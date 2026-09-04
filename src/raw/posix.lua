---@class socket.raw.posix: socket.raw
local socket = {}

local ffi = require("ffi")

local isOsx = jit.os == "OSX"

if isOsx then
	ffi.cdef([[
		typedef unsigned int socklen_t;

		struct sockaddr {
			unsigned char  sa_len;
			unsigned char  sa_family;
			char           sa_data[14];
		};

		struct sockaddr_in {
			unsigned char  sin_len;
			unsigned char  sin_family;
			unsigned short sin_port;
			unsigned int   sin_addr;
			char           sin_zero[8];
		};
	]])
else
	ffi.cdef([[
		typedef int socklen_t;

		struct sockaddr {
			unsigned short sa_family;
			char           sa_data[14];
		};

		struct sockaddr_in {
			unsigned short sin_family;
			unsigned short sin_port;
			unsigned int   sin_addr;
			char           sin_zero[8];
		};
	]])
end

ffi.cdef([[
	int    socket(int domain, int type, int protocol);
	int    connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
	int    bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
	int    listen(int sockfd, int backlog);
	int    accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	int    close(int fd);
	int    fcntl(int fd, int cmd, int arg);
	int    poll(struct pollfd *fds, unsigned long nfds, int timeout);
	struct pollfd {
		int    fd;
		short  events;
		short  revents;
	};
	unsigned short htons(unsigned short hostshort);
	unsigned short ntohs(unsigned short netshort);
	unsigned int   inet_addr(const char *cp);
	char  *strerror(int errnum);
	ssize_t sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen);
	ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags, struct sockaddr *src_addr, socklen_t *addrlen);
	int     getsockname(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
]])

local AF_INET       = 2
local SOCK_STREAM   = 1
local SOCK_DGRAM    = 2
local RECV_BUF      = 4096
local SOCKADDR_SIZE = ffi.sizeof("struct sockaddr_in")

-- fcntl
local F_GETFL     = 3
local F_SETFL     = 4
local O_NONBLOCK  = isOsx and 0x0004 or 0x0800

-- EAGAIN == EWOULDBLOCK differs per platform.
local WOULD_BLOCK = isOsx and 35 or 11

-- poll(2) event bits; HUP/ERR/NVAL count as readable so callers notice
-- closed peers and failures instead of waiting forever.
local POLLIN     = 0x001
local POLLERR    = 0x008
local POLLHUP    = 0x010
local POLLNVAL   = 0x020
local POLL_READY = POLLIN | POLLERR | POLLHUP | POLLNVAL

-- Cached ctypes: ffi.typeof parses the declaration once instead of on every
-- ffi.new/ffi.cast call.
local sockaddrIn = ffi.typeof("struct sockaddr_in")
local sockaddrP  = ffi.typeof("struct sockaddr *")
local socklenBuf = ffi.typeof("socklen_t[1]")
local recvBuf    = ffi.typeof("char[?]")

-- poll() is synchronous, so one growable fd array is safe to reuse.
local pollfdArr = ffi.typeof("struct pollfd[?]")
local pollfds, pollfdsCap

---@return string
local function errmsg()
	return ffi.string(ffi.C.strerror(ffi.errno()))
end

---@param address string
---@param port integer
---@return ffi.cdata*
local function newSockaddrIn(address, port)
	local addr      = sockaddrIn()
	addr.sin_family = AF_INET
	addr.sin_port   = ffi.C.htons(port)
	addr.sin_addr   = ffi.C.inet_addr(address)

	if isOsx then
		addr.sin_len = SOCKADDR_SIZE
	end

	return addr
end

---@return socket.raw.Handle?, string?
function socket.tcp()
	local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then
		return nil, "socket failed: " .. errmsg()
	end

	return fd
end

---@param handle socket.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.connect(handle, address, port)
	local addr = newSockaddrIn(address, port)
	if ffi.C.connect(handle, ffi.cast(sockaddrP, addr), SOCKADDR_SIZE) < 0 then
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
	if ffi.C.bind(handle, ffi.cast(sockaddrP, addr), SOCKADDR_SIZE) < 0 then
		return nil, "bind failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@param backlog integer
---@return true?, string?
function socket.listen(handle, backlog)
	if ffi.C.listen(handle, backlog) < 0 then
		return nil, "listen failed: " .. errmsg()
	end

	return true
end

---@param handle socket.raw.Handle
---@return socket.raw.Handle?, string?
function socket.accept(handle)
	local addr    = sockaddrIn()
	local addrlen = socklenBuf(SOCKADDR_SIZE)

	local fd      = ffi.C.accept(handle, ffi.cast(sockaddrP, addr), addrlen)
	if fd < 0 then
		if ffi.errno() == WOULD_BLOCK then
			return nil, "would block"
		end

		return nil, "accept failed: " .. errmsg()
	end

	return fd
end

---@param handle socket.raw.Handle
---@param buf ffi.cdata*
---@param len number
---@return number?, string?
function socket.read(handle, buf, len)
	local n = ffi.C.read(handle, buf, len)

	if n < 0 then
		if ffi.errno() == WOULD_BLOCK then
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
	local n = ffi.C.write(handle, data, len)
	if n < 0 then
		if ffi.errno() == WOULD_BLOCK then
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
	-- The extra 0 arg is ignored for F_GETFL but keeps the declared arity.
	local flags = ffi.C.fcntl(handle, F_GETFL, 0)
	if flags < 0 then
		return nil, "fcntl failed: " .. errmsg()
	end

	if enable then
		flags = flags | O_NONBLOCK
	else
		flags = flags & ~O_NONBLOCK
	end

	if ffi.C.fcntl(handle, F_SETFL, flags) < 0 then
		return nil, "fcntl failed: " .. errmsg()
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

	local ret = ffi.C.poll(fds, n, timeout)
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
---@return true?, string?
function socket.close(handle)
	if ffi.C.close(handle) < 0 then
		return nil, "close failed: " .. errmsg()
	end

	return true
end

---@return socket.raw.Handle?, string?
function socket.udp()
	local fd = ffi.C.socket(AF_INET, SOCK_DGRAM, 0)
	if fd < 0 then
		return nil, "socket failed: " .. errmsg()
	end

	return fd
end

---@param handle socket.raw.Handle
---@param data string
---@param address string
---@param port integer
---@return true?, string?
function socket.sendto(handle, data, address, port)
	local addr      = sockaddrIn()
	addr.sin_family = AF_INET
	addr.sin_port   = ffi.C.htons(port)
	addr.sin_addr   = ffi.C.inet_addr(address)
	if ffi.C.sendto(handle, data, #data, 0, ffi.cast(sockaddrP, addr), ffi.sizeof(addr)) < 0 then
		if ffi.errno() == WOULD_BLOCK then
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
	local addrlen = socklenBuf(SOCKADDR_SIZE)
	local n       = ffi.C.recvfrom(handle, buf, RECV_BUF, 0, ffi.cast(sockaddrP, addr), addrlen)

	if n < 0 then
		if ffi.errno() == WOULD_BLOCK then
			return nil, nil, nil, "would block"
		end

		return nil, nil, nil, "recvfrom failed: " .. errmsg()
	end

	local raw = addr.sin_addr

	local ip  = string.format("%d.%d.%d.%d",
		bit.band(raw, 0xFF),
		bit.band(bit.rshift(raw, 8), 0xFF),
		bit.band(bit.rshift(raw, 16), 0xFF),
		bit.band(bit.rshift(raw, 24), 0xFF))

	return ffi.string(buf, n), ip, tonumber(ffi.C.ntohs(addr.sin_port))
end

---@param handle socket.raw.Handle
---@return string?, number?, string?
function socket.getsockname(handle)
	local addr    = sockaddrIn()
	local addrlen = socklenBuf(SOCKADDR_SIZE)
	if ffi.C.getsockname(handle, ffi.cast(sockaddrP, addr), addrlen) < 0 then
		return nil, nil, "getsockname failed: " .. errmsg()
	end
	local raw_addr = addr.sin_addr
	local ip = string.format("%d.%d.%d.%d",
		bit.band(raw_addr, 0xFF),
		bit.band(bit.rshift(raw_addr, 8), 0xFF),
		bit.band(bit.rshift(raw_addr, 16), 0xFF),
		bit.band(bit.rshift(raw_addr, 24), 0xFF))
	return ip, tonumber(ffi.C.ntohs(addr.sin_port))
end

return socket
