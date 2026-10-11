#!/bin/bash
# Builds Weatherglass.app (and a zip of it) in ./dist.
#
#   scripts/build-app.sh                 # ad-hoc signed, for your own Mac
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# A universal build (Apple silicon + Intel) needs Xcode. With only the command line tools,
# set ARCHS=native to build for this Mac alone.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-universal}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/Weatherglass.app"

if [ "$ARCHS" = "universal" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Weatherglass"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/Weatherglass"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  scripts/make-icns.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Weatherglass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --entitlements Resources/Weatherglass.entitlements "$APP"
codesign --verify --strict "$APP"

(cd dist && rm -f Weatherglass.zip && ditto -c -k --keepParent Weatherglass.app Weatherglass.zip)
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Weatherglass"))"
