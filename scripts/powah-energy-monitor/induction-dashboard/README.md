# Induction dashboard

Receives [`../induction-broadcaster/`](../induction-broadcaster/)'s single `kind="induction_matrix"` message on `CHANNEL` (6703) **only**, and renders everything it carries — net flow, input/output breakdown, transfer cap, storage, and charge/discharge ETA. A separate dashboard from [`../dashboard/`](../dashboard/) (which still serves the Powah Ender Cell + Energy Detector pair on channels 6701/6702, unchanged) — see [`../README.md`](../README.md) for how the two setups relate, and `../induction-broadcaster/README.md`'s ADR for why this isn't just a change to the existing dashboard.

## Wiring

- **Modem** on any free side — **must be Wireless or Ender, not Wired**, in range of the induction-broadcaster computer. `run.lua` checks `modem.isWireless()` at startup.
- **Advanced Monitor** recommended (color); a plain Monitor works too, just grayscale.
- No other peripheral needed — this computer only receives and displays.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/induction-dashboard/install.lua
```

Then `reboot` to activate `startup.lua`.

## ADR: one state track, not two

**Context.** `../dashboard/` tracks `lastCell`/`lastFlow` independently because Powah's setup is genuinely two computers that can fail separately. `induction-broadcaster/` is one computer reading one Induction Port — there's only one thing that can go stale.

**Decision.** A single `last`/`lastReceivedAt` pair, one `NO SIGNAL` check, one `Waiting for signal` state. No `kind` dispatch needed either, since only one message kind (`induction_matrix`) is ever expected on this channel.

**Consequences.** Considerably simpler than `../dashboard/`'s dual-track code — appropriate here since the underlying data source really is single-sourced, not a simplification that loses real information.

## ADR: shows everything the broadcaster sends — percentage, transfer cap, and charge/discharge ETA

**Context.** `../dashboard/` deliberately shows nothing beyond storage % and net flow, because that's all Powah's two broadcasters ever had to give it. The Induction Port hands over more for free: `getEnergyFilledPercentage()`, `getTransferCap()`, and (derived by the broadcaster) a measured charge/discharge rate — leaving any of it out would be throwing away information the hardware already provides at no extra cost.

**Decision.** The screen shows, top to bottom: net flow (biggest, first, with the live pulse), an input/output breakdown line, the transfer cap (`max IO`), storage %/energy, the storage gauge, and a charge/discharge line with ETA (`formatDuration()` — H:MM:SS, or `Xd Xh` past a day) computed from `induction-broadcaster`'s measured `changePerSecond`/`etaSeconds`. The graph still plots net flow over time, same continuity/rendering approach as `../dashboard/`.

**Consequences.** More on screen than `../dashboard/` for the same monitor size — acceptable since Induction Matrix users get a strictly richer data source and asked for it to be used, not held back to match Powah's simpler one. `percentage` is used as broadcast (Mekanism's own computation) rather than re-derived from `energy/maxEnergy` here, so it stays consistent with what the block's own GUI would show even in an edge case where the two might differ slightly.

## ADR: rendering code carried over verbatim from `../dashboard/`, not shared via a library

**Context.** `drawGradientBar()`, `valueAt()`, and `drawGraph()` are identical to `../dashboard/run.lua`'s — same steampunk look, same time-based graph continuity, same performance-conscious row-batching. There's no principled reason to reimplement proven, already-tested code differently here.

**Decision.** Copied as-is rather than factored into a shared module — consistent with every other script in this repo, which is deliberately self-contained so a single `wget run <url>` always fetches everything a computer needs in one file, with nothing to keep in sync across a shared library at install time.

**Consequences.** A future visual change to one dashboard's graph/gauge doesn't automatically apply to the other — has to be ported by hand if wanted in both. Given the two dashboards serve different peripherals for different setups, that's an acceptable, even reasonable, trade: they're allowed to diverge over time as each source's data shape suggests different treatment (this dashboard already does, with the ETA line neither Powah dashboard has any data to support).
