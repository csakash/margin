#!/bin/bash
# Signed, notarized release: dist/Margin-<version>.dmg that opens on any Mac without warnings.
#
#   scripts/release.sh                 # sign + DMG (+ notarize if a notary profile exists)
#
# Environment:
#   SIGN_ID         codesigning identity (default: first "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: margin-notary). Create once with:
#                   xcrun notarytool store-credentials margin-notary --apple-id <you@icloud.com> --team-id <TEAMID>
#   DOWNLOAD_BASE   where the DMG will be served from (default: https://margin.motiontic.com/download)
#   NOTES_DIR       folder holding <version>.md release notes (default: releases)
#
# Also writes dist/appcast.xml: the update feed entry for this version, with the DMG's EdDSA
# signature. Needs releases/<version>.md (1–5 lines starting with "- ") and the update-signing
# key in the login keychain. Publishing is a separate, manual step: see "Releasing" in README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-margin-notary}"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# A real release takes its version, bundle id and output folder from the scripts, never from the
# environment. Anything QA-shaped left exported in the shell must not shape what users install.
if [[ "${ALLOW_QA_RELEASE:-}" != "1" ]]; then
  for v in QA_LOCAL_FEED BUNDLE_ID VERSION OUT_DIR NOTES_DIR DOWNLOAD_BASE; do
    if [[ -n "${!v:-}" ]]; then
      echo "✗ $v is set in the environment (\"${!v}\"). Refusing to build a release from a QA configuration."
      echo "  Unset it, or change the default in the script if you mean it."; exit 1
    fi
  done
fi
OUT_DIR="${OUT_DIR:-dist}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://margin.motiontic.com/download}"
NOTES_DIR="${NOTES_DIR:-releases}"
export OUT_DIR
rm -f "$OUT_DIR/appcast.xml"   # never leave an older feed entry next to a build that failed
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$SIGN_ID" ]] || { echo "✗ No 'Developer ID Application' identity in the keychain"; exit 1; }

echo "→ building app bundle"
scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT_DIR/Margin.app/Contents/Info.plist")
NOTES="$NOTES_DIR/$VERSION.md"
[[ -f "$NOTES" ]] || { echo "✗ $NOTES is missing. Write 1–5 lines starting with \"- \" describing this release."; exit 1; }
NOTE_COUNT=$(grep -c '^- ' "$NOTES" || true)
[[ "$NOTE_COUNT" -ge 1 && "$NOTE_COUNT" -le 5 ]] || { echo "✗ $NOTES needs 1–5 lines starting with \"- \" (found $NOTE_COUNT)."; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "✗ $SIGN_UPDATE not found (it comes with the Sparkle package; run swift build)"; exit 1; }
APP="$OUT_DIR/Margin.app"
DMG="$OUT_DIR/Margin-${VERSION}.dmg"
NOTARIZED=0

echo "→ signing with: $SIGN_ID (hardened runtime, secure timestamp)"
scripts/sign.sh "$SIGN_ID" --options runtime --timestamp
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
  NOTARIZED=1
else
  echo "! No notary profile '$NOTARY_PROFILE' — signed but NOT notarized."
  echo "  Run once: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAMID>"
fi
# The feed entry is written last: stapling changes the DMG's bytes, and the signature covers them.
echo "→ signing the update and writing $OUT_DIR/appcast.xml"
ED_SIG=$("$SIGN_UPDATE" -p "$DMG" || true)
[[ -n "$ED_SIG" ]] || { echo "✗ sign_update produced no signature (is the update-signing key in the login keychain?)"; exit 1; }
LENGTH=$(stat -f %z "$DMG")
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ITEMS=$(grep '^- ' "$NOTES" | sed 's/^- *//' | xml_escape | sed 's|^|<li>|; s|$|</li>|' | tr -d '\n')
FEED_TMP=$(mktemp)
cat > "$FEED_TMP" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Margin</title>
    <link>https://margin.motiontic.com/appcast.xml</link>
    <item>
      <title>Margin ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>${ITEMS}</ul>]]></description>
      <enclosure url="${DOWNLOAD_BASE}/Margin-${VERSION}.dmg" sparkle:edSignature="${ED_SIG}" length="${LENGTH}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$FEED_TMP" || { rm -f "$FEED_TMP"; echo "✗ the generated feed is not well-formed XML"; exit 1; }
mv "$FEED_TMP" "$OUT_DIR/appcast.xml"
chmod 644 "$OUT_DIR/appcast.xml"

shasum -a 256 "$DMG"
echo
if [[ "$NOTARIZED" == "1" ]]; then
  echo "To publish (after checking the build): copy these into the margin-site repo and deploy it."
  echo "  $DMG  → download/"
  echo "  $OUT_DIR/appcast.xml  → the site root"
else
  echo "! NOT notarized. This build is for local testing only: do not publish it or its appcast.xml."
fi
