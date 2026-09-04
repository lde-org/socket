local test = require("lde-test")
local ffi = require("ffi")

local socket = require("socket")

local isPosix = jit.os ~= "Windows"

ffi.cdef([[
	typedef int pid_t;
	pid_t fork(void);
	int   waitpid(int pid, int *status, int options);
	int usleep(unsigned int usec);
]])

---@param n integer
local function ms(n)
	ffi.C.usleep(n * 1000)
end

test.skipIf(not isPosix)("watch reports stream data and then EOF", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local conn = assert(listener:accept())
		ms(300)
		conn:write("hi")
		ms(300)
		conn:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(socket.tcp.connect("127.0.0.1", port))
	assert(stream:setNonBlocking(true))

	local watch = socket.watch()
	local id = watch:add(stream)

	-- Nothing written yet: a zero timeout must not report the stream.
	test.equal(#assert(watch:wait(0)), 0)

	local ready = assert(watch:wait(5000))
	test.equal(#ready, 1)
	test.equal(ready[1], stream)
	test.equal(stream:readSome(1024), "hi")

	-- The close is also reported as readiness, so EOF never hangs a watcher.
	local ready = assert(watch:wait(5000))
	test.equal(#ready, 1)
	local data, err = stream:readSome(1024)
	test.falsy(data)
	test.truthy(err)

	stream:close()
	watch:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.skipIf(not isPosix)("watch reports a nonblocking listener accept", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())
	assert(listener:setNonBlocking(true))

	local pid = ffi.C.fork()
	if pid == 0 then
		ms(300)
		local conn = assert(socket.tcp.connect("127.0.0.1", port))
		ms(300)
		conn:close()
		os.exit(0)
	end

	local watch = socket.watch()
	local id = watch:add(listener)
	test.equal(#assert(watch:wait(0)), 0)

	local ready = assert(watch:wait(5000))
	test.equal(#ready, 1)
	test.equal(ready[1], listener)

	local conn = assert(listener:accept())
	conn:close()

	watch:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.it("watch returns only the ready udp sockets and honors remove", function()
	local watch = socket.watch()

	local a = assert(socket.udp.bind("127.0.0.1", 0))
	local b = assert(socket.udp.bind("127.0.0.1", 0))
	local idA = watch:add(a)
	local idB = watch:add(b)

	local ip, port = a:getLocalAddr()
	b:sendTo("one", ip, port)

	local ready = assert(watch:wait(1000))
	test.equal(#ready, 1)
	test.equal(ready[1], a)
	a:recvFrom()

	-- Removing the watched socket stops reporting it.
	watch:remove(idA)
	b:sendTo("two", ip, port)
	test.equal(#assert(watch:wait(500)), 0)

	watch:remove(idB)
	b:close()
	a:close()
	watch:close()
end)

return test.run()
