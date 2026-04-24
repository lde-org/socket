# net

A cross platform `net` library for [lde](https://lde.sh).

## Usage

```
lde add net --git https://github.com/lde-org/net
```

## Examples

### TCP server and client

```lua
local net = require("net")

-- Server: bind, accept one connection, echo back
local listener = assert(net.tcp.bind("127.0.0.1", 8080))
local client = assert(listener:accept())
local msg = assert(client:read(5))  -- read exactly 5 bytes
client:write("echo:" .. msg)
client:close()
listener:close()

-- Client: connect and exchange data
local stream = assert(net.tcp.connect("127.0.0.1", 8080))
stream:write("hello")
local reply = assert(stream:read(10))
stream:close()
```

### TCP server using the incoming() iterator

```lua
local net = require("net")

local listener = assert(net.tcp.bind("0.0.0.0", 8080))
for conn in listener:incoming() do
    local data = assert(conn:read(1024))
    conn:write(data)  -- echo
    conn:close()
end
```

### UDP send and receive

```lua
local net = require("net")

-- Receiver
local server = assert(net.udp.bind("127.0.0.1", 9000))
local data, addr, port = assert(server:recvFrom())
server:sendTo("pong", addr, port)
server:close()

-- Sender (sendTo, no prior connect needed)
local client = assert(net.udp.bind("127.0.0.1", 0))
client:sendTo("ping", "127.0.0.1", 9000)
local reply = assert(client:recvFrom())
client:close()

-- Sender (connect first, then send)
local sock = assert(net.udp.connect("127.0.0.1", 9000))
sock:send("ping")
sock:close()
```
