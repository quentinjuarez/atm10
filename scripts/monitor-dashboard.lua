-- monitor-dashboard.lua
-- Template: listens for broadcasts from sensor-broadcaster.lua and renders
-- them on a wrapped monitor.
--
-- TEMPLATE — customize before use:
--   - `peripheral.wrap("top")` side/name must match your setup
--   - protocol string must match the broadcaster
--   - swap the rendering for pixelbox_lite if you want higher resolution
--     (see the CC: Tweaked Field Guide, "Pixelbox Lite" section)

local monitor = peripheral.wrap("top")
local modem = peripheral.find("modem")
rednet.open(peripheral.getName(modem))
monitor.setTextScale(0.5)

local PROTOCOL = "atm10-sensor"

while true do
  local id, payload = rednet.receive(PROTOCOL)
  monitor.clear()
  monitor.setCursorPos(1, 1)
  local pct = math.floor(payload.stored / payload.capacity * 100)
  monitor.write(string.format("Energy: %d%% (%d / %d FE)", pct, payload.stored, payload.capacity))
end
