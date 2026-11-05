# Cutline 0.7.1

Looking at frames now costs much less on the Claude API.

## Looking at frames starts on Claude Haiku

- With the **Claude API** as the provider, **Looking at frames** now starts on `claude-haiku-5-5`, about 40 times cheaper than `claude-opus-5-5`. It sends many still frames per recording, so it was the step where Opus cost the most. Picking moments, titles and hooks, and the editing assistant stay on `claude-opus-5-5`.
- If Cutline had `claude-opus-5-5` saved for Looking at frames, it moves to Haiku once. To keep Opus, choose it again in **Settings → AI**.
- A model you choose for a step now stays until you change it, and steps you never changed follow Cutline's defaults. Switching between OpenRouter and the Claude API no longer saves the defaults as if you had chosen them.

Requires macOS 14 or later. AI picks cost OpenRouter or Anthropic credits and can be wrong: review each moment before posting. Whisper transcripts need whisper.cpp and a model (`scripts/setup-local-ai.sh`, or the model download in Cutline). Converting MKV needs FFmpeg. Cutline remains an early development version without full CapCut parity.
