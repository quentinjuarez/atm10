# Clips

Each subfolder here is one playable clip: `clips/<name>/frames.ccv` + `clips/<name>/audio.dfpwm`. `run.lua`'s `CLIP_NAME` constant picks which one plays.

No clip ships by default — see [`../../../tools/video_to_ccv.py`](../../../tools/video_to_ccv.py) (run on your own computer, not in Minecraft) to generate one from a video file you already have, then push the resulting `clips/<name>/` folder here and update `CLIP_NAME` in `../run.lua`.

Keep clips short (a few seconds to well under a minute) and low-res/low-fps — see [`../README.md`](../README.md)'s ADRs for why that's the platform's real ceiling, not just a suggestion.
