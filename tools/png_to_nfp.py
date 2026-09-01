#!/usr/bin/env python3
"""Convert a PNG/JPG into a CC:Tweaked .nfp pixel-image file.

Runs on YOUR OWN computer, NOT in Minecraft/CC:Tweaked -- see this
folder's README.md for why. Output goes straight into
../scripts/photo-viewer/images/ (or ../scripts/video-player/ frame
extraction uses the same palette/quantize logic, see video_to_ccv.py).

Usage:
    python3 png_to_nfp.py photo.png --width 40 --height 18 -o testcard.nfp

--width/--height should roughly match your target monitor's character
grid (check in-game: `lua` console on the computer, then `monitor.getSize()`).
The image is letterboxed (aspect-ratio preserved, padded with black) to
fit exactly that many character cells -- CC:Tweaked draws one pixel per
character cell, there's no sub-cell resolution here (see
../scripts/photo-viewer/README.md's format ADR for why that's the
platform's real ceiling, not a shortcut this script is taking).
"""

import argparse
import sys

from PIL import Image

# CC:Tweaked's default 16-color palette (approximate RGB -- matches the
# game's own default term/monitor palette). Index N here is the color
# colors.toBlit() encodes as hex digit N -- NOT a guess, it's how that
# function is defined (digit = index of the color's bit position).
PALETTE = [
    (0xF0, 0xF0, 0xF0),  # 0 white
    (0xF2, 0xB2, 0x33),  # 1 orange
    (0xE5, 0x7F, 0xD8),  # 2 magenta
    (0x99, 0xB2, 0xF2),  # 3 lightBlue
    (0xDE, 0xDE, 0x6C),  # 4 yellow
    (0x7F, 0xCC, 0x19),  # 5 lime
    (0xF2, 0xB2, 0xCC),  # 6 pink
    (0x4C, 0x4C, 0x4C),  # 7 gray
    (0x99, 0x99, 0x99),  # 8 lightGray
    (0x4C, 0x99, 0xB2),  # 9 cyan
    (0xB2, 0x66, 0xE5),  # a purple
    (0x33, 0x66, 0xCC),  # b blue
    (0x7F, 0x66, 0x4C),  # c brown
    (0x57, 0xA6, 0x4E),  # d green
    (0xCC, 0x4C, 0x4C),  # e red
    (0x11, 0x11, 0x11),  # f black
]
DIGITS = "0123456789abcdef"


def nearest_digit(rgb):
    r, g, b = rgb[:3]
    best_i, best_dist = 0, None
    for i, (pr, pg, pb) in enumerate(PALETTE):
        dist = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if best_dist is None or dist < best_dist:
            best_i, best_dist = i, dist
    return DIGITS[best_i]


def image_to_nfp_lines(img, width, height):
    """Letterbox `img` (a PIL Image) into width x height and quantize to
    the 16-color palette, returning a list of row strings (no trailing
    newline) -- the shared core also used by video_to_ccv.py so a video's
    frames are quantized with exactly the same logic as a still photo."""
    img = img.convert("RGB")

    # Letterbox: scale to fit inside width x height, keep aspect ratio,
    # pad the rest with black -- avoids a stretched/distorted result.
    scale = min(width / img.width, height / img.height)
    new_w = max(1, round(img.width * scale))
    new_h = max(1, round(img.height * scale))
    img = img.resize((new_w, new_h), Image.LANCZOS)

    canvas = Image.new("RGB", (width, height), (0x11, 0x11, 0x11))
    off_x = (width - new_w) // 2
    off_y = (height - new_h) // 2
    canvas.paste(img, (off_x, off_y))

    pixels = canvas.load()
    lines = []
    for y in range(height):
        row = [nearest_digit(pixels[x, y]) for x in range(width)]
        lines.append("".join(row))
    return lines


def convert(src_path, width, height):
    img = Image.open(src_path)
    lines = image_to_nfp_lines(img, width, height)
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", help="source PNG/JPG path")
    parser.add_argument("--width", type=int, default=40, help="target character columns (default 40)")
    parser.add_argument("--height", type=int, default=18, help="target character rows (default 18)")
    parser.add_argument("-o", "--output", help="output .nfp path (default: same name, .nfp extension)")
    args = parser.parse_args()

    if args.width < 1 or args.height < 1:
        sys.exit("--width and --height must both be positive")

    out_path = args.output
    if not out_path:
        stem = args.image.rsplit(".", 1)[0]
        out_path = stem + ".nfp"

    nfp_text = convert(args.image, args.width, args.height)
    with open(out_path, "w") as f:
        f.write(nfp_text)

    print(f"Wrote {out_path} ({args.width}x{args.height} pixels)")
    print("Now: drop it into scripts/photo-viewer/images/ and add its filename to manifest.txt")


if __name__ == "__main__":
    main()
