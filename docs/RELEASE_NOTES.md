# Cutline 0.6.0

Cutline now hears what you say on stream and can ask AI to pick the moments worth clipping.

## Review clips without leaving Pick clips

- **Play each moment in place.** A play button and scrubber sit under the preview, so you can watch a moment as the finished short without opening **Edit this clip…**.
- **Every moment says why it was picked.** Each row shows the AI's reason or a quote of what you said, instead of the same "Big reaction during action" line on every row. **Why this moment?** shows the AI's reason, the measured evidence, notes about what was on screen, and what was said.

## Transcripts

- **Cutline transcribes the whole stream on this Mac** as soon as you choose a recording. It uses whisper.cpp with voice activity detection when Whisper is installed, otherwise macOS speech recognition. The audio never leaves the Mac.
- Whisper's habit of repeating one line through silence is filtered out. The transcript is saved, so reopening the same recording doesn't transcribe it again.
- Captions for kept clips are cut from the stream transcript, so exporting doesn't need another speech pass.

## AI picks moments, titles and hooks (optional)

Connect an OpenRouter key under the sliders button in **Pick clips**, or in the AI panel. There are three steps, and each one has its own model:

- **Picking moments.** AI reads the transcript, along with the measured loudness and screen-activity peaks and any moments you marked, then returns clips with a score and a reason. Long streams are read in overlapping sections. Weak picks are dropped and overlapping picks are merged. AI picks lead the list, and measured moments fill the rest.
- **Titles and hooks** (on by default). A second pass writes the title and hook for each pick from just that clip, plus alternative hooks in the Ideas menu.
- **Look at frames** (off by default). Sends small still frames from the strongest moments, plus a sparse sweep of the stream, to a vision model, so picking knows what was on screen. You choose how many frames to send.

With a key connected, transcript text goes to OpenRouter. Still frames go too only when **Look at frames** is on, and audio and video files never do. The status bar always shows which of these applies. Results are saved per recording, so reopening a stream doesn't spend credits again; **Ask AI again** does. Without a key, Cutline works as before.

## Removed

- **Game HUD text reading (OCR) and game presets.** The transcript and AI steps work for any game or stream without per-game setup. Saved layouts keep their motion area.

## Development builds

- Local builds are called **Cutline Dev**, with a DEV badge on the icon and a DEV label beside the name. They keep their own settings, data and key. The status bar and Settings show which build and version you're running.

Requires macOS 14 or later. macOS asks for Speech Recognition permission the first time it transcribes. Whisper transcripts need whisper.cpp and a model (`scripts/setup-local-ai.sh`, or the model download in Cutline); the voice activity model downloads automatically. Converting MKV needs FFmpeg; without it, Cutline explains how to remux in OBS. AI picks cost OpenRouter credits and can be wrong: review each moment before posting. Cutline remains an early development version without full CapCut parity.
