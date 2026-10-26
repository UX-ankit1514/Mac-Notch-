#!/usr/bin/env python3
"""Step 1: cut the 12 storyboard poses out of the Figma sheet.

The sheet (Figma "Untitled" → Page 2 → Emotion, image eb75f1…) is a 3×4 grid.
Each cell shows the expanded notch with the character peeking up from its
bottom edge. We crop the notch interior (below the menu-bar strip, so the
camera dot is excluded), centre it on the notch, and bottom-align every pose
on one common canvas so poses stay registered when cross-faded at runtime.

Usage: crop_poses.py <sheet.png> <out_dir>
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

POSES = [
    "p01_idle_peek", "p02_look_around", "p03_blink",
    "p04_curious", "p05_notice", "p06_call_attention",
    "p07_point", "p08_serious", "p09_thinking",
    "p10_happy", "p11_playful", "p12_retreat",
]
COLS = [(0, 510), (513, 1023), (1026, 1536)]
ROWS = [(0, 252), (255, 494), (497, 744), (747, 1024)]
HALF_WIDTH = 150          # crop is 300 px wide, centred on the notch
DARK = 45                 # luminance below this counts as notch black


def measure(cell: np.ndarray) -> dict:
    lum = cell.mean(axis=2)
    h, w = lum.shape
    dark = lum < DARK

    full_rows = np.nonzero(dark.mean(axis=1) > 0.95)[0]
    strip_bottom = int(full_rows.max())

    probe = strip_bottom + 15
    xs = np.nonzero(dark[probe, 30:w - 30])[0] + 30
    left, right = int(xs.min()), int(xs.max())

    # The notch ends at the first row where the grey surround spans the
    # whole notch width (character pixels never cover that much of a row).
    y = strip_bottom + 20
    while y < h and (lum[y, left:right] > 90).mean() < 0.9:
        y += 1
    bottom = y - 1
    return {"strip_bottom": strip_bottom, "left": left, "right": right,
            "bottom": bottom, "cx": (left + right) // 2}


def notch_mask(lum: np.ndarray, x0: int, x1: int) -> np.ndarray:
    """Per-row interior of the notch, found by scanning in from both sides
    until the grey surround turns dark. Handles the rounded bottom corners."""
    h, _ = lum.shape
    mask = np.zeros(lum.shape, dtype=bool)
    for y in range(h):
        row = lum[y]
        l = x0
        while l < x1 and row[l] > 90:
            l += 1
        r = x1 - 1
        while r > l and row[r] > 90:
            r -= 1
        mask[y, l:r + 1] = True
    return mask


def main() -> None:
    sheet_path, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    sheet = np.asarray(Image.open(sheet_path).convert("RGB")).astype(np.int32)

    crops, meta = [], {}
    for i, name in enumerate(POSES):
        (y0, y1), (x0, x1) = ROWS[i // 3], COLS[i % 3]
        cell = sheet[y0:y1, x0:x1]
        m = measure(cell)
        top, bottom = m["strip_bottom"] + 1, m["bottom"]
        cl, cr = m["cx"] - HALF_WIDTH, m["cx"] + HALF_WIDTH
        crop = cell[top:bottom + 1, cl:cr].copy()

        lum = crop.mean(axis=2)
        inside = notch_mask(lum, 0, crop.shape[1])
        crop[~inside] = 0

        crops.append((name, crop))
        meta[name] = {"cell": [x0, y0, x1, y1], **m,
                      "crop_src": [x0 + cl, y0 + top, x0 + cr, y0 + bottom + 1]}

    height = max(c.shape[0] for _, c in crops)
    for name, crop in crops:
        canvas = np.zeros((height, 2 * HALF_WIDTH, 3), dtype=np.uint8)
        canvas[height - crop.shape[0]:] = np.clip(crop, 0, 255).astype(np.uint8)
        Image.fromarray(canvas).save(out_dir / f"{name}.png")
        meta[name]["canvas_pad_top"] = height - crop.shape[0]

    (out_dir / "crops.json").write_text(json.dumps(
        {"canvas": [2 * HALF_WIDTH, height], "poses": meta}, indent=2))
    print(f"cropped {len(crops)} poses to {2 * HALF_WIDTH}x{height}")


if __name__ == "__main__":
    main()
