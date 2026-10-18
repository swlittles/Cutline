#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
VARIANT="${CUTLINE_BUILD_VARIANT:-development}"
case "$VARIANT" in
  development) APP_NAME='Cutline Dev'; BUNDLE_ID=studio.cutline.editor.dev ;;
  production) APP_NAME=Cutline; BUNDLE_ID=studio.cutline.editor ;;
  *) echo 'CUTLINE_BUILD_VARIANT must be development or production.' >&2; exit 1 ;;
esac
VERSION=$(cat VERSION); BUILD_NUMBER=$(cat BUILD_NUMBER)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid version/build number.' >&2; exit 1; }
OUTPUT_DIR="${CUTLINE_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
DESTINATION="$OUTPUT_DIR/$APP_NAME.app"
IDENTITY="${CUTLINE_SIGNING_IDENTITY:--}"
STAGING=$(mktemp -d "$OUTPUT_DIR/.cutline-build.XXXXXX")
trap 'if [ -d "$STAGING/previous.app" ] && [ ! -e "$DESTINATION" ]; then mv "$STAGING/previous.app" "$DESTINATION"; fi; rm -rf "$STAGING"' EXIT
APP="$STAGING/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [ "${CUTLINE_UNIVERSAL:-0}" = 1 ]; then
  for arch in arm64 x86_64; do
    for product in Cutline cutline-mcp; do swift build -c release --product "$product" --triple "$arch-apple-macosx14.0" --scratch-path ".build/distribution-$arch"; done
  done
  BIN=$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/distribution-arm64 --show-bin-path)
  INTEL_BIN=$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/distribution-x86_64 --show-bin-path)
  for product in Cutline cutline-mcp; do
    lipo -create "$BIN/$product" "$INTEL_BIN/$product" -output "$APP/Contents/MacOS/$product"
    lipo "$APP/Contents/MacOS/$product" -verify_arch arm64 x86_64
  done
else
  swift build -c release --product Cutline
  swift build -c release --product cutline-mcp
  BIN=$(swift build -c release --show-bin-path)
  cp "$BIN/Cutline" "$BIN/cutline-mcp" "$APP/Contents/MacOS/"
fi
# Keep debug paths in local build outputs, out of signed distributables.
xcrun strip -S "$APP/Contents/MacOS/Cutline" "$APP/Contents/MacOS/cutline-mcp"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != - ]; then SIGN_ARGS+=(--options runtime --timestamp); fi
for component in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" "$FRAMEWORK"; do codesign "${SIGN_ARGS[@]}" "$component"; done
# Optional self-contained helpers (static ffmpeg, whisper-cli) so MKV conversion and Whisper
# captions work without Homebrew. Captions fall back to macOS speech recognition without them.
if [ -n "${CUTLINE_HELPERS_DIR:-}" ]; then
  mkdir -p "$APP/Contents/Helpers"
  for helper in ffmpeg whisper-cli; do
    if [ -x "$CUTLINE_HELPERS_DIR/$helper" ]; then
      if otool -L "$CUTLINE_HELPERS_DIR/$helper" | tail -n +2 | grep -qE '/(opt/homebrew|usr/local)/'; then echo "$helper links Homebrew libraries; supply a self-contained build." >&2; exit 1; fi
      cp "$CUTLINE_HELPERS_DIR/$helper" "$APP/Contents/Helpers/$helper"; codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/$helper"
    fi
  done
fi
# The agent connector (Model Context Protocol server) that Claude Code and Codex launch.
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID.mcp" "$APP/Contents/MacOS/cutline-mcp"
python3 scripts/make-plist.py "$APP/Contents/Info.plist" "$APP_NAME" "$BUNDLE_ID" "$VERSION" "$BUILD_NUMBER" "${CUTLINE_RELEASE_CHANNEL:-stable}"
cp Config/AppIcon.icns LICENSE docs/THIRD_PARTY_NOTICES.txt docs/Sparkle-LICENSE.txt "$APP/Contents/Resources/"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
# Moving whole bundles preserves a running previous executable; never overwrite its inode.
if [ -e "$DESTINATION" ]; then mv "$DESTINATION" "$STAGING/previous.app"; fi
mv "$APP" "$DESTINATION"
echo "Built $DESTINATION"
