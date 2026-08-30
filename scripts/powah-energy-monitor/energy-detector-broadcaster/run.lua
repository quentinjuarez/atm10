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
-- WIRING: place an Advanced Peripherals Energy Detector inline on each
-- energy source's output cable (the cable passes THROUGH the detector
-- block), reachable from this computer directly or over a wired network.
-- Plus a modem (Wireless or Ender) on any free side to broadcast with.
--
-- CHANNEL below must match CHANNEL in ../dashboard/run.lua and
-- ../ender-cell-broadcaster/run.lua exactly. Both broadcast types share
-- one channel; the dashboard tells them apart by payload `kind`.
--
-- Only problems get logged (crashes, source-list/flow-state changes) --
-- not every routine transmit. Logs are printed AND appended to LOG_FILE,
-- so you can check what happened after the fact even without watching
-- the screen -- e.g. run `edit energy-detector-broadcast.log` in the shell.

local CHANNEL = 6060
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
      local readOk, rate = pcall(d.getTransferRate)
      if readOk and type(rate) == "number" then
        table.insert(sources, { name = name, rateFEt = rate })
        total = total + rate
      end
    end
    return sources, total
  end

  log("READY broadcasting kind=%s on ch.%d every %ds", KIND, CHANNEL, INTERVAL_SECONDS)

  local lastDetectorNames = table.concat(detectorNames, ",")
  local lastActive = nil -- nil = unknown yet, else true/false on total flow ~= 0

  while true do
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
      kind = KIND,
      t = os.epoch("utc"),
      sources = sources,
      totalFlowFEt = totalFlowFEt,
    })

    os.sleep(INTERVAL_SECONDS)
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
