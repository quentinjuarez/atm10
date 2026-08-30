-- skeleton.lua
-- Generic CC: Tweaked program skeleton: timed tick + event loop, wrapped in
-- pcall so an unhandled error prints instead of silently killing the program.
-- Copy this file, rename it, and fill in onTick/onEvent for a new script.

local RUNNING = true

local function onTick()
  -- periodic work goes here
end

local function onEvent(event, ...)
  if event == "modem_message" then
    local side, channel, reply, message = ...
    -- handle incoming message
  elseif event == "terminate" then
    RUNNING = false
  end
end

local ok, err = pcall(function()
  local timer = os.startTimer(1)
  while RUNNING do
    local event, a, b, c, d = os.pullEvent()
    if event == "timer" and a == timer then
      onTick()
      timer = os.startTimer(1)
    else
      onEvent(event, a, b, c, d)
    end
  end
end)

if not ok then
  print("Crashed: " .. tostring(err))
end
