# Local automatic clipping

Open **Clips**, choose an imported recording, select the audio track, and click **Find clips**. The scan does not require a timeline, captions, an OpenRouter key, or a network connection. It analyzes the source recording rather than the edited timeline.

Review each candidate with **Preview** and **Why this clip?**. **Add to timeline** appends the source range as an undoable edit. **Export selected clips** makes a new folder containing independent MP4s, `.cutline` projects, and `analysis.json` with the scan settings, measurements, source timestamps and selection evidence. Exports use the current resolution/frame-rate settings and preserve the complete source field of view in 16:9. Timeline effects, captions and added layers are not copied. Editable projects reference the original recording, so retain that file. Cancellation or failure removes the unfinished batch; existing files are never overwritten.

## Signals and controls

- **Audio bursts:** decode the selected embedded track to PCM, measure quarter-second RMS energy across its channels, and compare it to a local 30-second median. The default trigger is 8 dB above the median and at least −35 dBFS. Steady loud sound and very quiet noise do not qualify merely by being relatively loud. Select an isolated mic for reaction activity or isolated game audio for combat. The detector does not recognize laughter, speech, gunshots or emotion.
- **Sustained frame changes:** sample the displayed source frame at 2 fps by default, crop the configured Motion region and compare small grayscale images. Two adjacent changes above the threshold are needed; isolated flashes and large full-frame cuts are excluded. Exclude facecam/chat/animated overlays with **Preview / calibrate regions**. Camera movement, menus, flashing effects and loading animations can still trigger it. Sparse sampling can miss brief events.
- **Require audio and motion together:** enabled by default when both detectors are active. Only events within two seconds of each other qualify. Disable this for quieter visual activity or mic reactions without gameplay changes, or use one detector independently.
- **HUD OCR:** optional local macOS Vision text recognition. No cloud/LLM calls or API fees. OCR uses Apple's trained recognition model; audio/pixel rules do not use models. Enable **Read elimination feed**, enter the exact on-screen player names, and confirm the region on the recording. English recognition is configured; other scripts have not been validated.
- **Markers:** existing project markers attached to the selected source also create candidates, including games without a reliable HUD feed.

Audio peaks and visual activity are measurements, not a clip-worthiness model. The score is a ranking of measured evidence, not a confidence percentage or a guarantee that a play is interesting. No candidates is a valid result. There is no paid fallback.

## Game profiles from game

The native implementation was informed by `reference-editor/packages/clipper/src/game-profiles.ts`, `hud-scan.ts`, `gameplay.ts` and `audio-energy.ts` (repository revision recorded below). Cutline does not run that repository's cloud worker, transcript service, OpenRouter selectors, or rendering pipeline.

| Profile | Starting alias | Starting HUD region | Setup / payoff | Encounter gap |
| --- | --- | --- | --- | --- |
| Valorant | playerone | x 55%, y 2%, width 45%, height 30% | 6 / 4 sec | 12 sec |
| Counter-Strike 2 | PlayerOne | same upper-right region | 6 / 4 sec | 12 sec |
| Rainbow Six Siege | PlayerOne | same upper-right region | 8 / 4 sec | 15 sec |
| WARDOGS | PlayerOne | no verified preset | 10 / 5 sec | 20 sec |
| Escape from Tarkov | PlayerOne | no verified preset | 15 / 8 sec | 25 sec |

Coordinates use the displayed frame's top-left, after its rotation transform, and are fractions of width/height. The three starting rectangles are not accuracy-certified. OCR requires explicit calibration confirmation; switching recordings or profiles, opening a project, or restarting clears that confirmation. For unsupported games, the initial rectangle is only an editable placeholder. Tarkov may have no usable elimination feed; use audio/motion/markers instead of claiming kill detection. Profile changes retain per-game edits, saved locally when a scan starts. Dev and production profiles use separate application-support directories.

HUD rules require an exact normalized name on the killer side, an icon-sized horizontal gap, a different victim, high-confidence text and repeated observations. A local player's name on the victim side is a death boundary, not an elimination. Assister text and generic “You” are not treated as the player's identity. Persistent rows are counted once; another identical row needs an absence of more than two seconds. The default gameplay threshold is two elimination matches in an encounter. Name collisions, spectator mode, OCR mistakes and missed rows remain possible: these are HUD matches for human review, not independently verified kills.

Nearby events form encounters with configurable setup/payoff, maximum duration and clip count. Death evidence breaks encounters. Overlapping padded candidates are suppressed in score order; the output is chronological. Long or overlapping activity can therefore be omitted. Each run uses one game profile; split or select recordings by game when a stream changes games.

## Validation and limits

Synthetic tests cover relative/absolute loudness thresholds, selected-track isolation, steady sound/silence, frame differences, cuts/flashes, signal coincidence, name attribution, confidence, assist rejection, repeated-feed deduplication, death boundaries, padding, caps, source changes, cancellation, batch cleanup, real Vision OCR and playable exports. Native UI tests exercise scanning, preview, selection, timeline append/undo, calibration, invalid settings, quiet tracks, and native folder export. These tests are not a precision/recall benchmark on real gameplay.

Scans retain numeric measurements and the current frame rather than dumping every frame to disk. Audio decoding is sequential; frame sampling uses timestamped AVFoundation image generation. Scans support local recordings up to 24 hours but multi-hour 4K/OBS performance has not been benchmarked. No model download, FFmpeg installation, or transcription is required for this feature. Decoder errors are shown instead of silently returning partial coverage. MP4/MOV inputs supported by AVFoundation are the intended sources; unsupported containers/codecs must be remuxed or converted first.

Before trusting automatic selection for a game, calibrate its region on representative footage, then label a separate set of recordings with expected events and clip boundaries. Include deaths, assists, spectator view, scoreboard/menu screens, busy feeds, quiet gameplay, and HUD-scale/overlay changes. Review false positives, missed events and whether setup/payoff remains complete. No real-game accuracy percentage is claimed.

Reference revision: `04498f6da411fe531e075e2b68f8797a5749d361`.
