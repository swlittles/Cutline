# Cutline 0.5.0

A guided, four-step path from a stream recording to finished shorts, a simpler editor, and a new look in light and dark.

## Clip a stream in four steps

- **Video → Layout → Pick clips → Export.** Cutline starts finding moments the moment you choose a recording, and the list fills in while you check the layout.
- **OBS MKV recordings work directly.** MKV, FLV and TS files are copied into an MP4 beside the original without re-encoding, keeping every audio track. An existing MP4 of the same name (for example from OBS's own remux) is reused.
- **Layout once, then skip it.** Drag the facecam and gameplay boxes on a real frame with a live 9:16 preview. Sound and game have sensible defaults; plain-language track roles (Everything / My voice / Game / Not used) are one click away. Layouts are remembered by default, so the next stream goes straight to picking clips.
- **Pick clips with the finished short playing.** Keep always works: an empty hook gets the suggested one, in the same undo step. Labelled Start/End buttons and drag handles trim; a Fewer ↔ More slider changes how many moments appear instantly; **Add a moment** marks plays you remember. Detection settings stay out of the way behind one button.
- **One-button export.** Shorts save to `~/Movies/Cutline/<stream> shorts/` without a file dialog. Editable projects and the scan report sit in an **Editable projects** subfolder.
- **Captions without setup.** Turn on captions and Cutline writes them for the kept clips when you export, using macOS on-device speech recognition. Whisper is used instead when it is installed with a model. Audio never leaves the Mac.
- **Edit a clip without losing your picks.** **Edit this clip…** opens one moment in the editor; **Back to my clips** returns with every decision, hook and trim. Sessions autosave, and Home offers to continue after a relaunch.

## A simpler editor

- **Simple** mode shows what most edits need: import, Add to timeline, Start here / End here trimming, volume, captions, hook, layout and Export. **Advanced** adds layers, AI, numeric trims, transform/speed/color and per-track audio.
- Clear empty states, plain-language messages, and Export explains what is missing.

## Mobile shorts

- New projects default to **Short · 9:16**; **YouTube · 16:9** is an explicit Format choice.
- Every short uses 30% facecam, a 2% black strip with locally configured branding and an optional Kick mark, and 68% gameplay. Each clip has a hook for its first three seconds; timeline clips can override the shared hook.
- Older projects keep their framing on open and require a format choice before export. Version-3 project files preserve hooks and crops and are rejected by older apps instead of silently losing the layout.
- Creator branding has no personal defaults and is saved only on this Mac.

## Look and feel

- A warm ivory/slate palette with a terracotta accent, consistent across every screen, in **Light**, **Dark** or **System** appearance (header button, View → Appearance, or Settings).
- Cutline has an app icon in the Dock, Finder and Spotlight.

Requires macOS 14 or later. macOS asks for Speech Recognition permission the first time you make captions. Converting MKV needs FFmpeg; without it, Cutline explains how to remux in OBS. Crop calibration is per layout; mixed OBS scenes still need checking. Detection measures activity, not quality: review each moment before posting. Cutline remains an early development version without full CapCut parity.
