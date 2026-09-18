-- powah-energy-monitor/induction-dashboard/run.lua
--
-- Dashboard for ../induction-broadcaster/ ONLY -- listens on CHANNEL
-- (6703) alone, not the CELL_CHANNEL/FLOW_CHANNEL pair ../dashboard/
-- listens on. One computer/one Induction Port now carries everything
-- (storage, flow, transfer cap, charge/discharge ETA) in a single
-- message, so there's no need for ../dashboard/'s two-independent-
-- streams design here -- see this folder's README.md ADR for why this
-- is a separate dashboard rather than a change to that one.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- This computer does NOT need to touch the Induction Port itself --
-- only a modem (to receive) and a monitor (to display).
--
-- LOOK: same steampunk copper/brass conventions as ../dashboard/ --
-- plain ASCII + monitor background COLOR fills only, no character
-- glyphs (see that dashboard's README.md for why); flow shown first,
-- no header, graph dominant. drawGraph()/drawGradientBar()/valueAt()
-- below are carried over verbatim from that dashboard -- proven,
-- already tested code, not reinvented here.
--
-- PERFORMANCE: redraws happen ONLY on the REDRAW_SECONDS timer, never
-- directly on message receipt -- see ../dashboard/README.md's ADR for
-- the reasoning, identical here.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-09-18.1"

local CHANNEL = 6703 -- must match CHANNEL in ../induction-broadcaster/run.lua
local STALE_AFTER_SECONDS = 5
local REDRAW_SECONDS = 1
local LOG_FILE = "induction-dashboard.log"
local LOG_MAX_LINES = 50
local FLOW_HISTORY_SECONDS = 60 -- rolling window for the graph
local TEXT_SCALE = 1

local CONFIG = {
  warn_below_pct = 25, -- pct number shows red below this
  ok_below_pct = 75,   -- yellow between warn and ok, green above -- the
                        -- storage bar itself is a uniform brass gauge,
                        -- see ../dashboard/README.md's matching ADR.
}

-- ---------------------------------------------------------------------
-- Logging: prints live and keeps a bounded on-disk history.
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
  return string.format("%s%d FE", sign, math.floor(n + 0.5))
end

-- Copper/brass palette, same semantics as ../dashboard/: orange
-- producing, red draining, brown idle.
local function flowColor(rateFEt)
  if rateFEt > 0 then return colors.orange end
  if rateFEt < 0 then return colors.red end
  return colors.brown
end

-- H:MM:SS, or "Xd Xh" past a day -- used for charge/discharge ETA.
local function formatDuration(seconds)
  if seconds ~= seconds or seconds == math.huge then return "unknown" end
  seconds = math.floor(math.max(seconds, 0))
  local days = math.floor(seconds / 86400)
  seconds = seconds - days * 86400
  local hours = math.floor(seconds / 3600)
  seconds = seconds - hours * 3600
  local minutes = math.floor(seconds / 60)
  seconds = seconds - minutes * 60
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  end
  return string.format("%d:%02d:%02d", hours, minutes, seconds)
end

local monitor -- assigned once peripheral discovery succeeds, below

local function statusColor(pct)
  if pct < CONFIG.warn_below_pct then return colors.red end
  if pct < CONFIG.ok_below_pct then return colors.yellow end
  return colors.green
end

-- Uniform brass/copper gauge -- carried over verbatim from
-- ../dashboard/run.lua, see that file's matching ADR.
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

-- Linear-interpolated value of `history` at time `t` -- carried over
-- verbatim from ../dashboard/run.lua, see that file's continuity ADR.
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

-- Trading-chart line + grid, no fill -- carried over verbatim from
-- ../dashboard/run.lua, see that file's matching ADRs.
local function drawGraph(x, yTop, width, height, history, windowMs, minV, maxV)
  local now = os.epoch("utc")
  local range = maxV - minV
  local lineColor = flowColor(history[#history] and history[#history].value or 0)

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
-- State -- ONE stream now, unlike ../dashboard/'s two independent
-- tracks, since one Induction Port message already carries everything.
-- ---------------------------------------------------------------------

local last = nil           -- most recent kind="induction_matrix" payload
local lastReceivedAt = nil -- os.epoch("utc") of the last message

local flowHistory = {}  -- {t=, value=} samples of netFlow, oldest first
local hourBucket = nil
local hourMin, hourMax = nil, nil

local pulseOn = false

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

  if not last then
    row = writeLine(row, ("Waiting for signal (ch. %d)..."):format(CHANNEL), colors.gray)
  else
    -- ---- Flow: shown first, biggest priority ------------------------
    local trend = last.netFlow > 0 and "+" or (last.netFlow < 0 and "-" or "o")
    monitor.setCursorPos(1, row)
    monitor.setTextColor(pulseOn and colors.yellow or colors.orange)
    monitor.write("*")
    monitor.setTextColor(flowColor(last.netFlow))
    monitor.write(" " .. trend .. " " .. formatFE(last.netFlow) .. "/t")
    row = row + 1

    row = writeLine(row, "  in " .. formatFE(last.input) .. "/t  out " .. formatFE(last.output) .. "/t", colors.lightGray)
    row = writeLine(row, "  max IO " .. formatFE(last.transferCap) .. "/t", colors.brown)

    row = row + 1 -- blank

    -- ---- Storage: secondary, compact --------------------------------
    local pct = last.percentage * 100
    row = writeLine(row, string.format("%.1f%%  ", pct) .. formatFE(last.energy) .. " / " .. formatFE(last.maxEnergy), statusColor(pct))

    local barWidth = math.max(w - 2, 10)
    drawGradientBar(2, row, barWidth, 1, pct)
    row = row + 1

    -- ---- Charge/discharge ETA, from the broadcaster's own measured
    -- change rate (see ../induction-broadcaster/README.md's ADR) -----
    if last.changePerSecond > 0 and last.etaSeconds then
      row = writeLine(row, "  Charging -- full in " .. formatDuration(last.etaSeconds), colors.orange)
    elseif last.changePerSecond < 0 and last.etaSeconds then
      row = writeLine(row, "  Discharging -- empty in " .. formatDuration(last.etaSeconds), colors.red)
    else
      row = writeLine(row, "  Idle", colors.brown)
    end

    local staleSeconds = (os.epoch("utc") - lastReceivedAt) / 1000
    if staleSeconds > STALE_AFTER_SECONDS then
      row = writeLine(row, string.format("  NO SIGNAL (%ds ago)", math.floor(staleSeconds)), pulseOn and colors.red or colors.gray)
    end
  end

  row = row + 1 -- blank before the graph

  if #flowHistory > 0 and hourMin and hourMax then
    local graphHeight = h - row
    if graphHeight >= 3 then
      drawGraph(1, row, w, graphHeight, flowHistory, FLOW_HISTORY_SECONDS * 1000, hourMin, hourMax)
    end
  end
end

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
  local modem = peripheral.find("modem")
  if not modem then
    error("no modem peripheral found -- attach a Wireless or Ender Modem to this computer", 0)
  end
  if modem.isWireless and not modem.isWireless() then
    error("the attached modem is a Wired Modem -- receiving needs a Wireless or Ender Modem in range of the broadcaster", 0)
  end
  if not modem.isOpen(CHANNEL) then
    modem.open(CHANNEL)
  end

  monitor = peripheral.find("monitor")
  if not monitor then
    error("no monitor peripheral found -- attach one to this computer", 0)
  end
  monitor.setTextScale(TEXT_SCALE)

  log("READY v%s -- listening on ch.%d", SCRIPT_VERSION, CHANNEL)
  safeRender()

  local redrawTimer = os.startTimer(REDRAW_SECONDS)
  while true do
    local event, sideOrTimerId, channel, replyChannel, message = os.pullEvent()

    if event == "modem_message" and type(message) == "table"
      and channel == CHANNEL and message.kind == "induction_matrix" then
      -- State only here, no safeRender() -- the redrawTimer below is the
      -- only thing that draws, same reasoning as ../dashboard/README.md's
      -- matching ADR.
      last = message
      lastReceivedAt = os.epoch("utc")

      if type(message.netFlow) == "number" then
        local now = os.epoch("utc")
        table.insert(flowHistory, { t = now, value = message.netFlow })
        while #flowHistory > 0 and (now - flowHistory[1].t) > FLOW_HISTORY_SECONDS * 1000 do
          table.remove(flowHistory, 1)
        end

        local bucket = math.floor(now / 3600000)
        if bucket ~= hourBucket then
          hourBucket = bucket
          hourMin, hourMax = message.netFlow, message.netFlow
        else
          hourMin = math.min(hourMin, message.netFlow)
          hourMax = math.max(hourMax, message.netFlow)
        end
      end
    elseif event == "timer" and sideOrTimerId == redrawTimer then
      safeRender()
      redrawTimer = os.startTimer(REDRAW_SECONDS)
    elseif event == "peripheral_detach" then
      log("PERIPHERAL DETACHED: %s", tostring(sideOrTimerId))
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
