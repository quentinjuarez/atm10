-- debug-block-reader.lua
--
-- ONE-OFF DIAGNOSTIC, not something to leave running or auto-boot.
--
-- Advanced Peripherals' ender_cell.getEnergy() clamps to the 32-bit
-- signed max (2147483647) on cells/networks storing more (see the header
-- comment in ender-cell-broadcaster.lua). This dumps whatever the Block
-- Reader peripheral sees on the block it's facing, to check whether the
-- raw NBT contains an unclamped value we could read instead.
--
-- WIRING: place a Block Reader (Advanced Peripherals) so it's FACING the
-- Ender Cell -- it reads whatever block is directly in front of it, not
-- its own block.
--
-- Run with:
--   wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/debug-block-reader.lua
--
-- Everything below is also written to debug-output.txt, because the
-- terminal only shows ~19 lines with no scrollback, so a longer dump
-- will scroll past before you can read it. After running this:
--   edit debug-output.txt
-- and screenshot it (scroll with arrow keys if it doesn't fit one
-- screen), then share the screenshot(s) here.

local OUT_FILE = "debug-output.txt"
local outLines = {}

local function out(fmt, ...)
  local line = select("#", ...) > 0 and fmt:format(...) or fmt
  print(line)
  table.insert(outLines, line)
end

out("Attached peripherals:")
for _, name in ipairs(peripheral.getNames()) do
  out("  %s -> %s", name, peripheral.getType(name))
end
out("")

-- Advanced Peripherals' own docs use "block_reader" as the type name
-- (matching their snake_case convention, e.g. "ender_cell"), but that's
-- not independently confirmed against your exact AP version -- if this
-- comes back nil, check the peripheral list above for the real type name.
local reader = peripheral.find("block_reader")
if not reader then
  out("No 'block_reader' peripheral found under that exact type name.")
  out("Check the list above for the real type name of your Block Reader.")
else
  out("Block name: %s", tostring(reader.getBlockName()))
  out("")
  out("Block data (NBT):")
  local data = reader.getBlockData()
  if data then
    out(textutils.serialize(data))
  else
    out("<nil -- block has no tile entity data, or the reader isn't facing it>")
  end
end

local f = fs.open(OUT_FILE, "w")
if f then
  f.write(table.concat(outLines, "\n"))
  f.close()
  print("")
  print("Full output written to " .. OUT_FILE .. " -- run: edit " .. OUT_FILE)
end
