--!strict
--[[
	AlbumService
	------------
	Album / Index koleksi critter per bioma (pulau).
	  • Setiap critter yang pernah ditangkap tercatat di data.Collection (diisi CritterService).
	  • Saat semua critter di satu pulau pernah ditangkap minimal sekali, pemain otomatis
	    mendapat hadiah IslandConfig.AlbumReward (hanya sekali, dicatat di data.AlbumClaimed).
	  • Client menerima salinan koleksi lewat CollectionChanged untuk menggambar UI Album.

	Hadiah diberikan otomatis (tanpa remote "klaim"), jadi tidak ada celah exploit klaim ganda.
	Jika nanti ada critter baru di pulau yang hadiahnya sudah diambil, hadiah tidak diberikan ulang.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local CritterService = require(ServerScriptService.Services.CritterService)
local StateViews = require(ServerScriptService.Util.StateViews)

local AlbumService = {}

-- Signal: (player: Player, islandId: string, reward: number)
AlbumService.AlbumCompleted = Signal.new()

local collectionChangedRemote: RemoteEvent
local albumCompletedRemote: RemoteEvent

-- (jumlah jenis yang sudah ditangkap, total jenis) untuk satu pulau
function AlbumService.GetProgress(collection: { [string]: any }, island: IslandConfig.IslandDef): (number, number)
	local caught = 0
	for _, critterId in island.Critters do
		if collection[critterId] ~= nil then
			caught += 1
		end
	end
	return caught, #island.Critters
end

local function sendCollection(profile: DataService.Profile): ()
	local data = profile.Data
	collectionChangedRemote:FireClient(
		profile.Player,
		StateViews.Collection(data.Collection),
		table.clone(data.AlbumClaimed),
		DataService.NextRevision(profile)
	)
end

-- Memberi hadiah untuk setiap pulau yang baru lengkap. Tidak ada yield.
local function checkCompletion(profile: DataService.Profile): boolean
	local data = profile.Data
	local anyNew = false
	for _, island in IslandConfig.Islands do
		if not data.AlbumClaimed[island.Id] then
			local caught, total = AlbumService.GetProgress(data.Collection, island)
			if total > 0 and caught >= total then
				data.AlbumClaimed[island.Id] = true
				anyNew = true
				if island.AlbumReward > 0 then
					EconomyService.AddEssence(profile.Player, island.AlbumReward, "Album:" .. island.Id)
				end
				albumCompletedRemote:FireClient(profile.Player, island.Id, island.AlbumReward)
				AlbumService.AlbumCompleted:Fire(profile.Player, island.Id, island.AlbumReward)
			end
		end
	end
	return anyNew
end

function AlbumService.Init(): ()
	collectionChangedRemote = Net.Event(Net.Events.CollectionChanged)
	albumCompletedRemote = Net.Event(Net.Events.AlbumCompleted)

	-- Saat dimuat: berikan hadiah yang mungkin tertunda (mis. pulau lengkap sebelum fitur ini ada)
	DataService.ProfileLoaded:Connect(function(_player: Player, profile: DataService.Profile)
		checkCompletion(profile)
	end)

	CritterService.CritterCaught:Connect(function(player: Player, _critterId: string, _shiny: boolean, _isNew: boolean)
		local profile = DataService.GetProfile(player)
		if not profile then
			return
		end
		checkCompletion(profile)
		sendCollection(profile)
	end)
end

function AlbumService.Start(): () end

return AlbumService
