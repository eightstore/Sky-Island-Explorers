--!strict
--[[
	IslandConfig
	------------
	Daftar pulau berurutan dari terendah ke tertinggi.

	Syarat membuka pulau:
	  1. Pulau sebelumnya (Order - 1) sudah terbuka
	  2. Level Glider >= RequiredGliderLevel
	  3. Membayar UnlockCost essence di gerbang pulau

	Height = ketinggian permukaan pulau (sumbu Y, dalam stud) sebagai acuan saat membangun map.
	Critters = daftar CritterId yang muncul di pulau ini (detailnya di CritterConfig).
]]

export type IslandDef = {
	Id: string,
	DisplayName: string,
	Order: number, -- 1 = paling rendah
	Height: number, -- acuan ketinggian (Y) permukaan pulau, dalam stud
	UnlockCost: number, -- essence
	RequiredGliderLevel: number,
	DefaultUnlocked: boolean,
	Critters: { string },
	MaxCritters: number, -- batas critter hidup sekaligus di pulau ini
	RespawnDelay: number, -- detik sebelum slot critter yang tertangkap boleh diisi lagi
	Color: Color3, -- warna tema (papan gerbang, UI)
	AlbumReward: number, -- essence saat semua critter pulau ini pernah ditangkap
}

local Islands: { IslandDef } = {
	{
		Id = "Meadow",
		DisplayName = "Padang Awan",
		Order = 1,
		Height = 50,
		UnlockCost = 0,
		RequiredGliderLevel = 1,
		DefaultUnlocked = true,
		Critters = { "CloudBunny", "LeafWing", "BreezeBee", "SunPuff" },
		MaxCritters = 10,
		RespawnDelay = 6,
		Color = Color3.fromRGB(140, 220, 120),
		AlbumReward = 200,
	},
	{
		Id = "MistForest",
		DisplayName = "Hutan Kabut",
		Order = 2,
		Height = 150,
		UnlockCost = 750,
		RequiredGliderLevel = 3,
		DefaultUnlocked = false,
		Critters = { "MistMoth", "FogFox", "DewSprite", "MossDragonling" },
		MaxCritters = 10,
		RespawnDelay = 8,
		Color = Color3.fromRGB(120, 170, 150),
		AlbumReward = 2000,
	},
	{
		Id = "ThunderDesert",
		DisplayName = "Gurun Petir",
		Order = 3,
		Height = 300,
		UnlockCost = 6000,
		RequiredGliderLevel = 6,
		DefaultUnlocked = false,
		Critters = { "SparkBeetle", "SandSerpent", "VoltHawk", "ThunderRam", "StormDjinn" },
		MaxCritters = 9,
		RespawnDelay = 10,
		Color = Color3.fromRGB(240, 200, 90),
		AlbumReward = 15000,
	},
	{
		Id = "IceCrystal",
		DisplayName = "Kristal Es",
		Order = 4,
		Height = 500,
		UnlockCost = 40000,
		RequiredGliderLevel = 10,
		DefaultUnlocked = false,
		Critters = { "FrostPenguin", "CrystalCat", "AuroraOwl", "GlacierWhale", "IcePhoenix" },
		MaxCritters = 8,
		RespawnDelay = 12,
		Color = Color3.fromRGB(150, 220, 255),
		AlbumReward = 100000,
	},
	{
		Id = "RainbowPalace",
		DisplayName = "Istana Pelangi",
		Order = 5,
		Height = 750,
		UnlockCost = 250000,
		RequiredGliderLevel = 15,
		DefaultUnlocked = false,
		Critters = { "PrismPup", "RainbowKoi", "StarUnicorn", "HaloGriffin", "CelestialDragon", "SkySpirit" },
		MaxCritters = 8,
		RespawnDelay = 15,
		Color = Color3.fromRGB(255, 150, 220),
		AlbumReward = 750000,
	},
}

table.sort(Islands, function(a, b)
	return a.Order < b.Order
end)

local byId: { [string]: IslandDef } = {}
for _, island in Islands do
	assert(byId[island.Id] == nil, "Id pulau duplikat: " .. island.Id)
	byId[island.Id] = island
end

local IslandConfig = {}

IslandConfig.Islands = Islands

-- Pengaturan gerbang pulau & anti-exploit
IslandConfig.Gate = table.freeze({
	Tag = "IslandGate", -- tag CollectionService untuk Part/Model gerbang
	IdAttribute = "IslandId", -- atribut string di gerbang: Id pulau yang dijaga
	PromptName = "IslandGatePrompt",
	PromptDistance = 12, -- jarak ProximityPrompt muncul
	InteractDistance = 22, -- jarak maksimum yang diterima server (ada toleransi lag)
	ClientAutoCloseDistance = 20, -- dialog otomatis tertutup jika pemain menjauh
	UnlockCooldown = 0.5, -- jeda minimum antar permintaan buka pulau (detik)
})

function IslandConfig.Get(id: string): IslandDef?
	return byId[id]
end

-- Pulau sebelum pulau ini (nil untuk pulau pertama)
function IslandConfig.GetPrevious(id: string): IslandDef?
	local island = byId[id]
	if not island then
		return nil
	end
	for _, other in Islands do
		if other.Order == island.Order - 1 then
			return other
		end
	end
	return nil
end

-- Mengembalikan pulau tertinggi yang sudah terbuka (minimal pulau pertama)
function IslandConfig.GetHighestUnlocked(unlocked: { [string]: boolean }): IslandDef
	local highest = Islands[1]
	for _, island in Islands do
		if unlocked[island.Id] == true and island.Order > highest.Order then
			highest = island
		end
	end
	return highest
end

return IslandConfig
