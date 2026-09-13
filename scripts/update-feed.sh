#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE_REPOSITORY=$(python3 scripts/release_config.py)
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
TAG="${1:?Usage: update-feed.sh tag}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$ ]] || exit 1
OUT="$PWD/release-assets/$TAG"
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$OUT/release.json")
TOOLS="$PWD/.build/distribution-arm64/artifacts/sparkle/Sparkle/bin"
WORK=$(mktemp -d "$PWD/.build/appcast.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp "$OUT/$NAME.zip" "$WORK/"
cp docs/RELEASE_NOTES.md "$WORK/$NAME.md"
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | swift scripts/verify-update-key.swift Config/SparklePublicKey.txt
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - --maximum-deltas 0 --embed-release-notes --download-url-prefix "https://github.com/$RELEASE_REPOSITORY/releases/download/$TAG/" "$WORK"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/sign_update" --ed-key-file - --verify "$WORK/appcast.xml"
else
  [[ "$("$TOOLS/generate_keys" --account studio.cutline.updates -p)" = "$(cat Config/SparklePublicKey.txt)" ]] || exit 1
  "$TOOLS/generate_appcast" --account studio.cutline.updates --maximum-deltas 0 --embed-release-notes --download-url-prefix "https://github.com/$RELEASE_REPOSITORY/releases/download/$TAG/" "$WORK"
  "$TOOLS/sign_update" --account studio.cutline.updates --verify "$WORK/appcast.xml"
fi
cp "$WORK/appcast.xml" "$OUT/appcast.xml"
python3 scripts/validate-release.py "$OUT"
