# Cutline 0.4.0

Automatic local clipping for game recordings, with no OpenRouter calls or AI API costs.

- New Clips workspace: measure audio bursts and sustained frame changes across a recording, then group activity into padded, non-overlapping clips.
- Optional local HUD OCR with game profiles for Valorant, Counter-Strike 2 and Rainbow Six Siege; editable player aliases and visual region calibration. WARDOGS and Tarkov use audio/motion/markers unless a usable feed is calibrated.
- Select an isolated OBS audio track, adjust thresholds and timing, and inspect the measured evidence for every candidate.
- Preview clips, append them to the timeline with undo, or batch-export independent MP4s, editable projects and an analysis report.
- Cancellation and source-change checks, plus synthetic signal, real-media, OCR, app-state and native UI tests.

Requires macOS 14 or later. Universal Apple silicon / Intel app, Developer ID signed and Apple-notarized. Existing installations can use Check for Updates; Cutline Dev stays separate.

Automatic clipping uses AVFoundation and optional built-in macOS OCR. It needs no FFmpeg, transcript, downloaded model or API key. Captions still use separately installed FFmpeg/whisper.cpp. Batch clips preserve the source field of view in 16:9; timeline effects are not copied.

Review candidates before sharing: loudness, motion and OCR are fallible activity indicators. No real-game precision/recall or multi-hour 4K performance claim is made. Cutline remains an early development version without full CapCut parity.
