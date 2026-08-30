# Dashboard

Receives both broadcast types — `CELL_CHANNEL` (6701) and `FLOW_CHANNEL` (6702) — renders both on a monitor. See [`../README.md`](../README.md) for the shared three-computer architecture and why each broadcast type gets its own channel.

## Wiring

- **Modem** on any free side — just needs to be in range of both broadcasters' modems, no cable back to either of them. Both channels are opened on this one modem; no second modem needed.
- **Monitor**, either directly adjacent to this computer or over a **Wired Modem + Networking Cable** run if you want the screen elsewhere in the base: a Wired Modem against the computer, one against the monitor, Networking Cable between them, then **right-click every modem once to activate it** (light turns on) — the single most common reason a script reports "no peripheral found."
- **Monitor type.** An Advanced Monitor gives colored fill bars (green/yellow/red by charge level) and colored flow numbers; a plain Monitor works too, just without color — `monitor.isColor()` is checked and adapts automatically.
- **Monitor size.** Built and tested at **5 blocks wide × 3 tall** with `setTextScale(1)` (`TEXT_SCALE` at the top of `run.lua`) — big, legible from a distance, and wide enough for the graph to show close to the full `FLOW_HISTORY_SECONDS` (60s) window. Whatever size you build, `render()` reads `monitor.getSize()` live and lays out (bar, warnings, graph) to fit — no size is hard-coded. Smaller monitors just show a narrower/shorter graph and may clip the per-source breakdown; there's no hard minimum, but a single block at scale 1 (~7×5 chars) is too small to be useful. Bump `TEXT_SCALE` up for even bigger text (at the cost of graph resolution) or down for a wider graph window.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/dashboard/run.lua`.

## ADR: two independent state tracks, dispatched by `kind`

**Context.** `../ender-cell-broadcaster/` and `../energy-detector-broadcaster/` are two separate computers that can crash, lose power, or go out of modem range independently of each other. An earlier version tracked one merged `last` payload from a single combined broadcaster — that stopped working once storage level and flow became genuinely separate broadcasts.

**Decision.** `lastCell`/`lastCellReceivedAt` track the most recent `kind="ender_cell"` message; `lastFlow`/`lastFlowReceivedAt` track the most recent `kind="energy_flow"` message, completely separately. The main loop's `modem_message` handler branches on `message.kind` before touching either track. `render()` draws both sections independently, each with its own "Waiting for signal" (before the first message of that kind ever arrives) and "NO SIGNAL (cell|flow, Ns ago)" (once one goes stale) — never a single combined status for both.

**Consequences.** Losing the Ender Cell broadcaster doesn't blank the flow numbers, and vice versa — you can tell exactly which of the two computers needs attention from the dashboard alone, without checking either broadcaster's own log. Costs two of everything (two "received at" timestamps, two stale checks) instead of one, but that's the point.

## ADR: dynamic row layout, and a capped per-source breakdown

**Context.** The flow broadcaster's `sources` list (see `../energy-detector-broadcaster/README.md`) can hold zero, one, or many Energy Detectors, growing over time as more power sources get built. Combined with the cell section's own variable-length warnings, hard-coded row numbers for everything would collide or leave gaps depending on what showed up in a given render.

**Decision.** `render()` uses a `row` cursor (`writeLine()` returns the next free row) instead of fixed `monitor.setCursorPos(1, <n>)` calls, for both sections. `Total: ... FE/t` shows whenever `totalFlowFEt` is present; the per-source breakdown only renders when there's more than one source (a single source would just repeat what `Total` already says), and is capped at `MAX_SOURCE_LINES = 4` with a `+N more` line past that.

**Consequences.** Works identically whether 0 or many Energy Detectors are attached, and whether either broadcaster is currently reachable — no dashboard change needed as more power sources get built or a broadcaster's wiring changes. Source names are CC:Tweaked's auto-assigned peripheral names (e.g. `energy_detector_0`); `sourceLabel()` shortens the common `_<N>` suffix pattern to `src 0` for a small monitor, falling back to the raw name otherwise.

## ADR: rolling bar graph + current-hour min/max, computed here not broadcast

**Context.** A single `Total: X FE/t` number doesn't show a trend, and the flow broadcaster already sends a sample every second — there's no need to ask it to also track history or min/max; the dashboard already receives every sample and can keep its own window.

**Decision.** Every `kind="energy_flow"` message appends `{t, value=totalFlowFEt}` to `flowHistory`, trimmed to the last `FLOW_HISTORY_SECONDS` (60s) by timestamp. `hourMin`/`hourMax` track the running min/max of `totalFlowFEt`, reset whenever `floor(epoch_ms / 3600000)` (an hour-bucket number) changes from the previous sample's — pure integer arithmetic, no dependency on `os.date`'s format-string support. `drawGraph()` renders `flowHistory` as a bottom-up bar chart, one column per pixel of monitor width, newest sample at the right edge, each bar's height scaled between `hourMin`/`hourMax` (not a per-frame local min/max, so the graph's vertical scale stays stable instead of jumping every redraw) and colored via the same `flowColor()` as everything else.

**Consequences.** The graph and hour min/max reset on every dashboard reboot (no on-disk persistence) — acceptable for "current hour" framing, but a reboot mid-hour loses that hour's earlier extremes. Graph width is whatever the monitor provides; a monitor narrower than ~60 columns shows fewer than 60 seconds of history rather than compressing samples, so the visible window shrinks with a smaller build instead of the graph misleadingly rescaling.

## ADR: no rate/consumption number derived from the cell stream — the flow graph is the one signal for that

**Context.** An earlier version also computed a level-based "FE/s" from consecutive `kind="ender_cell"` readings. It was never a good signal (see `../README.md`'s "why level alone can't show consumption") and duplicated what the flow graph already shows properly — two numbers claiming to answer the same question, one of them near-meaningless, was more confusing than having one.

**Decision.** Dropped entirely — no rate computation, no FE/s display, anywhere in this file. `lastCell` is used only for stored/capacity/fill % and the clamp guard; consumption/production is `lastFlow`'s job alone, shown as `Total: X FE/t` and the graph.

**Consequences.** One fewer thing to read on screen, and no risk of the two numbers disagreeing or confusing which one to trust.

## ADR: `detectAnomaly()` guard, kept even though the clamp bug is fixed upstream

**Context.** Before the Ender Cell broadcaster switched to Block Reader NBT (see `../ender-cell-broadcaster/README.md`), a clamped reading was silently wrong.

**Decision.** `detectAnomaly()` flags NaN, negative values, `energy > maxEnergy`, and the exact clamp signature (`energy == 2147483647` while `maxEnergy` is larger). When triggered, the dashboard shows a `%+ (min)` floor instead of a false precise percentage, with `GUARD: <reason>` on screen. It only applies to the cell stream — flow data from Energy Detectors isn't known to have an equivalent clamp issue.

**Consequences.** Should never fire now that the Ender Cell broadcaster reads raw NBT — kept anyway as defense in depth, in case Powah's data ever changes shape again. Costs nothing to leave in.

## ADR: every `render()` call wrapped in its own `pcall`

**Context.** An earlier version formatted a fractional rate value with `%d`, which CC:Tweaked's Lua runtime rejects for non-integral floats — that crashed the *entire* main loop the first time it happened, freezing the monitor on a stale frame with no further updates or way to tell why. The flow broadcaster's FE/t values are per-tick averages now (see `../energy-detector-broadcaster/README.md`), so `formatFE()` still routinely handles fractional numbers — the `pcall` stays as insurance regardless.

**Decision.** `safeRender()` wraps every `render()` call in its own `pcall`; a failure there logs `RENDER ERROR: ...` and the listening loop keeps running instead of dying.

**Consequences.** A future display bug degrades to "monitor doesn't update, log shows why" instead of "computer silently stops" — a much easier failure to diagnose.

## ADR: bounded log file (50 lines, rewritten in place)

Same reasoning as both broadcasters: only problems get logged (guard transitions, crashes — "no signal" is shown on-screen per-stream, not logged per-tick), and the file is capped so a computer left running for days never slowly fills its disk.

## ADR: redraw only on the timer, never directly on message receipt

**Context.** Both broadcasters transmit roughly once a second, independently of each other and of the redraw timer. The original main loop called `safeRender()` immediately on every `modem_message`, on top of the existing `REDRAW_SECONDS` timer redraw — meaning up to 3 full redraws/sec (1 timer tick + up to 2 message-triggered), each one a `monitor.clear()` and a full re-layout including the graph, whether or not the display had actually changed since the last frame.

**Decision.** `modem_message` handling now only updates state (`lastCell`/`lastFlow`/`flowHistory`/`hourMin`/`hourMax`, guard-transition logging) — it never calls `safeRender()`. Only the `redrawTimer` (still `REDRAW_SECONDS = 1`) draws. A message that just arrived shows up on the *next* tick, at most ~1s later.

**Consequences.** Cuts redraw frequency from up to 3×/s down to a flat 1×/s regardless of how many broadcasters are transmitting or how often — the single biggest lever on total monitor-call volume, since every redraw includes the graph (see the batching ADR below). Trade-off: a state change can sit invisible for up to `REDRAW_SECONDS` before it's drawn, instead of appearing instantly — a non-issue at 1s for a monitor meant to be glanced at, not used as a stopwatch.

## ADR: `drawGraph()` batches same-color runs per row instead of one monitor call per cell

**Context.** The original `drawGraph()` looped `width * height` cells and issued `setCursorPos` + `setBackgroundColor` + `write` for *each one* — for a 5×3 monitor at `TEXT_SCALE = 1` (~43×19 characters, roughly an 8-row-tall graph after the rest of the layout), that's on the order of `43 * 8 * 3 ≈ 1000` monitor peripheral calls in a single graph draw, every redraw. Monitor API calls are real peripheral RPCs, not free function calls, and are the most commonly cited source of "why is my CC:Tweaked script laggy" in practice.

**Decision.** Column heights/colors are computed once per draw in plain Lua (`barHeights`/`colColors` arrays — cheap, no peripheral calls). Each row is then drawn as **runs of contiguous same-color cells**: scan left to right, and only emit `setCursorPos` + `setBackgroundColor` + `write(string.rep(" ", runLength))` when the color changes, covering the whole run in one `write` instead of one per cell.

**Consequences.** A row near the top of a typical bar chart — mostly empty, occasionally interrupted by a tall bar — collapses to 2-4 calls instead of `width` calls; a fully "busy" bottom row with many different-colored short bars is the worst case and doesn't improve much, but that's one row out of `height`, not all of them. Combined with the once-per-second redraw cap above, actual monitor call volume in normal operation is a small fraction of the original per-cell, up-to-3×/sec version. The column-height/color precompute is pure Lua and doesn't touch the monitor at all, so it's not part of this cost regardless of graph size.
