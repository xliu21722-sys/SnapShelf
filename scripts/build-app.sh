#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
swift scripts/GenerateIcon.swift .build/AppIcon.iconset
iconutil -c icns -o .build/AppIcon.icns .build/AppIcon.iconset
app_dir="$PWD/dist/截图暂存.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/SnapShelf "$app_dir/Contents/MacOS/SnapShelf"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp .build/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.awei.snapshelf "$app_dir"
codesign --verify --strict "$app_dir"
printf '\n应用已生成：%s\n' "$app_dir"
