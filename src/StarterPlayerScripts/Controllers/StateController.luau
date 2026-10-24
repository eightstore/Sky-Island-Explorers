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
		"Essence", delta, reason      -- saldo berubah (reason mis. "Passive", "Deposit")
		"Upgrades", upgradeId         -- level upgrade berubah
		"Bag"                         -- isi tas berubah
		"Base"                        -- isi markas berubah
		"Collection"                  -- koleksi / hadiah album berubah
		"Islands", islandId?          -- pulau terbuka
	AlbumCompleted:Fire(islandId, reward) -- satu bioma album baru lengkap
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)

type CritterView = Types.CritterView
type CollectionView = Types.CollectionView
type OfflineReport = Types.OfflineReport

local SNAPSHOT_MAX_ATTEMPTS = 10

local StateController = {}

StateController.Changed = Signal.new()
StateController.AlbumCompleted = Signal.new()
-- Dipicu jika snapshot gagal dimuat setelah semua percobaan
StateController.LoadFailed = Signal.new()

local state = {
	Loaded = false,
	Essence = 0,
	Upgrades = {} :: { [string]: number },
	Bag = {} :: { CritterView },
	BaseCritters = {} :: { CritterView },
	Collection = {} :: CollectionView,
	AlbumClaimed = {} :: { [string]: boolean },
	UnlockedIslands = {} :: { [string]: boolean },
	OfflineReport = nil :: OfflineReport?,
}

local revisions = {
	Essence = -1,
	Bag = -1,
	Base = -1,
	Collection = -1,
	Upgrades = {} :: { [string]: number },
	Islands = {} :: { [string]: number },
}

---------------------------------------------------------------------
-- Validasi data dari server
---------------------------------------------------------------------

local function parseCritterList(value: any): { CritterView }?
	if type(value) ~= "table" then
		return nil
	end
	local result: { CritterView } = {}
	for _, item in value do
		if type(item) == "table" and typeof(item.CritterId) == "string" then
			table.insert(result, { CritterId = item.CritterId, Shiny = item.Shiny == true })
		end
	end
	return result
end

local function parseCollection(value: any): CollectionView?
	if type(value) ~= "table" then
		return nil
	end
	local result: CollectionView = {}
	for critterId, entry in value do
		if typeof(critterId) == "string" and type(entry) == "table" then
			result[critterId] = { Caught = tonumber(entry.Caught) or 0, Shiny = tonumber(entry.Shiny) or 0 }
		end
	end
	return result
end

local function parseFlags(value: any): { [string]: boolean }
	local result: { [string]: boolean } = {}
	if type(value) == "table" then
		for key, flag in value do
			if typeof(key) == "string" and flag == true then
				result[key] = true
			end
		end
	end
	return result
end

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

function StateController.GetBag(): { CritterView }
	return state.Bag
end

function StateController.GetBagCount(): number
	return #state.Bag
end

function StateController.GetBagCapacity(): number
	return StateController.GetUpgradeStat("Bag", "Capacity")
end

function StateController.IsBagFull(): boolean
	return #state.Bag >= StateController.GetBagCapacity()
end

function StateController.GetBaseCritters(): { CritterView }
	return state.BaseCritters
end

function StateController.GetBaseSlots(): number
	return StateController.GetUpgradeStat("Base", "Slots")
end

-- Perkiraan essence pasif per menit (untuk tampilan; perhitungan asli di server)
function StateController.GetPassiveRate(): number
	local rate = 0
	for _, item in state.BaseCritters do
		rate += CritterConfig.GetPassive(item.CritterId, item.Shiny)
	end
	return rate
end

function StateController.GetCollection(): CollectionView
	return state.Collection
end

function StateController.IsAlbumClaimed(islandId: string): boolean
	return state.AlbumClaimed[islandId] == true
end

function StateController.IsIslandUnlocked(islandId: string): boolean
	return state.UnlockedIslands[islandId] == true
end

-- Laporan offline earnings dari snapshot awal (diambil sekali, lalu dikosongkan)
function StateController.TakeOfflineReport(): OfflineReport?
	local report = state.OfflineReport
	state.OfflineReport = nil
	return report
end

---------------------------------------------------------------------
-- Penerapan update
---------------------------------------------------------------------

local function applyEssence(balance: number, revision: number, delta: number, reason: string): ()
	if revision < revisions.Essence then
		return
	end
	revisions.Essence = revision
	state.Essence = balance
	StateController.Changed:Fire("Essence", delta, reason)
end

local function applyUpgrade(upgradeId: string, level: number, revision: number): ()
	if revision < (revisions.Upgrades[upgradeId] or -1) then
		return
	end
	revisions.Upgrades[upgradeId] = revision
	state.Upgrades[upgradeId] = level
	StateController.Changed:Fire("Upgrades", upgradeId)
end

local function applyBag(items: { CritterView }, revision: number): ()
	if revision < revisions.Bag then
		return
	end
	revisions.Bag = revision
	state.Bag = items
	StateController.Changed:Fire("Bag")
end

local function applyBase(items: { CritterView }, revision: number): ()
	if revision < revisions.Base then
		return
	end
	revisions.Base = revision
	state.BaseCritters = items
	StateController.Changed:Fire("Base")
end

local function applyCollection(collection: CollectionView, claimed: { [string]: boolean }, revision: number): ()
	if revision < revisions.Collection then
		return
	end
	revisions.Collection = revision
	state.Collection = collection
	state.AlbumClaimed = claimed
	StateController.Changed:Fire("Collection")
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
	if typeof(snapshot.Essence) ~= "number" or typeof(revision) ~= "number" or type(snapshot.Upgrades) ~= "table" then
		return false
	end
	local bag = parseCritterList(snapshot.Bag)
	local base = parseCritterList(snapshot.BaseCritters)
	local collection = parseCollection(snapshot.Collection)
	if not bag or not base or not collection then
		return false
	end

	applyEssence(snapshot.Essence, revision, 0, "Snapshot")
	applyBag(bag, revision)
	applyBase(base, revision)
	applyCollection(collection, parseFlags(snapshot.AlbumClaimed), revision)
	for upgradeId, level in snapshot.Upgrades do
		if typeof(upgradeId) == "string" and typeof(level) == "number" then
			applyUpgrade(upgradeId, level, revision)
		end
	end
	for islandId in parseFlags(snapshot.UnlockedIslands) do
		applyIsland(islandId, revision)
	end

	local report = snapshot.OfflineReport
	if type(report) == "table" and typeof(report.Amount) == "number" and typeof(report.Seconds) == "number" then
		state.OfflineReport = { Amount = report.Amount, Seconds = report.Seconds }
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
	Net.Event(Net.Events.EssenceChanged).OnClientEvent:Connect(function(balance: any, delta: any, reason: any, revision: any)
		if typeof(balance) == "number" and typeof(revision) == "number" then
			applyEssence(balance, revision, if typeof(delta) == "number" then delta else 0, if typeof(reason) == "string" then reason else "")
		end
	end)

	Net.Event(Net.Events.UpgradeChanged).OnClientEvent:Connect(function(upgradeId: any, level: any, revision: any)
		if typeof(upgradeId) == "string" and typeof(level) == "number" and typeof(revision) == "number" then
			applyUpgrade(upgradeId, level, revision)
		end
	end)

	Net.Event(Net.Events.BagChanged).OnClientEvent:Connect(function(items: any, revision: any)
		local parsed = parseCritterList(items)
		if parsed and typeof(revision) == "number" then
			applyBag(parsed, revision)
		end
	end)

	Net.Event(Net.Events.BaseChanged).OnClientEvent:Connect(function(items: any, revision: any)
		local parsed = parseCritterList(items)
		if parsed and typeof(revision) == "number" then
			applyBase(parsed, revision)
		end
	end)

	Net.Event(Net.Events.CollectionChanged).OnClientEvent:Connect(function(collection: any, claimed: any, revision: any)
		local parsed = parseCollection(collection)
		if parsed and typeof(revision) == "number" then
			applyCollection(parsed, parseFlags(claimed), revision)
		end
	end)

	Net.Event(Net.Events.IslandUnlocked).OnClientEvent:Connect(function(islandId: any, revision: any)
		if typeof(islandId) == "string" and typeof(revision) == "number" then
			applyIsland(islandId, revision)
		end
	end)

	Net.Event(Net.Events.AlbumCompleted).OnClientEvent:Connect(function(islandId: any, reward: any)
		if typeof(islandId) == "string" and typeof(reward) == "number" then
			StateController.AlbumCompleted:Fire(islandId, reward)
		end
	end)
end

function StateController.Start(): ()
	loadInitialState()
end

return StateController
