#!/usr/bin/env python3
"""Keeps only the notch from screen captures, so documentation images never
show the desktop around it (tab titles, terminal text, menu-bar items).

The notch is pure black and hangs from the top edge; everything connected to
that black region (plus what it encloses: the character, the text) is kept,
the rest becomes a neutral background.

Usage: sanitize_captures.py <out.png> <columns> <frame.png>...
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

BACKGROUND = (231, 231, 234)


def notch_only(path: Path) -> Image.Image:
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    h, w, _ = rgb.shape
    # Thin dark lines (window edges) are opened away so they can't join the notch.
    black = ndimage.binary_opening(rgb.max(axis=2) < 10, iterations=3)
    labels, _ = ndimage.label(black)
    seeds = set(labels[0:6, w // 2 - 120:w // 2 + 120].ravel()) - {0}
    notch = np.isin(labels, list(seeds)) if seeds else np.zeros_like(black)
    rows = np.nonzero(notch.any(axis=1))[0]
    mask = np.zeros_like(notch)
    if len(rows):
        # Rebuild the shape from its bounds rather than tracing pixels: the
        # character can cover the edge, and nothing outside the notch leaks in.
        cols = np.nonzero(notch.any(axis=0))[0]
        # Captures are centred on the notch and the shape is symmetric, so the
        # side the character doesn't cover gives the true half-width.
        half = max(w / 2 - np.percentile(cols, 1), np.percentile(cols, 99) - w / 2)
        left, right = w / 2 - half, w / 2 + half
        bottom = rows.max()
        radius = 24 if bottom < 100 else 48          # 12 / 24 pt corners at @2x
        shape = Image.new("L", (w, h), 0)
        ImageDraw.Draw(shape).rounded_rectangle((left, -radius, right, bottom), radius, fill=255)
        mask = np.asarray(shape) > 127
    out = np.where(mask[..., None], rgb, np.array(BACKGROUND, dtype=np.int16))
    return Image.fromarray(out.astype(np.uint8))


def main() -> None:
    out, columns, frames = Path(sys.argv[1]), int(sys.argv[2]), [Path(p) for p in sys.argv[3:]]
    images = [notch_only(f) for f in frames]
    w, h = images[0].size
    rows = (len(images) + columns - 1) // columns
    label_h = 36
    sheet = Image.new("RGB", (columns * w + (columns - 1) * 12, rows * (h + label_h)), (250, 250, 251))
    draw = ImageDraw.Draw(sheet)
    for i, (frame, image) in enumerate(zip(frames, images)):
        x, y = (i % columns) * (w + 12), (i // columns) * (h + label_h)
        sheet.paste(image, (x, y))
        draw.text((x + 10, y + h + 10), frame.stem, fill=(70, 70, 76))
    sheet.save(out, optimize=True)
    print(f"{len(images)} frames → {out} {sheet.size}")


if __name__ == "__main__":
    main()
