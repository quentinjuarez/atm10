-- powah-energy-monitor/energy-detector-broadcaster/run.lua
--
-- Broadcasts FE/t flow from every Advanced Peripherals Energy Detector
-- reachable on this computer's network, over a modem on a fixed channel,
-- for ../dashboard/run.lua to pick up elsewhere. Flow/production only --
-- storage level is a separate broadcast type, see
-- ../ender-cell-broadcaster/run.lua and this folder's README.md for why
-- they're two independent scripts instead of one.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- WHY EVERY Energy Detector ON THE NETWORK, NOT A SPECIFIC GENERATOR
-- PERIPHERAL: getTransferRate() reads FE/t off a cable, which works
-- identically no matter which mod produced the power -- unlike a
-- mod-specific peripheral (e.g. Powah's own Reactor), which only exists
-- for that one block. Adding a second/third power source later -- a
-- different generator, a different mod entirely -- just means placing
-- another Energy Detector on ITS output cable: no script change, it
-- shows up in the `sources` list automatically next broadcast. This
-- computer doesn't need a Block Reader or an Ender Cell at all -- it
-- only needs Energy Detectors somewhere on its network.
--
-- READS ONCE PER SECOND, NO AVERAGING: an earlier version sampled every
-- tick and broadcast a 1s average, suspecting Powah delivers energy in
-- bursts that a single-tick sample could miss. The actual cause of the
-- bad readings was wiring (a Wired Modem where a Wireless/Ender Modem
-- was needed -- transmit() never errors, it just never leaves the local
-- wired network), not sampling -- so the extra timer and per-detector
-- accumulator were solving the wrong problem. Reverted to one read, one
-- send, once a second -- same structure as ../ender-cell-broadcaster/run.lua.
-- Full history in this folder's README.md ADR.
--
-- WIRING: place an Advanced Peripherals Energy Detector inline on each
-- energy source's output cable (the cable passes THROUGH the detector
-- block), reachable from this computer directly or over a wired network.
-- Plus a WIRELESS or ENDER modem (not Wired -- see the note above) on
-- any free side to broadcast with. Check with `peripheral.find("modem"
-- ).isWireless()` from the `lua` console if unsure which one is attached.
--
-- CHANNEL below must match FLOW_CHANNEL in ../dashboard/run.lua exactly.
-- Each broadcast type has its own channel (see this folder's README
-- ADR) -- ../ender-cell-broadcaster/run.lua uses a different one.
--
-- Only problems get logged (crashes, source-list/flow-state changes) --
-- not every routine transmit. Logs are printed AND appended to LOG_FILE,
-- so you can check what happened after the fact even without watching
-- the screen -- e.g. run `edit energy-detector-broadcast.log` in the shell.
--
-- RESILIENCE: each broadcast cycle runs inside its own pcall, not just
-- the one wrapping the whole script -- see ../README.md's "every timed
-- cycle wrapped in its own pcall" ADR for why that matters.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-08-31.1"

local CHANNEL = 6702
local KIND = "energy_flow"
local INTERVAL_SECONDS = 1
local LOG_FILE = "energy-detector-broadcast.log"
local LOG_MAX_LINES = 50
local DETECTOR_TYPE = "energy_detector" -- "energyDetector" pre-1.21.1

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
-- Everything below runs inside one pcall so ANY failure gets logged to
-- file, not just flashed on a screen nobody's watching after an
-- unattended reboot.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local modem = peripheral.find("modem")
  if not modem then
    error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
  end
  if modem.isWireless and not modem.isWireless() then
    error("the attached modem is a Wired Modem -- broadcasts need a Wireless or Ender Modem to reach the dashboard", 0)
  end

  -- Finds every currently-attached Energy Detector and reads its flow in
  -- one pass. Re-scans peripheral.getNames() every call (once a second,
  -- not once a tick) so a newly placed or removed detector is picked up
  -- automatically -- at this frequency there's no need to cache wrapped
  -- peripherals across calls, so this doesn't.
  local function readSources()
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == DETECTOR_TYPE then
        table.insert(names, name)
      end
    end
    table.sort(names) -- stable order broadcast to broadcast

    local sources, total = {}, 0
    for _, name in ipairs(names) do
      local wrapOk, d = pcall(peripheral.wrap, name)
      if wrapOk and d then
        local readOk, rate = pcall(d.getTransferRate)
        if readOk and type(rate) == "number" then
          table.insert(sources, { name = name, rateFEt = rate })
          total = total + rate
        end
      end
    end
    return sources, total
  end

  local startupSources = readSources()
  log("READY v%s -- broadcasting kind=%s on ch.%d every %ds, %d Energy Detector(s) found",
    SCRIPT_VERSION, KIND, CHANNEL, INTERVAL_SECONDS, #startupSources)

  local function namesOf(sources)
    local names = {}
    for _, s in ipairs(sources) do table.insert(names, s.name) end
    return table.concat(names, ",")
  end

  -- Seeded from the startup read so the READY line above isn't
  -- immediately followed by a redundant "Energy Detectors changed" on
  -- the very first cycle.
  local lastDetectorNames = namesOf(startupSources)
  local lastActive = nil -- nil = unknown yet, else true/false on total flow ~= 0

  while true do
    -- Own pcall: a single failed peripheral call here (a detector's
    -- block breaking, the modem detaching for an instant) shouldn't end
    -- the whole script -- see ../README.md's matching ADR.
    local cycleOk, cycleErr = pcall(function()
      local sources, totalFlowFEt = readSources()

      local joined = namesOf(sources)
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
        kind = KIND,
        t = os.epoch("utc"),
        sources = sources,
        totalFlowFEt = totalFlowFEt,
      })
    end)
    if not cycleOk then
      log("CYCLE ERROR: %s", tostring(cycleErr))
    end

    os.sleep(INTERVAL_SECONDS)
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
