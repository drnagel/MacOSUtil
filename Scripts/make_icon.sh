#!/bin/zsh
# Genera Resources/AppIcon.icns a partir de Scripts/make_icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift Scripts/make_icon.swift "$TMP/icon.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "✓ Resources/AppIcon.icns"
