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
# The test DMGs are signed with the real keys, so they are deleted from build/qa when a run is
# stopped with the command printed at the end; never copy them anywhere.
# Everything is built under build/qa; dist/ (the real release output) is never touched.
# The update runs use their own bundle id, so they never touch the real app's settings.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-run}"
case "$MODE" in run|--check-only|--tamper|--no-launch) ;; *) echo "unknown option: $MODE"; sed -n 2,9p scripts/qa-update.sh; exit 1 ;; esac
PORT="${QA_PORT:-8765}"
OLD="0.2.0"; NEW="0.2.1"
QA="build/qa"
OUT="$QA/out"
export NOTARY_PROFILE="qa-none-skip-notarization" OUT_DIR="$OUT" ALLOW_QA_RELEASE=1

fail() { echo "✗ $*"; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$OUT/Margin.app/Contents/Info.plist"; }

BIN=".build/artifacts/sparkle/Sparkle/bin"

# Stop what an earlier run left behind, matched by command line (a pid file can outlive its process).
stop_previous() {
  pkill -f "http.server $PORT --bind 127.0.0.1 --directory $QA/feed" 2>/dev/null || true
  pkill -f "$PWD/$QA/Margin.app/Contents/MacOS/Margin" 2>/dev/null || true
}

if [[ "$MODE" == "--check-only" ]]; then
  # The normal configuration (real bundle id, real version, no QA switches), built outside dist/.
  rm -rf "$OUT"; mkdir -p "$OUT"
  scripts/release.sh
  APP="$OUT/Margin.app"; V=$(plist CFBundleShortVersionString)
  [[ "$(plist CFBundleIdentifier)" == "app.margin.notes" ]] || fail "bundle id is $(plist CFBundleIdentifier)"
  [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || fail "Sparkle.framework is not embedded"
  [[ -z "$(find "$APP/Contents/Frameworks" -name XPCServices)" ]] || fail "XPCServices were not removed"
  otool -l "$APP/Contents/MacOS/Margin" | grep -q "@executable_path/../Frameworks" || fail "rpath is missing"
  [[ "$(plist CFBundleVersion)" == "$V" ]] || fail "CFBundleVersion ($(plist CFBundleVersion)) != short version ($V)"
  for k in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval; do
    plist "$k" >/dev/null || fail "Info.plist is missing $k"
  done
  ! plist NSAppTransportSecurity >/dev/null 2>&1 || fail "a normal build must not relax App Transport Security"
  codesign --verify --strict --deep "$APP" || fail "code signature does not verify"
  xmllint --noout "$OUT/appcast.xml" || fail "appcast.xml is not well-formed"
  DMG="$OUT/Margin-$V.dmg"
  LEN=$(xmllint --xpath 'string(//enclosure/@length)' "$OUT/appcast.xml")
  [[ "$LEN" == "$(stat -f %z "$DMG")" ]] || fail "enclosure length $LEN != DMG size $(stat -f %z "$DMG")"
  SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml")
  [[ -n "$SIG" ]] || fail "enclosure has no EdDSA signature"
  "$BIN/sign_update" --verify "$DMG" "$SIG" || fail "EdDSA signature does not verify"
  # The key that signed it must be the key the app trusts, or every install would refuse every update.
  [[ "$("$BIN/generate_keys" -p)" == "$(plist SUPublicEDKey)" ]] || fail "SUPublicEDKey in the app is not the keychain key's public half"
  # The guard itself: anything QA-shaped in the environment must be refused as a release.
  # GUARD_ONLY stops release.sh right after its guard, so a broken guard cannot build into dist/.
  for v in QA_LOCAL_FEED BUNDLE_ID VERSION OUT_DIR NOTES_DIR DOWNLOAD_BASE; do
    REFUSAL=$(env -u ALLOW_QA_RELEASE -u OUT_DIR GUARD_ONLY=1 "$v=x" scripts/release.sh 2>&1 || true)
    grep -q "✗ $v is set in the environment" <<<"$REFUSAL" || fail "release.sh did not refuse $v"
  done
  env -u ALLOW_QA_RELEASE -u OUT_DIR GUARD_ONLY=1 scripts/release.sh | grep -q "guard passed" || fail "release.sh refused a clean environment"
  [[ ! -e dist ]] || [[ -z "$(find dist -newer "$OUT/appcast.xml" 2>/dev/null)" ]] || fail "the check wrote into dist/"
  echo "✓ bundle and feed checks passed for $V"
  exit 0
fi

stop_previous
export QA_LOCAL_FEED=1 BUNDLE_ID="app.margin.notes.qa"
rm -rf "$QA"; mkdir -p "$QA/notes" "$QA/releases" "$OUT"
# Start from a first launch every time: Sparkle remembers its last check in the QA app's settings.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
# Stored in the QA app's own settings (not just the environment) so the copy that relaunches
# after the update still uses the scratch notes folder and the local feed.
defaults write "$BUNDLE_ID" MARGIN_NOTES_DIR "$PWD/$QA/notes"
defaults write "$BUNDLE_ID" MARGIN_FEED_URL "http://127.0.0.1:$PORT/appcast.xml"

echo "== building the OLD app ($OLD) =="
cp "releases/$OLD.md" "$QA/releases/$OLD.md"
VERSION="$OLD" NOTES_DIR="$QA/releases" scripts/release.sh >/dev/null
ditto "$OUT/Margin.app" "$QA/Margin.app"

echo "== building the NEW update ($NEW) =="
printf -- '- Test update: proves 0.2.0 can update itself\n- Second note line, with <angle> & ampersand\n' > "$QA/releases/$NEW.md"
VERSION="$NEW" NOTES_DIR="$QA/releases" DOWNLOAD_BASE="http://127.0.0.1:$PORT" scripts/release.sh >/dev/null
rm -rf "$QA/feed"; mkdir -p "$QA/feed"
cp "$OUT/Margin-$NEW.dmg" "$OUT/appcast.xml" "$QA/feed/"
rm -f "$OUT"/Margin-*.dmg   # only the served copy remains

if [[ "$MODE" == "--tamper" ]]; then
  echo "== corrupting the served DMG (flipping one byte) =="
  python3 - "$QA/feed/Margin-$NEW.dmg" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
    f.seek(0, 2); mid = f.tell() // 2
    f.seek(mid); b = f.read(1)
    f.seek(mid); f.write(bytes([b[0] ^ 0xFF]))
PYEOF
fi

echo "== serving the feed on 127.0.0.1:$PORT (log: $QA/server.log) =="
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$QA/feed" > "$QA/server.log" 2>&1 &
echo $! > "$QA/server.pid"
sleep 1
curl -sf -o /dev/null "http://127.0.0.1:$PORT/appcast.xml" \
  || fail "the feed server did not start on port $PORT (see $QA/server.log; is the port in use?)"

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
Stop everything and delete the test update:
  pkill -f "$QA/feed"; pkill -f "$QA/Margin.app"; rm -rf $QA/feed $QA/out
TXT
