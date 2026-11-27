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
# A build gets an update feed only when the manifest records the Sparkle public key (as in Trellis).
sparkle_key=$(python3 -c 'import json;print(json.load(open("release/manifest.json")).get("sparklePublicKey") or "")')
feed_url="https://raw.githubusercontent.com/bearstouch/postwoman/appcast/appcast.xml"
# macOS wants numeric bundle versions: CFBundleShortVersionString is the X.Y.Z core, and CFBundleVersion adds a build
# that orders pre-releases before the release (alpha.N = N, beta.N = 30+N, rc.N = 60+N, release = 100). Sparkle
# compares CFBundleVersion. The full version, label included, goes to PostWomanVersion for the app to show.
bundle_versions=$(python3 - "$version" <<'PY'
import re, sys
match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.([1-9]\d?))?", sys.argv[1])
if not match or (match[5] and int(match[5]) >= 30): sys.exit(f"Unsupported version {sys.argv[1]!r}: use X.Y.Z or X.Y.Z-alpha|beta|rc.N with N < 30.")
core = ".".join(match.group(1, 2, 3))
build = 100 if not match[4] else {"alpha": 0, "beta": 30, "rc": 60}[match[4]] + int(match[5])
print(core, f"{core}.{build}")
PY
)
short_version=${bundle_versions% *}
bundle_version=${bundle_versions#* }
dist="$PWD/dist"
rm -rf "$dist"
mkdir -p "$dist"

# Per-architecture native builds combined into Universal 2 with lipo. Each architecture gets its own scratch path:
# the swiftbuild build system (SwiftPM's default since Swift 6.4) uses one bin path for every --triple.
for arch in arm64 x86_64; do
    swift build --configuration release --scratch-path ".build/release-$arch" --triple "$arch-apple-macosx$minimum" --product PostWoman
    swift build --configuration release --scratch-path ".build/release-$arch" --triple "$arch-apple-macosx$minimum" --product postwoman-cli
done
arm=$(swift build --configuration release --scratch-path .build/release-arm64 --triple "arm64-apple-macosx$minimum" --show-bin-path)
intel=$(swift build --configuration release --scratch-path .build/release-x86_64 --triple "x86_64-apple-macosx$minimum" --show-bin-path)

app="$dist/PostWoman.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers" "$app/Contents/Frameworks"
/usr/bin/lipo -create "$arm/PostWoman" "$intel/PostWoman" -output "$app/Contents/MacOS/PostWoman"
# The command-line tool, which talks to the app's MCP server (Settings → Remote Agent).
/usr/bin/lipo -create "$arm/postwoman-cli" "$intel/postwoman-cli" -output "$app/Contents/Helpers/postwoman"
# The PostWoman_PostWoman.bundle resources only serve unbundled runs; the app icon comes from AppIcon.icns.
cp Design/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Sparkle's framework is already Universal 2.
/usr/bin/ditto "$arm/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp ThirdParty/Sparkle-LICENSE.txt "$app/Contents/Resources/Sparkle-LICENSE.txt"
if [ -n "$sparkle_key" ]; then
    # Sandboxed: Sparkle installs through its Installer XPC service. Automatic checks start off (Settings → Updates).
    updates="<key>SUFeedURL</key><string>$feed_url</string>
<key>SUPublicEDKey</key><string>$sparkle_key</string>
<key>SUEnableInstallerLauncherService</key><true/>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUEnableSystemProfiling</key><false/>"
else
    echo "warning: release/manifest.json has no sparklePublicKey; this build has no updater." >&2
    updates=""
fi
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
<key>CFBundleShortVersionString</key><string>$short_version</string>
<key>CFBundleVersion</key><string>$bundle_version</string>
<key>PostWomanVersion</key><string>$version</string>
<key>NSHumanReadableCopyright</key><string>$copyright</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>$minimum</string>
$updates
</dict></plist>
PLIST

# Hardened runtime plus the App Sandbox entitlements (network client, user-selected files).
# The sandbox container (and its SwiftData store) is keyed by the bundle identifier.
# Nested code first (hardened runtime, no sandbox: the CLI runs in the user's shell), then the app seals it.
if [ "$identity" = "-" ]; then
    /usr/bin/codesign --force --options runtime --sign - --identifier "$bundle_id.cli" "$app/Contents/Helpers/postwoman"
    scripts/sign-sparkle.sh "$app" -
    # Ad-hoc signatures have no Team ID, so library validation would refuse the embedded Sparkle.framework. Only these
    # non-distributable builds relax it; Developer ID builds keep library validation.
    adhoc_entitlements="$dist/adhoc.entitlements"
    cp "$entitlements" "$adhoc_entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$adhoc_entitlements"
    /usr/bin/codesign --force --options runtime --entitlements "$adhoc_entitlements" --sign - --identifier "$bundle_id" "$app"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" --identifier "$bundle_id.cli" "$app/Contents/Helpers/postwoman"
    scripts/sign-sparkle.sh "$app" "$identity"
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" --identifier "$bundle_id" "$app"
fi

# Notarize and staple the app before it goes into the DMG, so the copy users drag out of the
# DMG carries its own ticket (Gatekeeper accepts it offline). Then notarize and staple the DMG.
notarized=false
stapled=false
notary_requested=false
dmg="$dist/PostWoman-$version.dmg"
if [ -n "${POSTWOMAN_NOTARY_PROFILE:-}" ] && [ "$identity" != "-" ]; then
    notary_requested=true
    zip="$dist/PostWoman-$version-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$app" "$zip"
    /usr/bin/xcrun notarytool submit "$zip" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait \
        && /usr/bin/xcrun stapler staple "$app" && app_stapled=true
    rm -f "$zip"
fi
scripts/make-dmg.sh "$app" "$dmg" "PostWoman $version"
if [ "$identity" != "-" ]; then /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"; fi
if [ "${app_stapled:-false}" = true ]; then
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$POSTWOMAN_NOTARY_PROFILE" --wait && notarized=true
    if [ "$notarized" = true ]; then
        /usr/bin/xcrun stapler staple "$dmg" && scripts/verify-dmg-staple.sh "$dmg" && stapled=true
    fi
fi

verified=false
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app" && verified=true
runtime=false
# The CodeDirectory flags list "runtime" for hardened-runtime signatures (with or without adhoc).
/usr/bin/codesign --display --verbose=4 "$app" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && \
    /usr/bin/codesign --display --verbose=4 "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>&1 | grep -Eq "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" && runtime=true
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
if info.get("PostWomanVersion") != manifest["version"]: problems.append("version mismatch")
if info.get("SUPublicEDKey", "") != (manifest.get("sparklePublicKey") or ""): problems.append("SUPublicEDKey does not match the manifest")
entitlements = subprocess.run(["codesign", "--display", "--entitlements", "-", app], capture_output=True, text=True).stdout
if identity != "-" and "disable-library-validation" in entitlements: problems.append("a distributable build must keep library validation")
if info.get("SUFeedURL") and "postwoman-spki" not in entitlements: problems.append("the sandboxed updater needs the -spks/-spki mach-lookup exceptions")
missing = set(manifest["architectures"]) - set(archs(os.path.join(app, "Contents/MacOS/PostWoman")))
if missing: problems.append(f"Contents/MacOS/PostWoman lacks {sorted(missing)}")
missing = set(manifest["architectures"]) - set(archs(os.path.join(app, "Contents/Helpers/postwoman")))
if missing: problems.append(f"Contents/Helpers/postwoman lacks {sorted(missing)}")
problems += [f"missing {a}" for a in manifest["artifacts"] if not os.path.exists(os.path.join(os.path.dirname(app), a))]
if runtime != "true": problems.append("hardened runtime missing")
if sandboxed != "true": problems.append("app sandbox entitlement missing")
# A requested notarization that fails must not leave a "successful" signed build behind.
if notary_requested == "true" and stapled != "true": problems.append("notarization or stapling failed")
evidence = {
    "version": manifest["version"], "dmg": os.path.basename(dmg), "signingIdentity": "ad-hoc (not distributable)" if identity == "-" else identity,
    "architectures": {"app": archs(os.path.join(app, "Contents/MacOS/PostWoman")), "cli": archs(os.path.join(app, "Contents/Helpers/postwoman"))},
    "minimumMacOS": info["LSMinimumSystemVersion"], "signatureVerified": verified == "true", "hardenedRuntime": runtime == "true", "sandboxed": sandboxed == "true",
    "notarized": notarized == "true", "stapled": stapled == "true", "gatekeeperLocal": gatekeeper.strip(), "updateFeed": info.get("SUFeedURL"), "manifestProblems": problems,
}
json.dump(evidence, open(os.path.join(os.path.dirname(app), "release-evidence.json"), "w"), indent=2)
print(json.dumps(evidence, indent=2))
sys.exit(1 if problems or verified != "true" else 0)
PY
