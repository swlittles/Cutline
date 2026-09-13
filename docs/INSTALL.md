Cutline for macOS 14 and later (Apple silicon and Intel)

Open the DMG and drag Cutline.app into Applications, then open it from there.
The ZIP contains the same app. Do not run directly from the mounted disk image.
Developer-preview downloads are explicitly labeled and are not Apple-notarized.

For local transcription and still-image conversion, install Homebrew (https://brew.sh), then run:
  brew install ffmpeg whisper-cpp
These dependencies are not bundled in this release. Download a speech model from Cutline's Captions panel.
Video editing, project saving and native MP4 export use built-in macOS frameworks.

Updates: Cutline > Check for Updates, or Settings > Automatically check for updates.
Downloads are verified using Cutline's dedicated Sparkle signing key. Installation is your choice.
No GitHub login is required to download or update the public app.

Cutline Dev is for local source builds. It has separate settings, recovery and generated files, and does not run the updater.
Projects can be opened by either build. Referenced recordings and generated media must remain available.

Find downloads in this repository’s Releases tab.
