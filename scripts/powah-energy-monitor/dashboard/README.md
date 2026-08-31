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

## ADR: rolling line+area graph + current-hour min/max, computed here not broadcast

**Context.** A single `Total: X FE/t` number doesn't show a trend, and the flow broadcaster already sends a sample every second — there's no need to ask it to also track history or min/max; the dashboard already receives every sample and can keep its own window.

**Decision.** Every `kind="energy_flow"` message appends `{t, value=totalFlowFEt}` to `flowHistory`, trimmed to the last `FLOW_HISTORY_SECONDS` (60s) by timestamp. `hourMin`/`hourMax` track the running min/max of `totalFlowFEt`, reset whenever `floor(epoch_ms / 3600000)` (an hour-bucket number) changes from the previous sample's — pure integer arithmetic, no dependency on `os.date`'s format-string support. `drawGraph()` renders `flowHistory` as a single-line-plus-area chart (see the two ADRs below for the look and the time-based sampling), scaled between `hourMin`/`hourMax` — not a per-frame local min/max of only what's currently visible — so the vertical scale stays stable instead of jumping every redraw.

**Consequences.** The graph and hour min/max reset on every dashboard reboot (no on-disk persistence) — acceptable for "current hour" framing, but a reboot mid-hour loses that hour's earlier extremes. Graph width is whatever the monitor provides; a monitor narrower than ~60 columns compresses the same 60s window into fewer columns (see the sampling ADR below — width no longer has to equal the number of samples received).

## ADR: line+area "trading chart" look, plain color fills only — no character glyphs

**Context.** A first pass at this graph (and the storage bar, and the header) used CP437 block/shade characters (`█`, `░▒▓`, `▀`, box-drawing lines) for a gradient bar and doubled graph resolution. In-game, those characters didn't render as intended — wrong/unfamiliar glyphs instead of blocks and shading. There's no way to screenshot the actual result from here to iterate on which specific glyph is safe, so the fix is to stop depending on font glyphs at all.

**Decision.** Everything visual in this file is now plain ASCII text plus monitor **background-color fills** — a colored space always renders as a solid block on any font/resource pack, unlike a specific character glyph. The graph specifically now draws as one continuous accent line tracing the value over time, with a dim gray fill beneath it (an area chart, like a stock/trading chart) instead of one independently-colored bar per sample — colored by the *latest* value via the same `flowColor()` used everywhere else on screen (lime producing, orange draining, gray idle), not per-column, so it reads as one clean line rather than a multicolor bar chart. A vertical connector between each column and the previous one (`connLow`/`connHigh` in `drawGraph()`) turns the per-column points into a genuinely continuous line even where the value jumps a lot between two samples, instead of looking like disconnected dots.

**Consequences.** Guaranteed to render correctly regardless of font/resource pack, at the cost of losing the sub-row resolution boost the glyph-based version had — an acceptable trade given the glyphs didn't actually work. The storage bar (`drawGradientBar()`) went through the same change: still a 5-band red→orange→yellow→lime→green gauge by position, just drawn with colored spaces instead of `█`/`░` characters.

## ADR: graph sampled by TIME, not by "one column per received message" — fixes visible gaps from dropped broadcasts

**Context.** The energy-detector-broadcaster sends roughly once a second, but a server hiccup can drop a broadcast or a receive. The original `drawGraph()` packed whatever samples were currently in `flowHistory` one-per-column by array index (`idx = n - width + col`) — when a sample was missed, `flowHistory` briefly held fewer entries than the graph was wide, which pulled the whole trace rightward and left a blank margin on the left edge that hadn't been there a moment before: a visible "hole" appearing and disappearing with each dropped tick, even though nothing was actually wrong with the underlying data.

**Decision.** `drawGraph()` no longer maps history entries to columns by index at all. Instead, each column is assigned a fixed point in time (`now - windowMs * (width-col)/width`, evenly spaced across the visible window, rightmost column = now) and its value comes from `valueAt(history, t)`, which **linearly interpolates** between the two stored samples straddling that time — or, for the newest edge (`t` at/after the last sample), **holds the last known value flat**, exactly like a real trading chart between ticks. A dropped broadcast just means the two samples straddling a given column's time are a bit further apart than usual; the interpolated line through that stretch is unaffected.

**Consequences.** The graph now reads as a genuinely continuous trace regardless of receive hiccups — a missed second stretches a line segment slightly, it never produces a gap or a shifting margin. `valueAt()` is a binary search over the time-ordered `flowHistory` array (`O(log n)`), called once per column, so cost stays negligible even redrawn every `REDRAW_SECONDS`. The only remaining "no data" case is the genuine one: columns whose target time predates the very first sample (freshly rebooted, `flowHistory` not yet 60s deep) correctly show as empty, since there's nothing to interpolate from yet.

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

**Decision.** Row 1 is a full-width colored band (blue background) with the title centered, plain text; row 2 is a divider line (plain `-` repeated) with a small clock overlaid on its right end, prefixed by a `*` that alternates lime/green every redraw. The alternation reuses `pulseOn`, a bool flipped once per `render()` call (i.e. once per `REDRAW_SECONDS`) — no extra timer. The same `pulseOn` also drives a slow blink on `NO SIGNAL` (alternating red/gray) instead of a static red line.

**Consequences.** A glance tells you two things a static screen can't: the clock confirms *when* this frame was drawn, and the pulsing dot/blink confirms the loop is still running at all — a genuinely frozen computer (crashed, out of memory) stops pulsing, which a static "NO SIGNAL" text alone wouldn't distinguish from "still updating, still says no signal." Costs one extra bool and two extra monitor writes per redraw (dot + clock), well within the existing REDRAW_SECONDS budget.

## ADR: `drawGraph()`/`drawGradientBar()` batch same-color runs per row instead of one monitor call per cell

**Context.** A naive version of either would loop `width * height` cells and issue `setCursorPos` + `setBackgroundColor` + `write` for *each one* — for a 5×3 monitor at `TEXT_SCALE = 1` (~43×19 characters, roughly an 8-row-tall graph after the rest of the layout), that's on the order of `43 * 8 ≈ 350` monitor peripheral calls in a single graph draw, every redraw. Monitor API calls are real peripheral RPCs, not free function calls, and are the most commonly cited source of "why is my CC:Tweaked script laggy" in practice.

**Decision.** Column heights/colors (`lineRow`/`connLow`/`connHigh` for the graph, the filled/empty split for the bar) are computed once per draw in plain Lua — cheap, no peripheral calls. Each row is then drawn as **runs of contiguous same-color cells**: scan left to right, and only emit `setCursorPos` + `setBackgroundColor` + `write(string.rep(" ", runLength))` when the color changes, covering the whole run in one `write` instead of one per cell.

**Consequences.** A row near the top of the graph — mostly empty "sky," occasionally crossed by the line — collapses to 2-4 calls instead of `width` calls; a busy row full of short alternating runs is the worst case and doesn't improve much, but that's one row out of `height`, not all of them. Combined with the once-per-second redraw cap above, actual monitor call volume in normal operation is a small fraction of the naive per-cell version. The precompute step is pure Lua and doesn't touch the monitor at all, so it's not part of this cost regardless of graph size.
