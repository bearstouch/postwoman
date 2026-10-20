#!/bin/sh
# Packages an app into a drag-to-install DMG: the app icon beside an Applications
# shortcut, over Design/DMG/background.png, with the app icon as the volume icon.
#
#   scripts/make-dmg.sh <path/to/PostWoman.app> <output.dmg> <volume name>
#
# The Finder layout is applied with AppleScript; when Finder automation is unavailable
# (e.g. a headless runner) the DMG is still built with the shortcut, just without layout.
set -eu
cd "$(dirname "$0")/.."
app=$1; dmg=$2; volname=$3
work=$(mktemp -d "${TMPDIR:-/tmp}/postwoman-dmg.XXXXXX")
device=""
cleanup() {
    if [ -n "$device" ]; then /usr/bin/hdiutil detach -quiet -force "$device" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

stage="$work/stage"
mkdir -p "$stage/.background"
/usr/bin/ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
/usr/bin/tiffutil -cathidpicheck Design/DMG/background.png Design/DMG/background@2x.png -out "$stage/.background/background.tiff" 2>/dev/null

rw="$work/rw.dmg"
/usr/bin/hdiutil create -quiet -volname "$volname" -srcfolder "$stage" -fs HFS+ -format UDRW -ov "$rw"
attached=$(/usr/bin/hdiutil attach -readwrite -noverify -noautoopen "$rw")
device=$(echo "$attached" | awk 'NR==1 {print $1}')
mount=$(echo "$attached" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')
[ -d "$mount" ] || { echo "Could not mount $rw" >&2; exit 1; }

# Icon centres must match Design/DMG/make-background.swift (660x400 window).
if ! /usr/bin/osascript - "$(basename "$mount")" "$(basename "$app")" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    set appName to item 2 of argv
    with timeout of 60 seconds
        tell application "Finder"
            -- A fresh mount can take a moment to appear in Finder.
            repeat 20 times
                if exists disk diskName then exit repeat
                delay 0.5
            end repeat
            tell disk diskName
                open
                set current view of container window to icon view
                set toolbar visible of container window to false
                set statusbar visible of container window to false
                set bounds of container window to {200, 120, 860, 520}
                set opts to icon view options of container window
                set arrangement of opts to not arranged
                set icon size of opts to 128
                set text size of opts to 13
                set background picture of opts to file ".background:background.tiff"
                set position of item appName of container window to {180, 170}
                set position of item "Applications" of container window to {480, 170}
                update without registering applications
                delay 1
                close
            end tell
        end tell
    end timeout
end run
APPLESCRIPT
then
    echo "warning: Finder layout not applied (Finder automation unavailable); the DMG still has the Applications shortcut." >&2
fi

# hdiutil -srcfolder drops .VolumeIcon.icns and the Finder pass resets it, so it goes in last.
cp Design/AppIcon/AppIcon.icns "$mount/.VolumeIcon.icns"
if [ -x /usr/bin/SetFile ]; then /usr/bin/SetFile -a C "$mount"; fi
rm -rf "$mount/.fseventsd" "$mount/.Trashes"
sync
/usr/bin/hdiutil detach -quiet "$device" || { sleep 2; /usr/bin/hdiutil detach -quiet -force "$device"; }
device=""
/usr/bin/hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg"
