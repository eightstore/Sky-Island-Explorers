--!strict
--[[
	CritterService
	--------------
	Mengurus Sky Critters: spawn, gerak melayang, penangkapan, isi tas, dan setor ke essence.

	SPAWN
	  • Titik spawn = Part ber-tag "CritterSpawn" dengan atribut IslandId (string).
	  • Tiap pulau punya batas critter hidup (IslandConfig.MaxCritters).
	  • Critter yang tertangkap "memesan" slot selama RespawnDelay, lalu slot boleh diisi lagi.
	  • Jenis critter dipilih berbobot (CritterConfig.SpawnWeight).

	GERAK
	  • Critter adalah Part anchored yang di-tween (TweenService) ke titik acak di sekitar posisi awal.
	  • Posisinya ditentukan server, jadi posisi itu yang dipakai untuk validasi jarak.

	TANGKAP (remote CatchCritter, satu panggilan)
	  1. Validasi: tipe argumen, rate limit, pemain tidak sedang menangkap, critter ada & bebas,
	     pulau sudah terbuka, tas belum penuh, jarak <= radius jaring + toleransi.
	  2. Critter "dipesan" untuk pemain itu (berhenti bergerak, pemain lain tidak bisa mengambil).
	  3. Server menunggu CaptureTime (dari upgrade Jaring) sementara client memutar animasi.
	  4. Validasi ulang (pemain masih ada, masih dekat, tas belum penuh) lalu critter masuk tas.
	  Waktu tangkap dihitung di server, jadi client tidak bisa mempercepatnya.

	SETOR (remote DepositBag)
	  • Pemain harus berada di dekat Part ber-tag "SellZone" di markas.
	  • Seluruh isi tas diubah menjadi essence lewat EconomyService.AddEssence (tanpa yield = atomik).
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local NumberFormat = require(ReplicatedStorage.Shared.Util.NumberFormat)
local CritterConfig = require(ReplicatedStorage.Shared.Config.CritterConfig)
local IslandConfig = require(ReplicatedStorage.Shared.Config.IslandConfig)
local DataService = require(ServerScriptService.Services.DataService)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)
local PromptFactory = require(ServerScriptService.Util.PromptFactory)
local StateViews = require(ServerScriptService.Util.StateViews)

type CatchResult = Types.CatchResult
type DepositResult = Types.DepositResult
type IslandDef = IslandConfig.IslandDef

type CritterRecord = {
	Uid: string,
	CritterId: string,
	IslandId: string,
	Part: BasePart,
	Home: Vector3,
	CaughtBy: Player?,
	Tween: Tween?,
	NextMoveAt: number,
}

type IslandState = {
	Island: IslandDef,
	Alive: { [string]: CritterRecord },
	AliveCount: number,
	PendingRespawns: number,
	WarnedNoSpawns: boolean,
}

local MAX_UID_LENGTH = 64
local CRITTER_FOLDER_NAME = "Critters"

local CritterService = {}

-- Signal: (player: Player, critterId: string, shiny: boolean, isNew: boolean)
CritterService.CritterCaught = Signal.new()
-- Signal: (player: Player, count: number, gained: number)
CritterService.BagDeposited = Signal.new()

local critters: { [string]: CritterRecord } = {}
local islandStates: { [string]: IslandState } = {}
local busyPlayers: { [Player]: boolean } = {}
local rng = Random.new()
local worldLuckMultiplier = 1

local critterFolder: Folder
local bagChangedRemote: RemoteEvent

---------------------------------------------------------------------
-- Luck & atribut pemain
---------------------------------------------------------------------

-- Dipakai WeatherService / event di tahap berikutnya (mis. hujan pelangi = luck x2)
function CritterService.SetWorldLuckMultiplier(multiplier: number): ()
	if RemoteGuard.IsFiniteNumber(multiplier) and multiplier > 0 then
		worldLuckMultiplier = multiplier
	end
end

-- Luck total pemain. Tahap ini: hanya luck dunia. Sumber luck lain (boost, pass) ditambahkan nanti.
function CritterService.GetLuck(_player: Player): number
	return worldLuckMultiplier
end

local function getBagCapacity(player: Player): number
	return EconomyService.GetUpgradeStats(player, "Bag").Capacity or 0
end

local function getNetStats(player: Player): (number, number)
	local stats = EconomyService.GetUpgradeStats(player, "Net")
	return stats.Radius or 0, stats.CaptureTime or 1
end

local function sendBag(profile: DataService.Profile): ()
	bagChangedRemote:FireClient(profile.Player, StateViews.Critters(profile.Data.Bag), DataService.NextRevision(profile))
end

-- Kirim ulang isi tas ke client (dipakai BaseService saat critter dipindah tas <-> markas)
CritterService.SyncBag = sendBag

-- Kapasitas tas pemain saat ini (dari upgrade Tas)
CritterService.GetBagCapacity = getBagCapacity

---------------------------------------------------------------------
-- Pembuatan visual critter
---------------------------------------------------------------------

local function createCritterPart(def: CritterConfig.CritterDef, rarity: CritterConfig.RarityDef, position: Vector3): BasePart
	local body = Instance.new("Part")
	body.Name = def.DisplayName
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.one * def.Size
	body.Color = def.Color
	body.Material = if rarity.Glow then Enum.Material.Neon else Enum.Material.SmoothPlastic
	body.Anchored = true
	body.CanCollide = false
	body.CanTouch = false
	body.CanQuery = true -- wajib true agar client bisa klik/tap (raycast)
	body.CastShadow = false
	body.CFrame = CFrame.new(position)

	-- Dua mata kecil supaya terlihat imut. Ikut bergerak lewat WeldConstraint.
	for _, side in { -1, 1 } do
		local eye = Instance.new("Part")
		eye.Name = "Eye"
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.one * (def.Size * 0.22)
		eye.Color = Color3.fromRGB(30, 30, 40)
		eye.Material = Enum.Material.SmoothPlastic
		eye.Anchored = false
		eye.CanCollide = false
		eye.CanTouch = false
		eye.CanQuery = false
		eye.Massless = true
		eye.CastShadow = false
		eye.CFrame = body.CFrame * CFrame.new(side * def.Size * 0.2, def.Size * 0.12, -def.Size * 0.42)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = eye
		weld.Parent = eye
		eye.Parent = body
	end

	-- Label nama + rarity
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.fromOffset(180, 48)
	billboard.StudsOffset = Vector3.new(0, def.Size / 2 + 1.4, 0)
	billboard.MaxDistance = 70
	billboard.LightInfluence = 0
	billboard.Parent = body

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(1, 0.58)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = def.DisplayName
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.TextScaled = true
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Parent = billboard

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Position = UDim2.fromScale(0, 0.58)
	rarityLabel.Size = UDim2.fromScale(1, 0.42)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Text = rarity.DisplayName
	rarityLabel.TextColor3 = rarity.Color
	rarityLabel.TextStrokeTransparency = 0.3
	rarityLabel.TextScaled = true
	rarityLabel.Font = Enum.Font.FredokaOne
	rarityLabel.Parent = billboard

	-- Rarity tinggi bercahaya
	if rarity.Glow then
		local light = Instance.new("PointLight")
		light.Color = rarity.Color
		light.Range = def.Size * 4
		light.Brightness = 1.5
		light.Parent = body

		local sparkles = Instance.new("ParticleEmitter")
		sparkles.Name = "RaritySparkles"
		sparkles.Color = ColorSequence.new(rarity.Color)
		sparkles.LightEmission = 1
		sparkles.Size = NumberSequence.new(0.25, 0)
		sparkles.Lifetime = NumberRange.new(0.6, 1.2)
		sparkles.Rate = 6
		sparkles.Speed = NumberRange.new(1, 2)
		sparkles.SpreadAngle = Vector2.new(180, 180)
		sparkles.Parent = body
	end

	return body
end

---------------------------------------------------------------------
-- Spawn & hapus
---------------------------------------------------------------------

local function getSpawnPoints(islandId: string): { BasePart }
	local points: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(CritterConfig.Tags.Spawn) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) and instance:GetAttribute(CritterConfig.Attributes.IslandId) == islandId then
			table.insert(points, instance)
		end
	end
	return points
end

local function spawnCritter(state: IslandState, point: BasePart): ()
	local island = state.Island
	local critterId = CritterConfig.PickWeighted(island.Critters, rng)
	local def = if critterId then CritterConfig.Get(critterId) else nil
	local rarity = if def then CritterConfig.GetRarity(def.Rarity) else nil
	if not def or not rarity then
		return
	end

	local scatterAttr = point:GetAttribute(CritterConfig.Attributes.SpawnRadius)
	local scatter = if typeof(scatterAttr) == "number" then scatterAttr else CritterConfig.Movement.SpawnScatter
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = rng:NextNumber(0, scatter)
	local height = rng:NextNumber(CritterConfig.Movement.HoverHeightMin, CritterConfig.Movement.HoverHeightMax)
	local position = point.Position + Vector3.new(math.cos(angle) * distance, height, math.sin(angle) * distance)

	local uid = HttpService:GenerateGUID(false)
	local part = createCritterPart(def, rarity, position)
	part:SetAttribute(CritterConfig.Attributes.Uid, uid)
	part:SetAttribute(CritterConfig.Attributes.CritterId, def.Id)
	part:SetAttribute(CritterConfig.Attributes.IslandId, island.Id)
	part:SetAttribute(CritterConfig.Attributes.Rarity, def.Rarity)
	part:SetAttribute(CritterConfig.Attributes.BeingCaught, false)
	part:AddTag(CritterConfig.Tags.Critter)
	part.Parent = critterFolder

	local record: CritterRecord = {
		Uid = uid,
		CritterId = def.Id,
		IslandId = island.Id,
		Part = part,
		Home = position,
		CaughtBy = nil,
		Tween = nil,
		NextMoveAt = os.clock() + rng:NextNumber(0, CritterConfig.Movement.PauseMax),
	}
	critters[uid] = record
	state.Alive[uid] = record
	state.AliveCount += 1
end

-- Menghapus critter dari dunia. reserveRespawn = true jika slot harus menunggu RespawnDelay.
local function removeCritter(record: CritterRecord, reserveRespawn: boolean): ()
	if critters[record.Uid] == nil then
		return
	end
	critters[record.Uid] = nil

	local state = islandStates[record.IslandId]
	if state then
		state.Alive[record.Uid] = nil
		state.AliveCount -= 1
		if reserveRespawn then
			state.PendingRespawns += 1
			task.delay(state.Island.RespawnDelay, function()
				state.PendingRespawns -= 1
			end)
		end
	end

	local tween = record.Tween
	if tween then
		tween:Cancel()
	end
	record.Part:Destroy()
end

local function spawnLoop(): ()
	while true do
		for _, state in islandStates do
			local points = getSpawnPoints(state.Island.Id)
			if #points == 0 then
				if not state.WarnedNoSpawns then
					state.WarnedNoSpawns = true
					warn(string.format("[CritterService] Pulau %s belum punya titik spawn (tag %s, atribut IslandId=%s)",
						state.Island.DisplayName, CritterConfig.Tags.Spawn, state.Island.Id))
				end
			else
				state.WarnedNoSpawns = false
				local spawned = 0
				while state.AliveCount + state.PendingRespawns < state.Island.MaxCritters and spawned < CritterConfig.Spawn.MaxPerTick do
					spawnCritter(state, points[rng:NextInteger(1, #points)])
					spawned += 1
				end
			end
		end
		task.wait(CritterConfig.Spawn.CheckInterval)
	end
end

---------------------------------------------------------------------
-- Gerak melayang
---------------------------------------------------------------------

local function moveCritter(record: CritterRecord): ()
	local movement = CritterConfig.Movement
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = rng:NextNumber(0, movement.WanderRadius)
	local target = record.Home
		+ Vector3.new(math.cos(angle) * distance, rng:NextNumber(-movement.HeightJitter, movement.HeightJitter), math.sin(angle) * distance)

	local current = record.Part.Position
	local flat = Vector3.new(target.X - current.X, 0, target.Z - current.Z)
	local goal = if flat.Magnitude > 0.1 then CFrame.lookAt(target, target + flat.Unit) else CFrame.new(target)

	local duration = rng:NextNumber(movement.MoveTimeMin, movement.MoveTimeMax)
	local tween = TweenService:Create(record.Part, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { CFrame = goal })
	record.Tween = tween
	tween:Play()
	record.NextMoveAt = os.clock() + duration + rng:NextNumber(movement.PauseMin, movement.PauseMax)
end

local function movementLoop(): ()
	while true do
		local now = os.clock()
		for _, record in critters do
			if record.CaughtBy == nil and now >= record.NextMoveAt then
				moveCritter(record)
			end
		end
		task.wait(CritterConfig.Movement.UpdateInterval)
	end
end

---------------------------------------------------------------------
-- Tangkap
---------------------------------------------------------------------

local function reject(message: string): CatchResult
	return { Success = false, Message = message }
end

local function reserveCritter(record: CritterRecord, player: Player): ()
	record.CaughtBy = player
	local tween = record.Tween
	if tween then
		tween:Cancel()
		record.Tween = nil
	end
	record.Part:SetAttribute(CritterConfig.Attributes.BeingCaught, true)
end

local function releaseCritter(record: CritterRecord): ()
	if critters[record.Uid] == nil then
		return
	end
	record.CaughtBy = nil
	record.NextMoveAt = os.clock() + 0.5
	record.Part:SetAttribute(CritterConfig.Attributes.BeingCaught, false)
end

local function isWithin(player: Player, position: Vector3, maxDistance: number): boolean
	return RemoteGuard.IsNear(player, position, maxDistance)
end

local function handleCatchCritter(player: Player, uid: any): CatchResult
	-- 1. Validasi argumen
	if not RemoteGuard.IsValidString(uid, MAX_UID_LENGTH) then
		RemoteGuard.Flag(player, "CatchCritter:BadType")
		return reject("Permintaan tidak valid.")
	end
	if busyPlayers[player] then
		return reject("Sabar, jaringmu masih bekerja!")
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return reject("Data kamu belum siap, coba lagi sebentar.")
	end

	-- 2. Critter harus ada dan bebas
	local record = critters[uid]
	if not record then
		return reject("Critter itu sudah terbang pergi!")
	end
	if record.CaughtBy ~= nil then
		return reject("Critter itu sedang ditangkap pemain lain.")
	end

	-- 3. Pulau critter harus sudah terbuka untuk pemain ini (anti tembus gerbang)
	if profile.Data.UnlockedIslands[record.IslandId] ~= true then
		RemoteGuard.Flag(player, "CatchCritter:LockedIsland")
		return reject("Buka pulau ini dulu di gerbangnya.")
	end

	-- 4. Tas belum penuh
	local capacity = getBagCapacity(player)
	if #profile.Data.Bag >= capacity then
		return { Success = false, Message = "Tas penuh! Setor dulu di markas 🎒", BagFull = true, BagCount = #profile.Data.Bag }
	end

	-- 5. Jarak <= radius jaring (+ toleransi lag)
	local radius, captureTime = getNetStats(player)
	if not isWithin(player, record.Part.Position, radius + CritterConfig.Catch.DistanceTolerance) then
		RemoteGuard.Flag(player, "CatchCritter:TooFar")
		return reject("Terlalu jauh! Dekati critter-nya.")
	end

	-- 6. Pesan critter lalu tunggu waktu tangkap (dihitung server)
	busyPlayers[player] = true
	reserveCritter(record, player)

	task.wait(captureTime)

	busyPlayers[player] = nil

	-- 7. Validasi ulang setelah menunggu (TIDAK ADA yield setelah titik ini)
	if critters[uid] ~= record or record.CaughtBy ~= player then
		return reject("Critter itu lolos!")
	end
	local currentProfile = DataService.GetProfile(player)
	if player.Parent ~= Players or currentProfile ~= profile then
		releaseCritter(record)
		return reject("Penangkapan dibatalkan.")
	end
	if not isWithin(player, record.Part.Position, radius + CritterConfig.Catch.FinishTolerance) then
		releaseCritter(record)
		return reject("Critter lolos karena kamu terlalu jauh!")
	end
	local data = profile.Data
	if #data.Bag >= getBagCapacity(player) then
		releaseCritter(record)
		return { Success = false, Message = "Tas penuh! Setor dulu di markas 🎒", BagFull = true, BagCount = #data.Bag }
	end

	-- 8. Berhasil: tentukan shiny (dengan luck), masukkan tas, catat koleksi
	local shiny = rng:NextNumber() < CritterConfig.GetShinyChance(CritterService.GetLuck(player))
	local critterId = record.CritterId
	removeCritter(record, true)

	table.insert(data.Bag, { CritterId = critterId, Shiny = shiny, CaughtAt = os.time() })

	local entry = data.Collection[critterId]
	local isNew = entry == nil
	if not entry then
		entry = { Caught = 0, Shiny = 0, FirstCaughtAt = os.time() }
		data.Collection[critterId] = entry
	end
	entry.Caught += 1
	data.Stats.TotalCrittersCaught += 1
	if shiny then
		entry.Shiny += 1
		data.Stats.TotalShinyCaught += 1
	end

	sendBag(profile)
	CritterService.CritterCaught:Fire(player, critterId, shiny, isNew)

	local def = CritterConfig.Get(critterId)
	local name = if def then def.DisplayName else critterId
	local message = if shiny then "✨ SHINY " .. name .. "! ✨" else name .. " tertangkap!"
	if isNew then
		message ..= " (Baru! 📖)"
	end

	return {
		Success = true,
		Message = message,
		CritterId = critterId,
		Shiny = shiny,
		IsNew = isNew,
		BagCount = #data.Bag,
		BagFull = #data.Bag >= getBagCapacity(player),
	}
end

---------------------------------------------------------------------
-- Setor
---------------------------------------------------------------------

local function rejectDeposit(message: string): DepositResult
	return { Success = false, Message = message }
end

local function handleDepositBag(player: Player): DepositResult
	local profile = DataService.GetProfile(player)
	if not profile then
		return rejectDeposit("Data kamu belum siap, coba lagi sebentar.")
	end
	if not RemoteGuard.IsNearTagged(player, CritterConfig.Deposit.Tag, CritterConfig.Deposit.InteractDistance) then
		RemoteGuard.Flag(player, "DepositBag:TooFar")
		return rejectDeposit("Dekati Zona Setor di markas dulu.")
	end

	local data = profile.Data
	local count = #data.Bag
	if count == 0 then
		return rejectDeposit("Tasmu masih kosong. Ayo tangkap critter!")
	end

	-- Hitung nilai di server dari config (tanpa yield sampai selesai)
	local total = 0
	for _, item in data.Bag do
		total += CritterConfig.GetValue(item.CritterId, item.Shiny)
	end

	table.clear(data.Bag)
	if total > 0 then
		EconomyService.AddEssence(player, total, "Deposit")
	end
	sendBag(profile)
	CritterService.BagDeposited:Fire(player, count, total)

	return {
		Success = true,
		Message = string.format("Setor %d critter: +%s ✨", count, NumberFormat.Abbreviate(total)),
		Count = count,
		Gained = total,
	}
end

local function setupSellZone(instance: Instance): ()
	PromptFactory.Attach(instance, {
		Name = CritterConfig.Deposit.PromptName,
		ActionText = "Setor Tas",
		ObjectText = "Zona Setor",
		MaxActivationDistance = CritterConfig.Deposit.PromptDistance,
	})
end

---------------------------------------------------------------------
-- Siklus hidup
---------------------------------------------------------------------

function CritterService.Init(): ()
	CritterConfig.Validate()
	for _, island in IslandConfig.Islands do
		for _, critterId in island.Critters do
			assert(CritterConfig.Get(critterId), string.format("IslandConfig: critter '%s' di pulau %s tidak ada di CritterConfig", critterId, island.Id))
		end
		islandStates[island.Id] = {
			Island = island,
			Alive = {},
			AliveCount = 0,
			PendingRespawns = 0,
			WarnedNoSpawns = false,
		}
	end

	local existing = Workspace:FindFirstChild(CRITTER_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = CRITTER_FOLDER_NAME
	folder.Parent = Workspace
	critterFolder = folder

	bagChangedRemote = Net.Event(Net.Events.BagChanged)
end

function CritterService.Start(): ()
	RemoteGuard.BindFunction(Net.Function(Net.Functions.CatchCritter), {
		Key = "CatchCritter",
		Cooldown = CritterConfig.Catch.MinInterval,
		MaxArgs = 1,
		OnReject = reject,
	}, handleCatchCritter)

	RemoteGuard.BindFunction(Net.Function(Net.Functions.DepositBag), {
		Key = "DepositBag",
		Cooldown = CritterConfig.Deposit.Cooldown,
		MaxArgs = 0,
		OnReject = rejectDeposit,
	}, handleDepositBag)

	for _, instance in CollectionService:GetTagged(CritterConfig.Deposit.Tag) do
		setupSellZone(instance)
	end
	CollectionService:GetInstanceAddedSignal(CritterConfig.Deposit.Tag):Connect(setupSellZone)

	-- Lepaskan critter yang sedang ditangkap pemain yang keluar
	Players.PlayerRemoving:Connect(function(player: Player)
		busyPlayers[player] = nil
		for _, record in critters do
			if record.CaughtBy == player then
				releaseCritter(record)
			end
		end
	end)

	task.spawn(spawnLoop)
	task.spawn(movementLoop)
end

return CritterService
