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

local CHANNEL = 6060
local STALE_AFTER_SECONDS = 8 -- no signal warning if nothing received this long
local REDRAW_SECONDS = 1

local INT32_MAX = 2147483647

local CONFIG = {
  warn_below_pct = 25, -- draw the bar red below this
  ok_below_pct = 75,   -- yellow between warn and ok, green above
}

-- ---------------------------------------------------------------------
-- Peripheral discovery -- fail loudly and clearly instead of guessing.
-- ---------------------------------------------------------------------

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

local monitor = requirePeripheral("monitor", "output display")
monitor.setTextScale(0.5)

print(("Listening on channel %d..."):format(CHANNEL))

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
  return string.format("%s%d FE", sign, n)
end

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

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" then
      if channel == CHANNEL and type(message) == "table"
        and type(message.energy) == "number" and type(message.maxEnergy) == "number" then
        previous = last
        last = message
        lastReceivedAt = os.epoch("utc")
        render()
      end
    elseif event == "timer" and sideOrTimerId == redrawTimer then
      render()
      redrawTimer = os.startTimer(REDRAW_SECONDS)
    elseif event == "peripheral_detach" then
      monitor.clear()
      monitor.setCursorPos(1, 1)
      monitor.setTextColor(colors.red)
      monitor.write("Peripheral disconnected")
    end
  end
end)

if not ok then
  print("Crashed: " .. tostring(err))
end
