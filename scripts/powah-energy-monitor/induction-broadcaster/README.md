# Induction broadcaster

**Replaces both** [`../ender-cell-broadcaster/`](../ender-cell-broadcaster/) and [`../energy-detector-broadcaster/`](../energy-detector-broadcaster/) with a single computer, if your setup is a Mekanism Induction Matrix rather than a Powah Ender Cell — one Block Reader facing the Induction Casing gives capacity, stored energy, AND live input/output FE/t all at once, so there's no need for the two-computer split the Powah setup required. See [`../README.md`](../README.md) for the shared three-computer architecture this replaces.

**The two old scripts are kept in the repo, untouched** — this is an alternative, not a migration. Run whichever setup matches your actual power source; both broadcast the same message shapes so [`../dashboard/`](../dashboard/) works unmodified either way.

## Read this before installing: field names are unconfirmed

Powah's Ender Cell fields (`energy_stored_main_energy`/`energy_capacity_main_energy`) were confirmed by literally dumping a live block's NBT with [`../debug-block-reader.lua`](../debug-block-reader.lua) before `ender-cell-broadcaster` was written. Mekanism's Induction Matrix NBT schema hasn't gone through that same confirmation step yet.

`run.lua` tries several plausible field names for each value (`CAPACITY_FIELDS`/`ENERGY_FIELDS`/`INPUT_FIELDS`/`OUTPUT_FIELDS` at the top of the file) and — this is the important part — **if none of a value's candidates match, it logs every field the Block Reader actually returned**, so the real names are visible straight from `induction-broadcast.log` without needing to guess blind a second time. You can also run [`../debug-induction-reader.lua`](../debug-induction-reader.lua) first standalone to get the same dump before wiring up the full broadcaster at all — faster feedback loop while narrowing down the right names.

If the log shows different names than what's in `run.lua`, tell me what they are (or edit the four `*_FIELDS` lists yourself) and push — no reinstall needed, `startup.lua` always fetches the current `run.lua`.

## Wiring

- **Block Reader (Advanced Peripherals)** placed **facing** the Induction Casing — same placement convention as `../ender-cell-broadcaster/`.
- **Modem** on any other free side — **must be Wireless or Ender, not Wired**. `run.lua` checks `modem.isWireless()` at startup, same as every other broadcaster in this repo.
- No Energy Detector needed — the Induction Matrix's own NBT already carries live input/output, unlike Powah where flow had to be measured separately on a cable.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/induction-broadcaster/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/induction-broadcaster/run.lua`.

## ADR: one computer instead of two, broadcasting both message kinds

**Context.** The Powah setup needed two separate computers because storage level (Ender Cell) and flow (Energy Detector on a cable) were physically different peripherals with no relationship to each other. A Mekanism Induction Matrix doesn't have that split — one block's NBT already contains capacity, stored energy, and both transfer directions.

**Decision.** `run.lua` reads the Block Reader once per cycle and transmits BOTH `kind="ender_cell"` (on `CELL_CHANNEL`) and `kind="energy_flow"` (on `FLOW_CHANNEL`) from that single read — the exact same two message shapes `../ender-cell-broadcaster/` and `../energy-detector-broadcaster/` send from two separate computers. `../dashboard/run.lua` dispatches by channel + `kind` regardless of how many computers are actually sending, so it needed zero changes.

**Consequences.** One computer and one peripheral to build instead of three computers total (two broadcasters + dashboard) down to two (this + dashboard). The trade-off Powah's split bought you — the two streams going stale independently, so you can tell which physical thing broke — is gone here, but that's fine: with one block reader on one computer, there's only one thing left to go wrong, not two independent ones.

## ADR: input/output sent as both a net total AND two synthetic "sources"

**Context.** The dashboard's `Total: X FE/t` line and graph expect a single signed number (positive = producing, negative = draining) — that's what Powah's Energy Detectors summed to. An Induction Matrix reports input and output as two separate, always-non-negative numbers instead, and collapsing them into just their difference would hide the fact that, say, 50K in and 44K out (net +6K) is a very different situation from 6K in and 0 out (also net +6K).

**Decision.** `totalFlowFEt` is `input - output`, feeding the existing graph/Total line unchanged. Additionally, `sources` carries two synthetic entries — `{name="input", rateFEt=input}` and `{name="output", rateFEt=-output}` (negated so it colors red/draining like everything else keyed on sign) — reusing `../dashboard/`'s existing per-source breakdown display, which already handles an arbitrary-length `sources` list generically.

**Consequences.** The dashboard shows net flow as its headline number (unchanged behavior) plus the input/output breakdown underneath (since `#sources > 1` there), with no dashboard code changes — it already didn't assume `sources` summed to `totalFlowFEt`. `sourceLabel()`'s `_<N>` suffix-shortening doesn't match `"input"`/`"output"`, so they just show as-is, which is clearer here than a shortened form would be anyway.

## ADR: Joules→FE conversion applied once, right after reading

**Context.** Mekanism stores energy internally in Joules, not Forge Energy (FE) — everything downstream (`../dashboard/`'s `formatFE()`, the whole rest of this repo) assumes FE.

**Decision.** `JOULES_PER_FE = 2.5` (Mekanism's own published conversion ratio) divides every raw NBT value before it's used for anything — anomaly detection, logging, or broadcasting. Conversion happens in exactly one place (`readInduction()`), not scattered across the cycle loop.

**Consequences.** If dashboard numbers come out exactly 2.5x too high or too low, this is the first thing to check — either the ratio itself, or (more likely) that raw NBT values were already in FE and shouldn't be divided at all. Set `JOULES_PER_FE = 1` if a debug dump shows the latter.

## ADR: `requireNumber()` fails loudly on a non-number field, doesn't guess

**Context.** Mekanism's large energy values use its own "FloatingLong" numeric type internally, which *might* serialize to NBT as a nested table (e.g. two longs) instead of a plain number — this wasn't a concern for Powah's Ender Cell, whose NBT fields were confirmed to be plain longs.

**Decision.** `requireNumber()` passes plain numbers through untouched and raises a specific, actionable error — which field, which NBT key matched, what type it actually got — for anything else, rather than trying to coerce a table via `tostring`/`tonumber` and silently broadcasting garbage.

**Consequences.** A FloatingLong-as-table situation shows up as a clear `CRASHED: field 'energy' ... is a table, not a number` log line pointing at exactly which field needs a follow-up fix (reading a specific sub-field once the table's shape is known), instead of a wrong number quietly reaching the dashboard.
