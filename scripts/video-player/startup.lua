-- startup.lua (video-player)
--
-- Don't wget this directly -- run install.lua in this same folder, which
-- fetches this file and saves it locally AS "startup.lua". CC:Tweaked
-- auto-runs a file with exactly that name on every boot/reboot.
--
-- Once installed, this re-fetches and runs the CURRENT run.lua straight
-- from GitHub every time -- this computer never keeps or runs a stale
-- local copy of the real logic, same reasoning as the repo root README's
-- "why not Pastebin" section.

local URL = "https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/video-player/run.lua"
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
