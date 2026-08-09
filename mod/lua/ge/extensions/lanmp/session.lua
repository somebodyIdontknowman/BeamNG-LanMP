-- Connection state machine, player roster, ping and chat.
--
-- This is the extension the UI app talks to.

local M = {}

local PING_INTERVAL = 0.5
local SERVER_TIMEOUT = 10
local HANDSHAKE_TIMEOUT = 5
local UI_INTERVAL = 0.25
local MAX_CHAT_HISTORY = 100

local state = "disconnected"   -- disconnected | connecting | authenticating | connected
local session = { playerId = 0, sessionKey = 0 }
local server = { host = "127.0.0.1", port = 4144, name = "", map = "", tickRate = 30, maxPlayers = 0 }
local account = { username = "", pin = "", pendingRegister = false }

local players = {}             -- id -> {id, name, ping, isYou}
local chatHistory = {}
local lastError = ""
local status = "Not connected"
local lastPin = ""             -- shown once after a successful registration

local pingId = 0
local pingTimer = 0
local pendingPings = {}
local rtt = 0
local lastServerPacket = 0
local handshakeStarted = 0
local uiTimer = 0
local clock = os.clock

function M.getState() return state end
function M.getSession() return session end
function M.getPlayers() return players end
function M.getPing() return rtt end
function M.isConnected() return state == "connected" end

function M.send(data)
  if not lanmp_network.isOpen() then return false end
  return lanmp_network.send(data)
end

-- ---------------------------------------------------------------------- UI --

local function uiPlayerList()
  local list = {}
  for _, p in pairs(players) do
    list[#list + 1] = { id = p.id, name = p.name, ping = p.ping, isYou = p.isYou }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function pushUI(extra)
  local data = {
    state = state,
    status = status,
    lastError = lastError,
    host = server.host,
    port = server.port,
    serverName = server.name,
    map = server.map,
    username = account.username,
    playerId = session.playerId,
    ping = rtt,
    players = uiPlayerList(),
    chat = chatHistory,
    pin = lastPin,
    nametags = lanmp_nametags and lanmp_nametags.isEnabled() or false,
  }
  if extra then
    for k, v in pairs(extra) do data[k] = v end
  end
  guihooks.trigger("LanmpUpdate", data)
end

M.requestState = function() pushUI() end

local function setStatus(text)
  status = text
  pushUI()
end

local function setError(text)
  lastError = text
  log("W", "lanmp", text)
  pushUI()
end

local function addChat(name, message, kind)
  chatHistory[#chatHistory + 1] = { name = name, text = message, kind = kind or "chat", t = clock() }
  while #chatHistory > MAX_CHAT_HISTORY do table.remove(chatHistory, 1) end
  guihooks.trigger("LanmpChat", chatHistory[#chatHistory])
  if kind ~= "silent" then
    guihooks.trigger("toastrMsg", { type = "info", title = name, msg = message, config = { timeOut = 4000 } })
  end
end

M.addSystemMessage = function(msg) addChat("system", msg, "system") end

-- --------------------------------------------------------------- connecting --

local function resetSession()
  session = { playerId = 0, sessionKey = 0 }
  players = {}
  pendingPings = {}
  rtt = 0
end

local function startHandshake(host, port)
  local ok, err = lanmp_network.open(host, port)
  if not ok then
    state = "disconnected"
    setError(err)
    return false
  end
  server.host, server.port = host, port
  state = "connecting"
  handshakeStarted = clock()
  lastServerPacket = clock()
  lastError = ""
  resetSession()
  M.send(lanmp_protocol.hello("lanmp-client"))
  setStatus("Contacting " .. host .. ":" .. tostring(port) .. " ...")
  return true
end

-- Registers a new account. The server replies with the generated PIN.
function M.registerAccount(host, port, username)
  account.username = username
  account.pin = ""
  account.pendingRegister = true
  lastPin = ""
  startHandshake(host, tonumber(port) or 4144)
end

function M.connect(host, port, username, pin)
  account.username = username
  account.pin = tostring(pin or "")
  account.pendingRegister = false
  startHandshake(host, tonumber(port) or 4144)
end

function M.disconnect(reason)
  if lanmp_network.isOpen() then
    if state == "connected" then M.send(lanmp_protocol.disconnect(session)) end
    lanmp_network.close()
  end
  local wasConnected = state == "connected"
  state = "disconnected"
  resetSession()
  lanmp_vehicles.onDisconnected()
  status = reason or "Disconnected"
  if wasConnected then log("I", "lanmp", "disconnected: " .. tostring(status)) end
  pushUI()
end

function M.sendChatMessage(text)
  if state ~= "connected" then return end
  text = tostring(text or "")
  if text == "" then return end
  M.send(lanmp_protocol.chat(session, text))
  addChat(account.username .. " (you)", text, "silent")
end

-- ------------------------------------------------------------ packet handling

local T = nil  -- protocol type table, resolved lazily

local function handlePacket(p)
  lastServerPacket = clock()

  if p.t == T.HelloAck then
    server.name = p.serverName
    server.map = p.map
    server.tickRate = p.tickRate
    server.maxPlayers = p.maxPlayers
    if p.version ~= lanmp_protocol.VERSION then
      M.disconnect("Server speaks protocol " .. p.version .. ", this mod speaks " .. lanmp_protocol.VERSION)
      setError("Protocol mismatch - update the mod or the server")
      return
    end
    state = "authenticating"
    if account.pendingRegister then
      setStatus("Registering " .. account.username .. " ...")
      M.send(lanmp_protocol.register(account.username))
    else
      setStatus("Logging in as " .. account.username .. " ...")
      M.send(lanmp_protocol.login(account.username, account.pin))
    end

  elseif p.t == T.RegisterAck then
    lastPin = p.pin
    account.pin = p.pin
    account.pendingRegister = false
    setStatus("Registered. Your PIN is " .. p.pin .. " - write it down.")
    M.send(lanmp_protocol.login(account.username, account.pin))

  elseif p.t == T.LoginAck then
    session.playerId = p.playerId
    session.sessionKey = p.sessionKey
    server.map = p.map
    server.tickRate = p.tickRate
    state = "connected"
    lastError = ""
    players[p.playerId] = { id = p.playerId, name = account.username, ping = 0, isYou = true }
    lanmp_vehicles.onConnected(p.tickRate)
    setStatus("Connected to " .. (server.name ~= "" and server.name or server.host))
    addChat("system", "Connected as " .. account.username, "system")

  elseif p.t == T.AuthNack then
    local msg = p.message
    if msg == "" then msg = lanmp_protocol.AuthReason[p.reason] or "Login refused" end
    M.disconnect("Login refused")
    setError(msg)

  elseif p.t == T.Kick then
    M.disconnect("Kicked: " .. tostring(p.reason))
    setError("Kicked: " .. tostring(p.reason))

  elseif p.t == T.Pong then
    local sent = pendingPings[p.pingId]
    if sent then
      rtt = math.floor((clock() - sent) * 1000)
      pendingPings[p.pingId] = nil
      if players[session.playerId] then players[session.playerId].ping = rtt end
    end

  elseif p.t == T.Roster then
    local seen = {}
    for _, entry in ipairs(p.players) do
      seen[entry.id] = true
      players[entry.id] = players[entry.id] or {}
      players[entry.id].id = entry.id
      players[entry.id].name = entry.name
      players[entry.id].ping = entry.isYou and rtt or entry.ping
      players[entry.id].isYou = entry.isYou
    end
    for id in pairs(players) do
      if not seen[id] then players[id] = nil end
    end

  elseif p.t == T.PlayerJoin then
    players[p.playerId] = { id = p.playerId, name = p.name, ping = 0, isYou = false }
    addChat("system", p.name .. " joined", "system")

  elseif p.t == T.PlayerLeave then
    players[p.playerId] = nil
    lanmp_vehicles.removePlayerVehicles(p.playerId)
    addChat("system", p.name .. " left", "system")

  elseif p.t == T.ChatBroadcast then
    if p.playerId ~= session.playerId then addChat(p.name, p.message, "chat") end

  elseif p.t == T.PosBroadcast then
    lanmp_vehicles.handlePos(p)

  elseif p.t == T.VehicleSpawnB then
    lanmp_vehicles.handleSpawn(p)

  elseif p.t == T.VehicleDespawnB then
    lanmp_vehicles.handleDespawn(p)

  elseif p.t == T.VehicleResetB then
    lanmp_vehicles.handleReset(p)

  elseif p.t == T.InputBroadcast then
    lanmp_vehicles.handleInputs(p)

  elseif p.t == T.GearBroadcast then
    lanmp_vehicles.handleGear(p)
  end
end

-- -------------------------------------------------------------------- update

function M.onUpdate(dt)
  T = T or lanmp_protocol.Type
  if state == "disconnected" then return end

  for _, datagram in ipairs(lanmp_network.receive()) do
    local packet, err = lanmp_protocol.decode(datagram)
    if packet then
      local ok, hErr = pcall(handlePacket, packet)
      if not ok then log("E", "lanmp", "packet handler error: " .. tostring(hErr)) end
    else
      log("D", "lanmp", "bad packet: " .. tostring(err))
    end
  end

  local now = clock()

  if state == "connecting" or state == "authenticating" then
    if now - handshakeStarted > HANDSHAKE_TIMEOUT then
      M.disconnect("No response from server")
      setError("No response from " .. server.host .. ":" .. tostring(server.port) ..
        " - is the server running and the port open?")
    end
    return
  end

  if now - lastServerPacket > SERVER_TIMEOUT then
    M.disconnect("Connection lost")
    setError("Lost connection to the server")
    return
  end

  pingTimer = pingTimer + dt
  if pingTimer >= PING_INTERVAL then
    pingTimer = 0
    pingId = (pingId + 1) % 4294967295
    pendingPings[pingId] = now
    M.send(lanmp_protocol.ping(session, pingId, now, rtt))
    -- Forget ping ids that never came back so the table cannot grow forever.
    for id, sent in pairs(pendingPings) do
      if now - sent > 5 then pendingPings[id] = nil end
    end
  end

  lanmp_vehicles.onUpdate(dt)

  uiTimer = uiTimer + dt
  if uiTimer >= UI_INTERVAL then
    uiTimer = 0
    pushUI()
  end
end

-- Keep the player out of other people's cars.
function M.onVehicleSwitched(oldId, newId)
  if state ~= "connected" then return end
  if newId and lanmp_vehicles.isRemote(newId) then
    if oldId and oldId ~= newId and be:getObjectByID(oldId) then
      be:enterVehicle(0, be:getObjectByID(oldId))
    end
    addChat("system", "You cannot drive another player's vehicle", "system")
  end
end

function M.onVehicleSpawned(id) lanmp_vehicles.onVehicleSpawned(id) end
function M.onVehicleDestroyed(id) lanmp_vehicles.onVehicleDestroyed(id) end
function M.onVehicleResetted(id) lanmp_vehicles.onVehicleResetted(id) end

function M.onExtensionLoaded()
  log("I", "lanmp", "session extension loaded")
end

function M.onSerialize()
  return { host = server.host, port = server.port, username = account.username }
end

function M.onDeserialized(data)
  if type(data) == "table" then
    server.host = data.host or server.host
    server.port = data.port or server.port
    account.username = data.username or account.username
  end
end

return M
