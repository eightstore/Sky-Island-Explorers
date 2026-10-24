--!strict
--[[
	EggController
	-------------
	UI telur di client:
	  • Toko Telur (ProximityPrompt di objek ber-tag EggShop): daftar telur, dan untuk telur
	    yang dipilih: PELUANG SETIAP CRITTER (%) + peluang shiny ditampilkan SEBELUM membeli.
	  • Tombol HUD 🥚 menampilkan status inkubator (sisa waktu nyata / "Buka!").
	  • Jendela inkubator: progres, tombol "Buka Telur", dan opsi Tetas Instan (Robux) —
	    tanpa membeli pun telur tetap menetas saat waktunya habis.
	  • Animasi buka telur: diputar SETELAH server mengirim hasil undian (server menentukan isi).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Net = require(ReplicatedStorage.Shared.Net)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local UIKit = require(script.Parent.Parent.UI.UIKit)
local StateController = require(script.Parent.StateController)
local UIController = require(script.Parent.UIController)
local EffectsController = require(script.Parent.EffectsController)

local THEME = UIKit.THEME
local make = UIKit.Make

local EggController = {}

local HUD_UPDATE_INTERVAL = 0.5

type ShopRefs = {
	Frame: Frame,
	Pop: UIScale,
	EggButtons: { [string]: TextButton },
	DetailTitle: TextLabel,
	DetailInfo: TextLabel,
	OddsList: ScrollingFrame,
	ShinyInfo: TextLabel,
	BuyButton: TextButton,
}

type IncubatorRefs = {
	Frame: Frame,
	Pop: UIScale,
	Title: TextLabel,
	Status: TextLabel,
	BarFill: Frame,
	HatchButton: TextButton,
	InstantButton: TextButton,
}

type RevealRefs = {
	Overlay: Frame,
	Egg: Frame,
	EggRotation: UIScale,
	Card: Frame,
	CardCircle: Frame,
	CardName: TextLabel,
	CardRarity: TextLabel,
	CardNote: TextLabel,
}

local shop: ShopRefs? = nil
local incubator: IncubatorRefs? = nil
local reveal: RevealRefs? = nil
local hudButton: TextButton? = nil
local selectedEggId = EggConfig.Order[1]
local pending = false
local instantPriceText = "R$ ?"
local revealToken = 0

local buyRemote: RemoteFunction? = nil
local hatchRemote: RemoteFunction? = nil
local productRemote: RemoteFunction? = nil

---------------------------------------------------------------------
-- Helper
---------------------------------------------------------------------

local function formatChance(chance: number): string
	local percent = chance * 100
	if percent >= 10 then
		return string.format("%.0f%%", percent)
	elseif percent >= 1 then
		return string.format("%.1f%%", percent)
	end
	return string.format("%.2f%%", percent)
end

local function shinyText(): string
	local luck = StateController.GetLuckMultiplier()
	local base = CritterConfig.GetShinyChance(1)
	local current = CritterConfig.GetShinyChance(luck)
	if luck > 1 then
		return string.format("✨ Peluang Shiny: 1/%d → <b>1/%d</b> (luck kamu x%s)", math.floor(1 / base + 0.5), math.floor(1 / current + 0.5), tostring(luck))
	end
	return string.format("✨ Peluang Shiny: 1/%d", math.floor(1 / base + 0.5))
end

local function invoke(remote: RemoteFunction?, ...: any): any
	if not remote then
		return nil
	end
	local args = table.pack(...)
	local ok, result = pcall(function(): any
		return remote:InvokeServer(table.unpack(args, 1, args.n))
	end)
	if ok and type(result) == "table" and type(result.Message) == "string" then
		return result
	end
	UIController.ShowToast("Koneksi bermasalah, coba lagi ya.", false)
	return nil
end

---------------------------------------------------------------------
-- Animasi buka telur (hasil sudah ditentukan server)
---------------------------------------------------------------------

local function playReveal(eggId: string, critterId: string, shiny: boolean, isNew: boolean): ()
	local r = reveal
	if not r then
		return
	end
	local egg = EggConfig.Get(eggId)
	local def = CritterConfig.Get(critterId)
	local rarity = def and CritterConfig.GetRarity(def.Rarity)
	if not egg or not def or not rarity then
		return
	end

	UIController.CloseModal()
	revealToken += 1
	local myToken = revealToken
	r.Overlay.Visible = true
	r.Egg.Visible = true
	r.Egg.BackgroundColor3 = egg.Color
	r.Egg.Rotation = 0
	r.Card.Visible = false

	-- 1. Telur bergoyang makin kencang
	for i = 1, 6 do
		local angle = (if i % 2 == 0 then 1 else -1) * (6 + i * 3)
		local tween = TweenService:Create(r.Egg, TweenInfo.new(0.12 + 0.02 * (6 - i), Enum.EasingStyle.Sine), { Rotation = angle })
		tween:Play()
		tween.Completed:Wait()
	end
	-- 2. Membesar lalu pecah
	r.Egg.Rotation = 0
	local grow = TweenService:Create(r.EggRotation, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 1.3 })
	grow:Play()
	grow.Completed:Wait()
	r.Egg.Visible = false
	r.EggRotation.Scale = 1

	-- 3. Tampilkan hasil
	r.Card.Visible = true
	r.CardCircle.BackgroundColor3 = def.Color
	r.CardName.Text = (if shiny then "✨ " else "") .. def.DisplayName .. (if shiny then " ✨" else "")
	r.CardRarity.Text = (if shiny then "SHINY · " else "") .. rarity.DisplayName
	r.CardRarity.TextColor3 = if shiny then THEME.Gold else rarity.Color
	r.CardNote.Text = (if isNew then "Baru di Album! 📖  " else "") .. "Masuk ke tas 🎒  ·  Ketuk untuk menutup"
	local cardScale = r.Card:FindFirstChildOfClass("UIScale")
	if cardScale then
		UIKit.Pop(cardScale, 0.3)
	end

	local rootPosition = UIController.GetRootPosition()
	if rootPosition then
		EffectsController.Burst(rootPosition, rarity.Color, if shiny then 80 else 35)
		if shiny then
			EffectsController.Burst(rootPosition, THEME.Gold, 60)
		end
	end

	task.delay(4, function()
		if revealToken == myToken then
			r.Overlay.Visible = false
		end
	end)
end

---------------------------------------------------------------------
-- Aksi
---------------------------------------------------------------------

local function renderShop(): ()
	local refs = shop
	if not refs then
		return
	end
	local egg = EggConfig.Get(selectedEggId)
	if not egg then
		return
	end
	local island = IslandConfig.Get(egg.IslandId)
	local islandOpen = StateController.IsIslandUnlocked(egg.IslandId)

	for eggId, button in refs.EggButtons do
		local def = EggConfig.Get(eggId)
		if def then
			local open = StateController.IsIslandUnlocked(def.IslandId)
			button.BackgroundColor3 = if eggId == selectedEggId then def.Color else THEME.CannotAfford
			button.TextColor3 = if eggId == selectedEggId then THEME.Text else THEME.TextLight
			button.Text = (if open then "🥚 " else "🔒 ") .. def.DisplayName
		end
	end

	refs.DetailTitle.Text = "🥚 " .. egg.DisplayName
	refs.DetailInfo.Text = string.format("Harga: <b>%s ✨</b>  ·  Dierami: <b>%d detik</b>%s",
		NumberFormat.Abbreviate(egg.Price), egg.HatchTime,
		if islandOpen then "" else string.format('\n<font color="%s">🔒 Buka %s dulu</font>', THEME.NotOk, if island then island.DisplayName else egg.IslandId))

	-- Tabel peluang (sama persis dengan yang dipakai server)
	UIKit.ClearList(refs.OddsList)
	for index, odd in EggConfig.GetOdds(egg) do
		local def = CritterConfig.Get(odd.CritterId)
		local rarity = def and CritterConfig.GetRarity(def.Rarity)
		if def and rarity then
			local row: Frame = make("Frame", {
				Size = UDim2.new(1, -12, 0, 44),
				BackgroundColor3 = THEME.Card,
				LayoutOrder = index,
				Parent = refs.OddsList,
			})
			UIKit.Corner(row, 12)
			local dot: Frame = make("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 8, 0.5, 0),
				Size = UDim2.fromOffset(30, 30),
				BackgroundColor3 = def.Color,
				Parent = row,
			})
			UIKit.Corner(dot, 15)
			UIKit.Stroke(dot, rarity.Color, 3)
			make("TextLabel", {
				Position = UDim2.fromOffset(48, 0),
				Size = UDim2.new(1, -140, 1, 0),
				BackgroundTransparency = 1,
				RichText = true,
				Text = string.format('%s  <font color="#%s">%s</font>', def.DisplayName, rarity.Color:ToHex(), rarity.DisplayName),
				TextColor3 = THEME.Text,
				TextSize = 20,
				Font = THEME.Font,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			make("TextLabel", {
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -10, 0, 0),
				Size = UDim2.new(0, 80, 1, 0),
				BackgroundTransparency = 1,
				Text = formatChance(odd.Chance),
				TextColor3 = THEME.Text,
				TextSize = 22,
				Font = THEME.Font,
				TextXAlignment = Enum.TextXAlignment.Right,
				Parent = row,
			})
		end
	end

	refs.ShinyInfo.Text = shinyText()

	local incubatingEgg = StateController.GetIncubator()
	local button = refs.BuyButton
	if pending then
		button.Text = "..."
		button.BackgroundColor3 = THEME.CannotAfford
	elseif not islandOpen then
		button.Text = "Pulau terkunci 🔒"
		button.BackgroundColor3 = THEME.CannotAfford
	elseif incubatingEgg then
		button.Text = "Inkubator terisi 🥚"
		button.BackgroundColor3 = THEME.CannotAfford
	elseif StateController.GetEssence() >= egg.Price then
		button.Text = "Beli & Erami · " .. NumberFormat.Abbreviate(egg.Price) .. " ✨"
		button.BackgroundColor3 = THEME.Buy
	else
		button.Text = "Butuh " .. NumberFormat.Abbreviate(egg.Price) .. " ✨"
		button.BackgroundColor3 = THEME.CannotAfford
	end
end

local function buySelected(): ()
	if pending then
		return
	end
	local egg = EggConfig.Get(selectedEggId)
	if not egg then
		return
	end
	if StateController.GetIncubator() then
		UIController.ShowToast("Inkubator masih berisi telur. Buka dulu lewat tombol 🥚", false)
		return
	end
	if StateController.GetEssence() < egg.Price then
		UIController.ShowToast("Kurang " .. NumberFormat.Abbreviate(egg.Price - StateController.GetEssence()) .. " ✨ lagi.", false)
		return
	end
	pending = true
	renderShop()
	local result = invoke(buyRemote, egg.Id)
	pending = false
	if result then
		UIController.ShowToast(result.Message, result.Success == true)
	end
	renderShop()
end

local function hatch(): ()
	if pending then
		return
	end
	pending = true
	local result = invoke(hatchRemote)
	pending = false
	if not result then
		return
	end
	if result.Success == true and typeof(result.EggId) == "string" and typeof(result.CritterId) == "string" then
		task.spawn(playReveal, result.EggId, result.CritterId, result.Shiny == true, result.IsNew == true)
	else
		UIController.ShowToast(result.Message, false)
	end
end

local function requestInstantHatch(): ()
	local result = invoke(productRemote, "InstantHatch")
	if result and result.Success ~= true then
		UIController.ShowToast(result.Message, false)
	end
end

---------------------------------------------------------------------
-- Inkubator
---------------------------------------------------------------------

local function renderIncubator(): ()
	local refs = incubator
	if not refs then
		return
	end
	local eggId, remaining = StateController.GetIncubator()
	local egg = eggId and EggConfig.Get(eggId)
	if not egg then
		refs.Title.Text = "🥚 Inkubator kosong"
		refs.Status.Text = "Beli telur di Toko Telur untuk mulai mengerami."
		refs.BarFill.Size = UDim2.fromScale(0, 1)
		refs.HatchButton.Visible = false
		refs.InstantButton.Visible = false
		return
	end

	refs.Title.Text = "🥚 " .. egg.DisplayName
	local progress = if egg.HatchTime > 0 then 1 - remaining / egg.HatchTime else 1
	refs.BarFill.Size = UDim2.fromScale(math.clamp(progress, 0, 1), 1)
	refs.BarFill.BackgroundColor3 = egg.Color
	refs.HatchButton.Visible = true

	if remaining <= 0 then
		refs.Status.Text = "Telur siap dibuka! 🎉"
		refs.HatchButton.Text = if pending then "..." else "Buka Telur! 🐣"
		refs.HatchButton.BackgroundColor3 = THEME.Buy
		refs.InstantButton.Visible = false
	else
		refs.Status.Text = string.format("Menetas dalam %d detik. Kamu boleh menunggu sambil bermain 😊", math.ceil(remaining))
		refs.HatchButton.Text = "Belum siap"
		refs.HatchButton.BackgroundColor3 = THEME.CannotAfford
		local instant = ProductConfig.Products.InstantHatch
		refs.InstantButton.Visible = instant.ProductId ~= 0
		refs.InstantButton.Text = "⚡ Tetas Instan · " .. instantPriceText
	end
end

local function openIncubator(): ()
	local refs = incubator
	if not refs then
		return
	end
	UIController.OpenModal({
		Frame = refs.Frame,
		Pop = refs.Pop,
		IsInRange = function(): boolean
			return true -- telur boleh dibuka di mana saja
		end,
		FirstSelectable = function(): GuiObject?
			return refs.HatchButton
		end,
		OnRefresh = renderIncubator,
	})
end

local function renderHudButton(): ()
	local button = hudButton
	if not button then
		return
	end
	local eggId, remaining = StateController.GetIncubator()
	if not eggId then
		button.Text = "🥚\nTelur"
		button.BackgroundColor3 = THEME.HudBackground
	elseif remaining <= 0 then
		button.Text = "🐣\nBuka!"
		button.BackgroundColor3 = THEME.Buy
	else
		button.Text = string.format("🥚\n%ds", math.ceil(remaining))
		button.BackgroundColor3 = THEME.HudBackground
	end
end

---------------------------------------------------------------------
-- Membangun UI
---------------------------------------------------------------------

local function buildShop(gui: ScreenGui): ShopRefs
	local frame, pop = UIKit.ModalFrame("EggShop", Vector2.new(860, 520), gui)
	UIKit.Title(frame, "🥚 Toko Telur")
	UIKit.CloseButton(frame, UIController.CloseModal)

	-- Kiri: daftar telur
	local eggList = UIKit.ScrollList(frame, UDim2.fromOffset(16, 84), UDim2.new(0, 250, 1, -100), 10)
	local eggButtons: { [string]: TextButton } = {}
	for index, eggId in EggConfig.Order do
		local egg = EggConfig.Get(eggId)
		if egg then
			local button = UIKit.BigButton({
				Name = eggId,
				Size = UDim2.new(1, -12, 0, 70),
				Color = THEME.CannotAfford,
				Text = egg.DisplayName,
				TextSize = 20,
				LayoutOrder = index,
				Parent = eggList,
			})
			button.Activated:Connect(function()
				selectedEggId = eggId
				renderShop()
			end)
			eggButtons[eggId] = button
		end
	end

	-- Kanan: detail + peluang
	local detail: Frame = make("Frame", {
		Name = "Detail",
		Position = UDim2.fromOffset(282, 84),
		Size = UDim2.new(1, -298, 1, -100),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	local detailTitle: TextLabel = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = THEME.Text,
		TextSize = 30,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = detail,
	})
	local detailInfo: TextLabel = make("TextLabel", {
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		TextColor3 = THEME.TextMuted,
		TextSize = 20,
		TextWrapped = true,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = detail,
	})
	make("TextLabel", {
		Position = UDim2.fromOffset(0, 88),
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "📊 Peluang isi telur (dipakai server persis seperti ini):",
		TextColor3 = THEME.Text,
		TextSize = 19,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = detail,
	})
	local oddsList = UIKit.ScrollList(detail, UDim2.fromOffset(0, 116), UDim2.new(1, 0, 1, -236), 6)
	local shinyInfo: TextLabel = make("TextLabel", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -88),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Text = "",
		RichText = true,
		TextColor3 = THEME.TextMuted,
		TextSize = 19,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = detail,
	})
	local buyButton = UIKit.BigButton({
		Name = "Buy",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 78),
		Color = THEME.Buy,
		Text = "Beli",
		Parent = detail,
	})
	buyButton.Activated:Connect(buySelected)

	return {
		Frame = frame,
		Pop = pop,
		EggButtons = eggButtons,
		DetailTitle = detailTitle,
		DetailInfo = detailInfo,
		OddsList = oddsList,
		ShinyInfo = shinyInfo,
		BuyButton = buyButton,
	}
end

local function buildIncubator(gui: ScreenGui): IncubatorRefs
	local frame, pop = UIKit.ModalFrame("Incubator", Vector2.new(560, 360), gui)
	local title = UIKit.Title(frame, "🥚 Inkubator")
	UIKit.CloseButton(frame, UIController.CloseModal)

	local status: TextLabel = make("TextLabel", {
		Position = UDim2.fromOffset(28, 80),
		Size = UDim2.new(1, -56, 0, 56),
		BackgroundTransparency = 1,
		Text = "",
		TextColor3 = THEME.TextMuted,
		TextSize = 21,
		TextWrapped = true,
		Font = THEME.Font,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local bar: Frame = make("Frame", {
		Position = UDim2.fromOffset(28, 142),
		Size = UDim2.new(1, -56, 0, 26),
		BackgroundColor3 = Color3.fromRGB(210, 218, 232),
		Parent = frame,
	})
	UIKit.Corner(bar, 13)
	local fill: Frame = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = THEME.Buy, Parent = bar })
	UIKit.Corner(fill, 13)

	local hatchButton = UIKit.BigButton({
		Name = "Hatch",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 186),
		Size = UDim2.new(1, -56, 0, 72),
		Color = THEME.Buy,
		Text = "Buka Telur! 🐣",
		Parent = frame,
	})
	hatchButton.Activated:Connect(function()
		local _, remaining = StateController.GetIncubator()
		if remaining > 0 then
			UIController.ShowToast("Telur belum siap menetas. Sabar sebentar ya!", false)
			return
		end
		hatch()
	end)

	local instantButton = UIKit.BigButton({
		Name = "Instant",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 268),
		Size = UDim2.new(1, -56, 0, 64),
		Color = THEME.Action,
		Text = "⚡ Tetas Instan",
		TextSize = 22,
		Parent = frame,
	})
	instantButton.Activated:Connect(requestInstantHatch)

	return { Frame = frame, Pop = pop, Title = title, Status = status, BarFill = fill, HatchButton = hatchButton, InstantButton = instantButton }
end

local function buildReveal(gui: ScreenGui): RevealRefs
	local overlay: Frame = make("Frame", {
		Name = "EggReveal",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
		ZIndex = 20,
		Active = true,
		Parent = gui,
	})
	local egg: Frame = make("Frame", {
		Name = "Egg",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(180, 230),
		BackgroundColor3 = THEME.Panel,
		ZIndex = 21,
		Parent = overlay,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = egg })
	UIKit.Stroke(egg, Color3.new(1, 1, 1), 5)
	local eggScale: UIScale = make("UIScale", { Parent = egg })

	local card: Frame = make("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(420, 360),
		BackgroundColor3 = THEME.Panel,
		Visible = false,
		ZIndex = 21,
		Parent = overlay,
	})
	UIKit.Corner(card, 26)
	UIKit.Stroke(card, THEME.Gold, 4)
	make("UIScale", { Parent = card })
	local circle: Frame = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 24),
		Size = UDim2.fromOffset(140, 140),
		ZIndex = 22,
		Parent = card,
	})
	UIKit.Corner(circle, 70)
	local function cardLabel(y: number, height: number, size: number): TextLabel
		return make("TextLabel", {
			Position = UDim2.fromOffset(16, y),
			Size = UDim2.new(1, -32, 0, height),
			BackgroundTransparency = 1,
			Text = "",
			TextColor3 = THEME.Text,
			TextSize = size,
			TextWrapped = true,
			Font = THEME.Font,
			ZIndex = 22,
			Parent = card,
		})
	end
	local name = cardLabel(176, 44, 34)
	local rarity = cardLabel(222, 32, 26)
	local note = cardLabel(270, 70, 18)
	note.TextColor3 = THEME.TextMuted

	-- Ketuk di mana saja untuk menutup
	overlay.InputBegan:Connect(function(input: InputObject)
		if card.Visible and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonA) then
			overlay.Visible = false
		end
	end)

	return { Overlay = overlay, Egg = egg, EggRotation = eggScale, Card = card, CardCircle = circle, CardName = name, CardRarity = rarity, CardNote = note }
end

local function fetchInstantPrice(): ()
	local product = ProductConfig.Products.InstantHatch
	if product.ProductId == 0 then
		return
	end
	local ok, info = pcall(function(): any
		return MarketplaceService:GetProductInfo(product.ProductId, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" and typeof(info.PriceInRobux) == "number" then
		instantPriceText = "R$ " .. tostring(info.PriceInRobux)
	end
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function EggController.Init(): ()
	buyRemote = Net.Function(Net.Functions.BuyEgg)
	hatchRemote = Net.Function(Net.Functions.HatchEgg)
	productRemote = Net.Function(Net.Functions.RequestProductPurchase)

	local gui = UIController.GetGui()
	shop = buildShop(gui)
	incubator = buildIncubator(gui)
	reveal = buildReveal(gui)

	UIController.RegisterPrompt(EggConfig.Shop.PromptName, function()
		local refs = shop
		if not refs then
			return
		end
		UIController.OpenModal({
			Frame = refs.Frame,
			Pop = refs.Pop,
			IsInRange = function(): boolean
				return UIController.IsNearTagged(EggConfig.Shop.Tag, EggConfig.Shop.ClientAutoCloseDistance)
			end,
			FirstSelectable = function(): GuiObject?
				return refs.BuyButton
			end,
			OnRefresh = renderShop,
		})
	end)

	hudButton = UIController.AddHudButton("EggButton", "🥚", "Telur", 2, function()
		local eggId, remaining = StateController.GetIncubator()
		if eggId and remaining <= 0 then
			hatch()
		elseif eggId then
			openIncubator()
		else
			UIController.ShowToast("Inkubator kosong. Beli telur di Toko Telur 🥚", true)
		end
	end)
end

function EggController.Start(): ()
	task.spawn(fetchInstantPrice)
	-- Hitung mundur inkubator (waktu nyata dari server)
	while true do
		renderHudButton()
		if incubator and UIController.IsModalOpen(incubator.Frame) then
			renderIncubator()
		end
		task.wait(HUD_UPDATE_INTERVAL)
	end
end

return EggController
