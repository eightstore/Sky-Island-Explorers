--!strict
--[[
	Types
	-----
	Definisi tipe yang dipakai bersama oleh server dan client.
	Modul ini tidak berisi logika, hanya "kontrak" bentuk data.
]]

-- Level setiap upgrade, contoh: { Net = 3, Glider = 1, Bag = 5 }
export type UpgradeLevels = { [string]: number }

-- Satu critter yang sedang dibawa di tas (belum disetor / ditaruh di markas)
export type BagItem = {
	CritterId: string,
	Shiny: boolean,
	CaughtAt: number, -- os.time() saat ditangkap
}

-- Catatan koleksi per jenis critter (untuk "buku koleksi")
export type CollectionEntry = {
	Caught: number, -- total pernah ditangkap
	Shiny: number, -- total versi shiny yang pernah ditangkap
	FirstCaughtAt: number, -- os.time() pertama kali ditangkap
}

-- Critter yang ditaruh di markas (menghasilkan essence pasif di tahap berikutnya)
export type BaseCritter = {
	CritterId: string,
	Shiny: boolean,
	PlacedAt: number,
}

export type Cosmetics = {
	Owned: { [string]: boolean }, -- CosmeticId -> true
	Equipped: { [string]: string }, -- Slot ("Net", "Glider", "Trail") -> CosmeticId
}

export type PlayerStats = {
	TotalEssenceEarned: number,
	TotalEssenceSpent: number,
	TotalCrittersCaught: number,
	TotalShinyCaught: number,
	HighestIslandOrder: number,
	PlayTimeSeconds: number,
}

-- Struktur data utama yang disimpan di DataStore
export type PlayerData = {
	SchemaVersion: number,
	Essence: number,
	Upgrades: UpgradeLevels,
	Bag: { BagItem },
	Collection: { [string]: CollectionEntry },
	UnlockedIslands: { [string]: boolean },
	BaseCritters: { BaseCritter },
	LoginStreak: number,
	LastLoginDay: number, -- nomor hari UTC (os.time() // 86400), untuk hitung streak
	LastLoginDate: string, -- format "YYYY-MM-DD" (UTC), agar mudah dibaca manusia
	LastLoginTime: number,
	Cosmetics: Cosmetics,
	Stats: PlayerStats,
	FirstJoinTime: number,
	LastPassiveTime: number, -- os.time() terakhir essence pasif markas dihitung
	PassiveRemainder: number, -- sisa pecahan essence pasif (agar 1.5/menit tidak hilang)
	AlbumClaimed: { [string]: boolean }, -- IslandId -> hadiah album sudah diberikan
}

-- Versi ringkas critter (isi tas / markas) yang dikirim ke client
export type CritterView = {
	CritterId: string,
	Shiny: boolean,
}

-- Versi ringkas koleksi untuk client: CritterId -> jumlah
export type CollectionView = { [string]: { Caught: number, Shiny: number } }

-- Laporan essence yang terkumpul saat pemain offline
export type OfflineReport = {
	Amount: number,
	Seconds: number,
}

-- Snapshot awal yang dikirim server ke client
export type ClientSnapshot = {
	Loaded: boolean,
	Essence: number,
	Upgrades: UpgradeLevels,
	Bag: { CritterView },
	BaseCritters: { CritterView },
	Collection: CollectionView,
	AlbumClaimed: { [string]: boolean },
	UnlockedIslands: { [string]: boolean },
	OfflineReport: OfflineReport?,
	Revision: number,
}

-- Hasil umum remote (PlaceCritter, RetrieveCritter, dll.)
export type ActionResult = {
	Success: boolean,
	Message: string,
}

-- Hasil remote PurchaseUpgrade
export type PurchaseResult = {
	Success: boolean,
	Message: string,
	UpgradeId: string?,
	NewLevel: number?,
	Essence: number?,
}

-- Hasil remote CatchCritter
export type CatchResult = {
	Success: boolean,
	Message: string,
	CritterId: string?,
	Shiny: boolean?,
	IsNew: boolean?, -- true jika baru pertama kali ditangkap (masuk buku koleksi)
	BagCount: number?,
	BagFull: boolean?,
}

-- Hasil remote DepositBag
export type DepositResult = {
	Success: boolean,
	Message: string,
	Count: number?,
	Gained: number?,
}

-- Hasil remote UnlockIsland
export type UnlockResult = {
	Success: boolean,
	Message: string,
	IslandId: string?,
}

return {}
