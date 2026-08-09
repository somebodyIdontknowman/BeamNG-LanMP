-- Loads the LANMP game engine extensions when the mod is mounted and keeps
-- them alive across level loads.

local extNames = {
  "lanmp_protocol",
  "lanmp_network",
  "lanmp_vehicles",
  "lanmp_nametags",
  "lanmp_session",
}

for _, name in ipairs(extNames) do
  local ok, err = pcall(extensions.load, name)
  if not ok then
    log("E", "lanmp", "failed to load " .. name .. ": " .. tostring(err))
  elseif setExtensionUnloadMode then
    setExtensionUnloadMode(name, "manual")
  end
end

log("I", "lanmp", "LANMP loaded - open the LANMP app from the UI apps menu to connect")
