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

Templates are meant to be copied and customized, not run as-is — each one lists what to check before use (peripheral side/name, exact API method names, protocol string).

## Reference doc

[CC: Tweaked Field Guide](https://claude.ai/code/artifact/19b31c6c-5c7c-4c7e-a3de-8683e0c42613) — core Lua APIs, ATM10-specific peripherals (Advanced Peripherals, ME Bridge, RS Bridge...), Pixelbox Lite, and known ATM9→ATM10 API gotchas. Written to be pasted as context when asking for a new script.
