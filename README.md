# ATM10 — CC: Tweaked scripts

Lua scripts for [CC: Tweaked](https://tweaked.cc/) computers/turtles running in an **All the Mods 10** world, plus a [reference doc](#reference-doc) for writing new ones.

## Installing a script in-game

Each file in [`scripts/`](./scripts) is installed with CC: Tweaked's built-in `wget`, pointed at this repo's **raw** GitHub URL — no Pastebin involved, so there's no API key to manage and no stale link to fix after an edit (`wget` always re-fetches the current file content):

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/<file>.lua
```

Everything is pushed straight to `main`, so this URL always serves the current version of a script — no branch name to swap out.

### Why not Pastebin?

Pastebin's public API has no "edit an existing paste" endpoint — only create (new URL every time) and delete. A GitHub raw URL updates in place on every push, so it's the more stable choice for a link you `wget` repeatedly. See [`pastebin.com/doc_api`](https://pastebin.com/doc_api).

## Scripts

| File | Status | Purpose |
|---|---|---|
| [`scripts/skeleton.lua`](./scripts/skeleton.lua) | Template | Starting point for a new script: timed tick + event loop, wrapped in `pcall` |
| [`scripts/sensor-broadcaster.lua`](./scripts/sensor-broadcaster.lua) | Template | Reads a peripheral on an interval, broadcasts the reading over `rednet` |
| [`scripts/monitor-dashboard.lua`](./scripts/monitor-dashboard.lua) | Template | Listens for a broadcast and renders it on a monitor |
| [`scripts/ender-cell-broadcaster.lua`](./scripts/ender-cell-broadcaster.lua) | Ready to use | Reads a POWAH Ender Cell's raw NBT via a Block Reader (no int32 clamp), broadcasts stored/max energy over a modem on a fixed channel |
| [`scripts/powah-ender-cell-dashboard.lua`](./scripts/powah-ender-cell-dashboard.lua) | Ready to use | Receives that broadcast and renders it on a monitor: stored/capacity, fill %, FE/s rate, "no signal" state if the broadcaster goes quiet |
| [`scripts/startup-broadcaster.lua`](./scripts/startup-broadcaster.lua) | Install as `startup.lua` | Auto-runs `ender-cell-broadcaster.lua` fresh from GitHub on every boot of the broadcaster computer |
| [`scripts/startup-dashboard.lua`](./scripts/startup-dashboard.lua) | Install as `startup.lua` | Auto-runs `powah-ender-cell-dashboard.lua` fresh from GitHub on every boot of the dashboard computer |
| [`scripts/debug-block-reader.lua`](./scripts/debug-block-reader.lua) | One-off diagnostic | Dumps a Block Reader's peripheral list and NBT view of the block it faces — not meant to be left running |

Templates are meant to be copied and customized, not run as-is — each one lists what to check before use (peripheral side/name, exact API method names, protocol string). "Ready to use" scripts still discover their peripherals by type at startup and fail with a clear error if something expected isn't attached, rather than assuming a side/slot.

This is a **two-computer setup**: one computer sits on the Ender Cell and broadcasts, a separate computer (anywhere in modem range) receives and drives the monitor. Both scripts hard-code `CHANNEL = 6060` at the top — if you change it, change it in both files, or the dashboard will sit at "Waiting for signal" forever.

### The int32 energy clamp, and how it's avoided

Advanced Peripherals' `ender_cell.getEnergy()` clamps to the 32-bit signed max (`2147483647`, ~2.15B FE) for a cell/network storing more than that — confirmed upstream at [IntelligenceModding/AdvancedPeripherals#642](https://github.com/IntelligenceModding/AdvancedPeripherals/issues/642), and confirmed directly against this world with `scripts/debug-block-reader.lua` on a `powah:ender_cell_nitro`. That method's return value is a dead end once clamped — the true number is already lost before it reaches Lua, so there's no way to ask it for something more precise.

Instead, `ender-cell-broadcaster.lua` reads the Ender Cell's raw NBT through Advanced Peripherals' **Block Reader** peripheral, which isn't limited to a 32-bit int. `debug-block-reader.lua`'s dump confirmed the exact fields: `energy_stored_main_energy` and `energy_capacity_main_energy`, both well past int32 range with no clamping. If a future Powah/Advanced Peripherals update renames these, re-run `debug-block-reader.lua` and update the two constants at the top of the broadcaster.

`powah-ender-cell-dashboard.lua`'s guard (`detectAnomaly`) still checks for the old clamp signature as defense in depth — it shouldn't ever trigger reading raw NBT, but costs nothing to keep.

### Wiring

**Broadcaster computer** (`ender-cell-broadcaster.lua`):
- **A Block Reader (Advanced Peripherals) placed facing the Ender Cell** — it reads whatever block is directly in front of it, not its own block. Use the same placement that worked for `debug-block-reader.lua` if you ran that first.
- **A modem on any other free side** — no cable needed, it talks over the air:
  - **Wireless Modem** if the dashboard is going to be somewhere in the same base/render distance.
  - **Ender Modem** if the dashboard is far away or in another dimension — unlimited range, no line-of-sight or distance limit, but costs more to craft.

**Dashboard computer** (`powah-ender-cell-dashboard.lua`):
- **A modem on any free side** — same type consideration as above; it just needs to be in range of the broadcaster's modem. No cable back to the broadcaster, they talk wirelessly on `CHANNEL`.
- **Monitor**, either directly adjacent to this computer or over a **Wired Modem + Networking Cable** run if you want the screen somewhere else in the base: a Wired Modem against the computer, a Wired Modem against the monitor, Networking Cable between them, then **right-click every modem once to activate it** (light turns on) — the single most common reason a script reports "no peripheral found."

Neither computer needs to touch the other one — the only link between them is the modem channel.

**Monitor type.** An Advanced Monitor gives colored fill bars (green/yellow/red by charge level); a plain Monitor still works, just without color — the script checks `monitor.isColor()` and adapts automatically.

**Monitor size.** The script sets `setTextScale(0.5)` and needs about 10 rows of text plus a bit of width for the bar. Per the [ComputerCraft resolution reference](https://www.computercraft.info/wiki/Resolution), at scale 0.5 a single monitor block gives roughly **15×10 characters** — technically enough, but with zero margin for anything added later. Build **1 block wide × 2 blocks tall** instead: monitor blocks placed edge-to-edge on the same plane merge into one screen automatically (no interaction needed), giving roughly 15×24 characters — comfortable headroom.

### Logs

Both `ender-cell-broadcaster.lua` and `powah-ender-cell-dashboard.lua` print every transmit/receive (and any crash) to the computer's own terminal live, and also keep the same lines in a small on-disk log — `broadcast.log` on the broadcaster, `dashboard.log` on the dashboard. The file is capped at the last 50 lines (rewritten in place each time, oldest line dropped first), so it can run for days at 1 message/sec without slowly eating the computer's disk space.

To read a log after the fact — e.g. to see why a computer isn't broadcasting after you weren't watching it — open the computer's shell and run:

```
edit broadcast.log
```

(`edit` is CC:Tweaked's built-in file viewer/editor; there's no separate `cat`/`type` program in the stock ROM. Ctrl+E to exit without saving.)

### Auto-boot

CC:Tweaked runs a file named exactly `startup.lua` in a computer's root automatically on every boot/reboot — that's the entire mechanism, nothing to configure beyond having that file exist. [`startup-broadcaster.lua`](./scripts/startup-broadcaster.lua) and [`startup-dashboard.lua`](./scripts/startup-dashboard.lua) are meant to be installed *as* `startup.lua` on their respective computers; each one just does `wget run <url>` against the real script (with a few retries in case HTTP isn't up yet right after boot) — so the computer never runs a stale local copy, the same "always fetch from GitHub raw" reasoning as everywhere else in this README.

One-time install per computer:

```
-- on the broadcaster computer
wget https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/startup-broadcaster.lua startup.lua

-- on the dashboard computer
wget https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/startup-dashboard.lua startup.lua
```

After that, `reboot` (or a world/server restart) brings each computer back up already running the latest pushed version — no need to `wget run` by hand again unless you're actively testing changes.

## Reference doc

[CC: Tweaked Field Guide](https://claude.ai/code/artifact/19b31c6c-5c7c-4c7e-a3de-8683e0c42613) — core Lua APIs, ATM10-specific peripherals (Advanced Peripherals, ME Bridge, RS Bridge...), Pixelbox Lite, and known ATM9→ATM10 API gotchas. Written to be pasted as context when asking for a new script.
