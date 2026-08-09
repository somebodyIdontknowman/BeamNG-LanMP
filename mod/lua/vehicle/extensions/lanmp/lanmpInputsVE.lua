-- Driver input replication.
--
-- Positions alone make a remote car look right from the outside but its wheels
-- do not steer, the brake lights stay off and the engine is silent. Sending the
-- driver inputs fixes all of that for a handful of bytes per change.

local M = {}

local SEND_INTERVAL = 1 / 15
local SMOOTH_RATE = 30
local EPSILON = 0.0025

local tracked = { "steering", "throttle", "brake", "parkingbrake", "clutch" }

local mode = nil
local sendTimer = 0
local lastSent = {}
local lastGear = nil
local gearTimer = 0

local targets = {}          -- inputName -> {value, smoother, current}
local remoteGear = nil
local inputsLocked = false

function M.setLocal()
  mode = "local"
  if inputsLocked then
    for name in pairs(input.state) do input.setAllowedInputSource(name, "local", true) end
    inputsLocked = false
  end
end

function M.setRemote()
  mode = "remote"
end

local function readInput(name)
  local value = electrics.values[name] or electrics.values[name .. "_input"]
  if not value then return nil end
  if name == "steering" and v.data.input then
    value = -value / (v.data.input.steeringWheelLock or 1)
  end
  if math.abs(value) < EPSILON then value = 0 end
  return math.floor(value * 1000 + 0.5) / 1000
end

local function sendInputs(dt)
  sendTimer = sendTimer + dt
  gearTimer = gearTimer + dt
  if sendTimer < SEND_INTERVAL then return end
  sendTimer = 0

  local changed = {}
  local any = false
  for _, name in ipairs(tracked) do
    local value = readInput(name)
    if value and lastSent[name] ~= value then
      lastSent[name] = value
      changed[name] = value
      any = true
    end
  end

  -- Resend the gear periodically so someone who joins mid-session sees the car
  -- in the right gear rather than neutral.
  local gear = electrics.values.gear
  if gear and (gear ~= lastGear or gearTimer > 5) then
    lastGear = gear
    gearTimer = 0
    changed.gear = tostring(gear)
    any = true
  end

  if not any then return end
  obj:queueGameEngineLua("lanmp_vehicles.onLocalInputs(" .. obj:getID() .. ", '" ..
    jsonEncode(changed) .. "')")
end

local function ensureTarget(name)
  if targets[name] then return targets[name] end
  local limits = input.state[name]
  targets[name] = {
    value = 0,
    current = 0,
    smoother = newTemporalSmoothingNonLinear(SMOOTH_RATE),
    maxLimit = limits and limits.maxLimit or 1,
    minLimit = limits and limits.minLimit or -1,
  }
  return targets[name]
end

function M.applyInputs(encoded)
  local decoded = jsonDecode(encoded)
  if not decoded then return end
  mode = "remote"
  for name, value in pairs(decoded) do
    if name == "gear" then
      remoteGear = value
    elseif type(value) == "number" then
      ensureTarget(name).value = value
    end
  end
end

function M.applyGear(gear)
  remoteGear = gear
end

local function applyRemoteGear()
  if not remoteGear or not electrics.values.gearIndex then return end
  if electrics.values.gear == remoteGear then return end
  local device = powertrain.getDevice("gearbox") or powertrain.getDevice("mainMotor")
    or powertrain.getDevice("frontMotor") or powertrain.getDevice("rearMotor")
  if not device then return end

  local index = tonumber(remoteGear)
  if index and device.setGearIndex then
    device:setGearIndex(index)
  elseif controller.mainController and controller.mainController.shiftToGearIndex then
    local modes = { R = -1, N = 0, P = 1, D = 2, S = 3, ["2"] = 4, ["1"] = 5, M = 6 }
    local target = modes[string.sub(tostring(remoteGear), 1, 1)]
    if target then controller.mainController.shiftToGearIndex(target) end
  end
end

local function applyRemote(dt)
  if not inputsLocked then
    inputsLocked = true
    for name in pairs(input.state) do
      input.setAllowedInputSource(name, "local", false)
      input.setAllowedInputSource(name, "lanmp", true)
    end
  end

  applyRemoteGear()

  for name, data in pairs(targets) do
    local diff = math.abs(data.value - data.current)
    -- Exponential smoothing never quite reaches its target, which would leave
    -- the brake slightly applied forever, so snap when we are close or far.
    if diff > 0.2 or diff < 1e-6
      or math.abs(data.value - data.maxLimit) < 0.01
      or math.abs(data.value - data.minLimit) < 0.01 then
      data.current = data.value
      data.smoother:set(data.value, dt)
    else
      data.current = data.smoother:get(data.value, dt)
    end
    input.event(name, data.current, FILTER_DIRECT, nil, nil, nil, "lanmp")
  end
end

local function updateGFX(dt)
  if mode == "local" then
    sendInputs(dt)
  elseif mode == "remote" then
    applyRemote(dt)
  end
end

local function onReset()
  lastSent = {}
  lastGear = nil
  for _, data in pairs(targets) do
    data.value = 0
    data.current = 0
    data.smoother:reset()
  end
end

M.updateGFX = updateGFX
M.onReset = onReset

return M
