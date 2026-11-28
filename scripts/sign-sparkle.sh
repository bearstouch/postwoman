#!/bin/sh
# Prepares and signs Reqs.app/Contents/Frameworks/Sparkle.framework, inside-out, before the app is signed.
#
#   scripts/sign-sparkle.sh <Reqs.app> <identity|-> [arm64|x86_64]
#
# Reqs is sandboxed, so Sparkle installs through its Installer XPC service (SUEnableInstallerLauncherService and
# the -spks/-spki mach-lookup exceptions in release/Reqs.entitlements). The app has the network-client
# entitlement, so the Downloader service is removed. With an architecture, every binary is thinned to it.
set -eu
app=$1; identity=$2; arch=${3:-}
framework="$app/Contents/Frameworks/Sparkle.framework"
[ -d "$framework" ] || { echo "No Sparkle.framework in $app" >&2; exit 1; }
rm -rf "$framework/Versions/B/XPCServices/Downloader.xpc"
[ -d "$framework/Versions/B/XPCServices/Installer.xpc" ] || { echo "Sparkle.framework has no Installer.xpc" >&2; exit 1; }
if [ -n "$arch" ]; then
    for binary in Versions/B/Sparkle Versions/B/Autoupdate Versions/B/Updater.app/Contents/MacOS/Updater \
        Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer; do
        /usr/bin/lipo -thin "$arch" "$framework/$binary" -output "$framework/$binary.thin"
        mv "$framework/$binary.thin" "$framework/$binary"
    done
fi
sign() {
    if [ "$identity" = "-" ]; then
        /usr/bin/codesign --force --options runtime --sign - "$1"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$1"
    fi
}
sign "$framework/Versions/B/XPCServices/Installer.xpc"
sign "$framework/Versions/B/Autoupdate"
sign "$framework/Versions/B/Updater.app"
sign "$framework"
