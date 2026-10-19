#!/bin/sh
# Minimal FFmpeg build for the game videos: only what avi/*.asf needs —
# ASF demuxer, MS-MPEG4 v1/v2/v3 video, WMA v1/v2 and MP3 audio, plus swscale and
# swresample. No network, encoders, filters, devices or external libraries.
# Shared libraries (LGPL: replaceable without rebuilding the game).
#
#   scripts/build-ffmpeg.sh [dir]   — default zig-out/ffmpeg
#   ARCH=x86_64|arm64 scripts/build-ffmpeg.sh dir — macOS: build for one architecture
#     (x86_64 on Apple Silicon is a clang -arch cross build without asm;
#     scripts/dist-macos.sh makes universal libraries with lipo)
#   CROSS=x86_64-w64-mingw32 scripts/build-ffmpeg.sh dir — Windows DLLs (mingw-w64 cross gcc;
#     scripts/dist-windows.sh), without winpthreads or libgcc DLLs
# Result: <dir>/prefix/{include,lib}; game build: zig build -Dffmpeg-prefix=<dir>/prefix
set -e
VER=${FFMPEG_VERSION:-9.0.1}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${1:-$ROOT/zig-out/ffmpeg}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TAR="$OUT/ffmpeg-$VER.tar.xz"
[ -f "$TAR" ] || curl -sSL -o "$TAR" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
rm -rf "$OUT/src" "$OUT/prefix"
mkdir -p "$OUT/src"
tar -xJf "$TAR" -C "$OUT/src" --strip-components=1
cd "$OUT/src"
case "$(uname -s)" in
  Darwin)
    set -- --install-name-dir=@rpath
    if [ -n "$ARCH" ]; then
      FFARCH=$ARCH; [ "$ARCH" = arm64 ] && FFARCH=aarch64
      set -- "$@" --arch="$FFARCH" --target-os=darwin --enable-cross-compile \
        --cc="clang -arch $ARCH" --extra-cflags=-mmacosx-version-min=13.0 \
        --extra-ldflags=-mmacosx-version-min=13.0
      [ "$ARCH" = x86_64 ] && set -- "$@" --disable-x86asm
    fi
    ;;
  *) set -- ;;
esac
THREADS=--enable-pthreads
if [ -n "$CROSS" ]; then
  set -- --arch=x86_64 --target-os=mingw32 --cross-prefix="$CROSS-" --enable-cross-compile \
    --extra-ldflags=-static-libgcc
  THREADS=--enable-w32threads
fi
./configure --prefix="$OUT/prefix" "$@" \
  --enable-shared --disable-static --enable-pic --enable-small \
  --disable-programs --disable-doc --disable-network --disable-autodetect \
  --disable-everything --disable-avdevice --disable-avfilter $THREADS \
  --enable-avformat --enable-avcodec --enable-swscale --enable-swresample \
  --enable-protocol=file --enable-demuxer=asf \
  --enable-decoder=msmpeg4v1,msmpeg4v2,msmpeg4v3,wmav1,wmav2,mp3,mp3float \
  --enable-parser=mpegaudio >/dev/null
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
make install >/dev/null
du -sh "$OUT/prefix/lib"
