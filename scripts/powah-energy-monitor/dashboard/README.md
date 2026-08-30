# Dashboard

Receives both broadcast types on `CHANNEL`, renders both on a monitor. See [`../README.md`](../README.md) for the shared three-computer architecture.

## Wiring

- **Modem** on any free side — just needs to be in range of both broadcasters' modems, no cable back to either of them.
- **Monitor**, either directly adjacent to this computer or over a **Wired Modem + Networking Cable** run if you want the screen elsewhere in the base: a Wired Modem against the computer, one against the monitor, Networking Cable between them, then **right-click every modem once to activate it** (light turns on) — the single most common reason a script reports "no peripheral found."
- **Monitor type.** An Advanced Monitor gives colored fill bars (green/yellow/red by charge level) and colored flow numbers; a plain Monitor works too, just without color — `monitor.isColor()` is checked and adapts automatically.
- **Monitor size.** `setTextScale(0.5)` needs up to ~18 rows in the worst case (both streams' warnings plus a full source breakdown). Per the [ComputerCraft resolution reference](https://www.computercraft.info/wiki/Resolution), a single monitor block at scale 0.5 gives roughly **15×10 characters** — not enough anymore. Build **1 block wide × 2 blocks tall** (blocks merge into one screen automatically when placed edge-to-edge): roughly 15×24 characters, comfortable headroom.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/run.lua`.

## ADR: two independent state tracks, dispatched by `kind`

**Context.** `../ender-cell-broadcaster/` and `../energy-detector-broadcaster/` are two separate computers that can crash, lose power, or go out of modem range independently of each other. An earlier version tracked one merged `last` payload from a single combined broadcaster — that stopped working once storage level and flow became genuinely separate broadcasts.

**Decision.** `lastCell`/`previousCell`/`lastCellReceivedAt` track the most recent `kind="ender_cell"` message; `lastFlow`/`lastFlowReceivedAt` track the most recent `kind="energy_flow"` message, completely separately. The main loop's `modem_message` handler branches on `message.kind` before touching either track. `render()` draws both sections independently, each with its own "Waiting for signal" (before the first message of that kind ever arrives) and "NO SIGNAL (cell|flow, Ns ago)" (once one goes stale) — never a single combined status for both.

**Consequences.** Losing the Ender Cell broadcaster doesn't blank the flow numbers, and vice versa — you can tell exactly which of the two computers needs attention from the dashboard alone, without checking either broadcaster's own log. Costs two of everything (two "received at" timestamps, two stale checks) instead of one, but that's the point.

## ADR: dynamic row layout, and a capped per-source breakdown

**Context.** The flow broadcaster's `sources` list (see `../energy-detector-broadcaster/README.md`) can hold zero, one, or many Energy Detectors, growing over time as more power sources get built. Combined with the cell section's own variable-length warnings, hard-coded row numbers for everything would collide or leave gaps depending on what showed up in a given render.

**Decision.** `render()` uses a `row` cursor (`writeLine()` returns the next free row) instead of fixed `monitor.setCursorPos(1, <n>)` calls, for both sections. `Total: ... FE/t` shows whenever `totalFlowFEt` is present; the per-source breakdown only renders when there's more than one source (a single source would just repeat what `Total` already says), and is capped at `MAX_SOURCE_LINES = 4` with a `+N more` line past that.

**Consequences.** Works identically whether 0 or many Energy Detectors are attached, and whether either broadcaster is currently reachable — no dashboard change needed as more power sources get built or a broadcaster's wiring changes. Source names are CC:Tweaked's auto-assigned peripheral names (e.g. `energy_detector_0`); `sourceLabel()` shortens the common `_<N>` suffix pattern to `src 0` for a small monitor, falling back to the raw name otherwise.

## ADR: rate calculated from the broadcaster's timestamps, not receipt time

**Decision.** Each `kind="ender_cell"` payload carries `t = os.epoch("utc")` set by that broadcaster at read time; the level-based FE/s is computed from consecutive `t`/`energy` pairs, not from when this computer happened to receive them.

**Consequences.** Immune to receive-side jitter (event queue delay, redraw timing). Requires the broadcaster and dashboard clocks to agree, which `os.epoch("utc")` guarantees since it's wall-clock, not per-computer uptime.

## ADR: `detectAnomaly()` guard, kept even though the clamp bug is fixed upstream

**Context.** Before the Ender Cell broadcaster switched to Block Reader NBT (see `../ender-cell-broadcaster/README.md`), a clamped reading was silently wrong and, worse, made the FE/s math show a false `0 FE/s` (a clamped value never changes, so the delta between two clamped readings is always zero — indistinguishable from genuinely idle).

**Decision.** `detectAnomaly()` flags NaN, negative values, `energy > maxEnergy`, and the exact clamp signature (`energy == 2147483647` while `maxEnergy` is larger). When triggered, the dashboard shows a `%+ (min)` floor instead of a false precise percentage, and hides FE/s instead of a fake `0 FE/s`, with `GUARD: <reason>` on screen. It only applies to the cell stream — flow data from Energy Detectors isn't known to have an equivalent clamp issue.

**Consequences.** Should never fire now that the Ender Cell broadcaster reads raw NBT — kept anyway as defense in depth, in case Powah's data ever changes shape again. Costs nothing to leave in.

## ADR: every `render()` call wrapped in its own `pcall`

**Context.** An earlier version formatted a fractional FE/s value with `%d`, which CC:Tweaked's Lua runtime rejects for non-integral floats — that crashed the *entire* main loop the first time a rate was computed, freezing the monitor on a stale frame with no further updates or way to tell why.

**Decision.** `safeRender()` wraps every `render()` call in its own `pcall`; a failure there logs `RENDER ERROR: ...` and the listening loop keeps running instead of dying.

**Consequences.** A future display bug degrades to "monitor doesn't update, log shows why" instead of "computer silently stops" — a much easier failure to diagnose.

## ADR: bounded log file (50 lines, rewritten in place)

Same reasoning as both broadcasters: only problems get logged (guard transitions, crashes — "no signal" is shown on-screen per-stream, not logged per-tick), and the file is capped so a computer left running for days never slowly fills its disk.
