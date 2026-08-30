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
-- Then share everything it prints (the peripheral list and the NBT dump)
-- so the broadcaster can be updated if a usable field is actually there.

print("Attached peripherals:")
for _, name in ipairs(peripheral.getNames()) do
  print(("  %s -> %s"):format(name, peripheral.getType(name)))
end
print("")

-- Advanced Peripherals' own docs use "block_reader" as the type name
-- (matching their snake_case convention, e.g. "ender_cell"), but that's
-- not independently confirmed against your exact AP version -- if this
-- comes back nil, check the peripheral list printed above for the real
-- type name.
local reader = peripheral.find("block_reader")
if not reader then
  print("No 'block_reader' peripheral found under that exact type name.")
  print("Check the list above for the real type name of your Block Reader.")
  return
end

print("Block name: " .. tostring(reader.getBlockName()))
print("")
print("Block data (NBT):")
local data = reader.getBlockData()
if data then
  print(textutils.serialize(data))
else
  print("<nil -- block has no tile entity data, or the reader isn't facing it>")
end
