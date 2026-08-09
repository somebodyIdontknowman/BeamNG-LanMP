-- LANMP wire protocol (client side).
--
-- Mirrors server/src/Protocol.h. All integers little endian, strings are u16
-- length prefixed. Gameplay packets carry {playerId, sessionKey} right after
-- the type byte; the server rejects anything else.

local M = {}

local ffi = require("ffi")

M.VERSION = 2

M.Type = {
  Hello           = 0x01,
  HelloAck        = 0x02,
  Register        = 0x03,
  RegisterAck     = 0x04,
  Login           = 0x05,
  LoginAck        = 0x06,
  AuthNack        = 0x07,
  Discover        = 0x08,
  DiscoverAck     = 0x09,

  PosUpdate       = 0x10,
  PosBroadcast    = 0x11,
  InputUpdate     = 0x12,
  InputBroadcast  = 0x13,
  GearUpdate      = 0x14,
  GearBroadcast   = 0x15,

  VehicleSpawn    = 0x20,
  VehicleSpawnB   = 0x21,
  VehicleDespawn  = 0x22,
  VehicleDespawnB = 0x23,
  VehicleReset    = 0x24,
  VehicleResetB   = 0x25,

  Chat            = 0x30,
  ChatBroadcast   = 0x31,

  Disconnect      = 0x40,
  Kick            = 0x41,

  Ping            = 0x50,
  Pong            = 0x51,

  PlayerJoin      = 0x60,
  PlayerLeave     = 0x61,
  Roster          = 0x62,
}

M.AuthReason = {
  [1] = "Wrong PIN",
  [2] = "Unknown user",
  [3] = "Username already registered",
  [4] = "Too many attempts, wait 30 seconds",
  [5] = "Server is full",
  [6] = "Protocol version mismatch",
  [7] = "Invalid username",
  [8] = "That account is already connected",
}

M.Input = {
  steering     = 1,
  throttle     = 2,
  brake        = 3,
  parkingbrake = 4,
  clutch       = 5,
  lightbar     = 6,
  headlights   = 7,
  signal       = 8,
  horn         = 9,
}

M.InputById = {}
for name, id in pairs(M.Input) do M.InputById[id] = name end

-- ---------------------------------------------------------------- encoding --

local conv = ffi.new("union { float f; uint32_t u; uint8_t b[4]; }")
local char = string.char
local floor = math.floor

local function u8(v) return char(floor(v) % 256) end

local function u16(v)
  v = floor(v) % 65536
  return char(v % 256, floor(v / 256))
end

local function u32(v)
  v = floor(v) % 4294967296
  return char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256)
end

local function f32(v)
  conv.f = v or 0
  return ffi.string(conv.b, 4)
end

local function str(s)
  s = tostring(s or "")
  if #s > 65535 then s = s:sub(1, 65535) end
  return u16(#s) .. s
end

M.u8, M.u16, M.u32, M.f32, M.str = u8, u16, u32, f32, str

-- ---------------------------------------------------------------- decoding --

local Reader = {}
Reader.__index = Reader

function M.reader(data)
  return setmetatable({ d = data, p = 1, n = #data }, Reader)
end

function Reader:take(count)
  if self.p + count - 1 > self.n then error("packet truncated", 0) end
  local s = self.d:sub(self.p, self.p + count - 1)
  self.p = self.p + count
  return s
end

function Reader:u8()
  return self:take(1):byte()
end

function Reader:u16()
  local a, b = self:take(2):byte(1, 2)
  return a + b * 256
end

function Reader:u32()
  local a, b, c, d = self:take(4):byte(1, 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

function Reader:f32()
  ffi.copy(conv.b, self:take(4), 4)
  return conv.f
end

function Reader:str()
  return self:take(self:u16())
end

function Reader:remaining()
  return self.n - self.p + 1
end

-- ------------------------------------------------------------ constructors --

function M.hello(clientVersion)
  return u8(M.Type.Hello) .. u16(M.VERSION) .. str(clientVersion or "lanmp")
end

function M.discover(nonce)
  return u8(M.Type.Discover) .. u16(M.VERSION) .. u32(nonce or 0)
end

function M.register(username)
  return u8(M.Type.Register) .. str(username)
end

function M.login(username, pin)
  return u8(M.Type.Login) .. str(username) .. str(pin)
end

-- Auth header shared by every in-session packet.
local function auth(session)
  return u32(session.playerId) .. u32(session.sessionKey)
end
M.auth = auth

function M.posUpdate(session, vehId, seq, tim, pos, rot, vel, rvel)
  return u8(M.Type.PosUpdate) .. auth(session) .. u32(vehId) .. u32(seq) .. f32(tim)
    .. f32(pos[1]) .. f32(pos[2]) .. f32(pos[3])
    .. f32(rot[1]) .. f32(rot[2]) .. f32(rot[3]) .. f32(rot[4])
    .. f32(vel[1]) .. f32(vel[2]) .. f32(vel[3])
    .. f32(rvel[1]) .. f32(rvel[2]) .. f32(rvel[3])
end

-- inputs: array of {id, value}
function M.inputUpdate(session, vehId, inputs)
  local parts = { u8(M.Type.InputUpdate), auth(session), u32(vehId), u8(#inputs) }
  for i = 1, #inputs do
    parts[#parts + 1] = u8(inputs[i][1]) .. f32(inputs[i][2])
  end
  return table.concat(parts)
end

function M.gearUpdate(session, vehId, gear)
  return u8(M.Type.GearUpdate) .. auth(session) .. u32(vehId) .. str(gear)
end

function M.vehicleSpawn(session, vehId, model, config, plate, colorInt)
  return u8(M.Type.VehicleSpawn) .. auth(session) .. u32(vehId)
    .. str(model) .. str(config) .. str(plate or "") .. u32(colorInt or 0)
end

function M.vehicleDespawn(session, vehId)
  return u8(M.Type.VehicleDespawn) .. auth(session) .. u32(vehId)
end

function M.vehicleReset(session, vehId, pos, rot)
  return u8(M.Type.VehicleReset) .. auth(session) .. u32(vehId)
    .. f32(pos[1]) .. f32(pos[2]) .. f32(pos[3])
    .. f32(rot[1]) .. f32(rot[2]) .. f32(rot[3]) .. f32(rot[4])
end

function M.chat(session, message)
  return u8(M.Type.Chat) .. auth(session) .. str(message)
end

function M.disconnect(session)
  return u8(M.Type.Disconnect) .. auth(session)
end

function M.ping(session, pingId, clientTime, measuredRttMs)
  return u8(M.Type.Ping) .. auth(session) .. u32(pingId) .. f32(clientTime)
    .. u16(math.min(measuredRttMs or 0, 65535))
end

-- ---------------------------------------------------------------- decoding --

-- Returns a table {t = <type>, ...} or nil plus an error string.
function M.decode(data)
  if not data or #data < 1 then return nil, "empty" end
  local ok, res = pcall(function()
    local r = M.reader(data)
    local t = r:u8()
    local p = { t = t }

    if t == M.Type.HelloAck then
      p.version = r:u16()
      p.serverName = r:str()
      p.maxPlayers = r:u8()
      p.tickRate = r:u8()
      p.map = r:str()
      p.playerCount = r:u8()

    elseif t == M.Type.DiscoverAck then
      p.version = r:u16()
      p.nonce = r:u32()
      p.serverName = r:str()
      p.players = r:u8()
      p.maxPlayers = r:u8()
      p.map = r:str()
      p.port = r:u16()

    elseif t == M.Type.RegisterAck then
      p.username = r:str()
      p.pin = r:str()

    elseif t == M.Type.LoginAck then
      p.playerId = r:u32()
      p.sessionKey = r:u32()
      p.map = r:str()
      p.tickRate = r:u8()

    elseif t == M.Type.AuthNack then
      p.reason = r:u8()
      p.message = r:str()

    elseif t == M.Type.PosBroadcast then
      p.playerId = r:u32()
      p.vehId = r:u32()
      p.seq = r:u32()
      p.tim = r:f32()
      p.pos = { r:f32(), r:f32(), r:f32() }
      p.rot = { r:f32(), r:f32(), r:f32(), r:f32() }
      p.vel = { r:f32(), r:f32(), r:f32() }
      p.rvel = { r:f32(), r:f32(), r:f32() }
      p.senderPing = r:u16()

    elseif t == M.Type.InputBroadcast then
      p.playerId = r:u32()
      p.vehId = r:u32()
      local count = r:u8()
      p.inputs = {}
      for _ = 1, count do
        local id = r:u8()
        p.inputs[M.InputById[id] or tostring(id)] = r:f32()
      end

    elseif t == M.Type.GearBroadcast then
      p.playerId = r:u32()
      p.vehId = r:u32()
      p.gear = r:str()

    elseif t == M.Type.VehicleSpawnB then
      p.playerId = r:u32()
      p.vehId = r:u32()
      p.model = r:str()
      p.config = r:str()
      p.plate = r:str()
      p.color = r:u32()

    elseif t == M.Type.VehicleDespawnB then
      p.playerId = r:u32()
      p.vehId = r:u32()

    elseif t == M.Type.VehicleResetB then
      p.playerId = r:u32()
      p.vehId = r:u32()
      p.pos = { r:f32(), r:f32(), r:f32() }
      p.rot = { r:f32(), r:f32(), r:f32(), r:f32() }

    elseif t == M.Type.ChatBroadcast then
      p.playerId = r:u32()
      p.name = r:str()
      p.message = r:str()

    elseif t == M.Type.Kick then
      p.reason = r:str()

    elseif t == M.Type.Pong then
      p.pingId = r:u32()
      p.clientTime = r:f32()

    elseif t == M.Type.PlayerJoin or t == M.Type.PlayerLeave then
      p.playerId = r:u32()
      p.name = r:str()

    elseif t == M.Type.Roster then
      local count = r:u8()
      p.players = {}
      for _ = 1, count do
        local entry = {}
        entry.id = r:u32()
        entry.name = r:str()
        entry.ping = r:u16()
        entry.isYou = r:u8() == 1
        p.players[#p.players + 1] = entry
      end

    else
      p.unknown = true
    end

    return p
  end)

  if not ok then return nil, tostring(res) end
  return res
end

return M
