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
-- WHY SAMPLE EVERY TICK INSTEAD OF ONCE PER BROADCAST: getTransferRate()
-- returns the INSTANTANEOUS flow at the exact tick it's called, not an
-- average -- calling it once per second (once every ~20 ticks) means
-- catching whatever that one arbitrary tick happened to be. If Powah
-- pushes energy in bursts rather than a perfectly smooth stream, a
-- single-tick sample can land on a near-zero gap or a brief spike,
-- nowhere near the true sustained rate (this is what "reads 0, then
-- 700, but real production is 50k" looked like). Sampling every tick and
-- broadcasting the 1-second AVERAGE smooths that out. See this folder's
-- README.md ADR for the reasoning and a performance note.
--
-- WIRING: place an Advanced Peripherals Energy Detector inline on each
-- energy source's output cable (the cable passes THROUGH the detector
-- block), reachable from this computer directly or over a wired network.
-- Plus a modem (Wireless or Ender) on any free side to broadcast with.
--
-- CHANNEL below must match FLOW_CHANNEL in ../dashboard/run.lua exactly.
-- Each broadcast type has its own channel now (see this folder's README
-- ADR) -- ../ender-cell-broadcaster/run.lua uses a different one.
--
-- Only problems get logged (crashes, source-list/flow-state changes) --
-- not every routine transmit. Logs are printed AND appended to LOG_FILE,
-- so you can check what happened after the fact even without watching
-- the screen -- e.g. run `edit energy-detector-broadcast.log` in the shell.
--
-- RESILIENCE: each sample tick and each broadcast tick runs inside its
-- OWN pcall, not just the one wrapping the whole script. One outer pcall
-- alone means any single failed peripheral call anywhere in the loop
-- (a detector's block breaking, a wired network flickering, the modem
-- itself detaching for an instant) kills the script permanently -- it
-- looks like "worked once, then silence" from the dashboard, with
-- nothing left running to even log why. Per-tick pcalls turn that into
-- a logged, recoverable hiccup instead: this tick fails, the next one
-- still runs.

local CHANNEL = 6702
local KIND = "energy_flow"
local SAMPLE_INTERVAL_SECONDS = 0.05 -- ~1 game tick, CC:Tweaked's own timer resolution
local BROADCAST_INTERVAL_SECONDS = 1
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

  -- Re-wraps the detector set. Called once per BROADCAST cycle (1/s),
  -- not once per sample (20/s) -- peripheral.getNames() walks the whole
  -- network's peripheral list, which is worth doing once a second, not
  -- every tick. Already-known detectors keep their wrapped reference
  -- instead of re-wrapping for no reason.
  local knownDetectors = {} -- [name] = wrapped peripheral
  local function refreshDetectors()
    local names = findDetectorNames()
    local refreshed = {}
    for _, name in ipairs(names) do
      if knownDetectors[name] then
        refreshed[name] = knownDetectors[name]
      else
        -- peripheral.wrap() can fail for a name that just disappeared
        -- (block broken between getNames() and here) -- skip it this
        -- cycle rather than letting that kill the whole broadcaster;
        -- it'll just be retried on the next refresh.
        local wrapOk, wrapped = pcall(peripheral.wrap, name)
        if wrapOk and wrapped then
          refreshed[name] = wrapped
        end
      end
    end
    knownDetectors = refreshed
    return names
  end

  local detectorNames = refreshDetectors()
  log("Energy Detectors (%s) found: %d (%s)", DETECTOR_TYPE, #detectorNames,
    #detectorNames > 0 and table.concat(detectorNames, ", ") or "none yet")
  log("READY broadcasting kind=%s on ch.%d, sampling every tick, averaging over %ds",
    KIND, CHANNEL, BROADCAST_INTERVAL_SECONDS)

  local lastDetectorNames = table.concat(detectorNames, ",")
  local lastActive = nil -- nil = unknown yet, else true/false on total flow ~= 0

  -- Per-detector running sum/count for the current broadcast window.
  local sampleSum, sampleCount = {}, {}

  local sampleTimer = os.startTimer(SAMPLE_INTERVAL_SECONDS)
  local broadcastTimer = os.startTimer(BROADCAST_INTERVAL_SECONDS)

  while true do
    local event, id = os.pullEvent("timer")

    if id == sampleTimer then
      -- Own pcall: a bad read on one detector shouldn't take the timer
      -- (and every future sample/broadcast) down with it.
      local sampleOk, sampleErr = pcall(function()
        for name, d in pairs(knownDetectors) do
          local readOk, rate = pcall(d.getTransferRate)
          if readOk and type(rate) == "number" then
            sampleSum[name] = (sampleSum[name] or 0) + rate
            sampleCount[name] = (sampleCount[name] or 0) + 1
          end
        end
      end)
      if not sampleOk then
        log("SAMPLE ERROR: %s", tostring(sampleErr))
      end
      sampleTimer = os.startTimer(SAMPLE_INTERVAL_SECONDS)

    elseif id == broadcastTimer then
      -- Own pcall, and the timer restart + accumulator reset below
      -- happen unconditionally (outside it) -- a failed broadcast this
      -- second still leaves the loop in a clean state to try again next
      -- second, instead of getting stuck.
      local broadcastOk, broadcastErr = pcall(function()
        local names = refreshDetectors()

        local joined = table.concat(names, ",")
        if joined ~= lastDetectorNames then
          log("Energy Detectors changed: now %d (%s)", #names, joined ~= "" and joined or "none")
          lastDetectorNames = joined
        end

        local sources, totalFlowFEt = {}, 0
        for _, name in ipairs(names) do
          local count = sampleCount[name] or 0
          -- A detector with zero ticks sampled this window (just placed,
          -- or every read failed) reports 0 rather than being omitted,
          -- so it still shows up in `sources`.
          local avg = count > 0 and (sampleSum[name] / count) or 0
          table.insert(sources, { name = name, rateFEt = avg })
          totalFlowFEt = totalFlowFEt + avg
        end

        local active = totalFlowFEt ~= 0
        if active ~= lastActive then
          log("Total flow: %s (%.0f FE/t avg)", active and "ACTIVE" or "IDLE", totalFlowFEt)
          lastActive = active
        end

        modem.transmit(CHANNEL, CHANNEL, {
          kind = KIND,
          t = os.epoch("utc"),
          sources = sources,
          totalFlowFEt = totalFlowFEt,
        })
      end)
      if not broadcastOk then
        log("BROADCAST ERROR: %s", tostring(broadcastErr))
      end

      sampleSum, sampleCount = {}, {}
      broadcastTimer = os.startTimer(BROADCAST_INTERVAL_SECONDS)
    end
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
