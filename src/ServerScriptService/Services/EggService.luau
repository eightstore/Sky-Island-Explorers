--!strict
--[[
	EggService
	----------
	Telur awan: beli dengan essence, dierami (waktu nyata), lalu dibuka.

	ALUR
	  1. BuyEgg(eggId): pemain di dekat Toko Telur, pulau telur sudah terbuka, inkubator kosong,
	     essence cukup -> essence dipotong, telur masuk inkubator dengan ReadyAt = sekarang + HatchTime.
	  2. Menunggu HatchTime. Developer Product "Instant Hatch" (atau kredit) membuatnya langsung siap.
	  3. HatchEgg(): server mengundi isi telur dengan Random.new() MILIK SERVER berdasarkan
	     EggConfig.Odds (tabel yang sama yang ditampilkan di UI), lalu mengundi shiny dengan luck.
	     Hasil dikirim ke client, yang baru kemudian memutar animasi buka telur.
	  Client tidak pernah ikut menentukan hasil.

	Status inkubator direplikasi lewat atribut pemain IncubatorEggId & IncubatorReadyAt.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local EggConfig = require(ReplicatedStorage.Shared.Config.EggConfig)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local MonetizationService = require(ServerScriptService.Services.MonetizationService)
local CritterService = require(ServerScriptService.Services.CritterService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)
local PromptFactory = require(ServerScriptService.Util.PromptFactory)

type ActionResult = Types.ActionResult
type HatchResult = Types.HatchResult
type Profile = DataService.Profile

local MAX_EGG_ID_LENGTH = 32
local ATTR = ProductConfig.Attributes

local EggService = {}

-- Random milik server: hasil telur tidak bisa ditebak atau dipengaruhi client
local rng = Random.new()

local function reject(message: string): ActionResult
	return { Success = false, Message = message }
end

local function rejectHatch(message: string): HatchResult
	return { Success = false, Message = message }
end

local function isIncubating(profile: Profile): boolean
	return profile.Data.Incubator.EggId ~= ""
end

local function refreshAttributes(player: Player): ()
	local data = DataService.GetData(player)
	if data and player.Parent == Players then
		player:SetAttribute(ATTR.IncubatorEggId, data.Incubator.EggId)
		player:SetAttribute(ATTR.IncubatorReadyAt, data.Incubator.ReadyAt)
	end
end

---------------------------------------------------------------------
-- Handler remote
---------------------------------------------------------------------

local function handleBuyEgg(player: Player, eggId: any): ActionResult
	if not RemoteGuard.IsValidString(eggId, MAX_EGG_ID_LENGTH) then
		RemoteGuard.Flag(player, "BuyEgg:BadType")
		return reject("Permintaan tidak valid.")
	end
	local egg = EggConfig.Get(eggId)
	if not egg then
		RemoteGuard.Flag(player, "BuyEgg:UnknownId")
		return reject("Telur tidak dikenal.")
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end
	if not RemoteGuard.IsNearTagged(player, EggConfig.Shop.Tag, EggConfig.Shop.InteractDistance) then
		RemoteGuard.Flag(player, "BuyEgg:TooFar")
		return reject("Dekati Toko Telur dulu.")
	end

	local data = profile.Data
	if data.UnlockedIslands[egg.IslandId] ~= true then
		local island = IslandConfig.Get(egg.IslandId)
		return reject("Buka " .. (if island then island.DisplayName else egg.IslandId) .. " dulu untuk membeli telur ini.")
	end
	if isIncubating(profile) then
		return reject("Inkubator masih berisi telur. Buka telurnya dulu ya!")
	end

	-- Bayar (atomik) lalu isi inkubator di frame yang sama
	local paid, why = EconomyService.SpendEssence(player, egg.Price, "Egg:" .. egg.Id)
	if not paid then
		return reject(why or "Essence belum cukup.")
	end

	local readyAt = os.time() + egg.HatchTime
	local message = string.format("%s mulai dierami (%d detik) 🥚", egg.DisplayName, egg.HatchTime)
	if data.InstantHatchCredits > 0 then
		data.InstantHatchCredits -= 1
		readyAt = os.time()
		message = egg.DisplayName .. " langsung siap dibuka! (kredit Tetas Instan dipakai) ⚡"
	end
	data.Incubator = { EggId = egg.Id, ReadyAt = readyAt }
	refreshAttributes(player)

	return { Success = true, Message = message }
end

local function handleHatchEgg(player: Player): HatchResult
	local profile = DataService.GetProfile(player)
	if not profile then
		return rejectHatch("Data kamu belum siap, coba lagi sebentar.")
	end
	local data = profile.Data
	local egg = EggConfig.Get(data.Incubator.EggId)
	if not egg then
		return rejectHatch("Tidak ada telur di inkubator.")
	end
	if os.time() + EggConfig.Shop.HatchTimeTolerance < data.Incubator.ReadyAt then
		return rejectHatch("Telur belum siap menetas. Sabar sebentar ya!")
	end
	if #data.Bag >= CritterService.GetBagCapacity(player) then
		return rejectHatch("Tas penuh! Setor dulu sebelum membuka telur 🎒")
	end

	-- Undi isi telur & shiny di server (tanpa yield sampai selesai)
	local critterId = EggConfig.Roll(egg, rng)
	local shiny = rng:NextNumber() < CritterConfig.GetShinyChance(CritterService.GetLuck(player))

	data.Incubator = { EggId = "", ReadyAt = 0 }
	data.Stats.EggsHatched += 1
	local isNew = CritterService.GiveCritter(profile, critterId, shiny)
	refreshAttributes(player)

	local def = CritterConfig.Get(critterId)
	local name = if def then def.DisplayName else critterId
	return {
		Success = true,
		Message = (if shiny then "✨ SHINY " .. name .. "! ✨" else name .. " menetas!") .. (if isNew then " (Baru! 📖)" else ""),
		EggId = egg.Id,
		CritterId = critterId,
		Shiny = shiny,
		IsNew = isNew,
	}
end

---------------------------------------------------------------------
-- Instant Hatch (Developer Product)
---------------------------------------------------------------------

local function registerInstantHatch(): ()
	MonetizationService.RegisterProductHandler("InstantHatch", {
		CanPurchase = function(_player: Player, profile: Profile): (boolean, string?)
			if not isIncubating(profile) then
				return false, "Tidak ada telur yang sedang dierami."
			end
			if profile.Data.Incubator.ReadyAt <= os.time() then
				return false, "Telurmu sudah siap dibuka! 🥚"
			end
			return true, nil
		end,
		Grant = function(player: Player, profile: Profile): string
			local data = profile.Data
			if isIncubating(profile) and data.Incubator.ReadyAt > os.time() then
				data.Incubator.ReadyAt = os.time()
				refreshAttributes(player)
				return "⚡ Telurmu langsung siap dibuka!"
			end
			-- Telur sudah menetas saat receipt tiba: simpan sebagai kredit untuk telur berikutnya
			data.InstantHatchCredits += 1
			return "⚡ Tetas Instan disimpan dan akan dipakai otomatis untuk telur berikutnya."
		end,
	})
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

local function setupEggShop(instance: Instance): ()
	PromptFactory.Attach(instance, {
		Name = EggConfig.Shop.PromptName,
		ActionText = "Lihat Telur",
		ObjectText = "Toko Telur",
		MaxActivationDistance = EggConfig.Shop.PromptDistance,
	})
end

function EggService.Init(): ()
	EggConfig.Validate(function(critterId: string): boolean
		return CritterConfig.Get(critterId) ~= nil
	end, function(islandId: string): boolean
		return IslandConfig.Get(islandId) ~= nil
	end)
	registerInstantHatch()

	DataService.ProfileLoaded:Connect(function(player: Player, _profile: Profile)
		refreshAttributes(player)
	end)
end

function EggService.Start(): ()
	RemoteGuard.BindFunction(Net.Function(Net.Functions.BuyEgg), {
		Key = "BuyEgg",
		Cooldown = EggConfig.Shop.Cooldown,
		MaxArgs = 1,
		OnReject = reject,
	}, handleBuyEgg)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.HatchEgg), {
		Key = "HatchEgg",
		Cooldown = EggConfig.Shop.Cooldown,
		MaxArgs = 0,
		OnReject = rejectHatch,
	}, handleHatchEgg)

	for _, instance in CollectionService:GetTagged(EggConfig.Shop.Tag) do
		setupEggShop(instance)
	end
	CollectionService:GetInstanceAddedSignal(EggConfig.Shop.Tag):Connect(setupEggShop)
end

return EggService
