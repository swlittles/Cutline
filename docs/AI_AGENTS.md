# Use Cutline with Claude Code or Codex

Cutline ships a connector, `cutline-mcp`, inside the app (`Cutline.app/Contents/MacOS/cutline-mcp`). It is a [Model Context Protocol](https://modelcontextprotocol.io) server that AI agents launch themselves. With it, an agent can find moments in a stream, cut and arrange clips, write hooks and captions, look at frames and export videos, all with Cutline's own engine, on this Mac.

## Connect

Open **Cutline → Settings → AI agents** and click **Connect** next to Claude Code or Codex. If Cutline can't find the agent, click **Copy Command** and run it in Terminal:

```sh
claude mcp add --scope user cutline -- '/Applications/Cutline.app/Contents/MacOS/cutline-mcp'
codex mcp add cutline -- '/Applications/Cutline.app/Contents/MacOS/cutline-mcp'
```

Development builds register as `cutline-dev` and point at the dev app, so both can be connected at once. Start a new agent session afterwards. Other MCP clients can launch the same executable over stdio.

Then ask in plain words, for example:

- "Find the best moments in ~/Movies/2026-10-16 stream.mkv and make five shorts with punchy hooks."
- "Open ~/Movies/Cutline/edit.cutline, cut the first 10 seconds and add background music from ~/Music/beat.m4a at low volume."
- "Make a 60-second YouTube montage from these three clips and export it."

## What agents can do

| Tool | What it does |
| --- | --- |
| `get_setup` | Saved facecam layouts, the channel badge (Kick/Twitch usernames, which logo, placement), caption and MKV readiness, output folder. |
| `inspect_video` | Length, size, frame rate, audio tracks. OBS MKV/FLV/TS are copied to an MP4 beside the original without re-encoding. |
| `view_frame` | Images of a recording, or of a project as rendered (layout, hook, captions, branding), so the agent checks its work. |
| `find_moments` | The same highlight scan as **Clip a Stream**, with hook ideas. Rescans of a file are instant. |
| `export_shorts` | Finished 9:16 shorts plus editable projects, in a new folder, as in the guided flow. |
| `create_project`, `read_project`, `edit_project` | Any edit: add, trim, split, reorder, speed, volume, per-track audio, hooks, layout, cut/keep ranges, captions and style, music, quality, format. Changes apply all-or-nothing. |
| `transcribe` | Captions from speech with Whisper, when installed. Agents can also write captions directly. |
| `export_video` | An MP4 of a project. Never overwrites a source or an existing file unless told to. |
| `open_in_cutline` | Shows a project in the app. |
| `set_branding` | Kick and Twitch usernames, which badge shorts carry, and its position and size. Agents are told to ask first. |
| `wait_for_job`, `cancel_job` | Long scans and exports hand back a job id after about 40 seconds, inside agents' tool timeouts. |

## Working together

- A project open in Cutline follows the agent's edits as they're saved. The status line says **Updated by an AI agent**, and **⌘Z** takes each change back. If you have unsaved changes when the agent edits, Cutline asks which to keep.
- Simultaneous edits to one project apply in order; none is lost.
- Settings are shared with the app: saved layouts, the channel badge, the scan cache and the export folder.
- Everything stays local. The connector makes no network requests; the agent itself talks to its own provider, and sees what tools return (file paths, timings, captions and the frames it asks for).

## Limits

- Captions from speech need Whisper (`scripts/setup-local-ai.sh`). The app's built-in macOS speech recognition isn't available to the connector, because macOS grants speech permission to the app, not to a command-line process.
- HUD/OCR elimination detection needs the in-app calibration, so agents scan with audio and motion.
- Detection measures activity, not quality. Agents should look at frames before choosing.
