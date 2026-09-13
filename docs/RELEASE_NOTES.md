# Cutline 0.3.0

First public macOS distribution of Cutline, an open-source video editor for game streamers.

- Native timeline editing, video/audio layers, transform and color controls, project recovery, and MP4 export.
- Local automatic captions with whisper.cpp and FFmpeg; editable captions and SRT/WebVTT exchange.
- Optional OpenRouter editing assistance and generated-media workflows.
- Sparkle updates signed with a dedicated Cutline key and hosted on GitHub.
- Separate Cutline Dev app for local work; release updates never replace it.
- Extensive native UI, app-state and actual-media tests.

Requires macOS 14 or later. Universal binary includes Apple silicon and Intel; Intel runtime behavior has not been validated on physical hardware.
Install FFmpeg and whisper.cpp separately for transcription and still-image conversion (`brew install ffmpeg whisper-cpp`). Models download from the Captions panel.

Developer-preview releases are ad-hoc signed and not notarized by Apple. Stable releases require Developer ID signing and notarization. Check the release tag and release.json for the artifact's mode. Cutline is an early development version and does not yet have full CapCut parity.
