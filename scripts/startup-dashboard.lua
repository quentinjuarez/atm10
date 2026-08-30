-- startup-dashboard.lua
--
-- Install this AS "startup.lua" on the dashboard computer so it runs
-- automatically on every boot/reboot. It re-fetches and runs the CURRENT
-- powah-ender-cell-dashboard.lua straight from GitHub every time -- this
-- computer never keeps or runs a stale local copy of the real logic,
-- same reasoning as the README's "why not Pastebin" section.
--
-- One-time install, run once in this computer's shell:
--   wget https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/startup-dashboard.lua startup.lua
--
-- After that, "reboot" (or a power cycle) re-runs this file automatically
-- -- that's CC:Tweaked's startup.lua convention, nothing extra to configure.

local URL = "https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-ender-cell-dashboard.lua"
local MAX_ATTEMPTS = 5
local RETRY_SECONDS = 3

for attempt = 1, MAX_ATTEMPTS do
  if shell.run("wget", "run", URL) then
    return
  end
  print(("wget failed (%d/%d), retrying in %ds..."):format(attempt, MAX_ATTEMPTS, RETRY_SECONDS))
  os.sleep(RETRY_SECONDS)
end

print("Could not fetch " .. URL)
print("Check this computer has HTTP access (computercraft-server.toml) and the network is up.")
