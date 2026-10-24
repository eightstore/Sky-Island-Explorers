--!strict
--[[
	ClientMain (LocalScript)
	------------------------
	Titik masuk client. Menunggu game selesai dimuat (agar ReplicatedStorage sudah tereplikasi),
	lalu menjalankan Init & Start setiap controller.

	Urutan penting:
	  StateController   -> harus pertama (controller lain membaca state darinya)
	  EffectsController -> dipakai UI, Island, dan Input
	  UIController      -> menyediakan toast & jendela
	  IslandController  -> tampilan gerbang pulau
	  InputController   -> klik/tap/gamepad untuk menangkap critter
	GliderController akan ditambahkan di tahap berikutnya.
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
	require(Controllers.StateController),
	require(Controllers.EffectsController),
	require(Controllers.UIController),
	require(Controllers.IslandController),
	require(Controllers.InputController),
}

for _, controller in orderedControllers do
	controller.Init()
end

for _, controller in orderedControllers do
	task.spawn(controller.Start)
end
