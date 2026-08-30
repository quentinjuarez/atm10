# Dashboard

Receives the broadcast on `CHANNEL`, renders it on a monitor. See [`../README.md`](../README.md) for the shared two-computer architecture.

## Wiring

- **Modem** on any free side — just needs to be in range of the broadcaster's modem, no cable back to it.
- **Monitor**, either directly adjacent to this computer or over a **Wired Modem + Networking Cable** run if you want the screen elsewhere in the base: a Wired Modem against the computer, one against the monitor, Networking Cable between them, then **right-click every modem once to activate it** (light turns on) — the single most common reason a script reports "no peripheral found."
- **Monitor type.** An Advanced Monitor gives colored fill bars (green/yellow/red by charge level); a plain Monitor works too, just without color — `monitor.isColor()` is checked and adapts automatically.
- **Monitor size.** `setTextScale(0.5)` needs about 10 rows of text plus bar width. Per the [ComputerCraft resolution reference](https://www.computercraft.info/wiki/Resolution), a single monitor block at scale 0.5 gives roughly **15×10 characters** — technically enough, zero margin. Build **1 block wide × 2 blocks tall** instead (blocks merge into one screen automatically when placed edge-to-edge): roughly 15×24 characters, comfortable headroom.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/run.lua`.

## ADR: dynamic row layout, and optional Reactor/flow lines

**Context.** Once the broadcaster started optionally sending `reactorRunning` and `flowFEt` (see `../broadcaster/README.md`), hard-coded row numbers for everything below the bar would either collide or leave gaps depending on which optional fields showed up in a given payload.

**Decision.** `render()` uses a `row` cursor (`writeLine()` returns the next free row) instead of fixed `monitor.setCursorPos(1, <n>)` calls. Reactor state and flow only take a line when `last.reactorRunning`/`last.flowFEt` are actually present; everything after them (blank line, `GUARD:`, `NO SIGNAL`) shifts automatically.

**Consequences.** Works identically whether 0, 1, or both optional peripherals are attached — no dashboard change needed as you add an Energy Detector or Reactor link later. Worst case (guard *and* stale *and* both optional lines) is 13 rows, still comfortably inside the 24-row recommendation below.

## ADR: rate calculated from the broadcaster's timestamps, not receipt time

**Decision.** Each payload carries `t = os.epoch("utc")` set by the broadcaster at read time; FE/s is computed from consecutive `t`/`energy` pairs, not from when this computer happened to receive them.

**Consequences.** Immune to receive-side jitter (event queue delay, redraw timing). Requires the two computers' clocks to agree, which `os.epoch("utc")` guarantees since it's wall-clock, not per-computer uptime.

## ADR: `detectAnomaly()` guard, kept even though the clamp bug is fixed upstream

**Context.** Before the broadcaster switched to Block Reader NBT (see `../broadcaster/README.md`), a clamped reading was silently wrong and, worse, made the FE/s math show a false `0 FE/s` (a clamped value never changes, so the delta between two clamped readings is always zero — indistinguishable from genuinely idle).

**Decision.** `detectAnomaly()` flags NaN, negative values, `energy > maxEnergy`, and the exact clamp signature (`energy == 2147483647` while `maxEnergy` is larger). When triggered, the dashboard shows a `%+ (min)` floor instead of a false precise percentage, and hides FE/s instead of a fake `0 FE/s`, with `GUARD: <reason>` on screen.

**Consequences.** Should never fire now that the broadcaster reads raw NBT — kept anyway as defense in depth, in case Powah's data ever changes shape again. Costs nothing to leave in.

## ADR: every `render()` call wrapped in its own `pcall`

**Context.** An earlier version formatted a fractional FE/s value with `%d`, which CC:Tweaked's Lua runtime rejects for non-integral floats — that crashed the *entire* main loop the first time a rate was computed, freezing the monitor on a stale frame with no further updates or way to tell why.

**Decision.** `safeRender()` wraps every `render()` call in its own `pcall`; a failure there logs `RENDER ERROR: ...` and the listening loop keeps running instead of dying.

**Consequences.** A future display bug degrades to "monitor doesn't update, log shows why" instead of "computer silently stops" — a much easier failure to diagnose.

## ADR: bounded log file (50 lines, rewritten in place)

Same reasoning as the broadcaster: only problems get logged (guard transitions, "no signal" is shown on-screen not logged per-tick, crashes), and the file is capped so a computer left running for days never slowly fills its disk.
