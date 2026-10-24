--!strict
--[[
	UIController
	------------
	Tahap 1: HUD saldo Essence + UI Toko Upgrade.

	Prinsip:
	  • Client TIDAK pernah menentukan saldo/level. Semua nilai datang dari server
	    (snapshot GetInitialState + event EssenceChanged / UpgradeChanged).
	  • Setiap update membawa nomor revisi; update yang lebih lama dari yang sudah diterima diabaikan,
	    sehingga urutan tiba snapshot vs event tidak membuat UI menampilkan angka usang.
	  • UI dibuat lewat kode (tidak perlu menyusun ScreenGui manual) dan diskalakan otomatis
	    untuk HP, tablet, PC, dan konsol. Tombol besar, mendukung mouse, touch, dan gamepad.
	  • Toko dibuka lewat ProximityPrompt di objek ber-tag "UpgradeShop".
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
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)

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
	NextValue = "#2E9E50",
}

local REFERENCE_SIZE = Vector2.new(1000, 560) -- resolusi acuan desain
local MIN_SCALE = 0.65 -- batas bawah agar tombol tetap besar di HP
local MAX_SCALE = 1.35
local TOAST_DURATION = 2.5
local AUTO_CLOSE_CHECK_INTERVAL = 0.5
local SNAPSHOT_MAX_ATTEMPTS = 10
local CLOSE_ACTION_NAME = "SkyIsland_CloseShop"

---------------------------------------------------------------------
-- State client (cerminan dari server, hanya untuk tampilan)
---------------------------------------------------------------------

local state = {
	Loaded = false,
	Essence = 0,
	EssenceRevision = -1,
	Upgrades = {} :: { [string]: number },
	UpgradeRevisions = {} :: { [string]: number },
	PendingPurchase = false,
	ShopOpen = false,
}

type CardRefs = {
	Frame: Frame,
	Level: TextLabel,
	Stats: TextLabel,
	BuyButton: TextButton,
}

type UiRefs = {
	Gui: ScreenGui,
	RootScale: UIScale,
	EssenceLabel: TextLabel,
	EssencePop: UIScale,
	ShopFrame: Frame,
	ShopPop: UIScale,
	CloseButton: TextButton,
	List: ScrollingFrame,
	Toast: TextLabel,
	Cards: { [string]: CardRefs },
}

local ui: UiRefs? = nil
local purchaseRemote: RemoteFunction? = nil
local toastToken = 0

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

---------------------------------------------------------------------
-- Pesan singkat (toast)
---------------------------------------------------------------------

local function showToast(message: string, positive: boolean): ()
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

---------------------------------------------------------------------
-- Render
---------------------------------------------------------------------

local function getLevel(upgradeId: string): number
	return state.Upgrades[upgradeId] or UpgradeConfig.StartLevel
end

local function renderEssence(animate: boolean): ()
	local refs = ui
	if not refs then
		return
	end
	refs.EssenceLabel.Text = "✨ " .. NumberFormat.Abbreviate(state.Essence)
	if animate then
		popTween(refs.EssencePop, 1.15)
	end
end

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

	for _, upgradeId in UpgradeConfig.Order do
		local card = refs.Cards[upgradeId]
		local def = UpgradeConfig.Get(upgradeId)
		if card and def then
			local level = getLevel(upgradeId)
			local cost = UpgradeConfig.GetCost(upgradeId, level)
			local isMax = cost == nil

			card.Level.Text = string.format("Level %d / %d", level, def.MaxLevel)
			card.Stats.Text = buildStatsText(def, level, isMax)

			local button = card.BuyButton
			if not state.Loaded then
				button.Text = "Memuat..."
				button.BackgroundColor3 = THEME.CannotAfford
			elseif cost == nil then
				button.Text = "MAKS ⭐"
				button.BackgroundColor3 = THEME.Max
			elseif state.PendingPurchase then
				button.Text = "..."
				button.BackgroundColor3 = THEME.CannotAfford
			elseif state.Essence >= cost then
				button.Text = "⬆ " .. NumberFormat.Abbreviate(cost) .. " ✨"
				button.BackgroundColor3 = THEME.Buy
			else
				button.Text = "Butuh " .. NumberFormat.Abbreviate(cost) .. " ✨"
				button.BackgroundColor3 = THEME.CannotAfford
			end
		end
	end
end

---------------------------------------------------------------------
-- Pembelian
---------------------------------------------------------------------

local function requestPurchase(upgradeId: string): ()
	local remote = purchaseRemote
	if not remote or state.PendingPurchase or not state.Loaded then
		return
	end

	-- Cek awal di client hanya untuk pesan yang ramah; server tetap memvalidasi ulang semuanya
	local cost = UpgradeConfig.GetCost(upgradeId, getLevel(upgradeId))
	if cost == nil then
		showToast("Sudah level maksimum! ⭐", true)
		return
	end
	if state.Essence < cost then
		showToast("Kurang " .. NumberFormat.Abbreviate(cost - state.Essence) .. " ✨ lagi. Ayo kumpulkan Essence!", false)
		return
	end

	state.PendingPurchase = true
	renderShop()

	local ok, result = pcall(function(): any
		return remote:InvokeServer(upgradeId)
	end)

	state.PendingPurchase = false

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

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

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

	local buyButton: TextButton = make("TextButton", {
		Name = "BuyButton",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(200, 84),
		BackgroundColor3 = THEME.CannotAfford,
		Text = "Memuat...",
		TextColor3 = THEME.TextLight,
		TextSize = 26,
		TextWrapped = true,
		Font = THEME.Font,
		AutoButtonColor = true,
		Selectable = true,
		Parent = frame,
	})
	addCorner(buyButton, 18)
	make("UIStroke", {
		Color = Color3.fromRGB(40, 60, 90),
		Thickness = 2,
		Transparency = 0.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = buyButton,
	})

	-- Activated berlaku untuk klik mouse, tap layar sentuh, dan tombol A gamepad
	buyButton.Activated:Connect(function()
		requestPurchase(def.Id)
	end)

	return { Frame = frame, Level = level, Stats = stats, BuyButton = buyButton }
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

	-- HUD saldo Essence (atas tengah)
	local essenceFrame: Frame = make("Frame", {
		Name = "EssenceCounter",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(260, 64),
		BackgroundColor3 = THEME.HudBackground,
		BackgroundTransparency = 0.15,
		Parent = gui,
	})
	addCorner(essenceFrame, 22)
	addStroke(essenceFrame, THEME.PanelStroke, 3)
	local essencePop: UIScale = make("UIScale", { Parent = essenceFrame })

	local essenceLabel: TextLabel = make("TextLabel", {
		Name = "Amount",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "✨ ...",
		TextColor3 = THEME.TextLight,
		TextScaled = true,
		Font = THEME.Font,
		Parent = essenceFrame,
	})
	addPadding(essenceLabel, 10)

	-- Panel Toko Upgrade (tengah layar)
	local shopFrame: Frame = make("Frame", {
		Name = "UpgradeShop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.53),
		Size = UDim2.fromOffset(680, 470),
		BackgroundColor3 = THEME.Panel,
		Visible = false,
		Parent = gui,
	})
	addCorner(shopFrame, 26)
	addStroke(shopFrame, THEME.PanelStroke, 4)
	local shopPop: UIScale = make("UIScale", { Parent = shopFrame })

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

	local closeButton: TextButton = make("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(64, 64),
		BackgroundColor3 = THEME.Close,
		Text = "✕",
		TextColor3 = THEME.TextLight,
		TextSize = 34,
		Font = THEME.Font,
		Selectable = true,
		Parent = shopFrame,
	})
	addCorner(closeButton, 18)

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

	-- Toast (bawah tengah)
	local toast: TextLabel = make("TextLabel", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(560, 60),
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
		ShopFrame = shopFrame,
		ShopPop = shopPop,
		CloseButton = closeButton,
		List = list,
		Toast = toast,
		Cards = cards,
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
-- Buka / tutup toko
---------------------------------------------------------------------

local function isNearShop(): boolean
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	for _, instance in CollectionService:GetTagged(UpgradeConfig.Shop.Tag) do
		local position: Vector3? = nil
		if instance:IsA("BasePart") then
			position = instance.Position
		elseif instance:IsA("Model") then
			position = instance:GetPivot().Position
		end
		if position and (position - root.Position).Magnitude <= UpgradeConfig.Shop.ClientAutoCloseDistance then
			return true
		end
	end
	return false
end

local function closeShop(): ()
	local refs = ui
	if not refs or not state.ShopOpen then
		return
	end
	state.ShopOpen = false
	refs.ShopFrame.Visible = false
	ContextActionService:UnbindAction(CLOSE_ACTION_NAME)
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(refs.ShopFrame) then
		GuiService.SelectedObject = nil
	end
end

local function openShop(): ()
	local refs = ui
	if not refs or state.ShopOpen then
		return
	end
	state.ShopOpen = true
	renderShop()
	refs.ShopFrame.Visible = true
	popTween(refs.ShopPop, 0.85)

	-- Tombol B pada gamepad menutup toko
	ContextActionService:BindActionAtPriority(CLOSE_ACTION_NAME, function(_name: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
		if inputState == Enum.UserInputState.Begin then
			closeShop()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonB)

	-- Pemain gamepad langsung diarahkan ke tombol beli pertama
	if UserInputService.GamepadEnabled then
		local firstId = UpgradeConfig.Order[1]
		local firstCard = firstId and refs.Cards[firstId]
		if firstCard then
			GuiService.SelectedObject = firstCard.BuyButton
		end
	end
end

---------------------------------------------------------------------
-- Sinkronisasi state dari server
---------------------------------------------------------------------

local function applyEssence(balance: number, revision: number, animate: boolean): ()
	if revision < state.EssenceRevision then
		return -- update usang
	end
	state.EssenceRevision = revision
	state.Essence = balance
	renderEssence(animate)
end

local function applyUpgrade(upgradeId: string, level: number, revision: number): ()
	if revision < (state.UpgradeRevisions[upgradeId] or -1) then
		return
	end
	state.UpgradeRevisions[upgradeId] = revision
	state.Upgrades[upgradeId] = level
end

local function applySnapshot(snapshot: any): boolean
	if type(snapshot) ~= "table" or snapshot.Loaded ~= true then
		return false
	end
	if typeof(snapshot.Essence) ~= "number" or typeof(snapshot.Revision) ~= "number" or type(snapshot.Upgrades) ~= "table" then
		return false
	end

	applyEssence(snapshot.Essence, snapshot.Revision, false)
	for upgradeId, level in snapshot.Upgrades do
		if typeof(upgradeId) == "string" and typeof(level) == "number" then
			applyUpgrade(upgradeId, level, snapshot.Revision)
		end
	end
	state.Loaded = true
	renderShop()
	return true
end

local function loadInitialState(): ()
	local remote = Net.Function(Net.Functions.GetInitialState)
	for attempt = 1, SNAPSHOT_MAX_ATTEMPTS do
		local ok, snapshot = pcall(function(): any
			return remote:InvokeServer()
		end)
		if ok and applySnapshot(snapshot) then
			return
		end
		task.wait(math.min(2 * attempt, 6))
	end
	showToast("Gagal memuat data. Coba bergabung ulang ya.", false)
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function UIController.Init(): ()
	local refs = buildUi()
	ui = refs
	purchaseRemote = Net.Function(Net.Functions.PurchaseUpgrade)

	refs.CloseButton.Activated:Connect(closeShop)

	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	Net.Event(Net.Events.EssenceChanged).OnClientEvent:Connect(function(balance: any, delta: any, _reason: any, revision: any)
		if typeof(balance) ~= "number" or typeof(revision) ~= "number" then
			return
		end
		applyEssence(balance, revision, typeof(delta) == "number" and delta > 0)
		if state.ShopOpen then
			renderShop()
		end
	end)

	Net.Event(Net.Events.UpgradeChanged).OnClientEvent:Connect(function(upgradeId: any, level: any, revision: any)
		if typeof(upgradeId) ~= "string" or typeof(level) ~= "number" or typeof(revision) ~= "number" then
			return
		end
		applyUpgrade(upgradeId, level, revision)
		if state.ShopOpen then
			renderShop()
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggeringPlayer: Player)
		if triggeringPlayer == localPlayer and prompt.Name == UpgradeConfig.Shop.PromptName then
			openShop()
		end
	end)
end

function UIController.Start(): ()
	-- Tutup toko otomatis jika pemain berjalan menjauh
	task.spawn(function()
		while true do
			task.wait(AUTO_CLOSE_CHECK_INTERVAL)
			if state.ShopOpen and not isNearShop() then
				closeShop()
				showToast("Toko ditutup karena kamu menjauh.", true)
			end
		end
	end)

	loadInitialState()
end

-- Dipakai controller lain di tahap berikutnya (mis. tombol HUD)
UIController.OpenShop = openShop
UIController.CloseShop = closeShop

return UIController
