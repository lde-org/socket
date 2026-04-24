---@class net.raw.socket.posix: net.raw.socket
local socket = {}

local ffi = require("ffi")

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

	int    socket(int domain, int type, int protocol);
	int    connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
	int    bind(int sockfd, const struct sockaddr *addr, socklen_t addrlen);
	int    listen(int sockfd, int backlog);
	int    accept(int sockfd, struct sockaddr *addr, socklen_t *addrlen);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	int    close(int fd);
	unsigned short htons(unsigned short hostshort);
	unsigned short ntohs(unsigned short netshort);
	unsigned int   inet_addr(const char *cp);
	char  *strerror(int errnum);
	ssize_t sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest_addr, socklen_t addrlen);
	ssize_t recvfrom(int sockfd, void *buf, size_t len, int flags, struct sockaddr *src_addr, socklen_t *addrlen);
	int     getsockname(int sockfd, struct sockaddr *addr, socklen_t *addrlen);

	extern int errno;
]])

local AF_INET     = 2
local SOCK_STREAM = 1
local SOCK_DGRAM  = 2
local RECV_BUF    = 4096

---@return string
local function errmsg()
	return ffi.string(ffi.C.strerror(ffi.C.errno))
end

---@return net.raw.Handle?, string?
function socket.tcp()
	local fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 then
		return nil, "socket failed: " .. errmsg()
	end

	return fd
end

---@param handle net.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.connect(handle, address, port)
	local addr      = ffi.new("struct sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port   = ffi.C.htons(port)
	addr.sin_addr   = ffi.C.inet_addr(address)

	if ffi.C.connect(handle, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
		return nil, "connect failed: " .. errmsg()
	end

	return true
end

---@param handle net.raw.Handle
---@param address string
---@param port integer
---@return true?, string?
function socket.bind(handle, address, port)
	local addr      = ffi.new("struct sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port   = ffi.C.htons(port)
	addr.sin_addr   = ffi.C.inet_addr(address)

	if ffi.C.bind(handle, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
		return nil, "bind failed: " .. errmsg()
	end

	return true
end

---@param handle net.raw.Handle
---@param backlog integer
---@return true?, string?
function socket.listen(handle, backlog)
	if ffi.C.listen(handle, backlog) < 0 then
		return nil, "listen failed: " .. errmsg()
	end

	return true
end

---@param handle net.raw.Handle
---@return net.raw.Handle?, string?
function socket.accept(handle)
	local addr    = ffi.new("struct sockaddr_in")
	local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(addr))

	local fd      = ffi.C.accept(handle, ffi.cast("struct sockaddr *", addr), addrlen)
	if fd < 0 then
		return nil, "accept failed: " .. errmsg()
	end

	return fd
end

---@param handle net.raw.Handle
---@param buf ffi.cdata*
---@param len number
---@return number?, string?
function socket.read(handle, buf, len)
	local n = ffi.C.read(handle, buf, len)

	if n < 0 then
		return nil, "read failed: " .. errmsg()
	end

	return n
end

---@param handle net.raw.Handle
---@param data ffi.cdata*
---@param len number
---@return number?, string?
function socket.write(handle, data, len)
	local n = ffi.C.write(handle, data, len)
	if n < 0 then
		return nil, "write failed: " .. errmsg()
	end

	return n
end

---@param handle net.raw.Handle
---@return true?, string?
function socket.close(handle)
	if ffi.C.close(handle) < 0 then
		return nil, "close failed: " .. errmsg()
	end

	return true
end

---@return net.raw.Handle?, string?
function socket.udp()
	local fd = ffi.C.socket(AF_INET, SOCK_DGRAM, 0)
	if fd < 0 then
		return nil, "socket failed: " .. errmsg()
	end

	return fd
end

---@param handle net.raw.Handle
---@param data string
---@param address string
---@param port integer
---@return true?, string?
function socket.sendto(handle, data, address, port)
	local addr      = ffi.new("struct sockaddr_in")
	addr.sin_family = AF_INET
	addr.sin_port   = ffi.C.htons(port)
	addr.sin_addr   = ffi.C.inet_addr(address)
	if ffi.C.sendto(handle, data, #data, 0, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
		return nil, "sendto failed: " .. errmsg()
	end
	return true
end

---@param handle net.raw.Handle
---@return string?, number?, string?
function socket.getsockname(handle)
	local addr    = ffi.new("struct sockaddr_in")
	local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(addr))
	if ffi.C.getsockname(handle, ffi.cast("struct sockaddr *", addr), addrlen) < 0 then
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

---@param handle net.raw.Handle
---@return string?, string?, number?, string?
function socket.recvfrom(handle)
	local buf     = ffi.new("char[?]", RECV_BUF)
	local addr    = ffi.new("struct sockaddr_in")
	local addrlen = ffi.new("socklen_t[1]", ffi.sizeof(addr))
	local n       = ffi.C.recvfrom(handle, buf, RECV_BUF, 0, ffi.cast("struct sockaddr *", addr), addrlen)

	if n < 0 then
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

return socket
