local test = require("lde-test")
local net = require("net")

-- tcp.bind()

test.it("tcp.bind() returns a Listener on loopback", function()
	local listener, err = net.tcp.bind("127.0.0.1", 0)
	test.falsy(err)
	test.truthy(listener)
	listener:close()
end)

test.it("tcp.bind() returns distinct Listeners", function()
	local a = assert(net.tcp.bind("127.0.0.1", 0))
	local b = assert(net.tcp.bind("127.0.0.1", 0))
	test.notEqual(a, b)
	a:close()
	b:close()
end)

test.it("tcp.bind() returns an error on already-bound port", function()
	local a = assert(net.tcp.bind("127.0.0.1", 0))
	local _, port = assert(a:getLocalAddr())
	local b, err = net.tcp.bind("127.0.0.1", port)
	test.falsy(b)
	test.truthy(err)
	a:close()
end)

-- Listener:getLocalAddr()

test.it("Listener:getLocalAddr() returns a non-zero port", function()
	local listener = assert(net.tcp.bind("127.0.0.1", 0))
	local ip, port, err = listener:getLocalAddr()
	test.falsy(err)
	test.truthy(ip)
	test.truthy(port and port > 0)
	listener:close()
end)

-- tcp.connect()

test.it("tcp.connect() returns an error on refused port", function()
	-- Bind and immediately close to get a port that is guaranteed free
	local tmp = assert(net.tcp.bind("127.0.0.1", 0))
	local _, port = assert(tmp:getLocalAddr())
	tmp:close()

	local stream, err = net.tcp.connect("127.0.0.1", port)
	test.falsy(stream)
	test.truthy(err)
end)

-- connect / accept / read / write round-trip

test.skipIf(jit.os == "Windows")("tcp round-trip: connect, write, read", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
	]])

	local listener = assert(net.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local client = assert(listener:accept())
		local data = assert(client:read(4))
		client:write("pong:" .. data)
		client:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream, err = net.tcp.connect("127.0.0.1", port)
	test.falsy(err)
	test.truthy(stream)

	stream:write("ping")
	local response = assert(stream:read(9))
	stream:close()

	ffi.C.waitpid(pid, nil, 0)

	test.equal(response, "pong:ping")
end)

-- Listener:incoming() iterator

test.skipIf(jit.os == "Windows")("Listener:incoming() yields accepted streams", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
	]])

	local listener = assert(net.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		for stream in listener:incoming() do
			stream:write("hello")
			stream:close()
			break
		end
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(net.tcp.connect("127.0.0.1", port))
	local msg = assert(stream:read(5))
	stream:close()

	ffi.C.waitpid(pid, nil, 0)

	test.equal(msg, "hello")
end)

-- Stream:readInto()

test.skipIf(jit.os == "Windows")("Stream:readInto() reads bytes into a buffer", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
	]])

	local listener = assert(net.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local client = assert(listener:accept())
		client:write("abcd")
		client:close()
		listener:close()
		os.exit(0)
	end

	listener:close()

	local stream = assert(net.tcp.connect("127.0.0.1", port))
	local buf = ffi.new("char[4]")
	local n = assert(stream:readInto(4, buf))
	stream:close()

	ffi.C.waitpid(pid, nil, 0)

	test.equal(n, 4)
	test.equal(ffi.string(buf, 4), "abcd")
end)

-- Listener:close()

test.it("Listener:close() returns true", function()
	local listener = assert(net.tcp.bind("127.0.0.1", 0))
	local ok, err = listener:close()
	test.falsy(err)
	test.truthy(ok)
end)

return test.run()
