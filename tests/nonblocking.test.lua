local test = require("lde-test")
local ffi = require("ffi")

local socket = require("socket")

local isPosix = jit.os ~= "Windows"

ffi.cdef([[
	typedef int pid_t;
	pid_t fork(void);
	int   waitpid(int pid, int *status, int options);
	unsigned int sleep(unsigned int seconds);
	int usleep(unsigned int usec);
]])

---@param n integer
local function ms(n)
	ffi.C.usleep(n * 1000)
end

test.skipIf(not isPosix)("setNonBlocking makes reads report would block", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local client = assert(listener:accept())
		ms(600)
		client:write("hello")
		ms(600)
		client:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(socket.tcp.connect("127.0.0.1", port))
	local ok, err = stream:setNonBlocking(true)
	test.falsy(err)
	test.truthy(ok)

	-- Nothing has been written yet: must not hang.
	local data, err = stream:readSome(1024)
	test.falsy(data)
	test.equal(err, "would block")

	-- poll() reports the stream once the child writes.
	local ready, err = socket.poll({ stream }, 10000)
	test.falsy(err)
	test.equal(#ready, 1)
	test.equal(ready[1], stream)

	local data, err = stream:readSome(1024)
	test.falsy(err)
	test.equal(data, "hello")

	-- poll() also reports readiness when the peer closes, so the EOF
	-- surfaces instead of hanging forever.
	local ready, err = socket.poll({ stream }, 10000)
	test.falsy(err)
	test.equal(#ready, 1)

	local data, err = stream:readSome(1024)
	test.falsy(data)
	test.truthy(err)
	test.includes(err, "closed")

	stream:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.skipIf(not isPosix)("poll with a timeout returns empty when idle", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local client = assert(listener:accept())
		ms(600)
		client:write("later")
		client:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(socket.tcp.connect("127.0.0.1", port))
	local ok, err = stream:setNonBlocking(true)
	test.truthy(ok)
	test.falsy(err)

	local ready, err = socket.poll({ stream }, 100)
	test.falsy(err)
	test.equal(#ready, 0, "nothing should be ready while the child sleeps")

	local ready, err = socket.poll({ stream }, 10000)
	test.equal(#ready, 1)
	test.equal(stream:readSome(1024), "later")

	stream:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.skipIf(not isPosix)("nonblocking listeners report accept would block", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local ok, err = listener:setNonBlocking(true)
	test.truthy(ok)
	test.falsy(err)

	-- No connection pending: accept must not hang.
	local stream, err = listener:accept()
	test.falsy(stream)
	test.equal(err, "would block")

	local pid = ffi.C.fork()
	if pid == 0 then
		ms(200)
		local client = assert(socket.tcp.connect("127.0.0.1", port))
		ms(400)
		client:close()
		os.exit(0)
	end

	local ready, err = socket.poll({ listener }, 10000)
	test.falsy(err)
	test.equal(#ready, 1)

	local stream, err = listener:accept()
	test.falsy(err)
	test.truthy(stream)
	stream:close()

	ffi.C.waitpid(pid, nil, 0)
end)

test.skipIf(not isPosix)("setNonBlocking(false) restores blocking reads", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local client = assert(listener:accept())
		ms(400)
		client:write("hi")
		client:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(socket.tcp.connect("127.0.0.1", port))
	assert(stream:setNonBlocking(true))
	assert(stream:setNonBlocking(false))

	-- Must block until the child writes, then return the data.
	local data, err = stream:readSome(1024)
	test.falsy(err)
	test.equal(data, "hi")

	stream:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.it("nonblocking udp recvFrom reports would block", function()
	local sock = assert(socket.udp.bind("127.0.0.1", 0))
	local ok, err = sock:setNonBlocking(true)
	test.truthy(ok)
	test.falsy(err)

	local data, ip, port, err = sock:recvFrom()
	test.falsy(data)
	test.falsy(ip)
	test.falsy(port)
	test.equal(err, "would block")

	sock:close()
end)

return test.run()
