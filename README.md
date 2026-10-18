# Cutline

A native, local-first macOS video editor for game streamers, built with SwiftUI, AppKit, AVFoundation and Core Image. MIT-licensed source. Original software, unaffiliated with CapCut.

**Version 0.4 is a working development build, not full CapCut parity.** The [parity tracker](docs/CAPCUT_PARITY.md) records implemented workflows, remaining subfeatures, and acceptance requirements. Matching the full product requires substantial further work in tracking, advanced effects/audio, templates, proxies, collaboration, and distribution.

## Downloads and development

Public source and macOS downloads are available in this repository’s Code and Releases tabs. Preview releases are explicitly labeled and not notarized by Apple.

`dev` is the local working branch; `main` publishes versioned downloads after the full CI suite passes. Release apps include Sparkle updates. Default local builds produce a separate **Cutline Dev** app with its own recovery, generated assets, preferences and API-key entry; its updater is disabled. See [release engineering](docs/RELEASING.md) and [installation](docs/INSTALL.md).

## Build locally

Requires macOS 14+, Swift 5.10+ and full Xcode for tests. The generated app runs without Xcode; local transcription and still-image conversion require the helper executables below.

```sh
./scripts/build-app.sh
open "dist/Cutline Dev.app"
```

The build selects `/Applications/Xcode.app` when available and targets the build machine's architecture. It produces an ad-hoc signed development app, not a notarized universal release. Open `Cutline.xcodeproj` in Xcode for the app and all test targets. `project.yml` generates this project; the Swift package remains available for command-line builds. Keep `DEVELOPER_DIR` consistent between Swift commands to avoid mixing compiler caches.

## Clip a stream (guided)

Cutline opens on **Home**. **Clip a stream** (⇧⌘N) has four steps:

1. **Video:** drop or choose one recording. MP4, MOV and OBS's default MKV all work. MKV/FLV/TS files are copied into an MP4 beside the original, with no re-encoding and every audio track kept. If an MP4 with the same name already exists (for example from OBS's own remux), Cutline uses it. Without `ffmpeg`, Cutline explains how to remux in OBS instead. Finding moments starts immediately in the background. If you saved a layout, **Use my saved layout** skips step 2.
2. **Layout:** drag the facecam and gameplay boxes on a real frame and watch the live 9:16 preview. Enter your Kick or Twitch username the first time, then drag the channel badge where you want it and set its size. Sound and game have sensible defaults and stay folded. **Change** under Sound shows each OBS track with a loudness graph, an eight-second listen and a plain-language role (Everything / My voice / Game / Not used). **Remember this layout** is on by default.
3. **Pick clips:** moments fill in as they are found. Each one plays as the finished short. **Keep** always works: if the hook is empty, Cutline uses the suggested hook (shown as the placeholder) in the same undo step. **Skip** passes. **Start/End −1s/+1s** buttons and drag handles trim. **Fewer ↔ More** changes how many moments appear instantly. **Add a moment** opens a scrubber for plays you remember. Detection settings (signals, thresholds, motion/HUD areas, OCR) live behind the sliders button. Keyboard shortcuts are listed under **Keyboard shortcuts**.
4. **Export:** one button. Shorts go to `~/Movies/Cutline/<recording> shorts/` (change the folder once and it is remembered). MP4s sit at the top of that folder. Editable `.cutline` projects and `analysis.json` go in **Editable projects**. With **Add captions** on, Cutline writes captions for the kept clips before exporting, so there is nothing extra to click.

**Edit this clip…** opens one moment in the editor without closing the session. **Back to my clips** returns with every decision, hook and trim. Clipping sessions autosave to `Recovery/clip-session.cutline`, so Home offers **Continue clipping** after a relaunch.

Measurements are cached in Application Support (`Analysis/`), keyed by file path, size, modification date and duration, so reopening a recording is instant. Layouts are stored in `scene-presets.json` with owner-only permissions. Saving the session (⌘S) keeps the recording reference, roles, framing, hooks, decisions and trims.

## Edit a video

**Output workflow:** mobile shorts (including YouTube Shorts) require 9:16 facecam/gameplay framing; only YouTube long-form uses 16:9. See the [output workflow contract](docs/OUTPUT_WORKFLOWS.md), including the mandatory 30% facecam / 2% branding strip / 68% gameplay layout and editable hooks.

Choose **Edit a video** on Home. The editor opens in **Simple** mode: Media and Captions, trimming with **Start here / End here**, volume, the hook, the layout and Export. **Advanced** (header toggle, View menu or Settings) adds Layers, AI, numeric trims, transform/speed/color, per-track gains and transcript gap cutting. If Export can't run yet, its tooltip and the alert say why in plain words.

1. **⌘I** or **Import videos** adds videos or still images. Click **Add** (or double-click) to put one on the timeline. Stills become five-second clips.
2. Seek with the timeline ruler. **Space** plays/pauses, **← / →** jumps five seconds, and **Option + ← / →** steps one frame at the selected project frame rate.
3. **⌘B** splits, **⌘D** duplicates, and **Delete** removes a selected clip. Drag clips to reorder. Drag a selected clip's edge, or use **Start here / End here**, to trim. Undo/redo is **⌘Z / ⇧⌘Z**.
4. Choose **Short · 9:16** or **YouTube · 16:9** under Format. Shorts default to 30 fps. Set a hook and check each recording's **Facecam & gameplay layout** before exporting.
5. In Advanced, **Source audio tracks** on a selected clip controls each embedded OBS track. If the source contains a combined mix alongside separate microphone/game tracks, mute the redundant tracks to avoid doubled audio.
6. In Advanced, **Layers** adds timed video overlays, music, and local text-to-speech voiceovers. Overlay/audio layers use absolute timeline positions; ordinary clip trim/reorder does not automatically relink them. Transcript cuts and AI keep-range edits do rebase all layers together.
7. **⌘S** saves an editable `.cutline` project. **⌘E** exports an MP4 snapshot, with progress/cancellation. Export uses a temporary sibling file and rejects source-media destinations.

## Channel badge

Every short carries a badge with your platform's logo and @username: Kick (green) or Twitch (purple), in a rounded container. Save both usernames in **Settings → Your channel** (a pasted channel address works), choose which badge shorts show, drag it anywhere on the 9:16 preview and set its size. It starts centred on the strip between facecam and gameplay. The badge is a setting on this Mac, never saved in project files.

## Appearance

Cutline uses a warm ivory/slate palette with a terracotta accent, in **Light**, **Dark** or **System** appearance. Switch with the sun/moon button in any header, **View → Appearance**, or Settings.

## AI agents (Claude Code, Codex)

Cutline includes a connector so Claude Code, Codex and other MCP agents can find moments, edit projects, write hooks and captions, and export, using Cutline's engine on this Mac. Connect it in **Settings → AI agents**; a project open in Cutline updates live as the agent edits it, and **⌘Z** undoes each change. See [AI agents](docs/AI_AGENTS.md).

## Local transcription and automatic captions

Captions work out of the box with macOS on-device speech recognition (audio never leaves the Mac; macOS asks for Speech Recognition permission the first time). For multilingual Whisper models and custom vocabulary, install the optional local engines once:

```sh
./scripts/setup-local-ai.sh
```

This script uses Homebrew to install `whisper-cpp` and `ffmpeg`. Homebrew must already be installed. The app finds the helpers under `/opt/homebrew/bin`, `/usr/local/bin`, or its bundle's `Contents/Helpers` directory. To bundle them, set `CUTLINE_HELPERS_DIR` to a folder of self-contained (statically linked) `ffmpeg`/`whisper-cli` builds when running `scripts/build-app.sh`; Homebrew-linked binaries are rejected. When Whisper is installed with a downloaded model, Cutline uses it; otherwise it uses macOS speech recognition.

In **Captions**, select the recording and its speech/microphone track. Download a model under **Speech model & language**, choose the language, optionally supply game/player vocabulary, then click **Make captions**. Models are SHA-256 verified and saved under `~/Library/Application Support/Cutline/Models` for release builds, or `Cutline Dev/Models` for local builds. Recognition runs locally after the initial download. No OpenRouter account is needed.

The multilingual Base model is about 148 MB; English Base and English Small are also available. Five-minute sections bound the transcription working set. Audio quality, model size, game noise and specialist names affect accuracy: review text and timings before export.

- Search captions, seek to a sentence, edit text/start/end, add/delete cues, and change size, color, position, case and background.
- Burn the same captions into preview/export or export SRT/WebVTT separately. Import existing SRT/WebVTT files.
- **Cut this range from video** removes that caption's time span across the timeline. **Edit video through the transcript → Find gaps** presents gaps between captions for review before cutting. These are gaps in recognized speech, not measured acoustic silence; nonverbal gameplay may be valuable.
- Caption timing follows source trims, splits, duplication, speed and reorder. Cuts can be undone.

## Optional OpenRouter AI

In **AI → Connect OpenRouter**, enter a key and click **Save to Keychain**. Keys stay in macOS Keychain and are never written to project files. These remote features use your OpenRouter credits.

**Editing assistant:** generate/import captions first. Ask for gaming highlights, title ideas, caption corrections or translation. The app sends your instruction and timestamped transcript text/IDs to OpenRouter and its provider, in bounded sections. It does not upload recordings. Suggestions display for review; apply caption edits or keep a highlight with undo. The default `google/gemini-2.5-flash` supports structured outputs. You can set another compatible model ID. This assistant understands transcript evidence, not visual gameplay events.

**Generate media:** choose Image or Video, load the current model catalog, choose supported options, and enter a prompt. Check the linked model pricing, then generate. Results stay under the current build’s Application Support folder (`Cutline/Generated` or `Cutline Dev/Generated`), with model/prompt/job/cost metadata. Add completed media to the library explicitly. Image results retain a PNG and become five-second video clips when added. Video jobs persist their remote IDs and offer **Resume job**. **Stop waiting** stops local polling; it does not promise to cancel a remote job or its charges. If submission is interrupted before an ID arrives, inspect OpenRouter activity before submitting again.

The public model catalogs were checked live. Paid assistant/image/video responses are covered with mocked transport tests; no live billable inference has been performed with a user key. These integrations need a live account acceptance pass before production use. See [AI architecture](docs/AI_ARCHITECTURE.md).

## Projects and recovery

Projects reference local source URLs; they do not embed recordings. Keep originals available, or use **Relink** in Media. Version 1 projects migrate to version 2. Transcripts, captions and edits persist in the project; credentials do not.

Edits produce a debounced recovery snapshot. **File → Recover Autosave** opens it; saving a project clears the snapshot. This is one recovery file, not version history. Generated assets and voiceovers live in Application Support: retain those files when moving or backing up a project.

## Verification and development

```sh
./scripts/test.sh          # Core tests and real-media checks
./scripts/test-ui.sh       # Automated native UI workflows
./scripts/test-all.sh      # All targets, coverage, and failure artifacts
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run CutlineVerify \
  /absolute/path/to/speech-fixture.mp4 /tmp/cutline-new-check --features --stills --transcribe
```

Use a fresh output directory. The fixture must contain at least 2.5 seconds of video and audio; `--transcribe` needs recognizable speech, the helpers, and the multilingual Base model. `--stills` consumes the image produced by `--features`.

See [the testing guide](docs/TESTING.md) for setup, isolation, CI, and result bundles, and [VERIFICATION.md](VERIFICATION.md) for measured results and limitations. Multi-hour gameplay, HDR/VFR media, Intel hardware, and macOS 14/15 have not received a full acceptance pass. This is an SDR renderer. Preview and output share one compositor.

- `Sources/CutlineCore`: projects, editing, captions, composition/rendering, local speech and AI transport.
- `Sources/Cutline`: native editor UI, document/lifecycle actions and background jobs.
- `Tests/CutlineCoreTests`: model, timing, persistence, speech extraction, rendering and provider tests.
- `Tests/CutlineAppTests`: hosted editor state, jobs, recovery and undo tests.
- `Tests/CutlineUITests`: native dialogs, editing workflows, AI/captions, layers and export.
- `Sources/CutlineVerify`: real-media integration checks.
- `docs/CAPCUT_PARITY.md`: feature and quality acceptance backlog.

No telemetry is implemented. Network access is used for model downloads, requested catalog loads, and explicitly invoked OpenRouter features. No automatic source uploads or publishing.

## License

[MIT](LICENSE). Helper executables, model weights and remote providers retain their own licenses/terms. They are not relicensed by this repository.

## Automatic clips without API costs

**Clip a stream** finds activity from local audio levels, sampled frame changes, optional game HUD OCR, and moments you mark. Review them one by one and batch-export separate videos and editable projects. No OpenRouter key or transcript is required. See [automatic clipping](docs/AUTOMATIC_CLIPS.md) for game profiles, calibration, thresholds and limitations.
