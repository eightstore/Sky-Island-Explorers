--!strict
--[[
	UIController
	------------
	Pusat UI layar dan "infrastruktur" untuk controller lain:
	  • HUD: saldo Essence & isi tas (🎒 3/10, merah jika penuh) + tombol HUD di kiri (Album, dll.)
	  • Manajer jendela modal: hanya satu terbuka, tombol B gamepad menutup,
	    tertutup otomatis jika pemain menjauh dari objeknya
	  • Toast (pesan singkat) untuk semua controller
	  • Pengarah ProximityPrompt: controller lain mendaftar lewat RegisterPrompt
	  • Jendela milik UIController sendiri: Toko Upgrade, Dialog Buka Pulau, Setor tas

	API publik:
		UIController.ShowToast(pesan, positif, durasi?)
		UIController.OpenModal(modal) / CloseModal() / IsModalOpen(frame)
		UIController.GetGui() -> ScreenGui
		UIController.AddHudButton(nama, ikon, teks, urutan, callback) -> TextButton
		UIController.RegisterPrompt(namaPrompt, callback(prompt))

	Client TIDAK pernah menentukan saldo/level. Semua nilai dibaca dari StateController.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local EffectsController = require(script.Parent.EffectsController)

type Modal = UIKit.Modal

local THEME = UIKit.THEME
local make = UIKit.Make

local localPlayer = Players.LocalPlayer

local UIController = {}

local REFERENCE_SIZE = Vector2.new(1000, 560) -- resolusi acuan desain
local MIN_SCALE = 0.65 -- batas bawah agar tombol tetap besar di HP
local MAX_SCALE = 1.35
local TOAST_DURATION = 2.5
local AUTO_CLOSE_CHECK_INTERVAL = 0.5
local CLOSE_ACTION_NAME = "SkyIsland_CloseModal"

---------------------------------------------------------------------
-- Tipe referensi UI
---------------------------------------------------------------------

type CardRefs = {
	Frame: Frame,
	Level: TextLabel,
	Stats: TextLabel,
	BuyButton: TextButton,
}

type IslandDialogRefs = {
	Frame: Frame,
	Pop: UIScale,
	Title: TextLabel,
	Body: TextLabel,
	ConfirmButton: TextButton,
}

type UiRefs = {
	Gui: ScreenGui,
	RootScale: UIScale,
	EssenceLabel: TextLabel,
	EssencePop: UIScale,
	BagFrame: Frame,
	BagLabel: TextLabel,
	BagPop: UIScale,
	HudButtons: Frame,
	ShopFrame: Frame,
	ShopPop: UIScale,
	Cards: { [string]: CardRefs },
	Island: IslandDialogRefs,
	Toast: TextLabel,
}

local ui: UiRefs? = nil
local currentModal: Modal? = nil
local currentIslandId: string? = nil
local pendingRequest = false
local toastToken = 0
local promptHandlers: { [string]: (ProximityPrompt) -> () } = {}

local purchaseRemote: RemoteFunction? = nil
local depositRemote: RemoteFunction? = nil
local unlockRemote: RemoteFunction? = nil

local function getUi(): UiRefs
	local refs = ui
	assert(refs, "UIController belum di-Init")
	return refs
end

---------------------------------------------------------------------
-- Toast (pesan singkat)
---------------------------------------------------------------------

function UIController.ShowToast(message: string, positive: boolean, duration: number?): ()
	local refs = ui
	if not refs then
		return
	end
	toastToken += 1
	local myToken = toastToken

	refs.Toast.Text = message
	refs.Toast.BackgroundColor3 = if positive then THEME.Positive else THEME.Negative
	refs.Toast.Visible = true

	task.delay(duration or TOAST_DURATION, function()
		if toastToken == myToken then
			refs.Toast.Visible = false
		end
	end)
end

local showToast = UIController.ShowToast

---------------------------------------------------------------------
-- Jarak ke objek ber-tag (untuk menutup jendela otomatis)
---------------------------------------------------------------------

function UIController.GetRootPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function getInstancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

function UIController.IsNearTagged(tag: string, maxDistance: number, filter: ((Instance) -> boolean)?): boolean
	local rootPosition = UIController.GetRootPosition()
	if not rootPosition then
		return false
	end
	for _, instance in CollectionService:GetTagged(tag) do
		if not filter or filter(instance) then
			local position = getInstancePosition(instance)
			if position and (position - rootPosition).Magnitude <= maxDistance then
				return true
			end
		end
	end
	return false
end

local isNearTagged = UIController.IsNearTagged

---------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------

local function renderHud(animateEssence: boolean, animateBag: boolean): ()
	local refs = ui
	if not refs then
		return
	end
	refs.EssenceLabel.Text = "✨ " .. NumberFormat.Abbreviate(StateController.GetEssence())
	if animateEssence then
		UIKit.Pop(refs.EssencePop, 1.15)
	end

	local count = StateController.GetBagCount()
	local capacity = StateController.GetBagCapacity()
	refs.BagLabel.Text = if StateController.HasInfiniteBag()
		then string.format("🎒 %d/∞", count)
		else string.format("🎒 %d/%d", count, capacity)
	refs.BagFrame.BackgroundColor3 = if count >= capacity then THEME.BagFull else THEME.HudBackground
	if animateBag then
		UIKit.Pop(refs.BagPop, 1.15)
	end
end

-- Tombol bulat besar di sisi kiri layar (Album, dll.)
function UIController.AddHudButton(name: string, icon: string, label: string, order: number, callback: () -> ()): TextButton
	local refs = getUi()
	local button = UIKit.BigButton({
		Name = name,
		Size = UDim2.fromOffset(84, 84),
		Color = THEME.HudBackground,
		Text = icon .. "\n" .. label,
		TextSize = 20,
		LayoutOrder = order,
		Radius = 24,
		Parent = refs.HudButtons,
	})
	UIKit.Stroke(button, THEME.PanelStroke, 3)
	button.Activated:Connect(callback)
	return button
end

function UIController.GetGui(): ScreenGui
	return getUi().Gui
end

---------------------------------------------------------------------
-- Manajer modal (satu jendela pada satu waktu)
---------------------------------------------------------------------

function UIController.CloseModal(): ()
	local modal = currentModal
	if not modal then
		return
	end
	currentModal = nil
	currentIslandId = nil
	modal.Frame.Visible = false
	ContextActionService:UnbindAction(CLOSE_ACTION_NAME)
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(modal.Frame) then
		GuiService.SelectedObject = nil
	end
end

local closeModal = UIController.CloseModal

function UIController.OpenModal(modal: Modal): ()
	if currentModal then
		closeModal()
	end
	currentModal = modal
	modal.OnRefresh()
	modal.Frame.Visible = true
	UIKit.Pop(modal.Pop, 0.85)

	-- Tombol B pada gamepad menutup jendela
	ContextActionService:BindActionAtPriority(CLOSE_ACTION_NAME, function(_name: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if inputState == Enum.UserInputState.Begin then
			closeModal()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB)

	-- Pemain gamepad langsung diarahkan ke tombol utama
	if UserInputService.GamepadEnabled then
		local first = modal.FirstSelectable()
		if first then
			GuiService.SelectedObject = first
		end
	end
end

local openModal = UIController.OpenModal

function UIController.IsModalOpen(frame: Frame): boolean
	local modal = currentModal
	return modal ~= nil and modal.Frame == frame
end

local function refreshModal(): ()
	local modal = currentModal
	if modal then
		modal.OnRefresh()
	end
end

---------------------------------------------------------------------
-- ProximityPrompt
---------------------------------------------------------------------

function UIController.RegisterPrompt(promptName: string, callback: (ProximityPrompt) -> ()): ()
	promptHandlers[promptName] = callback
end

---------------------------------------------------------------------
-- Toko Upgrade
---------------------------------------------------------------------

local function buildStatsText(def: UpgradeConfig.UpgradeDef, level: number, isMax: boolean): string
	local lines: { string } = {}
	for _, stat in def.Stats do
		local current = UpgradeConfig.FormatStatValue(stat, UpgradeConfig.GetStatValue(stat, level))
		if isMax then
			table.insert(lines, string.format("<b>%s</b>: %s", stat.DisplayName, current))
		else
			local nextValue = UpgradeConfig.FormatStatValue(stat, UpgradeConfig.GetStatValue(stat, level + 1))
			table.insert(lines, string.format('<b>%s</b>: %s → <font color="%s">%s</font>', stat.DisplayName, current, THEME.NextValue, nextValue))
		end
	end
	return table.concat(lines, "\n")
end

local function renderShop(): ()
	local refs = ui
	if not refs then
		return
	end
	local essence = StateController.GetEssence()

	for _, upgradeId in UpgradeConfig.Order do
		local card = refs.Cards[upgradeId]
		local def = UpgradeConfig.Get(upgradeId)
		if card and def then
			local level = StateController.GetUpgradeLevel(upgradeId)
			local cost = UpgradeConfig.GetCost(upgradeId, level)

			card.Level.Text = string.format("Level %d / %d", level, def.MaxLevel)
			card.Stats.Text = buildStatsText(def, level, cost == nil)

			local button = card.BuyButton
			if not StateController.IsLoaded() then
				button.Text = "Memuat..."
				button.BackgroundColor3 = THEME.CannotAfford
			elseif cost == nil then
				button.Text = "MAKS ⭐"
				button.BackgroundColor3 = THEME.Max
			elseif pendingRequest then
				button.Text = "..."
				button.BackgroundColor3 = THEME.CannotAfford
			elseif essence >= cost then
				button.Text = "⬆ " .. NumberFormat.Abbreviate(cost) .. " ✨"
				button.BackgroundColor3 = THEME.Buy
			else
				button.Text = "Butuh " .. NumberFormat.Abbreviate(cost) .. " ✨"
				button.BackgroundColor3 = THEME.CannotAfford
			end
		end
	end
end

local function requestPurchase(upgradeId: string): ()
	local remote = purchaseRemote
	if not remote or pendingRequest or not StateController.IsLoaded() then
		return
	end

	-- Cek awal di client hanya untuk pesan yang ramah; server tetap memvalidasi ulang semuanya
	local cost = UpgradeConfig.GetCost(upgradeId, StateController.GetUpgradeLevel(upgradeId))
	if cost == nil then
		showToast("Sudah level maksimum! ⭐", true)
		return
	end
	local essence = StateController.GetEssence()
	if essence < cost then
		showToast("Kurang " .. NumberFormat.Abbreviate(cost - essence) .. " ✨ lagi. Ayo kumpulkan Essence!", false)
		return
	end

	pendingRequest = true
	renderShop()

	local ok, result = pcall(function(): any
		return remote:InvokeServer(upgradeId)
	end)

	pendingRequest = false

	if ok and type(result) == "table" and type(result.Message) == "string" then
		local success = result.Success == true
		showToast(result.Message, success)
		local refs = ui
		if success and refs then
			local card = refs.Cards[upgradeId]
			local pop = card and card.Frame:FindFirstChildOfClass("UIScale")
			if pop then
				UIKit.Pop(pop, 1.05)
			end
		end
	else
		showToast("Koneksi bermasalah, coba lagi ya.", false)
	end

	renderShop()
end

local function buildCard(def: UpgradeConfig.UpgradeDef, parent: Instance): CardRefs
	local frame: Frame = make("Frame", {
		Name = def.Id,
		Size = UDim2.new(1, -12, 0, 132),
		BackgroundColor3 = THEME.Card,
		LayoutOrder = def.Order,
		Parent = parent,
	})
	UIKit.Corner(frame, 18)
	UIKit.Stroke(frame, THEME.PanelStroke, 2)
	make("UIScale", { Parent = frame })

	local icon: TextLabel = make("TextLabel", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(88, 88),
		BackgroundColor3 = THEME.IconBackground,
		Text = def.Icon,
		TextScaled = true,
		Font = THEME.Font,
		Parent = frame,
	})
	UIKit.Corner(icon, 20)
	UIKit.Padding(icon, 10)

	make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(116, 10),
		Size = UDim2.new(1, -340, 0, 34),
		BackgroundTransparency = 1,
		Text = def.DisplayName,
		TextColor3 = THEME.Text,
		TextSize = 30,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local level: TextLabel = make("TextLabel", {
		Name = "Level",
		Position = UDim2.fromOffset(116, 44),
		Size = UDim2.new(1, -340, 0, 24),
		BackgroundTransparency = 1,
		Text = "Level 1",
		TextColor3 = THEME.TextMuted,
		TextSize = 20,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local stats: TextLabel = make("TextLabel", {
		Name = "Stats",
		Position = UDim2.fromOffset(116, 70),
		Size = UDim2.new(1, -340, 0, 56),
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		TextColor3 = THEME.Text,
		TextSize = 19,
		Font = THEME.Font,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})

	local buyButton = UIKit.BigButton({
		Name = "BuyButton",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(200, 84),
		Color = THEME.CannotAfford,
		Text = "Memuat...",
		Parent = frame,
	})

	-- Activated berlaku untuk klik mouse, tap layar sentuh, dan tombol A gamepad
	buyButton.Activated:Connect(function()
		requestPurchase(def.Id)
	end)

	return { Frame = frame, Level = level, Stats = stats, BuyButton = buyButton }
end

function UIController.OpenShop(): ()
	local refs = getUi()
	openModal({
		Frame = refs.ShopFrame,
		Pop = refs.ShopPop,
		IsInRange = function(): boolean
			return isNearTagged(UpgradeConfig.Shop.Tag, UpgradeConfig.Shop.ClientAutoCloseDistance)
		end,
		FirstSelectable = function(): GuiObject?
			local firstId = UpgradeConfig.Order[1]
			local card = firstId and refs.Cards[firstId]
			return if card then card.BuyButton else nil
		end,
		OnRefresh = renderShop,
	})
end

---------------------------------------------------------------------
-- Dialog Buka Pulau
---------------------------------------------------------------------

local function check(ok: boolean): string
	return if ok
		then string.format('<font color="%s">✔</font>', THEME.Ok)
		else string.format('<font color="%s">✘</font>', THEME.NotOk)
end

-- Mengembalikan (semua syarat terpenuhi?, teks isi dialog)
local function describeIsland(island: IslandConfig.IslandDef): (boolean, string)
	local lines: { string } = {}
	local allOk = true

	table.insert(lines, string.format("Ketinggian: <b>%d m</b>", island.Height))

	local previous = IslandConfig.GetPrevious(island.Id)
	if previous then
		local ok = StateController.IsIslandUnlocked(previous.Id)
		allOk = allOk and ok
		table.insert(lines, string.format("%s Buka %s dulu", check(ok), previous.DisplayName))
	end

	local gliderLevel = StateController.GetUpgradeLevel("Glider")
	local gliderOk = gliderLevel >= island.RequiredGliderLevel
	allOk = allOk and gliderOk
	table.insert(lines, string.format("%s Glider level %d (kamu: %d)", check(gliderOk), island.RequiredGliderLevel, gliderLevel))

	local essence = StateController.GetEssence()
	local costOk = essence >= island.UnlockCost
	allOk = allOk and costOk
	table.insert(lines, string.format("%s Harga: <b>%s ✨</b> (kamu: %s)", check(costOk), NumberFormat.Abbreviate(island.UnlockCost), NumberFormat.Abbreviate(essence)))

	-- Peluang critter di pulau ini (transparan untuk pemain)
	local odds = CritterConfig.GetSpawnOdds(island.Critters)
	local names: { string } = {}
	for _, critterId in island.Critters do
		local def = CritterConfig.Get(critterId)
		local rarity = def and CritterConfig.GetRarity(def.Rarity)
		if def and rarity then
			table.insert(names, string.format('<font color="#%s">%s</font> %.1f%%', rarity.Color:ToHex(), def.DisplayName, (odds[critterId] or 0) * 100))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "<b>Critter di sini:</b> " .. table.concat(names, " · "))

	return allOk, table.concat(lines, "\n")
end

local function renderIslandDialog(): ()
	local refs = ui
	local islandId = currentIslandId
	if not refs or not islandId then
		return
	end
	local island = IslandConfig.Get(islandId)
	if not island then
		return
	end

	local dialog = refs.Island
	dialog.Title.Text = "🏝️ " .. island.DisplayName

	if StateController.IsIslandUnlocked(island.Id) then
		dialog.Body.Text = "Pulau ini sudah terbuka. Selamat menjelajah! ☁️"
		dialog.ConfirmButton.Text = "Terbuka ✔"
		dialog.ConfirmButton.BackgroundColor3 = THEME.CannotAfford
		return
	end

	local allOk, body = describeIsland(island)
	dialog.Body.Text = body
	if pendingRequest then
		dialog.ConfirmButton.Text = "..."
		dialog.ConfirmButton.BackgroundColor3 = THEME.CannotAfford
	elseif allOk then
		dialog.ConfirmButton.Text = "Buka! 🔓"
		dialog.ConfirmButton.BackgroundColor3 = THEME.Buy
	else
		dialog.ConfirmButton.Text = "Belum bisa"
		dialog.ConfirmButton.BackgroundColor3 = THEME.CannotAfford
	end
end

local function requestUnlock(): ()
	local remote = unlockRemote
	local islandId = currentIslandId
	if not remote or not islandId or pendingRequest then
		return
	end
	local island = IslandConfig.Get(islandId)
	if not island or StateController.IsIslandUnlocked(islandId) then
		return
	end

	local allOk = describeIsland(island)
	if not allOk then
		showToast("Syaratnya belum terpenuhi. Lihat tanda ✘ ya!", false)
		return
	end

	pendingRequest = true
	renderIslandDialog()

	local ok, result = pcall(function(): any
		return remote:InvokeServer(islandId)
	end)

	pendingRequest = false

	if ok and type(result) == "table" and type(result.Message) == "string" then
		local success = result.Success == true
		showToast(result.Message, success)
		if success then
			closeModal()
			return
		end
	else
		showToast("Koneksi bermasalah, coba lagi ya.", false)
	end
	renderIslandDialog()
end

function UIController.OpenIslandDialog(islandId: string): ()
	if not IslandConfig.Get(islandId) then
		return
	end
	local refs = getUi()
	openModal({
		Frame = refs.Island.Frame,
		Pop = refs.Island.Pop,
		IsInRange = function(): boolean
			local id = currentIslandId
			return isNearTagged(IslandConfig.Gate.Tag, IslandConfig.Gate.ClientAutoCloseDistance, function(gate: Instance): boolean
				return gate:GetAttribute(IslandConfig.Gate.IdAttribute) == id
			end)
		end,
		FirstSelectable = function(): GuiObject?
			return refs.Island.ConfirmButton
		end,
		OnRefresh = renderIslandDialog,
	})
	currentIslandId = islandId
	renderIslandDialog()
end

---------------------------------------------------------------------
-- Setor tas
---------------------------------------------------------------------

local function requestDeposit(): ()
	local remote = depositRemote
	if not remote or pendingRequest or not StateController.IsLoaded() then
		return
	end
	if StateController.GetBagCount() == 0 then
		showToast("Tasmu masih kosong. Ayo tangkap critter!", false)
		return
	end

	pendingRequest = true
	local ok, result = pcall(function(): any
		return remote:InvokeServer()
	end)
	pendingRequest = false

	if ok and type(result) == "table" and type(result.Message) == "string" then
		local success = result.Success == true
		showToast(result.Message, success)
		local rootPosition = UIController.GetRootPosition()
		if success and rootPosition and typeof(result.Gained) == "number" then
			EffectsController.Burst(rootPosition, THEME.Gold, 40)
			EffectsController.FloatText(rootPosition + Vector3.new(0, 4, 0), "+" .. NumberFormat.Abbreviate(result.Gained) .. " ✨", THEME.Gold, true)
		end
	else
		showToast("Koneksi bermasalah, coba lagi ya.", false)
	end
end

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

local function buildIslandDialog(parent: Instance): IslandDialogRefs
	local frame, pop = UIKit.ModalFrame("IslandDialog", Vector2.new(600, 420), parent)
	local title = UIKit.Title(frame, "🏝️ Pulau")

	local body: TextLabel = make("TextLabel", {
		Name = "Body",
		Position = UDim2.fromOffset(28, 78),
		Size = UDim2.new(1, -56, 1, -190),
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		TextColor3 = THEME.Text,
		TextSize = 22,
		TextWrapped = true,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})

	local cancel = UIKit.BigButton({
		Name = "Cancel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 24, 1, -20),
		Size = UDim2.new(0.5, -36, 0, 80),
		Color = THEME.Close,
		Text = "Batal",
		Parent = frame,
	})

	local confirm = UIKit.BigButton({
		Name = "Confirm",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -20),
		Size = UDim2.new(0.5, -36, 0, 80),
		Color = THEME.Buy,
		Text = "Buka! 🔓",
		Parent = frame,
	})

	cancel.Activated:Connect(closeModal)
	confirm.Activated:Connect(requestUnlock)

	return { Frame = frame, Pop = pop, Title = title, Body = body, ConfirmButton = confirm }
end

local function buildUi(): UiRefs
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui: ScreenGui = make("ScreenGui", {
		Name = "SkyIslandHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	local rootScale: UIScale = make("UIScale", { Parent = gui })

	-- Baris HUD atas tengah: [✨ Essence] [🎒 Tas]
	local topBar: Frame = make("Frame", {
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(460, 64),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = topBar,
	})

	local function hudPill(name: string, width: number, order: number): (Frame, TextLabel, UIScale)
		local frame: Frame = make("Frame", {
			Name = name,
			Size = UDim2.fromOffset(width, 64),
			BackgroundColor3 = THEME.HudBackground,
			BackgroundTransparency = 0.15,
			LayoutOrder = order,
			Parent = topBar,
		})
		UIKit.Corner(frame, 22)
		UIKit.Stroke(frame, THEME.PanelStroke, 3)
		local pop: UIScale = make("UIScale", { Parent = frame })
		local label: TextLabel = make("TextLabel", {
			Name = "Value",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "...",
			TextColor3 = THEME.TextLight,
			TextScaled = true,
			Font = THEME.Font,
			Parent = frame,
		})
		UIKit.Padding(label, 10)
		return frame, label, pop
	end

	local _, essenceLabel, essencePop = hudPill("EssenceCounter", 250, 1)
	local bagFrame, bagLabel, bagPop = hudPill("BagCounter", 190, 2)

	-- Kolom tombol HUD di kiri tengah (Album, dll.)
	local hudButtons: Frame = make("Frame", {
		Name = "HudButtons",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.fromOffset(90, 480),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = hudButtons,
	})

	-- Toko Upgrade
	local shopFrame, shopPop = UIKit.ModalFrame("UpgradeShop", Vector2.new(680, 470), gui)
	UIKit.Title(shopFrame, "🛠️ Toko Upgrade")
	UIKit.CloseButton(shopFrame, closeModal)
	local list = UIKit.ScrollList(shopFrame, UDim2.fromOffset(16, 84), UDim2.new(1, -32, 1, -100), 12)

	local cards: { [string]: CardRefs } = {}
	for _, upgradeId in UpgradeConfig.Order do
		local def = UpgradeConfig.Get(upgradeId)
		if def then
			cards[upgradeId] = buildCard(def, list)
		end
	end

	local island = buildIslandDialog(gui)

	-- Toast (bawah tengah)
	local toast: TextLabel = make("TextLabel", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(600, 64),
		BackgroundColor3 = THEME.Positive,
		Text = "",
		TextColor3 = THEME.TextLight,
		TextSize = 24,
		TextWrapped = true,
		Font = THEME.Font,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	UIKit.Corner(toast, 18)
	UIKit.Padding(toast, 8)

	return {
		Gui = gui,
		RootScale = rootScale,
		EssenceLabel = essenceLabel,
		EssencePop = essencePop,
		BagFrame = bagFrame,
		BagLabel = bagLabel,
		BagPop = bagPop,
		HudButtons = hudButtons,
		ShopFrame = shopFrame,
		ShopPop = shopPop,
		Cards = cards,
		Island = island,
		Toast = toast,
	}
end

-- Skala UI mengikuti ukuran layar, dengan batas bawah agar tombol tetap mudah disentuh
local function updateScale(): ()
	local refs = ui
	local camera = Workspace.CurrentCamera
	if not refs or not camera then
		return
	end
	local viewport = camera.ViewportSize
	local scale = math.min(viewport.X / REFERENCE_SIZE.X, viewport.Y / REFERENCE_SIZE.Y)
	refs.RootScale.Scale = math.clamp(scale, MIN_SCALE, MAX_SCALE)
end

local cameraConnection: RBXScriptConnection? = nil
local function watchCamera(): ()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function UIController.Init(): ()
	ui = buildUi()
	purchaseRemote = Net.Function(Net.Functions.PurchaseUpgrade)
	depositRemote = Net.Function(Net.Functions.DepositBag)
	unlockRemote = Net.Function(Net.Functions.UnlockIsland)

	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	StateController.Changed:Connect(function(key: string, extra: any)
		if key == "Essence" then
			renderHud(typeof(extra) == "number" and extra > 0, false)
		elseif key == "Bag" then
			renderHud(false, true)
		else
			renderHud(false, false)
		end
		refreshModal()
	end)

	-- Pesan dari server (mis. pembelian berhasil diproses)
	Net.Event(Net.Events.Notify).OnClientEvent:Connect(function(message: any, positive: any)
		if typeof(message) == "string" then
			showToast(message, positive == true, 4)
		end
	end)

	StateController.LoadFailed:Connect(function()
		showToast("Gagal memuat data. Coba bergabung ulang ya.", false)
	end)

	-- Prompt milik UIController
	UIController.RegisterPrompt(UpgradeConfig.Shop.PromptName, function()
		UIController.OpenShop()
	end)
	UIController.RegisterPrompt(CritterConfig.Deposit.PromptName, function()
		task.spawn(requestDeposit)
	end)
	UIController.RegisterPrompt(IslandConfig.Gate.PromptName, function(prompt: ProximityPrompt)
		-- Atribut IslandId ada di gerbang (Part) atau di salah satu Model induknya
		local node: Instance? = prompt.Parent
		local islandId: any = nil
		while node and node ~= Workspace and islandId == nil do
			islandId = node:GetAttribute(IslandConfig.Gate.IdAttribute)
			node = node.Parent
		end
		if typeof(islandId) == "string" then
			UIController.OpenIslandDialog(islandId)
		end
	end)

	-- Semua ProximityPrompt game ini diarahkan lewat RegisterPrompt
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggeringPlayer: Player)
		if triggeringPlayer ~= localPlayer then
			return
		end
		local handler = promptHandlers[prompt.Name]
		if handler then
			handler(prompt)
		end
	end)

	renderHud(false, false)
end

function UIController.Start(): ()
	-- Tutup jendela otomatis jika pemain berjalan menjauh
	task.spawn(function()
		while true do
			task.wait(AUTO_CLOSE_CHECK_INTERVAL)
			local modal = currentModal
			if modal and not modal.IsInRange() then
				closeModal()
				showToast("Jendela ditutup karena kamu menjauh.", true)
			end
		end
	end)
end

return UIController
