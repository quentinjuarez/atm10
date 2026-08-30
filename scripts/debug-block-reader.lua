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
-- Everything below is ALSO written to debug-output.txt AS IT HAPPENS (not
-- just at the end), so even if something errors partway through, whatever
-- ran before the error is still on disk -- and so is the error itself.
-- The terminal only shows ~19 lines with no scrollback, so read the file
-- instead: `edit debug-output.txt` (scrollable), screenshot it, share
-- the screenshot(s) here.

local OUT_FILE = "debug-output.txt"
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

-- Start the file immediately, before anything that could error, so
-- "edit debug-output.txt" is never blank even if step 1 itself fails.
out("=== debug-block-reader.lua ===")

local ok, err = pcall(function()
  out("")
  out("Attached peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    out("  %s -> %s", name, tostring(peripheral.getType(name)))
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
    return
  end

  out("Block name: %s", tostring(reader.getBlockName()))
  out("")

  out("Block data (NBT):")
  local dataOk, data = pcall(reader.getBlockData)
  if not dataOk then
    out("getBlockData() ERRORED: %s", tostring(data))
  elseif data then
    local serializeOk, serialized = pcall(textutils.serialize, data)
    if serializeOk then
      out(serialized)
    else
      out("textutils.serialize() ERRORED: %s", tostring(serialized))
      out("Raw keys found in the data table instead:")
      for k, v in pairs(data) do
        out("  [%s] (%s) = %s", tostring(k), type(v), tostring(v))
      end
    end
  else
    out("<nil -- block has no tile entity data, or the reader isn't facing it>")
  end
end)

if not ok then
  out("")
  out("SCRIPT CRASHED: %s", tostring(err))
end

print("")
print("Full output is in " .. OUT_FILE .. " -- run: edit " .. OUT_FILE)
