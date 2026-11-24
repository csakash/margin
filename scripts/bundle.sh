#!/bin/bash
# Builds a release binary and assembles dist/Margin.app (icon, Info.plist, Sparkle, ad-hoc signature).
# Usage: scripts/bundle.sh [--open]
#
# Environment (QA only; a normal build sets none of these):
#   VERSION        version to stamp (default below)
#   BUNDLE_ID      bundle identifier (default app.margin.notes)
#   QA_LOCAL_FEED  1 = allow a plain-http update feed on this Mac, for scripts/qa-update.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.0}"
BUNDLE_ID="${BUNDLE_ID:-app.margin.notes}"
# Public half of the update-signing key. The private half lives in the maintainer's login keychain
# (see "Releasing" in README.md). Sparkle refuses any update not signed with it.
SU_PUBLIC_KEY="bMkyLV6EQgTbkBFqyOhHUDu1nAId30iU+/f8N0BGzOo="
SU_FEED_URL="https://margin.motiontic.com/appcast.xml"
APP="dist/Margin.app"
WORK="build/icon"

echo "→ swift build -c release"
swift build -c release

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Margin "$APP/Contents/MacOS/Margin"

echo "→ embedding Sparkle"
SPARKLE=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework 2>/dev/null | head -1)
[[ -d "$SPARKLE" ]] || { echo "✗ Sparkle.framework not found under .build/artifacts"; exit 1; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$FW"   # keeps the framework's symlinks and permissions
# Margin is not sandboxed, so Sparkle's XPC services are not needed; headers are build-time only.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices" \
       "$FW/Versions/B/Headers" "$FW/Headers" "$FW/Versions/B/PrivateHeaders" "$FW/PrivateHeaders" \
       "$FW/Versions/B/Modules" "$FW/Modules"
if ! otool -l "$APP/Contents/MacOS/Margin" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Margin"
fi

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

QA_ATS=""
if [[ "${QA_LOCAL_FEED:-}" == "1" ]]; then
  echo "! QA build: plain-http update feeds on this Mac are allowed"
  QA_ATS="  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
${QA_ATS}
  <key>NSAppleEventsUsageDescription</key><string>Margin reads the URL and title of your front browser tab when you press “Clip tab”.</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc signing"
scripts/sign.sh -

echo "✓ $APP"
if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
