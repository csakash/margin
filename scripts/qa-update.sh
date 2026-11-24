#!/bin/bash
# End-to-end update test on this Mac: a real 0.2.0 build updates itself to a 0.2.1 test build
# from a feed served on 127.0.0.1. Nothing here is published or notarized.
#
#   scripts/qa-update.sh --check-only   # build once and assert the bundle and feed are well-formed
#   scripts/qa-update.sh                # build old + new, serve the feed, launch the old app
#   scripts/qa-update.sh --tamper       # same, but corrupt the served DMG (the update must be refused)
#   scripts/qa-update.sh --no-launch    # build and serve only (the caller launches the app)
#
# Needs a "Developer ID Application" identity and the update-signing key in the login keychain.
# QA builds use their own bundle id, so they never touch the real app's settings.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-run}"
PORT="${QA_PORT:-8765}"
OLD="0.2.0"; NEW="0.2.1"
QA="build/qa"
export BUNDLE_ID="app.margin.notes.qa" NOTARY_PROFILE="qa-none-skip-notarization"

fail() { echo "✗ $*"; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" dist/Margin.app/Contents/Info.plist; }

if [[ "$MODE" == "--check-only" ]]; then
  scripts/release.sh
  APP="dist/Margin.app"; V=$(plist CFBundleShortVersionString)
  [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
  [[ -z "$(find "$APP/Contents/Frameworks" -name XPCServices)" ]] || fail "XPCServices were not removed"
  otool -l "$APP/Contents/MacOS/Margin" | grep -q "@executable_path/../Frameworks" || fail "rpath is missing"
  [[ "$(plist CFBundleVersion)" == "$V" ]] || fail "CFBundleVersion ($(plist CFBundleVersion)) != short version ($V)"
  for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval; do
    plist "$k" >/dev/null || fail "Info.plist is missing $k"
  done
  ! plist NSAppTransportSecurity >/dev/null 2>&1 || fail "a normal build must not relax App Transport Security"
  codesign --verify --strict --deep "$APP" || fail "code signature does not verify"
  xmllint --noout dist/appcast.xml || fail "appcast.xml is not well-formed"
  DMG="dist/Margin-$V.dmg"
  LEN=$(xmllint --xpath 'string(//enclosure/@length)' dist/appcast.xml)
  [[ "$LEN" == "$(stat -f %z "$DMG")" ]] || fail "enclosure length $LEN != DMG size $(stat -f %z "$DMG")"
  SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' dist/appcast.xml)
  [[ -n "$SIG" ]] || fail "enclosure has no EdDSA signature"
  .build/artifacts/sparkle/Sparkle/bin/sign_update --verify "$DMG" "$SIG" || fail "EdDSA signature does not verify"
  # The QA guard itself: a QA configuration must be refused as a release.
  if QA_LOCAL_FEED=1 scripts/release.sh >/dev/null 2>&1; then fail "release.sh accepted QA_LOCAL_FEED"; fi
  echo "✓ bundle and feed checks passed for $V"
  exit 0
fi

export QA_LOCAL_FEED=1 ALLOW_QA_RELEASE=1
rm -rf "$QA"; mkdir -p "$QA/notes" "$QA/releases"
# Start from a first launch every time: Sparkle remembers its last check in the QA app's settings.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
# Stored in the QA app's own settings (not just the environment) so the copy that relaunches
# after the update still uses the scratch notes folder and the local feed.
defaults write "$BUNDLE_ID" MARGIN_NOTES_DIR "$PWD/$QA/notes"
defaults write "$BUNDLE_ID" MARGIN_FEED_URL "http://127.0.0.1:$PORT/appcast.xml"

echo "== building the OLD app ($OLD) =="
cp "releases/$OLD.md" "$QA/releases/$OLD.md"
VERSION="$OLD" NOTES_DIR="$QA/releases" scripts/release.sh >/dev/null
ditto dist/Margin.app "$QA/Margin.app"

echo "== building the NEW update ($NEW) =="
printf -- '- Test update: proves 0.2.0 can update itself\n- Second note line, with <angle> & ampersand\n' > "$QA/releases/$NEW.md"
VERSION="$NEW" NOTES_DIR="$QA/releases" DOWNLOAD_BASE="http://127.0.0.1:$PORT" scripts/release.sh >/dev/null
rm -rf "$QA/feed"; mkdir -p "$QA/feed"
cp "dist/Margin-$NEW.dmg" dist/appcast.xml "$QA/feed/"

if [[ "$MODE" == "--tamper" ]]; then
  echo "== corrupting the served DMG (one byte) =="
  SIZE=$(stat -f %z "$QA/feed/Margin-$NEW.dmg")
  printf '\x00' | dd of="$QA/feed/Margin-$NEW.dmg" bs=1 seek=$((SIZE / 2)) conv=notrunc 2>/dev/null
fi

echo "== serving the feed on 127.0.0.1:$PORT (log: $QA/server.log) =="
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$QA/feed" > "$QA/server.log" 2>&1 &
echo $! > "$QA/server.pid"
sleep 1

if [[ "$MODE" != "--no-launch" ]]; then
  echo "== launching the OLD app =="
  "$QA/Margin.app/Contents/MacOS/Margin" > "$QA/app.log" 2>&1 &
  echo $! > "$QA/app.pid"
fi

cat <<TXT

Running. Old app: $QA/Margin.app ($OLD). Feed offers $NEW.
Check, in order:
  4. Within 60 s, with no window or focus change, the card reads "Margin $NEW is ready".
  5. Minimise: the nub shows the pulsing dot. Expand: dot gone, card shown.
  6. "Restart to update" relaunches as $NEW:
       /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $QA/Margin.app/Contents/Info.plist
  7. "Later" hides the card; quitting installs it.
  8. Menu bar → "Check for Updates…" on $NEW says "You're up to date".
  9. Untick "Check for Updates Automatically", relaunch: no new GET in $QA/server.log.
 10. With --tamper: stays on $OLD, never shows "is ready".
 11. Stop the server (kill \$(cat $QA/server.pid)), then check manually: "Couldn't check for updates".
Stop everything:  kill \$(cat $QA/server.pid) \$(cat $QA/app.pid 2>/dev/null) 2>/dev/null
TXT
