# POWAH energy monitor

Three-computer system, one dashboard receiving two independent broadcasts:

- **`ender-cell-broadcaster`** sits on a POWAH Ender Cell and broadcasts stored/capacity energy (storage level).
- **`energy-detector-broadcaster`** sits on however many Advanced Peripherals Energy Detectors exist on power source output cables, and broadcasts their combined FE/t flow (production/consumption) — the real signal once the network's storage is large enough that its level barely moves.
- **`dashboard`** listens for both, on one shared channel, and renders both — see `dashboard/README.md`'s ADR for how it tells the two apart and why losing one doesn't blank out the other.

See each computer's own `README.md` for wiring and decisions specific to it — this file only covers what's shared between all three.

## Layout

```
powah-energy-monitor/
├── debug-block-reader.lua        one-off diagnostic (see ender-cell-broadcaster/README.md)
├── ender-cell-broadcaster/
│   ├── run.lua                      the real logic — install via install.lua, not directly
│   ├── startup.lua                   fetched by install.lua, saved locally as startup.lua
│   ├── install.lua                   run once: wget run install.lua
│   └── README.md                     ADR: why Block Reader, channel/kind, logging
├── energy-detector-broadcaster/
│   ├── run.lua
│   ├── startup.lua
│   ├── install.lua
│   └── README.md                     ADR: why every Energy Detector, not one generator peripheral
└── dashboard/
    ├── run.lua
    ├── startup.lua
    ├── install.lua
    └── README.md                     ADR: dual-stream state, guard/anomaly handling, monitor sizing
```

## ADR: three computers, not one reading + displaying everything

**Context.** The Ender Cell, the power sources' Energy Detectors, and the desired screen location aren't necessarily the same spot — the cell can sit in a power room, generators can be scattered elsewhere, and the dashboard goes somewhere visible.

**Decision.** Split into three independent computers linked only by a fixed modem channel (`CHANNEL = 6060`, hard-coded identically in all three `run.lua` files).

**Consequences.** No cable needed between any of them — Wireless or Ender Modem on each side. Three computers to build instead of one, but each one only needs wiring to what it actually reads, not to everything.

## ADR: two broadcast types on one channel, told apart by `kind`

**Context.** Storage level (Ender Cell) and flow (Energy Detectors) are unrelated readings with unrelated wiring and unrelated failure modes — an Energy Detector going missing shouldn't stop the Ender Cell level from updating, and vice versa. An earlier version combined both into a single broadcaster/payload; splitting them was requested specifically so both approaches stay available and independently deployable going forward, rather than coupled into one script.

**Decision.** Two separate broadcaster scripts, each transmitting its own payload shape tagged with a `kind` field (`"ender_cell"` or `"energy_flow"`) on the same `CHANNEL`. The dashboard opens that one channel and dispatches on `message.kind` into two separate state tracks (`lastCell` / `lastFlow`), each with its own "no signal" staleness check.

**Consequences.** One channel number to keep in sync across three files instead of two, but each broadcaster is independently placeable, independently restartable, and independently loggable — replacing or moving one doesn't touch the other. The dashboard degrades per-stream: if the Ender Cell broadcaster crashes, the flow numbers keep updating live and only the cell section shows "NO SIGNAL," and vice versa.

## ADR: raw modem channel, not `rednet`

**Context.** `rednet` adds computer-ID addressing, host/lookup, and protocol strings — built for many-to-many networks with discovery.

**Decision.** Use `modem.transmit`/`modem_message` directly on a fixed channel, with `kind` as a lightweight manual discriminator instead of `rednet`'s protocol strings. This is a small, fixed set of broadcasters and one dashboard; there's nothing dynamic to discover.

**Consequences.** Simpler code, but the channel number (and now `kind` values) are manual coordination points across files instead of something `rednet` would negotiate.

## ADR: GitHub raw + an installer that writes `startup.lua`, not Pastebin

Same reasoning as the repo root README's "why not Pastebin" section — Pastebin's API can't edit an existing paste, so a GitHub raw URL is the stable link to `wget`. Each computer's `install.lua` (run once) fetches that computer's `startup.lua` and saves it locally under that exact name, since CC:Tweaked auto-runs whatever's named `startup.lua` on boot — you don't need to remember the `wget <url> startup.lua` save-as syntax yourself.
