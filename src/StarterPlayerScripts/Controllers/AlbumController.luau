--!strict
--[[
	AlbumController
	---------------
	UI Album / Index koleksi critter per bioma (pulau):
	  • Tombol 📖 di HUD kiri membuka Album (bisa dibuka di mana saja).
	  • Tab per pulau, persentase penyelesaian + progress bar, info hadiah bioma.
	  • Kartu critter: yang sudah tertangkap berwarna (jumlah & jumlah shiny),
	    yang belum tertangkap tampil "???" tetapi rarity-nya tetap terlihat sebagai petunjuk.
	  • Perayaan saat satu bioma lengkap (hadiah diberikan otomatis oleh server, AlbumService).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)
local EffectsController = require(script.Parent.EffectsController)

local THEME = UIKit.THEME
local make = UIKit.Make

local AlbumController = {}

type Refs = {
	Frame: Frame,
	Pop: UIScale,
	Tabs: { [string]: TextButton },
	Header: TextLabel,
	BarFill: Frame,
	Reward: TextLabel,
	Grid: ScrollingFrame,
}

local refs: Refs? = nil
local selectedIslandId = IslandConfig.Islands[1].Id

-- (jumlah jenis tertangkap, total jenis) untuk satu pulau
local function getProgress(island: IslandConfig.IslandDef): (number, number)
	local collection = StateController.GetCollection()
	local caught = 0
	for _, critterId in island.Critters do
		if collection[critterId] then
			caught += 1
		end
	end
	return caught, #island.Critters
end

---------------------------------------------------------------------
-- Render
---------------------------------------------------------------------

local function makeCard(parent: Instance, order: number, critterId: string): ()
	local def = CritterConfig.Get(critterId)
	if not def then
		return
	end
	local rarity = CritterConfig.GetRarity(def.Rarity)
	local entry = StateController.GetCollection()[critterId]
	local caught = entry ~= nil

	local card: Frame = make("Frame", {
		Name = critterId,
		BackgroundColor3 = if caught then THEME.Card else Color3.fromRGB(225, 230, 240),
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(card, 18)
	UIKit.Stroke(card, if rarity then rarity.Color else THEME.PanelStroke, 3)

	local circle: TextLabel = make("TextLabel", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(72, 72),
		BackgroundColor3 = if caught then def.Color else THEME.Locked,
		Text = if caught then "" else "?",
		TextColor3 = THEME.TextLight,
		TextSize = 40,
		Font = THEME.Font,
		Parent = card,
	})
	UIKit.Corner(circle, 36)

	make("TextLabel", {
		Name = "Name",
		Position = UDim2.fromOffset(6, 86),
		Size = UDim2.new(1, -12, 0, 26),
		BackgroundTransparency = 1,
		Text = if caught then def.DisplayName else "???",
		TextColor3 = THEME.Text,
		TextScaled = true,
		Font = THEME.Font,
		Parent = card,
	})

	make("TextLabel", {
		Name = "Rarity",
		Position = UDim2.fromOffset(6, 112),
		Size = UDim2.new(1, -12, 0, 20),
		BackgroundTransparency = 1,
		Text = if rarity then rarity.DisplayName else "",
		TextColor3 = if rarity then rarity.Color else THEME.TextMuted,
		TextStrokeTransparency = 0.6,
		TextScaled = true,
		Font = THEME.Font,
		Parent = card,
	})

	make("TextLabel", {
		Name = "Count",
		Position = UDim2.fromOffset(6, 134),
		Size = UDim2.new(1, -12, 0, 20),
		BackgroundTransparency = 1,
		Text = if entry then string.format("x%s  ·  ✨%d", NumberFormat.Abbreviate(entry.Caught), entry.Shiny) else "Belum ditemukan",
		TextColor3 = THEME.TextMuted,
		TextScaled = true,
		Font = THEME.Font,
		Parent = card,
	})
end

local function render(): ()
	local r = refs
	if not r then
		return
	end
	local island = IslandConfig.Get(selectedIslandId)
	if not island then
		return
	end

	-- Tab
	for _, other in IslandConfig.Islands do
		local tab = r.Tabs[other.Id]
		if tab then
			local caught, total = getProgress(other)
			local locked = not StateController.IsIslandUnlocked(other.Id)
			local complete = total > 0 and caught >= total
			tab.Text = (if locked then "🔒 " elseif complete then "✔ " else "") .. other.DisplayName
			tab.BackgroundColor3 = if other.Id == selectedIslandId then other.Color else THEME.CannotAfford
		end
	end

	-- Header & progress
	local caught, total = getProgress(island)
	local percent = if total > 0 then math.floor(caught / total * 100) else 0
	r.Header.Text = string.format("%s — %d/%d (%d%%)", island.DisplayName, caught, total, percent)
	r.BarFill.Size = UDim2.fromScale(if total > 0 then caught / total else 0, 1)
	r.BarFill.BackgroundColor3 = island.Color

	if StateController.IsAlbumClaimed(island.Id) then
		r.Reward.Text = string.format("🎁 Hadiah bioma: %s ✨ — sudah didapat ✔", NumberFormat.Abbreviate(island.AlbumReward))
	else
		r.Reward.Text = string.format("🎁 Lengkapi bioma ini untuk mendapat %s ✨", NumberFormat.Abbreviate(island.AlbumReward))
	end

	-- Kartu critter
	UIKit.ClearList(r.Grid)
	for index, critterId in island.Critters do
		makeCard(r.Grid, index, critterId)
	end
end

local function selectIsland(islandId: string): ()
	selectedIslandId = islandId
	render()
end

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

local function buildUi(): Refs
	local gui = UIController.GetGui()
	local frame, pop = UIKit.ModalFrame("AlbumWindow", Vector2.new(840, 520), gui)
	UIKit.Title(frame, "📖 Album Critter")
	UIKit.CloseButton(frame, UIController.CloseModal)

	-- Baris tab pulau
	local tabRow: Frame = make("Frame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(1, -32, 0, 56),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = tabRow,
	})
	local tabs: { [string]: TextButton } = {}
	local tabWidth = (840 - 32 - 8 * (#IslandConfig.Islands - 1)) / #IslandConfig.Islands
	for index, island in IslandConfig.Islands do
		local tab = UIKit.BigButton({
			Name = island.Id,
			Size = UDim2.fromOffset(tabWidth, 56),
			Color = THEME.CannotAfford,
			Text = island.DisplayName,
			TextSize = 18,
			LayoutOrder = index,
			Radius = 14,
			Parent = tabRow,
		})
		tab.Activated:Connect(function()
			selectIsland(island.Id)
		end)
		tabs[island.Id] = tab
	end

	local header: TextLabel = make("TextLabel", {
		Name = "Header",
		Position = UDim2.fromOffset(24, 144),
		Size = UDim2.new(1, -48, 0, 30),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = THEME.Text,
		TextSize = 26,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local bar: Frame = make("Frame", {
		Name = "ProgressBar",
		Position = UDim2.fromOffset(24, 178),
		Size = UDim2.new(1, -48, 0, 20),
		BackgroundColor3 = Color3.fromRGB(210, 218, 232),
		Parent = frame,
	})
	UIKit.Corner(bar, 10)
	local fill: Frame = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = THEME.Buy,
		Parent = bar,
	})
	UIKit.Corner(fill, 10)

	local reward: TextLabel = make("TextLabel", {
		Name = "Reward",
		Position = UDim2.fromOffset(24, 202),
		Size = UDim2.new(1, -48, 0, 28),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = THEME.TextMuted,
		TextSize = 20,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local grid: ScrollingFrame = make("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromOffset(16, 236),
		Size = UDim2.new(1, -32, 1, -252),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = THEME.PanelStroke,
		Selectable = false,
		Parent = frame,
	})
	make("UIGridLayout", {
		CellSize = UDim2.fromOffset(148, 160),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = grid,
	})
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = grid })

	return { Frame = frame, Pop = pop, Tabs = tabs, Header = header, BarFill = fill, Reward = reward, Grid = grid }
end

function AlbumController.Open(islandId: string?): ()
	local r = refs
	if not r then
		return
	end
	if islandId and IslandConfig.Get(islandId) then
		selectedIslandId = islandId
	end
	UIController.OpenModal({
		Frame = r.Frame,
		Pop = r.Pop,
		IsInRange = function(): boolean
			return true -- Album bisa dibuka di mana saja
		end,
		FirstSelectable = function(): GuiObject?
			return r.Tabs[selectedIslandId]
		end,
		OnRefresh = render,
	})
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function AlbumController.Init(): ()
	refs = buildUi()

	UIController.AddHudButton("AlbumButton", "📖", "Album", 1, function()
		local r = refs
		if r and UIController.IsModalOpen(r.Frame) then
			UIController.CloseModal()
		else
			AlbumController.Open(nil)
		end
	end)

	StateController.AlbumCompleted:Connect(function(islandId: string, reward: number)
		local island = IslandConfig.Get(islandId)
		if not island then
			return
		end
		UIController.ShowToast(
			string.format("📖 Album %s lengkap! Hadiah +%s ✨ 🎉", island.DisplayName, NumberFormat.Abbreviate(reward)),
			true,
			5
		)
		local rootPosition = UIController.GetRootPosition()
		if rootPosition then
			EffectsController.Burst(rootPosition, island.Color, 80)
			EffectsController.Burst(rootPosition, THEME.Gold, 50)
			EffectsController.FloatText(rootPosition + Vector3.new(0, 5, 0), "📖 " .. island.DisplayName .. " lengkap!", THEME.Gold, true)
		end
	end)
end

function AlbumController.Start(): () end

return AlbumController
