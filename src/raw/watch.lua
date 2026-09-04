---@class socket.raw.watch
local watch = {}

local ffi = require("ffi")

local isLinux = jit.os == "Linux"
local isOsx   = jit.os == "OSX"

-- Level-triggered readiness watchers. Handles are raw fds (or SOCKETs on
-- Windows); every add gets a stable integer id returned by wait().

---@class socket.raw.Watcher
---@field add fun(self: socket.raw.Watcher, handle: socket.raw.Handle): integer
---@field remove fun(self: socket.raw.Watcher, sid: integer)
---@field wait fun(self: socket.raw.Watcher, timeout: integer?): integer[]?, string?
---@field close fun(self: socket.raw.Watcher)

local watcher = {}
watcher.__index = watcher

-- epoll (Linux): O(1) per event, reports only ready fds.
if isLinux then
	-- struct epoll_event is packed in the kernel: events at offset 0 and the
	-- 64-bit data at offset 4. Spell that out as two u32 halves so the layout
	-- matches without relying on attribute support.
	ffi.cdef([[
		struct epoll_event {
			uint32_t events;
			uint32_t data_lo;
			uint32_t data_hi;
		};

		int epoll_create1(int flags);
		int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
		int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
	]])

	local EPOLLIN      = 0x001
	local EPOLLERR     = 0x008
	local EPOLLHUP     = 0x010
	local EPOLL_CTL_ADD = 1
	local EPOLL_CTL_DEL = 2
	local READY        = EPOLLIN | EPOLLERR | EPOLLHUP

	---@type socket.raw.Watcher
	local Epoll = {}
	Epoll.__index = Epoll

	---@return socket.raw.Watcher
	function watch.new()
		local self = setmetatable({
			epfd = ffi.C.epoll_create1(0),
			events = ffi.new("struct epoll_event[64]"),
			bySid = {},
			sidByFd = {},
			next = 1,
		}, Epoll)

		assert(self.epfd >= 0)
		return self
	end

	---@param handle socket.raw.Handle
	---@return integer
	function Epoll:add(handle)
		local sid = self.next
		self.next = self.next + 1

		local event = ffi.new("struct epoll_event")
		event.events  = EPOLLIN
		event.data_lo = sid
		event.data_hi = 0
		ffi.C.epoll_ctl(self.epfd, EPOLL_CTL_ADD, handle, event)

		self.bySid[sid] = handle
		self.sidByFd[handle] = sid
		return sid
	end

	---@param sid integer
	function Epoll:remove(sid)
		local handle = self.bySid[sid]
		if not handle then
			return
		end

		ffi.C.epoll_ctl(self.epfd, EPOLL_CTL_DEL, handle, nil)
		self.bySid[sid] = nil
		self.sidByFd[handle] = nil
	end

	---@param timeout integer?
	---@return integer[]?, string?
	function Epoll:wait(timeout)
		local n = ffi.C.epoll_wait(self.epfd, self.events, 64, timeout or -1)
		if n < 0 then
			return nil, "epoll_wait failed"
		end

		local ready = {}
		for i = 0, n - 1 do
			if self.events[i].events & READY ~= 0 then
				ready[#ready + 1] = self.events[i].data_lo
			end
		end

		return ready
	end

	function Epoll:close()
		ffi.C.close(self.epfd)
	end

	return watch
end

-- kqueue (macOS): equivalent readiness primitive.
if isOsx then
	ffi.cdef([[
		struct kevent {
			uintptr_t      ident;
			int16_t        filter;
			uint16_t       flags;
			uint32_t       fflags;
			intptr_t       data;
			void          *udata;
		};

		int kqueue(void);
		int kevent(int kq, const struct kevent *changelist, int nchanges,
			struct kevent *eventlist, int nevents, const struct timespec *timeout);
		struct timespec {
			long tv_sec;
			long tv_nsec;
		};
	]])

	local EVFILT_READ  = -1
	local EV_ADD       = 0x0001
	local EV_DELETE    = 0x0002
	local EV_EOF       = 0x8000

	---@type socket.raw.Watcher
	local Kqueue = {}
	Kqueue.__index = Kqueue

	---@return socket.raw.Watcher
	function watch.new()
		local self = setmetatable({
			kq = ffi.C.kqueue(),
			events = ffi.new("struct kevent[64]"),
			bySid = {},
			next = 1,
		}, Kqueue)

		assert(self.kq >= 0)
		return self
	end

	---@param handle socket.raw.Handle
	---@return integer
	function Kqueue:add(handle)
		local sid = self.next
		self.next = self.next + 1

		local change = ffi.new("struct kevent")
		change.ident  = handle
		change.filter = EVFILT_READ
		change.flags  = EV_ADD
		change.udata  = ffi.cast("void*", sid)
		ffi.C.kevent(self.kq, change, 1, nil, 0, nil)

		self.bySid[sid] = handle
		return sid
	end

	---@param sid integer
	function Kqueue:remove(sid)
		local handle = self.bySid[sid]
		if not handle then
			return
		end

		local change = ffi.new("struct kevent")
		change.ident  = handle
		change.filter = EVFILT_READ
		change.flags  = EV_DELETE
		ffi.C.kevent(self.kq, change, 1, nil, 0, nil)

		self.bySid[sid] = nil
	end

	---@param timeout integer?
	---@return integer[]?, string?
	function Kqueue:wait(timeout)
		local ts
		if timeout ~= nil then
			ts = ffi.new("struct timespec")
			ts.tv_sec  = math.floor(timeout / 1000)
			ts.tv_nsec = (timeout % 1000) * 1e6
		end

		local n = ffi.C.kevent(self.kq, nil, 0, self.events, 64, ts)
		if n < 0 then
			return nil, "kevent failed"
		end

		local ready = {}
		for i = 0, n - 1 do
			-- Any returned read filter event means readable or EOF.
			ready[#ready + 1] = tonumber(ffi.cast("uintptr_t", self.events[i].udata))
		end

		return ready
	end

	function Kqueue:close()
		ffi.C.close(self.kq)
	end

	return watch
end

-- poll / WSAPoll (everything else): O(n) but portable.
local rawModule = require(jit.os == "Windows" ? "socket.raw.windows" : "socket.raw.posix")

---@type socket.raw.Watcher
local Poll = {}
Poll.__index = Poll

---@return socket.raw.Watcher
function watch.new()
	return setmetatable({
		handles = {},
		bySid = {},
		next = 1,
	}, Poll)
end

---@param handle socket.raw.Handle
---@return integer
function Poll:add(handle)
	local sid = self.next
	self.next = self.next + 1

	self.handles[#self.handles + 1] = handle
	self.bySid[sid] = handle
	return sid
end

---@param sid integer
function Poll:remove(sid)
	local handle = self.bySid[sid]
	if not handle then
		return
	end

	for i = 1, #self.handles do
		if self.handles[i] == handle then
			table.remove(self.handles, i)
			break
		end
	end

	self.bySid[sid] = nil
end

---@param timeout integer?
---@return integer[]?, string?
function Poll:wait(timeout)
	local readyIndexes, err = rawModule.poll(self.handles, timeout or -1)
	if not readyIndexes then
		return nil, err
	end

	local ready = {}
	for i = 1, #readyIndexes do
		local handle = self.handles[readyIndexes[i]]
		for sid, h in pairs(self.bySid) do
			if h == handle then
				ready[#ready + 1] = sid
				break
			end
		end
	end

	return ready
end

function Poll:close()
	-- nothing to release; poll is stateless
end

return watch
