--!strict
--[[
	BaseController
	--------------
	Markas pemain di sisi client:
	  • Jendela Markas (dibuka lewat ProximityPrompt di objek ber-tag PlayerBase):
	    kolom kiri = critter di markas (tombol "Ambil"), kolom kanan = isi tas (tombol "Taruh").
	  • Tampilan lokal: critter markas milik pemain ini melayang mengelilingi markas.
	  • Pesan "selamat datang kembali" berisi essence yang terkumpul saat offline.
	  • Teks "+X ✨" kecil setiap kali essence pasif masuk.

	Semua perhitungan essence pasif dilakukan server (BaseService). Angka "/menit" di UI hanya perkiraan.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local BaseConfig = require(ReplicatedStorage.Shared.Config.BaseConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)
local EffectsController = require(script.Parent.EffectsController)

type CritterView = Types.CritterView

local THEME = UIKit.THEME
local make = UIKit.Make

local BaseController = {}

local ROW_HEIGHT = 76

type Refs = {
	Frame: Frame,
	Pop: UIScale,
	Summary: TextLabel,
	BaseList: ScrollingFrame,
	BagList: ScrollingFrame,
}

local refs: Refs? = nil
local pending = false
local placeRemote: RemoteFunction? = nil
local retrieveRemote: RemoteFunction? = nil

-- Tampilan lokal critter markas
local displayFolder: Folder? = nil
local displayParts: { BasePart } = {}
local orbitAngle = 0

---------------------------------------------------------------------
-- Helper
---------------------------------------------------------------------

local function formatDuration(seconds: number): string
	local hours = seconds // 3600
	local minutes = (seconds % 3600) // 60
	if hours > 0 then
		return string.format("%dj %dm", hours, minutes)
	end
	return string.format("%dm", math.max(minutes, 1))
end

local function getBasePosition(): Vector3?
	for _, instance in CollectionService:GetTagged(BaseConfig.Tag) do
		if instance:IsA("BasePart") then
			return instance.Position
		elseif instance:IsA("Model") then
			return instance:GetPivot().Position
		end
	end
	return nil
end

local function critterName(item: CritterView): string
	local def = CritterConfig.Get(item.CritterId)
	local name = if def then def.DisplayName else item.CritterId
	return if item.Shiny then "✨ " .. name else name
end

---------------------------------------------------------------------
-- Aksi
---------------------------------------------------------------------

local function invoke(remote: RemoteFunction?, index: number, critterId: string): ()
	if not remote or pending then
		return
	end
	pending = true
	local ok, result = pcall(function(): any
		return remote:InvokeServer(index, critterId)
	end)
	pending = false
	if ok and type(result) == "table" and type(result.Message) == "string" then
		UIController.ShowToast(result.Message, result.Success == true)
	else
		UIController.ShowToast("Koneksi bermasalah, coba lagi ya.", false)
	end
end

local function place(index: number, item: CritterView): ()
	if #StateController.GetBaseCritters() >= StateController.GetBaseSlots() then
		UIController.ShowToast("Markas penuh! Tambah slot lewat upgrade Markas di toko.", false)
		return
	end
	invoke(placeRemote, index, item.CritterId)
end

local function retrieve(index: number, item: CritterView): ()
	if StateController.IsBagFull() then
		UIController.ShowToast("Tas penuh! Setor dulu sebelum mengambil critter.", false)
		return
	end
	invoke(retrieveRemote, index, item.CritterId)
end

---------------------------------------------------------------------
-- Render jendela
---------------------------------------------------------------------

local function makeRow(parent: Instance, order: number, item: CritterView?, subtitle: string, buttonText: string?, buttonColor: Color3?, onPress: (() -> ())?): TextButton?
	local row: Frame = make("Frame", {
		Name = "Row" .. order,
		Size = UDim2.new(1, -12, 0, ROW_HEIGHT),
		BackgroundColor3 = THEME.Card,
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(row, 16)
	UIKit.Stroke(row, THEME.PanelStroke, 2)

	local def = item and CritterConfig.Get(item.CritterId)
	local rarity = def and CritterConfig.GetRarity(def.Rarity)

	local dot: Frame = make("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(50, 50),
		BackgroundColor3 = if def then def.Color else THEME.Locked,
		Parent = row,
	})
	UIKit.Corner(dot, 25)
	UIKit.Stroke(dot, if rarity then rarity.Color else THEME.PanelStroke, 3)

	make("TextLabel", {
		Name = "Name",
		Position = UDim2.fromOffset(74, 8),
		Size = UDim2.new(1, -200, 0, 32),
		BackgroundTransparency = 1,
		Text = if item then critterName(item) else "Slot kosong",
		TextColor3 = if item then THEME.Text else THEME.TextMuted,
		TextSize = 24,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	make("TextLabel", {
		Name = "Sub",
		Position = UDim2.fromOffset(74, 40),
		Size = UDim2.new(1, -200, 0, 26),
		BackgroundTransparency = 1,
		Text = subtitle,
		RichText = true,
		TextColor3 = THEME.TextMuted,
		TextSize = 18,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})

	if buttonText and onPress then
		local button = UIKit.BigButton({
			Name = "Action",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(112, 58),
			Color = buttonColor,
			Text = buttonText,
			TextSize = 22,
			Parent = row,
		})
		button.Activated:Connect(onPress)
		return button
	end
	return nil
end

local function passiveText(item: CritterView): string
	local rarity = CritterConfig.Get(item.CritterId)
	local rarityDef = rarity and CritterConfig.GetRarity(rarity.Rarity)
	local rarityText = if rarityDef then string.format('<font color="#%s">%s</font>', rarityDef.Color:ToHex(), rarityDef.DisplayName) else ""
	return string.format("%s · +%s ✨/mnt", rarityText, NumberFormat.Abbreviate(CritterConfig.GetPassive(item.CritterId, item.Shiny)))
end

local function render(): ()
	local r = refs
	if not r then
		return
	end
	local baseItems = StateController.GetBaseCritters()
	local bagItems = StateController.GetBag()
	local slots = StateController.GetBaseSlots()

	r.Summary.Text = string.format("Slot %d/%d  ·  +%s ✨/menit", #baseItems, slots, NumberFormat.Abbreviate(StateController.GetPassiveRate()))

	UIKit.ClearList(r.BaseList)
	for index = 1, math.max(slots, #baseItems) do
		local item = baseItems[index]
		if item then
			makeRow(r.BaseList, index, item, passiveText(item), "Ambil", THEME.Action, function()
				retrieve(index, item)
			end)
		else
			makeRow(r.BaseList, index, nil, "Taruh critter dari tas →", nil, nil, nil)
		end
	end

	UIKit.ClearList(r.BagList)
	if #bagItems == 0 then
		makeRow(r.BagList, 1, nil, "Tas kosong. Ayo tangkap critter!", nil, nil, nil)
	end
	for index, item in bagItems do
		makeRow(r.BagList, index, item, passiveText(item), "Taruh", THEME.Buy, function()
			place(index, item)
		end)
	end
end

local function buildUi(): Refs
	local gui = UIController.GetGui()
	local frame, pop = UIKit.ModalFrame("BaseWindow", Vector2.new(820, 500), gui)
	UIKit.Title(frame, "🏡 Markas")
	UIKit.CloseButton(frame, UIController.CloseModal)

	local summary: TextLabel = make("TextLabel", {
		Name = "Summary",
		Position = UDim2.fromOffset(28, 70),
		Size = UDim2.new(1, -56, 0, 30),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = THEME.TextMuted,
		TextSize = 22,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local function columnHeader(text: string, xScale: number, xOffset: number)
		make("TextLabel", {
			Position = UDim2.new(xScale, xOffset, 0, 104),
			Size = UDim2.new(0.5, -28, 0, 30),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = THEME.Text,
			TextSize = 24,
			Font = THEME.Font,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = frame,
		})
	end
	columnHeader("Di Markas", 0, 20)
	columnHeader("Di Tas 🎒", 0.5, 8)

	local baseList = UIKit.ScrollList(frame, UDim2.fromOffset(16, 138), UDim2.new(0.5, -24, 1, -154), 10)
	local bagList = UIKit.ScrollList(frame, UDim2.new(0.5, 8, 0, 138), UDim2.new(0.5, -24, 1, -154), 10)

	return { Frame = frame, Pop = pop, Summary = summary, BaseList = baseList, BagList = bagList }
end

function BaseController.Open(): ()
	local r = refs
	if not r then
		return
	end
	UIController.OpenModal({
		Frame = r.Frame,
		Pop = r.Pop,
		IsInRange = function(): boolean
			return UIController.IsNearTagged(BaseConfig.Tag, BaseConfig.ClientAutoCloseDistance)
		end,
		FirstSelectable = function(): GuiObject?
			for _, list in { r.BagList, r.BaseList } do
				local action = list:FindFirstChild("Action", true)
				if action and action:IsA("GuiObject") then
					return action
				end
			end
			return nil
		end,
		OnRefresh = render,
	})
end

---------------------------------------------------------------------
-- Tampilan lokal critter markas (melayang mengelilingi markas)
---------------------------------------------------------------------

local function rebuildDisplay(): ()
	local folder = displayFolder
	if not folder then
		return
	end
	folder:ClearAllChildren()
	table.clear(displayParts)

	for _, item in StateController.GetBaseCritters() do
		local def = CritterConfig.Get(item.CritterId)
		if def then
			local part = Instance.new("Part")
			part.Name = def.DisplayName
			part.Shape = Enum.PartType.Ball
			part.Size = Vector3.one * def.Size
			part.Color = def.Color
			part.Material = if item.Shiny then Enum.Material.Neon else Enum.Material.SmoothPlastic
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			if item.Shiny then
				local sparkles = Instance.new("Sparkles")
				sparkles.SparkleColor = THEME.Gold
				sparkles.Parent = part
			end
			part.Parent = folder
			table.insert(displayParts, part)
		end
	end
end

local function updateDisplay(dt: number): ()
	if #displayParts == 0 then
		return
	end
	local center = getBasePosition()
	if not center then
		return
	end
	orbitAngle += dt * BaseConfig.DisplayOrbitSpeed
	local count = #displayParts
	local time = os.clock()
	for index, part in displayParts do
		local angle = orbitAngle + (index - 1) * (math.pi * 2 / count)
		local bob = math.sin(time * 2 + index) * 0.6
		local position = center + Vector3.new(
			math.cos(angle) * BaseConfig.DisplayOrbitRadius,
			BaseConfig.DisplayHeight + bob,
			math.sin(angle) * BaseConfig.DisplayOrbitRadius
		)
		part.CFrame = CFrame.lookAt(position, position + Vector3.new(-math.sin(angle), 0, math.cos(angle)))
	end
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function BaseController.Init(): ()
	placeRemote = Net.Function(Net.Functions.PlaceCritter)
	retrieveRemote = Net.Function(Net.Functions.RetrieveCritter)
	refs = buildUi()

	local folder = Instance.new("Folder")
	folder.Name = "LocalBaseCritters"
	folder.Parent = Workspace
	displayFolder = folder

	UIController.RegisterPrompt(BaseConfig.PromptName, function()
		BaseController.Open()
	end)

	StateController.Changed:Connect(function(key: string, delta: any, reason: any)
		if key == "Base" or key == "Loaded" then
			rebuildDisplay()
		end

		if key == "Loaded" then
			local report = StateController.TakeOfflineReport()
			if report then
				UIController.ShowToast(
					string.format("Selamat datang kembali! Critter markasmu mengumpulkan +%s ✨ selama %s 🏡",
						NumberFormat.Abbreviate(report.Amount), formatDuration(report.Seconds)),
					true,
					6
				)
			end
		elseif key == "Essence" and reason == "Passive" and typeof(delta) == "number" and delta > 0 then
			local rootPosition = UIController.GetRootPosition()
			if rootPosition then
				EffectsController.FloatText(rootPosition + Vector3.new(0, 4, 0), "+" .. NumberFormat.Abbreviate(delta) .. " ✨ markas", THEME.Gold, false)
			end
		end
	end)
end

function BaseController.Start(): ()
	RunService.RenderStepped:Connect(updateDisplay)
end

return BaseController
