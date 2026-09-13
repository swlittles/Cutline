#!/bin/bash
# This changes only the ephemeral GitHub runner's virtual display.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" = true ]] || { echo 'Run this only on GitHub Actions.' >&2; exit 1; }
screenresolution list
screenresolution set 1920x1080x32
screenresolution get
swift -e 'import AppKit; guard let screen = NSScreen.main, screen.visibleFrame.width >= 1440, screen.visibleFrame.height >= 900 else { fatalError("Native UI tests need a virtual desktop of at least 1440 x 900 points") }; print("UI test desktop:", screen.visibleFrame)'
