# Automated testing

Cutline has 155 XCTest cases across three layers: 79 core/media tests, 34 hosted application tests, and 42 native UI workflows, plus 14 Python release-tooling tests. `CutlineCoreTests` tests project invariants, subtitle/timeline transforms, provider transport, subprocesses, real AVFoundation composition and pixel output, and atomic export. `CutlineAppTests` hosts the actual application and tests EditorStore state, asynchronous work, undo/redo, persistence, and recovery. `CutlineUITests` drives the compiled macOS app through XCUITest, including native file dialogs, and reads the resulting project/media files to verify edits.

## Run

Use a logged-in, unlocked Mac desktop with full Xcode. XCUITest needs foreground control; avoid using the keyboard/mouse while it runs. Install `ffmpeg` and optionally `xcodegen` with Homebrew.

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v  # Release validation and feed publication
./scripts/test.sh          # Fast core and actual-media integration tests
./scripts/test-all.sh unit # Core plus hosted EditorStore tests
./scripts/test-ui.sh       # Native UI workflows
./scripts/test-all.sh      # Complete suite with coverage and result bundle
```

Open `Cutline.xcodeproj`, select the Cutline scheme, and press Command-U to run in Xcode. `project.yml` is the source of truth; regenerate with `xcodegen generate` when adding files. The Swift package also remains usable, but SwiftPM cannot run the hosted UI suite.

Results are saved under `.build/test-results/<timestamp>-<suite>/`. Open `Cutline.xcresult` in Xcode for test activities and failure screenshots. `coverage.json` contains per-target/file executable-line coverage from `xccov`. An alternate output directory can be set with `CUTLINE_RESULTS_DIR`; use an empty directory for each run. Test failures return a nonzero exit status. Tests run serially because environment overrides and native UI focus are process-global.

The GitHub Actions workflow runs the complete suite on macOS 15 and stores result bundles, coverage, and logs even on failure. A successful local run does not establish that the remote workflow has run. Runner and artifact configuration follows [GitHub's runner documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-where-workflows-run/choose-the-runner-for-a-job) and [artifact documentation](https://docs.github.com/en/actions/tutorials/store-and-share-data). Native automation uses [Apple XCUITest](https://developer.apple.com/documentation/XCUIAutomation).

## Isolation and external boundaries

The Xcode test app has bundle ID `studio.cutline.editor.tests`, separate from the packaged app. Every UI case gets a unique `cutline-test-*` directory. Debug-only `CUTLINE_TEST_ROOT` routes recovery, generated assets, models, and fake credentials there. Release builds ignore this environment variable and exclude the UI provider protocol. Tests require an isolation handshake before editing or entering a fake credential; isolated core/hosted tests skip safely in Release configuration.

UI network requests are intercepted at URLProtocol; unconfigured requests fail closed. Tests use fake keys and do not spend OpenRouter credits. Provider success, malformed responses, authentication errors, cancellation, catalogs, images, and video failure/resume/download are deterministic fixtures. These cases test the real app and transport code, but do not establish current provider quality, availability, prices, billing, or real Keychain access controls.

Transcription UI tests use real FFmpeg audio extraction and a fixture executable at the whisper process boundary. They exercise track selection, progress, parsing, applying captions, errors, and cancellation. A separate core integration test verifies the extracted waveform really comes from the selected OBS track (880 Hz, mono 16 kHz). These fixtures do not measure speech-recognition accuracy. The prior real whisper/model verification is recorded separately in `VERIFICATION.md`.

Media fixtures are synthetic and committed under `Tests/CutlineCoreTests/Fixtures`. `scripts/generate-test-fixtures.sh` regenerates the two-track gameplay, portrait facecam, music, and artwork. Core render tests export actual MP4s and inspect their duration, dimensions, rate, audio tracks and decoded pixels; tolerances accommodate codec rounding.

## Coverage policy

Passing tests are evidence for the scenarios asserted, not a promise that every possible edit or CapCut feature is implemented. New editing behavior should include a meaningful invariant or output test and a UI workflow when users interact with it. Failure/cancellation tests must verify that existing projects and source recordings survive.

Outstanding acceptance work includes multi-hour/4K60 workloads, HDR/VFR and more codecs, Intel and older macOS versions, live paid AI/video delivery, model-download interruption and integrity UI, library drag-in and exhaustive gesture combinations, every accessibility/localization setting, and notarized packaging. Track unimplemented product scope in [CAPCUT_PARITY.md](CAPCUT_PARITY.md).


## Workflow map

| Area | Automated assertions |
| --- | --- |
| Project lifecycle | Native open/save-as, exact persisted edits, dirty cancel/discard, debounced recovery, corrupt recovery, version migration |
| Timeline | Keyboard split/duplicate/delete, boundary no-ops, undo/redo, reordering, trim clamping, drag reorder/trim, speed-aware ranges |
| Playback and output | Playback advances/pauses, preview gates export, canvas/resolution/FPS persist, real MP4 metadata, active export cancellation, atomic replacement and source protection |
| Captions | Selected OBS track and extracted waveform, local process success/failure/cancel, search/text/timing edits, styles, SRT/VTT round trips and native dialogs |
| Transcript editing | Caption-range cut and undo, reviewed speech gaps, ripple effects across every track, invalid whole-timeline deletion |
| Visual edits | Color presets and rendered pixels, transform keyframes/interpolation, video overlay timing/opacity and actual output |
| Audio | Imported music, independent OBS gains, fade persistence/mix parameters, local generated voiceover |
| Assistant | Explicit review, caption/highlight apply and undo, stale proposal rejection, HTTP/auth/rate-limit errors, malformed JSON/retry, cancellation, size/ID/range validation |
| Generated media | Catalog capability checks, image generation/import, durable video jobs, failure, resume without a second submission, downloaded media inspection, unsafe job/asset paths |
| Failure isolation | Missing media and relinking, invalid edits leave projects intact, temporary-file cleanup, safe Release-mode test refusal |

This table describes assertions in the suite. It does not imply exhaustive coverage of every setting combination or external-provider behavior. Consult the latest result bundle for the actual pass/fail status.
