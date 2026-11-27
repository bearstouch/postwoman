#!/bin/sh
# Regenerate the iconset, Design/AppIcon/AppIcon.icns and the unbundled-run icon from the SVG
# sources in Design/AppIcon. Requires rsvg-convert (brew install librsvg) and iconutil (Xcode
# command-line tools).
set -eu
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }

icon=Design/AppIcon
set_dir="$icon/AppIcon.iconset"
rm -rf "$set_dir"
mkdir -p "$set_dir"

# 16 and 32 px use the simplified artwork; larger sizes use the full CRT artwork.
render() {
    if [ "$1" -le 32 ]; then source="$icon/PostWoman-small.svg"; else source="$icon/PostWoman.svg"; fi
    rsvg-convert --width "$1" --height "$1" "$source" --output "$set_dir/$2"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns --output "$icon/AppIcon.icns" "$set_dir"
# `swift run` has no bundle icon; the app sets this PNG as the Dock icon instead.
cp "$set_dir/icon_512x512@2x.png" Sources/PostWoman/Resources/AppIcon/AppIcon.png
echo "Generated $(pwd)/$icon/AppIcon.icns"
