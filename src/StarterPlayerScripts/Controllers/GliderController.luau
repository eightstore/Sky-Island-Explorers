--!strict
--[[
	GliderController
	----------------
	Melayang dengan glider:
	  • PC      : lompat (Spasi), lalu TAHAN Spasi saat di udara
	  • Gamepad : lompat (A), lalu TAHAN A saat di udara
	  • HP      : lompat, lalu TAHAN tombol 🪂 di layar (muncul saat di udara)

	Fisika: LinearVelocity pada HumanoidRootPart (karakter dikendalikan client lewat network
	ownership, jadi gerakannya mulus). Kecepatan & jarak maksimum diambil dari stat upgrade Glider.
	Arah mengikuti joystick/WASD; tanpa input, glider meluncur lurus ke depan sambil turun pelan.

	Server (GliderService) tetap mengawasi kecepatan, jadi mengubah angka di client tidak berguna.
	Status melayang dikirim ke server (remote GliderState) dan direplikasi lewat atribut karakter
	"Gliding" agar semua pemain melihat sayap glider.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage.Shared.Net)
local GliderConfig = require(ReplicatedStorage.Shared.Config.GliderConfig)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)
local EffectsController = require(script.Parent.EffectsController)

local THEME = UIKit.THEME
local make = UIKit.Make

local localPlayer = Players.LocalPlayer

local GliderController = {}

local GLIDE_ACTION_NAME = "SkyIsland_Glide"
local GLIDING_ATTRIBUTE = "Gliding"
local MOVER_NAME = "GliderVelocity"
local ATTACHMENT_NAME = "GliderAttachment"
local WINGS_NAME = "GliderWings"
local STATE_SEND_INTERVAL = 0.15 -- sedikit di atas cooldown server (0,1 dtk)
local WING_COLOR = Color3.fromRGB(120, 200, 255)

-- Status input & glide
local keyHolding = false
local touchHolding = false
local gliding = false
local exhausted = false -- jarak glide habis untuk sesi udara ini
local glideDistance = 0
local airStart: number? = nil
local lastPosition: Vector3? = nil
local mover: LinearVelocity? = nil

-- Pengiriman status ke server (dibatasi frekuensinya)
local stateRemote: RemoteEvent? = nil
local desiredState = false
local sentState = false
local lastSentAt = 0
local sendScheduled = false

-- UI
local mobileButton: TextButton? = nil
local meterFrame: Frame? = nil
local meterFill: Frame? = nil

---------------------------------------------------------------------
-- Visual sayap (untuk semua karakter)
---------------------------------------------------------------------

local function setWings(character: Model, visible: boolean): ()
	local existing = character:FindFirstChild(WINGS_NAME)
	if not visible then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local wings = Instance.new("Part")
	wings.Name = WINGS_NAME
	wings.Size = Vector3.new(8, 0.3, 2.6)
	wings.Color = WING_COLOR
	wings.Material = Enum.Material.SmoothPlastic
	wings.CanCollide = false
	wings.CanQuery = false
	wings.CanTouch = false
	wings.Massless = true
	wings.CastShadow = false
	wings.CFrame = root.CFrame * CFrame.new(0, 2.6, 0.3)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = wings
	weld.Parent = wings
	wings.Parent = character
end

local function watchCharacter(character: Model): ()
	local function update()
		setWings(character, character:GetAttribute(GLIDING_ATTRIBUTE) == true)
	end
	character:GetAttributeChangedSignal(GLIDING_ATTRIBUTE):Connect(update)
	update()
end

local function watchPlayer(player: Player): ()
	if player == localPlayer then
		return -- sayap pemain sendiri diatur langsung (tanpa menunggu server)
	end
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

---------------------------------------------------------------------
-- Kirim status ke server
---------------------------------------------------------------------

local function flushState(): ()
	local remote = stateRemote
	if remote and desiredState ~= sentState then
		sentState = desiredState
		lastSentAt = os.clock()
		remote:FireServer(desiredState)
	end
end

local function sendState(value: boolean): ()
	desiredState = value
	if sendScheduled then
		return
	end
	local waitTime = STATE_SEND_INTERVAL - (os.clock() - lastSentAt)
	if waitTime > 0 then
		sendScheduled = true
		task.delay(waitTime, function()
			sendScheduled = false
			flushState()
		end)
	else
		flushState()
	end
end

---------------------------------------------------------------------
-- Fisika glide
---------------------------------------------------------------------

local function getMover(root: BasePart): LinearVelocity
	local current = mover
	if current and current.Parent == root then
		return current
	end
	local attachment = root:FindFirstChild(ATTACHMENT_NAME)
	if not attachment then
		local newAttachment = Instance.new("Attachment")
		newAttachment.Name = ATTACHMENT_NAME
		newAttachment.Parent = root
		attachment = newAttachment
	end

	local linear = Instance.new("LinearVelocity")
	linear.Name = MOVER_NAME
	linear.Attachment0 = attachment :: Attachment
	linear.RelativeTo = Enum.ActuatorRelativeTo.World
	linear.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linear.MaxForce = root.AssemblyMass * GliderConfig.ForcePerMass
	linear.Enabled = false
	linear.Parent = root
	mover = linear
	return linear
end

local function updateMeter(): ()
	local frame = meterFrame
	local fill = meterFill
	if not frame or not fill then
		return
	end
	frame.Visible = gliding
	if gliding then
		local maxDistance = math.max(StateController.GetUpgradeStat("Glider", "MaxDistance"), 1)
		local remaining = math.clamp(1 - glideDistance / maxDistance, 0, 1)
		fill.Size = UDim2.fromScale(remaining, 1)
	end
end

local function startGlide(root: BasePart): ()
	gliding = true
	lastPosition = root.Position
	local linear = getMover(root)
	linear.MaxForce = root.AssemblyMass * GliderConfig.ForcePerMass
	linear.Enabled = true
	local character = localPlayer.Character
	if character then
		setWings(character, true)
	end
	sendState(true)
	updateMeter()
end

local function stopGlide(): ()
	if not gliding then
		return
	end
	gliding = false
	lastPosition = nil
	local linear = mover
	if linear then
		linear.Enabled = false
	end
	local character = localPlayer.Character
	if character then
		setWings(character, false)
	end
	sendState(false)
	updateMeter()
end

local function onHeartbeat(): ()
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		stopGlide()
		return
	end

	local humanoidState = humanoid:GetState()
	local airborne = humanoid.FloorMaterial == Enum.Material.Air
		and humanoidState ~= Enum.HumanoidStateType.Swimming
		and humanoidState ~= Enum.HumanoidStateType.Seated
		and humanoidState ~= Enum.HumanoidStateType.Climbing

	-- Tombol HP hanya muncul saat di udara
	local button = mobileButton
	if button then
		button.Visible = UserInputService.TouchEnabled and airborne and not exhausted
	end

	if not airborne then
		airStart = nil
		exhausted = false
		glideDistance = 0
		stopGlide()
		return
	end

	local now = os.clock()
	local startedAt = airStart or now
	airStart = startedAt

	local wantGlide = (keyHolding or touchHolding) and not exhausted and now - startedAt >= GliderConfig.MinAirTime
	if wantGlide and not gliding then
		startGlide(root)
	elseif not wantGlide and gliding then
		stopGlide()
	end
	if not gliding then
		return
	end

	-- Jarak glide yang sudah ditempuh (horizontal)
	local position = root.Position
	local previous = lastPosition
	if previous then
		glideDistance += Vector3.new(position.X - previous.X, 0, position.Z - previous.Z).Magnitude
	end
	lastPosition = position

	local maxDistance = StateController.GetUpgradeStat("Glider", "MaxDistance")
	if glideDistance >= maxDistance then
		exhausted = true
		stopGlide()
		EffectsController.FloatText(position + Vector3.new(0, 4, 0), "Glider lelah! 🪂", THEME.Gold, false)
		return
	end

	-- Arah: input gerak pemain, atau lurus ke depan jika tidak ada input
	local direction = humanoid.MoveDirection
	direction = Vector3.new(direction.X, 0, direction.Z)
	if direction.Magnitude < 0.1 then
		local look = root.CFrame.LookVector
		direction = Vector3.new(look.X, 0, look.Z)
	end
	if direction.Magnitude > 0 then
		direction = direction.Unit
	end

	local speed = StateController.GetUpgradeStat("Glider", "Speed")
	local linear = mover
	if linear then
		linear.VectorVelocity = direction * speed + Vector3.new(0, -GliderConfig.DescentSpeed, 0)
	end
	updateMeter()
end

---------------------------------------------------------------------
-- Input
---------------------------------------------------------------------

local function onGlideAction(_name: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		keyHolding = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		keyHolding = false
	end
	-- Pass: tombol tetap diteruskan ke sistem lompat bawaan Roblox
	return Enum.ContextActionResult.Pass
end

local function buildUi(): ()
	local gui = UIController.GetGui()

	-- Tombol 🪂 untuk HP (kanan tengah, jauh dari tombol lompat bawaan)
	local button = UIKit.BigButton({
		Name = "GlideButton",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -24, 0.55, 0),
		Size = UDim2.fromOffset(120, 120),
		Color = THEME.HudBackground,
		Text = "🪂\nTahan",
		TextSize = 26,
		Radius = 60,
		Parent = gui,
	})
	button.Visible = false
	UIKit.Stroke(button, THEME.PanelStroke, 4)
	button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHolding = true
		end
	end)
	button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHolding = false
		end
	end)
	mobileButton = button

	-- Meteran sisa jarak glide (bawah tengah, di atas toast)
	local frame: Frame = make("Frame", {
		Name = "GlideMeter",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -100),
		Size = UDim2.fromOffset(320, 26),
		BackgroundColor3 = THEME.HudBackground,
		BackgroundTransparency = 0.2,
		Visible = false,
		Parent = gui,
	})
	UIKit.Corner(frame, 13)
	UIKit.Stroke(frame, THEME.PanelStroke, 2)
	local fill: Frame = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WING_COLOR,
		Parent = frame,
	})
	UIKit.Corner(fill, 13)
	make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "🪂",
		TextScaled = true,
		Font = THEME.Font,
		ZIndex = 2,
		Parent = frame,
	})
	meterFrame = frame
	meterFill = fill
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function GliderController.Init(): ()
	stateRemote = Net.Event(Net.Events.GliderState)
	buildUi()

	ContextActionService:BindAction(GLIDE_ACTION_NAME, onGlideAction, false, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	UserInputService.WindowFocusReleased:Connect(function()
		keyHolding = false
		touchHolding = false
	end)

	localPlayer.CharacterAdded:Connect(function()
		-- Karakter baru: mover lama ikut terhapus bersama karakter lama
		mover = nil
		gliding = false
		exhausted = false
		glideDistance = 0
		airStart = nil
		sendState(false)
		updateMeter()
	end)

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
end

function GliderController.Start(): ()
	RunService.Heartbeat:Connect(onHeartbeat)
end

return GliderController
