#!/bin/sh
# Build and check in a Linux container: tests, decoding all data, the full
# playthrough and a viewer shot (SDL without a window). The game is mounted read-only.
# scripts/linux/check.sh <game dir>
set -e
GAME=${1:?game dir}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
docker build -q -t opengorky-linux "$ROOT/scripts/linux" >/dev/null
docker run --rm -v "$ROOT":/src:ro -v "$GAME":/game:ro -v opengorky-linux-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global opengorky-linux sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    zig build test
    zig build
    ./zig-out/bin/gorky-tool check /game | tail -3
    sh scripts/fullgame.sh /game | grep -E "end of game|: lost" | tail -3
    sh scripts/regress.sh /game
    SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy ./zig-out/bin/opengorky-viewer /game \
      01__port_bulldozer/sprite.dat --level --time 3000 --shot /tmp/shot.png && ls -la /tmp/shot.png
    SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy ./zig-out/bin/opengorky-viewer /game \
      01_port/sprite.dat --level --time 5000 --video gradma.avi --shot /tmp/video.png 2>&1 | grep video
  '
