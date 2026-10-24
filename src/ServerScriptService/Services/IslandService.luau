--!strict
--[[
	IslandService
	-------------
	Mengurus pembukaan pulau, gerbang pulau, dan teleport pulau (perk "Teleport Pulau").

	Cara kerja gerbang:
	  • Server memasang ProximityPrompt "Buka Pulau" di setiap objek ber-tag IslandGate.
	  • Gerbang di server SELALU tertutup (padat). Client membuka gerbang secara lokal
	    (CanCollide = false) untuk pulau yang sudah terbuka di data pemain tersebut.
	  • Karena itu exploiter bisa saja menembus gerbang di layarnya sendiri, TETAPI server
	    menolak penangkapan critter di pulau yang belum terbuka (dicek di CritterService).
	    Jadi menembus gerbang tidak memberi keuntungan apa pun.

	Remote: UnlockIsland(islandId) -> UnlockResult
	        TeleportToIsland(islandId) -> ActionResult  (butuh perk IslandTeleport + pulau terbuka)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local LeaderboardService = require(ServerScriptService.Services.LeaderboardService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)
local PromptFactory = require(ServerScriptService.Util.PromptFactory)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local MonetizationService = require(ServerScriptService.Services.MonetizationService)
local GliderService = require(ServerScriptService.Services.GliderService)

type UnlockResult = Types.UnlockResult

local MAX_ISLAND_ID_LENGTH = 32

local IslandService = {}

-- Signal: (player: Player, islandId: string)
IslandService.IslandUnlocked = Signal.new()

local islandUnlockedRemote: RemoteEvent

local function reject(message: string): UnlockResult
	return { Success = false, Message = message }
end

function IslandService.IsUnlocked(player: Player, islandId: string): boolean
	local data = DataService.GetData(player)
	return data ~= nil and data.UnlockedIslands[islandId] == true
end

-- true jika pemain berada dekat gerbang milik pulau islandId
local function isNearGate(player: Player, islandId: string): boolean
	local root = RemoteGuard.GetRootPart(player)
	if not root then
		return false
	end
	for _, gate in CollectionService:GetTagged(IslandConfig.Gate.Tag) do
		if gate:GetAttribute(IslandConfig.Gate.IdAttribute) == islandId then
			local position = RemoteGuard.GetInstancePosition(gate)
			if position and (position - root.Position).Magnitude <= IslandConfig.Gate.InteractDistance then
				return true
			end
		end
	end
	return false
end

local function handleUnlockIsland(player: Player, islandId: any): UnlockResult
	-- 1. Validasi argumen
	if not RemoteGuard.IsValidString(islandId, MAX_ISLAND_ID_LENGTH) then
		RemoteGuard.Flag(player, "UnlockIsland:BadType")
		return reject("Permintaan tidak valid.")
	end
	local island = IslandConfig.Get(islandId)
	if not island then
		RemoteGuard.Flag(player, "UnlockIsland:UnknownId")
		return reject("Pulau tidak dikenal.")
	end

	-- 2. Data siap & belum terbuka
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end
	local data = profile.Data
	if data.UnlockedIslands[island.Id] then
		return reject(island.DisplayName .. " sudah terbuka!")
	end

	-- 3. Pulau sebelumnya harus sudah terbuka
	local previous = IslandConfig.GetPrevious(island.Id)
	if previous and not data.UnlockedIslands[previous.Id] then
		return reject("Buka " .. previous.DisplayName .. " dulu ya!")
	end

	-- 4. Syarat level glider
	local gliderLevel = EconomyService.GetUpgradeLevel(player, "Glider")
	if gliderLevel < island.RequiredGliderLevel then
		return reject(string.format("Butuh Glider level %d (sekarang level %d).", island.RequiredGliderLevel, gliderLevel))
	end

	-- 5. Harus berada di dekat gerbang pulau tersebut
	if not isNearGate(player, island.Id) then
		RemoteGuard.Flag(player, "UnlockIsland:TooFar")
		return reject("Dekati gerbang " .. island.DisplayName .. " dulu.")
	end

	-- 6. Bayar (atomik) lalu buka di frame yang sama, tanpa yield
	if island.UnlockCost > 0 then
		local paid, errorMessage = EconomyService.SpendEssence(player, island.UnlockCost, "UnlockIsland:" .. island.Id)
		if not paid then
			return reject(errorMessage or "Gagal membuka pulau.")
		end
	end

	data.UnlockedIslands[island.Id] = true
	islandUnlockedRemote:FireClient(player, island.Id, DataService.NextRevision(profile))
	LeaderboardService.RefreshHighestIsland(player)
	IslandService.IslandUnlocked:Fire(player, island.Id)

	return {
		Success = true,
		Message = "🎉 " .. island.DisplayName .. " terbuka! Selamat menjelajah!",
		IslandId = island.Id,
	}
end

local function handleTeleport(player: Player, islandId: any): Types.ActionResult
	if not RemoteGuard.IsValidString(islandId, MAX_ISLAND_ID_LENGTH) then
		RemoteGuard.Flag(player, "TeleportToIsland:BadType")
		return { Success = false, Message = "Permintaan tidak valid." }
	end
	local island = IslandConfig.Get(islandId)
	if not island then
		return { Success = false, Message = "Pulau tidak dikenal." }
	end
	if not MonetizationService.HasPerk(player, "IslandTeleport") then
		RemoteGuard.Flag(player, "TeleportToIsland:NoPerk")
		return { Success = false, Message = "Butuh perk Teleport Pulau 🌀" }
	end
	if not IslandService.IsUnlocked(player, island.Id) then
		return { Success = false, Message = "Buka " .. island.DisplayName .. " dulu." }
	end
	local root = RemoteGuard.GetRootPart(player)
	if not root then
		return { Success = false, Message = "Karaktermu belum siap." }
	end

	for _, spawnPoint in CollectionService:GetTagged(ProductConfig.Shop.TeleportSpawnTag) do
		if spawnPoint:IsA("BasePart") and spawnPoint:GetAttribute(IslandConfig.Gate.IdAttribute) == island.Id then
			-- Beri jeda anti-cheat agar perpindahan jauh ini tidak dianggap speed-hack
			GliderService.GrantGrace(player, 3)
			root.AssemblyLinearVelocity = Vector3.zero
			root.CFrame = spawnPoint.CFrame + Vector3.new(0, 4, 0)
			return { Success = true, Message = "🌀 Tiba di " .. island.DisplayName .. "!" }
		end
	end
	warn("[IslandService] Tidak ada Part ber-tag " .. ProductConfig.Shop.TeleportSpawnTag .. " untuk " .. island.Id)
	return { Success = false, Message = "Titik teleport pulau ini belum dibuat." }
end

local function setupGate(gate: Instance): ()
	local islandId = gate:GetAttribute(IslandConfig.Gate.IdAttribute)
	local island = if typeof(islandId) == "string" then IslandConfig.Get(islandId) else nil
	if not island then
		warn(string.format("[IslandService] Gerbang %s butuh atribut %s berisi Id pulau yang valid", gate:GetFullName(), IslandConfig.Gate.IdAttribute))
		return
	end
	if island.DefaultUnlocked then
		return -- pulau awal tidak butuh prompt
	end
	PromptFactory.Attach(gate, {
		Name = IslandConfig.Gate.PromptName,
		ActionText = "Buka Pulau",
		ObjectText = island.DisplayName,
		MaxActivationDistance = IslandConfig.Gate.PromptDistance,
	})
end

function IslandService.Init(): ()
	islandUnlockedRemote = Net.Event(Net.Events.IslandUnlocked)
end

function IslandService.Start(): ()
	RemoteGuard.BindFunction(Net.Function(Net.Functions.UnlockIsland), {
		Key = "UnlockIsland",
		Cooldown = IslandConfig.Gate.UnlockCooldown,
		MaxArgs = 1,
		OnReject = reject,
	}, handleUnlockIsland)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.TeleportToIsland), {
		Key = "TeleportToIsland",
		Cooldown = ProductConfig.Effects.TeleportCooldown,
		MaxArgs = 1,
		OnReject = function(message: string): any
			return { Success = false, Message = message }
		end,
	}, handleTeleport)

	for _, gate in CollectionService:GetTagged(IslandConfig.Gate.Tag) do
		setupGate(gate)
	end
	CollectionService:GetInstanceAddedSignal(IslandConfig.Gate.Tag):Connect(setupGate)
end

return IslandService
