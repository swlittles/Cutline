# Output workflows

Cutline separates **Mobile Short (9:16)** from **YouTube Video (16:9)**. New projects and automatic clips use Mobile Short. The guided **Clip a stream** flow always produces Mobile Shorts; in the editor, the Inspector's **Format** control selects the workflow explicitly; existing unclassified projects retain their framing and require a choice before export. Version-3 documents persist workflow, hooks and per-recording crops.

## Mobile shorts

- Top 30%: cropped facecam, with per-recording source calibration.
- Next 2%: a full-width black divider. At 1080 × 1920 this is 38 pixels after rounding.
- A mandatory **channel badge**: the Kick or Twitch logo and @username in a rounded container (platform-colour 6-unit border, near-black body, white bold handle), 76 pixels tall at 1080 × 1920 and as wide as the name. Choose the platform, drag it anywhere and set its size (0.5–2.5×) in Settings or the Layout step. It starts centred on the divider and always stays inside the frame. No creator identity is shipped in the app.
- Remaining 68%: gameplay, cropped to fill or fitted to preserve the chosen region.
- An editable hook is required for every clip (1–80 characters on one line). It appears below the divider for the first three seconds, or the entire clip if shorter. Timeline clips can override the shared hook.

Check the camera and gameplay crops for every recording before exporting. Crop edits clear confirmation. Generic initial crop coordinates are placeholders, not an OBS scene preset. Mixed-scene recordings still need manual review.

Preview, automatic candidate preview, timeline export and batch export use the same native compositor. The badge renders after effects, captions and fades, and the hook draws over it. Export fails if required hooks, checked crops or the chosen badge's username are missing. Adding an automatic candidate selects Mobile Short as an undoable edit. A landscape source or previous YouTube edit cannot change automatic clips to landscape.

## Local creator settings

Branding is stored in `creator-profile.json` under the app's local Application Support directory, with owner-only file permissions. Dev and release builds have separate directories. Creator settings never enter project JSON, source code or release configuration. The profile holds the Kick and Twitch usernames, the chosen badge and its placement. Settings can save without a username, but short exports require one for the chosen badge. API credentials use Keychain.

Project documents and generated scan reports are user content: they retain media references, edits, hooks and the scan settings used. Review those documents before sharing. Exported videos intentionally include the configured branding. Opening a project on another Mac uses that Mac's creator profile.

## YouTube and local processing

YouTube Video preserves a 16:9 canvas without the short-specific stack, branding or hook requirements. Audio analysis and export tracks are independently selectable; choose the audience mix for output and an isolated track for analysis when available. Do not combine a full audience mix with a duplicate microphone track.

Automatic clipping uses local audio measurements, frame sampling and a local transcript without paid API calls. Remote AI picks are opt-in and send only transcript text and signal timings. Automatic camera detection, loudness normalization and word-level caption styling remain incomplete. Review selected ranges and tighten setup/payoff before posting.
