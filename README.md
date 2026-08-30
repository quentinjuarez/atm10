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
| [`scripts/powah-ender-cell-dashboard.lua`](./scripts/powah-ender-cell-dashboard.lua) | Ready to use | Live energy dashboard for a POWAH Ender Cell (any tier, incl. Nitro), read via Advanced Peripherals' `ender_cell` peripheral and rendered on a monitor: stored/capacity, fill %, FE/s rate |

Templates are meant to be copied and customized, not run as-is — each one lists what to check before use (peripheral side/name, exact API method names, protocol string). "Ready to use" scripts still discover their peripherals by type at startup and fail with a clear error if something expected isn't attached, rather than assuming a side/slot.

### In-game setup — `powah-ender-cell-dashboard.lua`

**Computer.** A plain Computer is enough (no touch input is used). It reads peripherals by *type*, not by side, so placement is flexible as long as it can reach both the Ender Cell and the monitor, either:

- **directly adjacent** — touching any of the computer's 6 faces, or
- **over a Wired Modem network** — place a Wired Modem against the computer and one against each peripheral, connect them with Networking Cable, then **right-click every modem once to activate it** (its light turns on). Until activated, the modem is invisible to `peripheral.find` — the single most common reason this script reports "no peripheral found." This also means the Ender Cell can stay in a power room while the monitor is mounted somewhere visible.

**Monitor type.** An Advanced Monitor gives colored fill bars (green/yellow/red by charge level); a plain Monitor still works, just without color — the script checks `monitor.isColor()` and adapts automatically.

**Monitor size.** The script sets `setTextScale(0.5)` and needs about 10 rows of text plus a bit of width for the bar. Per the [ComputerCraft resolution reference](https://www.computercraft.info/wiki/Resolution), at scale 0.5 a single monitor block gives roughly **15×10 characters** — technically enough, but with zero margin for anything added later. Build **1 block wide × 2 blocks tall** instead: monitor blocks placed edge-to-edge on the same plane merge into one screen automatically (no interaction needed), giving roughly 15×24 characters — comfortable headroom.

## Reference doc

[CC: Tweaked Field Guide](https://claude.ai/code/artifact/19b31c6c-5c7c-4c7e-a3de-8683e0c42613) — core Lua APIs, ATM10-specific peripherals (Advanced Peripherals, ME Bridge, RS Bridge...), Pixelbox Lite, and known ATM9→ATM10 API gotchas. Written to be pasted as context when asking for a new script.
