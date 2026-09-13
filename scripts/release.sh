#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
MODE="${1:-signed}"
[[ "$MODE" = signed || "$MODE" = preview ]] || { echo 'Usage: release.sh [signed|preview]' >&2; exit 1; }
VERSION=$(cat VERSION); BUILD_NUMBER=$(cat BUILD_NUMBER)
TAG="v$VERSION"; CHANNEL=stable
if [ "$MODE" = signed ]; then
  : "${CUTLINE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
  : "${NOTARY_PROFILE:?Set a notarytool Keychain profile}"
  [[ "$CUTLINE_SIGNING_IDENTITY" != - ]] || exit 1
else
  export CUTLINE_SIGNING_IDENTITY=-
  TAG="v$VERSION-preview.$BUILD_NUMBER"; CHANNEL=preview
fi
export CUTLINE_BUILD_VARIANT=production CUTLINE_UNIVERSAL=1 CUTLINE_OUTPUT_DIR="$PWD/release-build" CUTLINE_RELEASE_CHANNEL="$CHANNEL"
bash scripts/build-app.sh
APP="$PWD/release-build/Cutline.app"
WORK=$(mktemp -d "$PWD/release-build/.package.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
NAME="Cutline-${TAG#v}-macos-universal"
notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$WORK/notary.json"
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("status") != "Accepted")' "$WORK/notary.json"
  xcrun stapler staple "$2"
  xcrun stapler validate "$2"
}
if [ "$MODE" = signed ]; then
  signature=$(codesign -dvv "$APP" 2>&1)
  [[ "$signature" == *"Authority=Developer ID Application:"* && "$signature" == *"TeamIdentifier=${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"* ]] || { echo 'Wrong signing certificate/team.' >&2; exit 1; }
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notarize.zip"
  notarize "$WORK/notarize.zip" "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
mkdir "$WORK/disk"
ditto "$APP" "$WORK/disk/Cutline.app"
ln -s /Applications "$WORK/disk/Applications"
cp docs/INSTALL.md "$WORK/disk/Install.txt"
if [ "$MODE" = preview ]; then printf 'Developer preview: ad-hoc signed, not notarized by Apple.\n' > "$WORK/disk/DEVELOPER-PREVIEW.txt"; fi
hdiutil create -volname "Cutline $VERSION" -srcfolder "$WORK/disk" -format UDZO "$WORK/$NAME.dmg"
if [ "$MODE" = signed ]; then
  codesign --timestamp --sign "$CUTLINE_SIGNING_IDENTITY" "$WORK/$NAME.dmg"
  notarize "$WORK/$NAME.dmg" "$WORK/$NAME.dmg"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/$NAME.zip"
OUT="$PWD/release-assets/$TAG"
mkdir -p "$OUT"
cp "$WORK/$NAME.dmg" "$WORK/$NAME.zip" "$OUT/"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
python3 - "$OUT/release.json" "$TAG" "$VERSION" "$BUILD_NUMBER" "$MODE" "$NAME" <<'PY'
import json,sys
from pathlib import Path
path,tag,version,build,mode,name=sys.argv[1:]
Path(path).write_text(json.dumps(dict(tag=tag,version=version,build=int(build),mode=mode,name=name),indent=2)+'\n')
PY
echo "Packaged $OUT"
