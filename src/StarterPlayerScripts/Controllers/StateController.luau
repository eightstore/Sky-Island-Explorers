--!strict
--[[
	StateController
	---------------
	Cerminan state pemain di client (HANYA untuk tampilan, server tetap sumber kebenaran).
	Controller lain membaca state dari sini dan berlangganan StateController.Changed.

	Setiap update dari server membawa nomor revisi. Update yang lebih lama dari yang sudah
	diterima (per field) diabaikan, sehingga urutan tiba snapshot vs event tidak membuat
	UI menampilkan angka usang.

	Changed:Fire(key, ...) dengan key:
		"Loaded"                      -- snapshot pertama diterima
		"Essence", delta              -- saldo berubah
		"Upgrades", upgradeId         -- level upgrade berubah
		"Bag"                         -- jumlah isi tas berubah
		"Islands", islandId?          -- pulau terbuka
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)

local SNAPSHOT_MAX_ATTEMPTS = 10

local StateController = {}

StateController.Changed = Signal.new()
-- Dipicu jika snapshot gagal dimuat setelah semua percobaan
StateController.LoadFailed = Signal.new()

local state = {
	Loaded = false,
	Essence = 0,
	Upgrades = {} :: { [string]: number },
	BagCount = 0,
	UnlockedIslands = {} :: { [string]: boolean },
}

local revisions = {
	Essence = -1,
	Bag = -1,
	Upgrades = {} :: { [string]: number },
	Islands = {} :: { [string]: number },
}

---------------------------------------------------------------------
-- Getter
---------------------------------------------------------------------

function StateController.IsLoaded(): boolean
	return state.Loaded
end

function StateController.GetEssence(): number
	return state.Essence
end

function StateController.GetUpgradeLevel(upgradeId: string): number
	return state.Upgrades[upgradeId] or UpgradeConfig.StartLevel
end

function StateController.GetUpgradeStat(upgradeId: string, statId: string): number
	return UpgradeConfig.GetStats(upgradeId, StateController.GetUpgradeLevel(upgradeId))[statId] or 0
end

function StateController.GetBagCount(): number
	return state.BagCount
end

function StateController.GetBagCapacity(): number
	return StateController.GetUpgradeStat("Bag", "Capacity")
end

function StateController.IsBagFull(): boolean
	return state.BagCount >= StateController.GetBagCapacity()
end

function StateController.IsIslandUnlocked(islandId: string): boolean
	return state.UnlockedIslands[islandId] == true
end

---------------------------------------------------------------------
-- Penerapan update
---------------------------------------------------------------------

local function applyEssence(balance: number, revision: number, delta: number): ()
	if revision < revisions.Essence then
		return
	end
	revisions.Essence = revision
	state.Essence = balance
	StateController.Changed:Fire("Essence", delta)
end

local function applyUpgrade(upgradeId: string, level: number, revision: number): ()
	if revision < (revisions.Upgrades[upgradeId] or -1) then
		return
	end
	revisions.Upgrades[upgradeId] = revision
	state.Upgrades[upgradeId] = level
	StateController.Changed:Fire("Upgrades", upgradeId)
end

local function applyBag(count: number, revision: number): ()
	if revision < revisions.Bag then
		return
	end
	revisions.Bag = revision
	state.BagCount = count
	StateController.Changed:Fire("Bag")
end

local function applyIsland(islandId: string, revision: number): ()
	if revision < (revisions.Islands[islandId] or -1) then
		return
	end
	revisions.Islands[islandId] = revision
	state.UnlockedIslands[islandId] = true
	StateController.Changed:Fire("Islands", islandId)
end

local function applySnapshot(snapshot: any): boolean
	if type(snapshot) ~= "table" or snapshot.Loaded ~= true then
		return false
	end
	local revision = snapshot.Revision
	if typeof(snapshot.Essence) ~= "number" or typeof(revision) ~= "number" or typeof(snapshot.BagCount) ~= "number" then
		return false
	end
	if type(snapshot.Upgrades) ~= "table" or type(snapshot.UnlockedIslands) ~= "table" then
		return false
	end

	applyEssence(snapshot.Essence, revision, 0)
	applyBag(snapshot.BagCount, revision)
	for upgradeId, level in snapshot.Upgrades do
		if typeof(upgradeId) == "string" and typeof(level) == "number" then
			applyUpgrade(upgradeId, level, revision)
		end
	end
	for islandId, unlocked in snapshot.UnlockedIslands do
		if typeof(islandId) == "string" and unlocked == true then
			applyIsland(islandId, revision)
		end
	end

	state.Loaded = true
	StateController.Changed:Fire("Loaded")
	return true
end

local function loadInitialState(): ()
	local remote = Net.Function(Net.Functions.GetInitialState)
	for attempt = 1, SNAPSHOT_MAX_ATTEMPTS do
		local ok, snapshot = pcall(function(): any
			return remote:InvokeServer()
		end)
		if ok and applySnapshot(snapshot) then
			return
		end
		task.wait(math.min(2 * attempt, 6))
	end
	StateController.LoadFailed:Fire()
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function StateController.Init(): ()
	Net.Event(Net.Events.EssenceChanged).OnClientEvent:Connect(function(balance: any, delta: any, _reason: any, revision: any)
		if typeof(balance) == "number" and typeof(revision) == "number" then
			applyEssence(balance, revision, if typeof(delta) == "number" then delta else 0)
		end
	end)

	Net.Event(Net.Events.UpgradeChanged).OnClientEvent:Connect(function(upgradeId: any, level: any, revision: any)
		if typeof(upgradeId) == "string" and typeof(level) == "number" and typeof(revision) == "number" then
			applyUpgrade(upgradeId, level, revision)
		end
	end)

	Net.Event(Net.Events.BagChanged).OnClientEvent:Connect(function(count: any, revision: any)
		if typeof(count) == "number" and typeof(revision) == "number" then
			applyBag(count, revision)
		end
	end)

	Net.Event(Net.Events.IslandUnlocked).OnClientEvent:Connect(function(islandId: any, revision: any)
		if typeof(islandId) == "string" and typeof(revision) == "number" then
			applyIsland(islandId, revision)
		end
	end)
end

function StateController.Start(): ()
	loadInitialState()
end

return StateController
