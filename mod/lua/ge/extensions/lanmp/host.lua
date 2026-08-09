-- Launches the bundled lanmp_server.exe from inside the mod so the in-game
-- "Host a Server" button just works — no separate download or batch file.
--
-- The exe ships inside the (possibly still-zipped) mod at
--   lua/ge/extensions/lanmp/bin/lanmp_server.exe
-- We copy it out to the native tmp/ dir, resolve the real path with
-- FS:virtual2Native, then spawn it detached so Lua never blocks.

local M = {}

local BIN_VPATH = "lua/ge/extensions/lanmp/bin/lanmp_server.exe"
local TMP_VPATH = "tmp/lanmp_server.exe"

local running = false

local function logErr(msg) log("E", "lanmp_host", msg) end

-- Copy the bundled binary out of the VFS (which may be a zip) and return its
-- real filesystem path, or nil on failure.
local function resolveExe()
  if not FS:fileExists(BIN_VPATH) then
    logErr("server binary not found in mod: " .. BIN_VPATH)
    return nil
  end
  local ok = pcall(function() FS:copyFile(BIN_VPATH, TMP_VPATH) end)
  if not ok or not FS:fileExists(TMP_VPATH) then
    logErr("failed to extract server binary to " .. TMP_VPATH)
    return nil
  end
  local real = nil
  pcall(function() real = FS:virtual2Native(TMP_VPATH) end)
  if not real or real == "" then
    logErr("could not resolve native path for " .. TMP_VPATH)
    return nil
  end
  return real
end

local function shellEscape(s) return '"' .. tostring(s):gsub('"', '') .. '"' end

-- Start the server with the given options, then return true on success.
-- opts: { name, port, maxPlayers, map, closed }
function M.startServer(opts)
  opts = opts or {}
  if running then
    log("W", "lanmp_host", "startServer called but server is already running")
    return false
  end
  local exe = resolveExe()
  if not exe then
    guihooks.trigger("LanmpHostError", "Server binary not found in mod. Reinstall the LANMP mod.")
    return false
  end

  local name = opts.name or "LANMP Server"
  local port = tonumber(opts.port) or 4144
  local maxPlayers = tonumber(opts.maxPlayers) or 8
  local map = opts.map or "/levels/gridmap_v2/info.json"
  local closedFlag = opts.closed and "--closed" or ""

  local cmd = string.format(
    'cmd /c start "LANMP Server" %s --name %s --port %d --max-players %d --map %s %s',
    shellEscape(exe), shellEscape(name), port, maxPlayers, shellEscape(map), closedFlag
  )
  log("I", "lanmp_host", "launching server: " .. cmd)
  -- io.popen with `start` returns immediately; the exe runs in its own console.
  local p = io.popen(cmd)
  if p then p:close() end
  running = true
  M.refreshUI()
  log("I", "lanmp_host", "server started on UDP " .. port)
  return true
end

-- Best-effort stop. The server runs in its own console window; killing by
-- image name closes it. If multiple instances exist this kills all of them.
function M.stopServer()
  if not running then return end
  local p = io.popen('taskkill /im lanmp_server.exe /f 2>nul')
  if p then p:close() end
  running = false
  M.refreshUI()
  log("I", "lanmp_host", "server stopped")
end

function M.isRunning() return running end

function M.refreshUI()
  guihooks.trigger("LanmpHostState", { running = running })
end

function M.onExtensionLoaded()
  M.refreshUI()
end

return M
