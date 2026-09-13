#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo 'Full Xcode is required. Set DEVELOPER_DIR to Xcode.app/Contents/Developer.' >&2
  exit 1
fi
if ! command -v ffmpeg >/dev/null; then
  echo 'Install ffmpeg before running media integration and UI tests: brew install ffmpeg' >&2
  exit 1
fi
# The checked-in project works without XcodeGen. Regenerate after adding source files.
if command -v xcodegen >/dev/null; then xcodegen generate; fi
suite="${1:-all}"
selection=(-configuration Debug)
case "$suite" in
  all) ;;
  smoke) selection+=(-only-testing:CutlineUITests/EditorUITests/testCaptionTextSearchEditAndDelete -only-testing:CutlineUITests/EditorUITests/testSplitDuplicateDeleteUndoRedo) ;;
  ui) selection+=(-only-testing:CutlineUITests) ;;
  unit) selection+=(-only-testing:CutlineCoreTests -only-testing:CutlineAppTests) ;;
  *) echo 'Usage: scripts/test-all.sh [all|ui|unit|smoke]' >&2; exit 2 ;;
esac
result_dir="${CUTLINE_RESULTS_DIR:-$PWD/.build/test-results/$(date +%Y%m%d-%H%M%S)-$suite}"
mkdir -p "$result_dir"
set +e
xcodebuild test -project Cutline.xcodeproj -scheme Cutline \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -parallel-testing-enabled NO -enableCodeCoverage YES \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  -resultBundlePath "$result_dir/Cutline.xcresult" \
  "${selection[@]}" 2>&1 | tee "$result_dir/xcodebuild.log" | awk '/Test Case .* (started|passed|failed)|Test Suite |Executed [0-9]|error:|\*\* TEST/ { print; fflush() }'
result=${PIPESTATUS[0]}
set -e
if [ -d "$result_dir/Cutline.xcresult" ]; then
  xcrun xccov view --report --json "$result_dir/Cutline.xcresult" > "$result_dir/coverage.json" || true
fi
grep -E 'Test Suite .* (passed|failed)|Executed [0-9]|error:|\*\* TEST' "$result_dir/xcodebuild.log" || true
echo "Results: $result_dir"
exit "$result"
