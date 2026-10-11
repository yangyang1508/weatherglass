#!/bin/bash
# Records the README demo: a made-up desktop with Weatherglass on it.
# Only Weatherglass's own windows are captured, never the rest of your screen.
#
#   scripts/record-demo.sh snow          # docs/media/snow.mp4 and docs/media/snow.gif
#   scripts/record-demo.sh storm 9
#
# Needs ffmpeg (brew install ffmpeg). The first run asks for Screen Recording permission
# for your terminal app. Keep the mouse still while it records.
set -euo pipefail
cd "$(dirname "$0")/.."

KIND="${1:?usage: scripts/record-demo.sh <snow|blizzard|rain|storm|drizzle|hail|fog|wind> [seconds]}"
SECONDS_TO_RECORD="${2:-9.5}"
OUT=docs/media
SUITE=weatherglass.demo-recording

command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }
swift build -c release --product Weatherglass
BIN="$(swift build -c release --show-bin-path)/Weatherglass"
[ -x .build/capture ] || swiftc -O scripts/capture.swift -o .build/capture

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

QUIT_AFTER="$(awk "BEGIN { print $SECONDS_TO_RECORD + 2 }")"
"$BIN" --demo "$KIND" --quit-after "$QUIT_AFTER" --settings "$SUITE" &
PID=$!
# Give the windows a moment to appear before recording starts.
sleep 0.8
.build/capture video "$PID" "$SECONDS_TO_RECORD" "$TMP/raw.mov"
wait "$PID" || true
# The demo used its own settings domain. Remove it so nothing is left behind.
defaults delete "$SUITE" >/dev/null 2>&1 || true

ffmpeg -loglevel error -y -i "$TMP/raw.mov" -vf "scale=1280:-2:flags=lanczos" \
  -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart -an "$OUT/$KIND.mp4"
ffmpeg -loglevel error -y -i "$TMP/raw.mov" -vf \
  "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$OUT/$KIND.gif"
ls -lh "$OUT/$KIND.mp4" "$OUT/$KIND.gif"
