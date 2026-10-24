--!strict
--[[
	InputController
	---------------
	Input menangkap critter. Kontrol dibuat sesederhana mungkin:
	  • PC     : klik critter
	  • HP     : tap critter (tap yang sedikit meleset tetap kena critter terdekat di layar)
	  • Gamepad: tombol R2 menangkap critter terdekat dalam radius jaring

	Alur:
	  1. Cek ramah di client (tas penuh? terlalu jauh? pulau terkunci?) -> tampilkan pesan, tanpa remote.
	  2. Putar animasi jaring, panggil remote CatchCritter (server menunggu CaptureTime lalu memvalidasi).
	  3. Tampilkan hasil: efek sukses / shiny / gagal.
	Semua keputusan akhir tetap di server.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)
local EffectsController = require(script.Parent.EffectsController)

local localPlayer = Players.LocalPlayer

local InputController = {}

local CATCH_ACTION_NAME = "SkyIsland_Catch"
local RAY_LENGTH = 1000
local FAIL_COLOR = Color3.fromRGB(235, 90, 90)

local catchRemote: RemoteFunction? = nil
local catching = false

---------------------------------------------------------------------
-- Pencarian target
---------------------------------------------------------------------

local function getRootPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function isCritter(instance: Instance): boolean
	return instance:IsA("BasePart") and instance:HasTag(CritterConfig.Tags.Critter)
end

-- Critter yang diklik/di-tap pada posisi layar tertentu
local function findCritterAtScreen(screenPosition: Vector2): BasePart?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	-- 1. Raycast langsung, hanya mengenai critter
	local critters = CollectionService:GetTagged(CritterConfig.Tags.Critter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = critters
	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
	local result = Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
	if result and isCritter(result.Instance) then
		return result.Instance :: BasePart
	end

	-- 2. Bantuan tap: critter terdekat di layar dalam radius piksel tertentu
	local best: BasePart? = nil
	local bestDistance = CritterConfig.Catch.TapAssistPixels
	for _, instance in critters do
		if instance:IsA("BasePart") then
			local point, onScreen = camera:WorldToViewportPoint(instance.Position)
			if onScreen then
				local distance = (Vector2.new(point.X, point.Y) - screenPosition).Magnitude
				if distance < bestDistance then
					best = instance
					bestDistance = distance
				end
			end
		end
	end
	return best
end

-- Critter terdekat di dunia dalam radius tertentu (untuk gamepad)
local function findNearestCritter(maxDistance: number): BasePart?
	local rootPosition = getRootPosition()
	if not rootPosition then
		return nil
	end
	local best: BasePart? = nil
	local bestDistance = maxDistance
	for _, instance in CollectionService:GetTagged(CritterConfig.Tags.Critter) do
		if instance:IsA("BasePart") and instance:GetAttribute(CritterConfig.Attributes.BeingCaught) ~= true then
			local distance = (instance.Position - rootPosition).Magnitude
			if distance <= bestDistance then
				best = instance
				bestDistance = distance
			end
		end
	end
	return best
end

---------------------------------------------------------------------
-- Tangkap
---------------------------------------------------------------------

local function attemptCatch(target: BasePart): ()
	local remote = catchRemote
	if not remote or catching or not StateController.IsLoaded() then
		return
	end

	local uid = target:GetAttribute(CritterConfig.Attributes.Uid)
	local islandId = target:GetAttribute(CritterConfig.Attributes.IslandId)
	local critterId = target:GetAttribute(CritterConfig.Attributes.CritterId)
	if typeof(uid) ~= "string" or typeof(islandId) ~= "string" or typeof(critterId) ~= "string" then
		return
	end

	-- Cek ramah di client (server tetap memvalidasi semuanya)
	if target:GetAttribute(CritterConfig.Attributes.BeingCaught) == true then
		UIController.ShowToast("Critter itu sedang ditangkap.", false)
		return
	end
	if not StateController.IsIslandUnlocked(islandId) then
		UIController.ShowToast("Buka pulau ini dulu di gerbangnya.", false)
		return
	end
	if StateController.IsBagFull() then
		UIController.ShowToast("Tas penuh! Setor dulu di markas 🎒", false)
		return
	end
	local rootPosition = getRootPosition()
	local radius = StateController.GetUpgradeStat("Net", "Radius")
	if not rootPosition or (target.Position - rootPosition).Magnitude > radius then
		UIController.ShowToast("Terlalu jauh! Dekati critter-nya.", false)
		return
	end

	catching = true
	local captureTime = StateController.GetUpgradeStat("Net", "CaptureTime")
	local stopAnimation = EffectsController.PlayCatchStart(target, captureTime)
	local lastPosition = target.Position

	local ok, result = pcall(function(): any
		return remote:InvokeServer(uid)
	end)

	if target.Parent then
		lastPosition = target.Position
	end
	stopAnimation()
	catching = false

	if not ok or type(result) ~= "table" or type(result.Message) ~= "string" then
		UIController.ShowToast("Koneksi bermasalah, coba lagi ya.", false)
		return
	end

	if result.Success == true then
		local def = CritterConfig.Get(critterId)
		local rarity = def and CritterConfig.GetRarity(def.Rarity)
		local color = if rarity then rarity.Color else Color3.new(1, 1, 1)
		local shiny = result.Shiny == true
		local name = if def then def.DisplayName else critterId
		local text = if shiny then "✨ SHINY " .. name .. "! ✨" else "+1 " .. name
		EffectsController.PlayCatchSuccess(lastPosition, text, color, shiny)
		-- Pesan toast hanya untuk momen spesial agar layar tidak ramai
		if shiny or result.IsNew == true then
			UIController.ShowToast(result.Message, true)
		end
		if result.BagFull == true then
			UIController.ShowToast("Tas penuh! Setor dulu di markas 🎒", false)
		end
	else
		EffectsController.PlayCatchFail(lastPosition, "Lolos!")
		UIController.ShowToast(result.Message, false)
	end
end

---------------------------------------------------------------------
-- Input
---------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean): ()
	-- gameProcessed = true jika input mengenai UI, thumbstick, atau tombol lompat
	if gameProcessed then
		return
	end
	local inputType = input.UserInputType
	if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end
	local target = findCritterAtScreen(Vector2.new(input.Position.X, input.Position.Y))
	if target then
		task.spawn(attemptCatch, target)
	end
end

local function onGamepadCatch(_name: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	local radius = StateController.GetUpgradeStat("Net", "Radius")
	local target = findNearestCritter(radius)
	if target then
		task.spawn(attemptCatch, target)
	else
		local rootPosition = getRootPosition()
		if rootPosition then
			EffectsController.FloatText(rootPosition + Vector3.new(0, 4, 0), "Tidak ada critter di dekatmu", FAIL_COLOR, false)
		end
	end
	return Enum.ContextActionResult.Sink
end

function InputController.Init(): ()
	catchRemote = Net.Function(Net.Functions.CatchCritter)
	UserInputService.InputBegan:Connect(onInputBegan)
	ContextActionService:BindAction(CATCH_ACTION_NAME, onGamepadCatch, false, Enum.KeyCode.ButtonR2)
end

function InputController.Start(): () end

return InputController
