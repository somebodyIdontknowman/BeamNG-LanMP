-- Vehicle ownership, replication and remote vehicle lifecycle.
--
-- Local vehicles push their state from vehicle lua (lanmpSyncVE) once per tick;
-- incoming remote state is dropped into a per-vehicle mailbox where the remote
-- vehicle's own lanmpSyncVE picks it up and dead-reckons towards it.

local M = {}

local MAX_CONFIG_BYTES = 40000
local REMOTE_STALE_S = 15

-- gameVehId -> {netId, model, seq}
local localVehicles = {}
-- "pid:netId" -> remote entry
local remotes = {}
-- gameVehId -> remote key
local remoteByGameId = {}

local tickTimer = 0
local pingTimer = 0
local tickInterval = 1 / 30

local function remoteKey(playerId, netId)
  return tostring(playerId) .. ":" .. tostring(netId)
end

local function mailboxName(key)
  return "lanmpPos_" .. key:gsub(":", "_")
end

function M.getRemotes() return remotes end
function M.getLocalVehicles() return localVehicles end
function M.isRemote(gameVehId) return remoteByGameId[gameVehId] ~= nil end

function M.setTickRate(rate)
  if rate and rate >= 5 and rate <= 120 then tickInterval = 1 / rate end
end

-- ------------------------------------------------------------ local vehicles

local function loadVehicleExtensions(veh)
  veh:queueLuaCommand("extensions.loadModulesInDirectory('lua/vehicle/extensions/lanmp')")
end

local function vehicleConfigJson(gameVehId)
  if not core_vehicle_manager then return "" end
  local data = core_vehicle_manager.getVehicleData(gameVehId)
  if not data or not data.config then return "" end
  local ok, encoded = pcall(jsonEncode, data.config)
  if not ok or type(encoded) ~= "string" then return "" end
  if #encoded > MAX_CONFIG_BYTES then
    log("W", "lanmp", "vehicle config too large to sync (" .. #encoded .. " bytes), sending model only")
    return ""
  end
  return encoded
end

local function announceLocalVehicle(gameVehId)
  local veh = be:getObjectByID(gameVehId)
  if not veh then return end
  if remoteByGameId[gameVehId] then return end -- someone else's car

  local model = veh:getJBeamFilename() or veh.jbeam or ""
  if model == "" then return end

  local plate = ""
  if core_vehicles and core_vehicles.getVehicleLicenseName then
    plate = core_vehicles.getVehicleLicenseName(veh) or ""
  end

  localVehicles[gameVehId] = localVehicles[gameVehId] or { netId = gameVehId, seq = 0 }
  localVehicles[gameVehId].model = model

  loadVehicleExtensions(veh)
  veh:queueLuaCommand("lanmpSyncVE.setLocal()")

  lanmp_session.send(lanmp_protocol.vehicleSpawn(lanmp_session.getSession(), gameVehId, model,
    vehicleConfigJson(gameVehId), plate, 0))
end

-- Announces every vehicle the player already had spawned when they connected.
function M.onConnected(tickRate)
  M.setTickRate(tickRate)
  localVehicles = {}
  for _, veh in ipairs(getAllVehicles() or {}) do
    local id = veh:getID()
    if not remoteByGameId[id] then announceLocalVehicle(id) end
  end
end

function M.onDisconnected()
  for key, entry in pairs(remotes) do
    if entry.gameVehId then
      local veh = be:getObjectByID(entry.gameVehId)
      if veh then veh:delete() end
    end
    remotes[key] = nil
  end
  remoteByGameId = {}
  localVehicles = {}
end

function M.onVehicleSpawned(gameVehId)
  if not lanmp_session.isConnected() then return end
  if remoteByGameId[gameVehId] then
    -- Our own spawn call for a remote player's car; wire up its extensions.
    local veh = be:getObjectByID(gameVehId)
    if veh then
      loadVehicleExtensions(veh)
      veh:queueLuaCommand(string.format("lanmpSyncVE.setRemote(%q)", mailboxName(remoteByGameId[gameVehId])))
    end
    return
  end
  announceLocalVehicle(gameVehId)
end

function M.onVehicleDestroyed(gameVehId)
  local key = remoteByGameId[gameVehId]
  if key then
    remoteByGameId[gameVehId] = nil
    if remotes[key] then remotes[key].gameVehId = nil end
    return
  end
  if not localVehicles[gameVehId] then return end
  localVehicles[gameVehId] = nil
  if lanmp_session.isConnected() then
    lanmp_session.send(lanmp_protocol.vehicleDespawn(lanmp_session.getSession(), gameVehId))
  end
end

function M.onVehicleResetted(gameVehId)
  if not lanmp_session.isConnected() then return end
  if not localVehicles[gameVehId] then return end
  local veh = be:getObjectByID(gameVehId)
  if not veh then return end
  local p = veh:getPosition()
  local q = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  lanmp_session.send(lanmp_protocol.vehicleReset(lanmp_session.getSession(), gameVehId,
    { p.x, p.y, p.z }, { q.x, q.y, q.z, q.w }))
end

-- Called from vehicle lua once per tick for vehicles we own.
function M.onLocalState(gameVehId, encoded)
  local entry = localVehicles[gameVehId]
  if not entry or not lanmp_session.isConnected() then return end
  local state = jsonDecode(encoded)
  if not state or not state.pos then return end

  entry.seq = entry.seq + 1
  lanmp_session.send(lanmp_protocol.posUpdate(lanmp_session.getSession(), entry.netId, entry.seq,
    state.tim or 0, state.pos, state.rot, state.vel, state.rvel))
end

function M.onLocalInputs(gameVehId, encoded)
  local entry = localVehicles[gameVehId]
  if not entry or not lanmp_session.isConnected() then return end
  local decoded = jsonDecode(encoded)
  if not decoded then return end

  local inputs = {}
  for name, value in pairs(decoded) do
    if name == "gear" then
      lanmp_session.send(lanmp_protocol.gearUpdate(lanmp_session.getSession(), entry.netId, tostring(value)))
    else
      local id = lanmp_protocol.Input[name]
      if id then inputs[#inputs + 1] = { id, value } end
    end
  end
  if #inputs > 0 then
    lanmp_session.send(lanmp_protocol.inputUpdate(lanmp_session.getSession(), entry.netId, inputs))
  end
end

-- ----------------------------------------------------------- remote vehicles

local function spawnRemote(entry)
  if entry.gameVehId or entry.spawning or not entry.pos then return end
  entry.spawning = true

  local config = ""
  if entry.config ~= "" then
    local decoded = jsonDecode(entry.config)
    if decoded then config = serialize(decoded) end
  end

  local pos = vec3(entry.pos[1], entry.pos[2], entry.pos[3])
  local rot = quat(entry.rot[1], entry.rot[2], entry.rot[3], entry.rot[4])

  local ok, veh = pcall(spawn.spawnVehicle, entry.model, config, pos, rot,
    { autoEnterVehicle = false, vehicleName = "lanmpRemote", cling = false })

  entry.spawning = false
  if not ok or not veh then
    log("E", "lanmp", "failed to spawn remote vehicle " .. tostring(entry.model) .. ": " .. tostring(veh))
    entry.spawnFailed = true
    return
  end

  entry.gameVehId = veh:getID()
  remoteByGameId[entry.gameVehId] = remoteKey(entry.playerId, entry.netId)
  loadVehicleExtensions(veh)
  veh:queueLuaCommand(string.format("lanmpSyncVE.setRemote(%q)",
    mailboxName(remoteKey(entry.playerId, entry.netId))))
  log("I", "lanmp", "spawned remote vehicle " .. entry.model .. " for player " .. tostring(entry.playerId))
end

function M.handleSpawn(p)
  local key = remoteKey(p.playerId, p.vehId)
  local entry = remotes[key] or {}
  entry.playerId = p.playerId
  entry.netId = p.vehId
  entry.model = p.model
  entry.config = p.config or ""
  entry.plate = p.plate or ""
  entry.lastPacket = os.clock()
  remotes[key] = entry
  -- The vehicle is created once we know where to put it (first position packet).
end

function M.handleDespawn(p)
  local key = remoteKey(p.playerId, p.vehId)
  local entry = remotes[key]
  if not entry then return end
  if entry.gameVehId then
    local veh = be:getObjectByID(entry.gameVehId)
    if veh then veh:delete() end
    remoteByGameId[entry.gameVehId] = nil
  end
  remotes[key] = nil
end

function M.removePlayerVehicles(playerId)
  for key, entry in pairs(remotes) do
    if entry.playerId == playerId then
      M.handleDespawn({ playerId = playerId, vehId = entry.netId })
      remotes[key] = nil
    end
  end
end

function M.handlePos(p)
  local key = remoteKey(p.playerId, p.vehId)
  local entry = remotes[key]
  if not entry then return end -- position before spawn info, ignore

  entry.pos = p.pos
  entry.rot = p.rot
  entry.ping = p.senderPing
  entry.lastPacket = os.clock()

  if not entry.gameVehId then
    if not entry.spawnFailed then spawnRemote(entry) end
    return
  end

  be:sendToMailbox(mailboxName(key), jsonEncode({
    pos = p.pos, rot = p.rot, vel = p.vel, rvel = p.rvel,
    tim = p.tim, ping = (p.senderPing or 0) / 1000,
  }))
end

function M.handleInputs(p)
  local entry = remotes[remoteKey(p.playerId, p.vehId)]
  if not entry or not entry.gameVehId then return end
  local veh = be:getObjectByID(entry.gameVehId)
  if not veh then return end
  veh:queueLuaCommand(string.format("lanmpInputsVE.applyInputs(%q)", jsonEncode(p.inputs)))
end

function M.handleGear(p)
  local entry = remotes[remoteKey(p.playerId, p.vehId)]
  if not entry or not entry.gameVehId then return end
  local veh = be:getObjectByID(entry.gameVehId)
  if not veh then return end
  veh:queueLuaCommand(string.format("lanmpInputsVE.applyGear(%q)", tostring(p.gear)))
end

function M.handleReset(p)
  local entry = remotes[remoteKey(p.playerId, p.vehId)]
  if not entry or not entry.gameVehId then return end
  local veh = be:getObjectByID(entry.gameVehId)
  if not veh then return end
  veh:queueLuaCommand("recovery.startRecovering()")
  veh:setPositionRotation(p.pos[1], p.pos[2], p.pos[3], p.rot[1], p.rot[2], p.rot[3], p.rot[4])
  veh:queueLuaCommand("recovery.stopRecovering()")
end

-- Applies a position update to a remote vehicle from game engine lua. Called by
-- lanmpSyncVE when it decides the vehicle has drifted too far to correct with
-- forces alone; doing the transform here avoids destroying the soft body.
function M.setPositionRotationVelocity(gameVehId, data)
  local veh = be:getObjectByID(gameVehId)
  if not veh then return end

  local vel = vec3(data.vel)
  local localVel = vec3(veh:getVelocity())
  local refNodeId = veh:getRefNodeId()
  local vehRot = quatFromDir(-vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp()))
  local rot = vehRot:inversed() * quat(data.rot)
  local pos = vec3(data.pos)

  veh:setClusterPosRelRot(refNodeId, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)

  -- setClusterPosRelRot rotates the existing velocity too, so cancel that out.
  vel = vel - localVel:rotated(rot)
  veh:applyClusterVelocityScaleAdd(refNodeId, 1, vel.x, vel.y, vel.z)

  local rvel = vec3(data.rvel)
  veh:queueLuaCommand(string.format(
    "lanmpVelocityVE.setAngularVelocity(%f,%f,%f,%f,%f,%f)",
    vel.x, vel.y, vel.z, rvel.x, rvel.y, rvel.z))
end

-- ------------------------------------------------------------------- update

function M.onUpdate(dt)
  if not lanmp_session.isConnected() then return end

  tickTimer = tickTimer + dt
  if tickTimer >= tickInterval then
    tickTimer = 0
    for gameVehId, _ in pairs(localVehicles) do
      local veh = be:getObjectByID(gameVehId)
      if veh then
        veh:queueLuaCommand("lanmpSyncVE.sendState()")
      else
        M.onVehicleDestroyed(gameVehId)
      end
    end
  end

  pingTimer = pingTimer + dt
  if pingTimer >= 1 then
    pingTimer = 0
    be:queueAllObjectLua(string.format("if lanmpSyncVE then lanmpSyncVE.setPing(%f) end",
      lanmp_session.getPing() / 1000))
  end

  -- Clean up remote vehicles whose owner stopped sending anything.
  local now = os.clock()
  for key, entry in pairs(remotes) do
    if entry.lastPacket and now - entry.lastPacket > REMOTE_STALE_S then
      log("W", "lanmp", "removing stale remote vehicle " .. key)
      M.handleDespawn({ playerId = entry.playerId, vehId = entry.netId })
    end
  end
end

return M
