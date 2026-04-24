---@class socket.raw.windows: socket.raw
local socket = {}

local ffi = require("ffi")

ffi.cdef([[
	typedef unsigned int  SOCKET;
	typedef unsigned short u_short;

	struct in_addr {
		unsigned long s_addr;
	};

	struct sockaddr {
		unsigned short sa_family;
		char           sa_data[14];
	};

	struct sockaddr_in {
		short          sin_family;
		u_short        sin_port;
		struct in_addr sin_addr;
		char           sin_zero[8];
	};

	SOCKET socket(int af, int type, int protocol);
	int    connect(SOCKET s, const struct sockaddr *name, int namelen);
	int    bind(SOCKET s, const struct sockaddr *name, int namelen);
	int    listen(SOCKET s, int backlog);
	SOCKET accept(SOCKET s, struct sockaddr *addr, int *addrlen);
	int    recv(SOCKET s, char *buf, int len, int flags);
	int    send(SOCKET s, const char *buf, int len, int flags);
	int    closesocket(SOCKET s);
	u_short       htons(u_short hostshort);
	u_short       ntohs(u_short netshort);
	unsigned long inet_addr(const char *cp);
	int    sendto(SOCKET s, const char *buf, int len, int flags, const struct sockaddr *to, int tolen);
	int    recvfrom(SOCKET s, char *buf, int len, int flags, struct sockaddr *from, int *fromlen);
	int    getsockname(SOCKET s, struct sockaddr *name, int *namelen);
	int    WSAGetLastError(void);
	int    WSAStartup(unsigned short wVersionRequested, void *lpWSAData);
]])

local ws2 = ffi.load("ws2_32")

local AF_INET        = 2
local SOCK_STREAM    = 1
local SOCK_DGRAM     = 2
local RECV_BUF       = 4096
local INVALID_SOCKET = ffi.cast("SOCKET", -1)

-- WSAData buffer: 408 bytes covers both 32- and 64-bit layouts
local wsadata        = ffi.new("char[408]")
ws2.WSAStartup(0x0202, wsadata)

---@return string
local function errmsg()
	return "WSAError " .. ws2.WSAGetLastError()
end

---@return socket.raw.Handle?, string?
function socket.socket()
	local s = ws2.socket(AF_INET, SOCK_STREAM, 0)
	if s == INVALID_SOCKET then
		return nil, "socket failed: " .. errmsg()
	end

	return s
end

---@param handle socket.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.connect(handle, address, port)
	local addr           = ffi.new("struct sockaddr_in")
	addr.sin_family      = AF_INET
	addr.sin_port        = ws2.htons(port)
	addr.sin_addr.s_addr = ws2.inet_addr(address)

	if ws2.connect(handle, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) ~= 0 then
		return nil, "connect failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.bind(handle, address, port)
	local addr           = ffi.new("struct sockaddr_in")
	addr.sin_family      = AF_INET
	addr.sin_port        = ws2.htons(port)
	addr.sin_addr.s_addr = ws2.inet_addr(address)

	if ws2.bind(handle, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) ~= 0 then
		return nil, "bind failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@param backlog integer
---@return true?, string?
function socket.listen(handle, backlog)
	if ws2.listen(handle, backlog) ~= 0 then
		return nil, "listen failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@return socket.raw.Handle?, string?
function socket.accept(handle)
	local addr    = ffi.new("struct sockaddr_in")
	local addrlen = ffi.new("int[1]", ffi.sizeof(addr))
	local s       = ws2.accept(handle, ffi.cast("struct sockaddr *", addr), addrlen)

	if s == INVALID_SOCKET then
		return nil, "accept failed: " .. errmsg()
	end

	return s
end

---@param handle socket.raw.Handle
---@param buf ffi.cdata*
---@param len number
---@return number?, string?
function socket.read(handle, buf, len)
	local n = ws2.recv(handle, buf, len, 0)
	if n < 0 then
		return nil, "read failed: " .. errmsg()
	end

	return n
end

---@param handle socket.raw.Handle
---@param data ffi.cdata*
---@param len number
---@return number?, string?
function socket.write(handle, data, len)
	local n = ws2.send(handle, data, len, 0)
	if n < 0 then
		return nil, "write failed: " .. errmsg()
	end

	return n
end

---@param handle socket.raw.Handle
---@return string?, number?, string?
function socket.getsockname(handle)
	local addr    = ffi.new("struct sockaddr_in")
	local addrlen = ffi.new("int[1]", ffi.sizeof(addr))
	if ws2.getsockname(handle, ffi.cast("struct sockaddr *", addr), addrlen) ~= 0 then
		return nil, nil, "getsockname failed: " .. errmsg()
	end
	local s_addr = addr.sin_addr.s_addr
	local ip = string.format("%d.%d.%d.%d",
		bit.band(s_addr, 0xFF),
		bit.band(bit.rshift(s_addr, 8), 0xFF),
		bit.band(bit.rshift(s_addr, 16), 0xFF),
		bit.band(bit.rshift(s_addr, 24), 0xFF))
	return ip, tonumber(ws2.ntohs(addr.sin_port))
end

---@param handle socket.raw.Handle
---@return true?, string?
function socket.close(handle)
	if ws2.closesocket(handle) ~= 0 then
		return nil, "close failed: " .. errmsg()
	end

	return true
end

return socket
