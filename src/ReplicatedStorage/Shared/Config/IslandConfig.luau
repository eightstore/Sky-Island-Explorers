--!strict
--[[
	IslandConfig
	------------
	Daftar pulau berurutan dari terendah ke tertinggi.
	Tahap 1 hanya memakai Id, DisplayName, Order, dan DefaultUnlocked (untuk data awal & leaderstats).
	Harga buka pulau, bioma, dan titik spawn akan ditambahkan di tahap berikutnya.
]]

export type IslandDef = {
	Id: string,
	DisplayName: string,
	Order: number, -- 1 = paling rendah
	DefaultUnlocked: boolean,
}

local Islands: { IslandDef } = {
	{ Id = "Meadow", DisplayName = "Padang Awan", Order = 1, DefaultUnlocked = true },
	{ Id = "Crystal", DisplayName = "Gua Kristal", Order = 2, DefaultUnlocked = false },
	{ Id = "Storm", DisplayName = "Puncak Badai", Order = 3, DefaultUnlocked = false },
	{ Id = "Aurora", DisplayName = "Taman Aurora", Order = 4, DefaultUnlocked = false },
	{ Id = "Starfall", DisplayName = "Mahkota Bintang", Order = 5, DefaultUnlocked = false },
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

function IslandConfig.Get(id: string): IslandDef?
	return byId[id]
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
