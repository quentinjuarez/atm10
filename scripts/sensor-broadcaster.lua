-- sensor-broadcaster.lua
-- Template: reads a peripheral on a fixed interval and broadcasts the
-- reading over rednet. Pair with monitor-dashboard.lua.
--
-- TEMPLATE — customize before use:
--   - `peripheral.wrap("right")` side/name must match your setup
--   - swap source.getEnergy()/getEnergyCapacity() for whatever API your
--     target peripheral actually exposes (generic energy peripheral, AE2
--     ME Bridge, Advanced Peripherals detector, etc.) — verify with
--     peripheral.getMethods(name) in-world first.

local modem = peripheral.find("modem")
local source = peripheral.wrap("right") -- energy cell, ME Bridge, detector...
rednet.open(peripheral.getName(modem))

local PROTOCOL = "atm10-sensor"

while true do
  local payload = {
    t = os.epoch("utc"), -- real wall-clock time, not os.clock()
    stored = source.getEnergy(),
    capacity = source.getEnergyCapacity(),
  }
  rednet.broadcast(payload, PROTOCOL)
  os.sleep(5)
end
