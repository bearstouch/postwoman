#!/bin/sh
# Builds a Universal 2 release of PostWoman with SwiftPM, signs it with the hardened
# runtime and the app's entitlements, packages a DMG, optionally notarizes and
# staples, verifies, and records evidence in dist/release-evidence.json.
#
#   POSTWOMAN_SIGN_IDENTITY   "Developer ID Application: …" (default "-" = ad-hoc, not distributable)
#   POSTWOMAN_NOTARY_PROFILE  notarytool keychain profile; notarization is skipped when unset
set -eu
cd "$(dirname "$0")/.."
identity="${POSTWOMAN_SIGN_IDENTITY:--}"
manifest() { python3 -c 'import json,sys;print(json.load(open("release/manifest.json"))[sys.argv[1]])' "$1"; }
version=$(manifest version)
minimum=$(manifest minimumMacOS)
bundle_id=$(manifest bundleIdentifier)
display_name=$(manifest displayName)
copyright=$(manifest copyright)
entitlements=$(manifest entitlements)
dist="$PWD/dist"
rm -rf "$dist"
mkdir -p "$dist"

# Per-architecture native builds combined into Universal 2 with lipo.
for arch in arm64 x86_64; do
    swift build --configuration release --triple "$arch-apple-macosx$minimum" --product PostWoman
done
arm=$(swift build --configuration release --triple "arm64-apple-macosx$minimum" --show-bin-path)
intel=$(swift build --configuration release --triple "x86_64-apple-macosx$minimum" --show-bin-path)

app="$dist/PostWoman.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/lipo -create "$arm/PostWoman" "$intel/PostWoman" -output "$app/Contents/MacOS/PostWoman"
# The PostWoman_PostWoman.bundle resources only serve unbundled runs; the app icon comes from AppIcon.icns.
cp Design/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>PostWoman</string>
<key>CFBundleDisplayName</key><string>$display_name</string>
<key>CFBundleExecutable</key><string>PostWoman</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>NSHumanReadableCopyright</key><string>$copyright</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>$minimum</string>
</dict></plist>
PLIST

# Hardened runtime plus the App Sandbox entitlements (network client, user-selected files).
# The sandbox container (and its SwiftData store) is keyed by the bundle identifier.
if [ "$identity" = "-" ]; then
    /usr/bin/codesign --force --options runtime --entitlements "$entitlements" --sign - --identifier "$bundle_id" "$app"
else
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" --identifier "$bundle_id" "$app"
fi

dmg="$dist/PostWoman-$version.dmg"
scripts/make-dmg.sh "$app" "$dmg" "PostWoman $version"
if [ "$identity" != "-" ]; then /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"; fi

notarized=false
stapled=false
notary_requested=false
if [ -n "${POSTWOMAN_NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
    notary_requested=true
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait && notarized=true
    if [ "$notarized" = true ]; then
        /usr/bin/xcrun stapler staple "$app" && /usr/bin/xcrun stapler staple "$dmg" && stapled=true
    fi
fi

verified=false
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" && verified=true
runtime=false
# The CodeDirectory flags list "runtime" for hardened-runtime signatures (with or without adhoc).
/usr/bin/codesign --display --verbose=4 "$app" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && runtime=true
sandboxed=false
/usr/bin/codesign --display --entitlements - --xml "$app" 2>/dev/null | grep -q "com.apple.security.app-sandbox" && sandboxed=true
gatekeeper=$(/usr/sbin/spctl --assess --type execute --verbose=2 "$app" 2>&1 || true)
python3 - "$app" "$dmg" "$identity" "$verified" "$runtime" "$sandboxed" "$notarized" "$stapled" "$gatekeeper" "$notary_requested" <<'PY'
import json, plistlib, subprocess, sys, os
app, dmg, identity, verified, runtime, sandboxed, notarized, stapled, gatekeeper, notary_requested = sys.argv[1:]
manifest = json.load(open("release/manifest.json"))
info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
archs = lambda p: sorted(subprocess.run(["lipo", "-archs", p], capture_output=True, text=True).stdout.split())
problems = []
if info["LSMinimumSystemVersion"] != manifest["minimumMacOS"]: problems.append("minimum macOS mismatch")
if info["CFBundleIdentifier"] != manifest["bundleIdentifier"]: problems.append("bundle identifier mismatch")
if info["CFBundleShortVersionString"] != manifest["version"]: problems.append("version mismatch")
missing = set(manifest["architectures"]) - set(archs(os.path.join(app, "Contents/MacOS/PostWoman")))
if missing: problems.append(f"Contents/MacOS/PostWoman lacks {sorted(missing)}")
problems += [f"missing {a}" for a in manifest["artifacts"] if not os.path.exists(os.path.join(os.path.dirname(app), a))]
if runtime != "true": problems.append("hardened runtime missing")
if sandboxed != "true": problems.append("app sandbox entitlement missing")
# A requested notarization that fails must not leave a "successful" signed build behind.
if notary_requested == "true" and stapled != "true": problems.append("notarization or stapling failed")
evidence = {
    "version": manifest["version"], "dmg": os.path.basename(dmg), "signingIdentity": "ad-hoc (not distributable)" if identity == "-" else identity,
    "architectures": {"app": archs(os.path.join(app, "Contents/MacOS/PostWoman"))},
    "minimumMacOS": info["LSMinimumSystemVersion"], "signatureVerified": verified == "true", "hardenedRuntime": runtime == "true", "sandboxed": sandboxed == "true",
    "notarized": notarized == "true", "stapled": stapled == "true", "gatekeeperLocal": gatekeeper.strip(), "manifestProblems": problems,
}
json.dump(evidence, open(os.path.join(os.path.dirname(app), "release-evidence.json"), "w"), indent=2)
print(json.dumps(evidence, indent=2))
sys.exit(1 if problems or verified != "true" else 0)
PY
