local test = require("lde-test")
local socket = require("socket")

-- socket()

test.it("socket() returns a handle", function()
	local s, err = socket.socket()
	test.falsy(err)
	test.truthy(s)
	socket.close(s)
end)

test.it("socket() returns distinct handles", function()
	local a = assert(socket.socket())
	local b = assert(socket.socket())
	test.notEqual(a, b)
	socket.close(a)
	socket.close(b)
end)

-- bind() / listen()

test.it("bind() and listen() succeed on loopback", function()
	local s = assert(socket.socket())
	local ok, err = socket.bind(s, "127.0.0.1", 0)
	test.falsy(err)
	test.truthy(ok)
	local ok2, err2 = socket.listen(s, 1)
	test.falsy(err2)
	test.truthy(ok2)
	socket.close(s)
end)

test.it("bind() returns an error on already-bound port", function()
	local a = assert(socket.socket())
	local b = assert(socket.socket())
	assert(socket.bind(a, "127.0.0.1", 19876))
	local ok, err = socket.bind(b, "127.0.0.1", 19876)
	test.falsy(ok)
	test.truthy(err)
	socket.close(a)
	socket.close(b)
end)

-- connect() / accept() / read() / write()

test.skipIf(jit.os == "Windows")("connect, send, receive round-trip", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
		void  usleep(unsigned int usec);
	]])

	local PORT = 19877

	local pid = ffi.C.fork()
	if pid == 0 then
		local srv = assert(socket.socket())
		assert(socket.bind(srv, "127.0.0.1", PORT))
		assert(socket.listen(srv, 1))
		local client = assert(socket.accept(srv))
		local data = assert(socket.read(client))
		socket.write(client, "pong:" .. data)
		socket.close(client)
		socket.close(srv)
		os.exit(0)
	end

	ffi.C.usleep(20000)

	local s = assert(socket.socket())
	local ok, err = socket.connect(s, "127.0.0.1", PORT)
	test.falsy(err)
	test.truthy(ok)
	assert(socket.write(s, "ping"))
	local response = assert(socket.read(s))
	socket.close(s)

	ffi.C.waitpid(pid, nil, 0)

	test.equal(response, "pong:ping")
end)

test.it("connect() returns an error on refused port", function()
	local s = assert(socket.socket())
	local ok, err = socket.connect(s, "127.0.0.1", 19878)
	test.falsy(ok)
	test.truthy(err)
	test.includes(err, "connect failed")
	socket.close(s)
end)

-- write() / read()

test.it("write() returns an error on closed handle", function()
	local s = assert(socket.socket())
	socket.close(s)
	local ok, err = socket.write(s, "hello")
	test.falsy(ok)
	test.truthy(err)
end)

-- close()

test.it("close() returns true on valid handle", function()
	local s = assert(socket.socket())
	local ok, err = socket.close(s)
	test.falsy(err)
	test.truthy(ok)
end)

return test.run()
