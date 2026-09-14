# Output workflows

Cutline separates **Mobile Short (9:16)** from **YouTube Video (16:9)**. New projects and automatic clips use Mobile Short. The Inspector selects the workflow explicitly; existing unclassified projects retain their framing and require a choice before export. Version-3 documents persist workflow, hooks and per-recording crops.

## Mobile shorts

- Top 30%: cropped facecam, with per-recording source calibration.
- Next 2%: mandatory full-width black branding strip. At 1080 × 1920 this is 38 pixels after rounding. Configure your text and optional Kick mark in Settings. No creator identity is shipped in the app.
- Remaining 68%: gameplay, cropped to fill or fitted to preserve the chosen region.
- An editable hook is required for every clip (1–80 characters on one line). It appears below the strip for the first three seconds, or the entire clip if shorter. Timeline clips can override the shared hook.

Check the camera and gameplay crops for every recording before exporting. Crop edits clear confirmation. Generic initial crop coordinates are placeholders, not an OBS scene preset. Mixed-scene recordings still need manual review.

Preview, automatic candidate preview, timeline export and batch export use the same native compositor. The strip and hook render after effects, captions and fades. Export fails if required hooks, checked crops or locally configured branding are missing. Adding an automatic candidate selects Mobile Short as an undoable edit. A landscape source or previous YouTube edit cannot change automatic clips to landscape.

## Local creator settings

Branding is stored in `creator-profile.json` under the app's local Application Support directory, with owner-only file permissions. Dev and release builds have separate directories. Creator settings never enter project JSON, source code or release configuration. Settings can save an empty draft, but short exports require nonempty branding. Player aliases are user-entered and saved in the local per-game scan profiles. API credentials use Keychain.

Project documents and generated scan reports are user content: they retain media references, edits, hooks and the scan settings used. Review those documents before sharing. Exported videos intentionally include the configured branding. Opening a project on another Mac uses that Mac's creator profile.

## YouTube and local processing

YouTube Video preserves a 16:9 canvas without the short-specific stack, branding or hook requirements. Audio analysis and export tracks are independently selectable; choose the audience mix for output and an isolated track for analysis when available. Do not combine a full audience mix with a duplicate microphone track.

Automatic clipping uses local audio measurements, frame sampling and optional macOS OCR without paid API calls. Captions use separately installed local transcription tools. Remote AI is separately opt-in. Automatic camera detection, loudness normalization and word-level caption styling remain incomplete. Review selected ranges and tighten setup/payoff before posting.
