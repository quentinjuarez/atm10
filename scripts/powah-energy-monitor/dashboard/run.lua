-- powah-energy-monitor/dashboard/run.lua
--
-- Energy dashboard that RECEIVES readings broadcast by
-- ../broadcaster/run.lua over a modem, and renders stored energy,
-- capacity, fill %, and a live FE/s rate on a wrapped monitor -- plus,
-- when the broadcaster finds them, the Reactor's running state and the
-- Energy Detector's FE/t flow, which is the actual production/
-- consumption signal once the network sits pinned near 100% (see
-- ../README.md for why level alone can't show that).
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- This computer does NOT need to touch the Ender Cell itself -- only a
-- modem (to receive) and a monitor (to display). See this folder's
-- README.md for wiring and the decisions behind this design.
--
-- CHANNEL below must match CHANNEL in ../broadcaster/run.lua exactly.
--
-- Only problems get logged (guard warnings below, "no signal", crashes)
-- -- not every routine reception, which would just be noise once you've
-- confirmed receiving works. Logs are printed AND appended to LOG_FILE, so
-- you can check what happened after the fact even without watching the
-- screen -- e.g. run `edit dashboard.log` in the shell.
--
-- GUARD: Advanced Peripherals has a known bug where getEnergy() clamps to
-- the 32-bit signed max (2147483647, ~2.15B) on cells/networks storing
-- more than that -- see IntelligenceModding/AdvancedPeripherals#642. A
-- clamped reading is silently WRONG (the real stored energy is higher
-- than what's reported), so detectAnomaly() below flags it -- and a few
-- other "this number doesn't make sense" cases -- instead of trusting
-- every number the broadcaster hands back. When the guard is up, the
-- fill % is a floor (actual is at least that), and FE/s is hidden rather
-- than shown as a false "0 FE/s".

local CHANNEL = 6060
local STALE_AFTER_SECONDS = 5 -- no signal warning if nothing received this long
local REDRAW_SECONDS = 1
local LOG_FILE = "dashboard.log"
local LOG_MAX_LINES = 50

local INT32_MAX = 2147483647

local CONFIG = {
  warn_below_pct = 25, -- draw the bar red below this
  ok_below_pct = 75,   -- yellow between warn and ok, green above
}

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
-- Helpers
-- ---------------------------------------------------------------------

local function formatFE(n)
  local sign = n < 0 and "-" or ""
  n = math.abs(n)
  if n >= 1e12 then return string.format("%s%.2fT FE", sign, n / 1e12) end
  if n >= 1e9 then return string.format("%s%.2fB FE", sign, n / 1e9) end
  if n >= 1e6 then return string.format("%s%.2fM FE", sign, n / 1e6) end
  if n >= 1e3 then return string.format("%s%.2fK FE", sign, n / 1e3) end
  -- n can be a fractional rate (e.g. an FE/s division result); CC:Tweaked's
  -- Lua runtime errors on %d with a non-integral float, so round explicitly.
  return string.format("%s%d FE", sign, math.floor(n + 0.5))
end

local monitor -- assigned once peripheral discovery succeeds, below

local function barColor(pct)
  if not monitor.isColor or not monitor.isColor() then return nil end
  if pct < CONFIG.warn_below_pct then return colors.red end
  if pct < CONFIG.ok_below_pct then return colors.yellow end
  return colors.green
end

local function drawBar(x, y, width, pct, color)
  local filled = math.floor(width * math.min(math.max(pct, 0), 100) / 100)
  monitor.setCursorPos(x, y)
  if color then monitor.setBackgroundColor(color) end
  monitor.write(string.rep(" ", filled))
  if color then monitor.setBackgroundColor(colors.black) end
  monitor.write(string.rep(" ", width - filled))
end

-- ---------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------

local last = nil       -- most recent payload received {t, energy, maxEnergy}
local previous = nil    -- payload before that, for rate calc
local lastReceivedAt = nil -- os.epoch("utc") of last received message

-- Writes one line and advances past it -- used so optional fields
-- (reactor state, flow rate) can be present or absent without every
-- other line's row number needing to shift to compensate.
local function writeLine(row, text, color)
  monitor.setCursorPos(1, row)
  monitor.setTextColor(color or colors.white)
  monitor.write(text)
  return row + 1
end

local function render()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  if not last then
    writeLine(1, "POWAH Ender Cell")
    writeLine(3, ("Waiting for signal on ch. %d..."):format(CHANNEL), colors.gray)
    return
  end

  local energy, maxEnergy = last.energy, last.maxEnergy
  local anomaly = detectAnomaly(energy, maxEnergy)
  local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0

  -- Level-based rate: near-useless once the network sits pinned near
  -- 100% (a well-tuned reactor keeps it there on purpose), but harmless
  -- to keep as a secondary number. reactorRunning / flowFEt below are
  -- the actual production/consumption signal for that situation.
  local ratePerSec = nil
  local rateUnavailableReason = "warming up"
  if anomaly then
    rateUnavailableReason = "guard triggered"
  elseif previous and last.t > previous.t and not detectAnomaly(previous.energy, previous.maxEnergy) then
    ratePerSec = (last.energy - previous.energy) / ((last.t - previous.t) / 1000)
  end

  local row = 1
  row = writeLine(row, "POWAH Ender Cell")
  row = row + 1 -- blank

  row = writeLine(row, formatFE(energy) .. " / " .. formatFE(maxEnergy))
  row = writeLine(row, anomaly and string.format("%.1f%%+ (min)", pct) or string.format("%.1f%%", pct))
  row = row + 1 -- blank

  local w = select(1, monitor.getSize())
  drawBar(1, row, math.max(w - 2, 10), pct, barColor(pct))
  row = row + 2 -- bar row + blank

  if ratePerSec then
    row = writeLine(row, string.format("%s/s", formatFE(ratePerSec)), ratePerSec >= 0 and colors.lime or colors.orange)
  else
    row = writeLine(row, ("-- FE/s (%s)"):format(rateUnavailableReason), colors.gray)
  end

  if type(last.reactorRunning) == "boolean" then
    row = writeLine(row, last.reactorRunning and "Reactor: RUNNING" or "Reactor: IDLE",
      last.reactorRunning and colors.lime or colors.gray)
  end

  if type(last.flowFEt) == "number" then
    local flowColor = colors.gray
    if last.flowFEt > 0 then flowColor = colors.lime
    elseif last.flowFEt < 0 then flowColor = colors.orange end
    row = writeLine(row, formatFE(last.flowFEt) .. "/t", flowColor)
  end

  row = row + 1 -- blank before warnings

  if anomaly then
    row = writeLine(row, "GUARD: " .. anomaly, colors.red)
  end

  local staleSeconds = (os.epoch("utc") - lastReceivedAt) / 1000
  if staleSeconds > STALE_AFTER_SECONDS then
    row = writeLine(row, string.format("NO SIGNAL (%ds ago)", math.floor(staleSeconds)), colors.red)
  end
end

-- A single bad frame (e.g. an unexpected value from the broadcaster)
-- should never take down the whole listening loop -- log it and keep going.
local function safeRender()
  local renderOk, renderErr = pcall(render)
  if not renderOk then
    log("RENDER ERROR: %s", tostring(renderErr))
  end
end

-- ---------------------------------------------------------------------
-- Everything below runs inside one pcall so ANY failure -- a missing
-- peripheral included -- gets logged to file, not just flashed on a
-- screen nobody's watching after an unattended reboot.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local function requirePeripheral(kind, label)
    local p = peripheral.find(kind)
    if not p then
      error(("no '%s' peripheral found (%s) -- check it's placed next to this computer or on the same wired network"):format(kind, label), 0)
    end
    return p
  end

  local modem = requirePeripheral("modem", "receiver for the Ender Cell broadcast")
  if not modem.isOpen(CHANNEL) then
    modem.open(CHANNEL)
  end

  monitor = requirePeripheral("monitor", "output display")
  monitor.setTextScale(0.5)

  log("READY listening on ch.%d", CHANNEL)
  safeRender()

  local lastAnomaly = nil
  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" then
      if channel == CHANNEL and type(message) == "table"
        and type(message.energy) == "number" and type(message.maxEnergy) == "number" then
        previous = last
        last = message
        lastReceivedAt = os.epoch("utc")

        local anomaly = detectAnomaly(message.energy, message.maxEnergy)
        if anomaly ~= lastAnomaly then
          if anomaly then
            log("GUARD: %s (energy=%s, maxEnergy=%s)", anomaly, tostring(message.energy), tostring(message.maxEnergy))
          else
            log("GUARD: reading back to normal (energy=%s, maxEnergy=%s)", tostring(message.energy), tostring(message.maxEnergy))
          end
          lastAnomaly = anomaly
        end

        safeRender()
      end
    elseif event == "timer" and sideOrTimerId == redrawTimer then
      safeRender()
      redrawTimer = os.startTimer(REDRAW_SECONDS)
    elseif event == "peripheral_detach" then
      log("PERIPHERAL DETACHED")
      monitor.clear()
      monitor.setCursorPos(1, 1)
      monitor.setTextColor(colors.red)
      monitor.write("Peripheral disconnected")
    end
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
