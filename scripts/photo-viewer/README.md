# Photo viewer

Single computer, one monitor. Cycles through pre-converted photos (`.nfp` — CC:Tweaked's native pixel-image format) fetched from this repo, auto-advancing every `SLIDE_SECONDS`, or instantly on a player **touching the monitor**. No web page, no Discord — see [`../../README.md`](../../README.md) for the shared architecture.

## Wiring

- **Advanced Monitor** — recommended so photos show in color; a plain Monitor still works, CC:Tweaked quantizes colors to grayscale automatically. Any size — `run.lua` clips images to whatever `monitor.getSize()` reports, no size hard-coded. Touch input (`monitor_touch`) only fires from an Advanced Monitor, though — a plain Monitor can still show the slideshow, just without the "tap to skip" control.
- No other peripheral needed. This computer only needs HTTP access and the monitor.

## Getting your own photos on screen

This repo doesn't ship a photo converter that runs in Minecraft — image processing happens on **your own computer**, once, before pushing:

1. Run [`../../tools/png_to_nfp.py`](../../tools/png_to_nfp.py) (see that folder's README) against a PNG/JPG, sized to roughly your monitor's character grid (check with `monitor.getSize()` in the `lua` console on the actual computer — e.g. `40 18`).
2. Drop the resulting `.nfp` file into this folder's `images/`.
3. Add its filename as a new line in `manifest.txt`.
4. Push to `main`. The next auto-advance (or a `reboot`) picks it up — no code change needed.

`images/testcard.nfp` ships as a placeholder so the feature works the moment you install it, before you've converted anything of your own.

## Install

```
wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/photo-viewer/install.lua
```

Then `reboot` to activate `startup.lua`. To test a change without rebooting: `wget run https://raw.githubusercontent.com/quentinjuarez/atm10/main/scripts/photo-viewer/run.lua`.

## ADR: `.nfp` text format, not raw pixel data

**Context.** CC:Tweaked monitors can't display arbitrary bitmap images — there's no image codec in the Lua sandbox. What they CAN do is color individual character cells, one of CC:Tweaked's own 16-color palette per cell.

**Decision.** Convert photos to `.nfp` — the same plain-text pixel format CC:Tweaked's own `paintutils.loadImage`/`.drawImage` use: one line per row, one character per pixel, a hex digit (`0`-`9`, `a`-`f`) selecting one of the 16 colors via the exact same digit-to-color mapping as `colors.toBlit()`, or a space for "no pixel". `run.lua` parses and draws this itself (see the next ADR for why not the built-in `paintutils.drawImage`), but the *format* is unchanged from CC:Tweaked's own, so any existing `.nfp` converter/tool out there also works, not just this repo's.

**Consequences.** Resolution is one pixel per character cell — a monitor at `TEXT_SCALE = 1` gives roughly 40×18 "pixels", closer to retro pixel art than a sharp photo. This is a hard ceiling of the platform, not a bug in the conversion — the `png_to_nfp.py` README sets that expectation up front. An earlier attempt this session at higher-resolution rendering used specific extended-ASCII character codepoints that turned out not to render as expected on the actual in-game font (see `../powah-energy-monitor/dashboard/README.md`'s "steampunk" ADR) — `.nfp` sidesteps that risk entirely, since drawing is just per-cell background *color*, nothing depends on a character glyph rendering a particular way.

## ADR: custom row-batched renderer, not `paintutils.drawImage`

**Context.** CC:Tweaked's built-in `paintutils.drawImage()` would work correctly, but draws one monitor call per pixel — for a 40×18 image that's up to 720 peripheral calls per photo change, most of them wasted on runs of identical background color.

**Decision.** `run.lua` parses `.nfp` itself and draws with the same same-color-RUN batching used throughout `../powah-energy-monitor/dashboard/run.lua`'s graph: scan each row left to right, one `setCursorPos` + `setBackgroundColor` + `write` per contiguous run of same-colored pixels, not one call per pixel.

**Consequences.** A photo with large flat-colored areas (sky, a solid background) collapses to a handful of calls per row instead of the image's full width — consistent with this repo's established "monitor calls are the real cost" performance stance. Only matters at the moment a photo changes (draw is otherwise idle between slides), but costs nothing to do properly.

## ADR: fetch every photo once at startup, not on each slide change

**Context.** Re-fetching a photo's `.nfp` text over HTTP every time the slideshow advances to it would mean a network round-trip in the middle of an otherwise-instant `monitor_touch` response, and a mid-show connectivity hiccup would blank a slide that was working a moment ago.

**Decision.** All photos listed in `manifest.txt` are fetched once, right after the manifest itself, before the slideshow starts. A photo that fails to fetch is skipped (logged, not fatal) rather than aborting the whole slideshow over one bad file.

**Consequences.** Startup takes a moment longer proportional to the number of photos (each is a small text file, this stays fast for a reasonable-sized collection), but every slide change afterward — timer or touch — is instant, no network dependency once running. A manifest entry with a typo'd filename just gets skipped with a log line, not a crash.

## ADR: touch-to-skip via `monitor_touch`, no web/Discord integration

**Context.** Letting players influence something in-game without wiring up an external service was an explicit ask — CC:Tweaked's Advanced Monitor already fires a `monitor_touch` event with the click coordinates, first-party, no extra peripheral needed.

**Decision.** Any touch anywhere on the monitor advances to the next photo immediately and resets the auto-advance timer (`os.cancelTimer` + a fresh `os.startTimer`), so a deliberate tap doesn't get immediately followed by a redundant auto-skip. Coordinates aren't used for anything yet — the whole monitor is one big "next" button.

**Consequences.** Dead simple to use (no explaining a UI, just tap the screen) and a working example of `monitor_touch` for future features from `../../README.md`'s idea list that want actual player-driven choices (e.g. a touch-based menu with real button regions, using the same event with `x`/`y` this time compared against a layout).
