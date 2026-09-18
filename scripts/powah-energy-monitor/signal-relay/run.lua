-- powah-energy-monitor/signal-relay/run.lua
--
-- Rebroadcasts modem messages on this repo's known channels (CHANNELS
-- below) unchanged -- a code-only way to extend effective range when
-- two Wireless Modems are too far apart to hear each other directly, no
-- Ender Modem swap needed. Place this computer, with its OWN Wireless
-- Modem, anywhere within range of BOTH the sender and the receiver --
-- each hop gets its own fresh range budget. Chain multiple relays for
-- longer distances.
--
-- IMPORTANT -- this only helps within the SAME dimension. A plain
-- Wireless Modem cannot cross dimensions at all, relayed or not -- if
-- sender and receiver are in different dimensions, an Ender Modem
-- (unlimited range, works cross-dimension) is the only fix, on at
-- least one end. See this folder's README.md ADR for the full reasoning.
--
-- Works for ANY of this repo's broadcasters unmodified -- it relays by
-- CHANNEL NUMBER ONLY and never inspects `kind` or payload contents, so
-- one relay computer covers the Powah setup (6701/6702) and the
-- Mekanism setup (6703) at the same time.
--
-- Don't wget this file directly to install it -- see install.lua in
-- this same folder, or the repo root README's "Installing a script
-- in-game".
--
-- WIRING: a Wireless or Ender Modem on this computer, placed physically
-- between (or otherwise in range of both) whatever it's relaying for.
-- No monitor, no other peripheral needed.

-- Bumped by hand whenever this file changes, logged at READY -- since
-- `wget run` never saves this file to disk, there's no local mtime to
-- check; this is the only way to confirm from the terminal/log alone
-- that a reboot actually picked up the latest push instead of an old
-- fetch, without re-running anything by hand.
local SCRIPT_VERSION = "2026-09-18.1"

local CHANNELS = { 6701, 6702, 6703 } -- every channel used anywhere in this repo
local SEEN_MAX = 200 -- bounded memory of recently relayed timestamps, per channel
local LOG_FILE = "signal-relay.log"
local LOG_MAX_LINES = 50

-- ---------------------------------------------------------------------
-- Logging: prints live and keeps a bounded on-disk history. Only
-- problems and each channel's first-ever relayed message get logged --
-- not every routine relay, which at up to ~2 messages/sec across two
-- broadcasters would just be noise. See this folder's README.md ADR.
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
    error("the attached modem is a Wired Modem -- a relay needs a Wireless or Ender Modem to actually extend range", 0)
  end

  for _, ch in ipairs(CHANNELS) do
    if not modem.isOpen(ch) then
      modem.open(ch)
    end
  end

  log("READY v%s -- relaying channels: %s", SCRIPT_VERSION, table.concat(CHANNELS, ", "))

  -- Per-channel dedup: a message's own `t` (the ORIGINAL broadcaster's
  -- os.epoch, unchanged by relaying) identifies it uniquely enough for
  -- this purpose. Relaying the same message twice (because this relay
  -- heard its own retransmission, or a second relay's) would just be
  -- redundant, not wrong -- receivers already treat "last message wins"
  -- -- but skipping repeats keeps traffic/log volume sane and
  -- guarantees no infinite bounce between two relays that can hear
  -- each other.
  local seen = {}      -- [channel][t] = true
  local seenOrder = {} -- [channel] = {t, t, t, ...} insertion order, for eviction
  local announced = {} -- [channel] = true once its first message has been logged

  for _, ch in ipairs(CHANNELS) do
    seen[ch] = {}
    seenOrder[ch] = {}
  end

  local function alreadySeen(channel, t)
    return seen[channel][t] == true
  end

  local function markSeen(channel, t)
    seen[channel][t] = true
    table.insert(seenOrder[channel], t)
    if #seenOrder[channel] > SEEN_MAX then
      local oldest = table.remove(seenOrder[channel], 1)
      seen[channel][oldest] = nil
    end
  end

  while true do
    local event, side, channel, replyChannel, message = os.pullEvent("modem_message")

    if seen[channel] and type(message) == "table" and type(message.t) == "number"
      and not alreadySeen(channel, message.t) then
      markSeen(channel, message.t)

      if not announced[channel] then
        log("First message seen on ch.%d (kind=%s) -- relaying", channel, tostring(message.kind))
        announced[channel] = true
      end

      -- Own pcall: one bad transmit (modem detached for an instant)
      -- should skip this one message, not kill the whole relay -- same
      -- per-cycle resilience pattern as every broadcaster in this repo.
      local relayOk, relayErr = pcall(modem.transmit, channel, channel, message)
      if not relayOk then
        log("RELAY ERROR (ch.%d): %s", channel, tostring(relayErr))
      end
    end
  end
end)

if not ok then
  log("CRASHED: %s", tostring(err))
end
