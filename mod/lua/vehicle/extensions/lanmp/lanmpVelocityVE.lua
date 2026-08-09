-- Applies velocity / angular velocity corrections to a vehicle without
-- teleporting it.
--
-- Accelerating every node of the main cluster by the same amount moves the
-- whole car without stretching beams, which is what makes remote vehicles look
-- solid instead of exploding.

local M = {}

local physicsFPS = 2000
local refNode = 0

M.cogRel = vec3(0, 0, 0)

local function calcCOG()
  local cog = vec3(0, 0, 0)
  local totalMass = 0
  for _, n in pairs(v.data.nodes) do
    local mass = obj:getNodeMass(n.cid)
    cog:setAdd(vec3(obj:getNodePosition(n.cid)) * mass)
    totalMass = totalMass + mass
  end
  if totalMass <= 0 then return end
  cog:setScaled(1 / totalMass)
  local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  M.cogRel = cog:rotated(rot:inversed())
end

local function onInit()
  physicsFPS = obj:getPhysicsFPS() or 2000
  refNode = (v.data.refNodes and v.data.refNodes[0] and v.data.refNodes[0].ref) or 0
  calcCOG()
end

-- dv is a velocity change in m/s applied over one physics tick.
function M.addVelocity(x, y, z)
  obj:applyClusterLinearAngularAccel(refNode, vec3(x, y, z) * physicsFPS, vec3())
end

function M.setVelocity(x, y, z)
  local vel = obj:getVelocity()
  M.addVelocity(x - vel.x, y - vel.y, z - vel.z)
end

-- Adds both a linear and an angular velocity change. The linear part is
-- corrected for the offset between the reference node and the centre of mass so
-- the rotation happens around the centre of mass rather than the ref node.
function M.addAngularVelocity(x, y, z, pitchAV, rollAV, yawAV)
  local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local cog = M.cogRel:rotated(rot)
  local vel = vec3(x, y, z) - cog:cross(vec3(pitchAV, rollAV, yawAV))
  obj:applyClusterLinearAngularAccel(refNode, vel * physicsFPS,
    -vec3(pitchAV, rollAV, yawAV) * physicsFPS)
end

function M.setAngularVelocity(x, y, z, pitchAV, rollAV, yawAV)
  local rot = quatFromDir(-vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
  local cog = M.cogRel:rotated(rot)

  local targetRvel = vec3(pitchAV, rollAV, yawAV)
  local currentRvel = vec3(obj:getPitchAngularVelocity(), obj:getRollAngularVelocity(),
    obj:getYawAngularVelocity()):rotated(rot)

  local currentVel = vec3(obj:getVelocity()) + cog:cross(currentRvel)
  local dVel = vec3(x, y, z) - currentVel
  local dRvel = targetRvel - currentRvel

  M.addAngularVelocity(dVel.x, dVel.y, dVel.z, dRvel.x, dRvel.y, dRvel.z)
end

function M.recalculateCOG() calcCOG() end

M.onInit = onInit
M.onExtensionLoaded = onInit
M.onReset = calcCOG

return M
