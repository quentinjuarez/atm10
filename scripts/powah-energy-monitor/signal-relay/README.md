# Signal relay

Rebroadcasts any of this repo's known channels (6701/6702/6703) unchanged — a code-only fix for two Wireless Modems that are too far apart to hear each other directly, without swapping either one for an Ender Modem. Confirmed use case: `induction-broadcaster` and `induction-dashboard` ~100 blocks apart (in depth) with a Wireless Modem on each end, same dimension, and the dashboard never receiving anything despite both computers starting up cleanly.

## Read this first: what a relay can and can't fix

A plain Wireless Modem's range is enforced by the server itself (`computercraft-server.toml`'s `modem_range`, or CC:Tweaked's built-in default) — no amount of Lua can make one physically reach further. What a relay DOES do: sit within range of both ends and re-transmit, so each hop gets its OWN fresh range budget instead of needing one hop to cover the whole distance.

**This only works within the same dimension.** A plain Wireless Modem cannot cross dimensions at all, relayed or not — chaining a hundred relays together still can't bridge to the Nether or an ATM10 dimension the sender isn't in. If sender and receiver are in different dimensions, an Ender Modem (unlimited range, and the only modem type that works cross-dimension) is the only fix, on at least one end — there's no way around that in code.

## Wiring

- A **Wireless or Ender Modem**, placed physically between (or otherwise in range of both) whatever this is relaying for — for the confirmed 100-block case, roughly the midpoint is a reasonable starting placement. Chain a second relay if one hop still doesn't cover the distance.
- No monitor, no other peripheral needed.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/powah-energy-monitor/signal-relay/install.lua
```

Then `reboot`. Check `signal-relay.log` (`edit signal-relay.log`) for a `First message seen on ch.6703` line — that confirms the relay is actually within range of the broadcaster and picking up its traffic. If that line never appears, the relay itself is too far from the sender and needs to move closer (or a second relay hop is needed).

## ADR: relays by channel number only, never inspects `kind` or payload

**Context.** This repo has two independent broadcast setups (Powah on 6701/6702, Mekanism on 6703) that don't need to know about each other. A relay tied to one specific message shape would need updating every time a new broadcaster/channel gets added to the repo.

**Decision.** `CHANNELS = { 6701, 6702, 6703 }` — every channel used anywhere in this repo — and the relay logic never looks at `message.kind` or any payload field beyond `message.t` (used only for dedup, see below). It opens all three and blindly forwards whatever arrives on any of them.

**Consequences.** One relay computer covers both the Powah and Mekanism setups at once, and a future new broadcaster only needs its channel number added to this one list — no new relay logic. The trade-off: this relay can't selectively relay "just the flow channel, not storage" or similar — it's all-or-nothing per channel, which is the right granularity here since range is a physical problem affecting every broadcast type equally, not a per-message concern.

## ADR: dedup by the message's own `t`, to make relay chains and overlapping range safe

**Context.** A message reaching a relay that's already been relayed once (because a second relay also heard it, or this relay hears its own retransmission echo back) would, without any guard, get re-transmitted again — and if two relays can hear each other's retransmissions, that's an infinite bounce, not just wasted traffic.

**Decision.** Every message this repo broadcasts already carries `t = os.epoch("utc")` set once at the ORIGINAL broadcast (unchanged by relaying, since the relay forwards the same table as-is). The relay keeps a small bounded set of recently-seen `t` values **per channel** (`SEEN_MAX = 200`, oldest evicted first) and only relays a message whose `t` it hasn't relayed before on that channel.

**Consequences.** Safe to run multiple relays with overlapping range, or chain them, without any coordination between them or a risk of runaway retransmission loops. A message missing `t` (shouldn't happen for anything this repo actually broadcasts, but a stray unrelated modem message on the same channel might lack it) is silently ignored rather than relayed blind — see the code's `shouldRelay`-equivalent guard.

## ADR: only logs problems and each channel's first-ever message, not every relay

Same reasoning as every broadcaster in this repo — at up to ~2 messages/second across both broadcast setups, logging every routine relay would fill `signal-relay.log` with nothing but noise. The one exception (`First message seen on ch.N`) exists specifically to answer "is this relay actually in range of the sender at all?" from the log alone, without needing to watch the terminal live.
