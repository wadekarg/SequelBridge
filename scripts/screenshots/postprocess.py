#!/usr/bin/env python3
"""postprocess.py IN OUT — trim a window capture to its content plus shadow, scale it to
1.5x of the logical window width, and write an optimized PNG (budget: 400 KB).

A window capture with its shadow is transparent outside the shadow, so the bounding
box of the alpha channel is the crop; a region capture has no alpha and is kept whole."""
import os
import sys

from PIL import Image

BUDGET = 400_000
LOGICAL_WIDTH = 1440          # the window the driver sets
TARGET_SCALE = 1.5

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
bbox = im.getbbox()
if bbox:
    im = im.crop(bbox)
# Captures are 2x (Retina); scale every one of them — the main window, a smaller window
# such as Settings — to 1.5x, keeping the shadow margins in proportion.
scale = TARGET_SCALE / 2
im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
im.save(dst, optimize=True)
size = os.path.getsize(dst)
if size > BUDGET:            # fall back to a 256-colour palette (octree keeps the alpha channel)
    im.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG).save(dst, optimize=True)
    size = os.path.getsize(dst)
print(f"{dst}: {im.width}x{im.height}, {size // 1024} KB")
sys.exit(0 if size <= BUDGET else 1)
