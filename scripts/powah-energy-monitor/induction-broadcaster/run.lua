-- powah-energy-monitor/induction-broadcaster/run.lua
--
-- Replaces BOTH ../ender-cell-broadcaster/ and
-- ../energy-detector-broadcaster/ with a SINGLE computer + Block Reader
-- facing a Mekanism Induction Matrix casing: the casing's own NBT
-- carries capacity, stored energy, AND live input/output FE/t all in
-- one place, so there's no more need for a separate Ender Cell + Energy
-- Detector setup. Broadcasts the EXACT SAME message shapes on the EXACT
-- SAME channels as the two scripts it replaces (kind="ender_cell" on
-- CELL_CHANNEL, kind="energy_flow" on FLOW_CHANNEL) -- ../dashboard/
-- run.lua needs ZERO changes to work with this. See this folder's
-- README.md ADR for the full reasoning and why the two old scripts are
-- kept in the repo, not deleted.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- FIELD NAMES ARE UNCONFIRMED. Unlike Powah's Ender Cell (confirmed via
-- ../debug-block-reader.lua before ../ender-cell-broadcaster/ was
-- written), Mekanism's exact Induction Matrix NBT schema hasn't been
-- dumped against a live block yet. CAPACITY_FIELDS/ENERGY_FIELDS/
-- INPUT_FIELDS/OUTPUT_FIELDS below each try a short list of plausible
-- names; the FIRST one present in the NBT wins. If NONE of a field's
-- candidates are present, this logs every top-level key the Block
-- Reader actually returned (and one level into any nested table, in
-- case Mekanism's FloatingLong energy type serializes as a compound
-- rather than a plain number) so the real names are visible straight
-- from the log -- run ../debug-induction-reader.lua first for the same
-- info without waiting for this script to fail.
--
-- UNIT CONVERSION: Mekanism stores energy internally in Joules, not FE
-- -- JOULES_PER_FE below (2.5, Mekanism's own published conversion
-- ratio) converts every raw NBT value to FE before broadcasting, so
-- ../dashboard/run.lua's FE-based formatting stays correct. If numbers
-- on the dashboard look exactly 2.5x too high, this ratio or which
-- fields actually need it is wrong -- check the raw values in the log
-- against what the block's own GUI shows.
--
-- WIRING:
--   - Block Reader (Advanced Peripherals) placed FACING the Induction
--     Casing -- reads whatever block is directly in front of it.
--   - A WIRELESS or ENDER modem (not Wired) on any other free side --
--     see ../energy-detector-broadcaster/README.md's troubleshooting
--     section for how a Wired Modem mistake was found last time.
--
-- RESILIENCE: each broadcast cycle runs inside its own pcall, not just
-- the one wrapping the whole script -- see ../README.md's "every timed
-- cycle wrapped in its own pcall" ADR for why that matters.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-09-18.1"

local CELL_CHANNEL = 6701 -- must match CELL_CHANNEL in ../dashboard/run.lua
local FLOW_CHANNEL = 6702 -- must match FLOW_CHANNEL in ../dashboard/run.lua
local INTERVAL_SECONDS = 1
local LOG_FILE = "induction-broadcast.log"
local LOG_MAX_LINES = 50
local INT32_MAX = 2147483647

-- Mekanism's Joules-to-FE ratio (Mekanism's own conversion constant --
-- FE = Joules / 2.5). Set to 1 if a debug dump shows the NBT is somehow
-- already in FE.
local JOULES_PER_FE = 2.5

-- First matching candidate wins -- see the FIELD NAMES note above for
-- why there's a list per value instead of one guessed name each.
local CAPACITY_FIELDS = { "maxEnergy", "energyCapacity", "capacity", "EnergyCapacity", "storageCap" }
local ENERGY_FIELDS = { "energy", "storedEnergy", "energyStored", "Energy" }
local INPUT_FIELDS = { "lastInput", "inputRate", "energyInput", "receiveRate", "lastReceived", "input" }
local OUTPUT_FIELDS = { "lastOutput", "outputRate", "energyOutput", "extractRate", "lastExtracted", "output" }

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

-- Dumps every top-level key (and one level into any nested table) to
-- the log -- only called when an expected field is missing, so this
-- never fires during routine operation, only when the FIELDS constants
-- above need fixing. Same diagnostic ../debug-induction-reader.lua
-- prints standalone, inlined here so a wrong guess is self-diagnosing
-- without needing to re-run a separate tool.
local function logAvailableFields(data)
  log("Available top-level NBT fields:")
  for k, v in pairs(data) do
    if type(v) == "table" then
      log("  %s (table):", tostring(k))
      for k2, v2 in pairs(v) do
        log("    %s (%s) = %s", tostring(k2), type(v2), tostring(v2))
      end
    else
      log("  %s (%s) = %s", tostring(k), type(v), tostring(v))
    end
  end
end

-- Returns the value of the first candidate name present in `data`, plus
-- which name matched (for logging), or nil if none were found.
local function findField(data, candidates)
  for _, name in ipairs(candidates) do
    if data[name] ~= nil then
      return data[name], name
    end
  end
  return nil, nil
end

-- Mekanism's FloatingLong energy type MIGHT serialize as a nested table
-- instead of a plain number (see the FIELD NAMES note above) -- this
-- only handles the plain-number case and errors clearly on anything
-- else, rather than silently misreading a table as a huge/garbage
-- number via tostring/tonumber coercion.
local function requireNumber(value, fieldName, matchedName)
  if type(value) == "number" then
    return value
  end
  error(("field '%s' (matched NBT key '%s') is a %s, not a number -- " ..
    "Mekanism's FloatingLong energy type may be serializing as a nested " ..
    "table here; check the log's field dump and adjust the code to read " ..
    "the right sub-field"):format(fieldName, tostring(matchedName), type(value)), 0)
end

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
-- Everything below runs inside one pcall so ANY failure -- a missing
-- peripheral included -- gets logged to file, not just flashed on a
-- screen nobody's watching after an unattended reboot.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local reader = peripheral.find("block_reader")
  if not reader then
    error("no 'block_reader' peripheral found -- attach a Block Reader (Advanced Peripherals) facing the Induction Casing", 0)
  end

  local modem = peripheral.find("modem")
  if not modem then
    error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
  end
  if modem.isWireless and not modem.isWireless() then
    error("the attached modem is a Wired Modem -- broadcasts need a Wireless or Ender Modem to reach the dashboard", 0)
  end

  -- Reads all four values in one pass, converts Joules -> FE, and
  -- raises a clear, specific error (which field, which candidates were
  -- tried) the moment something's missing -- instead of reading three
  -- fields fine and only failing confusingly on the fourth.
  local function readInduction()
    local data = reader.getBlockData()
    if not data then
      error("getBlockData() returned nil -- is the Block Reader actually facing the Induction Casing?", 0)
    end

    local rawCapacity, capacityName = findField(data, CAPACITY_FIELDS)
    local rawEnergy, energyName = findField(data, ENERGY_FIELDS)
    local rawInput, inputName = findField(data, INPUT_FIELDS)
    local rawOutput, outputName = findField(data, OUTPUT_FIELDS)

    if not (rawCapacity and rawEnergy and rawInput and rawOutput) then
      logAvailableFields(data)
      local missing = {}
      if not rawCapacity then table.insert(missing, "capacity (tried: " .. table.concat(CAPACITY_FIELDS, ", ") .. ")") end
      if not rawEnergy then table.insert(missing, "energy (tried: " .. table.concat(ENERGY_FIELDS, ", ") .. ")") end
      if not rawInput then table.insert(missing, "input rate (tried: " .. table.concat(INPUT_FIELDS, ", ") .. ")") end
      if not rawOutput then table.insert(missing, "output rate (tried: " .. table.concat(OUTPUT_FIELDS, ", ") .. ")") end
      error("none of the configured field names matched for: " .. table.concat(missing, "; ") ..
        " -- see the field dump just logged above and fix the *_FIELDS constants at the top of this file", 0)
    end

    local capacity = requireNumber(rawCapacity, "capacity", capacityName) / JOULES_PER_FE
    local energy = requireNumber(rawEnergy, "energy", energyName) / JOULES_PER_FE
    local input = requireNumber(rawInput, "input", inputName) / JOULES_PER_FE
    local output = requireNumber(rawOutput, "output", outputName) / JOULES_PER_FE

    return energy, capacity, input, output
  end

  local probeOk, probeEnergy, probeCapacity = pcall(readInduction)
  if not probeOk then
    error(tostring(probeEnergy), 0)
  end

  log("READY v%s -- induction matrix=%.0f/%.0f FE, broadcasting kind=ender_cell on ch.%d and kind=energy_flow on ch.%d every %ds",
    SCRIPT_VERSION, probeEnergy, probeCapacity, CELL_CHANNEL, FLOW_CHANNEL, INTERVAL_SECONDS)

  local startupAnomaly = detectAnomaly(probeEnergy, probeCapacity)
  if startupAnomaly then
    log("GUARD: %s (energy=%s, maxEnergy=%s)", startupAnomaly, tostring(probeEnergy), tostring(probeCapacity))
  end
  local lastAnomaly = startupAnomaly
  local lastActive = nil -- nil = unknown yet, else true/false on net flow ~= 0

  while true do
    local readOk, energy, capacity, input, output = pcall(readInduction)

    if readOk then
      -- Own pcall: modem.transmit() can fail too (modem detached for an
      -- instant, e.g.) -- without this, that single failure would kill
      -- the whole broadcaster permanently instead of just skipping a
      -- cycle. See ../README.md's "every timed cycle wrapped in its own
      -- pcall" ADR.
      local cycleOk, cycleErr = pcall(function()
        modem.transmit(CELL_CHANNEL, CELL_CHANNEL, {
          kind = "ender_cell",
          t = os.epoch("utc"),
          energy = energy,
          maxEnergy = capacity,
        })

        -- Net flow (input - output) is the single signed number
        -- ../dashboard/run.lua's graph/Total line expects; input and
        -- output are ALSO sent as two synthetic "sources" so the
        -- dashboard's existing per-source breakdown shows both
        -- directions separately, not just their difference -- no
        -- dashboard code change needed for either.
        local netFlow = input - output
        modem.transmit(FLOW_CHANNEL, FLOW_CHANNEL, {
          kind = "energy_flow",
          t = os.epoch("utc"),
          totalFlowFEt = netFlow,
          sources = {
            { name = "input", rateFEt = input },
            { name = "output", rateFEt = -output },
          },
        })

        local anomaly = detectAnomaly(energy, capacity)
        if anomaly ~= lastAnomaly then
          if anomaly then
            log("GUARD: %s (energy=%s, maxEnergy=%s)", anomaly, tostring(energy), tostring(capacity))
          else
            log("GUARD: reading back to normal (energy=%s, maxEnergy=%s)", tostring(energy), tostring(capacity))
          end
          lastAnomaly = anomaly
        end

        local active = netFlow ~= 0
        if active ~= lastActive then
          log("Net flow: %s (in=%.0f out=%.0f net=%.0f FE/t)", active and "ACTIVE" or "IDLE", input, output, netFlow)
          lastActive = active
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
