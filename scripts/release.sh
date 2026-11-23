#!/bin/bash
# Signed, notarized release: dist/Margin-<version>.dmg that opens on any Mac without warnings.
#
#   scripts/release.sh                 # sign + DMG (+ notarize if a notary profile exists)
#
# Environment:
#   SIGN_ID         codesigning identity (default: first "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: margin-notary). Create once with:
#                   xcrun notarytool store-credentials margin-notary --apple-id <you@icloud.com> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Margin.app/Contents/Info.plist 2>/dev/null || echo "0.1.0")
NOTARY_PROFILE="${NOTARY_PROFILE:-margin-notary}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_ID" ]] || { echo "✗ No 'Developer ID Application' identity in the keychain"; exit 1; }

echo "→ building app bundle"
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Margin.app/Contents/Info.plist)
APP="dist/Margin.app"
DMG="dist/Margin-${VERSION}.dmg"

echo "→ signing with: $SIGN_ID (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --entitlements scripts/Margin.entitlements \
  --sign "$SIGN_ID" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "→ building $DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Margin" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "→ notarizing (this usually takes 1–5 minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "→ stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  echo "→ Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
  echo "✓ notarized: $DMG"
else
  echo "! No notary profile '$NOTARY_PROFILE' — signed but NOT notarized."
  echo "  Run once: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAMID>"
fi
shasum -a 256 "$DMG"
