-- powah-energy-monitor/debug-mekanism-peripheral.lua
--
-- ONE-OFF DIAGNOSTIC, not something to leave running or auto-boot.
--
-- ../debug-induction-reader.lua just showed that a Block Reader facing
-- an Induction Casing only sees generic multiblock bookkeeping
-- (redstone/inventory_id) -- no energy data at all. That data lives in
-- the multiblock's live structure, not in that block's saved NBT, so no
-- field name would ever have worked there.
--
-- Mekanism has its OWN ComputerCraft integration built in (separate
-- from Advanced Peripherals) that can expose a block directly as a
-- peripheral with real callable methods (getEnergy(), etc.) instead of
-- raw NBT -- IF this computer is actually touching/wired to the right
-- block. This dumps every attached peripheral's type AND its full
-- method list, so we can see if that's available here and what it's
-- actually called.
--
-- WIRING FOR THIS TEST: place this computer DIRECTLY ADJACENT to (or on
-- the same Wired Modem network as) an Induction PORT specifically --
-- not a plain Casing. The Port is the block Mekanism actually routes FE
-- in/out through, so it's the most likely one to expose a real
-- peripheral -- a Block Reader isn't needed for this test at all, this
-- checks for a native peripheral connection instead.
--
-- Run with:
--   wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/debug-mekanism-peripheral.lua
--
-- Everything below is ALSO written to debug-mekanism-output.txt AS IT
-- HAPPENS, same reasoning as the other debug-*.lua tools in this folder
-- -- `edit debug-mekanism-output.txt` to read it back, screenshot and
-- share it here.

local OUT_FILE = "debug-mekanism-output.txt"
local outLines = {}

local function out(fmt, ...)
  local line = select("#", ...) > 0 and fmt:format(...) or fmt
  print(line)
  table.insert(outLines, line)
  local f = fs.open(OUT_FILE, "w")
  if f then
    f.write(table.concat(outLines, "\n"))
    f.close()
  end
end

out("=== debug-mekanism-peripheral.lua ===")

local ok, err = pcall(function()
  out("")
  out("Attached peripherals and their methods:")
  local names = peripheral.getNames()
  if #names == 0 then
    out("  <none -- nothing is attached to this computer at all>")
  end
  for _, name in ipairs(names) do
    local ptype = peripheral.getType(name)
    out("")
    out("  %s -> type: %s", name, tostring(ptype))
    local methodsOk, methods = pcall(peripheral.getMethods, name)
    if methodsOk and methods then
      for _, m in ipairs(methods) do
        out("      %s()", m)
      end
    else
      out("      <could not list methods: %s>", tostring(methods))
    end
  end

  out("")
  out("If one of the types/method lists above looks like it's the")
  out("Induction Port (methods like getEnergy/getMaxEnergy/getInput/")
  out("getOutput or similar), that's the peripheral to read directly --")
  out("no Block Reader needed. If nothing here looks energy-related at")
  out("all, this computer probably isn't actually touching/networked to")
  out("the Port block yet -- check placement (adjacent side, or Wired")
  out("Modem + Networking Cable to it, with every modem right-clicked")
  out("once to activate).")
end)

if not ok then
  out("")
  out("SCRIPT CRASHED: %s", tostring(err))
end

print("")
print("Full output is in " .. OUT_FILE .. " -- run: edit " .. OUT_FILE)
print("Share a screenshot of it back.")
