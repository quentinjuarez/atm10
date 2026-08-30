# POWAH energy monitor

Three-computer system, one dashboard receiving two independent broadcasts:

- **`ender-cell-broadcaster`** sits on a POWAH Ender Cell and broadcasts stored/capacity energy (storage level).
- **`energy-detector-broadcaster`** sits on however many Advanced Peripherals Energy Detectors exist on power source output cables, and broadcasts their combined FE/t flow (production/consumption) — the real signal once the network's storage is large enough that its level barely moves.
- **`dashboard`** listens for both, one on each of two dedicated channels, and renders both — see `dashboard/README.md`'s ADR for why losing one doesn't blank out the other.

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

**Decision.** Split into three independent computers linked only by two dedicated modem channels — one per broadcast type, see the ADR below.

**Consequences.** No cable needed between any of them — Wireless or Ender Modem on each side. Three computers to build instead of one, but each one only needs wiring to what it actually reads, not to everything.

## ADR: two broadcast types, two channels, `kind` kept as a second check

**Context.** Storage level (Ender Cell) and flow (Energy Detectors) are unrelated readings with unrelated wiring and unrelated failure modes — an Energy Detector going missing shouldn't stop the Ender Cell level from updating, and vice versa. An earlier version put both `kind`s on one shared `CHANNEL = 6060`, discriminated only by `message.kind`. That's not technically wrong — `modem.transmit` doesn't have real collisions, each transmission is its own discrete event regardless of how many computers share a channel — but debugging "am I even receiving the right broadcaster" is simpler with each stream fully separated at the wire level, so it was split on request.

**Decision.** `ender-cell-broadcaster/run.lua` transmits on `CHANNEL = 6701`; `energy-detector-broadcaster/run.lua` transmits on `CHANNEL = 6702`. The dashboard opens both (`CELL_CHANNEL`/`FLOW_CHANNEL`) and checks the receiving `channel` first, `message.kind` second, before touching either state track — belt and suspenders, since a stray message on the wrong channel or with the wrong `kind` is now rejected twice over instead of once.

**Consequences.** Two channel numbers to keep in sync (one dashboard constant matching one broadcaster's constant each) instead of one shared number — marginally more to misconfigure, but each stream's traffic is now trivially distinguishable (e.g. if you ever sniff the channel from another computer) without reading payload contents. Each broadcaster is still independently placeable, restartable, and loggable; the dashboard still degrades per-stream exactly as before.

## ADR: raw modem channels, not `rednet`

**Context.** `rednet` adds computer-ID addressing, host/lookup, and protocol strings — built for many-to-many networks with discovery.

**Decision.** Use `modem.transmit`/`modem_message` directly on two fixed channels, one per broadcast type. This is a small, fixed set of broadcasters and one dashboard; there's nothing dynamic to discover.

**Consequences.** Simpler code, but the channel numbers are manual coordination points across files instead of something `rednet` would negotiate.

## ADR: GitHub raw + an installer that writes `startup.lua`, not Pastebin

Same reasoning as the repo root README's "why not Pastebin" section — Pastebin's API can't edit an existing paste, so a GitHub raw URL is the stable link to `wget`. Each computer's `install.lua` (run once) fetches that computer's `startup.lua` and saves it locally under that exact name, since CC:Tweaked auto-runs whatever's named `startup.lua` on boot — you don't need to remember the `wget <url> startup.lua` save-as syntax yourself.
