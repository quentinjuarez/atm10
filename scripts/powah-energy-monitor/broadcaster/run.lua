-- powah-energy-monitor/broadcaster/run.lua
--
-- Reads a POWAH Ender Cell via a Block Reader (Advanced Peripherals)
-- facing it, and broadcasts the energy reading over a modem on a fixed
-- channel, for ../dashboard/run.lua to pick up elsewhere. Also broadcasts
-- FE/t flow from every Advanced Peripherals Energy Detector reachable on
-- the network -- see the note below on why the Ender Cell level alone
-- can't show consumption, and this folder's README.md for why Energy
-- Detectors (not a Powah-specific peripheral) are the extensible way to
-- add more energy sources later.
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
-- CHANNEL below must match CHANNEL in ../dashboard/run.lua exactly, or
-- the dashboard will never see a message.
--
-- Only problems get logged (read failures, crashes, guard warnings below)
-- -- not every routine transmit, which would just be noise once you've
-- confirmed sending works. Logs are printed AND appended to LOG_FILE, so
-- you can check what happened after the fact even without watching the
-- screen -- e.g. run `edit broadcast.log` in the shell.
--
-- GUARD: detectAnomaly() below still flags NaN / negative / energy >
-- maxEnergy / an int32-clamp signature, as defense in depth in case
-- Powah's NBT ever changes shape -- it should never trigger reading raw
-- NBT longs, but "should never" isn't "can't."
--
-- WHY THE ENDER CELL LEVEL CAN'T SHOW CONSUMPTION: a network sized for
-- 22B FE with a reactor that only turns on below 70% stays pinned at (or
-- extremely close to) 100% most of the time by design -- the level
-- barely moves even with real consumption happening, so FE/s computed
-- from level deltas is nearly always ~0. Flow, not level, is the right
-- signal.
--
-- WHY EVERY Energy Detector ON THE NETWORK, NOT A SPECIFIC GENERATOR
-- PERIPHERAL: getTransferRate() reads FE/t off a cable, which works
-- identically no matter which mod produced the power -- unlike Powah's
-- own Reactor peripheral (uraninite_reactor), which only exists for that
-- one block. Adding a second/third power source later (a different
-- generator, a different mod entirely) just means placing another Energy
-- Detector on ITS output cable -- no script change needed, it shows up
-- in the `sources` list automatically next broadcast.

local CHANNEL = 6060
local INTERVAL_SECONDS = 1
local LOG_FILE = "broadcast.log"
local LOG_MAX_LINES = 50
local INT32_MAX = 2147483647

-- Confirmed via ../debug-block-reader.lua against a powah:ender_cell_nitro.
local ENERGY_FIELD = "energy_stored_main_energy"
local CAPACITY_FIELD = "energy_capacity_main_energy"

-- Every Advanced Peripherals Energy Detector reachable on the network is
-- read automatically -- none are required for the Ender Cell reading
-- above to keep working, and there's no fixed count to configure.
local DETECTOR_TYPE = "energy_detector" -- "energyDetector" pre-1.21.1

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

  -- Finds every currently-attached Energy Detector by NAME (not just
  -- type), since there can be more than one -- one per energy source.
  -- Zero found is not an error, just an empty `sources` list broadcast.
  local function findDetectorNames()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == DETECTOR_TYPE then
        table.insert(names, name)
      end
    end
    table.sort(names) -- stable order broadcast to broadcast
    return names
  end

  local detectorNames = findDetectorNames()
  log("Energy Detectors (%s) found: %d (%s)", DETECTOR_TYPE, #detectorNames,
    #detectorNames > 0 and table.concat(detectorNames, ", ") or "none yet")

  -- Reads every detector's flow, skipping (not erroring on) one that
  -- fails or disappears mid-run -- re-lists names each cycle so a newly
  -- placed detector shows up without restarting this script.
  local function readSources()
    local names = findDetectorNames()
    local sources = {}
    local total = 0
    for _, name in ipairs(names) do
      local d = peripheral.wrap(name)
      local readOptOk, rate = pcall(d.getTransferRate)
      if readOptOk and type(rate) == "number" then
        table.insert(sources, { name = name, rateFEt = rate })
        total = total + rate
      end
    end
    return sources, total
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

  log("READY cell=%.0f/%.0f FE, broadcasting on ch.%d every %ds", probeEnergy, probeMax, CHANNEL, INTERVAL_SECONDS)

  local startupAnomaly = detectAnomaly(probeEnergy, probeMax)
  if startupAnomaly then
    log("GUARD: %s (energy=%s, maxEnergy=%s)", startupAnomaly, tostring(probeEnergy), tostring(probeMax))
  end
  local lastAnomaly = startupAnomaly
  local lastDetectorNames = table.concat(detectorNames, ",")
  local lastActive = nil -- nil = unknown yet, else true/false on total flow ~= 0

  while true do
    local readOk, energy, maxEnergy = pcall(readCell)

    if readOk then
      local sources, totalFlowFEt = readSources()

      local currentDetectorNames = {}
      for _, s in ipairs(sources) do table.insert(currentDetectorNames, s.name) end
      local joined = table.concat(currentDetectorNames, ",")
      if joined ~= lastDetectorNames then
        log("Energy Detectors changed: now %d (%s)", #sources, joined ~= "" and joined or "none")
        lastDetectorNames = joined
      end

      local active = totalFlowFEt ~= 0
      if active ~= lastActive then
        log("Total flow: %s (%.0f FE/t)", active and "ACTIVE" or "IDLE", totalFlowFEt)
        lastActive = active
      end

      modem.transmit(CHANNEL, CHANNEL, {
        t = os.epoch("utc"),
        energy = energy,
        maxEnergy = maxEnergy,
        sources = sources,
        totalFlowFEt = totalFlowFEt,
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
