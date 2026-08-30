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
--
-- Only problems get logged (read failures, crashes, guard warnings below)
-- -- not every routine transmit, which would just be noise once you've
-- confirmed sending works. Logs are printed AND appended to LOG_FILE, so
-- you can check what happened after the fact even without watching the
-- screen -- e.g. run `edit broadcast.log` in the shell.
--
-- GUARD: Advanced Peripherals has a known bug where getEnergy() clamps to
-- the 32-bit signed max (2147483647, ~2.15B) on cells/networks storing
-- more than that -- see IntelligenceModding/AdvancedPeripherals#642. A
-- clamped reading is silently WRONG (the real stored energy is higher
-- than what's reported), so detectAnomaly() below flags it -- and a few
-- other "this number doesn't make sense" cases -- instead of trusting
-- every number the peripheral hands back.

local CHANNEL = 6060
local ENDER_CELL_SIDE = "top"
local INTERVAL_SECONDS = 1
local LOG_FILE = "broadcast.log"
local LOG_MAX_LINES = 50
local INT32_MAX = 2147483647

-- Returns a short problem description, or nil if the reading looks sane.
local function detectAnomaly(energy, maxEnergy)
  if energy ~= energy then return "energy is NaN" end
  if maxEnergy ~= maxEnergy then return "maxEnergy is NaN" end
  if energy < 0 then return "energy is negative" end
  if maxEnergy < 0 then return "maxEnergy is negative" end
  if energy > maxEnergy then return "energy > maxEnergy" end
  if energy == INT32_MAX and maxEnergy > INT32_MAX then
    return "clamped at int32 max"
  end
  return nil
end

-- ---------------------------------------------------------------------
-- Logging: prints live and keeps a bounded on-disk history. Oldest
-- lines drop off past LOG_MAX_LINES so this can run forever without
-- slowly filling the computer's disk space.
-- ---------------------------------------------------------------------

local logLines = {}

local function log(fmt, ...)
  local line = ("[%s] " .. fmt):format(os.date("%H:%M:%S"), ...)
  print(line)
  table.insert(logLines, line)
  if #logLines > LOG_MAX_LINES then
    table.remove(logLines, 1)
  end
  local f = fs.open(LOG_FILE, "w")
  if f then
    f.write(table.concat(logLines, "\n"))
    f.close()
  end
end

-- ---------------------------------------------------------------------
-- Everything below runs inside one pcall so ANY failure -- a missing
-- peripheral included -- gets logged to file, not just flashed on a
-- screen nobody's watching after an unattended reboot.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
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

  local probeOk, probeEnergy, probeMax = pcall(function()
    return cell.getEnergy(), cell.getMaxEnergy()
  end)
  if not probeOk or type(probeEnergy) ~= "number" or type(probeMax) ~= "number" then
    error("ender_cell did not return usable numbers from getEnergy()/getMaxEnergy() -- got: " .. tostring(probeEnergy), 0)
  end

  log("READY cell=%d/%d FE, broadcasting on ch.%d every %ds", probeEnergy, probeMax, CHANNEL, INTERVAL_SECONDS)

  local startupAnomaly = detectAnomaly(probeEnergy, probeMax)
  if startupAnomaly then
    log("GUARD: %s (energy=%s, maxEnergy=%s)", startupAnomaly, tostring(probeEnergy), tostring(probeMax))
  end
  local lastAnomaly = startupAnomaly

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

      local anomaly = detectAnomaly(energy, maxEnergy)
      if anomaly ~= lastAnomaly then
        if anomaly then
          log("GUARD: %s (energy=%s, maxEnergy=%s)", anomaly, tostring(energy), tostring(maxEnergy))
        else
          log("GUARD: reading back to normal (energy=%s, maxEnergy=%s)", tostring(energy), tostring(maxEnergy))
        end
        lastAnomaly = anomaly
      end
    else
      log("READ FAILED: %s", tostring(energy))
    end

    os.sleep(INTERVAL_SECONDS)
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
