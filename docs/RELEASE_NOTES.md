# Cutline 0.7.2

Titles and hooks now cost less on the Claude API.

## Titles and hooks start on Claude Sonnet

- With the **Claude API** as the provider, **Titles and hooks** now start on `claude-sonnet-5-5`, half the price of `claude-opus-5-5`. Picking moments and the editing assistant stay on `claude-opus-5-5`, and Looking at frames stays on `claude-haiku-5-5`.
- If Cutline had `claude-opus-5-5` saved for Titles and hooks, it moves to Sonnet once. To keep Opus, choose it again in **Settings → AI**.

Requires macOS 14 or later. AI picks cost OpenRouter or Anthropic credits and can be wrong: review each moment before posting. Whisper transcripts need whisper.cpp and a model (`scripts/setup-local-ai.sh`, or the model download in Cutline). Converting MKV needs FFmpeg. Cutline remains an early development version without full CapCut parity.
