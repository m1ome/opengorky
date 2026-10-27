#!/bin/sh
# Windows packages: zig-out/dist/opengorky-windows-x86_64.zip and, separately, the level
# editor opengorky-editor-windows-x86_64.zip (OpenGorkyEditor.exe, SDL3.dll), cross-built in the
# scripts/linux container (Zig for the viewer, mingw-w64 gcc for FFmpeg). Contains:
# OpenGorky.exe (the viewer, GUI subsystem, ReleaseFast, no debug info; a double
# click starts the game and asks for the game folder once), SDL3.dll (official
# mingw build), licenses; FFmpeg and LAME (scripts/build-ffmpeg.sh; LGPL) linked statically.
#
#   scripts/dist-windows.sh   — OPT=ReleaseFast to optimize for speed;
#                               SDL3_VERSION=3.4.14 — SDL3 release to bundle
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=${OPT:-ReleaseFast}
mkdir -p "$ROOT/zig-out/dist"
VER=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
SRCURL=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//' || true)
docker build -q -t opengorky-linux "$ROOT/scripts/linux" >/dev/null
docker run --rm -v "$ROOT":/src:ro -v "$ROOT/zig-out/dist":/out -v opengorky-linux-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global -e OPT="$OPT" -e VER="$VER" -e SRCURL="$SRCURL" -e SDL3_VERSION="${SDL3_VERSION:-3.4.14}" opengorky-linux sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    CROSS=x86_64-w64-mingw32 sh scripts/build-ffmpeg.sh /work/zig-out/ffmpeg >/dev/null 2>&1
    mkdir -p zig-out/sdl3
    curl -sSLf --retry 5 --retry-all-errors "https://github.com/libsdl-org/SDL/releases/download/release-$SDL3_VERSION/SDL3-devel-$SDL3_VERSION-mingw.tar.gz" |
      tar -xz -C zig-out/sdl3 --strip-components=1
    SDL=/work/zig-out/sdl3/x86_64-w64-mingw32
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
      -Dffmpeg-prefix=/work/zig-out/ffmpeg/prefix -Dsdl-prefix=$SDL -p /work/zig-out/b
    D=/work/zig-out/opengorky
    mkdir -p $D/licenses
    cp zig-out/b/bin/opengorky-viewer.exe $D/OpenGorky.exe
    cp $SDL/bin/SDL3.dll $D/
    cp LICENSE $D/licenses/OpenGorky-MIT.txt
    cp zig-out/sdl3/LICENSE.txt $D/licenses/SDL3-zlib.txt
    cp zig-out/ffmpeg/src/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
    cp zig-out/ffmpeg/lame/COPYING $D/licenses/LAME-LGPL-2.txt
    printf "%s\r\n" "OpenGorky - MIT. SDL3 - zlib (SDL3.dll)." \
      "FFmpeg $(cat zig-out/ffmpeg/src/VERSION) - LGPL 2.1+, and LAME 3.100 - LGPL 2+: linked statically into the program." \
      "To relink it with your own (modified) FFmpeg or LAME: the complete source of the program is the" \
      "relinkable form - ${SRCURL:-the OpenGorky repository}, version $VER; build the libraries with" \
      "scripts/build-ffmpeg.sh (or your own), then zig build -Dffmpeg-prefix=<build>/prefix (README)." \
      "Library sources: https://ffmpeg.org/releases/, https://lame.sourceforge.io/." > $D/licenses/README.txt
    printf "%s\r\n" "OpenGorky - MIT. SDL3 - zlib. FFmpeg, LAME - LGPL (linked in; see licenses/README.txt)." \
      "" "Run OpenGorky.exe and pick the Gorky 17 folder (with dat and avi)." \
      "Settings and saves: %APPDATA%\\OpenGorky." > $D/README.txt
    # Level editor: the game folder is chosen in its settings.
    E=/work/zig-out/opengorky-editor
    mkdir -p $E/licenses
    cp zig-out/b/bin/opengorky-editor.exe $E/OpenGorkyEditor.exe
    cp $SDL/bin/SDL3.dll $E/
    cp LICENSE $E/licenses/OpenGorky-MIT.txt
    cp zig-out/sdl3/LICENSE.txt $E/licenses/SDL3-zlib.txt
    cp third_party/clay/LICENSE.md $E/licenses/Clay-zlib.txt
    cp assets/fonts/OFL.txt $E/licenses/PTSans-OFL.txt
    cp assets/icons/LICENSE-lucide.txt $E/licenses/Lucide-ISC.txt
    cp $D/licenses/FFmpeg-LGPL-2.1.txt $D/licenses/LAME-LGPL-2.txt $D/licenses/README.txt $E/licenses/
    printf "%s\r\n" "OpenGorky - MIT. SDL3 - zlib. Clay - zlib. stb_truetype - public domain. PT Sans - SIL OFL 1.1. Lucide icons - ISC." \
      "FFmpeg, LAME - LGPL (linked in; see licenses/README.txt)." \
      "" "Run OpenGorkyEditor.exe and choose a COPY of the Gorky 17 folder in Settings:" \
      "the editor rewrites its .dat archives." "Settings: %APPDATA%\\OpenGorky\\editor.cfg." > $E/README.txt
    # Check: every imported DLL is in its package or a Windows system DLL.
    for P in $D $E; do for f in $P/*.exe $P/*.dll; do x86_64-w64-mingw32-objdump -p $f | sed -n "s/^\s*DLL Name: //p" | sed "s|^|$P |"; done; done | sort -u |
      while read P dll; do
        [ -f "$P/$dll" ] && continue
        case "$(echo "$dll" | tr A-Z a-z)" in
          kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|imm32.dll|\
          version.dll|winmm.dll|setupapi.dll|bcrypt.dll|ntdll.dll|msvcrt.dll|ws2_32.dll|secur32.dll|\
          api-ms-win-*) ;;
          *) echo "imports a DLL outside the package: $dll" >&2; exit 1 ;;
        esac
      done
    rm -f /out/opengorky-windows-x86_64.zip /out/opengorky-editor-windows-x86_64.zip
    (cd /work/zig-out && zip -qr /out/opengorky-windows-x86_64.zip opengorky && zip -qr /out/opengorky-editor-windows-x86_64.zip opengorky-editor)
    du -sh $D /out/opengorky-windows-x86_64.zip $E /out/opengorky-editor-windows-x86_64.zip
  '
