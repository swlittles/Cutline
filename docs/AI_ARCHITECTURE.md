# Local transcription and optional AI editing

## Speech and captions

`LocalTranscription` invokes **whisper.cpp** and **FFmpeg** with argument arrays, without a shell. Audio is decoded to a temporary 16 kHz mono WAV from the chosen source audio track. Recordings are processed in five-minute sections, avoiding an unbounded whole-stream WAV/model input. Temporary files are removed on completion/failure/cancellation. Processes use disk-backed logs so output cannot deadlock an unread pipe; cancellation terminates the child process.

Models reside in `~/Library/Application Support/Cutline/Models`. The app offers multilingual Base, English Base, and English Small downloads from the whisper.cpp model repository. Downloads are checked against pinned SHA-256 values before installation. The initial download requires internet; recognition then runs locally, with Metal acceleration when provided by the installed whisper.cpp build. Accuracy depends on the model, speech, language and microphone/game balance. Word-level karaoke and diarization are not implemented.

Transcripts store source-media IDs and source timestamps. Editable caption cues attach to a timeline clip and source time range. Projection into timeline time accounts for trimming and speed. Split/duplicate copy only relevant cues; deletion removes dependent cues. The same custom `AVVideoCompositing` renderer draws caption bitmaps into both preview and exported video. SRT/VTT export uses the projected timeline times.

Reference: [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [model repository](https://huggingface.co/ggerganov/whisper.cpp).

## OpenRouter

The assistant is optional. The app never needs a remote key to transcribe or export. The user saves their OpenRouter key in macOS Keychain and configures a structured-output-capable model. The initial default `google/gemini-2.5-flash` was present in OpenRouter's public model catalog with structured-output support when checked on September 12, 2026.

Requests go to `https://openrouter.ai/api/v1/chat/completions`. Only the explicit editing instruction, timeline duration, and timestamped caption text/IDs are included. Source files, filesystem paths, the project document, and raw audio/video are not uploaded. The Generate button explains the remote destination, credit use, and number of transcript sections. Long transcripts are split into bounded text requests; highlights are combined and overlapping suggestions deduplicated.

The response schema permits a summary, ranked highlight ranges, title ideas, and caption-text edits. There is no arbitrary code execution or filesystem tool interface. All ranges and caption IDs are validated locally. The UI shows the proposal and applies it only on user action. A project-snapshot check rejects stale suggestions. Apply creates an undo entry; keeping a highlight also clips/rebases audio and overlay layers. Recorded speech is identified as untrusted data in the system instructions.

HTTP authentication, credit, rate-limit, empty-response and malformed-response failures surface as actionable errors. Cancellation cancels the URLSession task. Chat has no automatic retry, provider selection UI, or cost accounting. Image/video generation uses the separate adapters below.

References: [OpenRouter chat API](https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request), [structured outputs](https://openrouter.ai/docs/guides/features/structured-outputs).

## Generated assets

`MediaGeneration` uses OpenRouter's dedicated `/images` and `/videos` APIs, with public model catalogs and capability validation. It submits only the user-entered prompt and chosen generation options. Image output is decoded through ImageIO, rejects unsupported/vector formats, enforces dimension limits, applies image orientation, and normalizes to PNG. Still import creates a five-second H.264 clip with FFmpeg using argument arrays.

Video submission persists its remote job ID before polling every 30 seconds. Poll/download URLs are constructed on a fixed OpenRouter HTTPS host from validated job IDs; the provider's returned URL is not trusted with credentials. Downloaded video must pass AVFoundation inspection before library use. Jobs and completed assets survive project switches and app restarts. Stopping a local task does not promise remote cancellation. No automatic submission retry can accidentally create another paid job; ambiguous submissions are shown for activity review.

Metadata includes a UUID, model, prompt, creation time, remote job ID, status, optional reported cost, and fixed local asset filename. It never contains the key. Assets are imported into a project only by explicit action. Catalog and mocked transport tests have passed; a live paid generation has not been run.

References: [OpenRouter image API](https://openrouter.ai/docs/guides/overview/multimodal/image-generation), [video API](https://openrouter.ai/docs/guides/overview/multimodal/video-generation).

## Transcript cuts

Caption-range deletion and reviewed gaps between recognized captions feed a shared range-edit operation. Retained ranges are applied to every clip, caption, marker, overlay and added audio layer; source times account for speed. Repeated fragments receive distinct IDs. Overlapping cuts merge, and a cut that removes the entire timeline is rejected without mutation. Gap detection keeps 200 ms around recognized speech; it is not acoustic silence detection. The UI asks the editor to review gaps, since gameplay often matters when nobody speaks.

## Rendering and project lifecycle

`CutlineCore` owns persisted data, validation, caption projection, media composition, a serial Core Image compositor, transcription and AI transport. SwiftUI views delegate edits to `EditorStore`, which creates undo snapshots and rebuilds the preview asynchronously. Video overlays and audio layers use explicit timeline positions. Primary clip/caption/marker timing uses source anchors. Overlay/audio positions are adjusted when applying a keep-range edit, but ordinary ripple edits do not yet automatically shift these absolute-position layers.

The renderer supports transform keyframes, simple color adjustments, fades and timed video overlays; it uses an SDR BGRA render path. Export options do not constitute HDR support. Caption bitmaps have a bounded cache. Project caption projection is cached for UI playback rather than recomputing the whole transcript on each playhead update.

Version 2 projects load version 1 with defaults. New saves use version 2 so older builds reject unknown feature data rather than silently dropping it. Recovery autosaves are separate from the user's project/source files. The first iteration stores one recovery snapshot, not a version history or portable media archive.
