--!strict
--[[
	LeaderboardService
	------------------
	Tahap 1: leaderstats di papan pemain (Essence & Pulau Tertinggi).
	Papan peringkat global (OrderedDataStore) akan ditambahkan di tahap berikutnya.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)

local STAT_ESSENCE = "Essence"
local STAT_HIGHEST_ISLAND = "Pulau Tertinggi"

local LeaderboardService = {}

local function getStat(player: Player, statName: string): ValueBase?
	local leaderstats = player:FindFirstChild("leaderstats")
	local stat = if leaderstats then leaderstats:FindFirstChild(statName) else nil
	if stat and stat:IsA("ValueBase") then
		return stat
	end
	return nil
end

-- Memperbarui "Pulau Tertinggi" dari data. Dipanggil lagi oleh service lain saat pulau baru terbuka.
function LeaderboardService.RefreshHighestIsland(player: Player): ()
	local data = DataService.GetData(player)
	if not data then
		return
	end
	local island = IslandConfig.GetHighestUnlocked(data.UnlockedIslands)
	data.Stats.HighestIslandOrder = math.max(data.Stats.HighestIslandOrder, island.Order)

	local stat = getStat(player, STAT_HIGHEST_ISLAND)
	if stat and stat:IsA("StringValue") then
		stat.Value = island.DisplayName
	end
end

local function createLeaderstats(player: Player, profile: DataService.Profile): ()
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	-- Urutan pembuatan = urutan kolom di papan pemain
	local essence = Instance.new("IntValue")
	essence.Name = STAT_ESSENCE
	essence.Value = profile.Data.Essence
	essence.Parent = leaderstats

	local island = Instance.new("StringValue")
	island.Name = STAT_HIGHEST_ISLAND
	island.Value = IslandConfig.GetHighestUnlocked(profile.Data.UnlockedIslands).DisplayName
	island.Parent = leaderstats

	leaderstats.Parent = player
	LeaderboardService.RefreshHighestIsland(player)
end

function LeaderboardService.Init(): ()
	-- Dihubungkan di Init (sebelum DataService.Start) agar tidak ada event yang terlewat
	DataService.ProfileLoaded:Connect(createLeaderstats)

	EconomyService.EssenceChanged:Connect(function(player: Player, balance: number)
		local stat = getStat(player, STAT_ESSENCE)
		if stat and stat:IsA("IntValue") then
			stat.Value = balance
		end
	end)
end

function LeaderboardService.Start(): ()
end

return LeaderboardService
