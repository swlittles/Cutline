#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE_REPOSITORY=$(python3 scripts/release_config.py)
TAG="${1:?Usage: publish-release.sh tag}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$ ]] || exit 1
OUT="$PWD/release-assets/$TAG"
python3 scripts/validate-release.py "$OUT"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  export GIT_COMMITTER_NAME="github-actions[bot]"
  export GIT_COMMITTER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
fi
SHA=$(git rev-parse HEAD)
git merge-base --is-ancestor "$SHA" origin/main || { echo 'Releases must come from main.' >&2; exit 1; }
# A tag must resolve to precisely the tested main commit, never a moved release tag.
if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  [[ "$(git rev-list -n 1 "$TAG")" = "$SHA" ]] || { echo 'Tag points at another commit.' >&2; exit 1; }
else
  git tag -a "$TAG" -m "Cutline $TAG" "$SHA"
  git push origin "refs/tags/$TAG"
fi
FLAGS=(--latest)
if [[ "$TAG" == *-preview.* ]]; then FLAGS=(--prerelease --latest=false); fi
if draft=$(gh release view "$TAG" --repo "$RELEASE_REPOSITORY" --json isDraft --jq .isDraft 2>/dev/null); then
  [[ "$draft" = true ]] || { echo 'Published release assets are immutable; refusing to replace them.' >&2; exit 1; }
  gh release upload "$TAG" "$OUT"/* --repo "$RELEASE_REPOSITORY" --clobber
  gh release edit "$TAG" --repo "$RELEASE_REPOSITORY" --title "Cutline $TAG" --notes-file docs/RELEASE_NOTES.md --target "$SHA" --draft=false "${FLAGS[@]}"
else
  gh release create "$TAG" "$OUT"/* --repo "$RELEASE_REPOSITORY" --verify-tag --target "$SHA" --title "Cutline $TAG" --notes-file docs/RELEASE_NOTES.md "${FLAGS[@]}"
fi
python3 scripts/publish-feed.py "$OUT" "$SHA"
