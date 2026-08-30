-- powah-ender-cell-dashboard.lua
--
-- Energy dashboard for a POWAH Ender Cell (Nitro tier or any other), read
-- through Advanced Peripherals' dedicated "ender_cell" peripheral type.
-- Renders stored energy, capacity, fill %, and a live FE/s rate on a
-- wrapped monitor.
--
-- REQUIRES: Powah + Advanced Peripherals (both confirmed in ATM10), the
-- Ender Cell reachable as a peripheral (adjacent to the computer, or on
-- the same wired modem network), and a monitor peripheral.
--
-- Peripheral API (docs.advanced-peripherals.de, integrations/powah/ender_cell):
--   getName()        -> string
--   getEnergy()       -> number   stored FE
--   getMaxEnergy()    -> number   capacity FE
--   getChannel()      -> number   current ender channel
--   getMaxChannels()  -> number
--   setChannel(n)     -> nil
--
-- KNOWN CAVEAT: older Advanced Peripherals builds clamp getEnergy() to the
-- 32-bit signed max (2147483647) for cells storing more than that -- fixed
-- in AP's dev builds per IntelligenceModding/AdvancedPeripherals#642, but
-- your ATM10 build's exact AP version isn't something this script can see.
-- A Nitro Ender Cell alone (2B FE cap) stays under that limit, but multiple
-- cells sharing one ender channel can push the *network* total over it --
-- this script flags a suspicious reading instead of silently trusting it.

local CONFIG = {
  refresh_seconds = 2,
  warn_below_pct = 25,   -- draw the bar red below this
  ok_below_pct = 75,     -- yellow between warn and ok, green above
}

local INT32_MAX = 2147483647

-- ---------------------------------------------------------------------
-- Peripheral discovery -- fail loudly and clearly instead of guessing.
-- ---------------------------------------------------------------------

local function requirePeripheral(kind, label)
  local p = peripheral.find(kind)
  if not p then
    error(("no '%s' peripheral found (%s) -- check the block is placed next to this computer or on the same wired network"):format(kind, label), 0)
  end
  return p
end

local function assertMethods(p, methods, label)
  for _, name in ipairs(methods) do
    if type(p[name]) ~= "function" then
      error(("'%s' peripheral is missing method '%s' -- wrong mod version? (%s)"):format(label, name, label), 0)
    end
  end
end

print("Looking for peripherals...")
local cell = requirePeripheral("ender_cell", "POWAH Ender Cell, via Advanced Peripherals")
assertMethods(cell, { "getEnergy", "getMaxEnergy" }, "ender_cell")

local monitor = requirePeripheral("monitor", "output display")
monitor.setTextScale(0.5)

-- Read once up front so a bad/empty cell fails before we ever draw anything.
local okProbe, probeEnergy, probeMax = pcall(function()
  return cell.getEnergy(), cell.getMaxEnergy()
end)
if not okProbe or type(probeEnergy) ~= "number" or type(probeMax) ~= "number" then
  error("ender_cell peripheral did not return usable numbers from getEnergy()/getMaxEnergy()", 0)
end
print(("OK -- cell reports %d / %d FE"):format(probeEnergy, probeMax))

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------

local function formatFE(n)
  if n >= 1e12 then return string.format("%.2fT FE", n / 1e12) end
  if n >= 1e9 then return string.format("%.2fB FE", n / 1e9) end
  if n >= 1e6 then return string.format("%.2fM FE", n / 1e6) end
  if n >= 1e3 then return string.format("%.2fK FE", n / 1e3) end
  return string.format("%d FE", n)
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
-- Main loop
-- ---------------------------------------------------------------------

local lastEnergy, lastTime = nil, nil

local function tick()
  local ok, energy, maxEnergy = pcall(function()
    return cell.getEnergy(), cell.getMaxEnergy()
  end)

  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  if not ok or type(energy) ~= "number" or type(maxEnergy) ~= "number" then
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.red)
    monitor.write("Ender Cell read failed: " .. tostring(energy))
    return
  end

  local suspiciouslyClamped = energy == INT32_MAX and maxEnergy > INT32_MAX

  local now = os.epoch("utc")
  local ratePerSec = nil
  if lastEnergy and lastTime and now > lastTime and not suspiciouslyClamped then
    ratePerSec = (energy - lastEnergy) / ((now - lastTime) / 1000)
  end
  lastEnergy, lastTime = energy, now

  local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0

  monitor.setTextColor(colors.white)
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
    monitor.write(string.format("%s%s FE/s", ratePerSec >= 0 and "+" or "", formatFE(ratePerSec)))
  else
    monitor.setTextColor(colors.gray)
    monitor.write("-- FE/s (warming up)")
  end

  if suspiciouslyClamped then
    monitor.setCursorPos(1, 10)
    monitor.setTextColor(colors.red)
    monitor.write("WARNING: reading may be clamped (AP #642)")
  end
end

local ok, err = pcall(function()
  local timer = os.startTimer(CONFIG.refresh_seconds)
  while true do
    local event, a = os.pullEvent()
    if event == "timer" and a == timer then
      tick()
      timer = os.startTimer(CONFIG.refresh_seconds)
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
