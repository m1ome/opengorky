#!/bin/sh
# Linux packages: zig-out/dist/opengorky-linux-<arch>.tar.xz and, separately, the level
# editor opengorky-editor-linux-<arch>.tar.xz (the editor and SDL3), built in the
# scripts/linux container (Debian trixie, Zig 0.17). Contains: the viewer
# (ReleaseFast, no debug info, rpath $ORIGIN/lib) with FFmpeg and LAME linked statically
# (scripts/build-ffmpeg.sh, gcc in the container; LGPL), lib/ with Debian's SDL3, licenses, the
# launcher opengorky <game dir>, icon opengorky.png and opengorky.desktop.
#
#   scripts/dist-linux.sh [game dir]   — OPT=ReleaseFast to optimize for speed
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=${OPT:-ReleaseFast}
GAME=${1:-}
mkdir -p "$ROOT/zig-out/dist"
VER=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
SRCURL=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//' || true)
# Optional game dir argument: check that a video decodes.
set --
[ -n "$GAME" ] && set -- -v "$GAME":/game:ro
docker build -q -t opengorky-linux "$ROOT/scripts/linux" >/dev/null
docker run --rm "$@" -v "$ROOT":/src:ro -v "$ROOT/zig-out/dist":/out -v opengorky-linux-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global -e OPT="$OPT" -e VER="$VER" -e SRCURL="$SRCURL" opengorky-linux sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    sh scripts/build-ffmpeg.sh /work/zig-out/ffmpeg >/dev/null 2>&1
    zig build -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
      -Dffmpeg-prefix=/work/zig-out/ffmpeg/prefix -Dbundle-rpath="\$ORIGIN/lib" -p /work/zig-out/b
    ARCH=$(uname -m)
    D=/work/zig-out/opengorky
    mkdir -p $D/lib $D/licenses
    cp zig-out/b/bin/opengorky-viewer $D/
    SDL=$(ldd zig-out/b/bin/opengorky-viewer | awk "/libSDL3/{print \$3; exit}")
    cp -L "$SDL" $D/lib/
    cp LICENSE $D/licenses/OpenGorky-MIT.txt
    cp /usr/share/doc/libsdl3-0/copyright $D/licenses/SDL3-copyright.txt 2>/dev/null || true
    cp zig-out/ffmpeg/src/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
    cp zig-out/ffmpeg/lame/COPYING $D/licenses/LAME-LGPL-2.txt
    printf "%s\n" "OpenGorky — MIT. SDL3 — zlib (lib/)." \
      "FFmpeg $(cat zig-out/ffmpeg/src/VERSION) — LGPL 2.1+, and LAME 3.100 — LGPL 2+: linked statically into the program." \
      "To relink it with your own (modified) FFmpeg or LAME: the complete source of the program is the" \
      "relinkable form — ${SRCURL:-the OpenGorky repository}, version $VER; build the libraries with" \
      "scripts/build-ffmpeg.sh (or your own), then zig build -Dffmpeg-prefix=<build>/prefix (README)." \
      "Library sources: https://ffmpeg.org/releases/, https://lame.sourceforge.io/." > $D/licenses/README.txt
    printf "%s\n" "#!/bin/sh" "# opengorky <Gorky 17 dir with dat/ and avi/> [flags]" \
      "HERE=\$(cd \"\$(dirname \"\$0\")\" && pwd)" "G=\${1:?game dir}; shift" \
      "exec \"\$HERE/opengorky-viewer\" \"\$G\" --play \"\$@\"" > $D/opengorky
    chmod +x $D/opengorky
    # Icon and app-menu entry (Exec: set the package path on install).
    cp assets/icon-256.png $D/opengorky.png
    printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=OpenGorky" \
      "Comment=Gorky 17 (needs the original game files)" "Exec=opengorky %f" \
      "Icon=opengorky" "Categories=Game;RolePlaying;" "Terminal=false" > $D/opengorky.desktop
    # Check: SDL3 from the package, FFmpeg inside the binary (its own NEEDED: ldd also lists
    # the LAME of libsndfile under SDL3), a video decodes.
    readelf -d $D/opengorky-viewer | grep NEEDED | grep -E "libav|libsw|libmp3lame" && { echo "viewer: FFmpeg linked dynamically" >&2; exit 1; }
    ldd $D/opengorky-viewer | grep SDL3
    if [ -d /game/dat ]; then
      SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy $D/opengorky-viewer /game 01_port/sprite.dat \
        --level --time 5000 --video incubus.avi --shot /tmp/v.png 2>&1 | grep video
    fi
    tar -C /work/zig-out -cJf /out/opengorky-linux-$ARCH.tar.xz opengorky
    du -sh $D /out/opengorky-linux-$ARCH.tar.xz
    # Level editor: the game folder is chosen in its settings (or given as the argument).
    E=/work/zig-out/opengorky-editor
    mkdir -p $E/lib $E/licenses
    cp zig-out/b/bin/opengorky-editor $E/
    cp $D/lib/* $E/lib/
    cp $D/licenses/OpenGorky-MIT.txt $E/licenses/
    cp /usr/share/doc/libsdl3-0/copyright $E/licenses/SDL3-copyright.txt 2>/dev/null || true
    cp third_party/clay/LICENSE.md $E/licenses/Clay-zlib.txt
    cp assets/fonts/OFL.txt $E/licenses/PTSans-OFL.txt
    cp assets/icons/LICENSE-lucide.txt $E/licenses/Lucide-ISC.txt
    cp $D/licenses/FFmpeg-LGPL-2.1.txt $D/licenses/LAME-LGPL-2.txt $E/licenses/
    { echo "Clay — zlib. stb_truetype — public domain. PT Sans — SIL OFL 1.1. Lucide icons — ISC."; cat $D/licenses/README.txt; } > $E/licenses/README.txt
    cp assets/icon-editor-256.png $E/opengorky-editor.png
    printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=OpenGorky Editor" \
      "Comment=Gorky 17 level editor (edits a copy of the game files)" "Exec=opengorky-editor" \
      "Icon=opengorky-editor" "Categories=Development;Game;" "Terminal=false" > $E/opengorky-editor.desktop
    ldd $E/opengorky-editor | grep SDL3 | grep -q "$E/lib/" || { echo "editor: SDL3 not from the package" >&2; exit 1; }
    readelf -d $E/opengorky-editor | grep NEEDED | grep -E "libav|libsw|libmp3lame" && { echo "editor: FFmpeg linked dynamically" >&2; exit 1; }
    tar -C /work/zig-out -cJf /out/opengorky-editor-linux-$ARCH.tar.xz opengorky-editor
    du -sh $E /out/opengorky-editor-linux-$ARCH.tar.xz
  '
