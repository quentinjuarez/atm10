-- powah-ender-cell-dashboard.lua
--
-- Energy dashboard that RECEIVES readings broadcast by
-- ender-cell-broadcaster.lua over a modem, and renders stored energy,
-- capacity, fill %, and a live FE/s rate on a wrapped monitor.
--
-- This computer does NOT need to touch the Ender Cell itself -- only a
-- modem (to receive) and a monitor (to display). See README "Wiring".
--
-- CHANNEL below must match CHANNEL in ender-cell-broadcaster.lua exactly.
--
-- Every received reading (and any crash) is printed AND appended to
-- LOG_FILE, so you can check what happened after the fact even without
-- watching the screen -- e.g. run `edit dashboard.log` in the shell.

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

local function render()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setTextColor(colors.white)

  if not last then
    monitor.setCursorPos(1, 1)
    monitor.write("POWAH Ender Cell")
    monitor.setCursorPos(1, 3)
    monitor.setTextColor(colors.gray)
    monitor.write(("Waiting for signal on ch. %d..."):format(CHANNEL))
    return
  end

  local energy, maxEnergy = last.energy, last.maxEnergy
  local suspiciouslyClamped = energy == INT32_MAX and maxEnergy > INT32_MAX
  local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0

  local ratePerSec = nil
  if previous and last.t > previous.t and not suspiciouslyClamped then
    ratePerSec = (last.energy - previous.energy) / ((last.t - previous.t) / 1000)
  end

  monitor.setCursorPos(1, 1)
  monitor.write("POWAH Ender Cell")

  monitor.setCursorPos(1, 3)
  monitor.write(formatFE(energy) .. " / " .. formatFE(maxEnergy))

  monitor.setCursorPos(1, 4)
  monitor.write(string.format("%.1f%%", pct))

  local w = select(1, monitor.getSize())
  drawBar(1, 6, math.max(w - 2, 10), pct, barColor(pct))

  monitor.setCursorPos(1, 8)
  if ratePerSec then
    monitor.setTextColor(ratePerSec >= 0 and colors.lime or colors.orange)
    monitor.write(string.format("%s/s", formatFE(ratePerSec)))
  else
    monitor.setTextColor(colors.gray)
    monitor.write("-- FE/s (warming up)")
  end

  if suspiciouslyClamped then
    monitor.setCursorPos(1, 10)
    monitor.setTextColor(colors.red)
    monitor.write("WARNING: reading may be clamped (AP #642)")
  end

  local staleSeconds = (os.epoch("utc") - lastReceivedAt) / 1000
  if staleSeconds > STALE_AFTER_SECONDS then
    monitor.setCursorPos(1, suspiciouslyClamped and 12 or 10)
    monitor.setTextColor(colors.red)
    monitor.write(string.format("NO SIGNAL (%ds ago)", math.floor(staleSeconds)))
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

  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" then
      if channel == CHANNEL and type(message) == "table"
        and type(message.energy) == "number" and type(message.maxEnergy) == "number" then
        previous = last
        last = message
        lastReceivedAt = os.epoch("utc")
        local pct = message.maxEnergy > 0 and (message.energy / message.maxEnergy * 100) or 0
        log("RX %d/%d FE (%.1f%%)", message.energy, message.maxEnergy, pct)
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
