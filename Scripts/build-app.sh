#!/bin/zsh
# Builds "Notch Companion.app" from the Swift package (no Xcode needed).
#
#   Scripts/build-app.sh            → build/Notch Companion.app
#   Scripts/build-app.sh --install  → also copies it to ~/Applications and launches it
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
APP="build/Notch Companion.app"
BUNDLE_ID=com.notchcompanion.app
VERSION=1.0.0

swift build -c $CONFIG --product NotchCompanion
swift build -c $CONFIG --product notch-hook
BIN="$(swift build -c $CONFIG --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/NotchCompanion" "$APP/Contents/MacOS/NotchCompanion"
cp "$BIN/notch-hook" "$APP/Contents/Helpers/notch-hook"
cp -R Resources/Character "$APP/Contents/Resources/Character"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Notch Companion</string>
  <key>CFBundleDisplayName</key><string>Notch Companion</string>
  <key>CFBundleExecutable</key><string>NotchCompanion</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Notch Companion uses Automation only to bring the exact Terminal or iTerm2 tab that needs you to the front when you click a notification.</string>
  <key>NSFocusStatusUsageDescription</key>
  <string>Notch Companion can stay quiet while a Focus is on.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/notch-hook"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x NotchCompanion 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Notch Companion.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"Notch Companion.app"
  echo "Installed to ~/Applications and launched"
fi
