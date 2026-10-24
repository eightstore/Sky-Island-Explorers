--!strict
--[[
	Net
	---
	Satu-satunya tempat yang mendefinisikan nama RemoteEvent / RemoteFunction.
	• Server memanggil Net.Setup() sekali saat boot untuk membuat folder ReplicatedStorage/Remotes.
	• Server dan client mengambil remote lewat Net.Event(...) / Net.Function(...).
	Dengan begitu tidak ada "string ajaib" yang tersebar di banyak file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.FOLDER_NAME = "Remotes"
Net.WAIT_TIMEOUT = 30

-- RemoteEvent. Arah ditulis di komentar: [S->C] server ke client, [C->S] client ke server.
Net.Events = table.freeze({
	EssenceChanged = "EssenceChanged", -- [S->C] (saldoBaru: number, delta: number, alasan: string, revisi: number)
	UpgradeChanged = "UpgradeChanged", -- [S->C] (upgradeId: string, levelBaru: number, revisi: number)
	BagChanged = "BagChanged", -- [S->C] (isiTas: {CritterView}, revisi: number)
	BaseChanged = "BaseChanged", -- [S->C] (isiMarkas: {CritterView}, revisi: number)
	CollectionChanged = "CollectionChanged", -- [S->C] (koleksi: CollectionView, hadiahAlbum: {[IslandId]: true}, revisi: number)
	IslandUnlocked = "IslandUnlocked", -- [S->C] (islandId: string, revisi: number)
	AlbumCompleted = "AlbumCompleted", -- [S->C] (islandId: string, hadiah: number)
	GliderState = "GliderState", -- [C->S] (sedangMelayang: boolean)
})

-- Client -> Server (dengan nilai balik)
Net.Functions = table.freeze({
	GetInitialState = "GetInitialState", -- () -> ClientSnapshot
	PurchaseUpgrade = "PurchaseUpgrade", -- (upgradeId: string) -> PurchaseResult
	CatchCritter = "CatchCritter", -- (critterUid: string) -> CatchResult
	DepositBag = "DepositBag", -- () -> DepositResult
	UnlockIsland = "UnlockIsland", -- (islandId: string) -> UnlockResult
	PlaceCritter = "PlaceCritter", -- (indeksTas: number, critterId: string) -> ActionResult
	RetrieveCritter = "RetrieveCritter", -- (indeksSlot: number, critterId: string) -> ActionResult
})

-- Membuat semua remote. HANYA dipanggil server.
function Net.Setup(): ()
	assert(RunService:IsServer(), "Net.Setup hanya boleh dipanggil dari server")

	local folder = ReplicatedStorage:FindFirstChild(Net.FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Net.FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	assert(folder, "Folder Remotes gagal dibuat")

	for _, name in Net.Events do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	for _, name in Net.Functions do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
end

local function getFolder(): Instance
	local folder = ReplicatedStorage:WaitForChild(Net.FOLDER_NAME, Net.WAIT_TIMEOUT)
	assert(folder, "Folder ReplicatedStorage/Remotes tidak ditemukan (apakah server sudah memanggil Net.Setup?)")
	return folder
end

function Net.Event(name: string): RemoteEvent
	local remote = getFolder():WaitForChild(name, Net.WAIT_TIMEOUT)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	error("RemoteEvent tidak ditemukan: " .. name)
end

function Net.Function(name: string): RemoteFunction
	local remote = getFolder():WaitForChild(name, Net.WAIT_TIMEOUT)
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	error("RemoteFunction tidak ditemukan: " .. name)
end

return Net
