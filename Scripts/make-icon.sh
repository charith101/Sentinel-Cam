#!/bin/zsh
# Generates Resources/AppIcon.icns from the drawn 1024 px icon.
set -euo pipefail
cd "$(dirname "$0")/.."

swift Scripts/make-icon.swift
mkdir -p Resources/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -s format png -z $size $size Resources/AppIcon-1024.png \
    --out "Resources/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -s format png -z $doubled $doubled Resources/AppIcon-1024.png \
    --out "Resources/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
sips -s format png -z 1024 1024 Resources/AppIcon-1024.png \
  --out "Resources/AppIcon.iconset/icon_1024x1024.png" >/dev/null
iconutil --convert icns Resources/AppIcon.iconset --output Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
echo "wrote Resources/AppIcon.icns"
