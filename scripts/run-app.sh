#!/bin/sh
# Assembles a debug .build/PostWoman.app (sandboxed, ad-hoc signed), verifies it and opens it.
#   scripts/run-app.sh [--build-only] [app arguments…]
# The dev bundle uses com.bearstouch.postwoman.dev, so its sandbox container (and SwiftData store)
# stays apart from an installed PostWoman.
set -eu
cd "$(dirname "$0")/.."
launch=true
if [ "${1:-}" = "--build-only" ]; then
    launch=false
    shift
fi
swift build --configuration debug --product PostWoman
bin_path=$(swift build --configuration debug --show-bin-path)
destination="$PWD/.build/PostWoman.app"
staging=$(mktemp -d "$PWD/.build/postwoman-app.XXXXXX")
bundle="$staging/PostWoman.app"
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
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
# Always assemble fresh files: do not overwrite a running executable or a stale signature.
cp "$bin_path/PostWoman" "$bundle/Contents/MacOS/PostWoman"
chmod u+x "$bundle/Contents/MacOS/PostWoman"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.bearstouch.postwoman.dev</string>
<key>CFBundleName</key><string>PostWoman Dev</string>
<key>CFBundleExecutable</key><string>PostWoman</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp Design/AppIcon/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
# The SwiftPM command-line signature does not seal an app's Info.plist/resources or carry entitlements.
# Sign the completed development bundle; no certificate or account is required.
/usr/bin/codesign --force --entitlements release/PostWoman.entitlements --sign - --identifier com.bearstouch.postwoman.dev "$bundle"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
if [ -e "$destination" ]; then
    mv "$destination" "$previous"
fi
mv "$bundle" "$destination"
if [ "$launch" = true ]; then
    open "$destination" --args "$@"
else
    printf 'Built and verified: %s\n' "$destination"
fi
