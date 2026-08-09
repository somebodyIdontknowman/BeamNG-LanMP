-- Raw UDP transport for LANMP.
--
-- BeamNG ships LuaSocket, so the mod talks to the server directly from the
-- game engine Lua state. No launcher, no bridge process.

local M = {}

local socket = require("socket")

local udp = nil
local host, port = nil, nil
local stats = { sent = 0, received = 0, bytesSent = 0, bytesReceived = 0 }

local MAX_DATAGRAM = 65535
local MAX_READS_PER_FRAME = 256

function M.isOpen()
  return udp ~= nil
end

function M.getHost() return host end
function M.getPort() return port end
function M.getStats() return stats end

function M.open(newHost, newPort)
  M.close()

  local sock, err = socket.udp()
  if not sock then
    return false, "socket.udp() failed: " .. tostring(err)
  end

  sock:settimeout(0)
  local ok, perr = sock:setpeername(newHost, newPort)
  if not ok then
    sock:close()
    return false, "cannot reach " .. tostring(newHost) .. ":" .. tostring(newPort) .. " (" .. tostring(perr) .. ")"
  end

  udp = sock
  host, port = newHost, newPort
  stats = { sent = 0, received = 0, bytesSent = 0, bytesReceived = 0 }
  log("I", "lanmp", "UDP socket open to " .. host .. ":" .. tostring(port))
  return true
end

function M.close()
  if udp then
    udp:close()
    udp = nil
  end
  host, port = nil, nil
end

function M.send(data)
  if not udp then return false, "socket closed" end
  local ok, err = udp:send(data)
  if not ok then
    -- ICMP port unreachable surfaces here on Windows; not fatal, the server
    -- may simply not be up yet.
    return false, tostring(err)
  end
  stats.sent = stats.sent + 1
  stats.bytesSent = stats.bytesSent + #data
  return true
end

-- Drains the receive queue and returns the datagrams as an array of strings.
function M.receive()
  if not udp then return {} end
  local out = {}
  for _ = 1, MAX_READS_PER_FRAME do
    local data, err = udp:receive(MAX_DATAGRAM)
    if not data then
      if err ~= "timeout" and err ~= nil then
        log("D", "lanmp", "udp receive: " .. tostring(err))
      end
      break
    end
    stats.received = stats.received + 1
    stats.bytesReceived = stats.bytesReceived + #data
    out[#out + 1] = data
  end
  return out
end

return M
