--!strict
--[[
	MonetizationService
	-------------------
	Gamepass, Developer Product, dan JALUR GRATIS (essence) untuk semuanya.

	GAMEPASS / PERK
	  • Kepemilikan = punya gamepass (UserOwnsGamePassAsync, di-cache per sesi)
	                  ATAU sudah membuka perk yang sama dengan essence (data.OwnedPerks).
	  • PromptGamePassPurchaseFinished ditangani agar perk langsung aktif tanpa rejoin.
	  • Status perk direplikasi lewat atribut pemain "Perk_<Key>" (diisi server, tidak bisa dipalsukan).

	DEVELOPER PRODUCT (ProcessReceipt idempoten)
	  1. Pemain tidak ada / data belum siap      -> NotProcessedYet (Roblox akan mencoba lagi nanti)
	  2. PurchaseId sudah tercatat                -> pastikan tersimpan, lalu PurchaseGranted
	  3. Jalankan efek + catat PurchaseId dalam satu langkah tanpa yield (atomik)
	  4. Simpan ke DataStore SEKARANG; hanya jika berhasil -> PurchaseGranted
	  Jika server mati sebelum tersimpan, efek & catatan sama-sama hilang, lalu Roblox mengulang
	  receipt di sesi berikutnya. Jadi pemain tidak pernah kehilangan atau mendapat dobel.

	  Produk tertentu punya syarat (mis. Instant Hatch butuh telur yang sedang dierami).
	  Syarat dicek SEBELUM prompt dibuka (remote RequestProductPurchase, prompt dibuka server).
	  Jika syarat sudah tidak terpenuhi saat receipt tiba, pemain mendapat "kredit" yang
	  dipakai otomatis nanti, sehingga Robux tidak pernah terbuang.

	Service lain mendaftarkan efek produk lewat RegisterProductHandler (mis. EggService -> InstantHatch),
	sehingga tidak ada require melingkar.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)

type ActionResult = Types.ActionResult
type Profile = DataService.Profile

export type ProductHandler = {
	-- Syarat sebelum membuka prompt / membeli dengan essence. nil = selalu boleh.
	CanPurchase: ((player: Player, profile: Profile) -> (boolean, string?))?,
	-- Efek produk. WAJIB tanpa yield. Mengembalikan pesan untuk pemain.
	Grant: (player: Player, profile: Profile) -> string,
}

local MAX_KEY_LENGTH = 40
local ATTR = ProductConfig.Attributes
local EFFECTS = ProductConfig.Effects

local MonetizationService = {}

-- Signal: (player: Player, perkKey: string)
MonetizationService.PerkGranted = Signal.new()

local passCache: { [Player]: { [string]: boolean } } = {}
local productHandlers: { [string]: ProductHandler } = {}
local notifyRemote: RemoteEvent

local function reject(message: string): ActionResult
	return { Success = false, Message = message }
end

local function notify(player: Player, message: string, positive: boolean): ()
	if player.Parent == Players then
		notifyRemote:FireClient(player, message, positive)
	end
end

---------------------------------------------------------------------
-- Perk & luck
---------------------------------------------------------------------

function MonetizationService.HasPerk(player: Player, perkKey: string): boolean
	local cache = passCache[player]
	if cache and cache[perkKey] then
		return true
	end
	local data = DataService.GetData(player)
	return data ~= nil and data.OwnedPerks[perkKey] == true
end

function MonetizationService.IsLuckPotionActive(player: Player): boolean
	local data = DataService.GetData(player)
	return data ~= nil and data.LuckBoostEndsAt > os.time()
end

-- Pengali luck pemain (memengaruhi peluang shiny)
function MonetizationService.GetLuckMultiplier(player: Player): number
	local multiplier = 1
	if MonetizationService.HasPerk(player, "DoubleLuck") then
		multiplier *= EFFECTS.DoubleLuckMultiplier
	end
	if MonetizationService.IsLuckPotionActive(player) then
		multiplier *= EFFECTS.LuckyPotionMultiplier
	end
	return multiplier
end

-- Streak yang masih bisa dipulihkan (0 jika tidak ada)
function MonetizationService.GetRevivableStreak(data: Types.PlayerData): number
	local today = os.time() // 86400
	if data.LostStreak > 1 and today - data.LostStreakDay <= EFFECTS.ReviveWindowDays then
		return data.LostStreak
	end
	return 0
end

-- Memperbarui semua atribut pemain yang dipakai UI client
function MonetizationService.RefreshAttributes(player: Player): ()
	if player.Parent ~= Players then
		return
	end
	for key in ProductConfig.GamePasses do
		player:SetAttribute(ATTR.PerkPrefix .. key, MonetizationService.HasPerk(player, key))
	end
	local data = DataService.GetData(player)
	if data then
		player:SetAttribute(ATTR.LuckBoostEndsAt, data.LuckBoostEndsAt)
		player:SetAttribute(ATTR.LoginStreak, data.LoginStreak)
		player:SetAttribute(ATTR.RevivableStreak, MonetizationService.GetRevivableStreak(data))
	end
end

local function grantPerk(player: Player, perkKey: string): ()
	MonetizationService.RefreshAttributes(player)
	MonetizationService.PerkGranted:Fire(player, perkKey)
end

---------------------------------------------------------------------
-- Gamepass
---------------------------------------------------------------------

local function checkPasses(player: Player): ()
	local cache = passCache[player]
	if not cache then
		cache = {}
		passCache[player] = cache
	end
	for key, pass in ProductConfig.GamePasses do
		if pass.PassId ~= 0 then
			for attempt = 1, EFFECTS.PassCheckRetries do
				local ok, owns = pcall(function(): boolean
					return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.PassId)
				end)
				if ok then
					cache[key] = owns == true
					break
				end
				warn(string.format("[MonetizationService] Cek gamepass %s gagal (%d): %s", key, attempt, tostring(owns)))
				task.wait(attempt)
			end
		end
	end
	MonetizationService.RefreshAttributes(player)
end

local function onGamePassPurchaseFinished(player: Player, passId: number, purchased: boolean): ()
	if not purchased then
		return
	end
	local pass = ProductConfig.GetPassById(passId)
	if not pass then
		return
	end
	local cache = passCache[player]
	if not cache then
		cache = {}
		passCache[player] = cache
	end
	cache[pass.Key] = true
	grantPerk(player, pass.Key)
	notify(player, string.format("Terima kasih! %s %s sudah aktif 🎉", pass.Icon, pass.DisplayName), true)
end

---------------------------------------------------------------------
-- Developer Product: efek bawaan
---------------------------------------------------------------------

function MonetizationService.RegisterProductHandler(productKey: string, handler: ProductHandler): ()
	assert(ProductConfig.Products[productKey], "Produk tidak dikenal: " .. productKey)
	productHandlers[productKey] = handler
end

local function registerBuiltInHandlers(): ()
	MonetizationService.RegisterProductHandler("LuckyPotion", {
		CanPurchase = function(_player: Player, profile: Profile): (boolean, string?)
			local remaining = profile.Data.LuckBoostEndsAt - os.time()
			if remaining + EFFECTS.LuckyPotionDuration > EFFECTS.LuckyPotionMaxStack then
				return false, "Ramuan Hoki sudah ditumpuk maksimal. Habiskan dulu ya!"
			end
			return true, nil
		end,
		Grant = function(player: Player, profile: Profile): string
			local data = profile.Data
			local now = os.time()
			-- Durasi bertumpuk: ditambahkan ke sisa waktu yang ada (dibatasi MaxStack)
			local endsAt = math.max(now, data.LuckBoostEndsAt) + EFFECTS.LuckyPotionDuration
			data.LuckBoostEndsAt = math.min(endsAt, now + EFFECTS.LuckyPotionMaxStack)
			MonetizationService.RefreshAttributes(player)
			return string.format("🧪 Ramuan Hoki aktif! Shiny x%d (%d menit tersisa)", EFFECTS.LuckyPotionMultiplier, (data.LuckBoostEndsAt - now) // 60)
		end,
	})

	for _, key in { "EssencePackSmall", "EssencePackMedium", "EssencePackLarge" } do
		local product = ProductConfig.Products[key]
		MonetizationService.RegisterProductHandler(key, {
			Grant = function(player: Player, _profile: Profile): string
				local amount = product.EssenceAmount or 0
				EconomyService.AddEssence(player, amount, "Purchase:" .. key)
				return string.format("%s +%s Essence! Terima kasih 💙", product.Icon, NumberFormat.Abbreviate(amount))
			end,
		})
	end

	MonetizationService.RegisterProductHandler("ReviveStreak", {
		CanPurchase = function(_player: Player, profile: Profile): (boolean, string?)
			if MonetizationService.GetRevivableStreak(profile.Data) <= 0 then
				return false, "Tidak ada streak yang perlu dipulihkan. 🔥"
			end
			return true, nil
		end,
		Grant = function(player: Player, profile: Profile): string
			local data = profile.Data
			local revivable = MonetizationService.GetRevivableStreak(data)
			if revivable > 0 then
				data.LoginStreak += revivable
				data.LostStreak = 0
				MonetizationService.RefreshAttributes(player)
				return string.format("🔥 Streak pulih! Sekarang %d hari.", data.LoginStreak)
			end
			-- Syarat sudah tidak berlaku saat receipt tiba: simpan sebagai kredit
			data.ReviveCredits += 1
			MonetizationService.RefreshAttributes(player)
			return "🔥 Revive Streak disimpan dan akan dipakai otomatis saat streak-mu putus."
		end,
	})
end

---------------------------------------------------------------------
-- ProcessReceipt
---------------------------------------------------------------------

local function trimReceipts(receipts: { [string]: number }): ()
	local count = 0
	for _ in receipts do
		count += 1
	end
	if count <= EFFECTS.MaxStoredReceipts then
		return
	end
	local list: { { Id: string, Time: number } } = {}
	for id, time in receipts do
		table.insert(list, { Id = id, Time = time })
	end
	table.sort(list, function(a, b)
		return a.Time < b.Time
	end)
	for i = 1, count - EFFECTS.MaxStoredReceipts do
		receipts[list[i].Id] = nil
	end
end

local function processReceipt(receipt: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Data belum siap (baru join): tunggu sebentar, kalau tetap belum -> coba lagi nanti
	local profile = DataService.WaitForProfile(player, EFFECTS.ReceiptProfileWait)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = profile.Data
	local purchaseId = tostring(receipt.PurchaseId)

	-- Sudah pernah diproses: pastikan tersimpan, lalu konfirmasi
	if data.ProcessedReceipts[purchaseId] then
		return if DataService.SaveNow(player)
			then Enum.ProductPurchaseDecision.PurchaseGranted
			else Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local product = ProductConfig.GetProductById(receipt.ProductId)
	local handler = product and productHandlers[product.Key]
	if not product or not handler then
		warn("[MonetizationService] ProductId tidak dikenal di ProductConfig: " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Efek + pencatatan PurchaseId tanpa yield (atomik)
	local ok, message = pcall(handler.Grant, player, profile)
	if not ok then
		warn("[MonetizationService] Gagal memberi produk " .. product.Key .. ": " .. tostring(message))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	data.ProcessedReceipts[purchaseId] = os.time()
	trimReceipts(data.ProcessedReceipts)

	-- Simpan sekarang. Hanya PurchaseGranted jika sudah benar-benar tersimpan.
	if not DataService.SaveNow(player) then
		warn("[MonetizationService] Receipt " .. purchaseId .. " belum tersimpan, akan dicoba lagi")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	notify(player, message, true)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

---------------------------------------------------------------------
-- Remote
---------------------------------------------------------------------

-- Client minta dibukakan prompt Developer Product. Syarat dicek dulu di server.
local function handleRequestProductPurchase(player: Player, productKey: any): ActionResult
	if not RemoteGuard.IsValidString(productKey, MAX_KEY_LENGTH) then
		RemoteGuard.Flag(player, "RequestProductPurchase:BadType")
		return reject("Permintaan tidak valid.")
	end
	local product = ProductConfig.Products[productKey]
	local handler = productHandlers[productKey]
	if not product or not handler then
		return reject("Produk tidak dikenal.")
	end
	if product.ProductId == 0 then
		return reject("Produk ini belum tersedia.")
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end
	local canPurchase = handler.CanPurchase
	if canPurchase then
		local allowed, why = canPurchase(player, profile)
		if not allowed then
			return reject(why or "Belum bisa dibeli sekarang.")
		end
	end

	MarketplaceService:PromptProductPurchase(player, product.ProductId)
	return { Success = true, Message = "Membuka jendela pembelian..." }
end

-- Jalur GRATIS: membuka perk gamepass atau membeli item dengan essence
local function handleBuyWithEssence(player: Player, key: any): ActionResult
	if not RemoteGuard.IsValidString(key, MAX_KEY_LENGTH) then
		RemoteGuard.Flag(player, "BuyWithEssence:BadType")
		return reject("Permintaan tidak valid.")
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end

	-- 1. Perk gamepass
	local pass = ProductConfig.GamePasses[key]
	if pass then
		if MonetizationService.HasPerk(player, pass.Key) then
			return reject(pass.DisplayName .. " sudah kamu miliki ✔")
		end
		local paid, why = EconomyService.SpendEssence(player, pass.EssencePrice, "Perk:" .. pass.Key)
		if not paid then
			return reject(why or "Essence belum cukup.")
		end
		profile.Data.OwnedPerks[pass.Key] = true
		grantPerk(player, pass.Key)
		return { Success = true, Message = string.format("%s %s terbuka! 🎉", pass.Icon, pass.DisplayName) }
	end

	-- 2. Item dengan harga essence
	local product = ProductConfig.Products[key]
	local handler = productHandlers[key]
	local price = product and product.EssencePrice
	if not product or not handler or not price then
		return reject("Item ini tidak bisa dibeli dengan essence.")
	end
	local canPurchase = handler.CanPurchase
	if canPurchase then
		local allowed, why = canPurchase(player, profile)
		if not allowed then
			return reject(why or "Belum bisa dibeli sekarang.")
		end
	end
	local paid, why = EconomyService.SpendEssence(player, price, "Item:" .. product.Key)
	if not paid then
		return reject(why or "Essence belum cukup.")
	end
	return { Success = true, Message = handler.Grant(player, profile) }
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function MonetizationService.Init(): ()
	ProductConfig.Validate()
	notifyRemote = Net.Event(Net.Events.Notify)
	registerBuiltInHandlers()

	DataService.ProfileLoaded:Connect(function(player: Player, _profile: Profile)
		MonetizationService.RefreshAttributes(player)
	end)
end

function MonetizationService.Start(): ()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onGamePassPurchaseFinished)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.RequestProductPurchase), {
		Key = "RequestProductPurchase",
		Cooldown = ProductConfig.Shop.PurchaseCooldown,
		MaxArgs = 1,
		OnReject = reject,
	}, handleRequestProductPurchase)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.BuyWithEssence), {
		Key = "BuyWithEssence",
		Cooldown = ProductConfig.Shop.PurchaseCooldown,
		MaxArgs = 1,
		OnReject = reject,
	}, handleBuyWithEssence)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(checkPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(checkPasses, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		passCache[player] = nil
	end)

	-- Perbarui atribut tiap menit (Lucky Potion habis, streak, dll.)
	task.spawn(function()
		while true do
			task.wait(60)
			for _, player in Players:GetPlayers() do
				MonetizationService.RefreshAttributes(player)
			end
		end
	end)
end

return MonetizationService
