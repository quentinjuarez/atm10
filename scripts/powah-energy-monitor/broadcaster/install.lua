-- install.lua (broadcaster)
--
-- Run ONCE on the broadcaster computer to install auto-boot:
--   wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/broadcaster/install.lua
--
-- This fetches startup.lua (in this same repo folder) and saves it
-- locally under that exact name -- CC:Tweaked auto-runs any file named
-- "startup.lua" in a computer's root on every boot. You don't need to
-- remember `wget <url> startup.lua` yourself; this does it for you.

local STARTUP_URL = "https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/broadcaster/startup.lua"

if fs.exists("startup.lua") then
  fs.delete("startup.lua")
end

if shell.run("wget", STARTUP_URL, "startup.lua") then
  print("Installed startup.lua -- run 'reboot' to activate it.")
else
  print("Failed to fetch " .. STARTUP_URL)
  print("Check this computer has HTTP access (computercraft-server.toml) and the network is up.")
end
