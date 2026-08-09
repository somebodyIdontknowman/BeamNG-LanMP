-- LAN server browser.
--
-- Sends a small broadcast probe on the well known LANMP ports and collects the
-- replies, so players find each other's servers without typing IP addresses.
-- Runs on its own unconnected socket, separate from the gameplay transport.

local M = {}

local socket = require("socket")

local PROBE_PORTS = { 4144, 4145, 4146, 4147 }
local SCAN_DURATION = 3
local PROBE_INTERVAL = 0.5
local ENTRY_TTL = 12
local PUSH_INTERVAL = 0.25

local sock = nil
local nonce = 0
local scanUntil = 0
local probeTimer = 0
local pushTimer = 0
local servers = {}      -- "ip:port" -> {host, port, name, players, maxPlayers, map, ping, seen}
local probeSentAt = {}
local clock = os.clock

local function close()
  if sock then
    sock:close()
    sock = nil
  end
end

local function open()
  if sock then return true end

  local s, err = socket.udp()
  if not s then return false, "socket.udp() failed: " .. tostring(err) end
  s:settimeout(0)
  s:setsockname("*", 0)
  local ok, berr = s:setoption("broadcast", true)
  if not ok then
    -- Still useful without broadcast: direct probes to localhost keep working.
    log("W", "lanmp", "cannot enable UDP broadcast: " .. tostring(berr))
  end
  sock = s
  return true
end

function M.getServers()
  local list = {}
  for _, s in pairs(servers) do list[#list + 1] = s end
  table.sort(list, function(a, b)
    if a.players ~= b.players then return a.players > b.players end
    return a.name < b.name
  end)
  return list
end

function M.isScanning()
  return clock() < scanUntil
end

-- Adds a server the player typed in by hand so it shows up in the list too.
function M.probe(host, port)
  if not open() then return end
  nonce = (nonce + 1) % 4294967295
  probeSentAt[nonce] = clock()
  sock:sendto(lanmp_protocol.discover(nonce), host, tonumber(port) or 4144)
end

local function sendProbes()
  if not open() then return end
  nonce = (nonce + 1) % 4294967295
  probeSentAt[nonce] = clock()
  local packet = lanmp_protocol.discover(nonce)
  for _, port in ipairs(PROBE_PORTS) do
    sock:sendto(packet, "255.255.255.255", port)
    sock:sendto(packet, "127.0.0.1", port)
  end
end

function M.scan()
  servers = {}
  scanUntil = clock() + SCAN_DURATION
  probeTimer = 0
  pushTimer = 0
  sendProbes()
  guihooks.trigger("LanmpServers", { scanning = true, servers = {} })
end

function M.stop()
  scanUntil = 0
  close()
end

local function receive()
  if not sock then return end
  for _ = 1, 64 do
    local data, ip, port = sock:receivefrom()
    if not data then break end

    local packet = lanmp_protocol.decode(data)
    if packet and packet.t == lanmp_protocol.Type.DiscoverAck then
      local sentAt = probeSentAt[packet.nonce]
      -- The port the reply actually came from is what we can reach; the port the
      -- server reports is only a hint and is wrong behind NAT or port mapping.
      local srvPort = tonumber(port) or packet.port
      local key = ip .. ":" .. tostring(srvPort)
      servers[key] = {
        host = ip,
        port = srvPort,
        name = packet.serverName,
        players = packet.players,
        maxPlayers = packet.maxPlayers,
        map = packet.map,
        version = packet.version,
        compatible = packet.version == lanmp_protocol.VERSION,
        ping = sentAt and math.floor((clock() - sentAt) * 1000) or 0,
        seen = clock(),
      }
    end
  end
end

function M.onUpdate(dt)
  if not sock then return end

  receive()

  local now = clock()
  if now < scanUntil then
    probeTimer = probeTimer + dt
    if probeTimer >= PROBE_INTERVAL then
      probeTimer = 0
      sendProbes()
    end
    pushTimer = pushTimer + dt
    if pushTimer >= PUSH_INTERVAL then
      pushTimer = 0
      guihooks.trigger("LanmpServers", { scanning = true, servers = M.getServers() })
    end
  elseif scanUntil > 0 then
    scanUntil = 0
    for id, t in pairs(probeSentAt) do
      if now - t > ENTRY_TTL then probeSentAt[id] = nil end
    end
    guihooks.trigger("LanmpServers", { scanning = false, servers = M.getServers() })
    close()
  end
end

function M.onExtensionLoaded()
  log("I", "lanmp", "discovery extension loaded")
end

function M.onExtensionUnloaded()
  close()
end

return M
