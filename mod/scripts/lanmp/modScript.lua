-- Loads the LANMP game engine extensions when the mod is mounted and keeps
-- them alive across level loads.

local extNames = {
  "lanmp_protocol",
  "lanmp_network",
  "lanmp_discovery",
  "lanmp_vehicles",
  "lanmp_nametags",
  "lanmp_session",
  "lanmp_host",
}

for _, name in ipairs(extNames) do
  local ok, err = pcall(extensions.load, name)
  if not ok then
    log("E", "lanmp", "failed to load " .. name .. ": " .. tostring(err))
  elseif setExtensionUnloadMode then
    setExtensionUnloadMode(name, "manual")
  end
end

log("I", "lanmp", "LANMP loaded - open Multiplayer from the main menu to host or join")
