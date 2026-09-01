-- photo-viewer/run.lua
--
-- Digital photo frame: fetches a list of pre-converted images (.nfp --
-- CC:Tweaked's native pixel-image text format) from this repo, cycles
-- through them on an Advanced Monitor, and lets a player TOUCH the
-- monitor to skip to the next photo immediately. No Discord/web
-- integration needed -- monitor_touch is CC:Tweaked's own built-in way
-- for a player to interact with a screen. See this folder's README.md
-- for why touch (not a lever/redstone) was picked for this feature.
--
-- Don't wget this file directly to install it -- see install.lua in this
-- same folder, or the repo root README's "Installing a script in-game".
--
-- IMAGES ARE NOT PHOTOS THEMSELVES -- they're .nfp text files, CC:Tweaked's
-- own pixel-art format (one character per pixel, 16 colors, no
-- transparency tricks needed). You convert a PNG to .nfp on your OWN
-- computer with ../../tools/png_to_nfp.py (NOT run in-game -- see that
-- folder's README) and push the result into this folder's images/. This
-- computer just fetches and draws whatever .nfp files MANIFEST_URL lists
-- -- it never does any image processing itself.
--
-- WIRING: an Advanced Monitor (any size; native colors), any free side.
-- A plain Monitor still works -- CC:Tweaked quantizes colors to
-- grayscale automatically, no special-casing needed here.
--
-- RESILIENCE: each redraw/fetch runs inside its own pcall -- see
-- ../powah-energy-monitor/README.md's "every timed cycle wrapped in its
-- own pcall" ADR, same reasoning applies to any long-running loop here.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-09-01.1"

local BASE_URL = "https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/photo-viewer/"
local MANIFEST_URL = BASE_URL .. "manifest.txt"
local IMAGES_BASE_URL = BASE_URL .. "images/"
local SLIDE_SECONDS = 15 -- auto-advance interval; touching the monitor resets this timer
local LOG_FILE = "photo-viewer.log"
local LOG_MAX_LINES = 50

-- ---------------------------------------------------------------------
-- Logging: prints live and keeps a bounded on-disk history, same
-- pattern as ../powah-energy-monitor's scripts.
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
-- .nfp parsing/drawing
-- ---------------------------------------------------------------------

-- hex digit -> color, the inverse of CC:Tweaked's own colors.toBlit()
-- (digit N = the color whose value is 2^N.decimal-of-that-hex-digit) --
-- not a guessed mapping, it's how colors.toBlit() is defined.
local BLIT_TO_COLOR = {
  ["0"] = colors.white,     ["1"] = colors.orange, ["2"] = colors.magenta,
  ["3"] = colors.lightBlue, ["4"] = colors.yellow, ["5"] = colors.lime,
  ["6"] = colors.pink,      ["7"] = colors.gray,    ["8"] = colors.lightGray,
  ["9"] = colors.cyan,      ["a"] = colors.purple,  ["b"] = colors.blue,
  ["c"] = colors.brown,     ["d"] = colors.green,   ["e"] = colors.red,
  ["f"] = colors.black,
}

-- Parses raw .nfp text into { width=, height=, rows={ "0f f0...", ... } }.
-- A space means "no pixel" (skip when drawing) -- same convention
-- CC:Tweaked's own paintutils.loadImage uses.
local function parseNfp(text)
  local rows = {}
  local width = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(rows, line)
    width = math.max(width, #line)
  end
  -- Trailing blank lines from a file's final newline aren't real rows.
  while #rows > 0 and rows[#rows] == "" do
    table.remove(rows)
  end
  return { width = width, height = #rows, rows = rows }
end

-- Draws one image top-left-aligned, clipped to the monitor's actual
-- size. Same same-color-RUN batching as ../powah-energy-monitor's
-- dashboard graph -- one setCursorPos + setBackgroundColor + write per
-- contiguous run of same-colored pixels in a row, not one monitor call
-- per pixel. See this folder's README.md ADR.
local function drawImage(monitor, image, monW, monH)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  local maxY = math.min(image.height, monH)
  local maxX = math.min(image.width, monW)
  for y = 1, maxY do
    local row = image.rows[y]
    local runStart, runColor = 1, nil
    for x = 1, maxX + 1 do
      local color = nil
      if x <= maxX then
        local ch = row:sub(x, x)
        color = ch ~= "" and ch ~= " " and BLIT_TO_COLOR[ch] or nil
      end
      if color ~= runColor then
        if runColor then
          monitor.setCursorPos(runStart, y)
          monitor.setBackgroundColor(runColor)
          monitor.write(string.rep(" ", x - runStart))
        end
        runStart, runColor = x, color
      end
    end
  end
  monitor.setBackgroundColor(colors.black)
end

local function drawMessage(monitor, text, color)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setCursorPos(1, 1)
  monitor.setTextColor(color or colors.white)
  monitor.write(text)
end

-- ---------------------------------------------------------------------
-- Everything below runs inside one pcall so ANY failure gets logged to
-- file, not just flashed on a screen nobody's watching.
-- ---------------------------------------------------------------------

local ok, err = pcall(function()
  local monitor = peripheral.find("monitor")
  if not monitor then
    error("no monitor peripheral found -- attach one to this computer", 0)
  end
  monitor.setTextScale(1)
  local monW, monH = monitor.getSize()

  drawMessage(monitor, "Loading photo list...", colors.gray)

  local manifestOk, manifestNames = pcall(function()
    local h = http.get(MANIFEST_URL)
    if not h then error("could not fetch manifest.txt", 0) end
    local body = h.readAll()
    h.close()
    local names = {}
    for line in body:gmatch("[^\r\n]+") do
      line = line:match("^%s*(.-)%s*$") -- trim
      if line ~= "" and not line:match("^%-%-") then -- skip blanks/comments
        table.insert(names, line)
      end
    end
    return names
  end)
  if not manifestOk then
    error("failed to load manifest: " .. tostring(manifestNames), 0)
  end
  if #manifestNames == 0 then
    error("manifest.txt is empty -- add at least one .nfp filename", 0)
  end

  -- Every image is fetched ONCE up front, not re-fetched each time it's
  -- shown -- keeps the slideshow smooth and immune to a mid-show network
  -- hiccup. A handful of small .nfp text files costs little memory.
  local images = {}
  for _, name in ipairs(manifestNames) do
    drawMessage(monitor, "Loading " .. name .. "...", colors.gray)
    local fetchOk, result = pcall(function()
      local h = http.get(IMAGES_BASE_URL .. name)
      if not h then error("fetch failed", 0) end
      local text = h.readAll()
      h.close()
      return parseNfp(text)
    end)
    if fetchOk then
      table.insert(images, { name = name, image = result })
    else
      log("SKIPPED %s: %s", name, tostring(result))
    end
  end

  if #images == 0 then
    error("no images could be loaded -- check manifest.txt filenames match images/", 0)
  end

  log("READY v%s -- %d/%d photo(s) loaded, %ds/slide, touch to skip",
    SCRIPT_VERSION, #images, #manifestNames, SLIDE_SECONDS)

  local index = 1
  local function showCurrent()
    local safeOk, safeErr = pcall(drawImage, monitor, images[index].image, monW, monH)
    if not safeOk then
      log("DRAW ERROR (%s): %s", images[index].name, tostring(safeErr))
    end
  end

  showCurrent()
  local slideTimer = os.startTimer(SLIDE_SECONDS)

  while true do
    local event, a = os.pullEvent()
    if event == "timer" and a == slideTimer then
      index = (index % #images) + 1
      showCurrent()
      slideTimer = os.startTimer(SLIDE_SECONDS)
    elseif event == "monitor_touch" then
      -- Any touch, anywhere on the screen, advances -- this is the
      -- whole "let a player choose" mechanism: no external site, no
      -- Discord, just tapping the block. Resets the auto-advance timer
      -- so a flurry of taps doesn't also trigger a redundant auto-skip
      -- right after.
      index = (index % #images) + 1
      showCurrent()
      os.cancelTimer(slideTimer)
      slideTimer = os.startTimer(SLIDE_SECONDS)
    elseif event == "peripheral_detach" then
      log("PERIPHERAL DETACHED: monitor may be gone")
    end
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
