# ATM10 — CC: Tweaked scripts

Lua scripts for [CC: Tweaked](https://tweaked.cc/) computers/turtles running in an **All the Mods 10** world, plus a [reference doc](#reference-doc) for writing new ones.

## Layout

```
scripts/
├── templates/                  copy-and-customize starting points, not run as-is
│   ├── skeleton.lua               generic tick + event loop, wrapped in pcall
│   ├── sensor-broadcaster.lua     read a peripheral on an interval, broadcast over rednet
│   └── monitor-dashboard.lua      listen for a broadcast, render it on a monitor
├── powah-energy-monitor/        one feature = one top-level folder
│   ├── README.md                  shared architecture + decisions for this feature
│   ├── debug-block-reader.lua     one-off diagnostic, not for auto-boot
│   ├── ender-cell-broadcaster/     one computer = one subfolder; storage level only
│   │   ├── run.lua                   the real logic
│   │   ├── startup.lua                fetched by install.lua, saved locally as startup.lua
│   │   ├── install.lua                run once: creates startup.lua for you
│   │   └── README.md                  wiring + ADR for this computer specifically
│   ├── energy-detector-broadcaster/ another computer = another subfolder; FE/t flow only
│   │   ├── run.lua
│   │   ├── startup.lua
│   │   ├── install.lua
│   │   └── README.md
│   └── dashboard/                   receives BOTH broadcast types, renders both
│       ├── run.lua
│       ├── startup.lua
│       ├── install.lua
│       └── README.md
├── photo-viewer/                Single-computer feature -- no subfolder split needed
│   ├── run.lua                     (see this feature's own README for why)
│   ├── startup.lua
│   ├── install.lua
│   ├── README.md
│   ├── manifest.txt                list of image filenames to show, in order
│   └── images/*.nfp                the actual pixel-art images
└── video-player/                Also single-computer
    ├── run.lua
    ├── startup.lua
    ├── install.lua
    ├── README.md
    └── clips/<name>/frames.ccv + audio.dfpwm   one subfolder per clip

tools/                          run on YOUR OWN computer, never in-game
├── README.md                     what these are and why they're not Lua
├── png_to_nfp.py                 photo -> .nfp, for photo-viewer/
└── video_to_ccv.py               video -> frames.ccv + audio.dfpwm, for video-player/
```

Each feature (a "main function") gets its own top-level folder under `scripts/`. A feature that needs multiple independent computers (like `powah-energy-monitor`) splits into one subfolder per computer; a feature that's genuinely one computer (`photo-viewer`, `video-player`) skips that extra nesting and puts `run.lua`/`startup.lua`/`install.lua` directly in the feature folder. Every computer — nested or not — follows the same three-file pattern: `run.lua` is the actual program, `startup.lua` is what ends up installed as the computer's real `startup.lua`, and `install.lua` is the one-time installer that fetches `startup.lua` and saves it under that exact name — see "Auto-boot" below for why that's a separate step from just running `run.lua`.

The two broadcasters are deliberately separate scripts/computers, not one combined one — storage level (Ender Cell) and flow (Energy Detectors) are independent concerns with independent wiring, and can live on different computers if that suits the build. Both broadcast on the same channel; the dashboard tells their messages apart by a `kind` field and tracks each independently, so losing one doesn't blank out the other. See [`powah-energy-monitor/README.md`](./scripts/powah-energy-monitor/README.md)'s ADR for the full reasoning.

Decisions that only make sense for one specific computer live in that computer's own `README.md` (wiring, sizing, why-this-not-that) — this file only covers what's shared across the whole repo. Read [`scripts/powah-energy-monitor/README.md`](./scripts/powah-energy-monitor/README.md) and each computer's own `README.md` for the actual build instructions and the reasoning behind them.

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
-- one-time, on each computer (pick the matching folder):
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/ender-cell-broadcaster/install.lua
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/energy-detector-broadcaster/install.lua
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/install.lua
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/photo-viewer/install.lua
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/video-player/install.lua
```

Then `reboot`. After that, a reboot (or world/server restart) brings the computer back up already running the latest pushed `run.lua` — no need to `wget run` by hand again unless you're actively testing an in-progress change.

## Logs

Every script in this repo prints problems (crashes, guard warnings, read/fetch failures) live to the terminal and also keeps a small bounded on-disk log — capped at 50 lines, rewritten in place, so a computer can run for days without slowly filling its disk. Routine successful operation isn't logged, only things worth knowing about — see each computer's README for exactly what triggers a log line.

To read a log after the fact — e.g. to see why a computer isn't broadcasting after you weren't watching it:

```
edit ender-cell-broadcast.log
```

(`edit` is CC:Tweaked's built-in file viewer/editor; there's no separate `cat`/`type` program in the stock ROM. Ctrl+E to exit without saving.)

## Reference doc

[CC: Tweaked Field Guide](https://claude.ai/code/artifact/19b31c6c-5c7c-4c7e-a3de-8683e0c42613) — core Lua APIs, ATM10-specific peripherals (Advanced Peripherals, ME Bridge, RS Bridge...), Pixelbox Lite, and known ATM9→ATM10 API gotchas. Written to be pasted as context when asking for a new script.
