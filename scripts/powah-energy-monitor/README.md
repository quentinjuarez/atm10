# POWAH energy monitor

Two-computer system: a **broadcaster** sits on a POWAH Ender Cell and reads its energy over a modem channel, a **dashboard** listens and drives a monitor. It also reports FE/t flow from every Advanced Peripherals Energy Detector it finds on the network — the real production/consumption signal once the network's storage is large enough that its level barely moves — and scales to more power sources by just placing more detectors, no script change (see `broadcaster/README.md`'s "report flow via Energy Detectors" ADR). See [`broadcaster/README.md`](./broadcaster/README.md) and [`dashboard/README.md`](./dashboard/README.md) for the decisions specific to each computer — this file only covers what's shared between them.

## Layout

```
powah-energy-monitor/
├── debug-block-reader.lua   one-off diagnostic (see broadcaster/README.md)
├── broadcaster/
│   ├── run.lua                the real logic — install via install.lua, not directly
│   ├── startup.lua             fetched by install.lua, saved locally as startup.lua
│   ├── install.lua             run once: wget run install.lua
│   └── README.md               ADR: why Block Reader, channel, interval, logging
└── dashboard/
    ├── run.lua
    ├── startup.lua
    ├── install.lua
    └── README.md               ADR: guard/anomaly handling, rate calc, monitor sizing
```

## ADR: two computers over a modem channel, not one computer reading + displaying

**Context.** The Ender Cell and the desired screen location aren't necessarily the same spot — the cell can sit in an out-of-the-way power room while the dashboard goes somewhere visible.

**Decision.** Split into a broadcaster (reads the cell, transmits) and a dashboard (receives, renders), linked only by a fixed modem channel (`CHANNEL = 6060`, hard-coded identically in both `run.lua` files — change one, change both, or the dashboard sits at "Waiting for signal" forever).

**Consequences.** No cable between the two computers — Wireless or Ender Modem on each side. Adds a second computer to build, but removes any placement constraint linking the cell to the screen.

## ADR: raw modem channel, not `rednet`

**Context.** `rednet` adds computer-ID addressing, host/lookup, and protocol strings — built for many-to-many networks with discovery.

**Decision.** Use `modem.transmit`/`modem_message` directly on a fixed channel. This is a single, fixed broadcaster→dashboard pair; there's nothing to discover.

**Consequences.** Simpler code, but the channel number is a manual coordination point between the two files instead of something `rednet` would negotiate.

## ADR: GitHub raw + an installer that writes `startup.lua`, not Pastebin

Same reasoning as the repo root README's "why not Pastebin" section — Pastebin's API can't edit an existing paste, so a GitHub raw URL is the stable link to `wget`. Each computer's `install.lua` (run once) fetches that computer's `startup.lua` and saves it locally under that exact name, since CC:Tweaked auto-runs whatever's named `startup.lua` on boot — you don't need to remember the `wget <url> startup.lua` save-as syntax yourself.
