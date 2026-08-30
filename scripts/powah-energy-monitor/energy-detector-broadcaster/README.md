# Energy Detector broadcaster

Reads every Advanced Peripherals Energy Detector on the network, transmits their combined flow as `kind="energy_flow"` on `CHANNEL`. Flow/production only — storage level is [`../ender-cell-broadcaster/`](../ender-cell-broadcaster/), a separate computer/script. See [`../README.md`](../README.md) for why they're split and the shared architecture.

## Wiring

- **One Energy Detector per energy source**, placed **inline on that source's output cable** (the cable passes *through* the detector block, not just next to it) — this is what makes `getTransferRate()` return that source's FE/t. Zero, one, or many; `run.lua` re-scans the network every cycle, so a newly placed detector shows up in the next broadcast with no script edit or restart.
- **Modem** on any free side of this computer — no cable needed, it talks over the air:
  - **Wireless Modem** if the dashboard is in the same base/render distance.
  - **Ender Modem** if it's far away or in another dimension — unlimited range, costs more to craft.

This computer doesn't need a Block Reader or the Ender Cell at all — it only ever touches Energy Detectors and a modem. It can be the same physical computer as the Ender Cell broadcaster, or a different one closer to wherever the power sources actually are.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/energy-detector-broadcaster/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/energy-detector-broadcaster/run.lua`.

## ADR: every Energy Detector on the network, not one generator's own peripheral

**Context.** An earlier version read a Powah-specific `uraninite_reactor` peripheral's `isRunning()` for source state. That only works for that one Powah block — a different generator, or a different mod entirely, would need its own separate peripheral-specific code.

**Decision.** Enumerate every `energy_detector` peripheral on the network (`peripheral.getNames()` + `peripheral.getType()` filter, not a single `peripheral.find`, since there can be more than one), read each one's `getTransferRate()`, and broadcast the list as `sources` (`{name, rateFEt}` each) plus their sum as `totalFlowFEt`. State (producing vs. idle) is inferred from `rateFEt ~= 0` rather than a separate call.

**Consequences.** This is mod-agnostic by construction — `getTransferRate()` reads FE/t off any FE-compatible cable regardless of which mod is on either end. Adding a second/third power source later, from any mod, is purely a building task: place another Energy Detector on its output cable, nothing to change here. `findDetectorNames()` re-running every cycle means the list self-updates; the tradeoff is that a detector only reflects the one cable it sits on — placed between a source and the network it shows that source's *output*, not necessarily every consumer's draw everywhere on the network. A detector placed on a consumer branch instead would show that branch's consumption specifically; nothing here assumes one placement over the other.

## ADR: source names are whatever CC:Tweaked auto-assigns, not a custom label

**Context.** Wanted to show something more readable than a bare peripheral name (e.g. `energy_detector_0`) per source on a small monitor.

**Decision.** Broadcast the peripheral's actual network name as-is in `sources[].name`; the dashboard shortens the common `<type>_<N>` suffix pattern to `src N` for display. No attempt to rename the block or peripheral in-game — a search for a confirmed CC:Tweaked mechanism to give a wired peripheral a custom label (e.g. via anvil-renaming the item before placing) didn't turn up a reliably documented one.

**Consequences.** Labels are positional (`src 0`, `src 1`, ...) rather than descriptive (`"Reactor Output"`) — fine for a handful of sources, would get confusing with many. If a real labeling mechanism turns up later, `sourceLabel()` in the dashboard is the one place to change.

## ADR: 1-second broadcast interval, log on transitions only

Same reasoning as `../ender-cell-broadcaster/README.md` — matches that broadcaster's cadence so both streams feel equally live, and only real changes get logged (the set of detected detector names changing, or total flow crossing zero) instead of routine successful sends, keeping `energy-detector-broadcast.log` small and worth reading.

## Troubleshooting: reading is 0 or far lower than the real production/consumption

`getTransferRate()` reports whatever actually passed through *that specific block* — it isn't a network-wide total, so a low or zero reading usually means the detector isn't sitting where all the power is. In rough order of likelihood:

1. **Parallel paths around the detector.** If the source is connected to the network through more than one cable run, most of the power can take the path that *doesn't* go through the detector, and it only sees whatever trickles through its own segment. Check that the detector's segment is the *only* connection between source and network — no direct source-to-network cable or block-to-block adjacency bypassing it.
2. **Rate limit set lower than real flow.** Advanced Peripherals documents the Energy Detector as able to "act as a resistor" via `setTransferRateLimit()`, capping throughput to whatever limit is set — which would show up exactly as "flow reads low/capped" while genuinely throttling the real power line, not just misreporting it. The default value isn't documented publicly. Check it directly from any computer's Lua console (the `lua` program, not `run.lua`):
   ```
   peripheral.find("energy_detector").getTransferRateLimit()
   ```
   If that's some small number and not what you expect, either the default isn't unlimited or something set it explicitly — `peripheral.find("energy_detector").setTransferRateLimit(0)` is documented as accepting an explicit limit but not confirmed here as an "unlimited" sentinel; test with a limit well above your real peak (e.g. `2000000`) if `0` doesn't restore full flow.
3. **Cross-mod cable compatibility.** Some third-party cable/conduit types have been reported not to transfer energy through the detector at all with certain Advanced Peripherals versions ([IntelligenceModding/AdvancedPeripherals#316](https://github.com/IntelligenceModding/AdvancedPeripherals/issues/316), [#536](https://github.com/IntelligenceModding/AdvancedPeripherals/issues/536) for Create-specific connectors) — if the detector reads exactly `0` no matter what, try a different cable type on both sides of it, or confirm your Advanced Peripherals version is current for this pack.

None of this is confirmed against this specific world yet — these are the documented/reported causes, not a diagnosis. `getTransferRate()`/`getTransferRateLimit()` from the `lua` console are the fastest way to narrow it down without editing any script.
