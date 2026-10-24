--!strict
--[[
	GliderConfig
	------------
	Angka gerak glider dan batas anti speed-hack.
	Kecepatan & jarak maksimum glider TIDAK di sini, melainkan dari stat upgrade Glider
	(UpgradeConfig: Speed & MaxDistance), supaya naik mengikuti level.

	Cara melayang: lompat, lalu TAHAN tombol lompat (Spasi / A gamepad) saat di udara.
	Di HP: tahan tombol 🪂 di layar saat di udara.
]]

local GliderConfig = {
	DescentSpeed = 8, -- kecepatan turun saat melayang (stud/detik)
	MinAirTime = 0.2, -- detik di udara sebelum glider boleh dibuka (agar lompat biasa tetap terasa)
	ForcePerMass = 2000, -- kekuatan LinearVelocity relatif terhadap massa karakter

	AntiCheat = table.freeze({
		CheckInterval = 0.5, -- server memeriksa posisi tiap 0,5 detik
		SpeedTolerance = 1.35, -- kelonggaran pengali di atas kecepatan yang diizinkan (lag)
		ExtraBuffer = 10, -- kelonggaran tambahan (stud/detik)
		MaxAscendSpeed = 70, -- kecepatan naik maksimum yang wajar (lompat biasa ±50)
		ViolationsToRubberBand = 3, -- pelanggaran beruntun sebelum pemain dikembalikan ke posisi valid
		GlideDistanceTolerance = 1.3, -- kelonggaran jarak glider (pengali MaxDistance)
		GroundCheckDistance = 5, -- raycast ke bawah untuk menentukan "menapak tanah"
		SpawnGrace = 3, -- detik bebas pemeriksaan setelah spawn / teleport
		StateCooldown = 0.1, -- jeda minimum remote GliderState
	}),
}

return table.freeze(GliderConfig)
