local test = require("lde-test")
local ffi = require("ffi")

local socket = require("socket")

local isPosix = jit.os ~= "Windows"

ffi.cdef([[
	typedef int pid_t;
	pid_t fork(void);
	int   waitpid(int pid, int *status, int options);
]])

test.it("resolve returns dotted-quad literals unchanged", function()
	local ip, err = socket.resolve("127.0.0.1")
	test.falsy(err)
	test.equal(ip, "127.0.0.1")
end)

test.it("resolve looks up localhost", function()
	local ip, err = socket.resolve("localhost")
	test.falsy(err)
	test.truthy(ip)
	test.truthy(ip:match("^%d+%.%d+%.%d+%.%d+$"), "expected an IPv4 address, got " .. tostring(ip))
end)

test.it("resolve reports unknown names", function()
	local ip, err = socket.resolve("no-such-host.invalid.example")
	test.falsy(ip)
	test.truthy(err)
	test.includes(err, "resolve failed")
end)

test.skipIf(not isPosix)("tcp.connect accepts hostnames", function()
	local listener = assert(socket.tcp.bind("127.0.0.1", 0))
	local _, port = assert(listener:getLocalAddr())

	local pid = ffi.C.fork()
	if pid == 0 then
		local conn = assert(listener:accept())
		conn:write("hi")
		conn:close()
		listener:close()
		os.exit(0)
	end

	listener:close()
	local stream, err = socket.tcp.connect("localhost", port)
	test.falsy(err)
	test.truthy(stream)
	test.equal(stream:read(2), "hi")
	stream:close()
	ffi.C.waitpid(pid, nil, 0)
end)

test.it("udp.connect accepts hostnames", function()
	local sock, err = socket.udp.connect("localhost", 9999)
	test.falsy(err, tostring(err))
	test.truthy(sock)
	sock:close()
end)

return test.run()
