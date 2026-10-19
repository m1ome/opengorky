#!/bin/sh
# Linux package: zig-out/dist/opengorky-linux-<arch>.tar.xz, built in the
# scripts/linux container (Debian trixie, Zig 0.17). Contains: the viewer
# (ReleaseFast, no debug info, rpath $ORIGIN/lib), lib/ with Debian's SDL3 and a
# minimal FFmpeg (scripts/build-ffmpeg.sh, gcc in the container), licenses, the
# launcher opengorky <game dir>, icon opengorky.png and opengorky.desktop.
#
#   scripts/dist-linux.sh [game dir]   — OPT=ReleaseFast to optimize for speed
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=${OPT:-ReleaseFast}
GAME=${1:-}
mkdir -p "$ROOT/zig-out/dist"
# Optional game dir argument: check that a video decodes.
set --
[ -n "$GAME" ] && set -- -v "$GAME":/game:ro
docker build -q -t opengorky-linux "$ROOT/scripts/linux" >/dev/null
docker run --rm "$@" -v "$ROOT":/src:ro -v "$ROOT/zig-out/dist":/out -v opengorky-linux-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global -e OPT="$OPT" opengorky-linux sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    sh scripts/build-ffmpeg.sh /work/zig-out/ffmpeg >/dev/null
    zig build -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
      -Dffmpeg-prefix=/work/zig-out/ffmpeg/prefix -Dbundle-rpath="\$ORIGIN/lib" -p /work/zig-out/b
    ARCH=$(uname -m)
    D=/work/zig-out/opengorky
    mkdir -p $D/lib $D/licenses
    cp zig-out/b/bin/opengorky-viewer $D/
    for l in libavcodec.so.63 libavformat.so.63 libavutil.so.61 libswresample.so.7 libswscale.so.10; do
      cp -L zig-out/ffmpeg/prefix/lib/$l $D/lib/
    done
    SDL=$(ldd zig-out/b/bin/opengorky-viewer | awk "/libSDL3/{print \$3; exit}")
    cp -L "$SDL" $D/lib/
    cp LICENSE $D/licenses/OpenGorky-MIT.txt
    cp /usr/share/doc/libsdl3-0/copyright $D/licenses/SDL3-copyright.txt 2>/dev/null || true
    cp zig-out/ffmpeg/src/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
    printf "%s\n" "OpenGorky — MIT. SDL3 — zlib. FFmpeg — LGPL 2.1+, shared libraries in lib/" \
      "(replaceable with your own build; options — scripts/build-ffmpeg.sh)." > $D/licenses/README.txt
    printf "%s\n" "#!/bin/sh" "# opengorky <Gorky 17 dir with dat/ and avi/> [flags]" \
      "HERE=\$(cd \"\$(dirname \"\$0\")\" && pwd)" "G=\${1:?game dir}; shift" \
      "exec \"\$HERE/opengorky-viewer\" \"\$G\" --play \"\$@\"" > $D/opengorky
    chmod +x $D/opengorky
    # Icon and app-menu entry (Exec: set the package path on install).
    cp assets/icon-256.png $D/opengorky.png
    printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=OpenGorky" \
      "Comment=Gorky 17 (needs the original game files)" "Exec=opengorky %f" \
      "Icon=opengorky" "Categories=Game;RolePlaying;" "Terminal=false" > $D/opengorky.desktop
    # Check: all libraries come from the package or the system, a video decodes.
    ldd $D/opengorky-viewer | grep -E "libav|libsw|SDL3"
    if [ -d /game/dat ]; then
      SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy $D/opengorky-viewer /game 01_port/sprite.dat \
        --level --time 5000 --video incubus.avi --shot /tmp/v.png 2>&1 | grep video
    fi
    tar -C /work/zig-out -cJf /out/opengorky-linux-$ARCH.tar.xz opengorky
    du -sh $D /out/opengorky-linux-$ARCH.tar.xz
  '
