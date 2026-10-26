#!/usr/bin/env python3
"""Builds the app icon from the Figma "Happy" pose: the character peeking out
of a black notch on a rounded square, as the macOS icon grid expects.

Usage: make_icon.py <pipeline_dir> <out.icns>
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

pipeline, out = Path(sys.argv[1]), Path(sys.argv[2])
rgb = Image.open(pipeline / "work/up/p10_happy.png").convert("RGB")
mask = Image.open(pipeline / "work/mask/p10_happy.png").convert("L")
character = rgb.copy()
character.putalpha(mask)
bbox = mask.point(lambda v: 255 if v > 20 else 0).getbbox()
character = character.crop(bbox)

S = 1024
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
inset = 100                       # macOS icon grid: 824px body inside 1024
body = (inset, inset, S - inset, S - inset)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + 12, body[2], body[3] + 12), 185, fill=(0, 0, 0, 110))
icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

plate = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(plate).rounded_rectangle(body, 185, fill=(10, 10, 12, 255))
# A faint top light so the black plate reads as an object on dark docks.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((body[0] - 200, body[1] - 520, body[2] + 200, body[1] + 260), fill=(255, 255, 255, 26))
plate.alpha_composite(glow.filter(ImageFilter.GaussianBlur(60)))
clip = Image.new("L", (S, S), 0)
ImageDraw.Draw(clip).rounded_rectangle(body, 185, fill=255)
plate.putalpha(Image.composite(plate.getchannel("A"), Image.new("L", (S, S), 0), clip))
icon.alpha_composite(plate)

# The character peeks up from the plate's lower edge, as it does in the notch.
width = int((body[2] - body[0]) * 0.86)
char = character.resize((width, int(character.height * width / character.width)), Image.LANCZOS)
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.alpha_composite(char, ((S - char.width) // 2 + 14, body[3] - char.height + 10))
layer.putalpha(Image.composite(layer.getchannel("A"), Image.new("L", (S, S), 0), clip))
icon.alpha_composite(layer)

with tempfile.TemporaryDirectory() as tmp:
    iconset = Path(tmp) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)
icon.save(pipeline / "work/app_icon_preview.png")
print("wrote", out)
