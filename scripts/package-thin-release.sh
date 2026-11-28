#!/bin/sh
# Derives single-architecture DMGs (Apple silicon and Intel) from the Universal 2
# dist/PostWoman.app produced by scripts/package-release.sh. Each thinned app is re-signed,
# packaged, and notarized/stapled with the same POSTWOMAN_SIGN_IDENTITY / POSTWOMAN_NOTARY_PROFILE.
set -eu
cd "$(dirname "$0")/.."
identity="${POSTWOMAN_SIGN_IDENTITY:--}"
manifest() { python3 -c 'import json,sys;print(json.load(open("release/manifest.json"))[sys.argv[1]])' "$1"; }
version=$(manifest version)
bundle_id=$(manifest bundleIdentifier)
entitlements=$(manifest entitlements)
universal="$PWD/dist/PostWoman.app"
[ -d "$universal" ] || { echo "Run scripts/package-release.sh first." >&2; exit 1; }

for pair in arm64:apple-silicon x86_64:intel; do
    arch=${pair%%:*}; label=${pair#*:}
    stage="$PWD/dist/$label"
    rm -rf "$stage"; mkdir -p "$stage"
    app="$stage/PostWoman.app"
    cp -R "$universal" "$app"
    rm -f "$app/Contents/CodeResources" # the Universal app's stapled ticket does not match the thinned app
    /usr/bin/lipo -thin "$arch" "$app/Contents/MacOS/PostWoman" -output "$app/Contents/MacOS/PostWoman.thin"
    mv "$app/Contents/MacOS/PostWoman.thin" "$app/Contents/MacOS/PostWoman"
    /usr/bin/lipo -thin "$arch" "$app/Contents/Helpers/postwoman" -output "$app/Contents/Helpers/postwoman.thin"
    mv "$app/Contents/Helpers/postwoman.thin" "$app/Contents/Helpers/postwoman"
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --sign - --identifier "$bundle_id.cli" "$app/Contents/Helpers/postwoman"
        scripts/sign-sparkle.sh "$app" - "$arch"
        # Ad-hoc only: no Team ID, so library validation would refuse the embedded Sparkle.framework.
        adhoc_entitlements="$stage/adhoc.entitlements"
        cp "$entitlements" "$adhoc_entitlements"
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$adhoc_entitlements"
        /usr/bin/codesign --force --options runtime --entitlements "$adhoc_entitlements" --sign - --identifier "$bundle_id" "$app"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" --identifier "$bundle_id.cli" "$app/Contents/Helpers/postwoman"
        scripts/sign-sparkle.sh "$app" "$identity" "$arch"
        /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" --identifier "$bundle_id" "$app"
    fi
    /usr/bin/codesign --verify --deep --strict "$app"
    [ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/PostWoman")" = "$arch" ] || { echo "$label app is not $arch" >&2; exit 1; }
    [ "$(/usr/bin/lipo -archs "$app/Contents/Helpers/postwoman")" = "$arch" ] || { echo "$label CLI is not $arch" >&2; exit 1; }
    [ "$(/usr/bin/lipo -archs "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")" = "$arch" ] || { echo "$label Sparkle is not $arch" >&2; exit 1; }

    dmg="$PWD/dist/PostWoman-$version-$label.dmg"
    notarize=false
    if [ "$identity" != "-" ] && [ -n "${POSTWOMAN_NOTARY_PROFILE:-}" ]; then notarize=true; fi
    # Staple the app before packaging so the copy dragged out of the DMG carries its own ticket.
    if [ "$notarize" = true ]; then
        zip="$stage/PostWoman-notarize.zip"
        /usr/bin/ditto -c -k --keepParent "$app" "$zip"
        /usr/bin/xcrun notarytool submit "$zip" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait
        /usr/bin/xcrun stapler staple "$app"
        rm -f "$zip"
    fi
    scripts/make-dmg.sh "$app" "$dmg" "PostWoman $version"
    if [ "$identity" != "-" ]; then
        /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
    fi
    if [ "$notarize" = true ]; then
        /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait
        /usr/bin/xcrun stapler staple "$dmg"
        scripts/verify-dmg-staple.sh "$dmg"
    fi
    rm -rf "$stage"
    echo "$dmg ($arch)"
done
