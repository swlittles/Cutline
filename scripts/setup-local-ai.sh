#!/bin/bash
set -euo pipefail
if ! command -v brew >/dev/null; then
  echo "Install Homebrew from https://brew.sh, then rerun this script."
  exit 1
fi
brew install whisper-cpp ffmpeg
echo "Local engines ready. Download a speech model in Cutline’s Captions panel."
