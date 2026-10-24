--!strict
--[[
	RemoteGuard
	-----------
	Lapisan anti-exploit untuk semua Remote dari client.
	  • Validasi tipe argumen (string, angka finite, dsb.)
	  • Batas jumlah argumen
	  • Rate limit / debounce per pemain per remote
	  • Cek jarak karakter pemain ke target (Part/Model bertag)
	  • pcall di sekeliling handler agar error tidak membuat remote "macet"

	Catatan: posisi karakter dikendalikan client (network ownership), jadi cek jarak
	BUKAN pertahanan sempurna terhadap teleport-exploit. Cek ini tetap wajib karena
	mencegah sebagian besar exploit sederhana dan menjadi dasar deteksi di tahap berikutnya.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local RemoteGuard = {}

-- Pelanggaran dalam satu jendela waktu sebelum dicatat sebagai "mencurigakan"
local VIOLATION_WINDOW_SECONDS = 10
local VIOLATION_WARN_THRESHOLD = 25

local lastCallTimes: { [Player]: { [string]: number } } = {}
local violations: { [Player]: { Count: number, WindowStart: number, Warned: boolean } } = {}

export type FunctionOptions = {
	Key: string, -- nama unik untuk rate limit
	Cooldown: number, -- detik
	MaxArgs: number, -- jumlah argumen maksimum yang boleh dikirim client
	OnReject: (message: string) -> any, -- nilai balik saat request ditolak
}

export type EventOptions = {
	Key: string,
	Cooldown: number,
	MaxArgs: number,
}

-- Mencatat perilaku mencurigakan. Tidak langsung kick: anak-anak sering menekan tombol berkali-kali.
function RemoteGuard.Flag(player: Player, reason: string): ()
	local now = os.clock()
	local record = violations[player]
	if not record or now - record.WindowStart > VIOLATION_WINDOW_SECONDS then
		record = { Count = 0, WindowStart = now, Warned = false }
		violations[player] = record
	end
	record.Count += 1
	if record.Count >= VIOLATION_WARN_THRESHOLD and not record.Warned then
		record.Warned = true
		warn(string.format("[RemoteGuard] %s (%d) mencurigakan: %d pelanggaran dalam %ds. Terakhir: %s",
			player.Name, player.UserId, record.Count, VIOLATION_WINDOW_SECONDS, reason))
	end
end

-- true jika boleh lanjut; false jika masih dalam cooldown
function RemoteGuard.CheckRate(player: Player, key: string, cooldown: number): boolean
	local now = os.clock()
	local perPlayer = lastCallTimes[player]
	if not perPlayer then
		perPlayer = {}
		lastCallTimes[player] = perPlayer
	end
	local last = perPlayer[key]
	if last and now - last < cooldown then
		RemoteGuard.Flag(player, "RateLimit:" .. key)
		return false
	end
	perPlayer[key] = now
	return true
end

function RemoteGuard.IsValidString(value: any, maxLength: number): boolean
	return typeof(value) == "string" and #value > 0 and #value <= maxLength and utf8.len(value) ~= nil
end

function RemoteGuard.IsFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- HumanoidRootPart pemain yang masih hidup, atau nil
function RemoteGuard.GetRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function RemoteGuard.GetInstancePosition(target: Instance): Vector3?
	if target:IsA("BasePart") then
		return target.Position
	elseif target:IsA("Model") then
		return target:GetPivot().Position
	elseif target:IsA("Attachment") then
		return target.WorldPosition
	end
	return nil
end

function RemoteGuard.IsNear(player: Player, position: Vector3, maxDistance: number): boolean
	local root = RemoteGuard.GetRootPart(player)
	if not root then
		return false
	end
	return (root.Position - position).Magnitude <= maxDistance
end

-- true jika pemain berada dalam maxDistance dari SALAH SATU instance ber-tag `tag` di Workspace
function RemoteGuard.IsNearTagged(player: Player, tag: string, maxDistance: number): boolean
	local root = RemoteGuard.GetRootPart(player)
	if not root then
		return false
	end
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsDescendantOf(Workspace) then
			local position = RemoteGuard.GetInstancePosition(instance)
			if position and (root.Position - position).Magnitude <= maxDistance then
				return true
			end
		end
	end
	return false
end

-- Memasang handler RemoteFunction yang sudah dilindungi (jumlah argumen + rate limit + pcall)
function RemoteGuard.BindFunction(remote: RemoteFunction, options: FunctionOptions, handler: (Player, ...any) -> any): ()
	remote.OnServerInvoke = function(player: Player, ...: any): any
		if select("#", ...) > options.MaxArgs then
			RemoteGuard.Flag(player, "TooManyArgs:" .. options.Key)
			return options.OnReject("Permintaan tidak valid.")
		end
		if not RemoteGuard.CheckRate(player, options.Key, options.Cooldown) then
			return options.OnReject("Pelan-pelan ya! Coba lagi sebentar.")
		end
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[RemoteGuard] Error di handler %s untuk %s: %s", options.Key, player.Name, tostring(result)))
			return options.OnReject("Terjadi kesalahan di server. Coba lagi ya.")
		end
		return result
	end
end

-- Versi RemoteEvent (tanpa nilai balik). Belum dipakai di Tahap 1, disiapkan untuk tahap berikutnya.
function RemoteGuard.BindEvent(remote: RemoteEvent, options: EventOptions, handler: (Player, ...any) -> ()): RBXScriptConnection
	return remote.OnServerEvent:Connect(function(player: Player, ...: any)
		if select("#", ...) > options.MaxArgs then
			RemoteGuard.Flag(player, "TooManyArgs:" .. options.Key)
			return
		end
		if not RemoteGuard.CheckRate(player, options.Key, options.Cooldown) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[RemoteGuard] Error di handler %s untuk %s: %s", options.Key, player.Name, tostring(err)))
		end
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastCallTimes[player] = nil
	violations[player] = nil
end)

return RemoteGuard
