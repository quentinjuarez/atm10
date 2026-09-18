-- powah-energy-monitor/induction-broadcaster/run.lua
--
-- Reads a Mekanism Induction Matrix directly through Mekanism's OWN
-- built-in ComputerCraft integration -- the "inductionPort" peripheral,
-- a real peripheral with real methods (getEnergy(), getLastInput(),
-- etc.), NOT Advanced Peripherals' Block Reader/NBT.
--
-- That NBT route was tried first and confirmed dead: ../debug-induction-
-- reader.lua's dump against a plain Induction Casing showed only
-- generic multiblock bookkeeping (redstone/inventory_id) -- no energy
-- data at all, because a Casing's own tile NBT never carries it; the
-- multiblock's live stats are queried on demand, not stored there. A
-- second debug run (../debug-mekanism-peripheral.lua) against that same
-- Casing found Mekanism DOES expose it as a native peripheral
-- ("mekanism:induction_casing") -- but only with generic item/fluid
-- methods (pullItems, tanks, ...), still no energy. The INDUCTION PORT
-- block specifically is the one that exposes energy methods -- method
-- names below confirmed against a working community reference script
-- (Wolfe's Mekanism Induction Matrix Monitor), not guessed. See this
-- folder's README.md ADR for the full trail.
--
-- Broadcasts ONE message (kind="induction_matrix") on CHANNEL -- a NEW
-- dedicated channel, not the CELL_CHANNEL/FLOW_CHANNEL pair
-- ../dashboard/ listens on, since this carries strictly more data than
-- that dashboard's two message shapes hold (percentage, transfer cap,
-- charge/discharge ETA). See ../induction-dashboard/ for the matching
-- receiver.
--
-- Don't wget this file directly to install it -- see install.lua in
-- this same folder, or the repo root README's "Installing a script
-- in-game".
--
-- WIRING: this computer must be placed directly adjacent to (or on the
-- same Wired Modem network as) the INDUCTION PORT block specifically --
-- not the Casing. This is a direct peripheral connection; no Block
-- Reader is used or needed here at all.
--
-- ENERGY UNITS: Mekanism's own methods return raw Joules, not FE. If
-- `mekanismEnergyHelper` (Mekanism's own CC:Tweaked conversion library)
-- is present as a global, its `joulesToFE()` is used -- the mod's own
-- conversion, not a guessed ratio. Falls back to dividing by
-- JOULES_PER_FE (2.5, Mekanism's published ratio) if that global isn't
-- available -- same defensive fallback the reference script itself uses.
--
-- RESILIENCE: each broadcast cycle runs inside its own pcall, not just
-- the one wrapping the whole script -- see ../README.md's "every timed
-- cycle wrapped in its own pcall" ADR for why that matters.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-09-18.2"

local CHANNEL = 6703 -- must match CHANNEL in ../induction-dashboard/run.lua
local INTERVAL_SECONDS = 1
local JOULES_PER_FE = 2.5 -- fallback only -- used when mekanismEnergyHelper isn't available
local LOG_FILE = "induction-broadcast.log"
local LOG_MAX_LINES = 50

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

-- Mekanism's own conversion helper, when available, beats a hardcoded
-- ratio -- see the ENERGY UNITS note above.
local usingHelper = _G.mekanismEnergyHelper ~= nil and _G.mekanismEnergyHelper.joulesToFE ~= nil
local function toFE(joules)
  if usingHelper then
    return _G.mekanismEnergyHelper.joulesToFE(joules)
  end
  return joules / JOULES_PER_FE
end

-- Returns a short problem description, or nil if the reading looks sane.
local function detectAnomaly(energy, maxEnergy)
  if energy ~= energy then return "energy is NaN" end
  if maxEnergy ~= maxEnergy then return "maxEnergy is NaN" end
  if energy < 0 then return "energy is negative" end
  if maxEnergy < 0 then return "maxEnergy is negative" end
  if energy > maxEnergy then return "energy > maxEnergy" end
  return nil
end

-- ---------------------------------------------------------------------
-- Everything below runs inside one pcall so ANY failure -- a missing
-- peripheral included -- gets logged to file, not just flashed on a
-- screen nobody's watching after an unattended reboot.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local port = peripheral.find("inductionPort")
  if not port then
    error("no 'inductionPort' peripheral found -- this computer must be placed directly adjacent to (or wired-networked to) the Induction PORT block specifically, not the Casing -- see this folder's README.md", 0)
  end

  local modem = peripheral.find("modem")
  if not modem then
    error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
  end
  if modem.isWireless and not modem.isWireless() then
    error("the attached modem is a Wired Modem -- broadcasts need a Wireless or Ender Modem to reach the dashboard", 0)
  end

  local function readMatrix()
    local energy = toFE(port.getEnergy())
    local maxEnergy = toFE(port.getMaxEnergy())
    local percentage = port.getEnergyFilledPercentage() -- 0..1, Mekanism's own computation
    local input = toFE(port.getLastInput())
    local output = toFE(port.getLastOutput())
    local transferCap = toFE(port.getTransferCap())
    return energy, maxEnergy, percentage, input, output, transferCap
  end

  local probeOk, probeEnergy, probeMax = pcall(readMatrix)
  if not probeOk then
    error(tostring(probeEnergy), 0)
  end

  log("READY v%s -- induction matrix=%.0f/%.0f FE (unit conversion via %s), broadcasting kind=induction_matrix on ch.%d every %ds",
    SCRIPT_VERSION, probeEnergy, probeMax, usingHelper and "mekanismEnergyHelper" or ("raw/" .. JOULES_PER_FE .. " fallback"), CHANNEL, INTERVAL_SECONDS)

  local startupAnomaly = detectAnomaly(probeEnergy, probeMax)
  if startupAnomaly then
    log("GUARD: %s (energy=%s, maxEnergy=%s)", startupAnomaly, tostring(probeEnergy), tostring(probeMax))
  end
  local lastAnomaly = startupAnomaly
  local lastActive = nil -- nil = unknown yet, else true/false on net flow ~= 0

  -- Tracks actual observed energy change between cycles (not just
  -- input-output) for changePerSecond/ETA -- see this folder's
  -- README.md's ADR for why that's measured rather than derived.
  local previousEnergy = probeEnergy
  local previousT = os.epoch("utc")

  while true do
    local readOk, energy, maxEnergy, percentage, input, output, transferCap = pcall(readMatrix)

    if readOk then
      -- Own pcall: modem.transmit() can fail too (modem detached for an
      -- instant, e.g.) -- without this, that single failure would kill
      -- the whole broadcaster permanently instead of just skipping a
      -- cycle. See ../README.md's "every timed cycle wrapped in its own
      -- pcall" ADR.
      local cycleOk, cycleErr = pcall(function()
        local now = os.epoch("utc")
        local elapsedSeconds = math.max((now - previousT) / 1000, 0.001)
        local changePerSecond = (energy - previousEnergy) / elapsedSeconds
        previousEnergy, previousT = energy, now

        local etaSeconds = nil
        if changePerSecond > 0 then
          etaSeconds = (maxEnergy - energy) / changePerSecond
        elseif changePerSecond < 0 then
          etaSeconds = energy / -changePerSecond
        end

        modem.transmit(CHANNEL, CHANNEL, {
          kind = "induction_matrix",
          t = now,
          energy = energy,
          maxEnergy = maxEnergy,
          percentage = percentage,
          input = input,
          output = output,
          netFlow = input - output,
          transferCap = transferCap,
          changePerSecond = changePerSecond,
          etaSeconds = etaSeconds,
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

        local active = (input - output) ~= 0
        if active ~= lastActive then
          log("Net flow: %s (in=%.0f out=%.0f net=%.0f FE/t)", active and "ACTIVE" or "IDLE", input, output, input - output)
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
