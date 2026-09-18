# Induction broadcaster

Reads a Mekanism Induction Matrix through Mekanism's **own built-in ComputerCraft integration** — the `inductionPort` peripheral — and broadcasts everything it exposes (storage, flow, transfer cap) as one message on `CHANNEL` (6703). Paired with [`../induction-dashboard/`](../induction-dashboard/), a dedicated new dashboard — **not** [`../dashboard/`](../dashboard/), which still serves the Powah `ender-cell-broadcaster`/`energy-detector-broadcaster` pair unchanged. See [`../README.md`](../README.md) for how the alternatives relate.

## Read this first: how we got here (it took two wrong turns)

1. **First attempt: Block Reader facing the Induction Casing, reading raw NBT.** This is exactly how `../ender-cell-broadcaster/` reads a Powah Ender Cell, so it seemed like the obvious approach. [`../debug-induction-reader.lua`](../debug-induction-reader.lua)'s dump against a live Casing showed only `redstone`/`inventory_id`/`current_redstone` — **no energy data at all**. The capacity/input/output numbers visible in the block's own GUI come from a live query against the multiblock's in-memory structure, not from that block's saved NBT — so no field name guess there could ever have worked, on any Casing.
2. **Second attempt: check for a native Mekanism peripheral on the Casing.** [`../debug-mekanism-peripheral.lua`](../debug-mekanism-peripheral.lua) run against that same Casing found Mekanism DOES expose it as a peripheral (`mekanism:induction_casing`) — but only generic item/fluid methods (`pullItems`, `tanks`, `pushFluid`, ...), confirmed from an actual in-game screenshot. Still no energy.
3. **What actually works: the INDUCTION PORT block specifically**, not the Casing. A community reference script (Wolfe's Mekanism Induction Matrix Monitor) confirmed the real peripheral type and method names — `peripheral.find("inductionPort")` with `getEnergy()`, `getMaxEnergy()`, `getEnergyFilledPercentage()`, `getLastInput()`, `getLastOutput()`, `getTransferCap()`. `run.lua` uses these directly. No Block Reader is used or needed anywhere in this computer.

If `peripheral.find("inductionPort")` comes back `nil` when you install this, the computer almost certainly isn't touching the Port block — see Wiring below.

## Wiring

- This computer must be **directly adjacent to the Induction Port block** (or on the same Wired Modem + Networking Cable network as it) — not the Casing, not any other multiblock component. The Port is the block Mekanism actually routes FE in/out through, and the only one that exposes energy methods as a peripheral.
- **Modem** on any other free side — **must be Wireless or Ender, not Wired**. `run.lua` checks `modem.isWireless()` at startup, same as every broadcaster in this repo.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/induction-broadcaster/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/induction-broadcaster/run.lua`.

## ADR: a dedicated new dashboard/channel, not reusing `../dashboard/`'s message shapes

**Context.** An earlier version of this file tried to stay compatible with `../dashboard/`'s existing `kind="ender_cell"`/`kind="energy_flow"` messages on `CELL_CHANNEL`/`FLOW_CHANNEL`, so that dashboard wouldn't need any changes. That meant collapsing everything into two message shapes designed around Powah's data (a single storage reading, a single flow reading) — no room for percentage, transfer cap, or charge/discharge ETA, all of which the Induction Port hands over for free and are worth showing.

**Decision.** One new message shape, `kind="induction_matrix"`, carrying every field the Port exposes, on its own `CHANNEL = 6703`. `../induction-dashboard/` is a dedicated receiver for it, built new rather than bolted onto `../dashboard/`.

**Consequences.** Two dashboards to choose from depending on which broadcaster setup is running, instead of one dashboard serving both — but each one's code stays simple and specific to its data source, instead of `../dashboard/` growing conditional logic for two very different underlying peripherals. `../dashboard/` is completely unaffected either way.

## ADR: `changePerSecond`/ETA measured from actual energy delta, not derived from input−output

**Context.** `getLastInput()`/`getLastOutput()` are the Port's own last-tick transfer numbers — in principle `input - output` should equal how fast stored energy is actually changing, but there's no guarantee Mekanism's internal accounting matches that exactly every tick (transfer caps, internal losses, timing of when the Port's cached values update relative to when the broadcaster reads them).

**Decision.** `run.lua` tracks `previousEnergy`/`previousT` across broadcast cycles and computes `changePerSecond` from the **actually observed** change in `getEnergy()` over the real elapsed time, not from `(input - output) * ticks_per_second`. Charge/discharge ETA (`etaSeconds`) is derived from that measured rate: `(maxEnergy - energy) / changePerSecond` while charging, `energy / -changePerSecond` while discharging, `nil` when flat. This mirrors the community reference script's own approach.

**Consequences.** ETA reflects what's actually happening to the stored total, even if it doesn't line up exactly with the input/output numbers shown alongside it. `netFlow` (`input - output`) is still broadcast separately and is what drives the graph/flow-color — it's a cleaner signal moment-to-moment than a measured delta would be at 1s resolution (measuring a small energy change over exactly 1 second is noisier than reading the Port's own last-tick transfer numbers directly).

## ADR: Mekanism's own `mekanismEnergyHelper` preferred over a hardcoded ratio

**Context.** The Port's methods return raw Joules, Mekanism's internal unit, but everything downstream in this repo assumes FE. A hardcoded `JOULES_PER_FE = 2.5` ratio works but is one more thing that could be subtly wrong for a given Mekanism version.

**Decision.** If `mekanismEnergyHelper` (a global Mekanism's own CC:Tweaked integration exposes, per the reference script) is present with a `joulesToFE` function, `toFE()` uses that instead — the mod's own conversion, not a guessed constant. `JOULES_PER_FE` is the fallback when that global isn't available, same defensive posture the reference script itself uses. The `READY` log line states which path was actually used, so it's never silently ambiguous which one is active.

**Consequences.** Correct regardless of whether the exact Joules-to-FE ratio ever changes between Mekanism versions, as long as the helper itself is present. If dashboard numbers look exactly 2.5x off, the log's `READY` line is the first thing to check — it says whether the fallback ratio was actually used.
