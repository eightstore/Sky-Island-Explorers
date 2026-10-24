--!strict
--[[
	UpgradeConfig
	-------------
	Semua angka balancing upgrade. Dibaca server (validasi & harga) DAN client (tampilan toko),
	sehingga angka di UI selalu sama dengan yang dipakai server.

	Rumus harga (untuk naik dari level L ke L+1):
		Harga(L) = BaseCost * CostGrowth ^ (L - StartLevel), dibulatkan ke 2 angka penting
		Contoh Jaring: 50, 68, 91, 120, 170, ...

	Rumus stat di level L:
		Nilai(L) = Base + PerLevel * (L - StartLevel), lalu dibatasi Min/Max
]]

export type StatDef = {
	Id: string,
	DisplayName: string,
	Base: number,
	PerLevel: number,
	Min: number?,
	Max: number?,
	Decimals: number, -- jumlah angka di belakang koma saat ditampilkan
	Unit: string,
	LowerIsBetter: boolean?, -- true untuk stat seperti "waktu tangkap"
}

export type UpgradeDef = {
	Id: string,
	DisplayName: string,
	Description: string,
	Icon: string,
	Order: number, -- urutan tampil di toko
	MaxLevel: number,
	BaseCost: number,
	CostGrowth: number,
	Stats: { StatDef },
}

local UpgradeConfig = {}

-- Level awal setiap upgrade untuk pemain baru
UpgradeConfig.StartLevel = 1

-- Pembulatan harga agar terlihat "rapi" (2 = dua angka penting, mis. 1234 -> 1200)
UpgradeConfig.CostSignificantDigits = 2

-- Pengaturan toko & anti-exploit
UpgradeConfig.Shop = table.freeze({
	Tag = "UpgradeShop", -- tag CollectionService untuk Part/Model toko
	PromptName = "UpgradeShopPrompt", -- nama ProximityPrompt yang dibuat server
	PromptDistance = 10, -- jarak (stud) ProximityPrompt muncul
	InteractDistance = 18, -- jarak maksimum yang diterima SERVER saat membeli (ada toleransi lag)
	ClientAutoCloseDistance = 16, -- UI toko otomatis tertutup jika pemain menjauh
	PurchaseCooldown = 0.3, -- jeda minimum antar pembelian per pemain (detik)
	SnapshotCooldown = 1, -- jeda minimum permintaan GetInitialState (detik)
})

local Upgrades: { [string]: UpgradeDef } = {
	Net = {
		Id = "Net",
		DisplayName = "Jaring",
		Description = "Jaring lebih lebar dan lebih cepat menangkap critter.",
		Icon = "🥅",
		Order = 1,
		MaxLevel = 25,
		BaseCost = 50,
		CostGrowth = 1.35,
		Stats = {
			{ Id = "Radius", DisplayName = "Radius", Base = 8, PerLevel = 0.5, Max = 20, Decimals = 1, Unit = " stud" },
			{
				Id = "CaptureTime",
				DisplayName = "Waktu Tangkap",
				Base = 1.5,
				PerLevel = -0.05,
				Min = 0.3,
				Decimals = 2,
				Unit = " dtk",
				LowerIsBetter = true,
			},
		},
	},

	Glider = {
		Id = "Glider",
		DisplayName = "Glider",
		Description = "Melayang lebih cepat dan lebih jauh antar pulau.",
		Icon = "🪂",
		Order = 2,
		MaxLevel = 25,
		BaseCost = 75,
		CostGrowth = 1.4,
		Stats = {
			{ Id = "Speed", DisplayName = "Kecepatan", Base = 30, PerLevel = 1.5, Max = 70, Decimals = 1, Unit = " stud/dtk" },
			{ Id = "MaxDistance", DisplayName = "Jarak Maks", Base = 120, PerLevel = 20, Max = 600, Decimals = 0, Unit = " stud" },
		},
	},

	Bag = {
		Id = "Bag",
		DisplayName = "Tas",
		Description = "Bawa lebih banyak critter sebelum kembali ke markas.",
		Icon = "🎒",
		Order = 3,
		MaxLevel = 30,
		BaseCost = 40,
		CostGrowth = 1.3,
		Stats = {
			{ Id = "Capacity", DisplayName = "Kapasitas", Base = 10, PerLevel = 2, Decimals = 0, Unit = " critter" },
		},
	},
}

UpgradeConfig.Upgrades = Upgrades

-- Daftar Id terurut sesuai Order (untuk UI)
local order: { string } = {}
for id in Upgrades do
	table.insert(order, id)
end
table.sort(order, function(a, b)
	return Upgrades[a].Order < Upgrades[b].Order
end)
UpgradeConfig.Order = order

local function roundToSignificant(value: number, digits: number): number
	if value <= 0 then
		return 0
	end
	local magnitude = math.floor(math.log10(value)) + 1
	local step = 10 ^ math.max(magnitude - digits, 0)
	return math.floor(value / step + 0.5) * step
end

function UpgradeConfig.Get(id: string): UpgradeDef?
	return Upgrades[id]
end

-- Harga untuk naik dari currentLevel ke currentLevel + 1. nil jika sudah maksimum / id tidak dikenal.
function UpgradeConfig.GetCost(id: string, currentLevel: number): number?
	local def = Upgrades[id]
	if not def or currentLevel >= def.MaxLevel then
		return nil
	end
	local raw = def.BaseCost * def.CostGrowth ^ (currentLevel - UpgradeConfig.StartLevel)
	return roundToSignificant(raw, UpgradeConfig.CostSignificantDigits)
end

function UpgradeConfig.GetStatValue(stat: StatDef, level: number): number
	local value = stat.Base + stat.PerLevel * (level - UpgradeConfig.StartLevel)
	local minValue = stat.Min
	if minValue then
		value = math.max(value, minValue)
	end
	local maxValue = stat.Max
	if maxValue then
		value = math.min(value, maxValue)
	end
	local factor = 10 ^ stat.Decimals
	return math.floor(value * factor + 0.5) / factor
end

-- Semua stat sebuah upgrade di level tertentu, contoh: { Radius = 9, CaptureTime = 1.4 }
function UpgradeConfig.GetStats(id: string, level: number): { [string]: number }
	local result: { [string]: number } = {}
	local def = Upgrades[id]
	if def then
		for _, stat in def.Stats do
			result[stat.Id] = UpgradeConfig.GetStatValue(stat, level)
		end
	end
	return result
end

function UpgradeConfig.FormatStatValue(stat: StatDef, value: number): string
	return string.format("%." .. stat.Decimals .. "f", value) .. stat.Unit
end

-- Pemeriksaan kewarasan config. Dipanggil server saat boot agar salah ketik langsung ketahuan.
function UpgradeConfig.Validate(): ()
	for id, def in Upgrades do
		assert(def.Id == id, "UpgradeConfig: Id tidak sama dengan key: " .. id)
		assert(def.MaxLevel > UpgradeConfig.StartLevel, "UpgradeConfig: MaxLevel terlalu kecil: " .. id)
		assert(def.BaseCost > 0, "UpgradeConfig: BaseCost harus > 0: " .. id)
		assert(def.CostGrowth > 1, "UpgradeConfig: CostGrowth harus > 1: " .. id)
		assert(#def.Stats > 0, "UpgradeConfig: upgrade tanpa stat: " .. id)

		local previous = 0
		for level = UpgradeConfig.StartLevel, def.MaxLevel - 1 do
			local cost = UpgradeConfig.GetCost(id, level)
			assert(cost and cost > previous, string.format("UpgradeConfig: harga %s level %d tidak naik", id, level))
			previous = cost
		end
	end
end

return UpgradeConfig
