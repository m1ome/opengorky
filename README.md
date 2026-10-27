<p align="center">
  <img src="assets/icon-256.png" width="128" alt="OpenGorky icon">
</p>

<h1 align="center">OpenGorky</h1>

<p align="center">
  An open-source reimplementation of the <b>Gorky 17</b> engine<br>
  (<i>Odium</i> in North America, Metropolis Software, 1999)<br>
  for macOS, Linux and Windows, written in Zig + SDL3.
</p>

<p align="center">
  <a href="../../releases/latest"><b>Download</b></a> ·
  <a href="#playing">Playing</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#building">Building</a> ·
  <a href="#tools">Tools</a>
</p>

---

OpenGorky aims to be an **exact port**: the battle rules, AI, scripts, effects and timings are
reconstructed from the original `gorky17.exe`, and gameplay is bit-identical across build
modes and CPU architectures. On top of that it runs natively on modern systems, at high
resolution, with fullscreen scaling and a modern save location.

> **You need the original game files** (for example the GOG version). None are included in
> this repository or in the release packages.

## Download

Prebuilt packages are on the [latest release](../../releases/latest) page:

| Platform | Package | How to run |
|---|---|---|
| macOS 13+ (Apple Silicon and Intel) | `OpenGorky-macos-x86_64-arm64.zip` | Unzip and open `OpenGorky.app`. It asks for the game folder once. |
| Windows 10+ (x86_64) | `opengorky-windows-x86_64.zip` | Unzip and run `OpenGorky.exe`. It asks for the game folder once. SmartScreen may warn: **More info → Run anyway**. |
| Linux x86_64 / aarch64 (glibc 2.41+) | `opengorky-linux-<arch>.tar.xz` | Unpack and run `./opengorky <game dir>`. An icon and a `.desktop` file are included. |

The level editor is a separate download: `OpenGorky-Editor-macos-x86_64-arm64.zip`
(`OpenGorky Editor.app`), `opengorky-editor-windows-x86_64.zip` (`OpenGorkyEditor.exe`),
`opengorky-editor-linux-<arch>.tar.xz` (`./opengorky-editor`). It starts empty: choose a
copy of the game folder in its Settings tab.

### Game files

Point OpenGorky at the folder of your Gorky 17 installation. It uses only:

| What | Why |
|---|---|
| `dat/` | levels, battles, `common/` graphics, sounds, voices, texts, scripts |
| `avi/` | videos and some music (`*.asf`) |
| `adjust.kdt` | engine tuning (weapons, effects, sound, camera); without it defaults are used |

Nothing else (`gorky17.exe`, DLLs, installer) is used. Original saves are not read.

Other editions on the same engine work too, e.g. the Russian «Горький-18»: file names are
case-insensitive and fonts follow the edition language.

## Playing

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
| F10 | scaling: integer / sharp / smooth / stretch / adaptive / stretch-blur |
| F11, Alt+Enter, Cmd+Enter | fullscreen |
| `` ` `` or F2 | debug console, only with `console = 1` or `--dev` |

## Configuration

### Where files live

| | Settings `opengorky.cfg`, mods | Saves |
|---|---|---|
| macOS | `~/Library/Application Support/OpenGorky/` | `~/Library/Application Support/OpenGorky/saves/` |
| Linux | `$XDG_CONFIG_HOME/opengorky/` (default `~/.config/opengorky/`) | `$XDG_DATA_HOME/opengorky/saves/` (default `~/.local/share/opengorky/saves/`) |
| Windows | `%APPDATA%\OpenGorky\` | `%APPDATA%\OpenGorky\saves\` |

### `opengorky.cfg`

A plain text file with `key = value` lines; `#` starts a comment. It is created with
defaults and explanations on the first launch. If a newer version adds keys, the file is
rewritten on startup with them added: your values are kept, your own comments are not.
Unknown keys and bad values are ignored. Scaling (F10) and fullscreen toggles made in the
game are saved back to it.

```ini
scaling = integer
hires = 1
upscale = xbr
fullscreen = 0
fps_limit = 60
fps_background = 15
pause_background = 1
log = warn
debug = 0
console = 0
game_path = /path/to/Gorky 17
```

| Key | Default | Meaning |
|---|---|---|
| `scaling` | `integer` | How the 640×480 frame fills the window: `integer` — integer zoom, crisp pixels, may leave borders; `sharp` — fill the window with sharp pixels; `smooth` — fill the window, smoothed; `stretch` — stretch to the whole window or screen with no borders (4:3 is distorted on wide screens); `adaptive` — the world fills the window: large locations show more at the sides, battles and rooms are zoomed in to fill the width (top and bottom scroll with the mouse at the edges), the UI stays in the middle, the menu and inventory stand over a blurred copy; `stretch-blur` — 4:3 in the middle over a blurred, darkened copy of the frame instead of black borders |
| `hires` | `1` | `1` — models, shadows and effects are drawn at window resolution (backgrounds and UI keep their pixels); `0` — 640×480 like the original |
| `upscale` | `xbr` | UI, icons and portraits with `hires`: `xbr` — smoothed edges (xBR); `off` — the original pixels, just larger |
| `fullscreen` | `0` | Start in fullscreen (in the game: F11, Alt+Enter, Cmd+Enter, Ctrl+Cmd+F) |
| `fps_limit` | `60` | Frame cap in the focused window; `0` — display rate (vsync). The world always runs at 30 ticks per second, like the original |
| `fps_background` | `15` | Frame cap when the window is not focused; `0` — same as focused. A minimized or fully covered window is not drawn at all |
| `pause_background` | `1` | Pause the game and sound when the window loses focus or is minimized |
| `log` | `warn` | Terminal messages: `none`, `warn`, `info` |
| `debug` | `0` | Debug overlays: battle status line, health bars, F1 line |
| `console` | `0` | Developer console (`` ` `` or F2) with debug commands: heal, win the battle, give items… |
| `game_path` | empty | The game folder, used when none is given at launch. Set automatically on the first launch with a path or after picking the folder |

On/off keys accept `1`/`0`, `on`/`off` or `true`/`false`.

### Environment variables

| Variable | Effect |
|---|---|
| `OPENGORKY_SAVES` | Saves folder instead of the default one |
| `OPENGORKY_MODS` | Mods folder instead of `<settings folder>/mods` |
| `OPENGORKY_MUTE` | Set (to any value): no sound, as `--mute` |
| `OPENGORKY_NO_SFX` | Set: no sound effects or voices, music only, as `--no-sfx` |
| `OPENGORKY_GAME` | macOS app: the game folder, overriding `game_path` |

### Command line

```sh
opengorky-viewer <game dir> --play [options]   # Linux: opengorky <game dir> [options]
```

| Option | Effect |
|---|---|
| `--mute`, `--no-sfx` | No sound; no sound effects or voices |
| `--fps N` | Frame cap instead of `fps_limit` (`0` — display rate) |
| `--hires N` | Fixed frame detail 1–4× instead of following the window size |
| `--upscale xbr\|off` | Instead of the `upscale` setting |
| `--window W,H` | Initial window size in points (default 1280,960) |
| `--dev` | Enable the developer console even with `console = 0` |

### Mods

Scripts and objects placed in `<game>/mods` or `<config dir>/mods` (or `$OPENGORKY_MODS`)
are looked up before the game archives, so levels, fighters and weapons can be changed or
added without touching the original files. Custom fighters use the generic class
(`classType = 100`): attacks, AI and resistances come from their `.ftr`/`.wpn` fields.

## Building

Requirements: [Zig 0.17.0](https://ziglang.org/download/), SDL3 and `pkg-config`
(`brew install sdl3` / `apt install libsdl3-dev`). Videos (MS-MPEG4 + WMA/MP3) and the
editor's video and music imports use the FFmpeg libraries if found (`brew install ffmpeg` /
`libav*-dev`, linked as shared libraries; imports need `libmp3lame` in that FFmpeg).
`-Dffmpeg-prefix=<dir>/prefix` links our own static build instead (`scripts/build-ffmpeg.sh`,
as the packages do). With `-Dffmpeg=false` videos play through an external `ffmpeg` program
in `PATH` and the editor cannot import.

```sh
zig build                             # zig-out/bin/opengorky-viewer, zig-out/bin/gorky-tool
zig build test
zig build viewer -- <game dir> --play # build and play
```

- The viewer builds ReleaseFast with debug info by default (`-Dviewer-optimize=safe|debug`).
  ReleaseSmall is avoided: LLVM's MachineOutliner miscompiles on arm64 with Zig 0.17.
- gorky-tool builds ReleaseSafe (`-Dtool-optimize=debug`). `-Dstrip=true` drops debug info.
- Gameplay does not depend on the build mode or the CPU (no `@setFloatMode`).

Regression checks with the game data: `scripts/regress.sh <game dir>`,
`scripts/fullgame.sh <game dir>` (full playthrough), `scripts/linux/check.sh <game dir>`
(everything in a Linux container).

### Packages

```sh
scripts/dist-macos.sh            # zig-out/dist/OpenGorky.app + zip (universal arm64 + x86_64)
scripts/dist-linux.sh [game dir] # zig-out/dist/opengorky-linux-<arch>.tar.xz (Docker)
scripts/dist-windows.sh          # zig-out/dist/opengorky-windows-x86_64.zip (Docker, cross build)
```

Each script also packs the level editor separately from the same build: `OpenGorky
Editor.app` + `OpenGorky-Editor-macos-<arch>.zip`, `opengorky-editor-linux-<arch>.tar.xz`,
`opengorky-editor-windows-x86_64.zip` — the editor, SDL3 and licenses.

- **FFmpeg**: `scripts/build-ffmpeg.sh` builds static FFmpeg 9.0.1 libraries (all decoders,
  demuxers and parsers; MS-MPEG4 v3, WMA v1 and MP3 encoders with LAME 3.100; ASF and MP3
  muxers; swscale, swresample; LGPL, no GPL or non-free parts), and `-Dffmpeg-prefix` links
  them into the viewer and the editor: videos play and imports convert in-process
  (`src/editor/transcode.zig`), no FFmpeg files or programs are shipped. Sources are
  checked by SHA-256.
- **SDL3**: macOS uses its own universal build (`scripts/build-sdl3.sh`), Linux Debian's,
  Windows the official mingw release.
- **macOS**: ad-hoc signed; set `SIGN_IDENTITY` and `NOTARY_PROFILE` for Developer ID
  signing and notarization. An ad-hoc build downloaded from the internet is blocked by
  Gatekeeper ("Apple could not verify…"): open it via System Settings → Privacy & Security →
  **Open Anyway**, or `xattr -dr com.apple.quarantine OpenGorky.app`.
- **Linux**: built on Debian trixie, libraries in `lib/` with an `$ORIGIN/lib` rpath.
- **Windows**: the viewer is cross-built with Zig, FFmpeg with mingw-w64.
- **CI**: `.github/workflows/release.yml` builds all packages; pushing a `v*` tag, or
  running it manually with a tag (`gh workflow run release.yml -f tag=v0.1.1`), publishes
  a GitHub release.

## Tools

### Resource viewer

```sh
zig build viewer -- <game dir> [01_port/sprite.dat] [--image N] [--shot out.png]
```

Without `--play`: `[` `]` archive, `↑` `↓` resource, `←` `→` frame, Space animate, `L` level
mode. `--shot` renders one frame and exits (`--level`, `--scroll X,Y`, `--time MS`,
`--hide-objects`).

### gorky-tool

```sh
gorky-tool list    <game>/dat/common/other.dat           # archive contents
gorky-tool extract <game>/dat/01_port/other.dat out/01_port
gorky-tool export  <game>/dat/01_port/sprite.dat png/01_port
gorky-tool check   <game>                                # decode all game data
gorky-tool sortdat <game>                                # repair archives saved by older editors (order, times, script marks)
gorky-tool scripts <game> [--api]
gorky-tool world   <game> 01_port 100
gorky-tool listen  <game> 01_port 30 port.wav 1700,200
gorky-tool play    <game> 01_port …                      # headless play scenarios
```

### Level editor (work in progress)

```sh
zig build editor -- [<game dir>] [--level NAME] [--lang en|ru] [--shot out.png]
```

The interface is in English or Russian (Settings tab, or `--lang`). Without a game folder
the editor starts empty; choose one in the Settings tab ("Choose…"), which reopens the
editor on it. The language and the folder (chosen there or given on the command line) are
kept in `editor.cfg` in the settings folder.

Edits the game folder in place (its `.dat` archives), so work on a copy. Every edit in every
tab goes into one undo stack (`Ctrl+Z`) and one save (`Ctrl+S`); only the numbers and lines
an edit touches change, the rest of every script stays byte for byte.

- **Battles / Locations**: the level with its battle grid and objects (wheel zooms, drag empty
  space pans, `F` fits). In battles drag an enemy, hero start, barrel or prop to move it (red
  tiles: blocked or occupied), `Delete` removes it. "Add enemy" copies the first fighter of a
  class (its `.ftr` and weapons under a new name such as `sphinx_1`) onto the first free tile.
  A selected enemy's parameters are edited for this enemy only (lines after the class
  `#include` in its `.ftr`/`.wpn`, × drops them) or for its whole class.
- **Enemies**: enemy classes (`classes\ft_*.ss` in `dat/common/other.dat`): parameters,
  resistances (shown only: the exe's table by `nameID`), the damage of their weapons (`wp_*.ss`), look (`act_*.ss`: model and
  animations; the class keeps its own `nameID`, so name and special rules stay) and "Make a
  copy" — a new class that battles can then add.
- **Items**: weapon, ammo and item classes (`cw_*`, `ca_*`, `ci_*`): numbers, icon,
  model in hand, damage type, behaviour class and ammo; recharge turns and effect on hit are
  shown only (the exe sets them by the behaviour class).
- **Heroes**: starting values of the heroes (`gamestart\*.hro` and those joining later).

"Edit…" by an icon (items, enemy report icons, heroes' portraits) opens its sprite frame by
frame: a frame from a PNG or to one, and pixel editing zoomed in (pencil, eraser,
eyedropper on the right button, the sprite's colours); a stroke is one step, Save writes
it in the game's format. An enemy's kill icon in the battle report comes from the exe's table by nameID (not from
`spriteFile`): the page shows it and replaces or edits that very file; a nameID missing
from the table (the shoggoth's) has none. An enemy or hero page has four parts: its values, the model (drag it to turn it), its
animations and the chosen one's frame sounds. The edges between panes and lists drag to
resize, and the sizes are kept in `editor.cfg`. Tabs keep their state: the battle and the location
open stay open each, and each of enemies, items and heroes shows the entry left there.
Under it are the animation's frame sounds (`gfx_3d\<model>.ani`, shared by every look with
that model): they play with the preview as in the game, and each can be swapped for another
`sound.dat` sound, moved by frames or removed, and new ones added; the `.ani` is written back
in the game's format. The Sounds tab lists `common/sound.dat` with search: listening, which
animation frames play each, saving one as WAV, and importing a WAV or MP3 of one's own —
converted to the game's own format (PCM 16-bit mono 22050 Hz) to put on frames. Enemy
classes no battle of the game has but able to strike (the shogoth) can be added too: the
editor builds the fighter as the battles' own and gives it a close attack
(`wp_cutterpillshort.ss`), shown on the class page. A battle enemy's weapon class can be swapped under its damage in the
parameters (another `wp_*.ss` of the same reach, close or long; that enemy's `.wpn` only). On
the enemy class page the same swap goes to every enemy of the class in every battle (each
one's `.wpn`), and enemies added later copy the new weapon. A weapon's page shows a hero of the party striking with it (the
exe's strike by nameID, two-handed ones in the two-handed stance, the weapon in hand) with
that animation's frame sounds, and in place of the model its damage zone: the exe's pattern
for its `classType` (following the class picked) — the damage percent at each tile around
the shooter, which tiles an obstacle before them cuts off, a wide ray's second tiles (2×2
fighters) and the tiles each hit covers around the target. The enemies' own attacks
(`wp_*.ss`) are listed under Items as "Enemy attacks": each page edits its damage, damage
type, class and other values and shows the same zone, which enemy classes hold it and the
battles using it. Enemy weapons on the class page show the zone on a click, and the tick of
their hit.
"New texture from PNG" gives an enemy look or an item model a new texture: a copy of the
model wearing it (the original stays); "Texture to PNG" writes the original to paint over,
since the model's UV layout stays. Items also take a new icon from a PNG. In a level, a right
click on a box edits its contents (item classes with amounts; the change applies to a new
game), and in a battle a right click elsewhere opens a menu to add there an enemy of the
picked class, an obstacle (wooden or metal crate, a barrel with its blast weapon), an item
box or a decoration (`obs_a_*.s` props by PlaceCombatActor), all written as the battles'
own files. Obstacles and props show which way they face, and a selected one has turn handles
(±45°: PlaceActor's direction is in eighths of a turn, a prop's angle in degrees). Fighters
have none: the battle start turns each to its nearest opponent, to a grid side. Lists
of classes to add have a search field matching ids and game names. The grid is numbered
along its edges as the scripts count tiles (x yellow, y cyan). Reinforcements (the
AIEnemyAppear calls of the level's CombatEnemiesAppear, run after each enemy turn) are
shown grey with a line from where they walk in; dragging one moves its `AIFreeTile`
checks too. When they come and their flags stay in the level script. An enemy's right-click menu turns it
into one walking in at the battle start (`AIEnemyAppear` from just past the nearest grid
edge, as the battles' own) and back into one standing on its tile (`PlaceActor`). Removing one from the battle deletes its files too
when no script names it any more, and a game fighter is disabled in `restore()` instead
(`DisableObject`, as the battles do): the original makes an object of every script file
and brings an unplaced fighter into the battle, crashing. Fighters left so by older
versions are listed above the objects with a button to take them out.

In a location, a right click on the floor puts a new box there, made as the game's own:
`<name>.itm` and `variables\<name>.var`. The Scenes tab lists the cutscenes, what each
changes in the game (heroes joining or leaving, objects removed, levels loaded) and where
level scripts start it. A scene can be shortened — its dialogue, pauses, fades, animations,
camera and sound commented out, as a skip runs it — so only its changes stay; or a start can
be turned off: the call, with the `if (…) { … }` around it, is commented out, which drops the
scene's changes too (turning off `museum-medusa_crazy` keeps Medusa in the party). The
editor's comments start with `//#ed`, so turning things on again restores the lines exactly.

Areas (triggers, exits) are drawn on locations, filled when they are more than a point; a
right click on one shows its own script and every block of the level's scripts naming it,
each can be turned off and on. Boxes have a right-click menu (edit contents, delete; also on
the object list). The History tab lists every edit of the session, saved ones too (the last save marked): a
click shows what a step changed, "Return here" (on a second click) undoes the steps after
it, also past a save — the next save writes the files back. One Save writes everything,
the code window's text included.
Any script (level, area, object, class, hero, scene) opens in a code window with
highlighting, completion and a syntax check by the engine's parser. A function taken from
the completion list comes with sample arguments, Tab moving through them; inside a call its
parameters show above the line. "Functions (F1)" lists all 109 the engine runs (every one
the game's scripts call) with parameters and what each does, a click inserting it; Save (Ctrl+S, also in the window) puts it into the edits and
writes it, keeping the file's encoding. Boxes
on locations can be dragged (their `.var` position and walk point). Heroes have a starting
inventory window. Closing the editor with unsaved edits asks first.

Everything the editor writes is the game's own script syntax and formats, valid for the
original `gorky17.exe` too, and behaves the same there. What the exe keeps to itself
(names by `nameID` in string.tab, monster resistances, effects and recharge by weapon class)
is shown but not edited.

## License

OpenGorky is [MIT](LICENSE). Release packages also contain SDL3 (zlib, a shared library) and
FFmpeg (LGPL 2.1+) with LAME (LGPL 2+), linked statically into the viewer and the editor;
their licenses are in the package. To relink with your own or a modified FFmpeg/LAME, build
from this repository's source (the relinkable form; the package's `licenses/README.txt` names
the version): `scripts/build-ffmpeg.sh` or your own build of those libraries, then
`zig build -Dffmpeg-prefix=<build>/prefix` (see Building).
Bundled decoders: [stb_image](https://github.com/nothings/stb) and
[dr_libs](https://github.com/mackron/dr_libs) (public domain / MIT-0). The editor also bundles
[Clay](https://github.com/nicbarker/clay) (zlib, `third_party/clay/LICENSE.md`),
stb_truetype (public domain), the PT Sans font (SIL OFL 1.1, `assets/fonts/OFL.txt`) and
[Lucide](https://lucide.dev) icons (ISC, `assets/icons/LICENSE-lucide.txt`).

Gorky 17 and Odium are trademarks of their respective owners. This project is not
affiliated with or endorsed by them and contains no original game content.
