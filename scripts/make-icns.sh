#!/bin/bash
# Renders the icon and packs it into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift "$WORK/icon.png" >/dev/null
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$WORK/icon.png" Resources/AppIcon.png
echo "Wrote Resources/AppIcon.icns"
