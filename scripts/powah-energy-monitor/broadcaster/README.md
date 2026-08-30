# Broadcaster

Reads the Ender Cell, transmits on `CHANNEL`. See [`../README.md`](../README.md) for the shared two-computer architecture.

## Wiring

- **Block Reader (Advanced Peripherals)** placed **facing** the Ender Cell — it reads whatever block is directly in front of it, not its own block. Use the same placement that worked for `../debug-block-reader.lua` if you ran that first.
- **Modem** on any other free side of this computer — no cable needed, it talks over the air:
  - **Wireless Modem** if the dashboard is in the same base/render distance.
  - **Ender Modem** if it's far away or in another dimension — unlimited range, costs more to craft.
- **Optional — one Energy Detector per energy source:** place an Advanced Peripherals **Energy Detector** inline on each source's output cable (the cable passes *through* the detector block) to get real FE/t for that source. Zero, one, or many — `run.lua` re-scans the network every cycle and broadcasts whatever it finds under `sources`, so adding a second/third power source later is just placing another detector, no script edit. None present just means an empty `sources` list, nothing else breaks.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/broadcaster/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/broadcaster/run.lua`.

## ADR: read via Block Reader NBT, not `ender_cell.getEnergy()`

**Context.** Advanced Peripherals' dedicated `ender_cell` peripheral clamps `getEnergy()` to the 32-bit signed max (`2147483647`, ~2.15B FE) for a cell/network storing more than that ([IntelligenceModding/AdvancedPeripherals#642](https://github.com/IntelligenceModding/AdvancedPeripherals/issues/642)). Confirmed against this world: a `powah:ender_cell_nitro` reporting `getEnergy()` pinned at exactly `2147483647` while the true value was far higher. The clamp happens inside Advanced Peripherals' Java code before the number ever reaches Lua — there's no way to ask that same method for a more precise answer.

**Decision.** Read the tile entity's raw NBT instead, via Advanced Peripherals' **Block Reader** peripheral (`getBlockData()`), which isn't limited to a 32-bit int. `../debug-block-reader.lua`'s dump against this exact block confirmed the field names: `energy_stored_main_energy` and `energy_capacity_main_energy` (the two `ENERGY_FIELD`/`CAPACITY_FIELD` constants at the top of `run.lua`) — not guessed, read directly off a live dump.

**Consequences.** No clamp regardless of network size. But this is now coupled to Powah's internal NBT schema, which isn't publicly documented and could change on a Powah/Advanced Peripherals update — if `run.lua` starts erroring with "NBT is missing '...' as numbers", re-run `../debug-block-reader.lua` and update the two field-name constants.

## ADR: report flow via Energy Detectors, not just level

**Context.** A network sized well above actual consumption, with a power source tuned to keep it topped up (this world: a Powah Reactor only runs below 70%), sits pinned at ~100% almost permanently by design. `energy`/`maxEnergy` barely move even with real consumption happening underneath — level is fundamentally the wrong signal to read "how much power is being used" once storage is oversized relative to draw. This showed up directly: the dashboard kept reading `22B/22B` with no visible change.

**Decision.** Broadcast `sources` (an array of `{name, rateFEt}`, one per Energy Detector found on the network) and `totalFlowFEt` (their sum). An earlier version read a Powah-specific `uraninite_reactor` peripheral for running state instead — dropped in favor of Energy Detectors for two reasons: it only works for that one Powah block, and `getTransferRate() ~= 0` already tells you a source is active without a separate state call. `sources`/`totalFlowFEt` are optional in the same sense as before — zero detectors found just broadcasts an empty list, the Ender Cell reading is unaffected either way.

**Consequences.** Energy Detector's `getTransferRate()` reads FE/t off any FE-compatible cable regardless of which mod is on either end — a second, third, or entirely different power source later just needs its own detector on its output cable; `findDetectorNames()` re-scans `peripheral.getNames()` every cycle, so a newly placed detector shows up on its own, no script change or restart. Each detector's broadcast `name` is whatever CC:Tweaked auto-assigned it (e.g. `energy_detector_0`) — there's no confirmed way to give it a nicer custom label, so the dashboard just shortens that to `src 0`. A detector only reflects the one cable it sits on: placed between a source and the network it shows that source's output, not every consumer's draw everywhere on the network — a detector on a consumer branch instead would show consumption from that branch specifically.

## ADR: 1-second broadcast interval

Started at 2s; confirmed working, then tightened to 1s once sending was verified stable — no other reason than "faster feels more live" for a dashboard.

## ADR: log on state transitions only, not every send

**Context.** Logging every transmit was useful while confirming the broadcast worked at all, but became pure noise once confirmed — at 1 message/sec that's a lot of identical lines for no benefit.

**Decision.** `log()` now only fires for read failures, crashes, and `detectAnomaly()` transitions (problem started / problem cleared) — see the file's `GUARD:` comment block for what it checks. Routine successful sends aren't logged at all.

**Consequences.** `broadcast.log` stays small and only contains things actually worth looking at, capped at 50 lines regardless so a long-running computer never slowly fills its disk.
