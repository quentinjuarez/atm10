# Tools

Python scripts that run on **your own computer**, not in Minecraft/CC:Tweaked — CC:Tweaked's Lua sandbox has no image or video codec, so converting a photo/video into something [`../scripts/photo-viewer/`](../scripts/photo-viewer/) or [`../scripts/video-player/`](../scripts/video-player/) can display has to happen outside the game, once, before you push the result into the repo.

## Setup

```
pip install Pillow
```

`video_to_ccv.py` additionally needs **ffmpeg** on your `PATH` (frame extraction, and audio encoding to DFPWM if your ffmpeg build supports the `dfpwm` encoder — see that script's own comments for the fallback if it doesn't).

## `png_to_nfp.py`

Converts a PNG/JPG into `.nfp` — CC:Tweaked's own pixel-image text format (one character per pixel, 16 colors). See [`../scripts/photo-viewer/README.md`](../scripts/photo-viewer/README.md) for the format itself and why resolution is capped at one pixel per monitor character cell.

```
python3 png_to_nfp.py photo.png --width 40 --height 18 -o ../scripts/photo-viewer/images/photo.nfp
```

## `video_to_ccv.py`

Converts a short video clip into `frames.ccv` + `audio.dfpwm` for [`../scripts/video-player/`](../scripts/video-player/) — see that folder's README for what this format actually is (pre-converted pixel-art frames + compressed audio, not a real video codec, and definitely not a live YouTube stream).

```
python3 video_to_ccv.py clip.mp4 --fps 6 --width 40 --height 18 -o ../scripts/video-player/clips/myclip
```

Keep source clips short — a few seconds to well under a minute. This produces plain text/data files fetched over HTTP into a Lua sandbox's memory, not a media pipeline built for anything longer.

## Why these aren't in-game scripts

Both share logic (`image_to_nfp_lines()` in `png_to_nfp.py`, imported by `video_to_ccv.py` so a video's frames are quantized identically to a still photo) that depends on Pillow and, for video, ffmpeg — neither of which exist inside CC:Tweaked's Lua sandbox. The Minecraft-side scripts only ever fetch and display files that already exist; nothing about the actual conversion could run in-game even in principle.
