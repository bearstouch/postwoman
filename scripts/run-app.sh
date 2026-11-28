#!/bin/sh
# Assembles a debug .build/Reqs.app (sandboxed, ad-hoc signed), verifies it and opens it.
#   scripts/run-app.sh [--build-only] [app arguments…]
# The dev bundle uses com.bearstouch.reqs.dev, so its sandbox container (and SwiftData store)
# stays apart from an installed Reqs.
set -eu
cd "$(dirname "$0")/.."
launch=true
if [ "${1:-}" = "--build-only" ]; then
    launch=false
    shift
fi
swift build --configuration debug --product Reqs
swift build --configuration debug --product reqs-cli
bin_path=$(swift build --configuration debug --show-bin-path)
destination="$PWD/.build/Reqs.app"
staging=$(mktemp -d "$PWD/.build/reqs-app.XXXXXX")
bundle="$staging/Reqs.app"
previous="$staging/previous.app"
cleanup() {
    status=$?
    # Restore the previous bundle if publishing the new one failed.
    if [ "$status" -ne 0 ] && [ -d "$previous" ] && [ ! -e "$destination" ]; then
        mv "$previous" "$destination"
    fi
    rm -rf "$staging"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Helpers" "$bundle/Contents/Frameworks"
# Always assemble fresh files: do not overwrite a running executable or a stale signature.
cp "$bin_path/Reqs" "$bundle/Contents/MacOS/Reqs"
chmod u+x "$bundle/Contents/MacOS/Reqs"
# The command-line tool (`reqs cli install-link` puts it on PATH).
cp "$bin_path/reqs-cli" "$bundle/Contents/Helpers/reqs"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bearstouch.reqs.dev</string>
<key>CFBundleName</key><string>Reqs Dev</string>
<key>CFBundleExecutable</key><string>Reqs</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp Design/AppIcon/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
# The app links Sparkle; this Info.plist has no SUFeedURL, so a development bundle never checks for updates.
/usr/bin/ditto "$bin_path/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
# The SwiftPM command-line signature does not seal an app's Info.plist/resources or carry entitlements.
# Sign the completed development bundle; no certificate or account is required.
# Nested code is signed first, then the bundle seals it. The CLI is not sandboxed: it runs in the user's shell.
/usr/bin/codesign --force --sign - --identifier com.bearstouch.reqs.dev.cli "$bundle/Contents/Helpers/reqs"
scripts/sign-sparkle.sh "$bundle" -
/usr/bin/codesign --force --entitlements release/Reqs.entitlements --sign - --identifier com.bearstouch.reqs.dev "$bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
# `open` only re-activates an app that is already running, so quit the old dev build first.
# Ask politely (a normal quit, so SwiftData saves) and never force-kill it.
if [ "$launch" = true ] && pgrep -f "$destination/Contents/MacOS/Reqs" >/dev/null; then
    printf 'Quitting the running Reqs Dev…\n'
    /usr/bin/osascript -e 'tell application id "com.bearstouch.reqs.dev" to quit' >/dev/null
    waited=0
    while pgrep -f "$destination/Contents/MacOS/Reqs" >/dev/null; do
        if [ "$waited" -ge 150 ]; then
            printf 'Reqs Dev did not quit (is a dialog open?). Quit it and run again.\n' >&2
            exit 1
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
fi
if [ -e "$destination" ]; then
    mv "$destination" "$previous"
fi
mv "$bundle" "$destination"
if [ "$launch" = true ]; then
    open "$destination" --args "$@"
else
    printf 'Built and verified: %s\n' "$destination"
fi
