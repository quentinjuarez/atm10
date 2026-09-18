-- powah-energy-monitor/debug-induction-reader.lua
--
-- ONE-OFF DIAGNOSTIC, not something to leave running or auto-boot.
--
-- ../induction-broadcaster/run.lua reads a Mekanism Induction Matrix
-- casing's raw NBT for capacity/stored/input/output -- but unlike
-- Powah's Ender Cell (confirmed via ../debug-block-reader.lua before
-- ../ender-cell-broadcaster/ was written), Mekanism's exact NBT field
-- names for the induction matrix haven't been confirmed against a live
-- block yet. induction-broadcaster/run.lua tries a handful of plausible
-- field names itself and dumps everything it sees if none of them
-- match -- but running this FIRST, before wiring up the full
-- broadcaster, is the faster way to get the real names in one shot.
--
-- WIRING: place a Block Reader (Advanced Peripherals) FACING the
-- Induction Casing -- it reads whatever block is directly in front of
-- it, not its own block.
--
-- Run with:
--   wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/debug-induction-reader.lua
--
-- Everything below is ALSO written to debug-induction-output.txt AS IT
-- HAPPENS (not just at the end), so even if something errors partway
-- through, whatever ran before the error is still on disk -- and so is
-- the error itself. The terminal only shows ~19 lines with no
-- scrollback, so read the file instead: `edit debug-induction-output.txt`
-- (scrollable), screenshot it, share the screenshot(s) here.

local OUT_FILE = "debug-induction-output.txt"
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
-- "edit debug-induction-output.txt" is never blank even if step 1 fails.
out("=== debug-induction-reader.lua ===")

local ok, err = pcall(function()
  out("")
  out("Attached peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    out("  %s -> %s", name, tostring(peripheral.getType(name)))
  end
  out("")

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

    -- Mekanism stores large energy values in its own "FloatingLong" type,
    -- which MIGHT serialize as a nested table (e.g. two longs) rather
    -- than a single plain number -- if any top-level value here is a
    -- table, dump one level deeper too, since that's likely where an
    -- energy value's actual number(s) are hiding.
    out("")
    out("One level deeper into any nested table values (in case an")
    out("energy value isn't a plain number):")
    local foundNested = false
    for k, v in pairs(data) do
      if type(v) == "table" then
        foundNested = true
        out("  [%s] is a table:", tostring(k))
        for k2, v2 in pairs(v) do
          out("    [%s] (%s) = %s", tostring(k2), type(v2), tostring(v2))
        end
      end
    end
    if not foundNested then
      out("  (no nested tables found -- every top-level value is a plain number/string/boolean)")
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
print("Share a screenshot of it back, or tell me the field names you see")
print("for capacity / stored energy / input rate / output rate.")
