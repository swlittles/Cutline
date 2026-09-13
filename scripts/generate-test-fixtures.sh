#!/bin/bash
# Synthetic, non-copyrighted media. Regenerate only when intentionally updating fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=Tests/CutlineCoreTests/Fixtures
mkdir -p "$fixture_dir"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x180:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -f lavfi -i sine=frequency=880:sample_rate=48000 -t 5 -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart "$fixture_dir/gameplay.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=red:size=180x320:rate=30 -f lavfi -i sine=frequency=660:sample_rate=48000 -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart "$fixture_dir/facecam.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=220:sample_rate=48000 -t 5 -c:a aac "$fixture_dir/music.m4a"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/gameplay.mp4" -frames:v 1 "$fixture_dir/artwork.png"
cat > "$fixture_dir/captions.srt" <<'SRT'
1
00:00:00,200 --> 00:00:01,200
Push the castle!

2
00:00:03,000 --> 00:00:04,000
We won the match!
SRT
