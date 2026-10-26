#!/usr/bin/env python3
"""Step 4+5: turn each upscaled, matted pose into an animation-ready 2.5D rig.

Inputs (all 4× upscaled, same canvas):
  work/up/<pose>.png     RGB render on black
  work/mask/<pose>.png   Vision subject matte (L8)
  rigs/hands.json        hand polygons + wrist pivots (hand-authored)

Per pose this writes, at @2x of a 300×116 pt canvas:
  body.png      character with pupils and hand removed (diffusion-inpainted)
  pupil_N.png   pupil sprites (move inside the eye ellipse at runtime)
  hand.png      hand sprite (rotates about its wrist pivot)
  fx.png        white tick / "?" strokes (pop in at runtime)
and one rig.json describing every layer in canvas units (0…300, 0…116).

Usage: build_rig.py <pipeline_dir> <resources_out_dir>
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

UPSCALE = 4               # work/up is 4× the 300×116 canvas
OUT_SCALE = 2             # ship @2x
DOWN = UPSCALE // OUT_SCALE


def load(pipeline: Path, pose: str):
    rgb = np.asarray(Image.open(pipeline / "work/up" / f"{pose}.png").convert("RGB")).astype(np.float32)
    mask = np.asarray(Image.open(pipeline / "work/mask" / f"{pose}.png").convert("L")).astype(np.float32) / 255
    return rgb, mask


def luminance(rgb):
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


def saturation(rgb):
    mx, mn = rgb.max(axis=-1), rgb.min(axis=-1)
    return np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)


def inpaint(rgba: np.ndarray, hole: np.ndarray, iterations: int = 400,
            crisp_alpha: bool = False) -> np.ndarray:
    """Fill `hole` by repeatedly averaging the 4-neighbourhood (harmonic fill).
    Smooth and seam-free at notch display size; colour and alpha both diffuse.
    With crisp_alpha the diffused alpha is snapped to a clean silhouette so a
    removed hand leaves face-or-background behind, never a translucent smudge."""
    if not hole.any():
        return rgba
    ys, xs = np.nonzero(hole)
    pad = 6
    y0, y1 = max(ys.min() - pad, 0), min(ys.max() + pad + 1, hole.shape[0])
    x0, x1 = max(xs.min() - pad, 0), min(xs.max() + pad + 1, hole.shape[1])
    patch = rgba[y0:y1, x0:x1].copy()
    h = hole[y0:y1, x0:x1]
    # premultiply so transparent neighbours don't drag colour toward black
    prem = patch.copy()
    prem[..., :3] *= prem[..., 3:4]
    known = prem.copy()
    prem[h] = prem[~h].mean(axis=0)
    for _ in range(iterations):
        p = np.pad(prem, ((1, 1), (1, 1), (0, 0)), mode="edge")
        avg = (p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:]) / 4
        prem = np.where(h[..., None], avg, known)
    a = np.clip(prem[..., 3:4], 1e-4, 1)
    prem[..., :3] = np.where(prem[..., 3:4] > 1e-3, prem[..., :3] / a, 0)
    if crisp_alpha:
        a = prem[..., 3] / 255 if prem[..., 3].max() > 1.5 else prem[..., 3]
        t = np.clip((a - 0.45) / 0.2, 0, 1)
        snapped = t * t * (3 - 2 * t)
        prem[..., 3] = snapped * (255 if patch[..., 3].max() > 1.5 else 1)
    patch[h] = prem[h]
    out = rgba.copy()
    out[y0:y1, x0:x1] = patch
    return out


def ellipse_fit(region: np.ndarray):
    ys, xs = np.nonzero(region)
    cx, cy = xs.mean(), ys.mean()
    cov = np.cov(np.vstack([xs - cx, ys - cy]))
    evals, evecs = np.linalg.eigh(cov)
    ry, rx = 2 * np.sqrt(evals)          # eigh: ascending → minor, major
    angle = float(np.degrees(np.arctan2(evecs[1, 1], evecs[0, 1])))
    if angle > 90:
        angle -= 180
    if angle < -90:
        angle += 180
    return float(cx), float(cy), float(rx), float(ry), angle


def ellipse_mask(shape, cx, cy, rx, ry, angle):
    yy, xx = np.mgrid[0:shape[0], 0:shape[1]].astype(np.float32)
    t = np.radians(angle)
    dx, dy = xx - cx, yy - cy
    u = dx * np.cos(t) + dy * np.sin(t)
    v = -dx * np.sin(t) + dy * np.cos(t)
    return (u / rx) ** 2 + (v / ry) ** 2 <= 1


def find_eyes(rgb, mask):
    lum, sat = luminance(rgb), saturation(rgb)
    white = (lum > 175) & (sat < 0.22) & (mask > 0.5)
    black = (lum < 48) & (mask > 0.5)
    labels, n = ndimage.label(white)
    eyes = []
    for i in range(1, n + 1):
        comp = labels == i
        area = comp.sum()
        if area < 2500:                       # specks, AirPod tips
            continue
        grow = ndimage.binary_dilation(comp, iterations=10)
        hull = ndimage.binary_fill_holes(ndimage.binary_closing(grow, iterations=4))
        pupil_labels, pn = ndimage.label(black & hull)
        if pn == 0:
            continue
        sizes = ndimage.sum(np.ones_like(lum), pupil_labels, range(1, pn + 1))
        pupil = pupil_labels == (int(np.argmax(sizes)) + 1)
        pupil = ndimage.binary_fill_holes(ndimage.binary_closing(pupil, iterations=2))
        if pupil.sum() < 0.025 * area or pupil.sum() > 1.2 * area:
            continue
        opening = ndimage.binary_fill_holes(ndimage.binary_closing(comp | pupil, iterations=3))
        cx, cy, rx, ry, ang = ellipse_fit(opening)
        # Eyes are near-round; cap highlights and AirPods are long and flat.
        if ry < 20 or rx / ry > 2.2:
            continue
        # Validated as an eye. Pupils are round: keep the largest inscribed disc, which drops thin
        # eye-outline and lash fragments that touch the pupil.
        dist = ndimage.distance_transform_edt(pupil)
        if dist.max() >= 3:
            py, px = np.unravel_index(int(np.argmax(dist)), dist.shape)
            radius = dist.max() + 1.5
            yy, xx = np.ogrid[0:pupil.shape[0], 0:pupil.shape[1]]
            pupil = ((xx - px) ** 2 + (yy - py) ** 2 <= radius ** 2) & ndimage.binary_dilation(pupil, iterations=2)
        pys, pxs = np.nonzero(pupil)
        pr = float(np.sqrt(pupil.sum() / np.pi))
        eyes.append({"opening": opening, "pupil": pupil,
                     "ellipse": [cx, cy, rx, ry, ang],
                     "pupil_center": [float(pxs.mean()), float(pys.mean())], "pupil_r": pr})
    eyes.sort(key=lambda e: -e["opening"].sum())
    eyes = sorted(eyes[:2], key=lambda e: e["ellipse"][0])
    return eyes


def skin_color(rgb, mask, eyes):
    """Median skin tone in a band around the eyes: what an eyelid looks like."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    skin = (mask > 0.9) & (r > 170) & (r > g + 25) & (g > b + 10) & (saturation(rgb) > 0.22) \
        & (saturation(rgb) < 0.55) & (luminance(rgb) > 150)
    if eyes:
        band = np.zeros_like(skin)
        for e in eyes:
            cx, cy, rx, ry, _ = e["ellipse"]
            band[int(max(cy - 3 * ry, 0)):int(cy + 3 * ry), int(max(cx - 2 * rx, 0)):int(cx + 2 * rx)] = True
        if (skin & band).sum() > 500:
            skin &= band
    return [int(v) for v in np.median(rgb[skin], axis=0)]


def fx_layer(rgb, mask):
    lum, sat = luminance(rgb), saturation(rgb)
    # Strokes sit clear of the character; the dilation keeps AirPod edges out.
    near_subject = ndimage.binary_dilation(mask > 0.35, iterations=8)
    strokes = (lum > 150) & (sat < 0.25) & ~near_subject
    strokes = ndimage.binary_opening(strokes, iterations=1)
    labels, n = ndimage.label(strokes)
    keep = np.zeros_like(strokes)
    for i in range(1, n + 1):
        comp = labels == i
        if comp.sum() >= 60:
            keep |= comp
    if keep.sum() < 200:
        return None
    region = ndimage.binary_dilation(keep, iterations=3)
    alpha = np.clip((lum - 40) / 160, 0, 1) * region
    return alpha


def polygon_mask(shape, pts):
    img = Image.new("L", (shape[1], shape[0]), 0)
    ImageDraw.Draw(img).polygon([tuple(p) for p in pts], fill=255)
    return np.asarray(img) > 127


def save_rgba(arr: np.ndarray, path: Path, crop: bool = False):
    """Downsample 4× → 2× and write. With crop=True, trims to the alpha bbox
    and returns that bbox (in output pixels)."""
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    img = img.resize((img.width // DOWN, img.height // DOWN), Image.LANCZOS)
    box = None
    if crop:
        bbox = img.getchannel("A").point(lambda v: 255 if v > 3 else 0).getbbox()
        if bbox is None:
            return None
        pad = 2
        box = (max(bbox[0] - pad, 0), max(bbox[1] - pad, 0),
               min(bbox[2] + pad, img.width), min(bbox[3] + pad, img.height))
        img = img.crop(box)
    img.save(path, optimize=True)
    return box


def to_units(v):            # 4× pixels → canvas units (pt)
    return round(float(v) / UPSCALE, 2)


def main():
    pipeline, out_root = Path(sys.argv[1]), Path(sys.argv[2])
    crops = json.loads((pipeline / "work/crops/crops.json").read_text())
    hands = json.loads((pipeline / "rigs/hands.json").read_text())
    canvas_w, canvas_h = crops["canvas"]
    rig = {"canvas": [canvas_w, canvas_h], "scale": OUT_SCALE, "poses": {}}

    for pose in crops["poses"]:
        rgb, mask = load(pipeline, pose)
        outdir = out_root / pose
        outdir.mkdir(parents=True, exist_ok=True)
        rgba = np.dstack([rgb, mask * 255]).astype(np.float32)
        entry = {"body": f"{pose}/body.png", "eyes": [], "hand": None, "fx": None}

        # FX strokes live outside the subject matte; lift them first.
        fx_alpha = fx_layer(rgb, mask)
        if fx_alpha is not None:
            fx = np.dstack([np.full_like(rgb, 255), fx_alpha * 255])
            box = save_rgba(fx, outdir / "fx.png", crop=True)
            ys, xs = np.nonzero(fx_alpha > 0.2)
            entry["fx"] = {"image": f"{pose}/fx.png",
                           "frame": [b / OUT_SCALE for b in box],
                           "pivot": [to_units(xs.mean()), to_units(ys.mean())]}

        # Hand: cut along the authored polygon, inpaint what was behind it.
        spec = hands.get(pose)
        if spec:
            poly = polygon_mask(mask.shape, spec["polygon"])
            hand = rgba.copy()
            hand[..., 3] *= poly
            box = save_rgba(hand, outdir / "hand.png", crop=True)
            rgba = inpaint(rgba, poly & (mask > 0.02), crisp_alpha=True)
            entry["hand"] = {"image": f"{pose}/hand.png",
                             "frame": [b / OUT_SCALE for b in box],
                             "pivot": [to_units(spec["pivot"][0]), to_units(spec["pivot"][1])]}

        # Eyes: sprite the pupils, then fill the sclera where they were.
        eyes = find_eyes(rgb, mask)
        lid = skin_color(rgb, mask, eyes)
        for idx, eye in enumerate(eyes):
            cx, cy, rx, ry, ang = eye["ellipse"]
            pupil = ndimage.binary_dilation(eye["pupil"], iterations=1)
            soft = np.asarray(Image.fromarray((pupil * 255).astype(np.uint8))
                              .filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32)
            sprite = np.dstack([rgb, soft * mask])
            box = save_rgba(sprite, outdir / f"pupil_{idx}.png", crop=True)
            hole = ndimage.binary_dilation(eye["pupil"], iterations=5) & eye["opening"]
            rgba = inpaint(rgba, hole, iterations=300)
            entry["eyes"].append({
                "ellipse": [to_units(cx), to_units(cy), to_units(rx * 0.94), to_units(ry * 0.94), round(ang, 1)],
                "pupil": {"image": f"{pose}/pupil_{idx}.png",
                          "frame": [b / OUT_SCALE for b in box],
                          "center": [to_units(v) for v in eye["pupil_center"]],
                          "radius": to_units(eye["pupil_r"])},
                "lid": lid,
            })

        save_rgba(rgba, outdir / "body.png")
        ys, xs = np.nonzero(mask > 0.5)
        entry["bounds"] = [to_units(xs.min()), to_units(ys.min()), to_units(xs.max()), to_units(ys.max())]
        if len(entry["eyes"]) == 2:
            a, b = entry["eyes"][0]["pupil"]["center"], entry["eyes"][1]["pupil"]["center"]
            entry["pupil_span"] = round(float(np.hypot(a[0] - b[0], a[1] - b[1])), 2)
        rig["poses"][pose] = entry
        print(f"{pose}: eyes={len(entry['eyes'])} hand={'y' if entry['hand'] else '-'} "
              f"fx={'y' if entry['fx'] else '-'} span={entry.get('pupil_span', '-')}")

    (out_root / "rig.json").write_text(json.dumps(rig, indent=1))


if __name__ == "__main__":
    main()
