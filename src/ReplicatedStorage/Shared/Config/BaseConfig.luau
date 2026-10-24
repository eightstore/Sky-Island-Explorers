--!strict
--[[
	BaseConfig
	----------
	Angka markas & essence pasif.
	Jumlah slot markas berasal dari upgrade "Base" (UpgradeConfig, stat Slots).
	Essence pasif per critter berasal dari CritterConfig.PassivePerMinute (shiny x ValueMultiplier).

	Essence pasif dihitung di server berdasarkan waktu nyata sejak perhitungan terakhir:
		essence = totalPerMenit * detikBerlalu / 60
	Saat pemain kembali, waktu offline dibatasi MaxOfflineSeconds (8 jam).
]]

local BaseConfig = {
	Tag = "PlayerBase", -- tag Part/Model markas
	PromptName = "PlayerBasePrompt",
	PromptDistance = 12,
	InteractDistance = 24, -- jarak maksimum yang diterima server
	ClientAutoCloseDistance = 22,
	ActionCooldown = 0.25, -- jeda minimum Taruh/Ambil (detik)

	PassiveTickInterval = 60, -- server menghitung essence pasif tiap 60 detik
	MaxOfflineSeconds = 8 * 60 * 60, -- batas offline earnings: 8 jam
	OfflineMultiplier = 1, -- 1 = offline sama cepatnya dengan online
	MinOfflineReportSeconds = 60, -- di bawah ini tidak ditampilkan pesan "selamat datang kembali"

	-- Tampilan critter markas (lokal di client)
	DisplayOrbitRadius = 9,
	DisplayHeight = 4,
	DisplayOrbitSpeed = 0.35, -- radian per detik
}

return table.freeze(BaseConfig)
