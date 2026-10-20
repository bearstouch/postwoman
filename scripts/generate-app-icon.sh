#!/bin/sh
# Regenerate Design/AppIcon/AppIcon.icns and the unbundled-run icon from the PNGs in
# Design/AppIcon/AppIcon.iconset. Requires iconutil (Xcode command-line tools).
set -eu
cd "$(dirname "$0")/.."
iconutil --convert icns --output Design/AppIcon/AppIcon.icns Design/AppIcon/AppIcon.iconset
# `swift run` has no bundle icon; the app sets this PNG as the Dock icon instead.
cp Design/AppIcon/AppIcon.iconset/icon_512x512@2x.png Sources/PostWoman/Resources/AppIcon/AppIcon.png
echo "Generated $(pwd)/Design/AppIcon/AppIcon.icns"
