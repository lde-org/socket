local ffi = require("ffi")

---@class socket
local socket = {}

--- Opaque socket handle
---@class socket.raw.Handle

---@class socket.raw
---@field tcp fun(): socket.raw.Handle?, string?
---@field udp fun(): socket.raw.Handle?, string?
---@field connect fun(handle: socket.raw.Handle, address: string, port: number): true?, string?
---@field bind fun(handle: socket.raw.Handle, address: string, port: number): true?, string?
---@field listen fun(handle: socket.raw.Handle, backlog: number): true?, string?
---@field accept fun(handle: socket.raw.Handle): socket.raw.Handle?, string?
---@field read fun(handle: socket.raw.Handle, buf: ffi.cdata*, len: number): number?, string?
---@field write fun(handle: socket.raw.Handle, data: ffi.cdata*, len: number): number?, string?
---@field close fun(handle: socket.raw.Handle): true?, string?
---@field setnonblocking fun(handle: socket.raw.Handle, enable: boolean): true?, string?
---@field poll fun(handles: socket.raw.Handle[], timeout: integer): integer[]?, string?
---@field sendto fun(handle: socket.raw.Handle, data: string, address: string, port: number): true?, string?
---@field recvfrom fun(handle: socket.raw.Handle): string?, string?, number?, string?
---@field getsockname fun(handle: socket.raw.Handle): string?, number?, string?

local raw ---@type socket.raw
if jit.os == "Windows" then
	raw = require("socket.raw.windows")
elseif jit.os == "OSX" or jit.os == "Linux" or jit.os == "POSIX" then
	raw = require("socket.raw.posix")
end

---@class socket.tcp
local tcp = {}
do
	---@class socket.tcp.Listener
	---@field private handle socket.raw.Handle
	local Listener = {}
	Listener.__index = Listener

	---@param handle socket.raw.Handle
	function Listener.new(handle)
		return setmetatable({ handle = handle }, Listener)
	end

	---@class socket.tcp.Stream
	---@field private handle socket.raw.Handle
	local Stream = {}
	Stream.__index = Stream

	---@param handle socket.raw.Handle
	function Stream.new(handle)
		return setmetatable({ handle = handle }, Stream)
	end

	---@param address string
	---@param port number
	---@return socket.tcp.Listener?, string?
	function tcp.bind(address, port)
		local handle, err = raw.tcp()
		if not handle then
			return nil, err
		end

		local ok, err = raw.bind(handle, address, port)
		if not ok then
			raw.close(handle)
			return nil, err
		end

		local ok, err = raw.listen(handle, 128)
		if not ok then
			raw.close(handle)
			return nil, err
		end

		return Listener.new(handle), nil
	end

	---@param address string
	---@param port number
	function tcp.connect(address, port)
		local handle, err = raw.tcp()
		if not handle then
			return nil, err
		end

		local ok, err = raw.connect(handle, address, port)
		if not ok then
			raw.close(handle)
			return nil, err
		end

		return Stream.new(handle), nil
	end

	---@return string?, number?, string?
	function Listener:getLocalAddr()
		return raw.getsockname(self.handle)
	end

	function Listener:close()
		return raw.close(self.handle)
	end

	--- Toggles non-blocking mode; `accept` then reports "would block" when
	--- no connection is pending. Check readiness with `socket.poll`.
	---@param enable boolean
	---@return true?, string?
	function Listener:setNonBlocking(enable)
		return raw.setnonblocking(self.handle, enable)
	end

	function Listener:accept()
		local handle, err = raw.accept(self.handle)
		if not handle then
			return nil, err
		end

		return Stream.new(handle), nil
	end

	--- Returns an iterator that repeatedly calls `accept()` on this listener.
	function Listener:incoming()
		return Listener.accept, self, nil
	end

	--- Reads exactly n bytes. These exact reads assume a blocking stream;
	--- once a stream is non-blocking, use `readSome`/`readSomeInto` and
	--- drive them with `socket.poll`, since an exact read can stop partway
	--- with "would block" after already consuming bytes.
	---@param n number
	function Stream:read(n)
		local buf   = ffi.new("char[?]", n)

		local total = 0
		while total < n do
			local got, err = raw.read(self.handle, buf + total, n - total)
			if not got then
				if err == "would block" then
					return nil, err
				end

				return nil, "read failed: " .. err
			end

			total = total + got
		end

		return ffi.string(buf, n)
	end

	---@param n number
	---@param buf ffi.cdata*
	function Stream:readInto(n, buf)
		local total = 0
		while total < n do
			local got, err = raw.read(self.handle, buf + total, n - total)
			if not got then
				if err == "would block" then
					return nil, err
				end

				return nil, "read failed: " .. err
			end

			total = total + got
		end

		return total
	end

	--- Reads up to n bytes that are available right now, without looping.
	--- Blocking streams return as soon as at least one byte arrives; a
	--- non-blocking stream with nothing buffered returns nil + "would block".
	---@param n number
	---@return string?, string?
	function Stream:readSome(n)
		local buf   = ffi.new("char[?]", n)

		local got, err = raw.read(self.handle, buf, n)
		if not got then
			if err == "would block" then
				return nil, err
			end

			return nil, "read failed: " .. err
		end

		return ffi.string(buf, got)
	end

	--- Like `readSome`, but into a caller-provided buffer.
	---@param n number
	---@param buf ffi.cdata*
	---@return number?, string?
	function Stream:readSomeInto(n, buf)
		local got, err = raw.read(self.handle, buf, n)
		if not got then
			if err == "would block" then
				return nil, err
			end

			return nil, "read failed: " .. err
		end

		return got
	end

	--- Toggles non-blocking mode; reads then report "would block" instead of
	--- waiting. Check readiness with `socket.poll`.
	---@param enable boolean
	---@return true?, string?
	function Stream:setNonBlocking(enable)
		return raw.setnonblocking(self.handle, enable)
	end

	---@param buf ffi.cdata*|string
	---@param n number?
	function Stream:write(buf, n)
		if type(buf) == "string" then
			n = #buf
			buf = ffi.cast("char*", buf)
		end

		local total = 0
		while total < n do
			local got, err = raw.write(self.handle, buf + total, n - total)
			if not got then
				if err == "would block" then
					return nil, err
				end

				return nil, "write failed: " .. err
			end

			total = total + got
		end

		return total
	end

	---@return string?, number?, string?
	function Stream:getLocalAddr()
		return raw.getsockname(self.handle)
	end

	function Stream:close()
		return raw.close(self.handle)
	end
end

---@class socket.udp
local udp = {}
do
	---@class socket.udp.Socket
	---@field private handle socket.raw.Handle
	local Socket = {}
	Socket.__index = Socket

	---@param handle socket.raw.Handle
	function Socket.new(handle)
		return setmetatable({ handle = handle }, Socket)
	end

	---@param address string
	---@param port number
	---@return socket.udp.Socket?, string?
	function udp.bind(address, port)
		local handle, err = raw.udp()
		if not handle then
			return nil, err
		end

		local ok, err = raw.bind(handle, address, port)
		if not ok then
			raw.close(handle)
			return nil, err
		end

		return Socket.new(handle), nil
	end

	---@param address string
	---@param port number
	---@return socket.udp.Socket?, string?
	function udp.connect(address, port)
		local handle, err = raw.udp()
		if not handle then
			return nil, err
		end

		local ok, err = raw.connect(handle, address, port)
		if not ok then
			raw.close(handle)
			return nil, err
		end

		return Socket.new(handle), nil
	end

	---@param data string
	---@param address string
	---@param port number
	---@return true?, string?
	function Socket:sendTo(data, address, port)
		return raw.sendto(self.handle, data, address, port)
	end

	---@param data string|ffi.cdata*
	---@param n number?
	---@return true?, string?
	function Socket:send(data, n)
		if type(data) == "string" then
			n = #data
			data = ffi.cast("char*", data)
		end

		local got, err = raw.write(self.handle, data, n)
		if not got then
			if err == "would block" then
				return nil, err
			end

			return nil, "send failed: " .. err
		end

		return true
	end

	--- Returns data, sender address, sender port, or nil + error.
	---@return string?, string?, number?, string?
	function Socket:recvFrom()
		return raw.recvfrom(self.handle)
	end

	---@return string?, number?, string?
	function Socket:getLocalAddr()
		return raw.getsockname(self.handle)
	end

	function Socket:close()
		return raw.close(self.handle)
	end

	--- Toggles non-blocking mode; `recvFrom` then reports "would block"
	--- instead of waiting. Check readiness with `socket.poll`.
	---@param enable boolean
	---@return true?, string?
	function Socket:setNonBlocking(enable)
		return raw.setnonblocking(self.handle, enable)
	end
end

--- Polls sockets for readability, returning the subset that are ready. This
--- includes streams whose peer closed, so pollers can notice EOF. `handles`
--- may mix listeners, streams and udp sockets; `timeout` is in milliseconds
--- (nil waits forever, 0 only checks). The result is an empty table when
--- nothing is ready.
---@param handles (socket.tcp.Stream|socket.tcp.Listener|socket.udp.Socket)[]
---@param timeout integer?
---@return table?, string?
function socket.poll(handles, timeout)
	local rawHandles = {}
	for i = 1, #handles do
		rawHandles[i] = handles[i].handle
	end

	local readyIndexes, err = raw.poll(rawHandles, timeout or -1)
	if not readyIndexes then
		return nil, err
	end

	local ready = {}
	for i = 1, #readyIndexes do
		ready[i] = handles[readyIndexes[i]]
	end

	return ready
end

socket.udp = udp
socket.tcp = tcp

return socket
