--!strict
--[[
	Main (Script server)
	--------------------
	Titik masuk server. Urutan:
	  1. Buat semua Remote (Net.Setup)
	  2. Init semua service (siapkan state & sambungkan Signal antar-service, belum memproses pemain)
	  3. Start semua service (mulai menerima pemain, remote, loop)
	Urutan service penting: DataService harus pertama karena service lain bergantung padanya.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ReplicatedStorage.Shared.Net)
Net.Setup()

local Services = ServerScriptService.Services

type Service = {
	Init: () -> (),
	Start: () -> (),
}

local orderedServices: { { Name: string, Module: Service } } = {
	{ Name = "DataService", Module = require(Services.DataService) },
	{ Name = "EconomyService", Module = require(Services.EconomyService) },
	{ Name = "LeaderboardService", Module = require(Services.LeaderboardService) },
}

for _, entry in orderedServices do
	local startTime = os.clock()
	entry.Module.Init()
	print(string.format("[Main] %s Init (%.0f ms)", entry.Name, (os.clock() - startTime) * 1000))
end

for _, entry in orderedServices do
	entry.Module.Start()
end

print("[Main] Sky Island Explorers server siap ☁️")
