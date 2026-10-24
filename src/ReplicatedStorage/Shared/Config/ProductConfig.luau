--!strict
--[[
	ProductConfig
	-------------
	Semua Gamepass & Developer Product, beserta efek dan JALUR GRATIS-nya.

	ATURAN RAMAH ANAK (bukan pay-to-win):
	  • Setiap gamepass punya EssencePrice: bisa dibuka GRATIS dengan essence hasil bermain.
	  • Lucky Potion & Revive Streak juga bisa dibeli dengan essence.
	  • Instant Hatch hanya mempercepat; tanpa membeli, telur tetap menetas setelah waktunya habis.
	  • Essence Pack = essence, yang juga didapat dari bermain biasa.
	  • Tidak ada timer palsu, diskon "terbatas", atau pop-up yang muncul sendiri.

	⚠️ Semua PassId / ProductId di bawah masih 0 = placeholder.
	   ISI DENGAN ID ASLI dari Creator Hub. Selama ID = 0, tombol Robux dinonaktifkan
	   dan server menolak pembelian, tetapi jalur essence tetap berfungsi untuk tes.
]]

export type GamePassDef = {
	Key: string,
	PassId: number,
	DisplayName: string,
	Description: string,
	Icon: string,
	EssencePrice: number, -- jalur gratis
	Order: number,
}

export type ProductDef = {
	Key: string,
	ProductId: number,
	DisplayName: string,
	Description: string,
	Icon: string,
	EssencePrice: number?, -- nil = tidak ada versi essence (lihat komentar di atas)
	EssenceAmount: number?, -- khusus Essence Pack
	Order: number,
}

local ProductConfig = {}

ProductConfig.GamePasses = {
	GliderBoost = {
		Key = "GliderBoost",
		PassId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Glider Cepat",
		Description = "Glider 50% lebih cepat.",
		Icon = "🪂",
		EssencePrice = 150000,
		Order = 1,
	},
	InfiniteBag = {
		Key = "InfiniteBag",
		PassId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Tas Tak Terbatas",
		Description = "Bawa critter sebanyak apa pun sebelum setor.",
		Icon = "🎒",
		EssencePrice = 400000,
		Order = 2,
	},
	AutoCatch = {
		Key = "AutoCatch",
		PassId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Jaring Otomatis",
		Description = "Menangkap critter terdekat secara otomatis tiap beberapa detik.",
		Icon = "🤖",
		EssencePrice = 250000,
		Order = 3,
	},
	IslandTeleport = {
		Key = "IslandTeleport",
		PassId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Teleport Pulau",
		Description = "Pindah langsung ke pulau yang sudah terbuka.",
		Icon = "🌀",
		EssencePrice = 80000,
		Order = 4,
	},
	DoubleLuck = {
		Key = "DoubleLuck",
		PassId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "2x Luck",
		Description = "Peluang Shiny 2x lipat (tangkap & telur).",
		Icon = "🍀",
		EssencePrice = 1000000,
		Order = 5,
	},
} :: { [string]: GamePassDef }

ProductConfig.Products = {
	LuckyPotion = {
		Key = "LuckyPotion",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Ramuan Hoki (15 menit)",
		Description = "Peluang Shiny 2x selama 15 menit. Durasi bertambah jika diminum lagi.",
		Icon = "🧪",
		EssencePrice = 20000,
		Order = 1,
	},
	EssencePackSmall = {
		Key = "EssencePackSmall",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Kantong Essence Kecil",
		Description = "+2.500 Essence.",
		Icon = "✨",
		EssenceAmount = 2500,
		Order = 2,
	},
	EssencePackMedium = {
		Key = "EssencePackMedium",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Kantong Essence Sedang",
		Description = "+15.000 Essence.",
		Icon = "💫",
		EssenceAmount = 15000,
		Order = 3,
	},
	EssencePackLarge = {
		Key = "EssencePackLarge",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Kantong Essence Besar",
		Description = "+100.000 Essence.",
		Icon = "🌟",
		EssenceAmount = 100000,
		Order = 4,
	},
	InstantHatch = {
		Key = "InstantHatch",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Tetas Instan",
		Description = "Telur yang sedang dierami langsung siap dibuka.",
		Icon = "⚡",
		Order = 5,
	},
	ReviveStreak = {
		Key = "ReviveStreak",
		ProductId = 0, -- ISI DENGAN ID ASLI
		DisplayName = "Pulihkan Streak",
		Description = "Kembalikan login streak yang baru saja putus.",
		Icon = "🔥",
		EssencePrice = 2000,
		Order = 6,
	},
} :: { [string]: ProductDef }

-- Angka efek (balancing)
ProductConfig.Effects = table.freeze({
	GliderSpeedMultiplier = 1.5, -- Glider Cepat
	InfiniteBagCapacity = 1000, -- "tak terbatas" dibatasi 1000 agar ukuran data tetap aman
	DoubleLuckMultiplier = 2, -- 2x Luck
	LuckyPotionMultiplier = 2, -- Ramuan Hoki
	LuckyPotionDuration = 15 * 60, -- detik, bertumpuk
	LuckyPotionMaxStack = 4 * 60 * 60, -- durasi maksimum yang bisa ditumpuk (4 jam)
	AutoCatchInterval = 3, -- detik antar tangkapan otomatis
	TeleportCooldown = 10, -- detik
	ReviveWindowDays = 2, -- streak yang putus bisa dipulihkan dalam 2 hari
	MaxStoredReceipts = 200, -- PurchaseId yang disimpan untuk idempotensi
	ReceiptProfileWait = 10, -- detik menunggu data pemain di ProcessReceipt
	PassCheckRetries = 3,
})

ProductConfig.Shop = table.freeze({
	TeleportSpawnTag = "IslandSpawn", -- Part tujuan teleport, atribut IslandId
	PurchaseCooldown = 1, -- jeda minimum permintaan pembelian (detik)
})

-- Atribut pemain yang diisi server (direplikasi ke client untuk UI)
ProductConfig.Attributes = table.freeze({
	PerkPrefix = "Perk_", -- Perk_GliderBoost = true, dst.
	LuckBoostEndsAt = "LuckBoostEndsAt",
	LoginStreak = "LoginStreak",
	RevivableStreak = "RevivableStreak", -- 0 = tidak ada streak yang bisa dipulihkan
	IncubatorEggId = "IncubatorEggId",
	IncubatorReadyAt = "IncubatorReadyAt",
})

local passByIdMap: { [number]: GamePassDef } = {}
for _, pass in ProductConfig.GamePasses do
	if pass.PassId ~= 0 then
		passByIdMap[pass.PassId] = pass
	end
end

local productByIdMap: { [number]: ProductDef } = {}
for _, product in ProductConfig.Products do
	if product.ProductId ~= 0 then
		productByIdMap[product.ProductId] = product
	end
end

function ProductConfig.GetPassById(passId: number): GamePassDef?
	return passByIdMap[passId]
end

function ProductConfig.GetProductById(productId: number): ProductDef?
	return productByIdMap[productId]
end

local function sortedKeys(map: { [string]: { Order: number } }): { string }
	local keys: { string } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return map[a].Order < map[b].Order
	end)
	return keys
end

ProductConfig.PassOrder = sortedKeys(ProductConfig.GamePasses :: any)
ProductConfig.ProductOrder = sortedKeys(ProductConfig.Products :: any)

function ProductConfig.Validate(): ()
	local seen: { [number]: string } = {}
	for key, pass in ProductConfig.GamePasses do
		assert(pass.Key == key, "ProductConfig: Key pass tidak cocok: " .. key)
		assert(pass.EssencePrice > 0, "ProductConfig: gamepass wajib punya jalur gratis (EssencePrice): " .. key)
		if pass.PassId ~= 0 then
			assert(seen[pass.PassId] == nil, "ProductConfig: PassId duplikat " .. pass.PassId)
			seen[pass.PassId] = key
		else
			warn("[ProductConfig] PassId " .. key .. " masih 0 (ISI DENGAN ID ASLI)")
		end
	end
	for key, product in ProductConfig.Products do
		assert(product.Key == key, "ProductConfig: Key produk tidak cocok: " .. key)
		if product.ProductId == 0 then
			warn("[ProductConfig] ProductId " .. key .. " masih 0 (ISI DENGAN ID ASLI)")
		end
	end
end

return ProductConfig
