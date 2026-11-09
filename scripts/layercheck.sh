#!/bin/sh
# Layer check: the core does not import the parsers
# (src/formats, save.zig) and the parsers do not import the core; the core imports neither
# the input layer (input.zig, input/) nor the renderer (render.zig, render/), and names no
# SDL, mouse or cursor (input and drawing are the clients'; a listed file may, for the reason given). Known violations are listed
# below with the phase that removes them; a new one, or a listed one gone (drop it
# from the list), fails. The viewer's core-facing code is checked the same way (only the
# listed viewer files read formats). The engine names no game (scripts/magiccheck.sh,
# run here). Prints OK or the offending files; non-zero exit on any.
#
#   scripts/layercheck.sh
cd "$(dirname "$0")/../src" || exit 1

# Core: the world model and behaviour. The loaders (loaders.zig, loaders/), composition
# (compose.zig, compose/) and the clients
# (viewer, editor, tool, console, render, modcheck) may import both; the core imports
# neither the parsers nor composition.
CORE="rules.zig fields.zig game.zig popup.zig outbox.zig actor.zig battle.zig combat.zig
inventory.zig state.zig world.zig scene.zig fx.zig effects.zig builtins.zig audio.zig core.zig
core rules battle combat inventory state world scene game builtins fx effects actor audio script"

# Known: core files importing the parsers (none any more).
KNOWN="
"

files=$(for p in $CORE; do
  if [ -d "$p" ]; then find "$p" -name '*.zig'; else echo "$p"; fi
done | sort -u)
found=$(for f in $files; do
  grep -qE '@import\("(\.\./)*formats(\.zig|/[a-z_0-9]+\.zig)"\)|@import\("(\.\./)*save\.zig"\)' "$f" && echo "$f"
done)
composed=$(for f in $files; do
  grep -qE '@import\("(\.\./)*compose(\.zig|/[a-z_0-9]+\.zig)"\)' "$f" && echo "$f"
done)
known=$(echo "$KNOWN" | awk 'NF { print $1 }' | sort -u)

# Input and render: the core draws nothing and handles no input.
clients=$(for f in $files; do
  grep -qE '@import\("(\.\./)*(input|render)(\.zig|/[a-z_0-9]+\.zig)"\)' "$f" && echo "$f"
done)
# Words of input and drawing in the core (case-sensitive: `ammoUsed` is no mouse).
CORE_WORDS="
core/classic.zig the exe's main menu names its cursor sprite (kursor.3df)
core/ui.zig      the UI record has the cursor sprite's field
rules/rows.zig   rule text: what the exe's cursor shows over an exit
"
wknown=$(echo "$CORE_WORDS" | awk 'NF { print $1 }' | sort -u)
wfound=$(for f in $files; do
  grep -qE 'SDL|[Mm]ouse|(^|[^_[:alnum:]])[Cc]ursor' "$f" && echo "$f"
done)

FAILED=0
for f in $composed; do echo "FAIL core imports composition: $f"; FAILED=1; done
for f in $clients; do echo "FAIL core imports input or render: $f"; FAILED=1; done
for f in $wfound; do
  echo "$wknown" | grep -qx "$f" || { echo "FAIL core names SDL, mouse or cursor: $f"; FAILED=1; }
done
for f in $wknown; do
  echo "$wfound" | grep -qx "$f" || { echo "FAIL core words: fixed, drop from the list: $f"; FAILED=1; }
done
for f in $found; do
  echo "$known" | grep -qx "$f" || { echo "FAIL core imports parsers: $f"; FAILED=1; }
done
for f in $known; do
  echo "$found" | grep -qx "$f" || { echo "FAIL fixed, drop from the list: $f"; FAILED=1; }
done
# Parsers: only the shared base (num, vec, image, the script values' number rules).
for f in formats.zig formats/*.zig; do
  grep -oE '@import\("\.\./[a-z_]+\.zig"\)' "$f" | grep -vE '"\.\./(num|vec|image|script)\.zig"' | sed "s|^|FAIL parser imports core: $f: |" | grep . && FAILED=1
  grep -nE '@import\("\.\./script\.zig"\)\.[a-z_]+' -o "$f" | grep -v '\.value$' | sed "s|^|FAIL parser imports core: $f:|" | grep . && FAILED=1
done
# The parsers outside formats/ and the base's image: any import but the base.
for f in save.zig image.zig; do
  grep -oE '@import\("[a-z_./]+\.zig"\)' "$f" | grep -vE '"(\.\./)?(num|vec|script)\.zig"' | sed "s|^|FAIL parser imports core: $f: |" | grep . && FAILED=1
  grep -nE '@import\("(\.\./)?script\.zig"\)\.[a-z_]+' -o "$f" | grep -v '\.value$' | sed "s|^|FAIL parser imports core: $f:|" | grep . && FAILED=1
done
# The two reader/writer pairs do not mix. The OG reader and writer
# (loaders/ogs.zig, compose/og/) import only OG Script, the core and loaders/assets.zig:
# nothing Classic-only, directly or as a member of formats.zig, core.zig or script.zig, nor compose.zig (it opens
# the Classic world). The Classic reader does not import them. Only the converter
# (compose/convert*, script/classic/ogsify.zig) and the clients see both.
CLASSIC_ONLY='^(script/classic/|script/(lexer|parser|ast)\.zig$|core/classic\.zig$|formats/(archive|vars|assigns|strtab|dialog|scriptlet|lang|adjust)\.zig$|loaders/world\.zig$|loaders/classic(\.zig|/))'
OG_ONLY='^(loaders/ogs(\.zig|/)|compose/og/)'
# Files $2.. importing what matches $1: "file: import" per line.
imports() {
  re=$1; shift
  [ $# = 0 ] && return
  awk -v re="$re" '
function norm(p,  n, a, i, o, k) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "..") k--; else if (a[i] != "." && a[i] != "") o[++k] = a[i]
  }
  p = o[1]; for (i = 2; i <= k; i++) p = p "/" o[i]
  return p
}
function dir(f) { return f ~ /\// ? substr(f, 1, match(f, /\/[^\/]*$/)) : "" }
{
  s = $0
  while (match(s, /@import\("[^"]+\.zig"\)(\.[a-z_]+)?/)) {
    m = substr(s, RSTART + 9, RLENGTH - 9); s = substr(s, RSTART + RLENGTH)
    p = m; sub(/".*/, "", p)
    mem = ""; if (m ~ /"\)\./) { mem = m; sub(/.*"\)\./, "", mem) }
    t = norm(dir(FILENAME) p)
    if ((t == "formats.zig" || t == "core.zig") && mem != "") t = substr(t, 1, length(t) - 4) "/" mem ".zig"
    if (t == "script.zig" && mem == "classic") t = "script/classic/"
    if (t == "script.zig" && mem ~ /^(lexer|parser|ast)$/) t = "script/" mem ".zig"
    if (t == "compose.zig" && mem ~ /^og/) t = "compose/og/" mem
    if (t == "loaders.zig" && mem != "") t = "loaders/" mem ".zig"
    if (t ~ re) print FILENAME ": " t
  }
}' "$@"
}
og_files=$( { [ -f loaders/ogs.zig ] && echo loaders/ogs.zig; find loaders/ogs compose/og -name '*.zig'; } | sort)
# shellcheck disable=SC2086
imports "$CLASSIC_ONLY" $og_files | sed 's/^/FAIL OG reader or writer imports Classic: /' | grep . && FAILED=1
# shellcheck disable=SC2086
imports "$OG_ONLY" loaders/world.zig loaders/classic.zig loaders/classic/entities.zig $(find script/classic -name '*.zig' ! -name ogsify.zig | sort) | sed 's/^/FAIL Classic reader imports the OG pair: /' | grep . && FAILED=1
# The viewer (a client over composition): its core-facing code — the world, battle, effects,
# depth and actor layers — takes core records only. These files read formats themselves
# (the launch, decoding pictures and fonts to draw, archives of sprites); any other viewer
# file naming `og.formats.<x>` fails, and so does a listed one that
# no longer does (drop it from the list).
VIEWER_FORMATS="
viewer/app/launcher.zig   launch: config pictures, the language
viewer/app/packages.zig   launch: mod packages' manifests
viewer/app/run.zig        launch: manifest, archives
viewer/app/viewer.zig     archive browser, screenshots
viewer/battle/gui.zig     drawing: fonts, string.tab
viewer/gui.zig            drawing: panel sprites, digit and message fonts
viewer/gui/panel.zig      drawing: fonts, string.tab
viewer/gui/safe.zig       drawing: the safe's sprites and font
viewer/gui/short.zig      drawing: string.tab labels
viewer/gui/stats.zig      drawing: string.tab labels
viewer/gui/text.zig       drawing: fonts
viewer/inventory.zig      drawing: inventory sprites, fonts, string.tab
viewer/inventory/draw.zig drawing: fonts
viewer/level.zig          drawing: level sprites (frames, z-frames)
viewer/level/overlay.zig  drawing: fonts
viewer/media/gfx.zig      drawing: picture decoders
viewer/menu.zig           drawing: menu sprites, fonts, string.tab
viewer/menu/font.zig      drawing: the menu's 3D font
viewer/menu/saves.zig     save thumbnails
"
vknown=$(echo "$VIEWER_FORMATS" | awk 'NF { print $1 }' | sort -u)
vfound=$(cd .. && for f in $(find src/viewer -name '*.zig' | sort); do
  grep -qE 'og\.formats\.[a-z_0-9]+' "$f" && echo "${f#src/}"
done)
for f in $vfound; do
  echo "$vknown" | grep -qx "$f" || { echo "FAIL viewer core-facing code reads formats: $f"; FAILED=1; }
done
for f in $vknown; do
  echo "$vfound" | grep -qx "$f" || { echo "FAIL viewer: fixed, drop from the list: $f"; FAILED=1; }
done
# Tests: every file with a test is named by `_ = x;` in a test block reachable from a test
# root (src/root.zig, the build.zig list, editor/transcode.zig, editor/font.zig), so its tests do not hang on
# the file being analyzed by chance. Known exceptions below; a new one, or a listed one
# gone (drop it from the list), fails.
TESTS_KNOWN="
battle/weapon_class.zig  runs only because battle.zig's users analyze it (add to battle.zig)
effects/projectile.zig   runs only because effects.zig's users analyze it
formats/text.zig         runs only because its users analyze it
fx/place.zig             runs only because its users analyze it
script/object.zig        runs only because its users analyze it
editor/text.zig          runs only because the editor test roots analyze it
editor/app_reload.zig    imports app.zig (SDL): never runs
editor/assettree.zig     imports app.zig (SDL): never runs
editor/dlgedit.zig       imports app.zig (SDL): never runs
editor/musicpage.zig     imports app.zig (SDL): never runs
editor/paint.zig         SDL: never runs
editor/paint_areas.zig   SDL: never runs
"
tknown=$(echo "$TESTS_KNOWN" | awk 'NF { print $1 }' | sort -u)
roots="root.zig editor/transcode.zig editor/font.zig $(grep '}) |p| {' ../build.zig | grep -oE '"src/[^"]+\.zig"' | sed 's|"src/||; s|"$||' | tr '\n' ' ')"
# One awk over all files (not xargs: a split batch would lose the edges).
tfound=$(awk -v roots="$roots" '
function norm(p,  n, a, i, o, k) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "..") k--; else if (a[i] != "." && a[i] != "") o[++k] = a[i]
  }
  p = o[1]; for (i = 2; i <= k; i++) p = p "/" o[i]
  return p
}
function dir(f) { return f ~ /\// ? substr(f, 1, match(f, /\/[^\/]*$/)) : "" }
FNR == 1 { intest = 0; ns = "" }
/^(pub )?const [A-Za-z_0-9]+ = struct \{/ { ns = $0; sub(/^(pub )?const /, "", ns); sub(/ =.*/, "", ns); ns = ns "." }
/^\};/ { ns = "" }
/^(    )?(pub )?const (@"[a-z]+"|[A-Za-z_0-9]+) = @import\("[^"]+\.zig"\);/ && (ns != "" || $0 !~ /^ /) {
  name = $0; sub(/^ *(pub )?const /, "", name); sub(/ =.*/, "", name); if ($0 ~ /^ /) name = ns name
  p = $0; sub(/.*@import\("/, "", p); sub(/".*/, "", p)
  imp[FILENAME, name] = norm(dir(FILENAME) p)
}
/^test ("|[A-Za-z_@])/ { hastest[FILENAME] = 1 }
/^test \{/ { intest = 1; next }
intest && /^\}/ { intest = 0 }
intest && /^    _ = / {
  r = $0; sub(/^    _ = /, "", r); sub(/;.*/, "", r)
  if (r ~ /^@import\("/) { sub(/^@import\("/, "", r); sub(/".*/, "", r); edge[FILENAME, ++ne[FILENAME]] = "@" norm(dir(FILENAME) r) }
  else edge[FILENAME, ++ne[FILENAME]] = r
}
END {
  n = split(roots, q, " "); for (i = 1; i <= n; i++) seen[q[i]] = 1
  for (h = 1; h <= n; h++) {
    f = q[h]
    for (j = 1; j <= ne[f]; j++) {
      t = edge[f, j]
      if (substr(t, 1, 1) == "@") t = substr(t, 2)
      else if ((f, t) in imp) t = imp[f, t]
      else { m = split(t, part, "."); t = f; for (k = 1; k <= m; k++) if ((t, part[k]) in imp) t = imp[t, part[k]]; if (t == f) t = "" }
      if (t != "" && !seen[t]) { seen[t] = 1; q[++n] = t }
    }
  }
  for (f in hastest) if (!seen[f]) print f
}' $(find . -name '*.zig' | sed 's|^\./||') | sort)

for f in $tfound; do
  echo "$tknown" | grep -qx "$f" || { echo "FAIL tests not reachable from a test root (add \`_ = x;\` to a test block): $f"; FAILED=1; }
done
for f in $tknown; do
  echo "$tfound" | grep -qx "$f" || { echo "FAIL tests: fixed, drop from the list: $f"; FAILED=1; }
done
# The engine names no game: scripts/magiccheck.sh.
sh ../scripts/magiccheck.sh || FAILED=1
[ $FAILED = 0 ] && echo "OK   layers ($(echo "$known" | grep -c .) known violations; viewer: $(echo "$vknown" | grep -c .) files read formats; core: no input or render, $(echo "$wknown" | grep -c .) files name a cursor; tests: $(echo "$tknown" | grep -c .) files off the test roots)"
exit $FAILED
