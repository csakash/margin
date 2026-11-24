#!/bin/bash
# Signs dist/Margin.app (or $OUT_DIR/Margin.app) from the inside out: Sparkle's helpers, the framework, then the app.
# Never uses --deep (Sparkle's docs: it breaks the helpers' signatures).
#
#   scripts/sign.sh -                                   # ad-hoc, for local runs
#   scripts/sign.sh "Developer ID Application: …" --options runtime --timestamp
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -ge 1 ]] || { echo "usage: scripts/sign.sh <identity|-> [codesign flags…]"; exit 1; }
ID="$1"; shift
APP="${OUT_DIR:-dist}/Margin.app"
FW="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$FW" ]] || { echo "✗ $FW is missing — run scripts/bundle.sh first"; exit 1; }

# codesign reports "replacing existing signature" on stderr for every re-sign; drop only that line.
sign() {
  codesign --force --sign "$ID" ${EXTRA[@]+"${EXTRA[@]}"} "$@" 2> >(grep -v "replacing existing signature" >&2)
}
EXTRA=("$@")

sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --entitlements scripts/Margin.entitlements "$APP"
