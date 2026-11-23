#!/bin/bash
# Builds a release binary and assembles dist/Margin.app (icon, Info.plist, ad-hoc signature).
# Usage: scripts/bundle.sh [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.1"
APP="dist/Margin.app"
WORK="build/icon"

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Margin "$APP/Contents/MacOS/Margin"

echo "→ icon"
rm -rf "$WORK"; mkdir -p "$WORK/AppIcon.iconset"
# Pad the artwork onto Apple's icon grid (body ≈ 80% of the canvas) so it sits right in the Dock.
sed 's/viewBox="0 0 512 512" width="512" height="512"/viewBox="-44 -44 600 600" width="1024" height="1024"/' \
  design/icon.svg > "$WORK/AppIcon.svg"
qlmanage -t -s 1024 -o "$WORK" "$WORK/AppIcon.svg" >/dev/null 2>&1
SRC="$WORK/AppIcon.svg.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SRC" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>app.margin.notes</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppleEventsUsageDescription</key><string>Margin reads the URL and title of your front browser tab when you press “Clip tab”.</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing"
codesign --force --deep --sign - "$APP" >/dev/null

echo "✓ $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
