--!strict
--[[
	EconomyConfig
	-------------
	Angka dasar ekonomi Cloud Essence. Diubah di sini, bukan di dalam Service.
]]

local EconomyConfig = {
	-- Essence yang dimiliki pemain baru (cukup untuk 1 upgrade pertama agar langsung merasakan progres)
	StartingEssence = 50,

	-- Batas saldo maksimum. Dijaga jauh di bawah 2^53 agar angka tetap presisi.
	MaxEssence = 1e15,

	-- Batas jumlah per satu transaksi (Add/Spend). Nilai di atas ini dianggap bug/exploit dan ditolak.
	MaxTransaction = 1e13,
}

return table.freeze(EconomyConfig)
