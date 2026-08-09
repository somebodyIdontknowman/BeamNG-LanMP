-- Per-vehicle state sync.
--
-- Local vehicles: sample position/rotation/velocity and hand it to game engine
-- lua once per network tick.
--
-- Remote vehicles: read the latest packet from this vehicle's mailbox, predict
-- forward by the measured latency, then steer the soft body towards that target
-- with velocity corrections. Only when the error is too large to correct do we
-- ask game engine lua to reposition the cluster, which is what stops remote
-- cars from jittering or being torn apart.

local M = {}

local abs, min, max = math.abs, math.min, math.max

-- Correction tuning
local posCorrectMul = 5     -- velocity used per metre of position error
local posForceMul   = 5     -- how aggressively velocity error is corrected
local minPosForce   = 0.04
local maxPosForce   = 100
local rotCorrectMul = 7     -- angular velocity used per radian of rotation error
local rotForceMul   = 7
local minRotForce   = 0.02
local maxRotForce   = 50

-- Teleport thresholds. Scaled by speed so a fast car is allowed to drift more
-- before we give up on force correction.
local tpDistBase = 1.0
local tpDistPerSpeed = 0.1
local tpDistInstant = 0.5
local tpRotBase = 0.5
local tpRotPerSpeed = 0.2
local tpRotInstant = 0.5
local tpDelay = 1.0

local maxPredict = 0.3      -- never extrapolate further than this
local packetTimeout = 0.15  -- stop predicting if the stream stalls

local mode = nil            -- nil | "local" | "remote"
local mailbox = nil
local lastMailboxVersion = -1

local timer = 0
local lastDt = 1 / 60
local framesSinceReset = 0
local tpTimer = 0
local ownPing = 0

local smoothVel = vec3(0, 0, 0)
local smoothRvel = vec3(0, 0, 0)

local remote = {
  pos = nil,
  rot = quat(0, 0, 0, 1),
  vel = vec3(0, 0, 0),
  rvel = vec3(0, 0, 0),
  acc = vec3(0, 0, 0),
  racc = vec3(0, 0, 0),
  tim = 0,
  recTime = 0,
  timeOffset = 0,
}

-- Simple linear vector smoother (the engine only ships a scalar one).
local VecSmoother = {}
VecSmoother.__index = VecSmoother
local function newVecSmoother(rate)
  return setmetatable({ rate = rate or 10, state = vec3(0, 0, 0) }, VecSmoother)
end
function VecSmoother:get(sample, dt)
  self.state = self.state + (sample - self.state) * min(self.rate * dt, 1)
  return self.state
end
function VecSmoother:set(sample) self.state = sample end
function VecSmoother:reset() self.state = vec3(0, 0, 0) end

local localVelSmoother = newVecSmoother(50)
local localRvelSmoother = newVecSmoother(50)
local remoteVelSmoother = newVecSmoother(2)
local remoteRvelSmoother = newVecSmoother(2)
local remoteAccSmoother = newVecSmoother(1)
local remoteRaccSmoother = newVecSmoother(1)
local timeOffsetSmoother = newTemporalSmoothingNonLinear(1)

local function limitLength(v, len)
  local l = v:length()
  if l > len then return v * (len / l) end
  return v
end

local function vehicleRotation()
  return quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
end

-- ------------------------------------------------------------------- setup --

function M.setLocal()
  mode = "local"
  mailbox = nil
  if lanmpInputsVE then lanmpInputsVE.setLocal() end
end

function M.setRemote(mailboxName)
  mode = "remote"
  mailbox = mailboxName
  lastMailboxVersion = -1
  framesSinceReset = 0
  if v then v.mpVehicleType = "R" end
  if lanmpInputsVE then lanmpInputsVE.setRemote() end
end

function M.setPing(p) ownPing = p or 0 end

function M.getMode() return mode end

-- ------------------------------------------------------------ local vehicle --

-- Called from game engine lua once per network tick.
function M.sendState()
  if mode ~= "local" then return end

  local rot = vehicleRotation()
  local rvel = smoothRvel:rotated(rot)
  local cog = lanmpVelocityVE and lanmpVelocityVE.cogRel:rotated(rot) or vec3(0, 0, 0)
  local pos = vec3(obj:getPosition()) + cog
  local vel = smoothVel + cog:cross(rvel)

  -- A single NaN here would poison the remote simulation, so drop the sample.
  if pos ~= pos or vel ~= vel or rvel ~= rvel then return end

  local payload = {
    pos = { pos.x, pos.y, pos.z },
    rot = { rot.x, rot.y, rot.z, rot.w },
    vel = { vel.x, vel.y, vel.z },
    rvel = { rvel.x, rvel.y, rvel.z },
    tim = timer,
  }
  obj:queueGameEngineLua("lanmp_vehicles.onLocalState(" .. obj:getID() .. ", '" ..
    jsonEncode(payload) .. "')")
end

-- ----------------------------------------------------------- remote vehicle --

local function readMailbox()
  if not mailbox then return end
  local version = obj:getLastMailboxVersion(mailbox)
  if version == lastMailboxVersion then return end
  lastMailboxVersion = version

  local raw = obj:getLastMailbox(mailbox)
  if not raw or raw == "" then return end
  local d = jsonDecode(raw)
  if not d or not d.pos or not d.tim then return end
  if remote.pos and d.tim <= remote.tim then return end  -- out of order

  local pos = vec3(d.pos[1], d.pos[2], d.pos[3])
  local vel = vec3(d.vel[1], d.vel[2], d.vel[3])
  local rvel = vec3(d.rvel[1], d.rvel[2], d.rvel[3])
  local dt = max(d.tim - remote.tim, 0.001)

  remote.acc = limitLength((vel - remote.vel) / dt, 100)
  remote.racc = limitLength((rvel - remote.rvel) / dt, 50)
  remote.pos = pos
  remote.rot = quat(d.rot[1], d.rot[2], d.rot[3], d.rot[4])
  remote.vel = vel
  remote.rvel = rvel
  remote.tim = d.tim
  remote.recTime = timer
  -- Half of each side's round trip is roughly the one way delay.
  remote.timeOffset = timer - d.tim - ownPing / 2 - (d.ping or 0) / 2 - lastDt
end

local function updateRemote(dt)
  readMailbox()
  if not remote.pos then return end
  if timer - remote.recTime > packetTimeout then return end

  local vehRot = vehicleRotation()
  local vehRvel = smoothRvel:rotated(vehRot)
  local cog = lanmpVelocityVE and lanmpVelocityVE.cogRel:rotated(vehRot) or vec3(0, 0, 0)
  local vehPos = vec3(obj:getPosition()) + cog
  local vehVel = smoothVel + cog:cross(vehRvel)

  -- Convert the sender's clock into ours, smoothed so jitter does not translate
  -- straight into position noise.
  local timeOffset = timeOffsetSmoother:get(remote.timeOffset, dt)
  if abs(timeOffset - remote.timeOffset) > 1 then
    timeOffsetSmoother:set(remote.timeOffset)
    timeOffset = remote.timeOffset
  end

  local predictTime = min(max(timer - (remote.tim + timeOffset), -maxPredict), maxPredict)
  local smootherDt = dt / max(abs(predictTime), 1e-6)

  local rVel = remoteVelSmoother:get(remote.vel, smootherDt)
  local rRvel = remoteRvelSmoother:get(remote.rvel, smootherDt)
  local rAcc = remoteAccSmoother:get(remote.acc, smootherDt)
  local rRacc = remoteRaccSmoother:get(remote.racc, smootherDt)

  local targetPos = remote.pos + rVel * predictTime + 0.5 * rAcc * predictTime * predictTime
  local targetVel = rVel + rAcc * predictTime
  local rotAdd = rRvel * predictTime + 0.5 * rRacc * predictTime * predictTime
  local targetRot = remote.rot * quatFromEuler(rotAdd.x, rotAdd.y, rotAdd.z)
  local targetRvel = rRvel + rRacc * predictTime

  local posError = targetPos - vehPos
  local rotErrorEuler = (vehRot:inversed() * targetRot):toEulerYXZ()
  local rotError = vec3(rotErrorEuler.y, rotErrorEuler.z, rotErrorEuler.x)

  local speed = max(targetVel:length(), vehVel:length())
  local rotSpeed = max(targetRvel:length(), vehRvel:length())
  local tpDist = tpDistBase + speed * tpDistPerSpeed
  local tpDistNow = tpDistBase + speed * tpDistInstant
  local tpRot = tpRotBase + rotSpeed * tpRotPerSpeed
  local tpRotNow = tpRotBase + rotSpeed * tpRotInstant

  local posErrorLen = posError:length()
  local rotErrorLen = rotError:length()

  if posErrorLen > tpDist or rotErrorLen > tpRot then
    tpTimer = tpTimer + dt
  else
    tpTimer = 0
  end

  framesSinceReset = framesSinceReset + 1
  if framesSinceReset > 5 then
    if framesSinceReset == 6 or tpTimer > (tpDelay + abs(predictTime))
      or posErrorLen > tpDistNow or rotErrorLen > tpRotNow then
      -- Too far gone to pull back with forces: hand the transform to game
      -- engine lua, which can move the cluster without damaging the vehicle.
      local pt = predictTime + dt
      local pos = remote.pos + rVel * pt + 0.5 * rAcc * pt * pt
      local vel = rVel + rAcc * pt
      local add = rRvel * pt + 0.5 * rRacc * pt * pt
      local rot = remote.rot * quatFromEuler(add.x, add.y, add.z)
      local tpPos = pos - (lanmpVelocityVE and lanmpVelocityVE.cogRel:rotated(rot) or vec3(0, 0, 0))

      obj:queueGameEngineLua(string.format(
        "lanmp_vehicles.setPositionRotationVelocity(%d, {pos={%f,%f,%f},rot={%f,%f,%f,%f},vel={%f,%f,%f},rvel={%f,%f,%f}})",
        obj:getID(), tpPos.x, tpPos.y, tpPos.z, rot.x, rot.y, rot.z, rot.w,
        vel.x, vel.y, vel.z, targetRvel.x, targetRvel.y, targetRvel.z))

      remoteVelSmoother:set(remote.vel)
      remoteRvelSmoother:set(remote.rvel)
      remoteAccSmoother:reset()
      remoteRaccSmoother:reset()
      remote.acc = vec3(0, 0, 0)
      remote.racc = vec3(0, 0, 0)
      tpTimer = 0
      return
    end
  else
    return
  end

  local velError = targetVel - vehVel
  local rvelError = targetRvel - vehRvel

  local targetAcc = limitLength((velError + posError * posCorrectMul) * min(posForceMul * dt, 1),
    maxPosForce * dt)
  local targetRacc = limitLength((rvelError + rotError * rotCorrectMul) * min(rotForceMul * dt, 1),
    maxRotForce * dt)

  if not lanmpVelocityVE then return end
  if targetRacc:length() > minRotForce or vehVel:length() > 1 then
    lanmpVelocityVE.addAngularVelocity(targetAcc.x, targetAcc.y, targetAcc.z,
      targetRacc.x, targetRacc.y, targetRacc.z)
  elseif targetAcc:length() > minPosForce then
    lanmpVelocityVE.addVelocity(targetAcc.x, targetAcc.y, targetAcc.z)
  end
end

-- ------------------------------------------------------------------ hooks --

local function onPhysicsStep(dtSim)
  smoothVel = localVelSmoother:get(vec3(obj:getVelocity()), dtSim)
  smoothRvel = localRvelSmoother:get(vec3(obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity(), obj:getYawAngularVelocity()), dtSim)
end

local function updateGFX(dt)
  timer = timer + dt
  lastDt = dt
  if mode == "remote" then updateRemote(dt) end
end

local function onReset()
  localVelSmoother:reset()
  localRvelSmoother:reset()
  remoteVelSmoother:reset()
  remoteRvelSmoother:reset()
  remoteAccSmoother:reset()
  remoteRaccSmoother:reset()
  remote.acc = vec3(0, 0, 0)
  remote.racc = vec3(0, 0, 0)
  framesSinceReset = 0
  tpTimer = 0
end

local function onInit()
  enablePhysicsStepHook()
end

M.onInit = onInit
M.onExtensionLoaded = onInit
M.onReset = onReset
M.onPhysicsStep = onPhysicsStep
M.updateGFX = updateGFX

return M
