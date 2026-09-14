# Cutline 0.5.0

Mobile shorts now have their own required composition, separate from YouTube long-form videos.

- New projects default to **Mobile Short · 9:16**. **YouTube Video · 16:9** is an explicit Inspector choice.
- Every short uses 30% facecam, a 2% black strip with the Kick mark and `Kick.com/your-channel`, and 68% gameplay. Branding remains visible through effects, fades, overlays and captions.
- Set a required opening hook in the Inspector or on each automatic clip. Individual timeline clips can override the shared hook; the hook appears for the first three seconds of each clip.
- Check facecam and gameplay crops against each recording in **Short framing**. A Fit option preserves a full gameplay region for chess or HUD-heavy scenes.
- Automatic candidate preview and export now use the same native portrait compositor. Automatic timeline insertion selects the mobile workflow, with undo. AI suggestions have separate mobile-short and YouTube-video actions.
- Older projects keep their framing on open and require an output choice before export. New version-3 project files preserve hooks and crops and are rejected by older apps instead of silently losing the layout.
- Additional model, pixel-rendering, export, app-state and native UI regression tests cover these workflows.

Requires macOS 14 or later. Cutline Dev remains a separate local app with its updater disabled. Production packaging continues through the existing signed/notarized main-branch release workflow.

Local automatic clipping makes no OpenRouter calls. Captions still use separately installed FFmpeg/whisper.cpp. Crop calibration is currently per recording; mixed OBS scenes need manual checking. Hooks are editable text, not automatically inferred. Review detection results and tighten their timing before posting. Cutline remains an early development version without full CapCut parity.
