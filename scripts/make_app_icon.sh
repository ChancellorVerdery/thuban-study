#!/bin/zsh
# Regenerates ThubanStudy/Resources/Assets.xcassets/AppIcon.appiconset from the app's mark (Brass, dark plate).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
cp scripts/make_app_icon.swift "$TMP/main.swift"
swiftc -D APPICON_TOOL -o "$TMP/make_app_icon" "$TMP/main.swift" \
  ThubanStudy/Views/Components/AppArt.swift ThubanStudy/Views/Components/AppArtSource.swift
find ThubanStudy/Resources/Assets.xcassets/AppIcon.appiconset -name "*.png" -delete
"$TMP/make_app_icon" ThubanStudy/Resources/Assets.xcassets/AppIcon.appiconset
rm -rf "$TMP"
