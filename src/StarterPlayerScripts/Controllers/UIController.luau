--!strict
--[[
	UIController
	------------
	Semua UI layar:
	  • HUD: saldo Essence & isi tas (🎒 3/10, merah jika penuh)
	  • Toko Upgrade (dibuka lewat ProximityPrompt toko)
	  • Dialog Buka Pulau (dibuka lewat ProximityPrompt gerbang): harga, syarat glider,
	    pulau sebelumnya, dan tombol konfirmasi (anti salah pencet untuk anak-anak)
	  • Setor tas (ProximityPrompt Zona Setor)
	  • Toast (pesan singkat) yang bisa dipakai controller lain: UIController.ShowToast(...)

	Prinsip:
	  • Client TIDAK pernah menentukan saldo/level. Semua nilai dibaca dari StateController.
	  • UI dibuat lewat kode dan diskalakan otomatis untuk HP, tablet, PC, dan konsol.
	  • Hanya satu jendela (modal) terbuka pada satu waktu. Tombol B gamepad menutupnya,
	    dan jendela tertutup otomatis jika pemain berjalan menjauh.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local UpgradeConfig = require(ReplicatedStorage.Shared.Config.UpgradeConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local StateController = require(script.Parent.StateController)
local EffectsController = require(script.Parent.EffectsController)

local localPlayer = Players.LocalPlayer

local UIController = {}

---------------------------------------------------------------------
-- Tampilan (bukan balancing gameplay)
---------------------------------------------------------------------

local THEME = {
	Font = Enum.Font.FredokaOne,
	HudBackground = Color3.fromRGB(28, 44, 84),
	Panel = Color3.fromRGB(235, 245, 255),
	PanelStroke = Color3.fromRGB(120, 170, 240),
	Card = Color3.fromRGB(255, 255, 255),
	IconBackground = Color3.fromRGB(200, 225, 255),
	Text = Color3.fromRGB(35, 45, 70),
	TextMuted = Color3.fromRGB(95, 105, 130),
	TextLight = Color3.fromRGB(255, 255, 255),
	Buy = Color3.fromRGB(70, 195, 105),
	CannotAfford = Color3.fromRGB(165, 172, 188),
	Max = Color3.fromRGB(255, 190, 50),
	Close = Color3.fromRGB(235, 95, 95),
	Positive = Color3.fromRGB(60, 170, 90),
	Negative = Color3.fromRGB(215, 85, 85),
	BagFull = Color3.fromRGB(200, 60, 60),
	NextValue = "#2E9E50",
	Ok = "#2E9E50",
	NotOk = "#D04545",
}

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
	CancelButton: TextButton,
}

type UiRefs = {
	Gui: ScreenGui,
	RootScale: UIScale,
	EssenceLabel: TextLabel,
	EssencePop: UIScale,
	BagFrame: Frame,
	BagLabel: TextLabel,
	BagPop: UIScale,
	ShopFrame: Frame,
	ShopPop: UIScale,
	ShopClose: TextButton,
	Cards: { [string]: CardRefs },
	Island: IslandDialogRefs,
	Toast: TextLabel,
}

type Modal = {
	Frame: Frame,
	Pop: UIScale,
	IsInRange: () -> boolean,
	FirstSelectable: () -> GuiObject?,
	OnRefresh: () -> (),
}

local ui: UiRefs? = nil
local currentModal: Modal? = nil
local currentIslandId: string? = nil
local pendingRequest = false
local toastToken = 0

local purchaseRemote: RemoteFunction? = nil
local depositRemote: RemoteFunction? = nil
local unlockRemote: RemoteFunction? = nil

---------------------------------------------------------------------
-- Helper pembuatan UI
---------------------------------------------------------------------

-- Membuat instance dengan properti. Parent diset terakhir (lebih efisien).
local function make(className: string, props: { [string]: any }): any
	local instance = Instance.new(className :: any)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function addCorner(parent: Instance, radius: number): ()
	make("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function addStroke(parent: Instance, color: Color3, thickness: number): ()
	make("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function addPadding(parent: Instance, pixels: number): ()
	make("UIPadding", {
		PaddingTop = UDim.new(0, pixels),
		PaddingBottom = UDim.new(0, pixels),
		PaddingLeft = UDim.new(0, pixels),
		PaddingRight = UDim.new(0, pixels),
		Parent = parent,
	})
end

local function popTween(scale: UIScale, from: number): ()
	scale.Scale = from
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function makeBigButton(props: { [string]: any }): TextButton
	local button: TextButton = make("TextButton", {
		Name = props.Name,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Position = props.Position,
		Size = props.Size,
		BackgroundColor3 = props.Color,
		Text = props.Text,
		TextColor3 = THEME.TextLight,
		TextSize = props.TextSize or 26,
		TextWrapped = true,
		Font = THEME.Font,
		AutoButtonColor = true,
		Selectable = true,
		Parent = props.Parent,
	})
	addCorner(button, 18)
	make("UIStroke", {
		Color = Color3.fromRGB(40, 60, 90),
		Thickness = 2,
		Transparency = 0.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = button,
	})
	return button
end

local function makeModalFrame(name: string, size: Vector2, parent: Instance): (Frame, UIScale)
	local frame: Frame = make("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = THEME.Panel,
		Visible = false,
		Parent = parent,
	})
	addCorner(frame, 26)
	addStroke(frame, THEME.PanelStroke, 4)
	local pop: UIScale = make("UIScale", { Parent = frame })
	return frame, pop
end

---------------------------------------------------------------------
-- Toast (pesan singkat)
---------------------------------------------------------------------

function UIController.ShowToast(message: string, positive: boolean): ()
	local refs = ui
	if not refs then
		return
	end
	toastToken += 1
	local myToken = toastToken

	refs.Toast.Text = message
	refs.Toast.BackgroundColor3 = if positive then THEME.Positive else THEME.Negative
	refs.Toast.Visible = true

	task.delay(TOAST_DURATION, function()
		if toastToken == myToken then
			refs.Toast.Visible = false
		end
	end)
end

local showToast = UIController.ShowToast

---------------------------------------------------------------------
-- Jarak ke objek ber-tag (untuk menutup jendela otomatis)
---------------------------------------------------------------------

local function getRootPosition(): Vector3?
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

local function isNearTagged(tag: string, maxDistance: number, filter: ((Instance) -> boolean)?): boolean
	local rootPosition = getRootPosition()
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
		popTween(refs.EssencePop, 1.15)
	end

	local count = StateController.GetBagCount()
	local capacity = StateController.GetBagCapacity()
	refs.BagLabel.Text = string.format("🎒 %d/%d", count, capacity)
	refs.BagFrame.BackgroundColor3 = if count >= capacity then THEME.BagFull else THEME.HudBackground
	if animateBag then
		popTween(refs.BagPop, 1.15)
	end
end

---------------------------------------------------------------------
-- Modal (satu jendela pada satu waktu)
---------------------------------------------------------------------

local function closeModal(): ()
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

local function openModal(modal: Modal): ()
	if currentModal then
		closeModal()
	end
	currentModal = modal
	modal.OnRefresh()
	modal.Frame.Visible = true
	popTween(modal.Pop, 0.85)

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

local function refreshModal(): ()
	local modal = currentModal
	if modal then
		modal.OnRefresh()
	end
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
				popTween(pop, 1.05)
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
	addCorner(frame, 18)
	addStroke(frame, THEME.PanelStroke, 2)
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
	addCorner(icon, 20)
	addPadding(icon, 10)

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

	local buyButton = makeBigButton({
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

local function getShopModal(): Modal?
	local refs = ui
	if not refs then
		return nil
	end
	return {
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
	}
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
			local hex = rarity.Color:ToHex()
			table.insert(names, string.format('<font color="#%s">%s</font> %s%%', hex, def.DisplayName, string.format("%.1f", (odds[critterId] or 0) * 100)))
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

local function getIslandModal(): Modal?
	local refs = ui
	if not refs then
		return nil
	end
	return {
		Frame = refs.Island.Frame,
		Pop = refs.Island.Pop,
		IsInRange = function(): boolean
			local islandId = currentIslandId
			return isNearTagged(IslandConfig.Gate.Tag, IslandConfig.Gate.ClientAutoCloseDistance, function(gate: Instance): boolean
				return gate:GetAttribute(IslandConfig.Gate.IdAttribute) == islandId
			end)
		end,
		FirstSelectable = function(): GuiObject?
			return refs.Island.ConfirmButton
		end,
		OnRefresh = renderIslandDialog,
	}
end

function UIController.OpenIslandDialog(islandId: string): ()
	if not IslandConfig.Get(islandId) then
		return
	end
	local modal = getIslandModal()
	if modal then
		openModal(modal)
		currentIslandId = islandId
		renderIslandDialog()
	end
end

function UIController.OpenShop(): ()
	local modal = getShopModal()
	if modal then
		openModal(modal)
	end
end

UIController.CloseModal = closeModal

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
		local rootPosition = getRootPosition()
		if success and rootPosition and typeof(result.Gained) == "number" then
			EffectsController.Burst(rootPosition, Color3.fromRGB(255, 215, 70), 40)
			EffectsController.FloatText(rootPosition + Vector3.new(0, 4, 0), "+" .. NumberFormat.Abbreviate(result.Gained) .. " ✨", Color3.fromRGB(255, 215, 70), true)
		end
	else
		showToast("Koneksi bermasalah, coba lagi ya.", false)
	end
end

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

local function buildIslandDialog(parent: Instance): IslandDialogRefs
	local frame, pop = makeModalFrame("IslandDialog", Vector2.new(600, 420), parent)

	local title: TextLabel = make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(24, 10),
		Size = UDim2.new(1, -120, 0, 60),
		BackgroundTransparency = 1,
		Text = "🏝️ Pulau",
		TextColor3 = THEME.Text,
		TextSize = 38,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

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

	local cancel = makeBigButton({
		Name = "Cancel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 24, 1, -20),
		Size = UDim2.new(0.5, -36, 0, 80),
		Color = THEME.Close,
		Text = "Batal",
		Parent = frame,
	})

	local confirm = makeBigButton({
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

	return { Frame = frame, Pop = pop, Title = title, Body = body, ConfirmButton = confirm, CancelButton = cancel }
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
		addCorner(frame, 22)
		addStroke(frame, THEME.PanelStroke, 3)
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
		addPadding(label, 10)
		return frame, label, pop
	end

	local _, essenceLabel, essencePop = hudPill("EssenceCounter", 250, 1)
	local bagFrame, bagLabel, bagPop = hudPill("BagCounter", 190, 2)

	-- Toko Upgrade
	local shopFrame, shopPop = makeModalFrame("UpgradeShop", Vector2.new(680, 470), gui)

	make("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(24, 10),
		Size = UDim2.new(1, -120, 0, 60),
		BackgroundTransparency = 1,
		Text = "🛠️ Toko Upgrade",
		TextColor3 = THEME.Text,
		TextSize = 38,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = shopFrame,
	})

	local shopClose = makeBigButton({
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(64, 64),
		Color = THEME.Close,
		Text = "✕",
		TextSize = 34,
		Parent = shopFrame,
	})
	shopClose.Activated:Connect(closeModal)

	local list: ScrollingFrame = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(16, 84),
		Size = UDim2.new(1, -32, 1, -100),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 10,
		ScrollBarImageColor3 = THEME.PanelStroke,
		Selectable = false,
		Parent = shopFrame,
	})
	make("UIListLayout", {
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Parent = list,
	})
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = list })

	local cards: { [string]: CardRefs } = {}
	for _, upgradeId in UpgradeConfig.Order do
		local def = UpgradeConfig.Get(upgradeId)
		if def then
			cards[upgradeId] = buildCard(def, list)
		end
	end

	-- Dialog pulau
	local island = buildIslandDialog(gui)

	-- Toast (bawah tengah)
	local toast: TextLabel = make("TextLabel", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(580, 60),
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
	addCorner(toast, 18)
	addPadding(toast, 8)

	return {
		Gui = gui,
		RootScale = rootScale,
		EssenceLabel = essenceLabel,
		EssencePop = essencePop,
		BagFrame = bagFrame,
		BagLabel = bagLabel,
		BagPop = bagPop,
		ShopFrame = shopFrame,
		ShopPop = shopPop,
		ShopClose = shopClose,
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

	StateController.LoadFailed:Connect(function()
		showToast("Gagal memuat data. Coba bergabung ulang ya.", false)
	end)

	-- Semua ProximityPrompt game ini diarahkan dari sini
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggeringPlayer: Player)
		if triggeringPlayer ~= localPlayer then
			return
		end
		if prompt.Name == UpgradeConfig.Shop.PromptName then
			UIController.OpenShop()
		elseif prompt.Name == CritterConfig.Deposit.PromptName then
			task.spawn(requestDeposit)
		elseif prompt.Name == IslandConfig.Gate.PromptName then
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
