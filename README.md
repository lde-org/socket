# socket

A cross platform `socket` library for [lde](https://lde.sh).

## Usage

```
lde add socket
```

## Examples

### TCP server and client

```lua
local socket = require("socket")

-- Server: bind, accept one connection, echo back
local listener = assert(socket.tcp.bind("127.0.0.1", 8080))
local client = assert(listener:accept())
local msg = assert(client:read(5))  -- read exactly 5 bytes
client:write("echo:" .. msg)
client:close()
listener:close()

-- Client: connect and exchange data
local stream = assert(socket.tcp.connect("127.0.0.1", 8080))
stream:write("hello")
local reply = assert(stream:read(10))
stream:close()
```

### TCP server using the incoming() iterator

```lua
local socket = require("socket")

local listener = assert(socket.tcp.bind("0.0.0.0", 8080))
for conn in listener:incoming() do
    local data = assert(conn:read(1024))
    conn:write(data)  -- echo
    conn:close()
end
```

### UDP send and receive

```lua
local socket = require("socket")

-- Receiver
local server = assert(socket.udp.bind("127.0.0.1", 9000))
local data, addr, port = assert(server:recvFrom())
server:sendTo("pong", addr, port)
server:close()

-- Sender (sendTo, no prior connect needed)
local client = assert(socket.udp.bind("127.0.0.1", 0))
client:sendTo("ping", "127.0.0.1", 9000)
local reply = assert(client:recvFrom())
client:close()

-- Sender (connect first, then send)
local sock = assert(socket.udp.connect("127.0.0.1", 9000))
sock:send("ping")
sock:close()
```

### Non-blocking sockets and polling

```lua
local socket = require("socket")

-- Streams, listeners and udp sockets can be toggled between blocking and
-- non-blocking mode.
local stream = assert(socket.tcp.connect("127.0.0.1", 8080))
assert(stream:setNonBlocking(true))

-- socket.poll() returns the subset of handles that are ready to read
-- (including peers that closed, so EOF never hangs a poller).
local listener = assert(socket.tcp.bind("0.0.0.0", 8081))
assert(listener:setNonBlocking(true))

while true do
    local ready = assert(socket.poll({ listener, stream }, 1000))

    for _, sock in ipairs(ready) do
        if sock == listener then
            local conn = assert(listener:accept())
            conn:setNonBlocking(true)
        else
            -- readSome reads what is available without looping; it returns
            -- nil + "would block" when there is nothing buffered yet.
            local data, err = stream:readSome(4096)
            if err == "would block" then
                -- spurious wakeup, keep polling
            elseif err then
                stream:close()
            else
                stream:write(data)
            end
        end
    end
end
```

`timeout` is in milliseconds: `socket.poll(handles, 0)` only checks, and
`nil` waits forever. Exact `read`/`write` calls assume blocking sockets;
once a socket is non-blocking, use `readSome`/`readSomeInto` (and poll for
writability separately if you push large payloads).
