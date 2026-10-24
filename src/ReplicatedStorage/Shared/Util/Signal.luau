--!strict
--[[
	Signal
	------
	Event sederhana untuk komunikasi antar-modul di sisi yang sama (server<->server atau client<->client).
	Lebih ringan daripada BindableEvent dan tidak menyalin tabel argumen.

	Pemakaian:
		local sig = Signal.new()
		local conn = sig:Connect(function(a, b) print(a, b) end)
		sig:Fire(1, 2)
		conn:Disconnect()
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
}

type Listener = {
	Handler: (...any) -> (),
	Connected: boolean,
}

local Signal = {}

function Signal.new(): Signal
	local listeners: { Listener } = {}
	local waitingThreads: { thread } = {}

	local self = {} :: any

	function self:Connect(handler: (...any) -> ()): Connection
		local listener: Listener = { Handler = handler, Connected = true }
		table.insert(listeners, listener)

		local connection = { Connected = true } :: any
		function connection:Disconnect()
			if not listener.Connected then
				return
			end
			listener.Connected = false
			connection.Connected = false
			local index = table.find(listeners, listener)
			if index then
				table.remove(listeners, index)
			end
		end
		return connection :: Connection
	end

	function self:Fire(...: any)
		-- Salin dulu agar aman jika ada listener yang disconnect saat iterasi
		local snapshot = table.clone(listeners)
		for _, listener in snapshot do
			if listener.Connected then
				task.spawn(listener.Handler, ...)
			end
		end

		local threads = waitingThreads
		waitingThreads = {}
		for _, thread in threads do
			task.spawn(thread, ...)
		end
	end

	function self:Wait(): ...any
		table.insert(waitingThreads, coroutine.running())
		return coroutine.yield()
	end

	function self:DisconnectAll()
		for _, listener in listeners do
			listener.Connected = false
		end
		table.clear(listeners)
	end

	return self :: Signal
end

return Signal
