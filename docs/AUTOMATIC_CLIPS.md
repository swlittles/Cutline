# Local automatic clipping

**Output:** every automatic clip is a [Mobile Short](OUTPUT_WORKFLOWS.md): 9:16 with 30% facecam, a 2% black divider, a mandatory Kick or Twitch channel badge (configured locally in Settings), and 68% gameplay. Every kept clip needs a hook (Keep fills in the suggested hook when the field is empty), and the recording's crops are confirmed in the **Layout** step. AI picks are optional; see [What was said](#what-was-said).

Start from **Home → Clip a stream** (or **Find moments for shorts** on a recording in the editor's media library). Choosing a recording starts measuring it at once. The scan does not require a timeline, captions, an OpenRouter key, or a network connection. It analyzes the source recording rather than the edited timeline.

## Measure once, evaluate instantly

Scanning is split into two parts. The slow part is a **measurement** pass: one AVAssetReader pass decodes *every* embedded audio track into quarter-second loudness, and, running at the same time, video is sampled for motion . The fast part is **evaluation**: the rules below run over the retained measurements. Changing sensitivity, thresholds, lead-in/payoff, encounter gap, clip caps, detection track or the "both signals" rule only re-evaluates, which takes milliseconds to a fraction of a second. Only a new motion region or sample rate samples the video again, and audio is never decoded twice. Measurements are cached in `Analysis/` under Application Support (owner-only, newest 24 kept) and invalidated when the file's path, size, modification date or duration changes.

## Audio roles

In **Layout → Sound → Change**, each embedded track gets a role, shown as **Everything** (full mix), **My voice** (mic), **Game** or **Not used**. Each track shows a loudness graph and has an eight-second listen button that starts near its loudest point. Roles decide:

- **Detection:** the first Mic track, otherwise Game, otherwise the Full mix.
- **Export audio:** the Full mix alone if there is one (so isolated tracks are never doubled); otherwise Mic and Game tracks mixed together.
- **Captions:** the first Mic track, otherwise the Full mix.

The initial roles are a guess from track titles written by the recorder, falling back to the common OBS order (mix, mic, game). Always confirm them.

## Review and export

**Review** plays each moment through the real compositor, with framing, channel badge, hook and captions. Keep (**K**; an empty hook gets the suggested one), skip (**X**), undo (**⌘Z**), and change lead-in/payoff with **[ ]** or the trim handles (1 s minimum, 180 s maximum). Decisions, trims, hooks and hand-marked moments are stored in the project under `clipReview`, so a saved session reopens where it stopped. **Why this moment?** lists the evidence.

**Export** makes a new folder, `<recording> shorts` in the chosen export folder (default `~/Movies/Cutline`), with one MP4 per kept clip (named after its hook) and an **Editable projects** subfolder holding each `.cutline` project plus `analysis.json` with the scan settings, measurements, source timestamps and selection evidence. Exports use the current resolution/frame-rate settings. Optional captions come from the stream transcript when there is one. Otherwise Cutline transcribes **only the kept ranges** on this Mac, with Whisper when it is installed with a model and macOS on-device speech recognition otherwise. Export writes any missing captions automatically; **Preview captions now** writes them first so you can fix the wording; trimming a clip afterwards discards its captions so they never drift. Editable projects reference the original recording, so retain that file. Cancellation or failure removes the unfinished batch; existing files are never overwritten.

## Signals and controls

- **Audio bursts:** decode the selected embedded track to PCM, measure quarter-second RMS energy across its channels, and compare it to a local 30-second median. The default trigger is 8 dB above the median and at least −35 dBFS. Steady loud sound and very quiet noise do not qualify merely by being relatively loud. Select an isolated mic for reaction activity or isolated game audio for combat. The detector does not recognize laughter, speech, gunshots or emotion.
- **Sustained frame changes:** sample the displayed source frame at 2 fps by default, crop the configured Motion region and compare small grayscale images. Two adjacent changes above the threshold are needed; isolated flashes and large full-frame cuts are excluded. Exclude facecam/chat/animated overlays with **Advanced → Motion area** (drag the box). Camera movement, menus, flashing effects and loading animations can still trigger it. Sparse sampling can miss brief events.
- **Require audio and motion together:** enabled by default when both detectors are active. Only events within two seconds of each other qualify. Disable this for quieter visual activity or mic reactions without gameplay changes, or use one detector independently.
- **Markers:** moments you add with **Pick clips → Add a moment**, and existing timeline markers on the selected source, always create candidates.
- **Sensitivity:** the single slider maps to audio rise (12 → 8 → 5 dB), audio floor (−30 → −35 → −45 dBFS) and frame-change threshold (0.10 → 0.07 → 0.04). The midpoint is exactly the default.

Audio peaks and visual activity are measurements, not a clip-worthiness model. The score is a ranking of measured evidence, not a confidence percentage or a guarantee that a play is interesting. No candidates is a valid result.

## What was said

Once the layout is confirmed, Cutline transcribes the whole stream on this Mac from the **Captions** track (see Audio roles). It uses Whisper (`whisper-cli`) when it is installed with a model, and macOS on-device speech recognition otherwise. Install Whisper with `scripts/setup-local-ai.sh`, then download a model from **Pick clips → settings** or the Captions panel. With the base model, a three-hour stream takes about ten minutes on Apple silicon. The transcript is cached per recording and track in `Transcripts/` under Application Support (owner-only), so it is made once. Turn it off with **Transcribe the stream on this Mac**.

The transcript is used three ways:

- **Each moment shows what was said** in the list and under **Why this moment?**, so measured moments are no longer described only as "Big reaction".
- **Captions for kept clips** are cut from it instead of transcribing again.
- **AI picks**, when OpenRouter is connected.

### AI picks (optional, OpenRouter)

With **Let AI pick moments from the transcript** on and an OpenRouter key saved (Keychain), up to three AI steps run once the transcript and scan are ready. Each step has its own model ID in **Pick clips → settings**, separate from the editor's AI panel. Every model must support structured output.

1. **Look at frames** (off by default). Small JPEG stills (768 px wide) go to a vision model, six per request and four requests at a time. The frames come from marked moments, just before "clip it", the strongest audio and motion peaks (at least 6 s apart), and an even sweep that uses a quarter of the budget. The default budget is 120 frames; the range is 20–400. For each frame, the model says what kind of activity it is (gameplay, menu, loading, chatting or other), gives a one-line description, and rates intensity. These notes join the timeline, are cached per recording, and appear under **Why this moment?**. This is the only step that uploads images. If it fails, picking carries on from the transcript and says frames were skipped.
2. **Picking moments.** The timeline goes to the picking model. It holds the transcript joined into utterances, plus the strongest audio bursts and screen-activity peaks, your marked moments, "clip it" voice markers, and any frame notes. Streams over 90 minutes are sent in 40-minute sections that overlap by 2 minutes, three at a time. The model rates each clip 0–10 on hook, payoff, arousal, pacing, clarity, novelty, relevance to strangers and commentability. Cutline combines these into the 0–100 score: hook and payoff count most, there is a small bonus for 18–32 second clips, and anything under 6/10 is dropped. Overlapping picks collapse to the better one, up to 30.
3. **Titles and hooks** (on by default). A second model rewrites each pick's title and hook from just that clip's part of the timeline, and suggests three alternative hooks for the **Ideas** menu. Clips with almost nothing said and no frame notes are skipped. If a reply can't be read, that clip keeps the picker's draft.

Picks lead the list, and measured moments fill in around them. Picks are cached with the transcript. **Ask again** reruns every step and keeps your decisions on moments that already exist. A section that fails three times is skipped; a rejected key, missing credits or an unsupported model stops the run. The status bar says what leaves the Mac: transcript text, plus still frames when **Look at frames** is on. Audio is never uploaded.

AI suggestions can be wrong, so review every clip.

## Grouping

Nearby events form encounters with configurable setup/payoff, maximum duration and clip count. Overlapping padded candidates are suppressed in score order; the output is chronological. Long or overlapping activity can therefore be omitted.

## Validation and limits

Synthetic tests cover relative/absolute loudness thresholds, selected-track isolation, steady sound/silence, frame differences, cuts/flashes, signal coincidence, padding, caps, source changes, cancellation, batch cleanup and playable exports. They also cover the AI timeline, sectioning, response parsing, scoring and merging, against a stubbed OpenRouter. Native UI tests exercise scanning, preview, selection, timeline append/undo, region editing, invalid settings, quiet tracks, and native folder export. These tests are not a precision/recall benchmark on real gameplay.

Scans retain numeric measurements and the current frame rather than dumping every frame to disk. Audio decoding is sequential; frame sampling uses timestamped AVFoundation image generation. Scans support local recordings up to 24 hours but multi-hour 4K/OBS performance has not been benchmarked. No model download, FFmpeg installation, or transcription is required to find moments by activity. Decoder errors are shown instead of silently returning partial coverage. MP4/MOV inputs supported by AVFoundation are the intended sources; unsupported containers/codecs must be remuxed or converted first.

Before trusting automatic selection, label a set of your own recordings with expected moments and clip boundaries, including menus, quiet stretches and busy overlays. Review false positives, missed moments and whether setup/payoff remains complete. No accuracy percentage is claimed.
