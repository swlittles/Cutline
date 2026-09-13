# Cutline 0.2 verification

Tested September 12–13, 2026, on macOS 26.5.2, Apple M3 Pro, with Swift 6.2.1 from the installed Xcode toolchain. Build scripts select the full Xcode installation without changing system developer settings.

## Automated checks

The suite has grown from 26 to **146 XCTest cases, all passing together with zero failures**: 76 core/media tests, 29 hosted application tests, and 41 native UI workflows. The final run completed September 13, 2026 at 00:22 EDT with `TEST SUCCEEDED`; native UI execution took 9 minutes 42 seconds. It covers:

- Source-range validation, split boundaries, persistence, version-1 migration and timecodes.
- Caption timing through split/trim/speed, SRT/VTT Unicode/multiline/hour timestamps, style validation, transform interpolation and marker migration.
- Transcript-based ripple cuts across video, captions, markers, overlays and added audio, including speed changes, overlapping cuts and rejected whole-timeline deletion without mutation.
- OpenRouter structured request construction, transcript-only payloads, mocked successful suggestions, authentication failure, invalid ranges/IDs and long-transcript chunking.
- Generation model capability validation, credential-free request bodies, safe job IDs, mocked image decoding/persistence and video submission/failure/resume metadata.
- Real subprocess cancellation: a 30-second child process is terminated promptly and reports `CancellationError`.
- Actual AVFoundation renders, decoded caption/color/overlay pixels, portrait dimensions and frame rate, still-image conversion, selected OBS audio waveform, and atomic export replacement/cancellation/source protection.
- EditorStore history limits, selection and trim invariants, stale asynchronous work, import deduplication, preview readiness, debounced autosave, corrupt recovery, and undoable edits across tracks.
- Native dialogs, timeline keyboard commands and drag gestures, numeric trim, playback, missing-media relinking, canvas/output settings, caption styling/editing/import/export, transcript cuts, overlays, independent OBS gains, music, and local voiceover.
- UI provider success/error/retry/cancellation, explicit proposal review, generated image import, durable video cancellation/resume/download without duplicate submission, and local transcription success/failure/cancellation.

Run **`./scripts/test-all.sh`** for all three layers, `./scripts/test-ui.sh` for native UI workflows, or `./scripts/test.sh` for the fast core/media suite. See [the testing guide](docs/TESTING.md) for the workflow map, prerequisites, isolation, and result bundles. GitHub Actions is configured to run the suite and retain coverage, logs, and failure screenshots; the remote workflow has not been executed in this session.

The final local evidence is in [.build/final-tests/Cutline.xcresult](.build/final-tests/Cutline.xcresult), [xcodebuild.log](.build/final-tests/xcodebuild.log), and [coverage.json](.build/final-tests/coverage.json). These generated artifacts are not source-controlled. Xcode's executable-line coverage report records:

| Production source | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| CutlineCore framework | 1,247 / 1,315 | 94.83% |
| Cutline app, excluding `UITestRuntime.swift` | 4,299 / 4,412 | 97.44% |

Test targets are excluded from these percentages. App code retains small Debug isolation branches; only the dedicated fixture runtime is subtracted. Executed lines do not imply every branch, assertion, visual state, feature, or setting combination has been verified. This is measured line coverage, not “tests for everything.”

The test app uses a separate bundle ID and temporary data roots. UI tests intercept network requests and use fake credentials; they do not read the user's API key or spend credits. Transcription UI tests run actual FFmpeg extraction with a fixture whisper executable; a core test verifies the selected second OBS track is the expected 880 Hz mono 16 kHz waveform. These tests do not establish live model availability, speech accuracy, provider quality, pricing, or real Keychain access controls. Five isolated speech tests were also run in Release mode and correctly skipped before touching model storage.

## Regressions fixed by the expanded suite

- Trimming an unselected clip now clamps against that clip's source duration rather than the selected library item's duration.
- Generated video downloads receive a staged `.mp4` filename before AVFoundation inspection; CFNetwork's temporary suffix previously caused valid downloads to be rejected. Invalid downloads are cleaned up.
- Portrait media thumbnails now constrain their click targets to the visible card. Their invisible image bounds previously intercepted neighboring Add and Relink interactions.
- Blank caption edits and duplicate project/keyframe/transcript identities are rejected. Export commits only a completed render and preserves an existing destination on failure or cancellation.

## Real media checks

`CutlineVerify` rendered actual fixture media, not placeholder results:

- Landscape **1920×1080**, portrait **1080×1920**, square **1080×1080**: trimmed/split/reordered clips export at the expected two-second duration with audio.
- **1280×720 at 60 fps**, two-times speed, transform keyframes, a video overlay and a separate audio layer export at one second. Comparing captioned/uncaptioned frames found **32,359 materially changed pixels**. The captioned PNG was visually inspected.
- Still-image conversion produced a five-second clip. A transcript cut removed one second and the resulting native composition exported at four seconds.
- `whisper-cli` **1.9.0**, FFmpeg and the multilingual Base model ran against a locally synthesized 15.73-second commentary fixture. Recognition returned seven editable captions with recognizable wording. The project, SRT and captioned MP4 were generated successfully.
- The multilingual model download was verified against SHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`.
- The original two-track 440/880 Hz fixture exported with both tones at the expected half-volume amplitude. That check predates independent per-track gains and does not validate all OBS track layouts.

Relevant local artifacts: `.build/verification/v02-full/` (real transcription and captioned output), `.build/verification/v02-final/` (rendering, still conversion and transcript cut). These build artifacts are not source-controlled.

## Native UI and packaging

- The release `.app` builds and passes ad-hoc code-signature verification.
- The initial manual UI pass exercised import through the native picker, append, numeric trim, canvas change, playback, save and MP4 export. A five-second portrait export contained audio. These editing and file-dialog workflows now also have native XCUITest coverage.
- The 0.2 UI generated captions locally from the commentary recording and showed seven editable results, with burned-in preview text.
- Empty/populated editor layouts were visually inspected. Workspace labels were adjusted to prevent wrapping in the sidebar.
- Declared `studio.cutline.project` and registered the app document type instead of relying on an undeclared filename-derived type. The final foreground UI pass opened a `.cutline` project, performed a caption-range cut (15.73 → 14.37 seconds, seven → six captions), undid it (original duration/seven captions restored), saved a version-2 copy, and exported a 15.733-second 1280×720 MP4 with audio.
- Both live image/video catalogs loaded in the AI panel, showing the default models and supported options, without submitting a paid request.
- Earlier CUA background launches intermittently left the remote file picker's Open button disabled. The automated suite now launches the app in the foreground with isolated state, handles AppKit's native dialog identifiers, and tests native project open/save plus cold `--project` launch. These passing foreground workflows do not establish all background launch contexts. Finder-open handling is implemented but has not received a separate double-click acceptance test.

## Network validation and limits

OpenRouter's public catalogs were queried successfully: the configured default chat model advertised structured outputs, and dedicated catalogs exposed image and video models/capabilities. No user API key was read for a paid test and **no live billable inference was performed**. Image/video completion and download quality still need an account-configured end-to-end pass; test fixtures only validate the implemented transport/validation paths.

No full acceptance run yet covers multi-hour gameplay, completed 4K60 production workloads, HDR/VFR media, rotated real camera recordings, every OBS audio layout, Intel hardware, macOS 14/15, or all accessibility/localization settings. The UI suite starts and cancels a five-minute 4K60 export to verify cleanup; that does not validate a completed long export. Actual model-download interruption/integrity UI, library drag-in, and exhaustive gesture combinations also remain acceptance work. The custom compositor is SDR. The app is not notarized or packaged with portable helper dependencies. Autosave is a single recovery snapshot. See [the parity tracker](docs/CAPCUT_PARITY.md) for outstanding functionality; this report is not a full-parity or production-readiness claim.

## 0.3 release engineering verification (September 13)

The public source is [project repository](../../), with `main` for CI-gated downloads and `dev` for local work. Local default packaging produces `Cutline Dev.app`, a separate bundle, storage folder and OpenRouter Keychain service; its updater never starts.

The expanded updater suite passed 79 core/media tests and 34 hosted app tests. The new native Dev update-settings/menu test passed separately. Fourteen Python tests passed for release manifests, corrupted assets, feed URLs, first publication, retries and rollback protection. A subsequent full local UI rerun was interrupted after event synthesis timed out while a Keychain prompt remained pending; this run is not reported as passing. Hosted CI results are available in [GitHub Actions](../../).

Universal preview packaging produced ZIP and DMG archives; both app variants passed signature verification. The main executable includes arm64 and x86_64. ZIP/DMG integrity checks passed. Sparkle accepted the archive/feed signatures and rejected deliberately tampered copies. The dedicated private signing key is held in Keychain and GitHub Actions secrets, never source or app resources.

The Developer ID certificate backup was located and configured as Actions secrets. No local notarization profile or app-specific password was found. The repository explicitly uses preview mode until that credential is supplied; preview artifacts are not Apple-notarized. A complete two-version Sparkle installation/relaunch, fresh-machine Gatekeeper acceptance, and physical Intel runtime acceptance remain outstanding. See [release engineering](docs/RELEASING.md).

The first hosted macOS 15 run passed all 79 core and 34 hosted app tests, but failed 14 of 42 UI tests on its 1024×768 virtual screen. Failure screenshots confirmed offscreen controls. CI now requests 1920×1080 and verifies available desktop space before testing. That run also caught Delete being routed to the timeline while editing caption search text; routing now forwards Delete to the active text editor, with two additional hosted regression tests. The expanded 79 core / 37 app test run passed locally. The initial hosted failure remains in Actions as evidence; it is not counted as a successful release gate.


The repeated macOS 15 keyboard tests captured `VKCImageTextSelectionView_macOS` taking first responder after caption edits. The editor preview now disables AVKit's automatic Live Text frame analysis; caption transcription remains unchanged. Delete is scoped to the focused timeline. A separate queued-player-callback issue was corrected so Pause and explicit seeks retain their playhead position. The current suite has 158 XCTest cases and 14 release-tooling tests; the latest complete results are in Actions.
