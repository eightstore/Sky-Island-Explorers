--!strict
--[[
	EggConfig
	---------
	Telur awan per pulau: harga essence, lama dierami, dan TABEL PELUANG.

	Tabel peluang ini dipakai SERVER untuk mengundi hasil, dan dipakai UI untuk menampilkan
	odds setiap critter SEBELUM pemain membeli (sesuai kebijakan Roblox untuk item acak).
	Bobot (Weight) per telur dijumlahkan menjadi 100 agar mudah dibaca sebagai persen.

	Luck (2x Luck, Lucky Potion, event) HANYA memengaruhi peluang shiny, tidak mengubah
	tabel di bawah, sehingga persentase yang ditampilkan selalu tepat.
]]

export type EggOdd = {
	CritterId: string,
	Weight: number,
}

export type EggDef = {
	Id: string,
	DisplayName: string,
	IslandId: string, -- pulau harus terbuka untuk membeli telur ini
	Price: number, -- essence
	HatchTime: number, -- detik dierami (nyata, bukan timer palsu)
	Color: Color3,
	Order: number,
	Odds: { EggOdd },
}

local EggConfig = {}

EggConfig.Shop = table.freeze({
	Tag = "EggShop", -- tag Part/Model tempat membeli telur
	PromptName = "EggShopPrompt",
	PromptDistance = 12,
	InteractDistance = 24,
	ClientAutoCloseDistance = 22,
	Cooldown = 0.5,
	HatchTimeTolerance = 1, -- detik toleransi selisih jam client/server saat membuka telur
})

local Eggs: { [string]: EggDef } = {
	MeadowEgg = {
		Id = "MeadowEgg",
		DisplayName = "Telur Padang Awan",
		IslandId = "Meadow",
		Price = 150,
		HatchTime = 10,
		Color = Color3.fromRGB(190, 240, 170),
		Order = 1,
		Odds = {
			{ CritterId = "CloudBunny", Weight = 50 },
			{ CritterId = "LeafWing", Weight = 30 },
			{ CritterId = "BreezeBee", Weight = 15 },
			{ CritterId = "SunPuff", Weight = 5 },
		},
	},
	MistEgg = {
		Id = "MistEgg",
		DisplayName = "Telur Hutan Kabut",
		IslandId = "MistForest",
		Price = 1500,
		HatchTime = 20,
		Color = Color3.fromRGB(170, 200, 190),
		Order = 2,
		Odds = {
			{ CritterId = "MistMoth", Weight = 50 },
			{ CritterId = "FogFox", Weight = 30 },
			{ CritterId = "DewSprite", Weight = 15 },
			{ CritterId = "MossDragonling", Weight = 5 },
		},
	},
	ThunderEgg = {
		Id = "ThunderEgg",
		DisplayName = "Telur Gurun Petir",
		IslandId = "ThunderDesert",
		Price = 12000,
		HatchTime = 30,
		Color = Color3.fromRGB(250, 220, 120),
		Order = 3,
		Odds = {
			{ CritterId = "SparkBeetle", Weight = 45 },
			{ CritterId = "SandSerpent", Weight = 30 },
			{ CritterId = "VoltHawk", Weight = 17 },
			{ CritterId = "ThunderRam", Weight = 7 },
			{ CritterId = "StormDjinn", Weight = 1 },
		},
	},
	IceEgg = {
		Id = "IceEgg",
		DisplayName = "Telur Kristal Es",
		IslandId = "IceCrystal",
		Price = 80000,
		HatchTime = 45,
		Color = Color3.fromRGB(190, 235, 255),
		Order = 4,
		Odds = {
			{ CritterId = "FrostPenguin", Weight = 45 },
			{ CritterId = "CrystalCat", Weight = 30 },
			{ CritterId = "AuroraOwl", Weight = 17 },
			{ CritterId = "GlacierWhale", Weight = 7 },
			{ CritterId = "IcePhoenix", Weight = 1 },
		},
	},
	RainbowEgg = {
		Id = "RainbowEgg",
		DisplayName = "Telur Istana Pelangi",
		IslandId = "RainbowPalace",
		Price = 500000,
		HatchTime = 60,
		Color = Color3.fromRGB(255, 190, 235),
		Order = 5,
		Odds = {
			{ CritterId = "PrismPup", Weight = 44 },
			{ CritterId = "RainbowKoi", Weight = 30 },
			{ CritterId = "StarUnicorn", Weight = 17 },
			{ CritterId = "HaloGriffin", Weight = 7 },
			{ CritterId = "CelestialDragon", Weight = 1.8 },
			{ CritterId = "SkySpirit", Weight = 0.2 },
		},
	},
}

EggConfig.Eggs = Eggs

local order: { string } = {}
for id in Eggs do
	table.insert(order, id)
end
table.sort(order, function(a, b)
	return Eggs[a].Order < Eggs[b].Order
end)
EggConfig.Order = order

function EggConfig.Get(id: string): EggDef?
	return Eggs[id]
end

function EggConfig.GetTotalWeight(egg: EggDef): number
	local total = 0
	for _, odd in egg.Odds do
		total += odd.Weight
	end
	return total
end

-- Peluang (0..1) tiap critter di telur, urutan sama dengan tabel
function EggConfig.GetOdds(egg: EggDef): { { CritterId: string, Chance: number } }
	local total = EggConfig.GetTotalWeight(egg)
	local result: { { CritterId: string, Chance: number } } = {}
	for _, odd in egg.Odds do
		table.insert(result, { CritterId = odd.CritterId, Chance = if total > 0 then odd.Weight / total else 0 })
	end
	return result
end

-- Mengundi isi telur. Dipanggil HANYA di server dengan Random milik server.
function EggConfig.Roll(egg: EggDef, rng: Random): string
	local total = EggConfig.GetTotalWeight(egg)
	local roll = rng:NextNumber(0, total)
	local running = 0
	for _, odd in egg.Odds do
		running += odd.Weight
		if roll <= running then
			return odd.CritterId
		end
	end
	return egg.Odds[#egg.Odds].CritterId
end

-- Dipanggil server saat boot. criterExists dipasok pemanggil agar modul ini tidak bergantung pada CritterConfig.
function EggConfig.Validate(critterExists: (string) -> boolean, islandExists: (string) -> boolean): ()
	for id, egg in Eggs do
		assert(egg.Id == id, "EggConfig: Id tidak cocok: " .. id)
		assert(islandExists(egg.IslandId), "EggConfig: pulau tidak dikenal di " .. id)
		assert(egg.Price > 0 and egg.HatchTime >= 0, "EggConfig: harga/waktu tidak valid di " .. id)
		assert(#egg.Odds > 0, "EggConfig: tabel peluang kosong di " .. id)
		local total = 0
		for _, odd in egg.Odds do
			assert(critterExists(odd.CritterId), "EggConfig: critter tidak dikenal " .. odd.CritterId .. " di " .. id)
			assert(odd.Weight > 0, "EggConfig: bobot harus > 0 di " .. id)
			total += odd.Weight
		end
		assert(math.abs(total - 100) < 1e-6, string.format("EggConfig: total bobot %s = %s (harus 100)", id, tostring(total)))
	end
end

return EggConfig
