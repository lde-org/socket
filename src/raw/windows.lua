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
	int    ioctlsocket(SOCKET s, long cmd, unsigned long *argp);
	int    WSAPoll(struct pollfd *fds, unsigned long nfds, int timeout);
	struct pollfd {
		SOCKET fd;
		short  events;
		short  revents;
	};
	u_short       htons(u_short hostshort);
	u_short       ntohs(u_short netshort);
	unsigned long inet_addr(const char *cp);
	int    sendto(SOCKET s, const char *buf, int len, int flags, const struct sockaddr *to, int tolen);
	int    recvfrom(SOCKET s, char *buf, int len, int flags, struct sockaddr *from, int *fromlen);
	int    getsockname(SOCKET s, struct sockaddr *name, int *namelen);
	int    WSAGetLastError(void);
	int    WSAStartup(unsigned short wVersionRequested, void *lpWSAData);

	-- winsock order: ai_canonname precedes ai_addr (unlike glibc)
	struct addrinfo {
		int              ai_flags;
		int              ai_family;
		int              ai_socktype;
		int              ai_protocol;
		size_t           ai_addrlen;
		char            *ai_canonname;
		struct sockaddr *ai_addr;
		struct addrinfo *ai_next;
	};
	int         getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
	void        freeaddrinfo(struct addrinfo *res);
	const char *gai_strerror(int errcode);
]])

local ws2 = ffi.load("ws2_32")

local AF_INET        = 2
local SOCK_STREAM    = 1
local SOCK_DGRAM     = 2
local RECV_BUF       = 4096
local SOCKADDR_SIZE  = ffi.sizeof("struct sockaddr_in")

-- Cached ctypes: ffi.typeof parses the declaration once instead of on every
-- ffi.new/ffi.cast call.
local socketT    = ffi.typeof("SOCKET")
local sockaddrIn = ffi.typeof("struct sockaddr_in")
local sockaddrP  = ffi.typeof("struct sockaddr *")
local intBuf     = ffi.typeof("int[1]")
local longBuf    = ffi.typeof("unsigned long[1]")
local recvBuf    = ffi.typeof("char[?]")

-- WSAPoll is synchronous, so one growable fd array is safe to reuse.
local pollfdArr = ffi.typeof("struct pollfd[?]")
local pollfds, pollfdsCap

local INVALID_SOCKET = ffi.cast(socketT, -1)

-- ioctlsocket
local FIONBIO = 0x8004667E

-- recv/send/accept report this instead of blocking on a non-blocking socket.
local WSAEWOULDBLOCK = 10035

-- WSAPoll event bits; HUP/ERR/NVAL count as readable so callers notice
-- closed peers and failures instead of waiting forever.
local POLLIN     = 0x001
local POLLERR    = 0x008
local POLLHUP    = 0x010
local POLLNVAL   = 0x020
local POLL_READY = POLLIN | POLLERR | POLLHUP | POLLNVAL

-- WSAData buffer: 408 bytes covers both 32- and 64-bit layouts
local wsadata        = ffi.typeof("char[408]")()
ws2.WSAStartup(0x0202, wsadata)

---@return string
local function errmsg()
	return "WSAError " .. ws2.WSAGetLastError()
end

---@param address string
---@param port integer
---@return ffi.cdata*
local function newSockaddrIn(address, port)
	local addr           = sockaddrIn()
	addr.sin_family      = AF_INET
	addr.sin_port        = ws2.htons(port)
	addr.sin_addr.s_addr = ws2.inet_addr(address)
	return addr
end

---@return socket.raw.Handle?, string?
function socket.tcp()
	local s = ws2.socket(AF_INET, SOCK_STREAM, 0)
	if s == INVALID_SOCKET then
		return nil, "socket failed: " .. errmsg()
	end

	return s
end

---@return socket.raw.Handle?, string?
function socket.udp()
	local s = ws2.socket(AF_INET, SOCK_DGRAM, 0)
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
	local addr = newSockaddrIn(address, port)
	if ws2.connect(handle, ffi.cast(sockaddrP, addr), SOCKADDR_SIZE) ~= 0 then
		return nil, "connect failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.bind(handle, address, port)
	local addr = newSockaddrIn(address, port)
	if ws2.bind(handle, ffi.cast(sockaddrP, addr), SOCKADDR_SIZE) ~= 0 then
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
	local addr    = sockaddrIn()
	local addrlen = intBuf(SOCKADDR_SIZE)
	local s       = ws2.accept(handle, ffi.cast(sockaddrP, addr), addrlen)

	if s == INVALID_SOCKET then
		if ws2.WSAGetLastError() == WSAEWOULDBLOCK then
			return nil, "would block"
		end

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
		if ws2.WSAGetLastError() == WSAEWOULDBLOCK then
			return nil, "would block"
		end

		return nil, "read failed: " .. errmsg()
	end

	if n == 0 then
		return nil, "connection closed"
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
		if ws2.WSAGetLastError() == WSAEWOULDBLOCK then
			return nil, "would block"
		end

		return nil, "write failed: " .. errmsg()
	end

	return n
end

--- Toggles non-blocking mode. Readiness must then be checked with
--- `socket.poll`; reads, writes and accepts report "would block" instead of
--- hanging when there is nothing to do.
---@param handle socket.raw.Handle
---@param enable boolean
---@return true?, string?
function socket.setnonblocking(handle, enable)
	local arg = longBuf(enable ? 1 : 0)
	if ws2.ioctlsocket(handle, FIONBIO, arg) ~= 0 then
		return nil, "ioctlsocket failed: " .. errmsg()
	end

	return true
end

--- Polls raw handles for readability. Returns the 1-based indexes into
--- `handles` that are ready (including peers that closed). `timeout` is in
--- milliseconds; pass -1 (or nil upstream) to wait forever and 0 to only
--- check.
---@param handles socket.raw.Handle[]
---@param timeout integer
---@return integer[]?, string?
function socket.poll(handles, timeout)
	local n   = #handles
	if not pollfds or n > pollfdsCap then
		pollfds    = pollfdArr(n)
		pollfdsCap = n
	end

	local fds = pollfds

	for i = 0, n - 1 do
		fds[i].fd     = handles[i + 1]
		fds[i].events = POLLIN
	end

	local ret = ws2.WSAPoll(fds, n, timeout)
	if ret < 0 then
		return nil, "poll failed: " .. errmsg()
	end

	local ready = {}
	if ret == 0 then
		return ready
	end

	for i = 0, n - 1 do
		if fds[i].revents & POLL_READY ~= 0 then
			ready[#ready + 1] = i + 1
		end
	end

	return ready
end

---@param handle socket.raw.Handle
---@param data string
---@param address string
---@param port integer
---@return true?, string?
function socket.sendto(handle, data, address, port)
	local addr = newSockaddrIn(address, port)
	if ws2.sendto(handle, data, #data, 0, ffi.cast(sockaddrP, addr), SOCKADDR_SIZE) < 0 then
		if ws2.WSAGetLastError() == WSAEWOULDBLOCK then
			return nil, "would block"
		end

		return nil, "sendto failed: " .. errmsg()
	end
	return true
end

---@param handle socket.raw.Handle
---@return string?, string?, number?, string?
function socket.recvfrom(handle)
	local buf     = recvBuf(RECV_BUF)
	local addr    = sockaddrIn()
	local addrlen = intBuf(SOCKADDR_SIZE)
	local n       = ws2.recvfrom(handle, buf, RECV_BUF, 0, ffi.cast(sockaddrP, addr), addrlen)

	if n < 0 then
		if ws2.WSAGetLastError() == WSAEWOULDBLOCK then
			return nil, nil, nil, "would block"
		end

		return nil, nil, nil, "recvfrom failed: " .. errmsg()
	end

	local s_addr = addr.sin_addr.s_addr
	local ip     = string.format("%d.%d.%d.%d",
		bit.band(s_addr, 0xFF),
		bit.band(bit.rshift(s_addr, 8), 0xFF),
		bit.band(bit.rshift(s_addr, 16), 0xFF),
		bit.band(bit.rshift(s_addr, 24), 0xFF))

	return ffi.string(buf, n), ip, tonumber(ws2.ntohs(addr.sin_port))
end

---@param handle socket.raw.Handle
---@return string?, number?, string?
function socket.getsockname(handle)
	local addr    = sockaddrIn()
	local addrlen = intBuf(SOCKADDR_SIZE)
	if ws2.getsockname(handle, ffi.cast(sockaddrP, addr), addrlen) ~= 0 then
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

--- Resolves a hostname to a dotted-quad IPv4 address via the native
--- resolver (getaddrinfo). Blocking, like everything else here.
---@param host string
---@return string?, string?
function socket.resolve(host)
	local hints = ffi.new("struct addrinfo")
	hints.ai_family   = AF_INET
	hints.ai_socktype = SOCK_STREAM

	local res = ffi.new("struct addrinfo *[1]")
	local code = ws2.getaddrinfo(host, nil, hints, res)
	if code ~= 0 then
		return nil, "resolve failed: " .. ffi.string(ws2.gai_strerror(code))
	end

	local ip
	local ai = res[0]
	while ai ~= nil do
		if ai.ai_addr ~= nil then
			local addr = ffi.cast("struct sockaddr_in *", ai.ai_addr)
			local s_addr = addr.sin_addr.s_addr
			ip = string.format("%d.%d.%d.%d",
				bit.band(s_addr, 0xFF),
				bit.band(bit.rshift(s_addr, 8), 0xFF),
				bit.band(bit.rshift(s_addr, 16), 0xFF),
				bit.band(bit.rshift(s_addr, 24), 0xFF))
			break
		end

		ai = ai.ai_next
	end

	ws2.freeaddrinfo(res[0])
	if not ip then
		return nil, "no IPv4 address for " .. host
	end

	return ip
end

return socket
