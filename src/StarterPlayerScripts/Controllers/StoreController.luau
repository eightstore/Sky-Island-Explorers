--!strict
--[[
	StoreController
	---------------
	Toko Spesial ⭐ (tombol HUD, bisa dibuka di mana saja):
	  • Tab Gamepass: tiap perk punya DUA jalan: Robux (gamepass) ATAU Essence (gratis, lebih lama).
	  • Tab Item: Ramuan Hoki (Robux / Essence), Kantong Essence (Robux), Pulihkan Streak (Robux / Essence).
	  • Tidak ada timer palsu, diskon "terbatas", atau pop-up yang muncul sendiri.

	Juga:
	  • Indikator 🍀 luck aktif (sisa waktu nyata Ramuan Hoki).
	  • Menu Teleport Pulau 🌀 (muncul jika punya perk Teleport Pulau).

	Gamepass dibuka lewat MarketplaceService:PromptGamePassPurchase di client; server menangani
	PromptGamePassPurchaseFinished. Developer Product diminta lewat remote agar server memeriksa
	syarat dulu, lalu server yang membuka prompt.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)

local THEME = UIKit.THEME
local make = UIKit.Make
local ATTR = ProductConfig.Attributes

local localPlayer = Players.LocalPlayer

local StoreController = {}

type StoreRefs = {
	Frame: Frame,
	Pop: UIScale,
	PassTab: TextButton,
	ItemTab: TextButton,
	List: ScrollingFrame,
}

type TeleportRefs = {
	Frame: Frame,
	Pop: UIScale,
	List: ScrollingFrame,
}

local store: StoreRefs? = nil
local teleport: TeleportRefs? = nil
local teleportButton: TextButton? = nil
local luckLabel: TextLabel? = nil
local currentTab = "Pass"
local pending = false
local robuxPrices: { [string]: string } = {} -- key -> "R$ 99"

local productRemote: RemoteFunction? = nil
local essenceRemote: RemoteFunction? = nil
local teleportRemote: RemoteFunction? = nil

---------------------------------------------------------------------
-- Helper
---------------------------------------------------------------------

local function invoke(remote: RemoteFunction?, ...: any): ()
	if not remote or pending then
		return
	end
	pending = true
	local args = table.pack(...)
	local ok, result = pcall(function(): any
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	pending = false
	if ok and type(result) == "table" and type(result.Message) == "string" then
		UIController.ShowToast(result.Message, result.Success == true)
	else
		UIController.ShowToast("Koneksi bermasalah, coba lagi ya.", false)
	end
end

local function formatDuration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

-- Mengambil harga Robux asli dari Roblox (sekali, di-cache)
local function fetchPrices(): ()
	for key, pass in ProductConfig.GamePasses do
		if pass.PassId ~= 0 then
			local ok, info = pcall(function(): any
				return MarketplaceService:GetProductInfo(pass.PassId, Enum.InfoType.GamePass)
			end)
			if ok and type(info) == "table" and typeof(info.PriceInRobux) == "number" then
				robuxPrices[key] = "R$ " .. tostring(info.PriceInRobux)
			end
		end
	end
	for key, product in ProductConfig.Products do
		if product.ProductId ~= 0 then
			local ok, info = pcall(function(): any
				return MarketplaceService:GetProductInfo(product.ProductId, Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" and typeof(info.PriceInRobux) == "number" then
				robuxPrices[key] = "R$ " .. tostring(info.PriceInRobux)
			end
		end
	end
end

---------------------------------------------------------------------
-- Baris toko
---------------------------------------------------------------------

type RowOptions = {
	Order: number,
	Icon: string,
	Title: string,
	Description: string,
	Owned: boolean,
	RobuxText: string?, -- nil = tidak ada tombol Robux
	RobuxEnabled: boolean,
	OnRobux: (() -> ())?,
	EssencePrice: number?, -- nil = tidak ada tombol essence
	EssenceEnabled: boolean,
	OnEssence: (() -> ())?,
}

local function makeRow(parent: Instance, options: RowOptions): ()
	local row: Frame = make("Frame", {
		Size = UDim2.new(1, -12, 0, 104),
		BackgroundColor3 = THEME.Card,
		LayoutOrder = options.Order,
		Parent = parent,
	})
	UIKit.Corner(row, 18)
	UIKit.Stroke(row, if options.Owned then THEME.Buy else THEME.PanelStroke, 2)

	local icon: TextLabel = make("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(72, 72),
		BackgroundColor3 = THEME.IconBackground,
		Text = options.Icon,
		TextScaled = true,
		Font = THEME.Font,
		Parent = row,
	})
	UIKit.Corner(icon, 18)
	UIKit.Padding(icon, 8)

	make("TextLabel", {
		Position = UDim2.fromOffset(96, 10),
		Size = UDim2.new(1, -370, 0, 32),
		BackgroundTransparency = 1,
		Text = options.Title .. (if options.Owned then "  ✔" else ""),
		TextColor3 = THEME.Text,
		TextSize = 24,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	})
	make("TextLabel", {
		Position = UDim2.fromOffset(96, 44),
		Size = UDim2.new(1, -370, 0, 52),
		BackgroundTransparency = 1,
		Text = options.Description,
		TextColor3 = THEME.TextMuted,
		TextSize = 18,
		TextWrapped = true,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = row,
	})

	if options.Owned then
		make("TextLabel", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -16, 0.5, 0),
			Size = UDim2.fromOffset(250, 60),
			BackgroundTransparency = 1,
			Text = "Sudah dimiliki ✔",
			TextColor3 = THEME.Buy,
			TextSize = 24,
			Font = THEME.Font,
			Parent = row,
		})
		return
	end

	-- Dua tombol bertumpuk: Robux (atas), Essence (bawah)
	local robuxText = options.RobuxText
	local onRobux = options.OnRobux
	if robuxText and onRobux then
		local robux = UIKit.BigButton({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 8),
			Size = UDim2.fromOffset(250, 42),
			Color = if options.RobuxEnabled then THEME.Buy else THEME.CannotAfford,
			Text = robuxText,
			TextSize = 20,
			Radius = 12,
			Parent = row,
		})
		robux.Activated:Connect(onRobux)
	end
	local essencePrice = options.EssencePrice
	local onEssence = options.OnEssence
	if essencePrice and onEssence then
		local essence = UIKit.BigButton({
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -12, 1, -8),
			Size = UDim2.fromOffset(250, 42),
			Color = if options.EssenceEnabled then THEME.Action else THEME.CannotAfford,
			Text = "Gratis: " .. NumberFormat.Abbreviate(essencePrice) .. " ✨",
			TextSize = 20,
			Radius = 12,
			Parent = row,
		})
		essence.Activated:Connect(onEssence)
	end
end

local function renderStore(): ()
	local refs = store
	if not refs then
		return
	end
	refs.PassTab.BackgroundColor3 = if currentTab == "Pass" then THEME.Action else THEME.CannotAfford
	refs.ItemTab.BackgroundColor3 = if currentTab == "Item" then THEME.Action else THEME.CannotAfford
	UIKit.ClearList(refs.List)

	local essence = StateController.GetEssence()

	-- Catatan kejujuran untuk pemain & orang tua
	make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 30),
		BackgroundTransparency = 1,
		Text = "💙 Semua perk & ramuan bisa didapat GRATIS dengan Essence. Robux hanya mempercepat.",
		TextColor3 = THEME.TextMuted,
		TextSize = 17,
		TextWrapped = true,
		Font = THEME.Font,
		LayoutOrder = 0,
		Parent = refs.List,
	})

	if currentTab == "Pass" then
		for index, key in ProductConfig.PassOrder do
			local pass = ProductConfig.GamePasses[key]
			makeRow(refs.List, {
				Order = index,
				Icon = pass.Icon,
				Title = pass.DisplayName,
				Description = pass.Description,
				Owned = StateController.HasPerk(key),
				RobuxText = if pass.PassId == 0 then "Segera hadir" else (robuxPrices[key] or "Beli (Robux)"),
				RobuxEnabled = pass.PassId ~= 0,
				OnRobux = function()
					if pass.PassId == 0 then
						UIController.ShowToast("Gamepass ini belum tersedia.", false)
						return
					end
					MarketplaceService:PromptGamePassPurchase(localPlayer, pass.PassId)
				end,
				EssencePrice = pass.EssencePrice,
				EssenceEnabled = essence >= pass.EssencePrice,
				OnEssence = function()
					if essence < pass.EssencePrice then
						UIController.ShowToast("Kurang " .. NumberFormat.Abbreviate(pass.EssencePrice - essence) .. " ✨ lagi. Terus bermain ya!", false)
						return
					end
					invoke(essenceRemote, key)
				end,
			})
		end
		return
	end

	-- Tab Item
	local revivable = StateController.GetNumberAttribute(ATTR.RevivableStreak)
	for index, key in ProductConfig.ProductOrder do
		local product = ProductConfig.Products[key]
		if key ~= "InstantHatch" then -- Tetas Instan ada di jendela inkubator
			local description = product.Description
			local available = true
			if key == "ReviveStreak" then
				available = revivable > 0
				description = if available
					then string.format("Streak %d hari-mu putus. Pulihkan sekarang! (Streak saat ini: %d)", revivable, StateController.GetNumberAttribute(ATTR.LoginStreak))
					else "Tidak ada streak yang putus. Streak saat ini: " .. StateController.GetNumberAttribute(ATTR.LoginStreak) .. " hari 🔥"
			end
			local essencePrice = product.EssencePrice
			makeRow(refs.List, {
				Order = index,
				Icon = product.Icon,
				Title = product.DisplayName,
				Description = description,
				Owned = false,
				RobuxText = if product.ProductId == 0 then "Segera hadir" else (robuxPrices[key] or "Beli (Robux)"),
				RobuxEnabled = product.ProductId ~= 0 and available,
				OnRobux = function()
					invoke(productRemote, key)
				end,
				EssencePrice = essencePrice,
				EssenceEnabled = available and essencePrice ~= nil and essence >= essencePrice,
				OnEssence = if essencePrice
					then function()
						invoke(essenceRemote, key)
					end
					else nil,
			})
		end
	end
end

function StoreController.Open(tab: string?): ()
	local refs = store
	if not refs then
		return
	end
	if tab then
		currentTab = tab
	end
	UIController.OpenModal({
		Frame = refs.Frame,
		Pop = refs.Pop,
		IsInRange = function(): boolean
			return true
		end,
		FirstSelectable = function(): GuiObject?
			return refs.PassTab
		end,
		OnRefresh = renderStore,
	})
end

---------------------------------------------------------------------
-- Teleport Pulau
---------------------------------------------------------------------

local function renderTeleport(): ()
	local refs = teleport
	if not refs then
		return
	end
	UIKit.ClearList(refs.List)
	for index, island in IslandConfig.Islands do
		local unlocked = StateController.IsIslandUnlocked(island.Id)
		local button = UIKit.BigButton({
			Name = island.Id,
			Size = UDim2.new(1, -12, 0, 68),
			Color = if unlocked then island.Color else THEME.CannotAfford,
			Text = (if unlocked then "🌀 " else "🔒 ") .. island.DisplayName,
			TextSize = 24,
			LayoutOrder = index,
			Parent = refs.List,
		})
		button.TextColor3 = if unlocked then THEME.Text else THEME.TextLight
		button.Activated:Connect(function()
			if not unlocked then
				UIController.ShowToast("Buka " .. island.DisplayName .. " dulu.", false)
				return
			end
			UIController.CloseModal()
			invoke(teleportRemote, island.Id)
		end)
	end
end

local function openTeleport(): ()
	local refs = teleport
	if not refs then
		return
	end
	UIController.OpenModal({
		Frame = refs.Frame,
		Pop = refs.Pop,
		IsInRange = function(): boolean
			return true
		end,
		FirstSelectable = function(): GuiObject?
			return refs.List:FindFirstChildWhichIsA("TextButton")
		end,
		OnRefresh = renderTeleport,
	})
end

---------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------

local function renderHud(): ()
	local button = teleportButton
	if button then
		button.Visible = StateController.HasPerk("IslandTeleport")
	end
	local label = luckLabel
	if label then
		local multiplier = StateController.GetLuckMultiplier()
		local remaining = StateController.GetLuckBoostRemaining()
		label.Visible = multiplier > 1
		if remaining > 0 then
			label.Text = string.format("🍀 Luck x%s · 🧪 %s", tostring(multiplier), formatDuration(remaining))
		else
			label.Text = string.format("🍀 Luck x%s", tostring(multiplier))
		end
	end
end

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

local function buildStore(gui: ScreenGui): StoreRefs
	local frame, pop = UIKit.ModalFrame("SpecialStore", Vector2.new(820, 520), gui)
	UIKit.Title(frame, "⭐ Toko Spesial")
	UIKit.CloseButton(frame, UIController.CloseModal)

	local passTab = UIKit.BigButton({
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(0.5, -24, 0, 56),
		Color = THEME.Action,
		Text = "Gamepass",
		TextSize = 22,
		Radius = 14,
		Parent = frame,
	})
	local itemTab = UIKit.BigButton({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 80),
		Size = UDim2.new(0.5, -24, 0, 56),
		Color = THEME.CannotAfford,
		Text = "Item",
		TextSize = 22,
		Radius = 14,
		Parent = frame,
	})
	passTab.Activated:Connect(function()
		currentTab = "Pass"
		renderStore()
	end)
	itemTab.Activated:Connect(function()
		currentTab = "Item"
		renderStore()
	end)

	local list = UIKit.ScrollList(frame, UDim2.fromOffset(16, 146), UDim2.new(1, -32, 1, -162), 10)
	return { Frame = frame, Pop = pop, PassTab = passTab, ItemTab = itemTab, List = list }
end

local function buildTeleport(gui: ScreenGui): TeleportRefs
	local frame, pop = UIKit.ModalFrame("TeleportMenu", Vector2.new(480, 480), gui)
	UIKit.Title(frame, "🌀 Teleport Pulau")
	UIKit.CloseButton(frame, UIController.CloseModal)
	local list = UIKit.ScrollList(frame, UDim2.fromOffset(16, 84), UDim2.new(1, -32, 1, -100), 10)
	return { Frame = frame, Pop = pop, List = list }
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function StoreController.Init(): ()
	productRemote = Net.Function(Net.Functions.RequestProductPurchase)
	essenceRemote = Net.Function(Net.Functions.BuyWithEssence)
	teleportRemote = Net.Function(Net.Functions.TeleportToIsland)

	local gui = UIController.GetGui()
	store = buildStore(gui)
	teleport = buildTeleport(gui)

	UIController.AddHudButton("StoreButton", "⭐", "Toko", 4, function()
		StoreController.Open(nil)
	end)
	teleportButton = UIController.AddHudButton("TeleportButton", "🌀", "Teleport", 5, openTeleport)

	-- Indikator luck di bawah HUD atas
	local label: TextLabel = make("TextLabel", {
		Name = "LuckIndicator",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 84),
		Size = UDim2.fromOffset(300, 40),
		BackgroundColor3 = Color3.fromRGB(60, 150, 80),
		BackgroundTransparency = 0.1,
		Text = "",
		TextColor3 = THEME.TextLight,
		TextSize = 22,
		Font = THEME.Font,
		Visible = false,
		Parent = gui,
	})
	UIKit.Corner(label, 14)
	luckLabel = label

	StateController.Changed:Connect(function(key: string)
		if key == "Attributes" or key == "Loaded" then
			renderHud()
		end
	end)

	-- Gamepass dibeli: segarkan toko (atribut perk akan diperbarui server)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, _passId: number, purchased: boolean)
		if player == localPlayer and purchased then
			renderStore()
		end
	end)

	renderHud()
end

function StoreController.Start(): ()
	task.spawn(function()
		fetchPrices()
		renderStore()
	end)
	-- Sisa waktu Ramuan Hoki (waktu nyata)
	while true do
		renderHud()
		task.wait(1)
	end
end

return StoreController
