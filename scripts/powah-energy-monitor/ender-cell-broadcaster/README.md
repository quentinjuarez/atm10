# Ender Cell broadcaster

Reads the Ender Cell's stored/capacity energy, transmits it as `kind="ender_cell"` on `CHANNEL`. Storage level only — flow/production is [`../energy-detector-broadcaster/`](../energy-detector-broadcaster/), a separate computer/script. See [`../README.md`](../README.md) for why they're split and the shared architecture.

## Wiring

- **Block Reader (Advanced Peripherals)** placed **facing** the Ender Cell — it reads whatever block is directly in front of it, not its own block. Use the same placement that worked for `../debug-block-reader.lua` if you ran that first.
- **Modem** on any other free side of this computer — no cable needed, it talks over the air:
  - **Wireless Modem** if the dashboard is in the same base/render distance.
  - **Ender Modem** if it's far away or in another dimension — unlimited range, costs more to craft.

This computer doesn't need any Energy Detector — that's the other broadcaster's job.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/ender-cell-broadcaster/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/ender-cell-broadcaster/run.lua`.

## ADR: read via Block Reader NBT, not `ender_cell.getEnergy()`

**Context.** Advanced Peripherals' dedicated `ender_cell` peripheral clamps `getEnergy()` to the 32-bit signed max (`2147483647`, ~2.15B FE) for a cell/network storing more than that ([IntelligenceModding/AdvancedPeripherals#642](https://github.com/IntelligenceModding/AdvancedPeripherals/issues/642)). Confirmed against this world: a `powah:ender_cell_nitro` reporting `getEnergy()` pinned at exactly `2147483647` while the true value was far higher. The clamp happens inside Advanced Peripherals' Java code before the number ever reaches Lua — there's no way to ask that same method for a more precise answer.

**Decision.** Read the tile entity's raw NBT instead, via Advanced Peripherals' **Block Reader** peripheral (`getBlockData()`), which isn't limited to a 32-bit int. `../debug-block-reader.lua`'s dump against this exact block confirmed the field names: `energy_stored_main_energy` and `energy_capacity_main_energy` (the two `ENERGY_FIELD`/`CAPACITY_FIELD` constants at the top of `run.lua`) — not guessed, read directly off a live dump.

**Consequences.** No clamp regardless of network size. But this is now coupled to Powah's internal NBT schema, which isn't publicly documented and could change on a Powah/Advanced Peripherals update — if `run.lua` starts erroring with "NBT is missing '...' as numbers", re-run `../debug-block-reader.lua` and update the two field-name constants.

## ADR: a separate broadcaster from flow, not one combined script

**Context.** A network sized well above actual consumption, with a power source tuned to keep it topped up (this world: a Powah Reactor only runs below 70%), sits pinned at ~100% almost permanently by design — level alone can't show consumption (see `../README.md`'s ADR for the full story). Reading flow needed a completely different peripheral (Energy Detector) with completely different wiring (inline on a cable, not facing a block) and no dependency on the Ender Cell at all. An earlier version bolted Energy Detector reading onto this same script.

**Decision.** Split into two broadcaster scripts/computers, this one staying scoped to *only* the Ender Cell's storage level, tagging its payload `kind = "ender_cell"`. Flow reporting moved entirely to `../energy-detector-broadcaster/run.lua`.

**Consequences.** This script no longer needs `peripheral.getNames()`-scanning or any Energy Detector at all — its only peripherals are the Block Reader and a modem. It can run on the same computer as the flow broadcaster or a completely different one; either way the dashboard just sees two `kind`s of message on the same channel.

## ADR: 1-second broadcast interval

Started at 2s; confirmed working, then tightened to 1s once sending was verified stable — no other reason than "faster feels more live" for a dashboard.

## ADR: log on state transitions only, not every send

**Context.** Logging every transmit was useful while confirming the broadcast worked at all, but became pure noise once confirmed — at 1 message/sec that's a lot of identical lines for no benefit.

**Decision.** `log()` now only fires for read failures, crashes, and `detectAnomaly()` transitions (problem started / problem cleared) — see the file's `GUARD:` comment block for what it checks. Routine successful sends aren't logged at all.

**Consequences.** `ender-cell-broadcast.log` stays small and only contains things actually worth looking at, capped at 50 lines regardless so a long-running computer never slowly fills its disk.
