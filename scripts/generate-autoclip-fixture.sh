#!/bin/bash
# Known signal timing; synthetic pixels and PCM, no game assets or model-generated labels.
set -euo pipefail
cd "$(dirname "$0")/.."
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "nullsrc=size=320x180:rate=16:duration=12,geq=lum='if(between(T,5,7)*lt(X,W/2),if(mod(floor(T*2),2),235,16),16)':cb=128:cr=128" \
  -f lavfi -i "aevalsrc='sin(2*PI*440*t)*if(between(t,5,7),0.5,0.003)':s=16000:d=12" \
  -f lavfi -i "aevalsrc=sin(2*PI*880*t)*0.003:s=16000:d=12" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart \
  Tests/CutlineCoreTests/Fixtures/autoclip.mp4
