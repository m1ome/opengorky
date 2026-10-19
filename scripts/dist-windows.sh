#!/bin/sh
# Windows package: zig-out/dist/opengorky-windows-x86_64.zip, cross-built in the
# scripts/linux container (Zig for the viewer, mingw-w64 gcc for FFmpeg). Contains:
# OpenGorky.exe (the viewer, GUI subsystem, ReleaseFast, no debug info; a double
# click starts the game and asks for the game folder once), SDL3.dll (official
# mingw build), a minimal FFmpeg (scripts/build-ffmpeg.sh) as DLLs, licenses.
#
#   scripts/dist-windows.sh   — OPT=ReleaseFast to optimize for speed;
#                               SDL3_VERSION=3.4.14 — SDL3 release to bundle
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=${OPT:-ReleaseFast}
mkdir -p "$ROOT/zig-out/dist"
docker build -q -t opengorky-linux "$ROOT/scripts/linux" >/dev/null
docker run --rm -v "$ROOT":/src:ro -v "$ROOT/zig-out/dist":/out -v opengorky-linux-cache:/cache \
  -e ZIG_GLOBAL_CACHE_DIR=/cache/global -e OPT="$OPT" -e SDL3_VERSION="${SDL3_VERSION:-3.4.14}" opengorky-linux sh -c '
    set -e
    cp -r /src /work && cd /work && rm -rf zig-out .zig-cache
    CROSS=x86_64-w64-mingw32 sh scripts/build-ffmpeg.sh /work/zig-out/ffmpeg >/dev/null
    mkdir -p zig-out/sdl3
    curl -sSLf "https://github.com/libsdl-org/SDL/releases/download/release-$SDL3_VERSION/SDL3-devel-$SDL3_VERSION-mingw.tar.gz" |
      tar -xz -C zig-out/sdl3 --strip-components=1
    SDL=/work/zig-out/sdl3/x86_64-w64-mingw32
    zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
      -Dffmpeg-prefix=/work/zig-out/ffmpeg/prefix -Dsdl-prefix=$SDL -p /work/zig-out/b
    D=/work/zig-out/opengorky
    mkdir -p $D/licenses
    cp zig-out/b/bin/opengorky-viewer.exe $D/OpenGorky.exe
    cp $SDL/bin/SDL3.dll zig-out/ffmpeg/prefix/bin/*.dll $D/
    cp LICENSE $D/licenses/OpenGorky-MIT.txt
    cp zig-out/sdl3/LICENSE.txt $D/licenses/SDL3-zlib.txt
    cp zig-out/ffmpeg/src/COPYING.LGPLv2.1 $D/licenses/FFmpeg-LGPL-2.1.txt
    printf "%s\r\n" "OpenGorky - MIT. SDL3 - zlib. FFmpeg - LGPL 2.1+, the av*/sw* DLLs" \
      "(replaceable with your own build; options - scripts/build-ffmpeg.sh)." \
      "" "Run OpenGorky.exe and pick the Gorky 17 folder (with dat and avi)." \
      "Settings and saves: %APPDATA%\\OpenGorky." > $D/README.txt
    # Check: every imported DLL is in the package or a Windows system DLL.
    for f in $D/*.exe $D/*.dll; do x86_64-w64-mingw32-objdump -p $f | sed -n "s/^\s*DLL Name: //p"; done | sort -u |
      while read dll; do
        [ -f "$D/$dll" ] && continue
        case "$(echo "$dll" | tr A-Z a-z)" in
          kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|imm32.dll|\
          version.dll|winmm.dll|setupapi.dll|bcrypt.dll|ntdll.dll|msvcrt.dll|ws2_32.dll|secur32.dll|\
          api-ms-win-*) ;;
          *) echo "imports a DLL outside the package: $dll" >&2; exit 1 ;;
        esac
      done
    rm -f /out/opengorky-windows-x86_64.zip
    (cd /work/zig-out && zip -qr /out/opengorky-windows-x86_64.zip opengorky)
    du -sh $D /out/opengorky-windows-x86_64.zip
  '
