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
    /usr/bin/lipo -thin "$arch" "$app/Contents/MacOS/PostWoman" -output "$app/Contents/MacOS/PostWoman.thin"
    mv "$app/Contents/MacOS/PostWoman.thin" "$app/Contents/MacOS/PostWoman"
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --entitlements "$entitlements" --sign - --identifier "$bundle_id" "$app"
    else
        /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" --identifier "$bundle_id" "$app"
    fi
    /usr/bin/codesign --verify --deep --strict "$app"
    [ "$(/usr/bin/lipo -archs "$app/Contents/MacOS/PostWoman")" = "$arch" ] || { echo "$label app is not $arch" >&2; exit 1; }

    dmg="$PWD/dist/PostWoman-$version-$label.dmg"
    scripts/make-dmg.sh "$app" "$dmg" "PostWoman $version"
    if [ "$identity" != "-" ]; then
        /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
        if [ -n "${POSTWOMAN_NOTARY_PROFILE:-}" ]; then
            /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait
            /usr/bin/xcrun stapler staple "$dmg"
        fi
    fi
    rm -rf "$stage"
    echo "$dmg ($arch)"
done
