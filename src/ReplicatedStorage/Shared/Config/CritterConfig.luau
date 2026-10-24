--!strict
--[[
	CritterConfig
	-------------
	Semua angka balancing Sky Critters: rarity, bobot spawn, nilai essence, essence pasif,
	peluang shiny, serta aturan tangkap, gerak, spawn, dan setor.

	Bobot spawn (SpawnWeight) bersifat RELATIF di dalam satu pulau.
	Contoh di Padang Awan: 55 + 30 + 12 + 3 = 100 -> Kelinci Awan muncul 55% dari waktu.
	Peluang per pulau bisa dihitung dengan CritterConfig.GetSpawnOdds(listCritterId).

	Shiny ditentukan SAAT DITANGKAP (per pemain), sehingga luck pemain berpengaruh:
		peluang = BaseChance (1/500) * luck, dibatasi MaxChance
]]

export type RarityDef = {
	Id: string,
	DisplayName: string,
	Order: number,
	Color: Color3,
	Glow: boolean, -- material Neon + cahaya untuk rarity tinggi
}

export type CritterDef = {
	Id: string,
	DisplayName: string,
	Rarity: string,
	SpawnWeight: number,
	EssenceValue: number, -- essence saat disetor
	PassivePerMinute: number, -- essence pasif per menit saat ditaruh di markas (dipakai tahap berikutnya)
	Color: Color3,
	Size: number, -- diameter tubuh (stud)
}

local CritterConfig = {}

CritterConfig.Tags = table.freeze({
	Critter = "Critter", -- dipasang server pada setiap critter yang hidup
	Spawn = "CritterSpawn", -- Part titik spawn, wajib punya atribut IslandId (string)
})

CritterConfig.Attributes = table.freeze({
	Uid = "CritterUid",
	CritterId = "CritterId",
	IslandId = "IslandId",
	Rarity = "Rarity",
	BeingCaught = "BeingCaught",
	SpawnRadius = "SpawnRadius", -- (opsional, di titik spawn) radius sebar critter
})

CritterConfig.Shiny = table.freeze({
	BaseChance = 1 / 500,
	MaxChance = 1 / 10, -- batas atas walau luck sangat tinggi
	ValueMultiplier = 5, -- shiny bernilai 5x essence (setor & pasif)
})

CritterConfig.Catch = table.freeze({
	MinInterval = 0.2, -- jeda minimum antar permintaan tangkap (detik)
	DistanceTolerance = 4, -- toleransi jarak di server (stud) di atas radius jaring, untuk lag
	FinishTolerance = 10, -- toleransi jarak saat animasi tangkap selesai (pemain boleh sedikit bergerak)
	TapAssistPixels = 70, -- client: tap meleset sedikit tetap mengenai critter terdekat (ramah HP)
})

CritterConfig.Movement = table.freeze({
	SpawnScatter = 8, -- radius sebar dari titik spawn jika tidak ada atribut SpawnRadius
	HoverHeightMin = 3, -- ketinggian melayang di atas titik spawn
	HoverHeightMax = 6,
	WanderRadius = 10, -- jarak jelajah dari posisi awal
	HeightJitter = 2,
	MoveTimeMin = 2.5, -- durasi satu gerakan (detik)
	MoveTimeMax = 5,
	PauseMin = 0.5, -- jeda diam setelah bergerak
	PauseMax = 2.5,
	UpdateInterval = 0.2, -- seberapa sering server memeriksa critter yang perlu bergerak
})

CritterConfig.Spawn = table.freeze({
	CheckInterval = 1, -- detik antar pemeriksaan spawn
	MaxPerTick = 2, -- maksimal critter baru per pulau per pemeriksaan (agar tidak muncul serentak)
})

CritterConfig.Deposit = table.freeze({
	Tag = "SellZone", -- tag Part/Model zona setor di markas
	PromptName = "SellZonePrompt",
	PromptDistance = 12,
	InteractDistance = 22,
	Cooldown = 1,
})

local Rarities: { [string]: RarityDef } = {
	Common = { Id = "Common", DisplayName = "Biasa", Order = 1, Color = Color3.fromRGB(200, 205, 215), Glow = false },
	Uncommon = { Id = "Uncommon", DisplayName = "Tidak Biasa", Order = 2, Color = Color3.fromRGB(110, 210, 110), Glow = false },
	Rare = { Id = "Rare", DisplayName = "Langka", Order = 3, Color = Color3.fromRGB(80, 160, 255), Glow = false },
	Epic = { Id = "Epic", DisplayName = "Epik", Order = 4, Color = Color3.fromRGB(180, 100, 255), Glow = true },
	Legendary = { Id = "Legendary", DisplayName = "Legendaris", Order = 5, Color = Color3.fromRGB(255, 170, 40), Glow = true },
	Mythical = { Id = "Mythical", DisplayName = "Mitos", Order = 6, Color = Color3.fromRGB(255, 90, 180), Glow = true },
}

CritterConfig.Rarities = Rarities

local function critter(
	id: string,
	name: string,
	rarity: string,
	weight: number,
	value: number,
	passive: number,
	color: Color3,
	size: number
): CritterDef
	return {
		Id = id,
		DisplayName = name,
		Rarity = rarity,
		SpawnWeight = weight,
		EssenceValue = value,
		PassivePerMinute = passive,
		Color = color,
		Size = size,
	}
end

local CritterList: { CritterDef } = {
	-- Padang Awan
	critter("CloudBunny", "Kelinci Awan", "Common", 55, 2, 1, Color3.fromRGB(245, 245, 255), 2.2),
	critter("LeafWing", "Sayap Daun", "Common", 30, 3, 1.5, Color3.fromRGB(120, 200, 90), 2),
	critter("BreezeBee", "Lebah Semilir", "Uncommon", 12, 8, 4, Color3.fromRGB(255, 220, 80), 1.8),
	critter("SunPuff", "Bola Mentari", "Rare", 3, 25, 12, Color3.fromRGB(255, 180, 60), 2.4),

	-- Hutan Kabut
	critter("MistMoth", "Ngengat Kabut", "Common", 55, 12, 6, Color3.fromRGB(190, 200, 210), 2.2),
	critter("FogFox", "Rubah Kabut", "Uncommon", 30, 30, 15, Color3.fromRGB(220, 150, 110), 2.6),
	critter("DewSprite", "Peri Embun", "Rare", 12, 80, 40, Color3.fromRGB(140, 230, 255), 1.8),
	critter("MossDragonling", "Naga Lumut Kecil", "Epic", 3, 300, 150, Color3.fromRGB(70, 160, 90), 3),

	-- Gurun Petir
	critter("SparkBeetle", "Kumbang Percik", "Common", 55, 70, 35, Color3.fromRGB(255, 230, 120), 2),
	critter("SandSerpent", "Ular Pasir Angin", "Uncommon", 28, 180, 90, Color3.fromRGB(220, 180, 120), 2.6),
	critter("VoltHawk", "Elang Petir", "Rare", 13, 500, 250, Color3.fromRGB(100, 140, 255), 2.8),
	critter("ThunderRam", "Domba Guntur", "Epic", 3.5, 1500, 750, Color3.fromRGB(150, 150, 190), 3.2),
	critter("StormDjinn", "Jin Badai", "Legendary", 0.5, 6000, 3000, Color3.fromRGB(90, 200, 255), 3.6),

	-- Kristal Es
	critter("FrostPenguin", "Pinguin Salju", "Common", 55, 400, 200, Color3.fromRGB(230, 240, 255), 2.4),
	critter("CrystalCat", "Kucing Kristal", "Uncommon", 28, 1000, 500, Color3.fromRGB(170, 220, 255), 2.4),
	critter("AuroraOwl", "Burung Hantu Aurora", "Rare", 12.5, 3000, 1500, Color3.fromRGB(120, 255, 200), 2.6),
	critter("GlacierWhale", "Paus Gletser", "Epic", 4, 10000, 5000, Color3.fromRGB(80, 140, 220), 3.8),
	critter("IcePhoenix", "Phoenix Es", "Legendary", 0.5, 40000, 20000, Color3.fromRGB(180, 240, 255), 3.6),

	-- Istana Pelangi
	critter("PrismPup", "Anak Anjing Prisma", "Common", 50, 2500, 1250, Color3.fromRGB(255, 200, 230), 2.4),
	critter("RainbowKoi", "Koi Pelangi", "Uncommon", 30, 6000, 3000, Color3.fromRGB(255, 140, 120), 2.6),
	critter("StarUnicorn", "Unicorn Bintang", "Rare", 14, 18000, 9000, Color3.fromRGB(250, 240, 255), 3),
	critter("HaloGriffin", "Griffin Halo", "Epic", 5, 60000, 30000, Color3.fromRGB(255, 220, 140), 3.6),
	critter("CelestialDragon", "Naga Langit", "Legendary", 0.9, 250000, 125000, Color3.fromRGB(140, 120, 255), 4.2),
	critter("SkySpirit", "Roh Langit", "Mythical", 0.1, 1000000, 500000, Color3.fromRGB(255, 255, 255), 4),
}

local Critters: { [string]: CritterDef } = {}
for _, def in CritterList do
	assert(Critters[def.Id] == nil, "CritterConfig: Id duplikat " .. def.Id)
	Critters[def.Id] = def
end

CritterConfig.Critters = Critters

function CritterConfig.Get(id: string): CritterDef?
	return Critters[id]
end

function CritterConfig.GetRarity(id: string): RarityDef?
	return Rarities[id]
end

-- Peluang shiny untuk luck tertentu (luck 1 = normal)
function CritterConfig.GetShinyChance(luck: number): number
	local safeLuck = if luck == luck and luck > 0 then luck else 1
	return math.min(CritterConfig.Shiny.BaseChance * safeLuck, CritterConfig.Shiny.MaxChance)
end

-- Nilai essence saat disetor
function CritterConfig.GetValue(id: string, shiny: boolean): number
	local def = Critters[id]
	if not def then
		return 0
	end
	return def.EssenceValue * (if shiny then CritterConfig.Shiny.ValueMultiplier else 1)
end

-- Memilih satu critter dari daftar berdasarkan SpawnWeight
function CritterConfig.PickWeighted(critterIds: { string }, rng: Random): string?
	local total = 0
	for _, id in critterIds do
		local def = Critters[id]
		if def then
			total += def.SpawnWeight
		end
	end
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber(0, total)
	local running = 0
	local last: string? = nil
	for _, id in critterIds do
		local def = Critters[id]
		if def then
			running += def.SpawnWeight
			last = id
			if roll <= running then
				return id
			end
		end
	end
	return last
end

-- Peluang (0..1) setiap critter dalam daftar, untuk ditampilkan di UI
function CritterConfig.GetSpawnOdds(critterIds: { string }): { [string]: number }
	local total = 0
	for _, id in critterIds do
		local def = Critters[id]
		if def then
			total += def.SpawnWeight
		end
	end
	local odds: { [string]: number } = {}
	for _, id in critterIds do
		local def = Critters[id]
		if def and total > 0 then
			odds[id] = def.SpawnWeight / total
		end
	end
	return odds
end

-- Pemeriksaan kewarasan config. Dipanggil server saat boot.
function CritterConfig.Validate(): ()
	for id, def in Critters do
		assert(Rarities[def.Rarity], "CritterConfig: rarity tidak dikenal untuk " .. id .. ": " .. def.Rarity)
		assert(def.SpawnWeight > 0, "CritterConfig: SpawnWeight harus > 0: " .. id)
		assert(def.EssenceValue > 0, "CritterConfig: EssenceValue harus > 0: " .. id)
		assert(def.PassivePerMinute >= 0, "CritterConfig: PassivePerMinute tidak boleh negatif: " .. id)
		assert(def.Size > 0, "CritterConfig: Size harus > 0: " .. id)
	end
end

return CritterConfig
