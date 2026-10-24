--!strict
--[[
	GliderService
	-------------
	Sisi server dari glider: status "sedang melayang" dan pemeriksaan anti speed-hack.

	Fisika karakter dijalankan di client (network ownership), jadi server tidak bisa mencegah
	client bergerak cepat. Yang bisa dilakukan server: MENGAWASI dan MENGOREKSI.
	  • Tiap CheckInterval, server mengukur kecepatan horizontal tiap pemain dari posisi
	    HumanoidRootPart, lalu membandingkannya dengan batas:
	        - sedang melayang  : Speed glider (stat upgrade) selama jarak glide belum habis
	        - tidak melayang   : WalkSpeed Humanoid di server
	    dikali SpeedTolerance + ExtraBuffer (toleransi lag).
	  • Kecepatan naik yang tidak wajar (terbang ke atas) juga dihitung pelanggaran.
	  • Setelah ViolationsToRubberBand pelanggaran beruntun, pemain dikembalikan ke posisi valid
	    terakhir ("rubber band"). Tidak ada kick: anak-anak dengan koneksi lambat bisa terkena lag spike.
	  • Jarak glide dihitung server dan direset hanya saat pemain benar-benar menapak tanah
	    (raycast di server), jadi client tidak bisa "mengisi ulang" glider di udara.

	Remote: GliderState(isGliding: boolean) [C->S]
	Atribut karakter "Gliding" (boolean) direplikasi ke semua client untuk efek visual sayap.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local GliderConfig = require(ReplicatedStorage.Shared.Config.GliderConfig)
local EconomyService = require(ServerScriptService.Services.EconomyService)
local RemoteGuard = require(ServerScriptService.Util.RemoteGuard)

local GLIDING_ATTRIBUTE = "Gliding"

type Track = {
	LastPosition: Vector3?,
	LastTime: number,
	LastValid: CFrame?,
	Gliding: boolean,
	GlideDistance: number,
	Violations: number,
	GraceUntil: number,
}

local GliderService = {}

local tracks: { [Player]: Track } = {}

local function newTrack(): Track
	return {
		LastPosition = nil,
		LastTime = os.clock(),
		LastValid = nil,
		Gliding = false,
		GlideDistance = 0,
		Violations = 0,
		GraceUntil = os.clock() + GliderConfig.AntiCheat.SpawnGrace,
	}
end

local function getTrack(player: Player): Track
	local track = tracks[player]
	if not track then
		track = newTrack()
		tracks[player] = track
	end
	return track
end

local function setGlidingAttribute(player: Player, value: boolean): ()
	local character = player.Character
	if character then
		character:SetAttribute(GLIDING_ATTRIBUTE, value)
	end
end

-- Beri jeda bebas pemeriksaan (dipakai saat server memindahkan pemain: teleport, jump pad, dsb.)
function GliderService.GrantGrace(player: Player, seconds: number): ()
	local track = getTrack(player)
	track.GraceUntil = math.max(track.GraceUntil, os.clock() + seconds)
	track.LastPosition = nil
end

local function isGrounded(root: BasePart, character: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local result = Workspace:Raycast(root.Position, Vector3.new(0, -GliderConfig.AntiCheat.GroundCheckDistance, 0), params)
	return result ~= nil
end

local function onGliderState(player: Player, isGliding: any): ()
	if typeof(isGliding) ~= "boolean" then
		RemoteGuard.Flag(player, "GliderState:BadType")
		return
	end
	local track = getTrack(player)
	track.Gliding = isGliding
	setGlidingAttribute(player, isGliding)
end

local function checkPlayer(player: Player, now: number): ()
	local track = getTrack(player)
	local character = player.Character
	local root = RemoteGuard.GetRootPart(player)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not humanoid then
		track.LastPosition = nil
		return
	end

	local position = root.Position
	local lastPosition = track.LastPosition
	local dt = now - track.LastTime
	track.LastTime = now
	track.LastPosition = position

	local grounded = isGrounded(root, character)
	if grounded then
		track.GlideDistance = 0
	end

	if not lastPosition or dt <= 0 or now < track.GraceUntil then
		track.LastValid = root.CFrame
		return
	end

	local delta = position - lastPosition
	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local horizontalSpeed = horizontal / dt
	local ascendSpeed = delta.Y / dt

	-- Batas kecepatan horizontal
	local antiCheat = GliderConfig.AntiCheat
	local gliderStats = EconomyService.GetUpgradeStats(player, "Glider")
	local maxGlideDistance = (gliderStats.MaxDistance or 0) * antiCheat.GlideDistanceTolerance
	local canGlide = track.Gliding and not grounded and track.GlideDistance <= maxGlideDistance
	local baseSpeed = if canGlide then math.max(gliderStats.Speed or 0, humanoid.WalkSpeed) else humanoid.WalkSpeed
	local allowedSpeed = baseSpeed * antiCheat.SpeedTolerance + antiCheat.ExtraBuffer

	if track.Gliding and not grounded then
		track.GlideDistance += horizontal
	end

	local violated = horizontalSpeed > allowedSpeed or ascendSpeed > antiCheat.MaxAscendSpeed
	if violated then
		track.Violations += 1
		RemoteGuard.Flag(player, string.format("Movement:%.0f/%.0f naik %.0f", horizontalSpeed, allowedSpeed, ascendSpeed))
		if track.Violations >= antiCheat.ViolationsToRubberBand then
			local valid = track.LastValid
			if valid then
				root.AssemblyLinearVelocity = Vector3.zero
				root.CFrame = valid
				track.LastPosition = valid.Position
			end
			track.Violations = 0
			warn(string.format("[GliderService] %s dikembalikan ke posisi valid (kecepatan %.0f, batas %.0f)", player.Name, horizontalSpeed, allowedSpeed))
		end
	else
		track.Violations = math.max(0, track.Violations - 1)
		track.LastValid = root.CFrame
	end
end

local function checkLoop(): ()
	while true do
		task.wait(GliderConfig.AntiCheat.CheckInterval)
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			checkPlayer(player, now)
		end
	end
end

local function onPlayerAdded(player: Player): ()
	tracks[player] = newTrack()
	player.CharacterAdded:Connect(function(character: Model)
		tracks[player] = newTrack()
		character:SetAttribute(GLIDING_ATTRIBUTE, false)
	end)
	if player.Character then
		player.Character:SetAttribute(GLIDING_ATTRIBUTE, false)
	end
end

function GliderService.Init(): () end

function GliderService.Start(): ()
	RemoteGuard.BindEvent(Net.Event(Net.Events.GliderState), {
		Key = "GliderState",
		Cooldown = GliderConfig.AntiCheat.StateCooldown,
		MaxArgs = 1,
	}, onGliderState)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		tracks[player] = nil
	end)

	task.spawn(checkLoop)
end

return GliderService
