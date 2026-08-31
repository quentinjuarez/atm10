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
-- LOOK: header band, gradient "fuel gauge" bar, and the graph's half-block
-- 2x vertical resolution all use CP437 block/shade characters (the same
-- extended-ASCII range CC:Tweaked's font has supported since classic
-- ComputerCraft) -- see this folder's README.md's "gauge and half-block
-- graph" ADR for why these specific characters and how they stay cheap
-- in monitor calls.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-08-31.2"

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
  -- Every value passed here today is a whole number (raw NBT longs,
  -- direct getTransferRate() reads and their sum), so this branch
  -- shouldn't see a fractional n -- rounds explicitly anyway, since
  -- CC:Tweaked's Lua runtime errors on %d with a non-integral float and
  -- that's a bad way to find out a future source of data isn't.
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

-- CP437 block/shade characters -- the same extended-ASCII range
-- CC:Tweaked's font has rendered since classic ComputerCraft, commonly
-- used across CC community UIs for exactly this kind of thing. Kept to
-- this one well-established range (no box-drawing corners, no 1-31
-- control-range glyphs) since there's no way to screenshot the in-game
-- result from here to confirm a riskier glyph renders as expected --
-- these are safe bets.
local CH = {
  block      = string.char(219), -- full block: bar/gauge fill
  halfTop    = string.char(223), -- upper-half block: graph sub-pixel
  shadeLight = string.char(176), -- dim dotted texture: empty gauge track
  shadeDark  = string.char(178), -- section-label flourish
  hLine      = string.char(196), -- header divider
}

local function centerText(text, width)
  if #text >= width then return text:sub(1, width) end
  return string.rep(" ", math.floor((width - #text) / 2)) .. text
end

-- Pct number / state coloring -- driven by CONFIG's thresholds, "what
-- state am I in" semantics. Kept separate from the bar's own coloring
-- below (bandColorAt), which is purely decorative and independent of
-- these thresholds -- see this folder's README.md ADR for why they're
-- two different color functions now instead of one.
local function statusColor(pct)
  if pct < CONFIG.warn_below_pct then return colors.red end
  if pct < CONFIG.ok_below_pct then return colors.yellow end
  return colors.green
end

-- Fixed red-to-green bands by POSITION along the bar, not by the current
-- pct -- same idea as a car's fuel gauge, which is always red-at-empty,
-- green-at-full regardless of where the needle sits. Five bands, not a
-- true per-pixel blend, so the fill still draws as a handful of
-- same-color runs (see drawGradientBar below) instead of one monitor
-- call per column.
local GRADIENT_BANDS = {
  { limit = 20,  color = colors.red },
  { limit = 40,  color = colors.orange },
  { limit = 60,  color = colors.yellow },
  { limit = 80,  color = colors.lime },
  { limit = 100, color = colors.green },
}

local function bandColorAt(colPct)
  for _, band in ipairs(GRADIENT_BANDS) do
    if colPct <= band.limit then return band.color end
  end
  return colors.green
end

-- "Fuel gauge" bar: filled portion colored by track position
-- (bandColorAt), empty portion drawn as a dim dotted texture
-- (shadeLight) instead of flat black, so an empty/low bar still reads as
-- "a gauge" rather than "nothing drawn". Same same-appearance-run
-- batching as drawGraph below -- at most 5 fill runs + 1 empty run per
-- row, not one call per column.
local function drawGradientBar(x, y, width, height, pct)
  local filled = math.floor(width * math.min(math.max(pct, 0), 100) / 100)
  for dy = 0, height - 1 do
    local rowY = y + dy
    local runStart, runColor, runChar = 1, nil, nil
    for col = 1, width + 1 do
      local color, char
      if col <= filled then
        color, char = bandColorAt(col / width * 100), CH.block
      elseif col <= width then
        color, char = colors.gray, CH.shadeLight
      end
      if col > width or color ~= runColor or char ~= runChar then
        if runColor then
          monitor.setCursorPos(x + runStart - 1, rowY)
          monitor.setTextColor(runColor)
          monitor.write(string.rep(runChar, col - runStart))
        end
        runStart, runColor, runChar = col, color, char
      end
    end
  end
  monitor.setTextColor(colors.white)
end

-- Rolling bar-chart of `history` ({t=, value=}, oldest first), newest
-- sample at the rightmost column, scaled between minV/maxV. TWO sub-rows
-- of vertical resolution per terminal row, via the ▀ (upper-half-block)
-- character: one cell can show two independently-colored half-height
-- pixels (foreground = top half, background = bottom half) instead of
-- one flat-colored cell, so a bar's top edge lands on the nearest
-- half-row instead of the nearest whole row -- noticeably smoother on a
-- short graph without costing extra monitor rows. Column heights/colors
-- are precomputed once (pure Lua, no peripheral calls), then each
-- terminal row is drawn as same-appearance RUNS -- one setCursorPos +
-- color set(s) + write per contiguous run of matching (top, bottom)
-- pair, not one per column. See this folder's README.md ADR.
local function drawGraph(x, yTop, width, height, history, minV, maxV)
  local n = #history
  local range = maxV - minV
  local subHeight = height * 2 -- two half-rows per terminal row

  local barSubHeights, colColors = {}, {}
  for col = 1, width do
    local idx = n - width + col
    if idx >= 1 and idx <= n then
      local v = history[idx].value
      colColors[col] = flowColor(v)
      local barH
      if range > 0 then
        barH = math.floor((v - minV) / range * subHeight + 0.5)
      else
        barH = math.floor(subHeight / 2)
      end
      barSubHeights[col] = math.max(0, math.min(subHeight, barH))
    else
      colColors[col] = colors.black
      barSubHeights[col] = 0
    end
  end

  for row = 0, height - 1 do
    local y = yTop + row
    -- Sub-row indices for this terminal row, counted from the bottom of
    -- the whole graph (0 = bottommost half-row, subHeight-1 = topmost).
    local bottomSub = (height - 1 - row) * 2
    local topSub = bottomSub + 1

    local runStart, runTop, runBottom = 1, nil, nil
    for col = 1, width + 1 do
      local topColor, bottomColor
      if col <= width then
        local barH = barSubHeights[col]
        topColor = (barH > topSub) and colColors[col] or colors.black
        bottomColor = (barH > bottomSub) and colColors[col] or colors.black
      end
      if col > width or topColor ~= runTop or bottomColor ~= runBottom then
        if runTop then
          monitor.setCursorPos(x + runStart - 1, y)
          if runTop == runBottom then
            -- Both halves the same color (often both black/empty) -- a
            -- plain colored space reads identically and skips a color
            -- switch the half-block character would otherwise need.
            monitor.setBackgroundColor(runTop)
            monitor.write(string.rep(" ", col - runStart))
          else
            monitor.setTextColor(runTop)
            monitor.setBackgroundColor(runBottom)
            monitor.write(string.rep(CH.halfTop, col - runStart))
          end
        end
        runStart, runTop, runBottom = col, topColor, bottomColor
      end
    end
  end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
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

-- Flipped once per render() -- drives the header's live dot and a slow
-- blink on "NO SIGNAL", both cheap ways to signal "this is actively
-- updating" versus a frozen screen, at REDRAW_SECONDS cadence (no extra
-- timer needed).
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

  -- ---- Header: colored title band + divider with a live clock/dot -----
  monitor.setBackgroundColor(colors.blue)
  monitor.setCursorPos(1, 1)
  monitor.write(string.rep(" ", w))
  monitor.setCursorPos(1, 1)
  monitor.write(centerText(CH.shadeDark .. CH.shadeDark .. " POWAH ENERGY GRID " .. CH.shadeDark .. CH.shadeDark, w))
  monitor.setBackgroundColor(colors.black)

  monitor.setCursorPos(1, 2)
  monitor.setTextColor(colors.gray)
  monitor.write(string.rep(CH.hLine, w))

  local clock = os.date("%H:%M:%S")
  if w >= #clock + 3 then
    monitor.setCursorPos(w - #clock - 1, 2)
    monitor.setTextColor(pulseOn and colors.lime or colors.green)
    monitor.write("*")
    monitor.setTextColor(colors.lightGray)
    monitor.write(clock)
  end

  local row = 4

  -- ---- Storage level (CELL_CHANNEL, kind="ender_cell") ---------------
  row = writeLine(row, CH.shadeDark .. " STORAGE", colors.cyan)
  if not lastCell then
    row = writeLine(row, ("  Waiting for cell signal (ch. %d)..."):format(CELL_CHANNEL), colors.gray)
    row = row + 1
  else
    local energy, maxEnergy = lastCell.energy, lastCell.maxEnergy
    local anomaly = detectAnomaly(energy, maxEnergy)
    local pct = maxEnergy > 0 and (energy / maxEnergy * 100) or 0
    local pctClamped = math.min(math.max(pct, 0), 100)

    row = writeLine(row, "  " .. formatFE(energy) .. " / " .. formatFE(maxEnergy))
    row = writeLine(row, "  " .. (anomaly and string.format("%.1f%%+ (min)", pct) or string.format("%.1f%%", pct)), statusColor(pctClamped))
    row = row + 1 -- blank

    local barWidth = math.max(w - 2, 10)
    drawGradientBar(2, row, barWidth, 2, pct)
    row = row + 2 -- bar rows

    if anomaly then
      row = writeLine(row, "  GUARD: " .. anomaly, colors.red)
    end

    local cellStaleSeconds = (os.epoch("utc") - lastCellReceivedAt) / 1000
    if cellStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("  NO SIGNAL (cell, %ds ago)", math.floor(cellStaleSeconds)), pulseOn and colors.red or colors.gray)
    end
  end

  row = row + 1 -- blank between the two sections

  -- ---- Flow (FLOW_CHANNEL, kind="energy_flow") ------------------------
  row = writeLine(row, CH.shadeDark .. " FLOW", colors.lightBlue)
  if not lastFlow then
    row = writeLine(row, ("  Waiting for flow signal (ch. %d)..."):format(FLOW_CHANNEL), colors.gray)
    row = row + 1
  else
    -- Checked in this order because totalFlowFEt is always a number (0
    -- when nothing was found) -- checking it first would mean the
    -- "no detector" message could never show, silently looking like
    -- "0 FE/t" instead of "nothing is even attached".
    if type(lastFlow.sources) == "table" and #lastFlow.sources == 0 then
      row = writeLine(row, "  No Energy Detector found", colors.gray)
    elseif type(lastFlow.totalFlowFEt) == "number" then
      -- Plain-ASCII trend marker (not an arrow glyph) next to the
      -- color -- readable even if a viewer's client renders an unusual
      -- character oddly, since the color alone already carries the
      -- same meaning (flowColor: lime producing, orange draining, gray
      -- idle).
      local trend = lastFlow.totalFlowFEt > 0 and "+" or (lastFlow.totalFlowFEt < 0 and "-" or "o")
      row = writeLine(row, "  " .. trend .. " Total: " .. formatFE(lastFlow.totalFlowFEt) .. "/t", flowColor(lastFlow.totalFlowFEt))

      if hourMin and hourMax then
        row = writeLine(row, "    Hour min " .. formatFE(hourMin) .. "/t  max " .. formatFE(hourMax) .. "/t", colors.lightGray)
      end

      -- Skip the breakdown when there's only one source -- Total already
      -- says the same thing. Cap the list so a growing sources array
      -- (more generators added later) can't push the graph off-screen.
      if type(lastFlow.sources) == "table" and #lastFlow.sources > 1 then
        local MAX_SOURCE_LINES = 4
        for i, source in ipairs(lastFlow.sources) do
          if i > MAX_SOURCE_LINES then
            row = writeLine(row, ("    +%d more"):format(#lastFlow.sources - MAX_SOURCE_LINES), colors.gray)
            break
          end
          if type(source.name) == "string" and type(source.rateFEt) == "number" then
            row = writeLine(row, "    " .. sourceLabel(source.name) .. ": " .. formatFE(source.rateFEt) .. "/t", flowColor(source.rateFEt))
          end
        end
      end
    end

    local flowStaleSeconds = (os.epoch("utc") - lastFlowReceivedAt) / 1000
    if flowStaleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("  NO SIGNAL (flow, %ds ago)", math.floor(flowStaleSeconds)), pulseOn and colors.red or colors.gray)
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
