# CapCut parity tracker

Full CapCut parity is **not achieved**. This document is the acceptance checklist for the product, not a claim that matching labels or adding a chat panel creates parity.

Reference scope: CapCut Desktop on macOS, including paid editing and AI capabilities where applicable. Mobile/web-only features are tracked separately. CapCut changes features by platform, version, region, and account; the research baseline below is dated September 12, 2026. Proprietary CapCut assets, branding, model weights, and service access are not included in this open-source project. Equivalent workflows require original or properly licensed assets/services.

Sources: [Desktop editor](https://www.capcut.com/tools/desktop-video-editor), [Desktop AI features](https://www.capcut.com/tools/desktop-ai-power), [Current AI suite](https://www.capcut.com/resource/ai-editing-the-capcut-way). These cover the product's timeline/creative tools, captioning and reframing, transcript-based workflows, AI clipping, generation, and enhancement families. They are marketing documentation, not an exhaustive version-specific specification; each remaining family also needs hands-on acceptance against the target desktop release.

## Implemented in Cutline

“Implemented” means a working code path and UI exist. Verification coverage is documented separately in `VERIFICATION.md`; it does not imply every codec, recording length, hardware model, or subfeature is tested.

| ID | Capability | Current implementation | Remaining work in this family |
|---|---|---|---|
| E01 | Import, media library, thumbnails | Native video/image picker, file drop, thumbnails, source relinking, five-second still conversion | Proxy browser, image sequences, arbitrary still duration/alpha, comprehensive format coverage |
| E02 | Timeline editing | Split, trim fields and edge handles, duplicate, delete, reorder buttons and drag/drop, undo/redo | Ripple/slip/slide tools, snapping, linked/grouped selections, compound clips, J/K/L shuttle |
| E03 | Playback and seeking | Shared AVFoundation/Core Image renderer, ruler seek, frame stepping | Playback quality controls, proxy switching, dropped-frame reporting |
| E04 | Transform/reframe | Fit/fill, position, zoom, rotate, mirror | Interactive canvas handles, arbitrary crop boxes, tracked auto-reframe, layout presets |
| E05 | Keyframes | Source-anchored transform keyframes, linear/smooth interpolation | Curve graph editor, per-property easing, animation presets, opacity/effects keyframes |
| E06 | Speed | Constant 0.25–4× UI, model supports 0.1–8×, audio time-pitch processing | Speed ramps, optical-flow slow motion, reverse, freeze frame |
| E07 | Color | Brightness, contrast, saturation, B&W/vivid presets | Wheels, curves, LUTs, scopes, exposure/WB, HDR color management |
| E08 | Fades/transitions | Per-clip fades to/from black | Cross dissolves, transition library, transition handles and previews |
| E09 | Video layers | Multiple timed video overlays with position, size, opacity | Full multitrack drag editing, masks, blend modes, chroma key, nesting |
| E10 | Audio | All embedded tracks, independent per-track gains, clip master gain, separate music/voiceover layers, audio-layer fades | Waveforms, meters, EQ, compressor, limiter, ducking, beat detection, noise/voice isolation, recording |
| E11 | Text-to-speech | Local macOS speech voice generates an audio layer | Voice browser, expressive voices, pronunciation dictionary, AI dubbing/voice conversion |
| E12 | Captions | Local whisper.cpp ASR, microphone-track selection, language selection, vocabulary hints, editable text/timing, SRT/VTT import/export, burned-in captions | Word highlighting, speaker labels, karaoke/animated templates, rich text, automatic line-break controls, batch language tracks |
| E13 | Transcript navigation | Caption search/seek, source-anchored timing, caption-range ripple cuts, reviewed speech-gap cuts across all tracks | Word-level selections, filler/repetition cleanup, acoustic silence detection |
| E14 | AI clipping | OpenRouter transcript-based ranked highlights, reasons, preview and undoable keep-range action | Visual/audio-event understanding, batch independent project/export creation, clip-quality scoring benchmark |
| E15 | AI writing/translation | OpenRouter caption correction/translation proposals and title ideas | Script/storyboard editing, translation glossary, localization QA, voice synchronization |
| E16 | Highlight markers | Source-anchored markers, split migration, seek/remove | Marker naming UI, colors, ranges, export, stream hotkey ingestion |
| E17 | Projects and recovery | Versioned local project files, v1 migration, atomic saves, debounced recovery file, explicit recovery command | Multiple recovery versions, automatic recovery prompt, portable media packages, media bookmarks |
| E18 | Export | MP4, 720p/1080p/4K, 24/25/30/50/60 fps, three aspect ratios, progress/cancel, safe destination replacement | Codec/bitrate controls, HDR, transparency, audio-only, queue, presets, batch and range exports |
| E20 | Generative media | OpenRouter image/video catalog discovery, supported option pickers, prompt-only submission, image normalization, durable video job IDs/resume, local assets/provenance/cost, library import | Live billable end-to-end validation, reference inputs, music generation, quality controls, remote cancellation where supported |
| E19 | AI credentials and transport | Keychain storage; fixed HTTPS OpenRouter endpoint; schema-constrained, locally validated suggestions; cancellation; long-transcript batching | Live account validation and cost reporting, provider/model browser, retry policy, streaming UX |

## Not yet implemented

| ID | Capability | Acceptance requirement |
|---|---|---|
| P01 | General title/graphic layers | Independent text, fonts, outline/shadow, arbitrary timing/position, stickers/images and animation must preview and export identically. Captions alone do not satisfy this. |
| P02 | Transition/effect catalogs | Original/licensed presets with previews, editable duration/parameters, stable rendering, and undo. |
| P03 | Chroma key and masks | Adjustable color key with spill suppression; geometric/freehand masks, feathering, inversion and animation. |
| P04 | Background/object removal | Local or explicitly configured model; quality benchmark on facecam and difficult edges; cancellation and consistent export. |
| P05 | Motion tracking/auto-reframe | Track selected subjects, expose corrections/keyframes, maintain gameplay and facecam visibility across aspect ratios. |
| P06 | Stabilization | Analyze real footage, show crop/strength tradeoff, cache results, preserve audio and render reliably. |
| P07 | Advanced audio restoration | Noise reduction, voice isolation/enhancement, normalization, ducking and effects with audible before/after and mix headroom tests. |
| P08 | Advanced silence/filler cuts | Caption-range and reviewed speech-gap cuts are implemented (E13). Still needed: acoustic silence/VAD, word timing for fillers/repetitions, and false-positive benchmarks on game audio. |
| P09 | Smart media search | Search actual visual/audio content, not only filenames or caption text; provide source/timestamp evidence. |
| P10 | Automatic scene and beat detection | Timestamped source markers with adjustable sensitivity and reproducible tests. |
| P11 | Advanced generation and validation | E20 implements prompt-to-image/video plumbing. Still needed: a live account acceptance pass, reference-image/video inputs, music generation, provider-quality comparison and production job recovery. |
| P12 | Script-to-video/story maker | Editable script, shot plan, media generation/selection, voiceover, captions and assembled timeline with user review. |
| P13 | Avatars/lipsync/AI dubbing | Separate compatible models/services, language and voice controls, provenance and synchronization QA. |
| P14 | Upscale/relight/retouch | Genuine image/video processing models, temporal consistency and quality/performance validation. A saturation preset is not an equivalent. |
| P15 | Reusable templates | Save/apply user-created templates, fonts/media dependency handling, duration adaptation, licensing metadata. |
| P16 | Recording/capture | Screen, camera and microphone input with native permissions, sync and dropped-frame handling. |
| P17 | Cloud collaboration/mobile handoff | Optional authenticated storage, project conflict/version management, scoped sharing, recovery and client support. |
| P18 | Direct publishing | Authorized platform integrations, destination preview, export/upload state, retry and account handling. |
| P19 | Asset libraries | Searchable, licensed fonts/music/effects/stickers; metadata, attribution and license visibility. |
| P20 | Distribution and accessibility | Notarized/universal builds, dependency packaging, keyboard/VoiceOver coverage, localization, updates and crash diagnostics. |
| P21 | Long-stream reliability | Multi-hour/4K60/VFR/OBS multitrack test corpus; proxy/cache jobs; memory/seek/export benchmarks; cancellation and crash-recovery tests. |

## Implementation order

1. Finish acceptance tests on local captioning, layered rendering and optional OpenRouter proposals, including a live key-configured provider test.
2. Harden streamer editing: proxies, actual waveforms, acoustic silence detection, crop/facecam layouts, transition and title layers.
3. Add tracking, masks/background removal, stabilization, advanced audio and color with appropriate local models/processors.
4. Expand and validate generative-service adapters, reusable templates/assets, publishing/collaboration and distribution.
5. Run a version-specific end-to-end CapCut comparison on the same recordings. Close a parity item only when its workflow, output quality, interaction and failure handling meet the acceptance criteria.

No percentage-complete claim is made: small features and model-backed production workflows are not equal units of work.
