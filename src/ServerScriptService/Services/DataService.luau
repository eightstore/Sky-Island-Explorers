--!strict
--[[
	DataService
	-----------
	Memuat, menyimpan, dan mengunci (session locking) data pemain.

	Bentuk record di DataStore:
		{
			Data = PlayerData,
			Meta = { SessionId = string?, LockedAt = number, LastSavedAt = number, SaveCount = number },
		}

	Cara kerja session locking (pola mirip ProfileStore, ditulis sendiri agar mudah dipahami):
	  1. Saat memuat, server memakai UpdateAsync untuk "mengklaim" record dengan menulis SessionId miliknya.
	  2. Jika record masih dikunci server LAIN dan kuncinya belum basi (LockedAt < LOCK_STALE_SECONDS),
	     server menunggu lalu mencoba lagi. Server lama biasanya sedang menyimpan saat pemain pindah server.
	     Jika tetap terkunci, pemain di-kick dengan pesan ramah, sehingga data tidak pernah dipakai di dua server.
	  3. Autosave (tiap 2 menit) memperbarui LockedAt agar kunci tetap "segar".
	  4. Saat pemain keluar atau server mati (BindToClose), data disimpan dan kunci dilepas (SessionId = nil).
	  5. Jika saat menyimpan ternyata kunci sudah diambil server lain, penyimpanan DIBATALKAN
	     (tidak menimpa data yang lebih baru) dan pemain di-kick.
	  6. Kunci yang basi (server crash tanpa sempat melepas) boleh diambil alih setelah LOCK_STALE_SECONDS.

	Semua request DataStore dibungkus pcall + retry dengan exponential backoff.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local EconomyConfig = require(ReplicatedStorage.Shared.Config.EconomyConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)

type PlayerData = Types.PlayerData

export type Profile = {
	Player: Player,
	UserId: number,
	Key: string,
	Data: PlayerData,
	Released: boolean, -- true = tidak menerima perubahan lagi (sedang/selesai dilepas)
	ReleaseDone: boolean, -- true = kunci sudah benar-benar dilepas di DataStore
	IsSaving: boolean,
	Revision: number, -- penghitung perubahan (tidak disimpan) agar client bisa mengabaikan update usang
	PlayTimeMark: number, -- os.clock() terakhir play time dihitung
	LoadedAt: number,
	LastSavedAt: number,
}

type StoredMeta = {
	SessionId: string?,
	LockedAt: number,
	LastSavedAt: number,
	SaveCount: number,
}

type StoredRecord = {
	Data: any,
	Meta: StoredMeta,
}

-- Pengaturan teknis (bukan balancing gameplay)
local SETTINGS = {
	STORE_NAME = "SkyIslandExplorers_PlayerData_v1",
	KEY_PREFIX = "Player_",
	SCHEMA_VERSION = 1,

	AUTOSAVE_INTERVAL = 120, -- detik (2 menit)
	AUTOSAVE_STAGGER = 0.25, -- jeda antar pemain saat autosave agar tidak membebani budget DataStore

	LOCK_STALE_SECONDS = 600, -- kunci tanpa pembaruan selama 10 menit dianggap basi (server crash)
	LOAD_LOCK_RETRIES = 6, -- berapa kali mencoba lagi jika data dikunci server lain
	LOAD_LOCK_RETRY_DELAY = 5, -- detik antar percobaan (total ±30 detik)

	REQUEST_RETRIES = 5, -- retry untuk error DataStore (jaringan/throttle)
	RETRY_BASE_DELAY = 1, -- 1, 2, 4, 8 detik

	BIND_TO_CLOSE_TIMEOUT = 25, -- Roblox memberi maksimal 30 detik

	-- Jika Studio belum diizinkan mengakses API DataStore, pakai penyimpanan sementara di memori
	USE_MOCK_STORE_IN_STUDIO = true,
}

-- ID unik sesi server ini (game.JobId kosong di Studio, jadi buat GUID sendiri)
local SESSION_ID = HttpService:GenerateGUID(false)

local DataService = {}

-- Signal: (player: Player, profile: Profile)
DataService.ProfileLoaded = Signal.new()
-- Signal: (player: Player, profile: Profile) — dipanggil SEBELUM data disimpan & dilepas
DataService.ProfileReleasing = Signal.new()

local store: any = nil
local usingMockStore = false
local profiles: { [Player]: Profile } = {}
local loadingPlayers: { [Player]: boolean } = {}
local pendingReleases: { [number]: boolean } = {} -- UserId yang sedang disimpan & dilepas

-- Migrasi skema: MIGRATIONS[n] mengubah data dari versi n ke n+1.
-- Contoh jika nanti SCHEMA_VERSION = 2:
--   [1] = function(data) data.Settings = { Music = true } end,
local MIGRATIONS: { [number]: (data: any) -> () } = {}

---------------------------------------------------------------------
-- Utilitas
---------------------------------------------------------------------

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function createTemplate(): PlayerData
	local upgrades: { [string]: number } = {}
	for id in UpgradeConfig.Upgrades do
		upgrades[id] = UpgradeConfig.StartLevel
	end

	local islands: { [string]: boolean } = {}
	for _, island in IslandConfig.Islands do
		if island.DefaultUnlocked then
			islands[island.Id] = true
		end
	end

	return {
		SchemaVersion = SETTINGS.SCHEMA_VERSION,
		Essence = EconomyConfig.StartingEssence,
		Upgrades = upgrades,
		Bag = {},
		Collection = {},
		UnlockedIslands = islands,
		BaseCritters = {},
		LoginStreak = 0,
		LastLoginDay = 0,
		LastLoginDate = "",
		LastLoginTime = 0,
		Cosmetics = {
			Owned = {},
			Equipped = {},
		},
		Stats = {
			TotalEssenceEarned = 0,
			TotalEssenceSpent = 0,
			TotalCrittersCaught = 0,
			TotalShinyCaught = 0,
			HighestIslandOrder = 1,
			PlayTimeSeconds = 0,
		},
		FirstJoinTime = os.time(),
	}
end

-- Mengisi field yang belum ada (mis. setelah update game menambah field baru). Field lama TIDAK dihapus.
local function reconcile(target: any, template: any): ()
	for key, templateValue in template do
		local current = target[key]
		if current == nil then
			target[key] = deepCopy(templateValue)
		elseif type(templateValue) == "table" then
			if type(current) == "table" then
				reconcile(current, templateValue)
			else
				warn(string.format("[DataService] Field '%s' rusak (tipe %s), diganti nilai default", tostring(key), typeof(current)))
				target[key] = deepCopy(templateValue)
			end
		elseif typeof(current) ~= typeof(templateValue) then
			warn(string.format("[DataService] Field '%s' rusak (tipe %s), diganti nilai default", tostring(key), typeof(current)))
			target[key] = templateValue
		end
	end
end

local function migrate(data: any): ()
	local version = tonumber(data.SchemaVersion) or 1
	while version < SETTINGS.SCHEMA_VERSION do
		local step = MIGRATIONS[version]
		if step then
			step(data)
		end
		version += 1
	end
	-- Jika version > SCHEMA_VERSION (ditulis server versi lebih baru), biarkan; reconcile tidak menghapus field.
	if version <= SETTINGS.SCHEMA_VERSION then
		data.SchemaVersion = SETTINGS.SCHEMA_VERSION
	end
end

-- Memastikan angka penting selalu valid (tidak NaN, tidak negatif, level dalam batas config)
local function sanitize(data: PlayerData): ()
	local essence = data.Essence
	if essence ~= essence then
		essence = 0
	end
	data.Essence = math.clamp(math.floor(essence), 0, EconomyConfig.MaxEssence)

	for id, def in UpgradeConfig.Upgrades do
		local level = data.Upgrades[id]
		if typeof(level) ~= "number" or level ~= level then
			level = UpgradeConfig.StartLevel
		end
		data.Upgrades[id] = math.clamp(math.floor(level), UpgradeConfig.StartLevel, def.MaxLevel)
	end

	for _, island in IslandConfig.Islands do
		if island.DefaultUnlocked then
			data.UnlockedIslands[island.Id] = true
		end
	end
end

local function updateLoginStreak(data: PlayerData): ()
	local now = os.time()
	local today = now // 86400 -- nomor hari UTC

	if data.LastLoginDay == today then
		-- Sudah login hari ini, streak tidak berubah
	elseif data.LastLoginDay == today - 1 then
		data.LoginStreak += 1
	else
		data.LoginStreak = 1
	end

	data.LastLoginDay = today
	data.LastLoginDate = os.date("!%Y-%m-%d", now) :: string
	data.LastLoginTime = now
end

-- Menjalankan fn dengan pcall + retry exponential backoff
local function withRetry(label: string, fn: () -> any): (boolean, any)
	local lastError: any = nil
	for attempt = 1, SETTINGS.REQUEST_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		warn(string.format("[DataService] %s gagal (percobaan %d/%d): %s", label, attempt, SETTINGS.REQUEST_RETRIES, tostring(result)))
		if attempt < SETTINGS.REQUEST_RETRIES then
			task.wait(SETTINGS.RETRY_BASE_DELAY * 2 ^ (attempt - 1))
		end
	end
	return false, lastError
end

---------------------------------------------------------------------
-- Mock store (hanya Studio tanpa akses API)
---------------------------------------------------------------------

local mockData: { [string]: any } = {}
local MockStore = {}

function MockStore.UpdateAsync(_self: any, key: string, transform: (any, any) -> any): any
	local current = mockData[key]
	local result = transform(deepCopy(current), nil)
	if result ~= nil then
		mockData[key] = deepCopy(result)
	end
	return result
end

local function resolveStore(): ()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(SETTINGS.STORE_NAME)
	end)

	-- Di Studio, coba satu request kecil untuk memastikan API benar-benar bisa diakses
	if ok and RunService:IsStudio() then
		local probeOk, probeError = pcall(function()
			result:GetAsync("__probe__")
		end)
		if not probeOk then
			ok = false
			result = probeError
		end
	end

	if ok then
		store = result
		usingMockStore = false
		return
	end

	if RunService:IsStudio() and SETTINGS.USE_MOCK_STORE_IN_STUDIO then
		warn("[DataService] DataStore tidak bisa diakses di Studio (" .. tostring(result) .. ").")
		warn("[DataService] Memakai MOCK STORE di memori: data TIDAK tersimpan setelah Stop.")
		store = MockStore
		usingMockStore = true
		return
	end

	error("[DataService] Gagal membuka DataStore: " .. tostring(result))
end

---------------------------------------------------------------------
-- Load & Save
---------------------------------------------------------------------

local function newMeta(): StoredMeta
	return { SessionId = nil, LockedAt = 0, LastSavedAt = 0, SaveCount = 0 }
end

-- Mengembalikan (Profile?, alasanGagal: string?)
local function loadProfile(player: Player): (Profile?, string?)
	local userId = player.UserId
	local key = SETTINGS.KEY_PREFIX .. tostring(userId)

	-- Jika server ini masih menyimpan sesi sebelumnya untuk pemain ini (rejoin cepat), tunggu dulu
	local waitStart = os.clock()
	while pendingReleases[userId] and os.clock() - waitStart < 30 do
		task.wait(0.25)
	end

	for lockAttempt = 1, SETTINGS.LOAD_LOCK_RETRIES do
		if player.Parent ~= Players then
			return nil, "left"
		end

		local lockedByOther = false
		local corruptRecord = false
		local claimedRecord: StoredRecord? = nil

		local ok, err = withRetry("Load " .. key, function()
			return store:UpdateAsync(key, function(old: any, _keyInfo: any): any
				-- Fungsi ini bisa dipanggil lebih dari sekali oleh Roblox, jadi reset status setiap kali
				lockedByOther = false
				corruptRecord = false
				claimedRecord = nil

				local now = os.time()
				local record: StoredRecord
				if old == nil then
					record = { Data = createTemplate(), Meta = newMeta() }
				elseif type(old) == "table" and type(old.Data) == "table" then
					record = old
					if type(record.Meta) ~= "table" then
						record.Meta = newMeta()
					end
				else
					-- Format tidak dikenal: jangan ditimpa diam-diam, batalkan dan laporkan
					corruptRecord = true
					return nil
				end

				local meta = record.Meta
				local lockOwner = meta.SessionId
				local lockAge = now - (tonumber(meta.LockedAt) or 0)
				if lockOwner ~= nil and lockOwner ~= SESSION_ID and lockAge < SETTINGS.LOCK_STALE_SECONDS then
					lockedByOther = true
					return nil -- batalkan penulisan
				end

				if lockOwner ~= nil and lockOwner ~= SESSION_ID then
					warn(string.format("[DataService] Mengambil alih kunci basi untuk %s (umur %ds)", key, lockAge))
				end

				meta.SessionId = SESSION_ID
				meta.LockedAt = now
				claimedRecord = record
				return record
			end)
		end)

		if not ok then
			warn("[DataService] Gagal memuat data " .. key .. ": " .. tostring(err))
			return nil, "error"
		end
		if corruptRecord then
			warn("[DataService] Record " .. key .. " berformat tidak dikenal. Tidak ditimpa; periksa manual.")
			return nil, "error"
		end

		local record = claimedRecord
		if not lockedByOther and record then
			local data = record.Data
			migrate(data)
			reconcile(data, createTemplate())
			local typedData = data :: PlayerData
			sanitize(typedData)
			updateLoginStreak(typedData)

			local profile: Profile = {
				Player = player,
				UserId = userId,
				Key = key,
				Data = typedData,
				Released = false,
				ReleaseDone = false,
				IsSaving = false,
				Revision = 0,
				PlayTimeMark = os.clock(),
				LoadedAt = os.time(),
				LastSavedAt = os.time(),
			}
			return profile, nil
		end

		warn(string.format("[DataService] Data %s dikunci server lain (percobaan %d/%d)", key, lockAttempt, SETTINGS.LOAD_LOCK_RETRIES))
		task.wait(SETTINGS.LOAD_LOCK_RETRY_DELAY)
	end

	return nil, "locked"
end

-- Menyimpan profil. release = true akan melepas session lock (dipakai saat keluar / shutdown).
local function saveProfile(profile: Profile, release: boolean): boolean
	if profile.ReleaseDone then
		return true
	end
	if profile.Released and not release then
		return false -- sudah dalam proses rilis, autosave tidak diperlukan
	end
	if release then
		profile.Released = true -- mulai sekarang tidak ada perubahan ekonomi yang diterima
	end

	-- Satu penyimpanan per profil dalam satu waktu
	while profile.IsSaving do
		task.wait(0.1)
	end
	if profile.ReleaseDone then
		return true
	end
	profile.IsSaving = true

	-- Hitung waktu bermain
	local now = os.clock()
	local elapsed = math.floor(now - profile.PlayTimeMark)
	profile.Data.Stats.PlayTimeSeconds += elapsed
	profile.PlayTimeMark += elapsed

	sanitize(profile.Data)

	local lostLock = false
	local ok, err = withRetry("Save " .. profile.Key, function()
		return store:UpdateAsync(profile.Key, function(old: any, _keyInfo: any): any
			lostLock = false
			-- Autosave yang tertunda tidak boleh mengunci ulang profil yang sudah dirilis
			if profile.Released and not release then
				return nil
			end

			local oldMeta = if type(old) == "table" and type(old.Meta) == "table" then old.Meta else nil
			local owner = if oldMeta then oldMeta.SessionId else nil
			if owner ~= nil and owner ~= SESSION_ID then
				lostLock = true
				return nil -- jangan timpa data milik sesi lain
			end

			local timestamp = os.time()
			local record: StoredRecord = {
				Data = profile.Data,
				Meta = {
					SessionId = if release then nil else SESSION_ID,
					LockedAt = timestamp,
					LastSavedAt = timestamp,
					SaveCount = (if oldMeta then tonumber(oldMeta.SaveCount) or 0 else 0) + 1,
				},
			}
			return record
		end)
	end)

	profile.IsSaving = false

	if lostLock then
		warn("[DataService] Kunci sesi " .. profile.Key .. " diambil server lain. Penyimpanan dibatalkan.")
		profile.Released = true
		profile.ReleaseDone = true
		local player = profile.Player
		if player.Parent == Players then
			player:Kick("Data kamu sedang dibuka di server lain. Silakan bergabung lagi ya!")
		end
		return false
	end

	if not ok then
		warn("[DataService] Gagal menyimpan " .. profile.Key .. ": " .. tostring(err))
		return false
	end

	profile.LastSavedAt = os.time()
	if release then
		profile.ReleaseDone = true
	end
	return true
end

---------------------------------------------------------------------
-- Event pemain
---------------------------------------------------------------------

local function onPlayerAdded(player: Player): ()
	if profiles[player] or loadingPlayers[player] then
		return
	end
	loadingPlayers[player] = true
	local profile, reason = loadProfile(player)
	loadingPlayers[player] = nil

	if not profile then
		if player.Parent == Players then
			if reason == "locked" then
				player:Kick("Data kamu masih dipakai di server lain. Tunggu sebentar lalu bergabung lagi ya!")
			else
				player:Kick("Gagal memuat data. Jangan khawatir, datamu aman. Silakan bergabung lagi!")
			end
		end
		return
	end

	-- Pemain keluar saat data sedang dimuat: langsung lepaskan kunci
	if player.Parent ~= Players then
		pendingReleases[profile.UserId] = true
		saveProfile(profile, true)
		pendingReleases[profile.UserId] = nil
		return
	end

	profiles[player] = profile
	print(string.format("[DataService] Data %s dimuat (Essence: %d, streak: %d)", player.Name, profile.Data.Essence, profile.Data.LoginStreak))
	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player): ()
	local profile = profiles[player]
	if not profile then
		return
	end
	DataService.ProfileReleasing:Fire(player, profile)

	pendingReleases[profile.UserId] = true
	local ok = saveProfile(profile, true)
	pendingReleases[profile.UserId] = nil
	profiles[player] = nil

	print(string.format("[DataService] Data %s %s saat keluar", player.Name, if ok then "tersimpan" else "GAGAL disimpan"))
end

local function autosaveLoop(): ()
	while true do
		task.wait(SETTINGS.AUTOSAVE_INTERVAL)

		-- Salin dulu daftar profil karena tabel bisa berubah saat menunggu
		local snapshot: { Profile } = {}
		for _, profile in profiles do
			table.insert(snapshot, profile)
		end

		for _, profile in snapshot do
			if not profile.Released then
				task.spawn(saveProfile, profile, false)
				task.wait(SETTINGS.AUTOSAVE_STAGGER)
			end
		end
	end
end

local function onServerClose(): ()
	local pending = 0
	for player, profile in profiles do
		pending += 1
		task.spawn(function()
			DataService.ProfileReleasing:Fire(player, profile)
			saveProfile(profile, true)
			pending -= 1
		end)
	end

	local start = os.clock()
	while pending > 0 and os.clock() - start < SETTINGS.BIND_TO_CLOSE_TIMEOUT do
		task.wait(0.1)
	end

	if pending > 0 then
		warn(string.format("[DataService] %d profil belum selesai disimpan saat server mati", pending))
	else
		print("[DataService] Semua data tersimpan sebelum server mati")
	end
end

---------------------------------------------------------------------
-- API publik
---------------------------------------------------------------------

-- Profil aktif (nil jika belum dimuat atau sedang dilepas)
function DataService.GetProfile(player: Player): Profile?
	local profile = profiles[player]
	if profile and not profile.Released then
		return profile
	end
	return nil
end

function DataService.GetData(player: Player): PlayerData?
	local profile = DataService.GetProfile(player)
	return if profile then profile.Data else nil
end

-- Menunggu profil siap (atau timeout / pemain keluar)
function DataService.WaitForProfile(player: Player, timeout: number): Profile?
	local deadline = os.clock() + timeout
	while player.Parent == Players and os.clock() < deadline do
		local profile = DataService.GetProfile(player)
		if profile then
			return profile
		end
		task.wait(0.1)
	end
	return DataService.GetProfile(player)
end

-- Simpan segera tanpa melepas kunci (mis. setelah pembelian Robux di tahap monetisasi)
function DataService.SaveNow(player: Player): boolean
	local profile = DataService.GetProfile(player)
	if not profile then
		return false
	end
	return saveProfile(profile, false)
end

function DataService.IsUsingMockStore(): boolean
	return usingMockStore
end

function DataService.Init(): ()
	resolveStore()
end

function DataService.Start(): ()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Pemain yang sudah masuk sebelum script berjalan (sering terjadi di Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(autosaveLoop)
	game:BindToClose(onServerClose)
end

return DataService
