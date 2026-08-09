-- In-world nametags: player name, live ping and distance above every remote
-- vehicle. Uses the engine's FFI debug text drawer, which is garbage free and
-- the same call BeamNG's own overlays use.

local M = {}

local ffi = require("ffi")
local drawTextAdvanced = (ffi and ffi.C and ffi.C.BNG_DBG_DRAW_TextAdvanced) or nop

local settings = {
  enabled = true,
  showPing = true,
  showDistance = true,
  fadeDistance = 250,      -- metres at which a tag has faded out completely
  hideBehindObjects = false,
  maxDistance = 2000,
}

local pos = vec3()
local dir = vec3()
local dirUp = vec3()
local camPos = vec3()

local textCache = {}       -- key -> {text, name, ping, dist}

function M.isEnabled() return settings.enabled end
function M.getSettings() return settings end

function M.setEnabled(v)
  settings.enabled = v and true or false
end

function M.setSetting(key, value)
  if settings[key] == nil then return end
  settings[key] = value
end

function M.toggle()
  settings.enabled = not settings.enabled
  return settings.enabled
end

local function formatDistance(d)
  if d >= 1000 then return string.format("%.1fkm", d / 1000) end
  return string.format("%dm", math.floor(d + 0.5))
end

local function tagText(key, name, ping, distance)
  local pingPart = settings.showPing and (" " .. tostring(ping) .. "ms") or ""
  local distPart = (settings.showDistance and distance > 10) and (" " .. formatDistance(distance)) or ""
  local cached = textCache[key]
  local text = " " .. name .. pingPart .. distPart .. " "
  if not cached or cached.raw ~= text then
    -- String() userdata is what the FFI drawer expects; cache it so we are not
    -- allocating one per vehicle per frame.
    textCache[key] = { raw = text, str = String(text) }
  end
  return textCache[key].str
end

function M.onPreRender(dt)
  if not settings.enabled then return end
  if not lanmp_session or not lanmp_session.isConnected() then return end

  local remotes = lanmp_vehicles.getRemotes()
  if not remotes or not next(remotes) then return end

  local players = lanmp_session.getPlayers()
  local cam = core_camera and core_camera.getPosition()
  if not cam then return end
  camPos:set(cam)

  for key, entry in pairs(remotes) do
    local player = players[entry.playerId]
    if player then
      local height = 1.5
      local havePos = false

      if entry.gameVehId then
        local veh = be:getObjectByID(entry.gameVehId)
        if veh and veh:getActive() then
          pos:set(be:getObjectOOBBCenterXYZ(entry.gameVehId))
          height = (veh:getInitialHeight() or 1.5) * 0.5 + 0.35
          havePos = true
        end
      end

      if not havePos and entry.pos then
        pos:set(entry.pos[1], entry.pos[2], entry.pos[3])
        havePos = true
      end

      if havePos then
        pos.z = pos.z + height
        local distance = camPos:distance(pos)
        if distance <= settings.maxDistance then
          local alpha = clamp(linearScale(distance, settings.fadeDistance, 0, 0, 1), 0.25, 1)
          local ping = entry.ping or player.ping or 0
          local backAlpha = math.floor(alpha * 110)
          drawTextAdvanced(
            pos.x, pos.y, pos.z,
            tagText(key, player.name, ping, distance),
            color(255, 255, 255, alpha * 254),
            true,                                   -- draw background
            false,
            color(0, 0, 0, backAlpha),
            false,                                  -- shadow
            settings.hideBehindObjects
          )
        end
      end
    end
  end
end

function M.onClientEndMission()
  textCache = {}
end

return M
