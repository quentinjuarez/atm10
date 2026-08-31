-- powah-energy-monitor/dashboard/run.lua
--
-- Energy dashboard that RECEIVES two independent broadcast types, one per
-- channel, and renders both on a monitor:
--   CELL_CHANNEL   kind="ender_cell"  from ../ender-cell-broadcaster/run.lua
--                  -- stored energy, capacity, fill % (no rate shown here,
--                  -- the flow graph below is the consumption signal)
--   FLOW_CHANNEL   kind="energy_flow" from ../energy-detector-broadcaster/run.lua
--                  -- total FE/t flow, a per-source breakdown, a rolling
--                  -- ~60s bar graph, and the current hour's min/max flow
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
-- CELL_CHANNEL/FLOW_CHANNEL below must match CHANNEL in the matching
-- broadcaster's run.lua exactly.
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
-- up, the fill % shown is a floor -- the real value is at least that.
--
-- PERFORMANCE: redraws happen ONLY on the REDRAW_SECONDS timer, never
-- directly on message receipt -- a message just updates state, the next
-- timer tick picks it up (at most REDRAW_SECONDS late). drawGraph() below
-- batches each row into same-appearance runs instead of one monitor call
-- per character cell -- see this folder's README.md ADR for both, with
-- the reasoning and the actual call-count difference.
--
-- LOOK: steampunk copper/brass theme, picked to match the build this
-- runs in. No header/title band -- flow (FE/t) is the number that
-- matters most, shown first and alone on its line; storage is secondary
-- and compact; the graph is dominant, a plain line (no fill) over a
-- light reference grid, with min/max shown as small corner labels
-- instead of a separate text row. All plain ASCII + monitor background
-- COLOR fills, no character glyphs -- an earlier version tried CP437
-- block/shade characters and they rendered wrong in-game, so nothing
-- here depends on font glyphs rendering a specific way. See this
-- folder's README.md's ADRs for the layout and graph decisions.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-08-31.4"

local CELL_CHANNEL = 6701
local FLOW_CHANNEL = 6702
local STALE_AFTER_SECONDS = 5 -- no signal warning if nothing received this long
local REDRAW_SECONDS = 1
local LOG_FILE = "dashboard.log"
local LOG_MAX_LINES = 50
local FLOW_HISTORY_SECONDS = 60 -- rolling window for the graph
local TEXT_SCALE = 1 -- bigger/more readable than the default 0.5; trades width

local INT32_MAX = 2147483647

local CONFIG = {
  warn_below_pct = 25, -- pct number shows red below this
  ok_below_pct = 75,   -- yellow between warn and ok, green above -- the
                        -- storage BAR itself is a uniform brass gauge
                        -- (no red/yellow/green banding) per this folder's
                        -- README.md ADR; these thresholds only color the
                        -- pct text now.
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
  -- Every value passed here today is a whole number (raw NBT longs,
  -- direct getTransferRate() reads and their sum), so this branch
  -- shouldn't see a fractional n -- rounds explicitly anyway, since
  -- CC:Tweaked's Lua runtime errors on %d with a non-integral float and
  -- that's a bad way to find out a future source of data isn't.
  return string.format("%s%d FE", sign, math.floor(n + 0.5))
end

-- Colors a flow number: copper/brass palette to match the steampunk
-- build this runs in -- orange producing (the boiler's running), red
-- draining (reserves going down, the one state worth flagging), brown
-- idle/zero (dim, nothing happening).
local function flowColor(rateFEt)
  if rateFEt > 0 then return colors.orange end
  if rateFEt < 0 then return colors.red end
  return colors.brown
end

-- "energy_detector_0" -> "src 0" -- CC:Tweaked auto-assigns these names
-- (no confirmed way to give a detector a custom label), so shorten the
-- common case for a small monitor rather than showing the full name.
local function sourceLabel(name)
  local suffix = name:match("_(%d+)$")
  return suffix and ("src " .. suffix) or name
end

local monitor -- assigned once peripheral discovery succeeds, below

-- Pct number coloring -- driven by CONFIG's thresholds, "what state am I
-- in" semantics. The bar itself (drawGradientBar below) is a uniform
-- brass gauge with no threshold banding -- this is the only place that
-- alert coloring still shows for storage level, other than GUARD/NO
-- SIGNAL text. See this folder's README.md ADR.
local function statusColor(pct)
  if pct < CONFIG.warn_below_pct then return colors.red end
  if pct < CONFIG.ok_below_pct then return colors.yellow end
  return colors.green
end

-- Uniform brass/copper gauge -- filled portion one solid color
-- (colors.orange), empty portion a dim brown track, no red/yellow/green
-- banding (that would clash with the steampunk theme this dashboard
-- sits in -- see this folder's README.md ADR). Plain background-color
-- fills, no character glyphs. Drawn as same-color RUNS -- 2 monitor
-- calls per row (fill + track), not one per column.
local function drawGradientBar(x, y, width, height, pct)
  local filled = math.floor(width * math.min(math.max(pct, 0), 100) / 100)
  for dy = 0, height - 1 do
    local rowY = y + dy
    if filled > 0 then
      monitor.setCursorPos(x, rowY)
      monitor.setBackgroundColor(colors.orange)
      monitor.write(string.rep(" ", filled))
    end
    if filled < width then
      monitor.setCursorPos(x + filled, rowY)
      monitor.setBackgroundColor(colors.brown)
      monitor.write(string.rep(" ", width - filled))
    end
  end
  monitor.setBackgroundColor(colors.black)
end

-- Linear-interpolated value of `history` ({t=, value=}, oldest first,
-- time-ordered) at time `t`. nil if `t` predates the first sample
-- (genuinely no data yet, e.g. right after reboot); holds the last known
-- value flat for `t` at/after the newest sample -- same as a real
-- trading chart between ticks. This is what makes a dropped broadcast (a
-- missed second from a server hiccup) invisible in the graph instead of
-- a gap: the line is sampled across a fixed TIME axis, not packed one
-- column per received message -- see this folder's README.md's
-- continuity ADR.
local function valueAt(history, t)
  local n = #history
  if n == 0 or t < history[1].t then return nil end
  if t >= history[n].t then return history[n].value end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if history[mid].t <= t then lo = mid else hi = mid end
  end
  local a, b = history[lo], history[hi]
  if b.t == a.t then return b.value end
  return a.value + (b.value - a.value) * (t - a.t) / (b.t - a.t)
end

-- Trading-chart line, no fill: a light reference grid drawn first (2
-- horizontal rows, 2 vertical columns, dim gray -- thin text-character
-- lines, not colored blocks, so they read as "grid" rather than "another
-- solid bar"), then one accent line on top tracing the value over TIME
-- (not one bar per received sample), colored by the latest value
-- (flowColor: orange producing, red draining, brown idle). Column values
-- come from valueAt() above, sampled evenly across a fixed window ending
-- "now" so the line keeps moving even if the last broadcast is a moment
-- stale (held flat, same as a real trading chart between ticks). A
-- vertical connector between each column and the previous one turns
-- isolated points into a continuous line even where the value jumps a
-- lot between two samples. Small corner labels show the current hour's
-- min/max directly on the plot instead of a separate text row -- see
-- this folder's README.md's layout ADR for why. Scaled between
-- minV/maxV (the current hour's running min/max, passed in by the
-- caller) rather than this frame's own visible-window min/max, so the
-- vertical scale stays stable instead of jumping every redraw.
local function drawGraph(x, yTop, width, height, history, windowMs, minV, maxV)
  local now = os.epoch("utc")
  local range = maxV - minV
  local lineColor = flowColor(history[#history] and history[#history].value or 0)

  -- ---- Reference grid, drawn first so the line/labels layer over it ---
  monitor.setTextColor(colors.gray)
  for _, frac in ipairs({ 1 / 3, 2 / 3 }) do
    monitor.setCursorPos(x, yTop + math.floor(height * frac))
    monitor.write(string.rep("-", width))
  end
  for _, frac in ipairs({ 1 / 3, 2 / 3 }) do
    local gx = x + math.floor(width * frac)
    for row = 0, height - 1 do
      monitor.setCursorPos(gx, yTop + row)
      monitor.write("|")
    end
  end

  -- lineRow[col]: row-from-bottom (0..height-1) the line passes through
  -- at that column's sampled time, or nil where there's no data yet.
  local lineRow = {}
  for col = 1, width do
    local t = now - windowMs * (width - col) / width
    local v = valueAt(history, t)
    if v then
      local rowFromBottom
      if range > 0 then
        rowFromBottom = math.floor((v - minV) / range * (height - 1) + 0.5)
      else
        rowFromBottom = math.floor((height - 1) / 2)
      end
      lineRow[col] = math.max(0, math.min(height - 1, rowFromBottom))
    end
  end

  -- connLow/connHigh: the row RANGE a column shades as "the line",
  -- spanning from the previous column's row to this one's -- a straight
  -- connector, not an isolated dot per column.
  local connLow, connHigh = {}, {}
  local prevRow = nil
  for col = 1, width do
    if lineRow[col] then
      local lo, hi = lineRow[col], lineRow[col]
      if prevRow then lo, hi = math.min(lo, prevRow), math.max(hi, prevRow) end
      connLow[col], connHigh[col] = lo, hi
      prevRow = lineRow[col]
    else
      prevRow = nil
    end
  end

  for row = 0, height - 1 do
    local fromBottom = height - 1 - row
    local y = yTop + row
    local runStart, runColor = 1, nil
    for col = 1, width + 1 do
      -- nil here means "leave the grid/background as-is", not "draw
      -- black" -- only cells the line actually passes through get
      -- touched, so the grid stays visible everywhere else.
      local color = nil
      if col <= width and lineRow[col] and fromBottom >= connLow[col] and fromBottom <= connHigh[col] then
        color = lineColor
      end
      if color ~= runColor then
        if runColor then
          monitor.setCursorPos(x + runStart - 1, y)
          monitor.setBackgroundColor(runColor)
          monitor.write(string.rep(" ", col - runStart))
        end
        runStart, runColor = col, color
      end
    end
  end
  monitor.setBackgroundColor(colors.black)

  -- ---- Corner labels: current-hour max (top-left) / min (bottom-left) -
  local function cornerLabel(labelY, text)
    monitor.setCursorPos(x, labelY)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightGray)
    monitor.write(text:sub(1, width))
  end
  cornerLabel(yTop, formatFE(maxV) .. "/t")
  if height > 1 then
    cornerLabel(yTop + height - 1, formatFE(minV) .. "/t")
  end
end

-- ---------------------------------------------------------------------
-- State -- one independent track per broadcast `kind`.
-- ---------------------------------------------------------------------

local lastCell = nil           -- most recent kind="ender_cell" payload
local lastCellReceivedAt = nil -- os.epoch("utc") of last kind="ender_cell"

local lastFlow = nil           -- most recent kind="energy_flow" payload
local lastFlowReceivedAt = nil -- os.epoch("utc") of last kind="energy_flow"

local flowHistory = {}    -- {t=, value=} samples, oldest first, trimmed to FLOW_HISTORY_SECONDS
local hourBucket = nil    -- current floor(epoch_ms / 3600000); a change means a new hour
local hourMin, hourMax = nil, nil

-- Flipped once per render() -- drives the flow line's leading pulse dot
-- and a slow blink on "NO SIGNAL", both cheap ways to signal "this is
-- actively updating" versus a frozen screen, at REDRAW_SECONDS cadence
-- (no extra timer needed).
local pulseOn = false

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
  monitor.setTextColor(colors.white)
  monitor.clear()

  local w, h = monitor.getSize()
  pulseOn = not pulseOn

  local row = 1

  -- ---- Flow (FLOW_CHANNEL, kind="energy_flow") -- the number that
  -- matters most, shown first with no header above it. -----------------
  if not lastFlow then
    row = writeLine(row, ("Waiting for flow signal (ch. %d)..."):format(FLOW_CHANNEL), colors.gray)
  else
    -- Checked in this order because totalFlowFEt is always a number (0
    -- when nothing was found) -- checking it first would mean the
    -- "no detector" message could never show, silently looking like
    -- "0 FE/t" instead of "nothing is even attached".
    if type(lastFlow.sources) == "table" and #lastFlow.sources == 0 then
      row = writeLine(row, "No Energy Detector found", colors.gray)
    elseif type(lastFlow.totalFlowFEt) == "number" then
      -- Manual two-color write, not writeLine(): the leading "*" pulses
      -- yellow/orange every redraw (liveness), independent of the
      -- trend/value's own flowColor (state) -- see the pulseOn comment
      -- above.
      monitor.setCursorPos(1, row)
      monitor.setTextColor(pulseOn and colors.yellow or colors.orange)
      monitor.write("*")
      -- Plain-ASCII trend marker (not an arrow glyph) -- readable even
      -- if a viewer's client renders an unusual character oddly, since
      -- the color alone already carries the same meaning (flowColor:
      -- orange producing, red draining, brown idle).
      local trend = lastFlow.totalFlowFEt > 0 and "+" or (lastFlow.totalFlowFEt < 0 and "-" or "o")
      monitor.setTextColor(flowColor(lastFlow.totalFlowFEt))
      monitor.write(" " .. trend .. " " .. formatFE(lastFlow.totalFlowFEt) .. "/t")
      row = row + 1

      -- Skip the breakdown when there's only one source -- the line
      -- above already says the same thing. Cap the list so a growing
      -- sources array (more generators added later) can't push the
      -- graph off-screen.
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
    end

    local flowStaleSeconds = (os.epoch("utc") - lastFlowReceivedAt) / 1000
    if flowStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("NO SIGNAL (flow, %ds ago)", math.floor(flowStaleSeconds)), pulseOn and colors.red or colors.gray)
    end
  end

  row = row + 1 -- blank

  -- ---- Storage level (CELL_CHANNEL, kind="ender_cell") -- secondary,
  -- kept compact: one combined line + a single-row gauge. ---------------
  if not lastCell then
    row = writeLine(row, ("Waiting for cell signal (ch. %d)..."):format(CELL_CHANNEL), colors.gray)
  else
    local energy, maxEnergy = lastCell.energy, lastCell.maxEnergy
    local anomaly = detectAnomaly(energy, maxEnergy)
    local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0
    local pctClamped = math.min(math.max(pct, 0), 100)
    local pctText = anomaly and string.format("%.1f%%+", pct) or string.format("%.1f%%", pct)

    row = writeLine(row, pctText .. "  " .. formatFE(energy) .. " / " .. formatFE(maxEnergy), statusColor(pctClamped))

    local barWidth = math.max(w - 2, 10)
    drawGradientBar(2, row, barWidth, 1, pct)
    row = row + 1

    if anomaly then
      row = writeLine(row, "GUARD: " .. anomaly, colors.red)
    end

    local cellStaleSeconds = (os.epoch("utc") - lastCellReceivedAt) / 1000
    if cellStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("NO SIGNAL (cell, %ds ago)", math.floor(cellStaleSeconds)), pulseOn and colors.red or colors.gray)
    end
  end

  row = row + 1 -- blank before the graph

  -- ---- Rolling flow graph -- dominant, fills whatever space is left ---
  if #flowHistory > 0 and hourMin and hourMax then
    local graphHeight = h - row
    if graphHeight >= 3 then
      drawGraph(1, row, w, graphHeight, flowHistory, FLOW_HISTORY_SECONDS * 1000, hourMin, hourMax)
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
  if modem.isWireless and not modem.isWireless() then
    error("the attached modem is a Wired Modem -- receiving needs a Wireless or Ender Modem in range of both broadcasters", 0)
  end
  if not modem.isOpen(CELL_CHANNEL) then
    modem.open(CELL_CHANNEL)
  end
  if not modem.isOpen(FLOW_CHANNEL) then
    modem.open(FLOW_CHANNEL)
  end

  monitor = requirePeripheral("monitor", "output display")
  monitor.setTextScale(TEXT_SCALE)

  log("READY v%s -- listening on ch.%d (cell) and ch.%d (flow)", SCRIPT_VERSION, CELL_CHANNEL, FLOW_CHANNEL)
  safeRender()

  local lastAnomaly = nil
  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" and type(message) == "table" then
      -- State only here, no safeRender() -- the redrawTimer below is the
      -- only thing that draws, so a burst of messages costs one redraw
      -- per REDRAW_SECONDS, not one per message. See the PERFORMANCE
      -- note at the top of this file.
      if channel == CELL_CHANNEL and message.kind == "ender_cell"
        and type(message.energy) == "number" and type(message.maxEnergy) == "number" then
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
      elseif channel == FLOW_CHANNEL and message.kind == "energy_flow" then
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
      end
    elseif event == "timer" and sideOrTimerId == redrawTimer then
      safeRender()
      redrawTimer = os.startTimer(REDRAW_SECONDS)
    elseif event == "peripheral_detach" then
      log("PERIPHERAL DETACHED: %s", tostring(sideOrTimerId))
      -- If it's the monitor itself that detached, these calls would
      -- throw on a now-invalid reference -- pcall so that doesn't take
      -- the whole listening loop down with it.
      local detachOk, detachErr = pcall(function()
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.setTextColor(colors.red)
        monitor.write("Peripheral disconnected")
      end)
      if not detachOk then
        log("DETACH HANDLER ERROR: %s", tostring(detachErr))
      end
    end
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
