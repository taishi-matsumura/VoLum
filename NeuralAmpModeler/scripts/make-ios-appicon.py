#!/usr/bin/env python3
"""Regenerate the iOS/iPadOS app icon as a full-bleed, opaque 1024x1024 PNG.

iOS masks the app icon into its own continuous-corner shape and composites
transparent pixels over a light backdrop, so an icon that ships as a pre-rounded
tile floating on a transparent canvas shows up on the home screen with a pale
frame around it (worst on iPad, where the icon renders large). The same padded
PNG also trips App Store validation (ITMS-90704: the marketing icon must not
carry an alpha channel).

The branding art that ships today is that padded tile. Its macOS 1024 slot
(icon_512x512@2x.png, byte-identical to the old iOSAppIcon.png) keeps the padded
master, so this tool derives the iOS icon from it:

  1. crop the tile body (drop the transparent margin),
  2. inpaint the tile's own rounded corners so the crop squares off,
  3. scale it to cover the 1024x1024 canvas edge-to-edge, centred,
  4. flatten to RGB so no alpha survives, and let iOS do the rounding.

Usage:
  python3 NeuralAmpModeler/scripts/make-ios-appicon.py           # rewrite in place
  python3 NeuralAmpModeler/scripts/make-ios-appicon.py --check   # report, no write
  Add --source <padded master png> --out <png> to build from new art.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

APPICONSET = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.realpath(__file__)),
        os.pardir,
        "resources",
        "Images.xcassets",
        "AppIcon.appiconset",
    )
)
MASTER = os.path.join(APPICONSET, "icon_512x512@2x.png")
OUTPUT = os.path.join(APPICONSET, "iOSAppIcon.png")

CANVAS = 1024
# Overscale a hair so the scaled tile clears the canvas edges on every side and
# the mask's corner cut lands on flat tile edge, never on a gap.
BLEED = 1.010
TILE_ALPHA = 64


def tile_bbox(rgba):
    """Tile body bbox (left, top, right, bottom); right/bottom exclusive."""
    ys, xs = np.nonzero(rgba[..., 3] >= TILE_ALPHA)
    if not len(xs):
        raise SystemExit("source has no opaque tile body to crop")
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def inpaint(rgb, mask, rounds=500):
    """Grow `mask` outward by averaging lit neighbours until nothing is left over.

    Used to fill the tile's rounded corners with a continuation of its own
    border, so upscaling leaves no transparent notches behind.
    """
    rgb = rgb.astype(np.float32)
    lit = mask.copy()
    h, w = lit.shape
    for _ in range(rounds):
        if lit.all():
            break
        pad = np.pad(lit, 1)
        count = np.zeros(lit.shape, dtype=np.int16)
        acc = np.zeros((*lit.shape, 3), dtype=np.float32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == dx == 0:
                    continue
                window = pad[1 + dy : 1 + dy + h, 1 + dx : 1 + dx + w]
                count += window
                acc += window[..., None] * rgb
        newly = (~lit) & (count >= 2)
        if not newly.any():
            break
        acc[newly] /= np.maximum(count[newly], 1)[..., None]
        rgb[newly] = acc[newly]
        lit |= newly
    if not lit.all():
        raise SystemExit("could not fill every corner of the tile body")
    return rgb


def build(source, out):
    rgba = np.array(Image.open(source).convert("RGBA"))
    left, top, right, bottom = tile_bbox(rgba)
    crop = rgba[top:bottom, left:right]
    filled = inpaint(crop[..., :3], crop[..., 3] >= TILE_ALPHA)

    width, height = right - left, bottom - top
    scale = max(CANVAS / width, CANVAS / height) * BLEED
    up_w, up_h = (int(round(width * scale)), int(round(height * scale)))
    tile = Image.fromarray(filled.astype(np.uint8), "RGB")
    tile = tile.resize((up_w, up_h), Image.LANCZOS)

    # Opaque backing underneath, so no sliver of the tile can leave a hole.
    icon = Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0))
    icon.paste(tile, ((CANVAS - up_w) // 2, (CANVAS - up_h) // 2))
    icon.save(out, "PNG", optimize=True)
    return (left, top, right, bottom), round(scale, 4)


def check(path):
    """Report whether an iOS app icon is fit to ship; non-zero exit if not."""
    if not os.path.exists(path):
        print(f"missing iOS app icon: {path}")
        return 1
    im = Image.open(path)
    problems = []
    if im.size != (CANVAS, CANVAS):
        problems.append(
            f"size is {im.size[0]}x{im.size[1]}, expected {CANVAS}x{CANVAS}"
        )
    if im.mode != "RGB":
        rgba = np.array(im.convert("RGBA"))
        left, top, right, bottom = tile_bbox(rgba)
        inset = min(left, top, CANVAS - 1 - right, CANVAS - 1 - bottom)
        problems.append(
            "icon carries transparency (alpha min %d, artwork inset %dpx); iOS "
            "composites those pixels over a light backdrop, which reads as a "
            "white frame" % (int(rgba[..., 3].min()), inset)
        )
    if problems:
        print(f"{path} is not a full-bleed iOS icon:")
        for p in problems:
            print(f"  - {p}")
        print("fix: python3 NeuralAmpModeler/scripts/make-ios-appicon.py")
        return 1
    print(f"{path} ok: {CANVAS}x{CANVAS}, opaque, full-bleed")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--source", default=MASTER, help="padded master artwork")
    ap.add_argument("--out", default=OUTPUT, help="PNG to write")
    ap.add_argument(
        "--check", action="store_true", help="validate the shipped icon instead of writing"
    )
    args = ap.parse_args()

    if args.check:
        return check(args.out)

    src = os.path.abspath(args.source)
    if not os.path.exists(src):
        raise SystemExit(f"no master artwork at {src}")
    src_rgba = np.array(Image.open(src).convert("RGBA"))
    left, top, right, bottom = tile_bbox(src_rgba)
    if min(left, top) < CANVAS // 50:
        raise SystemExit(
            f"{src} already looks full-bleed (bbox {(left, top, right, bottom)}); "
            "refusing to upscale it a second time"
        )

    bbox, scale = build(src, args.out)
    print(f"master tile bbox {bbox} -> {CANVAS}x{CANVAS} at {scale}x, opaque")
    print(f"wrote {os.path.relpath(args.out, os.getcwd())}")
    return check(args.out)


if __name__ == "__main__":
    sys.exit(main())
