#!/usr/bin/env python3
"""Convert a short video clip into a CC:Tweaked-playable bundle:
frames.ccv (pixel-art frames) + audio.dfpwm (compressed audio), for
../scripts/video-player/.

Runs on YOUR OWN computer, NOT in Minecraft/CC:Tweaked -- see this
folder's README.md for why, and ../scripts/video-player/README.md's
"What this actually is" section for what this format can and can't do
(short + low-res + low-fps clips, not a movie).

REQUIRES ffmpeg on your PATH (both for frame extraction and for audio
encoding -- see the note below if `-c:a dfpwm` isn't available in your
ffmpeg build).

Usage:
    python3 video_to_ccv.py clip.mp4 --fps 6 --width 40 --height 18 -o ../scripts/video-player/clips/myclip

Keep clips SHORT. A 40x18 clip at 6fps for 10 seconds is already
60 frames * 18 rows = 1080 text lines held in the CC:Tweaked computer's
memory at once, fetched in one HTTP request -- fine; a 2-minute clip at
that same size is 30x bigger and starts pushing against what's
reasonable for a Lua sandbox and a GitHub-raw-hosted text file.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# Reuses the exact same palette/quantize logic as photo conversion, so a
# video's frames and a photo shown by ../scripts/photo-viewer/ look
# consistent -- same colors, same letterboxing.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_to_nfp import image_to_nfp_lines  # noqa: E402
from PIL import Image  # noqa: E402


def require_ffmpeg():
    if shutil.which("ffmpeg") is None:
        sys.exit(
            "ffmpeg not found on PATH. Install it first (e.g. `apt install ffmpeg`, "
            "`brew install ffmpeg`, or download from ffmpeg.org) -- this script uses "
            "it for both frame extraction and audio encoding."
        )


def extract_frames(src_path, fps, tmp_dir):
    pattern = os.path.join(tmp_dir, "frame_%06d.png")
    cmd = ["ffmpeg", "-y", "-i", src_path, "-vf", f"fps={fps}", pattern]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"ffmpeg frame extraction failed:\n{result.stderr[-2000:]}")
    frames = sorted(f for f in os.listdir(tmp_dir) if f.startswith("frame_"))
    if not frames:
        sys.exit("ffmpeg produced no frames -- check the input file and --fps.")
    return [os.path.join(tmp_dir, f) for f in frames]


def encode_audio(src_path, out_path):
    # DFPWM is CC:Tweaked's own audio format -- recent ffmpeg builds
    # support it natively as an encoder (`-c:a dfpwm`). If your ffmpeg
    # predates that, this will fail with an "Unknown encoder" error --
    # in that case, upgrade ffmpeg or use a standalone DFPWM encoder from
    # the CC:Tweaked community (search "dfpwm encoder") to produce
    # audio.dfpwm yourself and place it alongside frames.ccv by hand;
    # this script only automates the common case.
    cmd = ["ffmpeg", "-y", "-i", src_path, "-ar", "48000", "-ac", "1", "-c:a", "dfpwm", out_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print("WARNING: ffmpeg could not encode audio as dfpwm:", file=sys.stderr)
        print(result.stderr[-1500:], file=sys.stderr)
        print(
            "\nNo audio.dfpwm was written. The clip can still play silently if you "
            "skip audio entirely, or encode it yourself with a standalone DFPWM "
            "encoder and drop the result at the path above.",
            file=sys.stderr,
        )
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", help="source video file")
    parser.add_argument("--fps", type=int, default=6, help="frames per second to extract (default 6 -- keep this low)")
    parser.add_argument("--width", type=int, default=40, help="target character columns (default 40)")
    parser.add_argument("--height", type=int, default=18, help="target character rows (default 18)")
    parser.add_argument("-o", "--output-dir", required=True, help="output folder, e.g. ../scripts/video-player/clips/myclip")
    parser.add_argument("--no-audio", action="store_true", help="skip audio extraction entirely")
    args = parser.parse_args()

    if args.width < 1 or args.height < 1 or args.fps < 1:
        sys.exit("--width, --height and --fps must all be positive")

    require_ffmpeg()
    os.makedirs(args.output_dir, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp_dir:
        print(f"Extracting frames at {args.fps}fps...")
        frame_paths = extract_frames(args.video, args.fps, tmp_dir)
        frame_count = len(frame_paths)
        print(f"Got {frame_count} frame(s). Quantizing to {args.width}x{args.height}, 16 colors...")

        ccv_path = os.path.join(args.output_dir, "frames.ccv")
        with open(ccv_path, "w") as f:
            f.write(f"CCV1 {args.width} {args.height} {args.fps} {frame_count}\n")
            for i, path in enumerate(frame_paths, 1):
                img = Image.open(path)
                for line in image_to_nfp_lines(img, args.width, args.height):
                    f.write(line + "\n")
                if i % 20 == 0 or i == frame_count:
                    print(f"  {i}/{frame_count} frames written")

        print(f"Wrote {ccv_path}")

        if not args.no_audio:
            audio_path = os.path.join(args.output_dir, "audio.dfpwm")
            print("Encoding audio to DFPWM...")
            if encode_audio(args.video, audio_path):
                print(f"Wrote {audio_path}")

    duration = frame_count / args.fps
    print(f"\nClip is ~{duration:.1f}s at {args.fps}fps, {args.width}x{args.height}.")
    print(f"Next: push {args.output_dir}/ to the repo, set CLIP_NAME in scripts/video-player/run.lua to match its folder name.")


if __name__ == "__main__":
    main()
