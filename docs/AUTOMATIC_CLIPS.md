# Local automatic clipping

**Output:** every automatic clip is a [Mobile Short](OUTPUT_WORKFLOWS.md): 9:16 with 30% facecam, 2% mandatory black branding strip (configured locally in Settings), and 68% gameplay. Every kept clip needs a hook (Keep fills in the suggested hook when the field is empty), and the recording's crops are confirmed in the **Layout** step. No additional AI service is used.

Start from **Home → Clip a stream** (or **Find moments for shorts** on a recording in the editor's media library). Choosing a recording starts measuring it at once. The scan does not require a timeline, captions, an OpenRouter key, or a network connection. It analyzes the source recording rather than the edited timeline.

## Measure once, evaluate instantly

Scanning is split into two parts. The slow part is a **measurement** pass: one AVAssetReader pass decodes *every* embedded audio track into quarter-second loudness, and, running at the same time, video is sampled for motion (plus HUD OCR when it is enabled). The fast part is **evaluation**: the rules below run over the retained measurements. Changing sensitivity, thresholds, lead-in/payoff, encounter gap, clip caps, detection track or the "both signals" rule only re-evaluates, which takes milliseconds to a fraction of a second. Only a new motion/HUD region, sample rate or OCR setup samples the video again, and audio is never decoded twice. Measurements are cached in `Analysis/` under Application Support (owner-only, newest 24 kept) and invalidated when the file's path, size, modification date or duration changes.

## Audio roles

In **Layout → Sound → Change**, each embedded track gets a role, shown as **Everything** (full mix), **My voice** (mic), **Game** or **Not used**. Each track shows a loudness graph and has an eight-second listen button that starts near its loudest point. Roles decide:

- **Detection:** the first Mic track, otherwise Game, otherwise the Full mix.
- **Export audio:** the Full mix alone if there is one (so isolated tracks are never doubled); otherwise Mic and Game tracks mixed together.
- **Captions:** the first Mic track, otherwise the Full mix.

The initial roles are a guess from track titles written by the recorder, falling back to the common OBS order (mix, mic, game). Always confirm them.

## Review and export

**Review** plays each moment through the real compositor, with framing, branding strip, hook and captions. Keep (**K**; an empty hook gets the suggested one), skip (**X**), undo (**⌘Z**), and change lead-in/payoff with **[ ]** or the trim handles (1 s minimum, 180 s maximum). Decisions, trims, hooks and hand-marked moments are stored in the project under `clipReview`, so a saved session reopens where it stopped. **Why this moment?** lists the evidence.

**Export** makes a new folder, `<recording> shorts` in the chosen export folder (default `~/Movies/Cutline`), with one MP4 per kept clip (named after its hook) and an **Editable projects** subfolder holding each `.cutline` project plus `analysis.json` with the scan settings, measurements, source timestamps and selection evidence. Exports use the current resolution/frame-rate settings. Optional captions transcribe **only the kept ranges** on this Mac, with Whisper when it is installed with a model and macOS on-device speech recognition otherwise. Export writes any missing captions automatically; **Preview captions now** writes them first so you can fix the wording; trimming a clip afterwards discards its captions so they never drift. Editable projects reference the original recording, so retain that file. Cancellation or failure removes the unfinished batch; existing files are never overwritten.

## Signals and controls

- **Audio bursts:** decode the selected embedded track to PCM, measure quarter-second RMS energy across its channels, and compare it to a local 30-second median. The default trigger is 8 dB above the median and at least −35 dBFS. Steady loud sound and very quiet noise do not qualify merely by being relatively loud. Select an isolated mic for reaction activity or isolated game audio for combat. The detector does not recognize laughter, speech, gunshots or emotion.
- **Sustained frame changes:** sample the displayed source frame at 2 fps by default, crop the configured Motion region and compare small grayscale images. Two adjacent changes above the threshold are needed; isolated flashes and large full-frame cuts are excluded. Exclude facecam/chat/animated overlays with **Advanced → Motion and HUD areas** (drag the boxes). Camera movement, menus, flashing effects and loading animations can still trigger it. Sparse sampling can miss brief events.
- **Require audio and motion together:** enabled by default when both detectors are active. Only events within two seconds of each other qualify. Disable this for quieter visual activity or mic reactions without gameplay changes, or use one detector independently.
- **HUD OCR:** optional local macOS Vision text recognition. No cloud/LLM calls or API fees. OCR uses Apple's trained recognition model; audio/pixel rules do not use models. Enable **Read elimination feed**, enter the exact on-screen player names, and confirm the region on the recording. English recognition is configured; other scripts have not been validated.
- **Markers:** moments you add with **Pick clips → Add a moment**, and existing timeline markers on the selected source, always create candidates. This includes games without a reliable HUD feed.
- **Sensitivity:** the single slider maps to audio rise (12 → 8 → 5 dB), audio floor (−30 → −35 → −45 dBFS) and frame-change threshold (0.10 → 0.07 → 0.04). The midpoint is exactly the default.

Audio peaks and visual activity are measurements, not a clip-worthiness model. The score is a ranking of measured evidence, not a confidence percentage or a guarantee that a play is interesting. No candidates is a valid result. There is no paid fallback.

## Game profiles

Game presets contain timing and approximate HUD regions. Enter your own exact player aliases; all presets start with empty names.

| Profile | Starting alias | Starting HUD region | Setup / payoff | Encounter gap |
| --- | --- | --- | --- | --- |
| Valorant | User-entered | x 55%, y 2%, width 45%, height 30% | 6 / 4 sec | 12 sec |
| Counter-Strike 2 | User-entered | same upper-right region | 6 / 4 sec | 12 sec |
| Rainbow Six Siege | User-entered | same upper-right region | 8 / 4 sec | 15 sec |
| WARDOGS | User-entered | no verified preset | 10 / 5 sec | 20 sec |
| Escape from Tarkov | User-entered | no verified preset | 15 / 8 sec | 25 sec |

Coordinates use the displayed frame's top-left, after its rotation transform, and are fractions of width/height. The three starting rectangles are not accuracy-certified. OCR requires explicit calibration confirmation; switching recordings or profiles, opening a project, or restarting clears that confirmation. For unsupported games, the initial rectangle is only an editable placeholder. Tarkov may have no usable elimination feed; use audio/motion/markers instead of claiming kill detection. Profile changes retain per-game edits, saved locally when a scan starts. Dev and production profiles use separate application-support directories.

HUD rules require an exact normalized name on the killer side, an icon-sized horizontal gap, a different victim, high-confidence text and repeated observations. A local player's name on the victim side is a death boundary, not an elimination. Assister text and generic “You” are not treated as the player's identity. Persistent rows are counted once; another identical row needs an absence of more than two seconds. The default gameplay threshold is two elimination matches in an encounter. Name collisions, spectator mode, OCR mistakes and missed rows remain possible: these are HUD matches for human review, not independently verified kills.

Nearby events form encounters with configurable setup/payoff, maximum duration and clip count. Death evidence breaks encounters. Overlapping padded candidates are suppressed in score order; the output is chronological. Long or overlapping activity can therefore be omitted. Each run uses one game profile; split or select recordings by game when a stream changes games.

## Validation and limits

Synthetic tests cover relative/absolute loudness thresholds, selected-track isolation, steady sound/silence, frame differences, cuts/flashes, signal coincidence, name attribution, confidence, assist rejection, repeated-feed deduplication, death boundaries, padding, caps, source changes, cancellation, batch cleanup, real Vision OCR and playable exports. Native UI tests exercise scanning, preview, selection, timeline append/undo, calibration, invalid settings, quiet tracks, and native folder export. These tests are not a precision/recall benchmark on real gameplay.

Scans retain numeric measurements and the current frame rather than dumping every frame to disk. Audio decoding is sequential; frame sampling uses timestamped AVFoundation image generation. Scans support local recordings up to 24 hours but multi-hour 4K/OBS performance has not been benchmarked. No model download, FFmpeg installation, or transcription is required for this feature. Decoder errors are shown instead of silently returning partial coverage. MP4/MOV inputs supported by AVFoundation are the intended sources; unsupported containers/codecs must be remuxed or converted first.

Before trusting automatic selection for a game, calibrate its region on representative footage, then label a separate set of recordings with expected events and clip boundaries. Include deaths, assists, spectator view, scoreboard/menu screens, busy feeds, quiet gameplay, and HUD-scale/overlay changes. Review false positives, missed events and whether setup/payoff remains complete. No real-game accuracy percentage is claimed.
