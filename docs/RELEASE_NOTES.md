# Cutline 0.7.0

Use the Claude API or OpenRouter for AI, set it all up in Settings, and add sound effects to your shorts.

## AI settings, with a choice of provider

- **Settings → AI** (⌘,) is the place for your API key. Settings now has three tabs: General, AI and Sounds. Choose where AI requests go: **OpenRouter**, or the **Claude API** from Anthropic. Paste the key, click **Save**, and it goes into your Keychain. Each provider keeps its own key.
- **Every AI step has its own model, per provider:** picking moments, titles and hooks, looking at frames, and the editor's assistant. Claude starts on `claude-opus-5-5`; `claude-sonnet-5-5` and `claude-haiku-5-5` cost less. OpenRouter keeps the models you already chose.
- Settings also has the switches for AI picks, titles and hooks, and looking at frames. Links in Pick clips and the AI panel open Settings straight to AI.
- Image and video generation still use OpenRouter.

## Sound effects

- **Settings → Sounds** keeps a library of sound effects. Import audio files, or a whole folder: subfolders such as `impact`, `whoosh`, `riser` and `pop` become categories, and an optional `sounds.json` gives each sound a display name. Listen to any sound before using it. Cutline doesn't come with sounds; bring your own.
- **Add sounds in Pick clips.** Pause the preview where a sound should land and choose **Add at 0:03** under the hook. The preview plays it straight away, and the exported short includes it. Click a sound to jump to it; ✕ removes it, and ⌘Z undoes.
- **Add sounds in the editor.** The new **Sounds** tab adds a sound at the playhead on the Music lane. Move it or change its volume in Layers.

Requires macOS 14 or later. AI picks cost OpenRouter or Anthropic credits and can be wrong: review each moment before posting. Whisper transcripts need whisper.cpp and a model (`scripts/setup-local-ai.sh`, or the model download in Cutline). Converting MKV needs FFmpeg. Cutline remains an early development version without full CapCut parity.
