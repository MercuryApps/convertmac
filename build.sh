#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Video & Audio Converter"
EXE="VideoAudioConverter"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXE"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swift scripts/make_icon.swift "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"; mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/$APP_NAME.app"
fi
