--!strict
--[[
	EffectsController
	-----------------
	Efek visual LOKAL (hanya terlihat oleh pemain ini, tidak memengaruhi gameplay):
	  • Animasi jaring saat menangkap critter
	  • Ledakan partikel saat berhasil (lebih meriah untuk shiny)
	  • Teks melayang ("+1 Kelinci Awan", "+120 ✨", dll.)
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local EffectsController = {}

local FONT = Enum.Font.FredokaOne
local NET_COLOR = Color3.fromRGB(255, 255, 255)
local SHINY_COLOR = Color3.fromRGB(255, 215, 70)
local FAIL_COLOR = Color3.fromRGB(235, 90, 90)

local effectsFolder: Folder

local function makeAnchoredPart(name: string, position: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = effectsFolder
	return part
end

-- Teks melayang yang naik lalu memudar
function EffectsController.FloatText(position: Vector3, text: string, color: Color3?, big: boolean?): ()
	local anchor = makeAnchoredPart("FloatText", position)

	local billboard = Instance.new("BillboardGui")
	billboard.Size = if big then UDim2.fromOffset(320, 80) else UDim2.fromOffset(240, 54)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Font = FONT
	label.Parent = billboard

	local duration = if big then 1.8 else 1.2
	TweenService:Create(anchor, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = anchor.CFrame + Vector3.new(0, 5, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(duration * 0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, duration * 0.5), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()

	Debris:AddItem(anchor, duration + 0.1)
end

-- Ledakan bintang di posisi tertentu
function EffectsController.Burst(position: Vector3, color: Color3, amount: number): ()
	local anchor = makeAnchoredPart("Burst", position)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.5, 0.9)
	emitter.Speed = NumberRange.new(8, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(amount)
	Debris:AddItem(anchor, 1.5)
end

-- Animasi jaring: bola jaring transparan yang mengecil mengurung critter selama `duration` detik.
-- Mengembalikan fungsi untuk menghentikan animasi (dipanggil saat server menjawab).
function EffectsController.PlayCatchStart(target: BasePart, duration: number): () -> ()
	local startSize = target.Size.X * 3
	local endSize = target.Size.X * 1.25

	local net = Instance.new("Part")
	net.Name = "CatchNet"
	net.Shape = Enum.PartType.Ball
	net.Anchored = true
	net.CanCollide = false
	net.CanTouch = false
	net.CanQuery = false
	net.CastShadow = false
	net.Material = Enum.Material.ForceField
	net.Color = NET_COLOR
	net.Transparency = 0
	net.Size = Vector3.one * startSize
	net.CFrame = target.CFrame
	net.Parent = effectsFolder

	local sizeTween = TweenService:Create(net, TweenInfo.new(math.max(duration, 0.1), Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		Size = Vector3.one * endSize,
	})
	sizeTween:Play()

	-- Ikuti posisi critter (bisa masih bergeser sedikit sebelum server menghentikannya)
	local spin = 0
	local connection = RunService.RenderStepped:Connect(function(dt: number)
		spin += dt * 4
		if target.Parent then
			net.CFrame = CFrame.new(target.Position) * CFrame.Angles(0, spin, 0)
		end
	end)

	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		connection:Disconnect()
		sizeTween:Cancel()
		net:Destroy()
	end
end

function EffectsController.PlayCatchSuccess(position: Vector3, text: string, rarityColor: Color3, shiny: boolean): ()
	if shiny then
		EffectsController.Burst(position, SHINY_COLOR, 60)
		EffectsController.Burst(position, rarityColor, 30)
		EffectsController.FloatText(position + Vector3.new(0, 2, 0), text, SHINY_COLOR, true)
	else
		EffectsController.Burst(position, rarityColor, 25)
		EffectsController.FloatText(position + Vector3.new(0, 2, 0), text, rarityColor, false)
	end
end

function EffectsController.PlayCatchFail(position: Vector3, text: string): ()
	EffectsController.FloatText(position + Vector3.new(0, 2, 0), text, FAIL_COLOR, false)
end

function EffectsController.Init(): ()
	local folder = Instance.new("Folder")
	folder.Name = "LocalEffects"
	-- Instance yang dibuat client hanya ada di client ini
	folder.Parent = Workspace
	effectsFolder = folder
end

function EffectsController.Start(): () end

return EffectsController
