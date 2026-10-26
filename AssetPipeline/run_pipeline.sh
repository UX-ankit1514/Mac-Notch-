#!/bin/zsh
# Rebuilds every character asset from the Figma storyboard export, in one go.
#
#   1. source/sheet_eb75f1.png — exported from Figma (Page 2 → Emotion section's
#      image fill) at native 1536×1024. Replace it with higher-resolution art
#      and rerun; nothing else needs to change.
#   2. crop → 4× upscale (Real-ESRGAN, offline) → Vision subject matte →
#      rig layers (pupils, lids, hand, fx) → Resources/Character + rig.json
#   3. QA sheet: work/rig_preview.png, and the app icon.
set -euo pipefail
cd "$(dirname "$0")"
ESRGAN=vendor/realesrgan/realesrgan-ncnn-vulkan
if [[ ! -x $ESRGAN ]]; then
  echo "Real-ESRGAN missing. Download realesrgan-ncnn-vulkan-20220424-macos.zip from"
  echo "https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0 and unzip into vendor/realesrgan/"
  exit 1
fi

python3 scripts/crop_poses.py source/sheet_eb75f1.png work/crops
rm -rf work/crops_only work/up && mkdir -p work/crops_only work/up
cp work/crops/p*.png work/crops_only/
$ESRGAN -i work/crops_only -o work/up -n realesrgan-x4plus-anime -m vendor/realesrgan/models -s 4 -f png >/dev/null 2>&1
swift scripts/cutout.swift work/up work/mask
rm -rf ../Resources/Character
python3 scripts/build_rig.py . ../Resources/Character
python3 scripts/preview_rig.py ../Resources/Character work/rig_preview.png
python3 scripts/make_icon.py . ../Resources/AppIcon.icns
echo "Done. Rebuild the app with ../Scripts/build-app.sh"
