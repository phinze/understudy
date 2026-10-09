#!/bin/bash
set -euo pipefail
# Renders make-icon.swift into Resources/AppIcon.icns. The .icns is checked
# in so bundle.sh doesn't need to draw it on every build.
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset SDKROOT DEVELOPER_DIR
swift make-icon.swift "$work/icon.png"
set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
    sips -z $size $size "$work/icon.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$work/icon.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o ../AppIcon.icns
echo "wrote Resources/AppIcon.icns"
