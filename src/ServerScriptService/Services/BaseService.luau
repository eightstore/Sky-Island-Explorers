--!strict
--[[
	BaseService
	-----------
	Markas pemain: menaruh critter dari tas ke slot markas, mengambilnya kembali,
	dan menghitung essence pasif (termasuk offline earnings).

	ESSENCE PASIF (semua di server)
	  • Laju = jumlah PassivePerMinute semua critter di markas (shiny x ValueMultiplier).
	  • settle() menghitung essence sejak LastPassiveTime sampai sekarang, lalu memperbarui
	    LastPassiveTime. Sisa pecahan disimpan di PassiveRemainder agar tidak hilang.
	  • settle() dipanggil: tiap 60 detik, sebelum isi markas berubah (agar laju lama dihitung
	    dulu), dan saat pemain keluar / server mati.
	  • Saat data dimuat, waktu sejak LastPassiveTime = waktu offline, dibatasi 8 jam.
	    Hasilnya dilaporkan ke client lewat snapshot awal (pesan "selamat datang kembali").
	  • Waktu memakai os.time() server, jadi mengubah jam di perangkat pemain tidak berpengaruh.

	Remote:
		PlaceCritter(bagIndex, critterId)     -> ActionResult
		RetrieveCritter(slotIndex, critterId) -> ActionResult
	critterId ikut dikirim untuk memastikan isi tas/markas tidak berubah sejak UI dibuka.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local CritterService = require(ServerScriptService.Services.CritterService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)
local PromptFactory = require(ServerScriptService.Util.PromptFactory)
local StateViews = require(ServerScriptService.Util.StateViews)

type ActionResult = Types.ActionResult
type PlayerData = Types.PlayerData

local MAX_CRITTER_ID_LENGTH = 32
local MAX_INDEX = 1000

local BaseService = {}

local baseChangedRemote: RemoteEvent

local function reject(message: string): ActionResult
	return { Success = false, Message = message }
end

---------------------------------------------------------------------
-- Perhitungan essence pasif
---------------------------------------------------------------------

-- Total essence pasif per menit dari isi markas
function BaseService.GetPassiveRate(data: PlayerData): number
	local rate = 0
	for _, item in data.BaseCritters do
		rate += CritterConfig.GetPassive(item.CritterId, item.Shiny)
	end
	return rate
end

function BaseService.GetSlotCount(player: Player): number
	return EconomyService.GetUpgradeStats(player, "Base").Slots or 0
end

-- Menghitung & memberikan essence pasif sejak LastPassiveTime. Tidak ada yield.
-- Mengembalikan (essenceDiberikan, detikDihitung).
local function settle(profile: DataService.Profile, reason: string, multiplier: number): (number, number)
	local data = profile.Data
	local now = os.time()
	local last = data.LastPassiveTime

	-- Data baru atau jam aneh: mulai hitung dari sekarang
	if last <= 0 or last > now then
		data.LastPassiveTime = now
		return 0, 0
	end

	local elapsed = math.min(now - last, BaseConfig.MaxOfflineSeconds)
	data.LastPassiveTime = now

	local rate = BaseService.GetPassiveRate(data)
	if rate <= 0 or elapsed <= 0 then
		return 0, elapsed
	end

	local exact = rate * elapsed / 60 * multiplier + data.PassiveRemainder
	local whole = math.floor(exact)
	data.PassiveRemainder = exact - whole
	if whole > 0 then
		EconomyService.AddEssence(profile.Player, whole, reason)
	end
	return whole, elapsed
end

local function sendBase(profile: DataService.Profile): ()
	baseChangedRemote:FireClient(profile.Player, StateViews.Critters(profile.Data.BaseCritters), DataService.NextRevision(profile))
end

---------------------------------------------------------------------
-- Validasi umum
---------------------------------------------------------------------

local function isValidIndex(value: any): boolean
	return RemoteGuard.IsFiniteNumber(value) and value >= 1 and value <= MAX_INDEX and value % 1 == 0
end

local function isNearBase(player: Player): boolean
	return RemoteGuard.IsNearTagged(player, BaseConfig.Tag, BaseConfig.InteractDistance)
end

---------------------------------------------------------------------
-- Handler remote
---------------------------------------------------------------------

local function handlePlaceCritter(player: Player, bagIndex: any, critterId: any): ActionResult
	if not isValidIndex(bagIndex) or not RemoteGuard.IsValidString(critterId, MAX_CRITTER_ID_LENGTH) then
		RemoteGuard.Flag(player, "PlaceCritter:BadArgs")
		return reject("Permintaan tidak valid.")
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end
	if not isNearBase(player) then
		RemoteGuard.Flag(player, "PlaceCritter:TooFar")
		return reject("Dekati markas dulu.")
	end

	local data = profile.Data
	local item = data.Bag[bagIndex]
	if not item or item.CritterId ~= critterId then
		return reject("Isi tas berubah, coba lagi.")
	end
	if #data.BaseCritters >= BaseService.GetSlotCount(player) then
		return reject("Markas penuh! Tambah slot lewat upgrade Markas di toko.")
	end

	-- Hitung dulu essence dengan laju lama, baru ubah isi markas (tanpa yield = atomik)
	settle(profile, "Passive", 1)
	table.remove(data.Bag, bagIndex)
	table.insert(data.BaseCritters, { CritterId = item.CritterId, Shiny = item.Shiny, PlacedAt = os.time() })

	CritterService.SyncBag(profile)
	sendBase(profile)

	local def = CritterConfig.Get(item.CritterId)
	local name = if def then def.DisplayName else item.CritterId
	return {
		Success = true,
		Message = string.format("%s%s menjaga markas! (+%s ✨/menit)", if item.Shiny then "✨ " else "", name,
			NumberFormat.Abbreviate(CritterConfig.GetPassive(item.CritterId, item.Shiny))),
	}
end

local function handleRetrieveCritter(player: Player, slotIndex: any, critterId: any): ActionResult
	if not isValidIndex(slotIndex) or not RemoteGuard.IsValidString(critterId, MAX_CRITTER_ID_LENGTH) then
		RemoteGuard.Flag(player, "RetrieveCritter:BadArgs")
		return reject("Permintaan tidak valid.")
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end
	if not isNearBase(player) then
		RemoteGuard.Flag(player, "RetrieveCritter:TooFar")
		return reject("Dekati markas dulu.")
	end

	local data = profile.Data
	local item = data.BaseCritters[slotIndex]
	if not item or item.CritterId ~= critterId then
		return reject("Isi markas berubah, coba lagi.")
	end
	if #data.Bag >= CritterService.GetBagCapacity(player) then
		return reject("Tas penuh! Setor dulu sebelum mengambil critter.")
	end

	settle(profile, "Passive", 1)
	table.remove(data.BaseCritters, slotIndex)
	table.insert(data.Bag, { CritterId = item.CritterId, Shiny = item.Shiny, CaughtAt = os.time() })

	CritterService.SyncBag(profile)
	sendBase(profile)

	local def = CritterConfig.Get(item.CritterId)
	return { Success = true, Message = (if def then def.DisplayName else item.CritterId) .. " kembali ke tas." }
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

local function onProfileLoaded(_player: Player, profile: DataService.Profile): ()
	-- Offline earnings: waktu sejak perhitungan terakhir (maksimal 8 jam)
	local amount, seconds = settle(profile, "Offline", BaseConfig.OfflineMultiplier)
	if amount > 0 and seconds >= BaseConfig.MinOfflineReportSeconds then
		profile.OfflineReport = { Amount = amount, Seconds = seconds }
	end
end

local function passiveLoop(): ()
	while true do
		task.wait(BaseConfig.PassiveTickInterval)
		for _, player in Players:GetPlayers() do
			local profile = DataService.GetProfile(player)
			if profile then
				settle(profile, "Passive", 1)
			end
		end
	end
end

local function setupBasePrompt(instance: Instance): ()
	PromptFactory.Attach(instance, {
		Name = BaseConfig.PromptName,
		ActionText = "Buka Markas",
		ObjectText = "Markas",
		MaxActivationDistance = BaseConfig.PromptDistance,
	})
end

function BaseService.Init(): ()
	baseChangedRemote = Net.Event(Net.Events.BaseChanged)

	-- Dihubungkan di Init (sebelum DataService.Start) agar tidak ada event terlewat
	DataService.ProfileLoaded:Connect(onProfileLoaded)
	DataService.ProfileReleasing:Connect(function(_player: Player, profile: DataService.Profile)
		-- Hitung sampai detik ini sebelum disimpan, agar offline dihitung tepat dari saat keluar
		settle(profile, "Passive", 1)
	end)
end

function BaseService.Start(): ()
	RemoteGuard.BindFunction(Net.Function(Net.Functions.PlaceCritter), {
		Key = "PlaceCritter",
		Cooldown = BaseConfig.ActionCooldown,
		MaxArgs = 2,
		OnReject = reject,
	}, handlePlaceCritter)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.RetrieveCritter), {
		Key = "RetrieveCritter",
		Cooldown = BaseConfig.ActionCooldown,
		MaxArgs = 2,
		OnReject = reject,
	}, handleRetrieveCritter)

	for _, instance in CollectionService:GetTagged(BaseConfig.Tag) do
		setupBasePrompt(instance)
	end
	CollectionService:GetInstanceAddedSignal(BaseConfig.Tag):Connect(setupBasePrompt)

	task.spawn(passiveLoop)
end

return BaseService
