--!strict
--[[
	IslandController
	----------------
	Mengatur tampilan gerbang pulau SECARA LOKAL untuk pemain ini:
	  • Pulau terkunci  : gerbang padat, papan "🔒 Nama Pulau · harga · syarat glider", prompt aktif
	  • Pulau terbuka   : gerbang tembus & transparan, papan "✔", prompt dimatikan

	Ini hanya tampilan/fisika lokal. Penjagaan sebenarnya ada di server: critter di pulau yang
	belum terbuka tidak bisa ditangkap (CritterService), jadi menembus gerbang tidak berguna.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local StateController = require(script.Parent.StateController)
local EffectsController = require(script.Parent.EffectsController)

local IslandController = {}

type PartOriginal = { Transparency: number, CanCollide: boolean }

local BILLBOARD_NAME = "GateSign"
local UNLOCKED_TRANSPARENCY = 1

-- Nilai asli tiap Part gerbang, supaya bisa dikembalikan (kunci lemah agar tidak bocor memori)
local originals: { [BasePart]: PartOriginal } = setmetatable({}, { __mode = "k" }) :: any
local watchedGates: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function getIsland(gate: Instance): IslandConfig.IslandDef?
	local islandId = gate:GetAttribute(IslandConfig.Gate.IdAttribute)
	if typeof(islandId) ~= "string" then
		return nil
	end
	return IslandConfig.Get(islandId)
end

local function getGateParts(gate: Instance): { BasePart }
	local parts: { BasePart } = {}
	if gate:IsA("BasePart") then
		table.insert(parts, gate)
	end
	for _, descendant in gate:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getSignHost(gate: Instance): BasePart?
	if gate:IsA("BasePart") then
		return gate
	elseif gate:IsA("Model") then
		local primary = gate.PrimaryPart
		if primary then
			return primary
		end
		local found = gate:FindFirstChildWhichIsA("BasePart", true)
		if found and found:IsA("BasePart") then
			return found
		end
	end
	return nil
end

local function ensureSign(gate: Instance, island: IslandConfig.IslandDef): TextLabel?
	local host = getSignHost(gate)
	if not host then
		return nil
	end
	local billboard = host:FindFirstChild(BILLBOARD_NAME)
	if not billboard then
		local newBillboard = Instance.new("BillboardGui")
		newBillboard.Name = BILLBOARD_NAME
		newBillboard.Size = UDim2.fromOffset(320, 110)
		newBillboard.StudsOffset = Vector3.new(0, host.Size.Y / 2 + 3, 0)
		newBillboard.MaxDistance = 120
		newBillboard.LightInfluence = 0
		newBillboard.Parent = host

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = island.Color
		frame.BackgroundTransparency = 0.15
		frame.Parent = newBillboard
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 16)
		corner.Parent = frame

		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.new(1, -16, 1, -12)
		label.Position = UDim2.fromOffset(8, 6)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.3
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.Parent = frame
		billboard = newBillboard
	end
	local label = billboard and billboard:FindFirstChild("Text", true)
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

local function applyGate(gate: Instance): ()
	local island = getIsland(gate)
	if not island then
		return
	end
	local unlocked = island.DefaultUnlocked or StateController.IsIslandUnlocked(island.Id)

	for _, part in getGateParts(gate) do
		local original = originals[part]
		if not original then
			original = { Transparency = part.Transparency, CanCollide = part.CanCollide }
			originals[part] = original
		end
		if unlocked then
			part.Transparency = UNLOCKED_TRANSPARENCY
			part.CanCollide = false
		else
			part.Transparency = original.Transparency
			part.CanCollide = original.CanCollide
		end
	end

	for _, descendant in gate:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant.Name == IslandConfig.Gate.PromptName then
			descendant.Enabled = not unlocked
		end
	end

	local sign = ensureSign(gate, island)
	if sign then
		if unlocked then
			sign.Text = "✔ " .. island.DisplayName
		else
			sign.Text = string.format("🔒 %s\n%s ✨ · Glider Lv %d", island.DisplayName, NumberFormat.Abbreviate(island.UnlockCost), island.RequiredGliderLevel)
		end
	end
end

local function applyAll(): ()
	for _, gate in CollectionService:GetTagged(IslandConfig.Gate.Tag) do
		applyGate(gate)
	end
end

local function watchGate(gate: Instance): ()
	if watchedGates[gate] then
		return
	end
	watchedGates[gate] = true
	-- Prompt dari server bisa tiba setelah gerbang diproses, jadi terapkan ulang saat ada isi baru
	gate.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") or descendant:IsA("BasePart") then
			applyGate(gate)
		end
	end)
	applyGate(gate)
end

local function playUnlockEffect(islandId: string): ()
	for _, gate in CollectionService:GetTagged(IslandConfig.Gate.Tag) do
		local island = getIsland(gate)
		local host = getSignHost(gate)
		if island and host and island.Id == islandId then
			EffectsController.Burst(host.Position, island.Color, 60)
			EffectsController.FloatText(host.Position + Vector3.new(0, 4, 0), "🎉 " .. island.DisplayName .. " terbuka!", island.Color, true)
		end
	end
end

function IslandController.Init(): ()
	for _, gate in CollectionService:GetTagged(IslandConfig.Gate.Tag) do
		watchGate(gate)
	end
	CollectionService:GetInstanceAddedSignal(IslandConfig.Gate.Tag):Connect(watchGate)

	StateController.Changed:Connect(function(key: string, islandId: any)
		if key == "Islands" or key == "Loaded" then
			applyAll()
			-- Efek hanya untuk pulau yang baru dibuka (bukan dari snapshot awal)
			if key == "Islands" and StateController.IsLoaded() and typeof(islandId) == "string" then
				playUnlockEffect(islandId)
			end
		end
	end)
end

function IslandController.Start(): () end

return IslandController
