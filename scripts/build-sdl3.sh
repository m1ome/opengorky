#!/bin/sh
# Own SDL3 build for macOS distribution: a universal (arm64 + x86_64) shared library
# with only video (Cocoa/Metal), audio (CoreAudio) and events — no camera, joysticks,
# touchpads, sensors, GPU API, dialogs or tests.
# CMake, if missing, is downloaded into a cache (zig-out/sdl3/cmake); the system is untouched.
#
#   scripts/build-sdl3.sh [dir]   — default zig-out/sdl3
# Result: <dir>/prefix/{include,lib}; game build: zig build -Dsdl-prefix=<dir>/prefix
set -e
VER=${SDL3_VERSION:-$(pkg-config --modversion sdl3 2>/dev/null || echo 3.4.14)}
CMAKE_VER=${CMAKE_VERSION:-3.31.6}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${1:-$ROOT/zig-out/sdl3}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

CMAKE=$(command -v cmake || true)
if [ -z "$CMAKE" ]; then
  CM="$OUT/cmake"
  if [ ! -x "$CM/CMake.app/Contents/bin/cmake" ]; then
    mkdir -p "$CM"
    curl -sSL "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VER/cmake-$CMAKE_VER-macos-universal.tar.gz" |
      tar -xz -C "$CM" --strip-components=1
  fi
  CMAKE="$CM/CMake.app/Contents/bin/cmake"
fi

TAR="$OUT/SDL3-$VER.tar.gz"
[ -f "$TAR" ] || curl -sSL -o "$TAR" "https://github.com/libsdl-org/SDL/releases/download/release-$VER/SDL3-$VER.tar.gz"
rm -rf "$OUT/src" "$OUT/build" "$OUT/prefix"
mkdir -p "$OUT/src"
tar -xzf "$TAR" -C "$OUT/src" --strip-components=1

"$CMAKE" -S "$OUT/src" -B "$OUT/build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_INSTALL_PREFIX="$OUT/prefix" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
  -DSDL_CAMERA=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_HIDAPI=OFF -DSDL_SENSOR=OFF \
  -DSDL_POWER=OFF -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_GPU=OFF -DSDL_VULKAN=OFF \
  -DSDL_OPENGLES=OFF >/dev/null
"$CMAKE" --build "$OUT/build" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >/dev/null
"$CMAKE" --install "$OUT/build" >/dev/null
lipo -info "$OUT/prefix/lib/libSDL3.0.dylib"
du -sh "$OUT/prefix/lib/libSDL3.0.dylib"
