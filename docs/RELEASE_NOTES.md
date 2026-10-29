# Cutline 0.5.1

Fixes finding moments on long stream recordings.

- **Finding moments no longer fails with "Cannot Open" at the very end of a scan.** Recordings often keep audio a fraction of a second past the last video frame. Cutline asked for a frame in that gap, so a scan of a multi-hour stream could fail on its final sample and lose its work. Frame sampling now stops at the last video frame.

Everything else is unchanged from 0.5.0.

Requires macOS 14 or later. macOS asks for Speech Recognition permission the first time you make captions. Converting MKV needs FFmpeg; without it, Cutline explains how to remux in OBS. Detection measures activity, not quality: review each moment before posting. Cutline remains an early development version without full CapCut parity.
