#!/bin/bash
# Lays out the mounted disk image the way Finder will show it: dark background with an arrow,
# 112 pt icons, Margin on the left and Applications on the right, no toolbar.
# Needs Finder automation; if that is refused, the caller ships the plain layout.
#
#   scripts/dmg-window.sh <volume name>
set -euo pipefail
VOL="$1"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 528}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Margin.app" of container window to {150, 170}
    set position of item "Applications" of container window to {450, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
