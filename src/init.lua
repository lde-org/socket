local ffi = require("ffi")

---@class net
local net = {}

--- Opaque socket handle
---@class net.raw.Handle

---@class net.raw.socket
---@field tcp fun(): net.raw.Handle?, string?
---@field udp fun(): net.raw.Handle?, string?
---@field connect fun(handle: net.raw.Handle, address: string, port: number): true?, string?
---@field bind fun(handle: net.raw.Handle, address: string, port: number): true?, string?
---@field listen fun(handle: net.raw.Handle, backlog: number): true?, string?
---@field accept fun(handle: net.raw.Handle): net.raw.Handle?, string?
---@field read fun(handle: net.raw.Handle, buf: ffi.cdata*, len: number): number?, string?
---@field write fun(handle: net.raw.Handle, data: ffi.cdata*, len: number): number?, string?
---@field close fun(handle: net.raw.Handle): true?, string?
---@field sendto fun(handle: net.raw.Handle, data: string, address: string, port: number): true?, string?
---@field recvfrom fun(handle: net.raw.Handle): string?, string?, number?, string?
---@field getsockname fun(handle: net.raw.Handle): string?, number?, string?

local raw ---@type net.raw.socket
if jit.os == "Windows" then
	raw = require("net.raw.windows")
elseif jit.os == "OSX" or jit.os == "Linux" or jit.os == "POSIX" then
	raw = require("net.raw.posix")
end

---@class net.tcp
local tcp = {}
do
	---@class net.tcp.Listener
	---@field private handle net.raw.Handle
	local Listener = {}
	Listener.__index = Listener

	---@param handle net.raw.Handle
	function Listener.new(handle)
		return setmetatable({ handle = handle }, Listener)
	end

	---@class net.tcp.Stream
	---@field private handle net.raw.Handle
	local Stream = {}
	Stream.__index = Stream

	---@param handle net.raw.Handle
	function Stream.new(handle)
		return setmetatable({ handle = handle }, Stream)
	end

	---@param address string
	---@param port number
	---@return net.tcp.Listener?, string?
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
	---@return net.tcp.Stream?, string?
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

	---@param n number
	function Stream:read(n)
		local buf   = ffi.new("char[?]", n)

		local total = 0
		while total < n do
			local got, err = raw.read(self.handle, buf + total, n - total)
			if not got then
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
				return nil, "read failed: " .. err
			end

			total = total + got
		end

		return total
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

---@class net.udp
local udp = {}
do
	---@class net.udp.Socket
	---@field private handle net.raw.Handle
	local Socket = {}
	Socket.__index = Socket

	---@param handle net.raw.Handle
	function Socket.new(handle)
		return setmetatable({ handle = handle }, Socket)
	end

	---@param address string
	---@param port number
	---@return net.udp.Socket?, string?
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
	---@return net.udp.Socket?, string?
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
end

net.udp = udp
net.tcp = tcp

return net
