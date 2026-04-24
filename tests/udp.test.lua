local test = require("lde-test")
local net = require("net")

-- udp.bind()

test.it("udp.bind() returns a Socket on loopback", function()
	local sock, err = net.udp.bind("127.0.0.1", 0)
	test.falsy(err)
	test.truthy(sock)
	sock:close()
end)

test.it("udp.bind() returns distinct Sockets", function()
	local a = assert(net.udp.bind("127.0.0.1", 0))
	local b = assert(net.udp.bind("127.0.0.1", 0))
	test.notEqual(a, b)
	a:close()
	b:close()
end)

test.it("udp.bind() returns an error on already-bound port", function()
	local a = assert(net.udp.bind("127.0.0.1", 0))
	local _, port = assert(a:getLocalAddr())
	local b, err = net.udp.bind("127.0.0.1", port)
	test.falsy(b)
	test.truthy(err)
	a:close()
end)

-- Socket:getLocalAddr()

test.it("Socket:getLocalAddr() returns a non-zero port", function()
	local sock = assert(net.udp.bind("127.0.0.1", 0))
	local ip, port, err = sock:getLocalAddr()
	test.falsy(err)
	test.truthy(ip)
	test.truthy(port and port > 0)
	sock:close()
end)

-- sendTo() / recvFrom() round-trip

test.skipIf(jit.os == "Windows")("udp sendTo/recvFrom round-trip", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
	]])

	local server = assert(net.udp.bind("127.0.0.1", 0))
	local _, port = assert(server:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local data, addr, src_port = assert(server:recvFrom())
		server:sendTo("pong:" .. data, addr, src_port)
		server:close()
		os.exit(0)
	end

	server:close()

	local client = assert(net.udp.bind("127.0.0.1", 0))
	local ok, err = client:sendTo("ping", "127.0.0.1", port)
	test.falsy(err)
	test.truthy(ok)

	local response = assert(client:recvFrom())
	client:close()

	ffi.C.waitpid(pid, nil, 0)

	test.equal(response, "pong:ping")
end)

-- udp.connect() / send()

test.skipIf(jit.os == "Windows")("udp connect/send round-trip", function()
	local ffi = require("ffi")

	ffi.cdef([[
		typedef int pid_t;
		pid_t fork(void);
		int   waitpid(int pid, int *status, int options);
	]])

	local server = assert(net.udp.bind("127.0.0.1", 0))
	local _, port = assert(server:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local data, addr, src_port = assert(server:recvFrom())
		server:sendTo("pong:" .. data, addr, src_port)
		server:close()
		os.exit(0)
	end

	server:close()

	local client = assert(net.udp.connect("127.0.0.1", port))
	local ok, err = client:send("ping")
	test.falsy(err)
	test.truthy(ok)
	client:close()

	ffi.C.waitpid(pid, nil, 0)
end)

-- Socket:close()

test.it("Socket:close() returns true", function()
	local sock = assert(net.udp.bind("127.0.0.1", 0))
	local ok, err = sock:close()
	test.falsy(err)
	test.truthy(ok)
end)

return test.run()
