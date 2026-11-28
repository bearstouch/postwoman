#!/bin/sh
# Checks that a DMG and the PostWoman.app inside it both carry a stapled notarization ticket.
#   scripts/verify-dmg-staple.sh <PostWoman.dmg>
set -eu
dmg="$1"
/usr/bin/xcrun stapler validate "$dmg"
mount=$(mktemp -d)
/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null
status=0
/usr/bin/xcrun stapler validate "$mount/PostWoman.app" || { echo "PostWoman.app in $dmg has no stapled ticket" >&2; status=1; }
/usr/bin/hdiutil detach "$mount" -quiet || /usr/bin/hdiutil detach "$mount" -force -quiet
rmdir "$mount" 2>/dev/null || true
exit $status
