-- ender-cell-broadcaster.lua
--
-- Reads a POWAH Ender Cell placed directly ABOVE this computer and
-- broadcasts its energy reading over a modem on a fixed channel, for
-- powah-ender-cell-dashboard.lua to pick up and display elsewhere.
--
-- WIRING (see README "Wiring" section for the full picture):
--   - Ender Cell: directly on top of this computer -> peripheral side "top"
--   - Modem: any other free side of this computer -- Wireless Modem if the
--     dashboard is in the same base/render distance, Ender Modem if it's
--     far away or in another dimension (unlimited range, no cable needed
--     either way: wireless/ender modems talk over the air, not cable)
--
-- CHANNEL below must match CHANNEL in powah-ender-cell-dashboard.lua
-- exactly, or the dashboard will never see a message.

local CHANNEL = 6060
local ENDER_CELL_SIDE = "top"
local INTERVAL_SECONDS = 2

-- ---------------------------------------------------------------------
-- Peripheral checks -- fail loudly before the loop starts, per block.
-- ---------------------------------------------------------------------

local cell = peripheral.wrap(ENDER_CELL_SIDE)
if not cell then
  error(("no peripheral on side '%s' -- is the Ender Cell placed there?"):format(ENDER_CELL_SIDE), 0)
end

local cellType = peripheral.getType(ENDER_CELL_SIDE)
if cellType ~= "ender_cell" then
  error(("peripheral on '%s' is a '%s', not an 'ender_cell' -- check placement, and that Advanced Peripherals is installed"):format(ENDER_CELL_SIDE, tostring(cellType)), 0)
end

if type(cell.getEnergy) ~= "function" or type(cell.getMaxEnergy) ~= "function" then
  error("ender_cell peripheral is missing getEnergy()/getMaxEnergy() -- wrong Advanced Peripherals version?", 0)
end

local modem = peripheral.find("modem")
if not modem then
  error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
end

local okProbe, probeEnergy, probeMax = pcall(function()
  return cell.getEnergy(), cell.getMaxEnergy()
end)
if not okProbe or type(probeEnergy) ~= "number" or type(probeMax) ~= "number" then
  error("ender_cell did not return usable numbers from getEnergy()/getMaxEnergy() -- got: " .. tostring(probeEnergy), 0)
end

print(("OK -- cell reports %d / %d FE"):format(probeEnergy, probeMax))
print(("Broadcasting on channel %d every %ds..."):format(CHANNEL, INTERVAL_SECONDS))

-- ---------------------------------------------------------------------
-- Broadcast loop
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  while true do
    local readOk, energy, maxEnergy = pcall(function()
      return cell.getEnergy(), cell.getMaxEnergy()
    end)

    if readOk then
      modem.transmit(CHANNEL, CHANNEL, {
        t = os.epoch("utc"),
        energy = energy,
        maxEnergy = maxEnergy,
      })
    else
      print("Read failed, skipping this cycle: " .. tostring(energy))
    end

    os.sleep(INTERVAL_SECONDS)
  end
end)

if not ok then
  print("Crashed: " .. tostring(err))
end
