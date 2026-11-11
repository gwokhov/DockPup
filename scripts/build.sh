#!/bin/bash
# Copyright (C) 2026 Gwokhou
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/.build/DockPup.app"
iconset_dir="$project_dir/.build/AppIcon.iconset"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/.build/module-cache" "$iconset_dir"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$project_dir/Resources/AppIcon.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_dir" --output "$app_dir/Contents/Resources/AppIcon.icns"

xcrun swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$project_dir/.build/module-cache" \
    "$project_dir"/Sources/DockPup/*.swift \
    -o "$app_dir/Contents/MacOS/DockPup"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
codesign --force --sign - --identifier local.g.lockdog "$app_dir"
touch "$app_dir"
printf 'Built: %s\n' "$app_dir"
