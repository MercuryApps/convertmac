#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh <version>   e.g. scripts/release.sh 1.0.0}"
APP_NAME="ConvertMac"
DMG_NAME="ConvertMac-$VERSION.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ ! -x .ffmpeg-build/out/ffmpeg ] || [ ! -x .ffmpeg-build/out/ffprobe ]; then
  scripts/build_ffmpeg.sh
fi

./build.sh
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
ditto "build/$APP_NAME.app" "$WORKDIR/$APP_NAME.app"
APP="$WORKDIR/$APP_NAME.app"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"

cp .ffmpeg-build/out/ffmpeg .ffmpeg-build/out/ffprobe "$APP/Contents/MacOS/"

LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp LICENSE "$LICENSES/GPL-3.0.txt"
cp docs/THIRD_PARTY.md "$LICENSES/THIRD_PARTY.md"

xattr -cr "$APP"
if [ -n "$SIGN_IDENTITY" ]; then
  SIGN=(codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")
else
  echo "SIGN_IDENTITY not set: using an ad-hoc signature (the app will not be notarized)"
  SIGN=(codesign --force --sign -)
fi
"${SIGN[@]}" "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"

mkdir -p dist
STAGE="$WORKDIR/dmg"
mkdir "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$WORKDIR/$DMG_NAME" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$WORKDIR/$DMG_NAME"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$WORKDIR/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORKDIR/$DMG_NAME"
  spctl --assess --type open --context context:primary-signature -v "$WORKDIR/$DMG_NAME"
fi

mv "$WORKDIR/$DMG_NAME" "dist/$DMG_NAME"

tar -cf "dist/ffmpeg-sources-$VERSION.tar" -C .ffmpeg-build sources

echo
echo "dist/$DMG_NAME"
echo "sha256: $(shasum -a 256 "dist/$DMG_NAME" | cut -d' ' -f1)"
echo "dist/ffmpeg-sources-$VERSION.tar"
