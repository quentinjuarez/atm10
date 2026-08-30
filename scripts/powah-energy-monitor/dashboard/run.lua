-- powah-energy-monitor/dashboard/run.lua
--
-- Energy dashboard that RECEIVES two independent broadcast types over one
-- modem channel and renders both on a monitor:
--   kind="ender_cell"   from ../ender-cell-broadcaster/run.lua -- stored
--                        energy, capacity, fill %, a level-based FE/s rate
--   kind="energy_flow"  from ../energy-detector-broadcaster/run.lua --
--                        total FE/t flow, a per-source breakdown, a
--                        rolling ~60s bar graph, and the current hour's
--                        min/max flow
--
-- These are two separate broadcaster computers/scripts (see this folder's
-- README.md and ../README.md for why), so each stream is tracked with
-- its own "last received" state and can go stale independently -- losing
-- one doesn't blank out the other.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- This computer does NOT need to touch the Ender Cell or any Energy
-- Detector itself -- only a modem (to receive) and a monitor (to
-- display). See this folder's README.md for wiring and the decisions
-- behind this design.
--
-- CHANNEL below must match CHANNEL in both broadcaster run.lua files
-- exactly.
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
-- every number the ender-cell-broadcaster hands back. When the guard is
-- up, the fill % is a floor (actual is at least that), and FE/s is
-- hidden rather than shown as a false "0 FE/s".

local CHANNEL = 6060
local STALE_AFTER_SECONDS = 5 -- no signal warning if nothing received this long
local REDRAW_SECONDS = 1
local LOG_FILE = "dashboard.log"
local LOG_MAX_LINES = 50
local FLOW_HISTORY_SECONDS = 60 -- rolling window for the graph
local TEXT_SCALE = 1 -- bigger/more readable than the default 0.5; trades width

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

-- Colors a flow number: lime producing, orange draining, gray idle/zero.
local function flowColor(rateFEt)
  if rateFEt > 0 then return colors.lime end
  if rateFEt < 0 then return colors.orange end
  return colors.gray
end

-- "energy_detector_0" -> "src 0" -- CC:Tweaked auto-assigns these names
-- (no confirmed way to give a detector a custom label), so shorten the
-- common case for a small monitor rather than showing the full name.
local function sourceLabel(name)
  local suffix = name:match("_(%d+)$")
  return suffix and ("src " .. suffix) or name
end

local monitor -- assigned once peripheral discovery succeeds, below

local function barColor(pct)
  if not monitor.isColor or not monitor.isColor() then return nil end
  if pct < CONFIG.warn_below_pct then return colors.red end
  if pct < CONFIG.ok_below_pct then return colors.yellow end
  return colors.green
end

local function drawBar(x, y, width, height, pct, color)
  local filled = math.floor(width * math.min(math.max(pct, 0), 100) / 100)
  for dy = 0, height - 1 do
    monitor.setCursorPos(x, y + dy)
    if color then monitor.setBackgroundColor(color) end
    monitor.write(string.rep(" ", filled))
    if color then monitor.setBackgroundColor(colors.black) end
    monitor.write(string.rep(" ", width - filled))
  end
  monitor.setBackgroundColor(colors.black)
end

-- Rolling bar-chart of `history` ({t=, value=}, oldest first), newest
-- sample at the rightmost column, scaled between minV/maxV. One column
-- per pixel of width; a flat (or not-yet-established) range just draws
-- every bar at half height rather than dividing by zero.
local function drawGraph(x, yTop, width, height, history, minV, maxV)
  local n = #history
  local range = maxV - minV
  for col = 0, width - 1 do
    local idx = n - width + 1 + col
    local barHeight = 0
    local color = colors.gray
    if idx >= 1 and idx <= n then
      local v = history[idx].value
      color = flowColor(v)
      if range > 0 then
        barHeight = math.floor((v - minV) / range * height + 0.5)
      else
        barHeight = math.floor(height / 2)
      end
      barHeight = math.max(0, math.min(height, barHeight))
    end
    for row = 0, height - 1 do
      local fromBottom = height - 1 - row
      monitor.setCursorPos(x + col, yTop + row)
      monitor.setBackgroundColor(fromBottom < barHeight and color or colors.black)
      monitor.write(" ")
    end
  end
  monitor.setBackgroundColor(colors.black)
end

-- ---------------------------------------------------------------------
-- State -- one independent track per broadcast `kind`.
-- ---------------------------------------------------------------------

local lastCell = nil           -- most recent kind="ender_cell" payload
local previousCell = nil       -- the one before that, for rate calc
local lastCellReceivedAt = nil -- os.epoch("utc") of last kind="ender_cell"

local lastFlow = nil           -- most recent kind="energy_flow" payload
local lastFlowReceivedAt = nil -- os.epoch("utc") of last kind="energy_flow"

local flowHistory = {}    -- {t=, value=} samples, oldest first, trimmed to FLOW_HISTORY_SECONDS
local hourBucket = nil    -- current floor(epoch_ms / 3600000); a change means a new hour
local hourMin, hourMax = nil, nil

-- Writes one line and advances past it -- used so optional/variable-
-- length sections (per-source breakdown, either stream going stale
-- independently) can be present or absent without every other line's
-- row number needing to shift to compensate.
local function writeLine(row, text, color)
  monitor.setCursorPos(1, row)
  monitor.setTextColor(color or colors.white)
  monitor.write(text)
  return row + 1
end

local function render()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  local w, h = monitor.getSize()
  local row = 1
  row = writeLine(row, "POWAH Energy Monitor")
  row = row + 1 -- blank

  -- ---- Storage level (kind="ender_cell") -----------------------------
  if not lastCell then
    row = writeLine(row, ("Waiting for cell signal (ch. %d)..."):format(CHANNEL), colors.gray)
    row = row + 1
  else
    local energy, maxEnergy = lastCell.energy, lastCell.maxEnergy
    local anomaly = detectAnomaly(energy, maxEnergy)
    local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0

    -- Level-based rate: near-useless once the network sits pinned near
    -- 100% (a well-tuned power source keeps it there on purpose), but
    -- harmless to keep as a secondary number -- Total/graph below are
    -- the actual production/consumption signal for that situation.
    local ratePerSec = nil
    local rateUnavailableReason = "warming up"
    if anomaly then
      rateUnavailableReason = "guard triggered"
    elseif previousCell and lastCell.t > previousCell.t and not detectAnomaly(previousCell.energy, previousCell.maxEnergy) then
      ratePerSec = (lastCell.energy - previousCell.energy) / ((lastCell.t - previousCell.t) / 1000)
    end

    row = writeLine(row, formatFE(energy) .. " / " .. formatFE(maxEnergy))
    row = writeLine(row, anomaly and string.format("%.1f%%+ (min)", pct) or string.format("%.1f%%", pct))
    row = row + 1 -- blank

    local barWidth = math.max(w - 2, 10)
    drawBar(1, row, barWidth, 2, pct, barColor(pct))
    row = row + 3 -- 2 bar rows + blank

    if ratePerSec then
      row = writeLine(row, string.format("%s/s", formatFE(ratePerSec)), ratePerSec >= 0 and colors.lime or colors.orange)
    else
      row = writeLine(row, ("-- FE/s (%s)"):format(rateUnavailableReason), colors.gray)
    end

    if anomaly then
      row = writeLine(row, "GUARD: " .. anomaly, colors.red)
    end

    local cellStaleSeconds = (os.epoch("utc") - lastCellReceivedAt) / 1000
    if cellStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("NO SIGNAL (cell, %ds ago)", math.floor(cellStaleSeconds)), colors.red)
    end
  end

  row = row + 1 -- blank between the two sections

  -- ---- Flow (kind="energy_flow") -------------------------------------
  if not lastFlow then
    row = writeLine(row, ("Waiting for flow signal (ch. %d)..."):format(CHANNEL), colors.gray)
    row = row + 1
  else
    if type(lastFlow.totalFlowFEt) == "number" then
      row = writeLine(row, "Total: " .. formatFE(lastFlow.totalFlowFEt) .. "/t", flowColor(lastFlow.totalFlowFEt))

      if hourMin and hourMax then
        row = writeLine(row, "Hour min " .. formatFE(hourMin) .. "/t  max " .. formatFE(hourMax) .. "/t", colors.lightGray)
      end

      -- Skip the breakdown when there's only one source -- Total already
      -- says the same thing. Cap the list so a growing sources array
      -- (more generators added later) can't push the graph off-screen.
      if type(lastFlow.sources) == "table" and #lastFlow.sources > 1 then
        local MAX_SOURCE_LINES = 4
        for i, source in ipairs(lastFlow.sources) do
          if i > MAX_SOURCE_LINES then
            row = writeLine(row, ("  +%d more"):format(#lastFlow.sources - MAX_SOURCE_LINES), colors.gray)
            break
          end
          if type(source.name) == "string" and type(source.rateFEt) == "number" then
            row = writeLine(row, "  " .. sourceLabel(source.name) .. ": " .. formatFE(source.rateFEt) .. "/t", flowColor(source.rateFEt))
          end
        end
      end
    elseif type(lastFlow.sources) == "table" and #lastFlow.sources == 0 then
      row = writeLine(row, "No Energy Detector found", colors.gray)
    end

    local flowStaleSeconds = (os.epoch("utc") - lastFlowReceivedAt) / 1000
    if flowStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("NO SIGNAL (flow, %ds ago)", math.floor(flowStaleSeconds)), colors.red)
    end
  end

  row = row + 1 -- blank before the graph

  -- ---- Rolling flow graph, fills whatever space is left ---------------
  if #flowHistory > 0 and hourMin and hourMax then
    local graphHeight = h - row
    if graphHeight >= 3 then
      drawGraph(1, row, w, graphHeight, flowHistory, hourMin, hourMax)
    end
  end
end

-- A single bad frame (e.g. an unexpected value from a broadcaster)
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

  local modem = requirePeripheral("modem", "receiver for both broadcast types")
  if not modem.isOpen(CHANNEL) then
    modem.open(CHANNEL)
  end

  monitor = requirePeripheral("monitor", "output display")
  monitor.setTextScale(TEXT_SCALE)

  log("READY listening on ch.%d", CHANNEL)
  safeRender()

  local lastAnomaly = nil
  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" and channel == CHANNEL and type(message) == "table" then
      if message.kind == "ender_cell"
        and type(message.energy) == "number" and type(message.maxEnergy) == "number" then
        previousCell = lastCell
        lastCell = message
        lastCellReceivedAt = os.epoch("utc")

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
      elseif message.kind == "energy_flow" then
        lastFlow = message
        lastFlowReceivedAt = os.epoch("utc")

        if type(message.totalFlowFEt) == "number" then
          local now = os.epoch("utc")
          table.insert(flowHistory, { t = now, value = message.totalFlowFEt })
          while #flowHistory > 0 and (now - flowHistory[1].t) > FLOW_HISTORY_SECONDS * 1000 do
            table.remove(flowHistory, 1)
          end

          local bucket = math.floor(now / 3600000) -- ms per hour
          if bucket ~= hourBucket then
            hourBucket = bucket
            hourMin, hourMax = message.totalFlowFEt, message.totalFlowFEt
          else
            hourMin = math.min(hourMin, message.totalFlowFEt)
            hourMax = math.max(hourMax, message.totalFlowFEt)
          end
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
