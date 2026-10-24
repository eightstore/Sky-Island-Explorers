--!strict
--[[
	ClientMain (LocalScript)
	------------------------
	Titik masuk client. Menunggu game selesai dimuat (agar ReplicatedStorage sudah tereplikasi),
	lalu menjalankan Init & Start setiap controller.
	Controller lain (Input, Glider, Effects) akan ditambahkan di tahap berikutnya.
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- Folder Controllers disalin bersama script ini ke PlayerScripts, jadi path statis aman
local Controllers = script.Parent.Controllers

type Controller = {
	Init: () -> (),
	Start: () -> (),
}

local orderedControllers: { Controller } = {
	require(Controllers.UIController),
}

for _, controller in orderedControllers do
	controller.Init()
end

for _, controller in orderedControllers do
	task.spawn(controller.Start)
end
