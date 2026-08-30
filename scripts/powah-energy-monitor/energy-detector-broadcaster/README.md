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
