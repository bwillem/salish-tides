#!/usr/bin/env python3
"""Regenerate the app-icon and launch-screen assets from the master logo.

Single source of truth: docs/logo.png — the hand-drawn mark (black strokes on a
transparent canvas), laid out as SALISH / eye-and-current emblem / TIDES.

Outputs into SalishTides/Assets.xcassets:
  AppIcon.appiconset/
    icon-light-1024.png   emblem, black ink on white   (Any appearance)
    icon-dark-1024.png    emblem, light ink on near-black (Dark appearance)
  LaunchLogo.imageset/
    launch-{light,dark}@{2,3}x.png   full wordmark, ink-only on transparent
  SplashEmblem.imageset/
    splash-emblem@{2,3}x.png   emblem silhouette, rendered as a TEMPLATE image
    (the in-app loading splash tints it with .primary, so no color is baked in)

App-icon PNGs are flattened to RGB (no alpha) — the App Store rejects icons with
an alpha channel. Launch images keep alpha so the wordmark composites over the
system background (white in light mode, black in dark).

Run from the repo root:  python3 dev/brand/make_brand_assets.py
Requires Pillow.  Re-run xcodegen / rebuild after regenerating.
"""
from pathlib import Path
from PIL import Image
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs" / "logo.png"
CAT = ROOT / "SalishTides" / "Assets.xcassets"

# Palette
WHITE = (255, 255, 255)     # light icon background
DARKBG = (13, 13, 15)       # dark icon background (near-black)
INK_DARK = (17, 17, 17)     # ink on light surfaces (#111)
INK_LIGHT = (242, 244, 246) # ink on dark surfaces

# Vertical crops of the 861x1100 master (rows), found from the whitespace bands
# between the three elements. FULL keeps the wordmark; EMBLEM is the eye+arrow.
FULL_BOX = (0, 30, 861, 1068)
EMBLEM_BOX = (0, 300, 861, 880)

# The emblem's rays fan out sparsely, so a plain alpha-bbox crop leaves the dense
# eye/arrow core small. Crop instead to the columns/rows carrying real ink (above
# this fraction of the peak), dropping the faint outer ray tips so the core fills
# the icon. Higher = tighter crop.
EMBLEM_CORE_THRESH = 0.12
ICON_MARGIN = 0.06     # padding around the emblem core inside the 1024 icon
LAUNCH_PT_WIDTH = 280  # on-screen width of the launch wordmark, in points
SPLASH_PT_WIDTH = 104  # on-screen width of the loading-splash emblem, in points


def ink(crop: Image.Image, color) -> Image.Image:
    """Recolor the mark: fill `color` wherever the master has ink (via alpha)."""
    solid = Image.new("RGBA", crop.size, color + (255,))
    solid.putalpha(crop.getchannel("A"))
    return solid


def make_icon(crop, bg, ink_color, path):
    W = 1024
    im = Image.new("RGB", (W, W), bg)  # RGB → no alpha, App Store-safe
    avail = int(W * (1 - 2 * ICON_MARGIN))
    cw, ch = crop.size
    scale = min(avail / cw, avail / ch)
    nw, nh = int(cw * scale), int(ch * scale)
    art = ink(crop, ink_color).resize((nw, nh), Image.LANCZOS)
    im.paste(art, ((W - nw) // 2, (W - nh) // 2), art)
    im.save(path)


def make_launch(full, color, scale, path):
    w = LAUNCH_PT_WIDTH * scale
    h = int(w * full.size[1] / full.size[0])
    ink(full, color).resize((int(w), h), Image.LANCZOS).save(path)


def emblem_core(emblem: Image.Image) -> Image.Image:
    """Crop to the dense eye/arrow core, dropping the sparse outer ray tips."""
    a = np.array(emblem.getchannel("A"))
    cols = a.sum(axis=0)
    rows = a.sum(axis=1)
    cx = np.where(cols > cols.max() * EMBLEM_CORE_THRESH)[0]
    ry = np.where(rows > rows.max() * EMBLEM_CORE_THRESH)[0]
    return emblem.crop((cx[0], ry[0], cx[-1], ry[-1]))


def main():
    logo = Image.open(SRC).convert("RGBA")
    full = logo.crop(FULL_BOX)
    emblem = emblem_core(logo.crop(EMBLEM_BOX))

    icons = CAT / "AppIcon.appiconset"
    make_icon(emblem, WHITE, INK_DARK, icons / "icon-light-1024.png")
    make_icon(emblem, DARKBG, INK_LIGHT, icons / "icon-dark-1024.png")

    launch = CAT / "LaunchLogo.imageset"
    make_launch(full, INK_DARK, 2, launch / "launch-light@2x.png")
    make_launch(full, INK_DARK, 3, launch / "launch-light@3x.png")
    make_launch(full, INK_LIGHT, 2, launch / "launch-dark@2x.png")
    make_launch(full, INK_LIGHT, 3, launch / "launch-dark@3x.png")

    # Loading-splash emblem: a single template image (ink color is irrelevant —
    # SwiftUI tints it via .foregroundStyle). Uses the same tight core crop.
    splash = CAT / "SplashEmblem.imageset"
    for scale in (2, 3):
        w = SPLASH_PT_WIDTH * scale
        h = int(w * emblem.size[1] / emblem.size[0])
        ink(emblem, INK_DARK).resize((int(w), h), Image.LANCZOS).save(
            splash / f"splash-emblem@{scale}x.png"
        )
    print("Regenerated app-icon, launch, and splash assets into", CAT)


if __name__ == "__main__":
    main()
