#!/bin/sh
# macOS packages: zig-out/dist/OpenGorky.app and OpenGorky-macos-<arch>.zip; the level
# editor separately: OpenGorky Editor.app and OpenGorky-Editor-macos-<arch>.zip (SDL3; it
# asks for the game folder in its settings).
# Contains: icon assets/icon.png (AppIcon.icns; the editor's assets/icon-editor.png), a universal (arm64 + x86_64) viewer
# (ReleaseFast, no debug info) with FFmpeg and LAME linked statically
# (scripts/build-ffmpeg.sh, per architecture; LGPL — see licenses/README.txt), our SDL3
# build (scripts/build-sdl3.sh) in Contents/Frameworks, licenses.
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

# FFmpeg (static, linked into the binaries): one build per architecture.
for a in $ARCHS; do
  [ -f "$ROOT/zig-out/ffmpeg-$a/prefix/lib/libavcodec.a" ] || ARCH=$a sh scripts/build-ffmpeg.sh "$ROOT/zig-out/ffmpeg-$a"
done
FIRST=$(echo $ARCHS | awk '{print $1}')
FFSRC="$ROOT/zig-out/ffmpeg-$FIRST"

# Viewer per architecture, then one universal binary.
BUILD="$ROOT/zig-out/dist-build"
set --
EDITORS=
for a in $ARCHS; do
  t=$a; [ "$a" = arm64 ] && t=aarch64
  zig build -Dtarget=$t-macos -Doptimize=ReleaseSafe -Dviewer-optimize="$OPT" -Dstrip=true \
    -Dffmpeg-prefix="$ROOT/zig-out/ffmpeg-$a/prefix" -Dsdl-prefix="$SDL" -Dbundle-rpath=@executable_path/../Frameworks -p "$BUILD-$a"
  set -- "$@" "$BUILD-$a/bin/opengorky-viewer"
  EDITORS="$EDITORS $BUILD-$a/bin/opengorky-editor"
done

APP="$ROOT/zig-out/dist/OpenGorky.app"
rm -rf "$APP" "$ROOT"/zig-out/dist/OpenGorky-macos-*.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/licenses"
BIN="$APP/Contents/MacOS/opengorky-viewer"
lipo -create "$@" -output "$BIN"

# SDL3: the real file under its LC_LOAD_DYLIB name (@rpath/<name>).
cp -L "$SDL_LIB" "$APP/Contents/Frameworks/libSDL3.0.dylib"
chmod u+w "$APP"/Contents/Frameworks/*.dylib
install_name_tool -id @rpath/libSDL3.0.dylib "$APP/Contents/Frameworks/libSDL3.0.dylib"
SDL_REF=$(otool -L "$BIN" | awk '/libSDL3/{print $1; exit}')
install_name_tool -change "$SDL_REF" @rpath/libSDL3.0.dylib "$BIN"
# No other external (non-system) libraries allowed; FFmpeg is inside the binary.
if otool -L "$BIN" "$APP"/Contents/Frameworks/*.dylib | grep -E '^\s+/(opt|usr/local)/|libav|libsw|libmp3lame'; then
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

# Bundle icon from a square PNG (1024 px and up): all sizes 16…512 @1x/@2x.
icns() {
  SET="$ROOT/zig-out/dist-build/AppIcon.iconset"
  rm -rf "$SET"; mkdir -p "$SET"
  for n in 16 32 128 256 512; do
    sips -z $n $n "$1" --out "$SET/icon_${n}x${n}.png" >/dev/null
    sips -z $((n * 2)) $((n * 2)) "$1" --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$2"
}
icns assets/icon.png "$APP/Contents/Resources/AppIcon.icns"

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
cp "$FFSRC/src/COPYING.LGPLv2.1" "$APP/Contents/Resources/licenses/FFmpeg-LGPL-2.1.txt"
cp "$FFSRC/lame/COPYING" "$APP/Contents/Resources/licenses/LAME-LGPL-2.txt"
FFVER=$(cat "$FFSRC/src/VERSION" 2>/dev/null || echo 9.0.1)
SRCURL=$(git remote get-url origin 2>/dev/null | sed 's/\.git$//' || true)
cat > "$APP/Contents/Resources/licenses/README.txt" <<EOF
OpenGorky — MIT. SDL3 — zlib (Contents/Frameworks).
FFmpeg $FFVER — LGPL 2.1+, and LAME 3.100 — LGPL 2+: linked statically into the program.
To relink it with your own (modified) FFmpeg or LAME: the program's complete source is the
relinkable form — ${SRCURL:-the OpenGorky repository}, version $VER; build the libraries with
scripts/build-ffmpeg.sh (or your own), then zig build -Dffmpeg-prefix=<build>/prefix (README).
Library sources: https://ffmpeg.org/releases/ffmpeg-$FFVER.tar.xz, https://lame.sourceforge.io/.
EOF

# Signature. SIGN_IDENTITY="Developer ID Application: …" signs with hardened runtime
# and a timestamp (needed for notarization); without it, ad-hoc (Gatekeeper asks on
# first launch: right click → "Open").
if [ -n "$SIGN_IDENTITY" ]; then
  SIGN="--force --timestamp --options runtime -s"
else
  SIGN="--force -s"; SIGN_IDENTITY=-
fi
# sign_app APP FILE… — the files inside, then the bundle.
sign_app() {
  app=$1; shift
  for f in "$@"; do codesign $SIGN "$SIGN_IDENTITY" "$f"; done
  codesign $SIGN "$SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
}
# zip_app APP ZIP — the zip; notarized (NOTARY_PROFILE: a keychain profile from
# `xcrun notarytool store-credentials`): the ticket stapled to the app and the zip rebuilt.
zip_app() {
  (cd "$(dirname "$1")" && ditto -c -k --keepParent "$(basename "$1")" "$2")
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$2" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$1"
    rm -f "$2"
    (cd "$(dirname "$1")" && ditto -c -k --keepParent "$(basename "$1")" "$2")
    spctl --assess --type execute -v "$1"
  fi
  du -sh "$1" "$2"
}

sign_app "$APP" "$APP"/Contents/Frameworks/*.dylib "$BIN" "$APP/Contents/MacOS/OpenGorky"
lipo -info "$BIN" "$APP"/Contents/Frameworks/*.dylib
zip_app "$APP" "$ROOT/zig-out/dist/OpenGorky-macos-$(lipo -archs "$BIN" | tr ' ' '-').zip"

# Level editor: its own bundle, the binary is the executable (FFmpeg inside: it plays
# videos and converts imports); SDL3 beside it.
EAPP="$ROOT/zig-out/dist/OpenGorky Editor.app"
rm -rf "$EAPP" "$ROOT"/zig-out/dist/OpenGorky-Editor-macos-*.zip
mkdir -p "$EAPP/Contents/MacOS" "$EAPP/Contents/Frameworks" "$EAPP/Contents/Resources/licenses"
EBIN="$EAPP/Contents/MacOS/opengorky-editor"
# shellcheck disable=SC2086
lipo -create $EDITORS -output "$EBIN"
cp "$APP"/Contents/Frameworks/*.dylib "$EAPP/Contents/Frameworks/"
SDL_REF=$(otool -L "$EBIN" | awk '/libSDL3/{print $1; exit}')
install_name_tool -change "$SDL_REF" @rpath/libSDL3.0.dylib "$EBIN"
if otool -L "$EBIN" | grep -E '^\s+/(opt|usr/local)/|libav|libsw|libmp3lame'; then
  echo "editor: references to libraries outside the package" >&2; exit 1
fi
if otool -l "$EBIN" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | grep -v '^@executable_path/../Frameworks$'; then
  echo "editor: unexpected rpath in the binary" >&2; exit 1
fi
icns assets/icon-editor.png "$EAPP/Contents/Resources/AppIcon.icns"
cat > "$EAPP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenGorky Editor</string>
  <key>CFBundleDisplayName</key><string>OpenGorky Editor</string>
  <key>CFBundleIdentifier</key><string>io.github.opengorky.editor</string>
  <key>CFBundleExecutable</key><string>opengorky-editor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF
cp LICENSE "$EAPP/Contents/Resources/licenses/OpenGorky-MIT.txt"
cp "$SDL_SRC/LICENSE.txt" "$EAPP/Contents/Resources/licenses/SDL3-zlib.txt"
cp third_party/clay/LICENSE.md "$EAPP/Contents/Resources/licenses/Clay-zlib.txt"
cp assets/fonts/OFL.txt "$EAPP/Contents/Resources/licenses/PTSans-OFL.txt"
cp assets/icons/LICENSE-lucide.txt "$EAPP/Contents/Resources/licenses/Lucide-ISC.txt"
cp "$APP/Contents/Resources/licenses/FFmpeg-LGPL-2.1.txt" "$APP/Contents/Resources/licenses/LAME-LGPL-2.txt" "$EAPP/Contents/Resources/licenses/"
{ echo "Clay — zlib. stb_truetype — public domain. PT Sans — SIL OFL 1.1. Lucide icons — ISC."
  cat "$APP/Contents/Resources/licenses/README.txt"; } > "$EAPP/Contents/Resources/licenses/README.txt"
sign_app "$EAPP" "$EAPP"/Contents/Frameworks/*.dylib "$EBIN"
lipo -info "$EBIN"
zip_app "$EAPP" "$ROOT/zig-out/dist/OpenGorky-Editor-macos-$(lipo -archs "$EBIN" | tr ' ' '-').zip"
