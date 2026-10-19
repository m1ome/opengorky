# OpenGorky

A free reimplementation of the **Gorky 17** engine (Odium, Metropolis Software, 1999) in Zig
0.17 + SDL3, for macOS, Linux and Windows, MIT. It aims to be an exact port. You need the original
game files (e.g. the GOG version); none are in this repository.

### Game files needed

| What | Why |
|---|---|
| `dat/` | levels, battles, `common/` graphics, sounds, voices, texts, scripts |
| `avi/` | videos and some music (`*.asf`) |
| `adjust.kdt` | engine tuning (weapons, effects, sound, camera); without it defaults are used |

Nothing else (`gorky17.exe`, DLLs, installer) is used. Original saves are not read. Other
editions on the same engine work too, e.g. the Russian «Горький-18»: file names are
case-insensitive and fonts follow the edition language (`string.tab` line 950).

## Build

Zig 0.17.0, SDL3 (`brew install sdl3` or `libsdl3-dev`) with `pkg-config`. Videos (MS-MPEG4 +
WMA/MP3) use FFmpeg libraries if found (`brew install ffmpeg` / `libav*-dev`);
`-Dffmpeg=false` falls back to an external `ffmpeg` program.

```sh
zig build        # zig-out/bin/gorky-tool, zig-out/bin/opengorky-viewer
zig build test
```

- Viewer: ReleaseFast with debug info by default (`-Dviewer-optimize=safe|debug`).
  ReleaseSmall is avoided: LLVM's MachineOutliner miscompiles on arm64 with Zig 0.17.
- gorky-tool: ReleaseSafe (`-Dtool-optimize=debug`). `-Dstrip=true` drops debug info.
- Gameplay is bit-identical across build modes and x86_64 (no `@setFloatMode`).

Checks: `zig build test`, `scripts/regress.sh <game dir>`, `scripts/fullgame.sh <game dir>`.

### Distribution

```sh
scripts/dist-macos.sh                # zig-out/dist/OpenGorky.app + zip (arm64 + x86_64)
scripts/dist-linux.sh [game dir]     # zig-out/dist/opengorky-linux-<arch>.tar.xz (Docker)
scripts/dist-windows.sh              # zig-out/dist/opengorky-windows-x86_64.zip (Docker, cross build)
```

- FFmpeg: `scripts/build-ffmpeg.sh` builds a minimal FFmpeg 9.0.1 (ASF, MS-MPEG4, WMA, MP3,
  swscale, swresample; ~2 MB) → `-Dffmpeg-prefix=…/prefix`. Shipped as replaceable shared
  libraries (LGPL).
- SDL3: macOS `scripts/build-sdl3.sh` (universal, Cocoa/Metal/CoreAudio) →
  `-Dsdl-prefix=…/prefix`; Linux uses Debian's.
- macOS: universal `.app`, ad-hoc signed (`SIGN_IDENTITY`/`NOTARY_PROFILE` for Developer ID
  signing and notarization); asks for the game folder on first run and stores it
  as `game_path` (or `OPENGORKY_GAME`). First launch: right-click → Open.
- Linux: `opengorky <game dir>`, icon, `.desktop`, `lib/` with `$ORIGIN/lib` rpath; built on
  Debian trixie (glibc 2.41+).
- Windows: cross-built with Zig (viewer) and mingw-w64 (FFmpeg), official SDL3 mingw DLL;
  `OpenGorky.exe` with no arguments starts the game and asks for the game folder once.
- CI: `.github/workflows/release.yml` builds all packages; a `v*` tag publishes a release.

Licences in the package: OpenGorky MIT, SDL3 zlib, FFmpeg LGPL 2.1+.

## Playing

```sh
zig build viewer -- <game dir> --play
```

| Key | |
|---|---|
| Esc | menu; skip video or scene; close windows |
| Space | next dialogue line; outside scenes toggle the panel |
| I / G | inventory / give |
| 1–6 | select hero |
| F | camera to the selected hero |
| W A S, arrows, screen edge | scroll (Shift faster) |
| Battle: Tab / Q / X or D / E or Enter / P | grid / next weapon / defend / end turn / push |
| Right button | cancel; in battle enter aim mode |
| F10 | scaling: integer / sharp / smooth |
| F11, Alt+Enter, Cmd+Enter | fullscreen |
| `` ` `` or F2 | debug console, only with `console = 1` or `--dev` |

- Saves: `~/Library/Application Support/OpenGorky/saves` (macOS),
  `$XDG_DATA_HOME/opengorky/saves` (Linux), `%APPDATA%\OpenGorky\saves` (Windows).
- `--no-sfx` / `OPENGORKY_NO_SFX=1`, `--mute` / `OPENGORKY_MUTE=1`.

Settings `opengorky.cfg` (macOS `~/Library/Application Support/OpenGorky/`, Linux
`~/.config/opengorky/`; missing keys are appended): `scaling` (integer/sharp/smooth),
`hires` (render models, shadows, effects at window resolution, up to 4×; 0 = 640×480),
`upscale` (xbr/off, UI sprites at `hires`), `fullscreen`, `debug` (debug labels only),
`log` (none/warn/info), `fps_limit` (60), `fps_background` (15), `pause_background` (1),
`console` (0), `game_path`.

## Resource viewer

```sh
zig build viewer -- <game dir> [01_port/sprite.dat] [--image N] [--shot out.png]
```

Without `--play`: `[` `]` archive, `↑` `↓` resource, `←` `→` frame, Space animate, `L` level
mode. `--shot` renders one frame and
exits (`--level`, `--scroll X,Y`, `--time MS`, `--hide-objects`).

## gorky-tool

```sh
gorky-tool list    <game>/dat/common/other.dat
gorky-tool extract <game>/dat/01_port/other.dat out/01_port
gorky-tool export  <game>/dat/01_port/sprite.dat png/01_port
gorky-tool check   <game>
gorky-tool scripts <game> [--api]
gorky-tool world   <game> 01_port 100
gorky-tool listen  <game> 01_port 30 port.wav 1700,200
gorky-tool play    <game> 01_port …
```

