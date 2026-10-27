#!/bin/sh
# FFmpeg for the viewer and the editor, static (linked into the binaries; LGPL 2.1+ —
# relinkable from the project source, see README): all decoders, demuxers and parsers
# (video playback and the editor's imports), encoders MS-MPEG4 v3, WMA v1 and MP3
# (LAME 3.100, LGPL 2+, built static first), muxers ASF and MP3, swscale and
# swresample. No network, filters, devices, hardware or other external libraries.
#
#   scripts/build-ffmpeg.sh [dir]   — default zig-out/ffmpeg
#   ARCH=x86_64|arm64 scripts/build-ffmpeg.sh dir — macOS: build for one architecture
#     (x86_64 on Apple Silicon is a clang -arch cross build without asm;
#     scripts/dist-macos.sh links one binary per architecture and lipo's them)
#   CROSS=x86_64-w64-mingw32 scripts/build-ffmpeg.sh dir — Windows (mingw-w64 cross gcc;
#     scripts/dist-windows.sh)
# Result: <dir>/prefix/{include,lib} (libav*.a, libsw*.a, libmp3lame.a);
# game build: zig build -Dffmpeg-prefix=<dir>/prefix
# Sources are checked by SHA-256; another FFMPEG_VERSION needs its FFMPEG_SHA256.
set -e
VER=${FFMPEG_VERSION:-9.0.1}
SHA=${FFMPEG_SHA256:-$([ "$VER" = 9.0.1 ] && echo cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635)}
# fetch URL FILE SHA256 — download once, then verify.
fetch() {
  [ -f "$2" ] || curl -sSLf --retry 5 --retry-all-errors -o "$2" "$1"
  got=$({ sha256sum "$2" 2>/dev/null || shasum -a 256 "$2"; } | awk '{print $1}')
  [ "$got" = "$3" ] || { echo "$2: SHA-256 $got, expected ${3:-(none given)}" >&2; rm -f "$2"; exit 1; }
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${1:-$ROOT/zig-out/ffmpeg}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
TAR="$OUT/ffmpeg-$VER.tar.xz"
fetch "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz" "$TAR" "$SHA"
rm -rf "$OUT/src" "$OUT/prefix" "$OUT/lame"
mkdir -p "$OUT/src"
tar -xJf "$TAR" -C "$OUT/src" --strip-components=1
cd "$OUT/src"
HOST=
case "$(uname -s)" in
  Darwin)
    set --
    if [ -n "$ARCH" ]; then
      FFARCH=$ARCH; [ "$ARCH" = arm64 ] && FFARCH=aarch64
      HOST="--host=$FFARCH-apple-darwin"
      set -- --arch="$FFARCH" --target-os=darwin --enable-cross-compile \
        --cc="clang -arch $ARCH" --extra-cflags=-mmacosx-version-min=13.0 \
        --extra-ldflags=-mmacosx-version-min=13.0
      [ "$ARCH" = x86_64 ] && set -- "$@" --disable-x86asm
    fi
    ;;
  *) set -- ;;
esac
THREADS=--enable-pthreads
if [ -n "$CROSS" ]; then
  set -- --arch=x86_64 --target-os=mingw32 --cross-prefix="$CROSS-" --enable-cross-compile
  THREADS=--enable-w32threads
  HOST="--host=$CROSS"
fi
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
# LAME: static, only the encoder library, built with the same compiler and target.
fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz "$OUT/lame-3.100.tar.gz" \
  ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
mkdir -p "$OUT/lame"
tar -xzf "$OUT/lame-3.100.tar.gz" -C "$OUT/lame" --strip-components=1
CC=gcc; [ -n "$CROSS" ] && CC=$CROSS-gcc
CFLAGS=-O2
if [ "$(uname -s)" = Darwin ]; then
  CC="clang${ARCH:+ -arch $ARCH}"; CFLAGS="-O2${ARCH:+ -mmacosx-version-min=13.0}"
fi
(cd "$OUT/lame" && CC="$CC" CFLAGS="$CFLAGS" ./configure $HOST --prefix="$OUT/prefix" \
  --disable-shared --enable-static --with-pic --disable-frontend --disable-decoder >/dev/null &&
  make -j"$JOBS" >/dev/null && make install >/dev/null)
./configure --prefix="$OUT/prefix" "$@" \
  --disable-shared --enable-static --enable-pic --enable-small \
  --disable-programs --disable-doc --disable-network --disable-autodetect \
  --disable-avdevice --disable-avfilter --disable-hwaccels $THREADS \
  --disable-encoders --enable-encoder=msmpeg4v3,wmav1,libmp3lame \
  --disable-muxers --enable-muxer=asf,mp3 \
  --disable-protocols --enable-protocol=file \
  --enable-libmp3lame --extra-cflags="-I$OUT/prefix/include" --extra-ldflags="-L$OUT/prefix/lib" >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null
du -sh "$OUT/prefix/lib"/*.a
