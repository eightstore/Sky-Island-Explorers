--!strict
--[[
	ClientMain (LocalScript)
	------------------------
	Titik masuk client. Menunggu game selesai dimuat (agar ReplicatedStorage sudah tereplikasi),
	lalu menjalankan Init & Start setiap controller.

	Urutan penting:
	  StateController   -> harus pertama (controller lain membaca state darinya)
	  EffectsController -> dipakai UI, Island, Input, Glider, Base, Album
	  UIController      -> menyediakan ScreenGui, toast, jendela, tombol HUD, pengarah prompt
	  IslandController  -> tampilan gerbang pulau
	  InputController   -> klik/tap/gamepad untuk menangkap critter
	  GliderController  -> melayang dengan glider
	  BaseController    -> jendela & tampilan markas
	  AlbumController   -> album koleksi
	  EggController     -> toko telur, inkubator, animasi buka telur
	  StoreController   -> Toko Spesial (gamepass/item, Robux & Essence), teleport, indikator luck
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- Folder Controllers & UI disalin bersama script ini ke PlayerScripts, jadi path statis aman
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
	require(Controllers.GliderController),
	require(Controllers.BaseController),
	require(Controllers.AlbumController),
	require(Controllers.EggController),
	require(Controllers.StoreController),
}

for _, controller in orderedControllers do
	controller.Init()
end

for _, controller in orderedControllers do
	task.spawn(controller.Start)
end
