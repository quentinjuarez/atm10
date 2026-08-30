-- powah-energy-monitor/ender-cell-broadcaster/run.lua
--
-- Reads a POWAH Ender Cell via a Block Reader (Advanced Peripherals)
-- facing it, and broadcasts the stored/capacity energy over a modem on a
-- fixed channel, for ../dashboard/run.lua to pick up elsewhere. Storage
-- level only -- flow/production is a separate broadcast type, see
-- ../energy-detector-broadcaster/run.lua and this folder's README.md for
-- why they're two independent scripts instead of one.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- WHY BLOCK READER, NOT ender_cell.getEnergy(): Advanced Peripherals'
-- dedicated ender_cell peripheral clamps getEnergy() to the 32-bit
-- signed max (2147483647, ~2.15B) on cells/networks storing more than
-- that -- see IntelligenceModding/AdvancedPeripherals#642. Block Reader
-- instead returns the tile entity's raw NBT, which isn't limited to a
-- 32-bit int, so it reports the true value. Confirmed in-world via
-- ../debug-block-reader.lua on a powah:ender_cell_nitro -- the two fields
-- read below (ENERGY_FIELD / CAPACITY_FIELD) are exactly what it dumped,
-- not a guess. If a future Powah/AP update renames them, re-run
-- ../debug-block-reader.lua and update the two constants below. Full
-- decision record in this folder's README.md.
--
-- WIRING (see this folder's README.md for the full picture):
--   - Block Reader: placed FACING the Ender Cell (reads whatever block
--     is directly in front of it, not its own block) -- same physical
--     placement that worked for ../debug-block-reader.lua.
--   - Modem: any free side of this computer -- Wireless Modem if the
--     dashboard is in the same base/render distance, Ender Modem if it's
--     far away or in another dimension (unlimited range, no cable needed
--     either way: wireless/ender modems talk over the air, not cable)
--
-- CHANNEL below must match CELL_CHANNEL in ../dashboard/run.lua exactly.
-- Each broadcast type has its own channel now (see this folder's README
-- ADR) -- ../energy-detector-broadcaster/run.lua uses a different one.
--
-- Only problems get logged (read failures, crashes, guard warnings below)
-- -- not every routine transmit, which would just be noise once you've
-- confirmed sending works. Logs are printed AND appended to LOG_FILE, so
-- you can check what happened after the fact even without watching the
-- screen -- e.g. run `edit ender-cell-broadcast.log` in the shell.
--
-- GUARD: detectAnomaly() below still flags NaN / negative / energy >
-- maxEnergy / an int32-clamp signature, as defense in depth in case
-- Powah's NBT ever changes shape -- it should never trigger reading raw
-- NBT longs, but "should never" isn't "can't."

local CHANNEL = 6701
local KIND = "ender_cell"
local INTERVAL_SECONDS = 1
local LOG_FILE = "ender-cell-broadcast.log"
local LOG_MAX_LINES = 50
local INT32_MAX = 2147483647

-- Confirmed via ../debug-block-reader.lua against a powah:ender_cell_nitro.
local ENERGY_FIELD = "energy_stored_main_energy"
local CAPACITY_FIELD = "energy_capacity_main_energy"

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
  local reader = peripheral.find("block_reader")
  if not reader then
    error("no 'block_reader' peripheral found -- attach a Block Reader (Advanced Peripherals) facing the Ender Cell", 0)
  end

  if type(reader.getBlockData) ~= "function" then
    error("block_reader peripheral is missing getBlockData() -- wrong Advanced Peripherals version?", 0)
  end

  local modem = peripheral.find("modem")
  if not modem then
    error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
  end

  -- Reads the two fields, with clear errors for every way this can go
  -- wrong: reader facing nothing, facing the wrong block, or Powah
  -- having renamed its NBT fields since ../debug-block-reader.lua ran.
  local function readCell()
    local data = reader.getBlockData()
    if not data then
      error("getBlockData() returned nil -- is the Block Reader actually facing the Ender Cell?", 0)
    end
    local energy, maxEnergy = data[ENERGY_FIELD], data[CAPACITY_FIELD]
    if type(energy) ~= "number" or type(maxEnergy) ~= "number" then
      error(("NBT is missing '%s'/'%s' as numbers -- Powah's schema may have changed, re-run ../debug-block-reader.lua"):format(ENERGY_FIELD, CAPACITY_FIELD), 0)
    end
    return energy, maxEnergy
  end

  local probeOk, probeEnergy, probeMax = pcall(readCell)
  if not probeOk then
    error(tostring(probeEnergy), 0)
  end

  log("READY cell=%.0f/%.0f FE, broadcasting kind=%s on ch.%d every %ds", probeEnergy, probeMax, KIND, CHANNEL, INTERVAL_SECONDS)

  local startupAnomaly = detectAnomaly(probeEnergy, probeMax)
  if startupAnomaly then
    log("GUARD: %s (energy=%s, maxEnergy=%s)", startupAnomaly, tostring(probeEnergy), tostring(probeMax))
  end
  local lastAnomaly = startupAnomaly

  while true do
    local readOk, energy, maxEnergy = pcall(readCell)

    if readOk then
      -- Own pcall: modem.transmit() can fail too (modem detached for an
      -- instant, e.g.) -- without this, that single failure would kill
      -- the whole broadcaster permanently instead of just skipping a
      -- cycle. See ../README.md's "every timed cycle wrapped in its own
      -- pcall" ADR.
      local cycleOk, cycleErr = pcall(function()
        modem.transmit(CHANNEL, CHANNEL, {
          kind = KIND,
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
      end)
      if not cycleOk then
        log("CYCLE ERROR: %s", tostring(cycleErr))
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
