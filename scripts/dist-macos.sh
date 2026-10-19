#!/bin/sh
# macOS package: zig-out/dist/OpenGorky.app and OpenGorky-macos-<arch>.zip.
# Contains: icon assets/icon.png (AppIcon.icns), a universal (arm64 + x86_64) viewer
# (ReleaseFast, no debug info), our SDL3 build (scripts/build-sdl3.sh) and a minimal
# FFmpeg (scripts/build-ffmpeg.sh, both architectures, lipo'd) in Contents/Frameworks, licenses.
# No game files inside: the first launch asks for the game dir (dat/, avi/,
# adjust.kdt) and stores it as game_path in ~/Library/Application Support/OpenGorky/opengorky.cfg.
#
#   scripts/dist-macos.sh            — OPT=ReleaseFast to optimize for speed;
#                                      SIGN_IDENTITY="Developer ID Application: …" to sign,
#                                      NOTARY_PROFILE=<notarytool profile> to notarize;
#                                      ARCHS="arm64" — one architecture only
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OPT=${OPT:-ReleaseFast}
ARCHS=${ARCHS:-arm64 x86_64}

# SDL3: our universal build.
SDL="$ROOT/zig-out/sdl3/prefix"
[ -f "$SDL/lib/libSDL3.0.dylib" ] || sh scripts/build-sdl3.sh
SDL_LIB="$SDL/lib/libSDL3.0.dylib"
SDL_SRC="$ROOT/zig-out/sdl3/src"

# FFmpeg: one build per architecture, then universal libraries via lipo.
FFLIBS="libavcodec.63 libavformat.63 libavutil.61 libswresample.7 libswscale.10"
FF="$ROOT/zig-out/ffmpeg-universal/prefix"
rm -rf "$FF"; mkdir -p "$FF/lib"
for a in $ARCHS; do
  [ -f "$ROOT/zig-out/ffmpeg-$a/prefix/lib/libavcodec.dylib" ] || ARCH=$a sh scripts/build-ffmpeg.sh "$ROOT/zig-out/ffmpeg-$a"
done
FIRST=$(echo $ARCHS | awk '{print $1}')
cp -R "$ROOT/zig-out/ffmpeg-$FIRST/prefix/include" "$FF/include"
for l in $FFLIBS; do
  set --
  for a in $ARCHS; do set -- "$@" "$ROOT/zig-out/ffmpeg-$a/prefix/lib/$l.dylib"; done
  lipo -create "$@" -output "$FF/lib/$l.dylib"
  ln -sf "$l.dylib" "$FF/lib/${l%.*}.dylib"
done

# Viewer per architecture, then one universal binary.
BUILD="$ROOT/zig-out/dist-build"
set --
for a in $ARCHS; do
  t=$a; [ "$a" = arm64 ] && t=aarch64
  zig build -Dtarget=$t-macos -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
    -Dffmpeg-prefix="$FF" -Dsdl-prefix="$SDL" -Dbundle-rpath=@executable_path/../Frameworks -p "$BUILD-$a"
  set -- "$@" "$BUILD-$a/bin/opengorky-viewer"
done

APP="$ROOT/zig-out/dist/OpenGorky.app"
rm -rf "$APP" "$ROOT"/zig-out/dist/OpenGorky-macos-*.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/licenses"
BIN="$APP/Contents/MacOS/opengorky-viewer"
lipo -create "$@" -output "$BIN"

# Libraries: real files under their LC_LOAD_DYLIB names (@rpath/<name>).
cp -L "$SDL_LIB" "$APP/Contents/Frameworks/libSDL3.0.dylib"
for l in $FFLIBS; do
  cp -L "$FF/lib/$l.dylib" "$APP/Contents/Frameworks/$l.dylib"
done
chmod u+w "$APP"/Contents/Frameworks/*.dylib
install_name_tool -id @rpath/libSDL3.0.dylib "$APP/Contents/Frameworks/libSDL3.0.dylib"
SDL_REF=$(otool -L "$BIN" | awk '/libSDL3/{print $1; exit}')
install_name_tool -change "$SDL_REF" @rpath/libSDL3.0.dylib "$BIN"
# No other external (non-system) libraries allowed.
if otool -L "$BIN" "$APP"/Contents/Frameworks/*.dylib | grep -E '^\s+/(opt|usr/local)/'; then
  echo "references to libraries outside the package" >&2; exit 1
fi
# The binary rpath is only the bundled Frameworks (-Dbundle-rpath).
if otool -l "$BIN" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | grep -v '^@executable_path/../Frameworks$'; then
  echo "unexpected rpath in the binary" >&2; exit 1
fi

# Launch from Finder: game dir from the settings, an env var or a folder prompt.
cat > "$APP/Contents/MacOS/OpenGorky" <<'EOF'
#!/bin/sh
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOME/Library/Application Support/OpenGorky"
# Game dir: $OPENGORKY_GAME, else game_path from opengorky.cfg (the viewer migrates
# the old game_path file itself); the viewer saves a new path on first launch.
GAME=${OPENGORKY_GAME:-$(sed -n 's/^[[:space:]]*game_path[[:space:]]*=[[:space:]]*//p' "$CONF/opengorky.cfg" 2>/dev/null | tail -n 1)}
[ -n "$GAME" ] || GAME=$(cat "$CONF/game_path" 2>/dev/null)
if [ ! -d "$GAME/dat" ]; then
  GAME=$(osascript -e 'POSIX path of (choose folder with prompt "Gorky 17 folder (with dat and avi)")' 2>/dev/null) || exit 0
  GAME=${GAME%/}
  [ -d "$GAME/dat" ] || { osascript -e 'display alert "OpenGorky" message "The selected folder has no dat folder."'; exit 1; }
fi
exec "$HERE/opengorky-viewer" "$GAME" --play "$@"
EOF
chmod +x "$APP/Contents/MacOS/OpenGorky"

# Bundle icon from assets/icon.png (1024×1024): all sizes 16…512 @1x/@2x.
SET="$ROOT/zig-out/dist-build/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for n in 16 32 128 256 512; do
  sips -z $n $n assets/icon.png --out "$SET/icon_${n}x${n}.png" >/dev/null
  sips -z $((n * 2)) $((n * 2)) assets/icon.png --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"

VER=$(git describe --always --dirty 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenGorky</string>
  <key>CFBundleDisplayName</key><string>OpenGorky</string>
  <key>CFBundleIdentifier</key><string>io.github.opengorky</string>
  <key>CFBundleExecutable</key><string>OpenGorky</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.role-playing-games</string>
</dict>
</plist>
EOF

cp LICENSE "$APP/Contents/Resources/licenses/OpenGorky-MIT.txt"
cp "$SDL_SRC/LICENSE.txt" "$APP/Contents/Resources/licenses/SDL3-zlib.txt"
cp "$ROOT/zig-out/ffmpeg-$FIRST/src/COPYING.LGPLv2.1" "$APP/Contents/Resources/licenses/FFmpeg-LGPL-2.1.txt"
cat > "$APP/Contents/Resources/licenses/README.txt" <<EOF
OpenGorky — MIT. SDL3 — zlib. FFmpeg $(sed -n 's/^\([0-9.]*\).*/\1/p' "$ROOT/zig-out/ffmpeg-$FIRST/src/VERSION" 2>/dev/null || true) — LGPL 2.1+,
shared libraries in Contents/Frameworks (replaceable with your own build;
sources: https://ffmpeg.org/releases/, options — scripts/build-ffmpeg.sh).
EOF

# Signature. SIGN_IDENTITY="Developer ID Application: …" signs with hardened runtime
# and a timestamp (needed for notarization); without it, ad-hoc (Gatekeeper asks on
# first launch: right click → "Open").
if [ -n "$SIGN_IDENTITY" ]; then
  SIGN="--force --timestamp --options runtime -s"
else
  SIGN="--force -s"; SIGN_IDENTITY=-
fi
for f in "$APP"/Contents/Frameworks/*.dylib "$BIN" "$APP/Contents/MacOS/OpenGorky"; do
  codesign $SIGN "$SIGN_IDENTITY" "$f"
done
codesign $SIGN "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

ARCH=$(lipo -archs "$BIN")
lipo -info "$BIN" "$APP"/Contents/Frameworks/*.dylib
ZIP="$ROOT/zig-out/dist/OpenGorky-macos-$(echo "$ARCH" | tr ' ' '-').zip"
(cd "$ROOT/zig-out/dist" && ditto -c -k --keepParent OpenGorky.app "$ZIP")

# Notarization: NOTARY_PROFILE is a keychain profile from
# `xcrun notarytool store-credentials`. The ticket is stapled to the app and the zip rebuilt.
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  (cd "$ROOT/zig-out/dist" && ditto -c -k --keepParent OpenGorky.app "$ZIP")
  spctl --assess --type execute -v "$APP"
fi
du -sh "$APP" "$ZIP"
