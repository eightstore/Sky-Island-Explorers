--!strict
--[[
	EconomyService
	--------------
	SATU-SATUNYA tempat yang boleh mengubah saldo Cloud Essence dan level upgrade.

	API untuk service lain:
		EconomyService.GetEssence(player) -> number
		EconomyService.AddEssence(player, amount, reason) -> (berhasil, saldoBaru)
		EconomyService.SpendEssence(player, amount, reason) -> (berhasil, pesanError?)
		EconomyService.GetUpgradeLevel(player, upgradeId) -> number
		EconomyService.EssenceChanged : Signal (player, saldoBaru, delta, reason)
		EconomyService.UpgradeChanged : Signal (player, upgradeId, levelBaru)

	Atomik: Luau di server berjalan single-threaded. Selama tidak ada yield (task.wait, InvokeClient,
	request DataStore) di antara "cek saldo" dan "kurangi saldo", tidak mungkin ada request lain yang
	menyelip. Karena itu SpendEssence dan alur beli upgrade sengaja ditulis TANPA yield.

	Remote yang ditangani:
		GetInitialState  : snapshot saldo & level untuk UI client
		PurchaseUpgrade  : beli upgrade (validasi penuh di server)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local EconomyConfig = require(ReplicatedStorage.Shared.Config.EconomyConfig)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local DataService = require(ServerScriptService.Services.DataService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)

type PurchaseResult = Types.PurchaseResult
type ClientSnapshot = Types.ClientSnapshot

local MAX_REASON_LENGTH = 64
local MAX_UPGRADE_ID_LENGTH = 32
local SNAPSHOT_WAIT_TIMEOUT = 30

local EconomyService = {}

EconomyService.EssenceChanged = Signal.new()
EconomyService.UpgradeChanged = Signal.new()

local essenceChangedRemote: RemoteEvent
local upgradeChangedRemote: RemoteEvent

---------------------------------------------------------------------
-- Internal
---------------------------------------------------------------------

-- Mengembalikan jumlah bulat positif yang valid, atau nil
local function validateAmount(amount: any): number?
	if not RemoteGuard.IsFiniteNumber(amount) then
		return nil
	end
	local whole = math.floor(amount)
	if whole <= 0 or whole > EconomyConfig.MaxTransaction then
		return nil
	end
	return whole
end

local function sanitizeReason(reason: any): string
	if typeof(reason) ~= "string" then
		return "Unknown"
	end
	return string.sub(reason, 1, MAX_REASON_LENGTH)
end

local function nextRevision(profile: DataService.Profile): number
	profile.Revision += 1
	return profile.Revision
end

local function broadcastEssence(profile: DataService.Profile, delta: number, reason: string): ()
	local player = profile.Player
	local balance = profile.Data.Essence
	local revision = nextRevision(profile)
	essenceChangedRemote:FireClient(player, balance, delta, reason, revision)
	EconomyService.EssenceChanged:Fire(player, balance, delta, reason)
end

local function reject(message: string): PurchaseResult
	return { Success = false, Message = message }
end

---------------------------------------------------------------------
-- API publik
---------------------------------------------------------------------

function EconomyService.GetEssence(player: Player): number
	local data = DataService.GetData(player)
	return if data then data.Essence else 0
end

function EconomyService.CanAfford(player: Player, amount: number): boolean
	local whole = validateAmount(amount)
	return whole ~= nil and EconomyService.GetEssence(player) >= whole
end

-- Menambah essence. Saldo dibatasi EconomyConfig.MaxEssence.
function EconomyService.AddEssence(player: Player, amount: number, reason: string): (boolean, number)
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, 0
	end

	local whole = validateAmount(amount)
	if not whole then
		warn(string.format("[EconomyService] AddEssence ditolak untuk %s: jumlah tidak valid (%s)", player.Name, tostring(amount)))
		return false, profile.Data.Essence
	end

	local data = profile.Data
	local before = data.Essence
	data.Essence = math.min(before + whole, EconomyConfig.MaxEssence)
	local gained = data.Essence - before
	data.Stats.TotalEssenceEarned += gained

	broadcastEssence(profile, gained, sanitizeReason(reason))
	return true, data.Essence
end

-- Mengurangi essence secara atomik. Gagal jika saldo kurang. TIDAK BOLEH ada yield di fungsi ini.
function EconomyService.SpendEssence(player: Player, amount: number, reason: string): (boolean, string?)
	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Data kamu belum siap, coba lagi sebentar."
	end

	local whole = validateAmount(amount)
	if not whole then
		warn(string.format("[EconomyService] SpendEssence ditolak untuk %s: jumlah tidak valid (%s)", player.Name, tostring(amount)))
		return false, "Jumlah tidak valid."
	end

	local data = profile.Data
	if data.Essence < whole then
		return false, "Essence kamu belum cukup."
	end

	-- Cek dan pengurangan terjadi di frame yang sama tanpa yield -> atomik
	data.Essence -= whole
	data.Stats.TotalEssenceSpent += whole

	broadcastEssence(profile, -whole, sanitizeReason(reason))
	return true, nil
end

function EconomyService.GetUpgradeLevel(player: Player, upgradeId: string): number
	local data = DataService.GetData(player)
	if not data then
		return UpgradeConfig.StartLevel
	end
	return data.Upgrades[upgradeId] or UpgradeConfig.StartLevel
end

-- Semua stat upgrade pemain saat ini, contoh: GetUpgradeStats(player, "Net").Radius
function EconomyService.GetUpgradeStats(player: Player, upgradeId: string): { [string]: number }
	return UpgradeConfig.GetStats(upgradeId, EconomyService.GetUpgradeLevel(player, upgradeId))
end

---------------------------------------------------------------------
-- Handler remote
---------------------------------------------------------------------

local function handlePurchaseUpgrade(player: Player, upgradeId: any): PurchaseResult
	-- 1. Validasi tipe & isi argumen
	if not RemoteGuard.IsValidString(upgradeId, MAX_UPGRADE_ID_LENGTH) then
		RemoteGuard.Flag(player, "PurchaseUpgrade:BadType")
		return reject("Permintaan tidak valid.")
	end
	local def = UpgradeConfig.Get(upgradeId)
	if not def then
		RemoteGuard.Flag(player, "PurchaseUpgrade:UnknownId")
		return reject("Upgrade tidak dikenal.")
	end

	-- 2. Data harus sudah dimuat
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end

	-- 3. Pemain harus berada di dekat toko
	if not RemoteGuard.IsNearTagged(player, UpgradeConfig.Shop.Tag, UpgradeConfig.Shop.InteractDistance) then
		RemoteGuard.Flag(player, "PurchaseUpgrade:TooFar")
		return reject("Dekati Toko Upgrade untuk membeli.")
	end

	-- 4. Level & harga dihitung di server dari config (client tidak pernah mengirim harga)
	local currentLevel = profile.Data.Upgrades[def.Id] or UpgradeConfig.StartLevel
	local cost = UpgradeConfig.GetCost(def.Id, currentLevel)
	if not cost then
		return reject(def.DisplayName .. " sudah level maksimum! ⭐")
	end

	-- 5. Bayar (atomik) lalu naikkan level di frame yang sama, tanpa yield
	local paid, errorMessage = EconomyService.SpendEssence(player, cost, "Upgrade:" .. def.Id)
	if not paid then
		return reject(errorMessage or "Pembelian gagal.")
	end

	local newLevel = currentLevel + 1
	profile.Data.Upgrades[def.Id] = newLevel

	upgradeChangedRemote:FireClient(player, def.Id, newLevel, nextRevision(profile))
	EconomyService.UpgradeChanged:Fire(player, def.Id, newLevel)

	return {
		Success = true,
		Message = string.format("%s naik ke level %d! 🎉", def.DisplayName, newLevel),
		UpgradeId = def.Id,
		NewLevel = newLevel,
		Essence = profile.Data.Essence,
	}
end

local function handleGetInitialState(player: Player): ClientSnapshot
	-- Boleh yield di sini (menunggu data dimuat) karena tidak mengubah ekonomi
	local profile = DataService.WaitForProfile(player, SNAPSHOT_WAIT_TIMEOUT)
	if not profile then
		return { Loaded = false, Essence = 0, Upgrades = {}, Revision = 0 }
	end
	return {
		Loaded = true,
		Essence = profile.Data.Essence,
		Upgrades = table.clone(profile.Data.Upgrades),
		Revision = profile.Revision,
	}
end

---------------------------------------------------------------------
-- Toko upgrade di dunia
---------------------------------------------------------------------

-- Membuat ProximityPrompt di setiap Part/Model ber-tag UpgradeShop (mendukung keyboard, touch & gamepad)
local function setupShop(instance: Instance): ()
	local host: Instance? = nil
	if instance:IsA("BasePart") then
		host = instance
	elseif instance:IsA("Model") then
		host = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
	end
	if not host then
		warn("[EconomyService] Objek ber-tag " .. UpgradeConfig.Shop.Tag .. " harus berupa Part atau Model berisi Part: " .. instance:GetFullName())
		return
	end
	if host:FindFirstChild(UpgradeConfig.Shop.PromptName) then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = UpgradeConfig.Shop.PromptName
	prompt.ActionText = "Buka Toko"
	prompt.ObjectText = "Toko Upgrade"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = UpgradeConfig.Shop.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Parent = host
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function EconomyService.Init(): ()
	UpgradeConfig.Validate()

	essenceChangedRemote = Net.Event(Net.Events.EssenceChanged)
	upgradeChangedRemote = Net.Event(Net.Events.UpgradeChanged)
end

function EconomyService.Start(): ()
	RemoteGuard.BindFunction(Net.Function(Net.Functions.PurchaseUpgrade), {
		Key = "PurchaseUpgrade",
		Cooldown = UpgradeConfig.Shop.PurchaseCooldown,
		MaxArgs = 1,
		OnReject = reject,
	}, handlePurchaseUpgrade)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.GetInitialState), {
		Key = "GetInitialState",
		Cooldown = UpgradeConfig.Shop.SnapshotCooldown,
		MaxArgs = 0,
		OnReject = function(_message: string): any
			return { Loaded = false, Essence = 0, Upgrades = {}, Revision = 0 }
		end,
	}, handleGetInitialState)

	for _, instance in CollectionService:GetTagged(UpgradeConfig.Shop.Tag) do
		setupShop(instance)
	end
	CollectionService:GetInstanceAddedSignal(UpgradeConfig.Shop.Tag):Connect(setupShop)

	if #CollectionService:GetTagged(UpgradeConfig.Shop.Tag) == 0 then
		warn("[EconomyService] Belum ada objek ber-tag '" .. UpgradeConfig.Shop.Tag .. "'. Pembelian upgrade akan selalu ditolak.")
	end
end

return EconomyService
