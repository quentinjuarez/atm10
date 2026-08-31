# Dashboard

Receives both broadcast types — `CELL_CHANNEL` (6701) and `FLOW_CHANNEL` (6702) — renders both on a monitor. See [`../README.md`](../README.md) for the shared three-computer architecture and why each broadcast type gets its own channel.

## Wiring

- **Modem** on any free side — **must be Wireless or Ender, not Wired**, and needs to be in range of both broadcasters' modems (no cable back to either of them). `run.lua` checks `modem.isWireless()` at startup and refuses to run with a clear error if it's Wired. Both channels are opened on this one modem; no second modem needed.
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

## ADR: colored header band + live pulse, instead of a plain title line

**Context.** The original first line was plain white text, "POWAH Energy Monitor" — functional, but gave no sense of the display being *alive*, and didn't visually separate "chrome" from data the way a real dashboard does.

**Decision.** Row 1 is a full-width colored band (blue background) with the title centered and flanked by `▓` flourishes (CP437 char 178 — see the char-set note below); row 2 is a divider line (`─`, char 196) with a small clock overlaid on its right end, prefixed by a `*` that alternates lime/green every redraw. The alternation reuses `pulseOn`, a bool flipped once per `render()` call (i.e. once per `REDRAW_SECONDS`) — no extra timer. The same `pulseOn` also drives a slow blink on `NO SIGNAL` (alternating red/gray) instead of a static red line.

**Consequences.** A glance tells you two things a static screen can't: the clock confirms *when* this frame was drawn, and the pulsing dot/blink confirms the loop is still running at all — a genuinely frozen computer (crashed, out of memory) stops pulsing, which a static "NO SIGNAL" text alone wouldn't distinguish from "still updating, still says no signal." Costs one extra bool and two extra monitor writes per redraw (dot + clock), well within the existing REDRAW_SECONDS budget.

## ADR: CP437 block/shade characters for a gradient "fuel gauge" bar and a half-resolution graph

**Context.** CC:Tweaked's monitor font is the same extended-ASCII (CP437) bitmap font classic ComputerCraft has always shipped — block characters (`█` 219), shade textures (`░▒▓` 176-178), and half-height blocks (`▀` 223, upper half in the foreground color, lower half in the background color) render identically to how they've worked in CC community UIs for years. The original storage bar was a single flat color for the whole fill (red/yellow/green from `barColor()`, one color chosen by the *current* pct) on a solid black empty track; the graph drew one flat-colored cell per history sample, so a bar's height only ever landed on a whole terminal row.

**Decision.** Two independent uses of that character range, both kept inside `CH` (a small constants table — deliberately *not* using riskier 1-31 control-range glyphs or box-drawing corners, since there's no way to screenshot the actual in-game result from here to confirm a less-common glyph renders as expected):
- The storage bar (`drawGradientBar()`) is now a fixed 5-band red→orange→yellow→lime→green gauge track by **position**, not by current value — like a car's fuel gauge, always red-at-empty/green-at-full regardless of where the fill currently ends. The empty portion is a dim `░` texture instead of flat black, so a low/empty bar still visibly reads as "a gauge," not "nothing drew." `statusColor()` (the old `barColor()`, renamed) keeps `CONFIG.warn_below_pct`/`ok_below_pct` meaningful by coloring the pct *text* by current-value threshold instead — decorative bar, functional text, not conflated into one color scheme.
- The graph (`drawGraph()`) doubles its own vertical resolution using `▀`: each terminal row can show two independently-colored half-height pixels (foreground = top half, background = bottom half) instead of one flat cell, so a bar's top edge lands on the nearest half-row instead of the nearest whole row — visibly smoother on a graph that's only a handful of rows tall, at zero extra monitor-row cost.

**Consequences.** Both stay inside the same-appearance-run batching this file already relies on (see the ADR below) — the gauge is at most 5 fill runs + 1 empty run per row regardless of monitor width, and the half-block graph is still one run per contiguous same-(top,bottom) span, not one call per column. If a future monitor/resource-pack font doesn't render one of these glyphs as expected, it degrades to an unfamiliar-but-harmless symbol, not a crash — nothing here is load-bearing for functionality, only for looks.

## ADR: `drawGraph()` batches same-color runs per row instead of one monitor call per cell

**Context.** The original `drawGraph()` looped `width * height` cells and issued `setCursorPos` + `setBackgroundColor` + `write` for *each one* — for a 5×3 monitor at `TEXT_SCALE = 1` (~43×19 characters, roughly an 8-row-tall graph after the rest of the layout), that's on the order of `43 * 8 * 3 ≈ 1000` monitor peripheral calls in a single graph draw, every redraw. Monitor API calls are real peripheral RPCs, not free function calls, and are the most commonly cited source of "why is my CC:Tweaked script laggy" in practice.

**Decision.** Column heights/colors are computed once per draw in plain Lua (`barSubHeights`/`colColors` arrays — cheap, no peripheral calls). Each row is then drawn as **runs of contiguous same-appearance cells**: scan left to right, and only emit `setCursorPos` + color set(s) + one `write()` when the appearance changes (a plain colored space for a flat run, or the `▀` half-block character with two colors set when the run's top/bottom halves differ — see the gradient/half-block ADR above), covering the whole run in one `write` instead of one per cell.

**Consequences.** A row near the top of a typical bar chart — mostly empty, occasionally interrupted by a tall bar — collapses to 2-4 calls instead of `width` calls; a fully "busy" bottom row with many different-colored short bars is the worst case and doesn't improve much, but that's one row out of `height`, not all of them. Combined with the once-per-second redraw cap above, actual monitor call volume in normal operation is a small fraction of the original per-cell, up-to-3×/sec version. The column-height/color precompute is pure Lua and doesn't touch the monitor at all, so it's not part of this cost regardless of graph size.
