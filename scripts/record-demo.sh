#!/bin/sh
# Six 10–15 s demo clips from the game played by the viewer itself (an input script,
# no sound): the arrival scene, the first battle (heroes on AI), the found-body scene,
# a walk through the port, the second battle, a walk in the city (04_city, reached
# with the console). The script is deterministic (one world tick a frame, 30 fps),
# so the clip windows below are fixed frame counts. Each clip is
# the 640×480 frame drawn at detail 3 (1920×1440), scaled to 1440×1080 in the middle
# of a 1920×1080 picture with a blurred copy behind it: zig-out/demo/NN_name.mp4.
#
#   scripts/record-demo.sh <game dir>     e.g. ~/Downloads/Gorky17 (the English GOG game)
#
# The game folder is only read. PNG frames (~0.7 MB each) live in zig-out/demo/frames
# while recording and are deleted once their clip is encoded.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${1:?usage: scripts/record-demo.sh <game dir>}"
OUT="$ROOT/zig-out/demo"
F="$OUT/frames"
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed" >&2; exit 1; }
cd "$ROOT"
zig build
rm -rf "$F"; mkdir -p "$F"

# Steps (app/input_script.zig): c — click in 640×480, p — key, w N — frames,
# x — console command, o DIR / O — record on / off, W — wait for a scene to end,
# R — wait for the battle report and close it. Points after `x click` are background
# pixels of 01_port. The rifles go into the heroes' hands first, as a player would
# (battle draws the weapon in hand; with none the AI shoots the rifle from an empty hand).
cat > "$F/script.txt" <<EOF
w 40;c 320,207;w 30;p Escape;
w 385;o $F/01_scene_arrival;w 390;O;W;w 30;
x hero ovitz;x equip ov_rifle;x hero trantigne;x equip tr_rifle;x hero sullivan;x equip su_rifle;
m 560,452;
x click 1250 220;w 270;x click 1450 330;w 150;
x click 1550 400;w 400;x auto;w 140;o $F/02_battle;w 420;O;R;w 60;
x click 1100 700;w 300;o $F/03_scene_bodyfound;w 390;O;W;w 30;
o $F/04_walk_port;x click 1636 380;w 270;x click 1308 356;w 150;O;
x click 1000 760;w 600;x auto;o $F/05_battle_heavy;w 450;O;R;w 60;
x level 04_city;w 100;m 560,452;o $F/06_walk_city;x click 2050 560;w 160;x click 2228 300;w 170;O;
q
EOF
tr -d '\n' < "$F/script.txt" > "$F/script1.txt"
zig-out/bin/opengorky-viewer "$GAME" --play --window 720,540 --hires 3 --mute --input "@$F/script1.txt"

for d in "$F"/*/; do
  name=$(basename "$d")
  [ -f "$d/00000.png" ] || continue
  # Middle: the frame at 1440×1080; behind it the same frame filling 1920×1080, blurred and darkened.
  ffmpeg -loglevel error -y -framerate 30 -i "$d/%05d.png" -filter_complex \
    "[0:v]split=2[a][b];[a]scale=1440:1080:flags=lanczos[fg];[b]scale=1920:1440,crop=1920:1080,boxblur=40:2,eq=brightness=-0.12[bg];[bg][fg]overlay=(W-w)/2:0,format=yuv420p" \
    -c:v libx264 -preset slow -crf 16 -movflags +faststart "$OUT/$name.mp4"
  rm -rf "$d"
  echo "$OUT/$name.mp4"
done
