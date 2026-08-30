# ATM10 — CC: Tweaked scripts

Lua scripts for [CC: Tweaked](https://tweaked.cc/) computers/turtles running in an **All the Mods 10** world, plus a [reference doc](#reference-doc) for writing new ones.

## Layout

```
scripts/
├── templates/                  copy-and-customize starting points, not run as-is
│   ├── skeleton.lua               generic tick + event loop, wrapped in pcall
│   ├── sensor-broadcaster.lua     read a peripheral on an interval, broadcast over rednet
│   └── monitor-dashboard.lua      listen for a broadcast, render it on a monitor
└── powah-energy-monitor/        one feature = one top-level folder
    ├── README.md                  shared architecture + decisions for this feature
    ├── debug-block-reader.lua     one-off diagnostic, not for auto-boot
    ├── broadcaster/                one computer = one subfolder
    │   ├── run.lua                   the real logic
    │   ├── startup.lua                fetched by install.lua, saved locally as startup.lua
    │   ├── install.lua                run once: creates startup.lua for you
    │   └── README.md                  wiring + ADR for this computer specifically
    └── dashboard/
        ├── run.lua
        ├── startup.lua
        ├── install.lua
        └── README.md
```

Each feature (a "main function" — right now just the one) gets its own top-level folder under `scripts/`, with one subfolder per computer it needs. Every computer subfolder follows the same three-file pattern: `run.lua` is the actual program, `startup.lua` is what ends up installed as the computer's real `startup.lua`, and `install.lua` is the one-time installer that fetches `startup.lua` and saves it under that exact name — see "Auto-boot" below for why that's a separate step from just running `run.lua`.

Decisions that only make sense for one specific computer live in that computer's own `README.md` (wiring, sizing, why-this-not-that) — this file only covers what's shared across the whole repo. Read [`scripts/powah-energy-monitor/README.md`](./scripts/powah-energy-monitor/README.md), [`.../broadcaster/README.md`](./scripts/powah-energy-monitor/broadcaster/README.md), and [`.../dashboard/README.md`](./scripts/powah-energy-monitor/dashboard/README.md) for the actual build instructions and the reasoning behind them.

## Installing a script in-game

Any `run.lua` (or a template) can be tried directly with CC: Tweaked's built-in `wget`, pointed at this repo's **raw** GitHub URL — no Pastebin involved, so there's no API key to manage and no stale link to fix after an edit (`wget` always re-fetches the current file content):

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/<path>/<file>.lua
```

Everything is pushed straight to `main`, so this URL always serves the current version — no branch name to swap out. For a computer meant to run 24/7, install auto-boot instead (below) rather than re-typing `wget run` after every restart.

### Why not Pastebin?

Pastebin's public API has no "edit an existing paste" endpoint — only create (new URL every time) and delete. A GitHub raw URL updates in place on every push, so it's the more stable choice for a link you `wget` repeatedly. See [`pastebin.com/doc_api`](https://pastebin.com/doc_api).

## Auto-boot

CC:Tweaked runs a file named exactly `startup.lua` in a computer's root automatically on every boot/reboot — that's the entire mechanism, nothing to configure beyond having that file exist. Each computer folder's `startup.lua` just does `wget run <url-to-run.lua>` (with a few retries in case HTTP isn't up yet right after boot), so the computer never runs a stale local copy, same "always fetch from GitHub raw" reasoning as everywhere else in this README.

You don't `wget` that file directly, though — its whole point is to be saved locally under the exact name `startup.lua`, and typing `wget <url> startup.lua` by hand is easy to get wrong. Instead, each computer has an `install.lua` that does that step for you:

```
-- one-time, on each computer:
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/<broadcaster-or-dashboard>/install.lua
```

Then `reboot`. After that, a reboot (or world/server restart) brings the computer back up already running the latest pushed `run.lua` — no need to `wget run` by hand again unless you're actively testing an in-progress change.

## Logs

The `powah-energy-monitor` scripts print problems (crashes, guard warnings, read failures) live to the terminal and also keep a small bounded on-disk log — capped at 50 lines, rewritten in place, so a computer can run for days without slowly filling its disk. Routine successful operation isn't logged, only things worth knowing about — see each computer's README for exactly what triggers a log line.

To read a log after the fact — e.g. to see why a computer isn't broadcasting after you weren't watching it:

```
edit broadcast.log
```

(`edit` is CC:Tweaked's built-in file viewer/editor; there's no separate `cat`/`type` program in the stock ROM. Ctrl+E to exit without saving.)

## Reference doc

[CC: Tweaked Field Guide](https://claude.ai/code/artifact/19b31c6c-5c7c-4c7e-a3de-8683e0c42613) — core Lua APIs, ATM10-specific peripherals (Advanced Peripherals, ME Bridge, RS Bridge...), Pixelbox Lite, and known ATM9→ATM10 API gotchas. Written to be pasted as context when asking for a new script.
