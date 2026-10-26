#!/usr/bin/env python3
"""QA contact sheet: re-assemble every pose from its rig layers, at rest and in
a 'moved' state (pupils shifted, hand rotated, lids half closed, fx scaled),
on the notch's black so seams and inpainting artefacts are visible.

Usage: preview_rig.py <resources_character_dir> <out.png>
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def compose(root: Path, pose: str, spec: dict, scale: int, moved: bool) -> Image.Image:
    cw, ch = spec["canvas"]
    p = spec["poses"][pose]
    img = Image.new("RGBA", (cw * scale, ch * scale), (0, 0, 0, 255))
    body = Image.open(root / p["body"]).convert("RGBA")
    img.alpha_composite(body)

    for eye in p["eyes"]:
        cx, cy, rx, ry, ang = eye["ellipse"]
        clip = Image.new("L", img.size, 0)
        ImageDraw.Draw(clip).ellipse(
            [(cx - rx) * scale, (cy - ry) * scale, (cx + rx) * scale, (cy + ry) * scale], fill=255)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        pupil = Image.open(root / eye["pupil"]["image"]).convert("RGBA")
        fx0, fy0 = eye["pupil"]["frame"][:2]
        dx = (rx - eye["pupil"]["radius"]) * 0.7 if moved else 0
        layer.alpha_composite(pupil, (int((fx0 + dx) * scale), int(fy0 * scale)))
        if moved:   # half-closed lid: curved lower edge, as drawn at runtime
            r, g, b = eye["lid"]
            d = ImageDraw.Draw(layer)
            edge = cy
            d.rectangle([(cx - rx) * scale, (cy - ry) * scale, (cx + rx) * scale, edge * scale], fill=(r, g, b, 255))
            d.chord([(cx - rx) * scale, (edge - ry * 0.35) * scale, (cx + rx) * scale, (edge + ry * 0.35) * scale],
                    0, 180, fill=(r, g, b, 255))
            d.arc([(cx - rx) * scale, (edge - ry * 0.35) * scale, (cx + rx) * scale, (edge + ry * 0.35) * scale],
                  0, 180, fill=(92, 52, 38, 255), width=2)
        a = layer.getchannel("A")
        a = Image.composite(a, Image.new("L", img.size, 0), clip)
        layer.putalpha(a)
        img.alpha_composite(layer)

    for key in ("hand", "fx"):
        part = p.get(key)
        if not part:
            continue
        sprite = Image.open(root / part["image"]).convert("RGBA")
        x0, y0 = part["frame"][:2]
        px, py = part["pivot"]
        canvas = Image.new("RGBA", img.size, (0, 0, 0, 0))
        canvas.alpha_composite(sprite, (int(x0 * scale), int(y0 * scale)))
        if moved:
            angle = 10 if key == "hand" else 0
            canvas = canvas.rotate(angle, center=(px * scale, py * scale), resample=Image.BICUBIC)
        img.alpha_composite(canvas)
    return img


def main():
    root, out = Path(sys.argv[1]), Path(sys.argv[2])
    spec = json.loads((root / "rig.json").read_text())
    scale = spec["scale"]
    poses = list(spec["poses"])
    cw, ch = spec["canvas"]
    tw, th = cw * scale, ch * scale
    sheet = Image.new("RGB", (tw * 2 + 30, (th + 10) * len(poses)), (50, 50, 50))
    for i, pose in enumerate(poses):
        sheet.paste(compose(root, pose, spec, scale, False).convert("RGB"), (0, i * (th + 10)))
        sheet.paste(compose(root, pose, spec, scale, True).convert("RGB"), (tw + 20, i * (th + 10)))
    sheet.save(out)
    print(out, sheet.size)


if __name__ == "__main__":
    main()
