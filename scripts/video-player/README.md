# Video player

Single computer, one monitor, one speaker. Plays a short pre-converted clip in a loop — pixel-art frames on the monitor, synced audio through the speaker. Read this whole file before getting excited — see the "What this actually is" section first.

## What this actually is (read this first)

There is **no video decoder inside CC:Tweaked's Lua sandbox**, and **no way to stream a live YouTube URL**. What actually works, and what this feature does, is the same trick the CC:Tweaked community has used for years (search "Bad Apple ComputerCraft" to see the result): a short clip is converted **once, on your own computer**, into:

- a sequence of pixel-art frames (the exact same one-character-per-pixel format as [`../photo-viewer/`](../photo-viewer/)'s `.nfp` images, just concatenated into one file), and
- an audio track in CC:Tweaked's own compressed format, DFPWM, which the in-game Speaker peripheral can play natively.

The Minecraft computer only ever plays back files that already exist — it never touches YouTube, never decodes real video, and never does any conversion itself. See [`../../tools/video_to_ccv.py`](../../tools/video_to_ccv.py) for the conversion step.

**Practical limits, honestly stated:** resolution is roughly one pixel per character cell (like `.nfp` photos — pixel art, not a sharp picture), frame rate is realistically single digits (CC:Tweaked's timers tick at 20/s and drawing a frame costs real monitor calls), and a clip's `frames.ccv` is plain text that has to be fetched over `http.get` and held in memory — fine for a few seconds to under a minute of clip, not a movie.

## Wiring

- **Advanced Monitor** — color is the whole point here; a plain Monitor would show everything in grayscale.
- **Speaker** (any of the mod's speaker blocks/items that expose the `speaker` peripheral) on the same computer, for `audio.dfpwm` playback.
- HTTP access, same as every other script in this repo.

## Adding a clip

1. On your own computer (not in Minecraft), run [`../../tools/video_to_ccv.py`](../../tools/video_to_ccv.py) against a short video file — see that tool's own `--help` and [`../../tools/README.md`](../../tools/README.md) for what it needs installed (ffmpeg).
2. It produces `frames.ccv` + `audio.dfpwm`. Put both under a new `clips/<name>/` folder in this repo.
3. Set `CLIP_NAME` at the top of `run.lua` to `<name>` and push.
4. `reboot` the computer (or `wget run .../video-player/run.lua` to test without rebooting).

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/video-player/install.lua
```

Then `reboot` to activate `startup.lua`.

## ADR: `.ccv`, a trivial bundle format — one header line + concatenated `.nfp`-style frames

**Context.** Fetching each frame as its own HTTP request would be both slow (one round-trip per frame, dozens to hundreds of them for even a short clip) and likely to hit GitHub raw's rate limits. The frames themselves already have a proven, simple text format — `../photo-viewer/`'s `.nfp` — no need to invent a new per-pixel encoding.

**Decision.** One file, `frames.ccv`: a `CCV1 <width> <height> <fps> <frameCount>` header line, then `frameCount × height` rows using the exact same hex-digit-per-pixel convention as `.nfp`. `run.lua` fetches this ONE file with ONE `http.get`, holds all rows in memory, and slices out frame `i`'s rows arithmetically (`rowOffset + (i-1)*height`) rather than re-parsing anything per frame.

**Consequences.** One network round-trip regardless of clip length. Memory cost scales with clip length × resolution × fps — the honest ceiling this README states up front. A malformed or truncated `frames.ccv` (e.g. from an interrupted conversion) is caught explicitly at load time (`parseCcv` checks the actual row count against what the header claims) rather than silently reading garbage or indexing past the end of the array.

## ADR: DFPWM audio via `cc.audio.dfpwm` + `speaker.playAudio`, not a hand-rolled decoder

**Context.** DFPWM is CC:Tweaked's own audio codec for the Speaker peripheral — a real, documented, first-party API (`require("cc.audio.dfpwm")` for the decoder, `speaker.playAudio(buffer)` to play a decoded chunk), not something this script needs to implement itself.

**Decision.** `audioLoop()` follows CC:Tweaked's own documented pattern exactly: read the `.dfpwm` file in chunks over HTTP (`http.get(url, nil, true)` for binary mode), feed each chunk through `dfpwm.make_decoder()`, and push the result to `speaker.playAudio()`, waiting on the `speaker_audio_empty` event when the speaker's buffer is full rather than dropping audio.

**Consequences.** Audio playback code is a handful of lines because it's just wiring together two first-party APIs, not a custom codec implementation. The **encoding** side (turning a WAV into `.dfpwm`) happens outside Minecraft entirely — see `../../tools/README.md` for why that step leans on `ffmpeg` rather than a from-scratch encoder here.

## ADR: video and audio fail independently, `waitForAll` not `waitForAny`

**Context.** Audio and video are fetched from two separate URLs and can fail independently — a missing/corrupt `audio.dfpwm` shouldn't take down a clip whose video is fine, and vice versa. `parallel.waitForAny(videoLoop, audioLoop)` would stop BOTH the instant either one finishes (or errors) first, which is wrong when they're not the exact same length.

**Decision.** `audioLoop()` wraps its entire body in one `pcall`; a failure there is logged and the function just returns, leaving the speaker silent for the rest of that playthrough while `videoLoop()` keeps going untouched. The two are run with `parallel.waitForAll`, which only proceeds once BOTH have actually finished (or, for audio, given up).

**Consequences.** A broken or missing audio file degrades to "silent video," never "no video." The video is effectively the pacing authority for a playthrough's length; audio just does its best to keep up alongside it.

## ADR: loops forever once installed, not a one-shot

**Context.** This gets installed via `startup.lua` like every other computer in this repo (see `../../README.md`'s "Auto-boot"), which implies "runs unattended" — a script that plays once and then sits at an idle shell until someone manually reboots it doesn't fit that expectation for something meant to be a standing attraction.

**Decision.** The whole play-a-clip step (`parallel.waitForAll(videoLoop, audioLoop)`) sits inside a `while true do ... end`, with a short `LOOP_PAUSE_SECONDS` pause and a "replaying in Ns" message between loops. Frame data is fetched once at startup and replayed from memory every loop (no re-fetch cost); audio re-opens `AUDIO_URL` each loop since its HTTP stream is consumed as it plays and can't be rewound. Each playthrough is wrapped in its own `pcall`, so one bad loop (e.g. a transient network failure re-opening the audio stream) logs and moves on to the next loop instead of ending the kiosk permanently.

**Consequences.** Once installed, this behaves like an actual kiosk/attraction — always playing, self-healing across transient network blips — at the cost of needing `CLIP_NAME`/a repo push (not an in-game control) to change what's showing. A future version could add `monitor_touch` to skip/pick a clip, the same mechanism `../photo-viewer/` uses.
