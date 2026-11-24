#!/bin/sh
# Regression suite: short gorky-tool play scenarios through places that broke
# before. Each scenario prints OK or FAIL; the
# exit code is non-zero if any failed.
#
# No saves needed: each scenario starts with the full-playthrough steps
# (scripts/fullgame.sh) up to the place it needs, then does what a player does.
# play itself fails on a loop (the same scene or battle 3+ times in a row — "LOOP").
#
#   scripts/regress.sh <game dir> [scenario…]     (no scenario: all, side by side)
# $GORKY_TOOL — another gorky-tool, $VIEWER — another viewer, $EDITOR_BIN — another editor.
# The logs carry the game's 1251 texts: byte tools (a UTF-8 sed stops at them, a check reads nothing).
export LC_ALL=C
G=${1:?game dir}
shift
cd "$(dirname "$0")/.."
# Without $GORKY_TOOL: the optimized build, made here (scripts/release.sh).
. scripts/release.sh
TOOL=$GORKY_TOOL
# The viewer and the editor from the same build as the tool.
VIEWER=${VIEWER:-$(dirname "$TOOL")/opengorky-viewer}
EDITOR_BIN=${EDITOR_BIN:-$(dirname "$TOOL")/opengorky-editor}
TMP=${TMPDIR:-/tmp}/opengorky-regress.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Full-playthrough steps as one line (after "01_port").
STEPS=$(sed -n '/play \$G 01_port/,$p' scripts/fullgame.sh | tr -d '\\\n' | sed 's/.*play \$G 01_port//')

# prefix STEP [N] — full-playthrough steps up to and including the N-th (default
# first) occurrence of STEP.
prefix() {
  echo "$STEPS" | tr -s ' ' '\n' | awk -v m="$1" -v n="${2:-1}" 'NF { print; if ($0 == m && ++k == n) exit }' | tr '\n' ' '
}

# play NAME STEPS… — run into $TMP/NAME.log; a non-zero play exit (loop) is a failure.
play() {
  name=$1
  shift
  # shellcheck disable=SC2068
  "$TOOL" play "$G" 01_port $@ >"$TMP/$name.log" 2>&1
}

FAILED=0
ok() { echo "OK   $1"; }
fail() {
  echo "FAIL $1: $2"
  echo "     log tail:"
  tail -n 15 "$TMP/$1.log" | sed 's/^/     | /'
  FAILED=1
}
count() { grep -c -e "$2" "$TMP/$1.log"; }

# sdl_env — no display in the Linux container: offscreen video, dummy audio.
sdl_env() {
  if [ "$(uname)" = Linux ]; then
    SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-offscreen}
    SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
    export SDL_VIDEODRIVER SDL_AUDIODRIVER
  fi
}

# view NAME INPUT [ARCHIVE] — hidden viewer `--play` run into $TMP/NAME.log.
view() {
  sdl_env
  OPENGORKY_SAVES="$TMP/saves" OPENGORKY_MUTE=1 "$VIEWER" "$G" "${3:-01__port_park/sprite.dat}" --level --heroes --play \
    --input "$2" >"$TMP/$1.log" 2>&1
}

# 1. Crazy Medusa (museum-medusa_crazy, battle 03__museum_medusa'sdeath): after
#    the win the scene and battle do not repeat — also after leaving and walking into
#    the trigger area again — Medusa is not in the party, and the party leaves. The full
#    playthrough never reaches this scene — it gets to the observatory before Medusa
#    joins (e35cee3, 5282029, abb847c). `medusaload`: the same with a full save/load
#    after every switch (Medusa still in the party before the scene, gone after).
medusa_run() {
  name=$1
  shift
  play "$name" oncecheck "$@" $(prefix goto:cutscene_medusa) scene \
    goto:exit2ships wait:60 goto:MapGoUp goto:exit2observatory wait:60 \
    pclick:1420,380 wait:200 scene wait:300 scene obj:Medusa party \
    goto:exit2old_ship wait:60 party goto:MapGoUp goto:exit2observatory wait:60 \
    pclick:1420,380 wait:300 scene party || { fail "$name" "play failed: $(grep -E 'SCENE TWICE|LOOP' "$TMP/$name.log" | head -1)"; return; }
  n=$(count "$name" "03_museum_observator: scene 'museum-medusa_crazy'")
  b=$(count "$name" "-> 03__museum_medusa'sdeath")
  if [ "$n" != 1 ] || [ "$b" != 1 ]; then fail "$name" "scene started $n times, battle $b"; return; fi
  grep -q "^  medusa: actor .*hero true" "$TMP/$name.log" && { fail "$name" "Medusa back in the party"; return; }
  grep -q "transition 03_museum_observator -> 03_museum_oldship" "$TMP/$name.log" || { fail "$name" "party did not leave the observatory"; return; }
  ok "$name"
}
medusa() { medusa_run medusa; }

# 1b. Load in 01_port_store before taking the matrix disc: GO_RunFun still sets
#     isMatrixDisc in 01_port (deviation: the exe loses it and softlocks), so the
#     park battle comes.
matrixload() {
  play matrixload autosaveload $(prefix goto:store_enter) loot goto:exit2port goto:fight11_place scene wait:600 ||
    { fail matrixload "play failed"; return; }
  grep -q "transition .* -> 01__port_park" "$TMP/matrixload.log" || { fail matrixload "no park battle after loading in the store"; return; }
  ok matrixload
}
medusaload() { medusa_run medusaload autosaveload; }

# 1a. Medusa joins before the observatory is first visited (the cards, then her, as a
#     player may go): the observatory and its battles are new locations where the party
#     creates her. She must be of the hero class there (Party.createMissingHeroes, exe
#     type 6 at 0x481d18), or HERO_EnableEnumerate("Medusa",0) in the crazy-scene trigger
#     (0x4c199a) did nothing and the scene and battle came again right after the win.
medusafirst() {
  play medusafirst oncecheck $(prefix use:03mf_CardYellow:monitors) scene goto:cutscene_medusa scene wait:100 scene \
    goto:exit2ships wait:60 loot goto:cutscene_girl scene click:1160,300 wait:30 goto:exit2observatory wait:60 loot \
    use:03mo_CardOrange:CardChecker scene goto:wajcha scene goto:cutscene_base scene goto:fight_stinger loot \
    pclick:1420,380 wait:300 scene wait:300 scene obj:Medusa || { fail medusafirst "play failed: $(grep -E 'SCENE TWICE|LOOP' "$TMP/medusafirst.log" | head -1)"; return; }
  n=$(count medusafirst "03_museum_observator: scene 'museum-medusa_crazy'")
  b=$(count medusafirst "-> 03__museum_medusa'sdeath")
  if [ "$n" != 1 ] || [ "$b" != 1 ]; then fail medusafirst "scene started $n times, battle $b"; return; fi
  grep -q "^  medusa: actor .*hero true" "$TMP/medusafirst.log" && { fail medusafirst "Medusa back in the party"; return; }
  ok medusafirst
}

# 2. BT walks after the trabant battle when the plank scene ran before
#    (port-deska puts BT on floor 1; PLACE without a floor means floor 0; 42403d8).
bt() {
  play bt autorefill autolevel autoequip wait:300 scene loot goto:trupy scene \
    use:decha:brzeg_na_deske scene wait:200 scene goto:fight2_place goto:garcia_place \
    goto:cutscene_trabant scene wait:200 actor:bt hero:BT goto:fight5_place actor:bt ||
    { fail bt "play failed"; return; }
  grep -q "transition 01__port_trabant -> 01_port" "$TMP/bt.log" || { fail bt "trabant battle not passed"; return; }
  first=$(grep "^  \[.*\] bt: " "$TMP/bt.log" | head -n 1)
  last=$(grep "^  \[.*\] bt: " "$TMP/bt.log" | tail -n 1)
  case $first in *"floor 0"*) ;; *) fail bt "BT not on floor 0 after the battle: $first"; return ;; esac
  [ "${first#* at }" != "${last#* at }" ] || { fail bt "BT did not move: $last"; return; }
  ok bt
}

# 3. Ladder by the port grid: a player click on it (pclick, as in the viewer)
#    takes the whole party down, also when the selected hero stands at its top
#    (.ap link for the last cell — dcf5691; party — 76accb6).
ladder() {
  play ladder $(prefix use:Gloves:furtka) scene pclick:350,1400 wait:400 party ||
    { fail ladder "play failed"; return; }
  # Ladder bottom is y ≥ 1450 (top is about 1324).
  up=$(sed -n '/> party/,$p' "$TMP/ladder.log" | awk '/ en true .* at / { split($0, a, " at "); split(a[2], p, "[ ,]"); if (p[2] + 0 < 1450) print }')
  [ -z "$up" ] || { fail ladder "left on top: $up"; return; }
  ok ladder
}

# 3b. A single-hero click (walk.click → clickAction) during the schodki descent
#     (.ap path) does not abort it: Sullivan reaches the bottom instead of
#     pathing from the stairs (onPortal, as in clickPlay).
ladderclick() {
  play ladderclick $(prefix use:Gloves:furtka) scene pclick:350,1400 wait:16 click:450,1300 party ||
    { fail ladderclick "play failed"; return; }
  y=$(sed -n '/> party/,$p' "$TMP/ladderclick.log" | awk '/^  sullivan: .* at / { split($0, a, " at "); split(a[2], p, "[ ,]"); print p[2] }' | head -n 1)
  [ -n "$y" ] && [ "$y" -ge 1450 ] || { fail ladderclick "Sullivan did not get down (y $y): the click aborted the descent"; return; }
  ok ladderclick
}

# 4. Loading in 05_laboratory: the lab-enter intro does not repeat and the party
#    stays put (f27aefc).
labload() {
  play labload $(prefix goto:exit2laboratory) wait:100 scene wait:300 scene actor:Sullivan saveload wait:200 actor:Sullivan ||
    { fail labload "play failed"; return; }
  after=$(sed -n '/> saveload/,$p' "$TMP/labload.log")
  echo "$after" | grep -q "scene 'lab-enter'" && { fail labload "lab-enter again after loading"; return; }
  p1=$(grep "^  \[.*\] sullivan: " "$TMP/labload.log" | head -n 1 | sed 's/.* at \([^ ]*\) .*/\1/')
  p2=$(grep "^  \[.*\] sullivan: " "$TMP/labload.log" | tail -n 1 | sed 's/.* at \([^ ]*\) .*/\1/')
  [ "$p1" = "$p2" ] || { fail labload "Sullivan at $p2 after loading, was at $p1"; return; }
  ok labload
}

# 5. A battle with a party hero the battle script did not place: Slavsky after
#    joining, in 03__museum_child (the script places only Sullivan, Ovitz,
#    Trantigne, MacFadden, Medusa) is not a participant: not a fighter, the AI
#    ignores him, the rocketeers move and shoot (turns.participates; ae41d3c).
sideline() {
  play sideline $(prefix use:03mob_stun_bomb1:enter2domek) scene wait:300 scene party \
    blog godmode passive level:03__museum_child wait:2500 ||
    { fail sideline "play failed"; return; }
  grep -q "^  slavsky: en true" "$TMP/sideline.log" || { fail sideline "Slavsky not in the party before the battle — the scenario checks nothing"; return; }
  grep -q "^  slavsky .*hero" "$TMP/sideline.log" && { fail sideline "Slavsky is a fighter in 03__museum_child"; return; }
  [ "$(count sideline ': 03ch_jetelmer[12] hits')" -ge 2 ] || { fail sideline "rocketeers do not shoot"; return; }
  ok sideline
}

# 6. A counterattack kills a monster on its own turn: the next monster plans its
#    own move instead of replaying the dead one's path (turns.stepAI does not
#    carry the stage over; exe drops the fighter's queue on death 0x4905c2).
#    Counterattack 100 %, monsters at 1 hp, heroes hold rifles and do not act
#    (passive + counters).
counterkill() {
  play counterkill autoequip blog passive counters level:01__port_park \
    cmd:pick+su_rifle cmd:pick+ov_rifle cmd:pick+tr_rifle \
    cmd:set+sullivan+counter_attack+100 cmd:set+ovitz+counter_attack+100 cmd:set+trantigne+counter_attack+100 \
    cmd:set+sullivan+hp+5000 cmd:set+ovitz+hp+5000 cmd:set+trantigne+hp+5000 \
    cmd:set+01pr_garcia1+hp+1 cmd:set+01pr_garcia2+hp+1 cmd:set+01pr_hornet03+hp+1 \
    cmd:set+01pr_hornet04+hp+1 cmd:set+01pr_hornet05+hp+1 wait:3000 ||
    { fail counterkill "play failed"; return; }
  # After the moving monster dies from a counterattack, the next AI line is a plan
  # ("AI X at"), not "AI final" without a plan. Only cases where the mover died count.
  bad=$(awk '/^  AI [^ ]+ at / { who = $2 } /counterattack/ { c = 1; next } c && $1 == who && / dies$/ { d = 1; c = 0; next } d && /^  AI / { if ($0 !~ / at [0-9]+,[0-9]+:/) print; d = 0; n++ } END { if (n == 0) print "NO CASES" }' "$TMP/counterkill.log")
  [ -z "$bad" ] || { fail counterkill "after a counterattack kill: $bad"; return; }
  ok counterkill
}

# Counter-attack roll needs a weapon in hand (+0x3250 and vfunc +0x6c):
# a bandage in Sullivan's hand never rolls, even with counter_attack 100.
counterhand() {
  play counterhand blog passive level:01__port_park cmd:pick+su_bandage1 \
    cmd:set+sullivan+counter_attack+100 cmd:set+sullivan+hp+5000 cmd:set+ovitz+hp+5000 \
    cmd:set+trantigne+hp+5000 wait:1500 || { fail counterhand "play failed"; return; }
  grep -q "sullivan: -" "$TMP/counterhand.log" || { fail counterhand "sullivan was never hit"; return; }
  if grep -q "sullivan: counterattack" "$TMP/counterhand.log"; then fail counterhand "countered without a weapon"; return; fi
  ok counterhand
}

# Hero sleep (Guard's tranquilizer, 03__museum_guard): a sleeping hero wakes up
# within 3 turns (0x49036f: 2 + enemy turn; decrement at the end of the hero
# turn 0x4903d0 → 0x490510) — the state is fully removed.
tranq() {
  play tranq blog godmode passive level:03__museum_guard wait:6000 ||
    { fail tranq "play failed"; return; }
  bad=$(awk '/^turn [0-9]+:/ { split($2, a, ":"); t = a[1] + 0 }
    / state 6$/ { n = $1; sub(":", "", n); if (!(n in s)) s[n] = t }
    / woke up$/ { n = $1; sub(":", "", n); if (n in s) { if (t - s[n] > 3) print n " slept " t - s[n] " turns"; delete s[n]; w++ } }
    END { for (n in s) if (t - s[n] > 3) print n " did not wake in " t - s[n] " turns"; if (w == 0) print "nobody woke up" }' "$TMP/tranq.log")
  [ -z "$bad" ] || { fail tranq "$bad"; return; }
  ok tranq
}

# 8. During a scene a player click on the field does not move the hero
#    (0x45bf90: a scene or line is running — the scene has control).
scenewalk() {
  play scenewalk wait:30 pclick:900,700 || { fail scenewalk "play failed"; return; }
  grep -q "pclick 900,700: false" "$TMP/scenewalk.log" || { fail scenewalk "a click during a scene moved the hero"; return; }
  ok scenewalk
}

# Sullivan's HP after the NATO scene (lab-nato_group3 → battle 05__lab_group3):
# the battle's restore() does FighterSetHp("Sullivan", hp / 2), and the party
# carry-over does not overwrite it (in the exe heroes are shared objects already
# at restore(), 0x431830). No auto-heal before the battle: at battle start hp ≤ half.
natohp() {
  play natohp $(prefix godmode 2) noautorefill hp blog goto:cutscene_nato scene ||
    { fail natohp "play failed"; return; }
  before=$(awk '/^  sullivan: hp / { split($3, a, "/"); print a[1]; exit }' "$TMP/natohp.log")
  start=$(awk '/-> 05__lab_group3/ { s = 1; next } s && $1 == "sullivan" && $3 == "hp" { print $4; exit }' "$TMP/natohp.log")
  if [ -z "$before" ] || [ -z "$start" ]; then fail natohp "no hp before the scene ($before) or at battle start ($start)"; return; fi
  [ "$start" -le $((before / 2)) ] || { fail natohp "Sullivan hp $before → $start at battle start, expected ≤ $((before / 2))"; return; }
  ok natohp
}

# 10. AI threat map (0x49af80): a hero's weapon only with its owner name, no ammo
#     check; the party's shared fist (no owner) gives no threat. Otherwise the far
#     NATO in 05__lab_group3 stand all battle (auto-battle, 6 turns, seed 1).
natothreat() {
  "$TOOL" battle "$G" 05__lab_group3 6 1 >"$TMP/natothreat.log" 2>&1 ||
    { fail natothreat "battle failed"; return; }
  [ "$(count natothreat 'AI 05g3_nato[45] at .*strike yes')" -ge 2 ] ||
    { fail natothreat "far NATO (nato4, nato5) do not attack"; return; }
  ok natothreat
}

# 11. Recharge (ion rifle, N = 4, 0x4b8490): a strike sets the full N (0x4cf778),
#     −1 at the start of the enemy turn (0x49844c). A shot on turn 1 shows 3, 2, 1
#     on turns 2–4; the counter reaches 0 at the enemy turn 4 start, so the next shot
#     is Sullivan's on turn 5 (heroes auto-play, godmode) and turn 6 shows 3. (Before
#     every animation change blended (0x44f910: one-shots end 10 ticks later, so the
#     idle picks' rand, 0x423019, moved) the turn-4 counter roll succeeded and shot
#     first.) A counterattack with a recharging weapon does not fire: the player gets
#     "Recharging" (0x47c2a6), autoCounter skips.
recharge() {
  play recharge blog godmode level:01__port_park cmd:attack+sullivan+cw_ion_rifle+01pr_garcia1 wait:4000 ||
    { fail recharge "play failed"; return; }
  # Strike on the first battle tick (before the enemies finish entering): the entry completes, no hang.
  ! grep -q "stuck" "$TMP/recharge.log" || { fail recharge "battle stuck: an enemy never entered"; return; }
  shots=$(awk '/^turn [0-9]+: sullivan hits .* with dbg_1_cw_ion_rifle/ { sub(":", "", $2); printf "%s ", $2 }' "$TMP/recharge.log")
  left=$(awk '/^turn [0-9]+: dbg_1_cw_ion_rifle.s recharging/ { sub(":", "", $2); printf "%s:%s ", $2, $NF }' "$TMP/recharge.log")
  case $shots in "1 5 "*) ;; *) fail recharge "shots on turns $shots, expected 1 5 …"; return ;; esac
  case $left in "2:3 3:2 4:1 6:3 "*) ;; *) fail recharge "recharge by turn $left, expected 2:3 3:2 4:1 6:3 …"; return ;; esac
  ok recharge
}

# 12. Level-up points window (0x4af780) is the top GUI mode (0x4af7c2, [0x651cbc]):
#     while open the battle holds (no victory, no report), panel and report do not
#     cover it; after Accept — victory. Damage, exp and "Level up" popups under it
#     keep living (world objects). Hidden viewer.
levelup() {
  sdl_env
  OPENGORKY_SAVES="$TMP/saves" OPENGORKY_MUTE=1 "$VIEWER" "$G" 01__port_park/sprite.dat --level --heroes --play \
    --input "w 700;x exp Sullivan;x attack Sullivan gs_fist_all 01pr_hornet05;w 20;x popups;w 20;x popups;w 20;x popups;w 20;x popups;w 20;x popups;w 20;x popups;w 20;x popups;w 20;x popups;x win;w 400;x fighters;c 340,400;w 400;x fighters;q" >"$TMP/levelup.log" 2>&1 ||
    { fail levelup "viewer failed"; return; }
  # A level-up strike: the window waits 150 ticks while popups (world objects) run:
  # the damage number appeared and rises, "Level up" (+75) appeared before the window.
  grep -q 'console: popup "[0-9][0-9+]*" delay 0 state [123]' "$TMP/levelup.log" ||
    { fail levelup "damage popup did not run under the points window"; return; }
  # The popup is string.tab text: English or the Russian edition's (cp1251).
  iconv -f cp1251 -t utf-8 "$TMP/levelup.log" | grep -q -e 'console: popup "Level up" delay 0 state [123]' -e 'console: popup "Уровень персонажа повышен" delay 0 state [123]' ||
    { fail levelup "\"Level up\" did not appear before the points window"; return; }
  phases=$(awk '/console: phase / { printf "%s ", $4 }' "$TMP/levelup.log")
  case $phases in "won "*) fail levelup "battle ended with the points window open ($phases)"; return ;; *" won ") ;; *) fail levelup "battle phases \"$phases\", expected … won"; return ;; esac
  ok levelup
}

# 13. Hound shadows in port-silos_hounds (01_port_silos — a level with .cfg and no
#     battle grid): the background floor on the round pad is 1–3 .zbf steps closer
#     than the actors' floor plane; without a depth tolerance the depth test cut
#     the shadow in stripes. No shadow pixel may be cut by the background
#     (shadowstat at --hires 2).
shadowfloor() {
  sdl_env
  OPENGORKY_SAVES="$TMP/saves" OPENGORKY_MUTE=1 "$VIEWER" "$G" 01_port_silos/sprite.dat --level --heroes --play --hires 2 \
    --input "w 10;x scene port-silos_hounds;w 100;x shadowstat;w 100;x shadowstat;w 100;x shadowstat;w 100;x shadowstat;q" >"$TMP/shadowfloor.log" 2>&1 ||
    { fail shadowfloor "viewer failed"; return; }
  stats=$(sed -n 's/.*console: shadow lit \([0-9]*\) cut_bg \([0-9]*\).*/\1:\2/p' "$TMP/shadowfloor.log" | tr '\n' ' ')
  case $stats in "") fail shadowfloor "no shadowstat output"; return ;; esac
  for s in $stats; do
    [ "${s%%:*}" -gt 0 ] || { fail shadowfloor "no shadow ($stats)"; return; }
    [ "${s##*:}" = 0 ] || { fail shadowfloor "shadow cut by the background floor (lit:cut_bg — $stats)"; return; }
  done
  ok shadowfloor
}

# 14. Truncated save (interrupted write): loading fails with BadSave instead of
#     silently losing the unwritten level; a complete one loads.
badsave() {
  play badsave wait:30 "savefile:$TMP/full.ogsave" || { fail badsave "could not write the save"; return; }
  head -c "$(($(wc -c <"$TMP/full.ogsave") - 20))" "$TMP/full.ogsave" >"$TMP/cut.ogsave"
  play badsave "loadsave:$TMP/full.ogsave" || { fail badsave "complete save did not load"; return; }
  if play badsave "loadsave:$TMP/cut.ogsave"; then fail badsave "truncated save loaded"; return; fi
  grep -q BadSave "$TMP/badsave.log" || { fail badsave "expected BadSave"; return; }
  ok badsave
}

# 15. Player turn start (0x498550 → 0x45b1b0): the camera flies to the selected
#     hero (0x45b2c3 → 0x4c9100) instead of staying on the last enemy. After the
#     enemy turn the scroll equals the scroll after re-selecting the hero.
turncam() {
  sdl_env
  OPENGORKY_SAVES="$TMP/saves" OPENGORKY_MUTE=1 "$VIEWER" "$G" 01__port_park/sprite.dat --level --heroes --play \
    --input "w 700;x endturn;w 1500;x fighters;x scroll;x hero sullivan;w 60;x scroll;q" >"$TMP/turncam.log" 2>&1 ||
    { fail turncam "viewer failed"; return; }
  grep -q 'console: phase player' "$TMP/turncam.log" || { fail turncam "player turn never came"; return; }
  sc=$(sed -n 's/.*console: scroll \(.*\)/\1/p' "$TMP/turncam.log" | tr '\n' ' ')
  case $sc in "") fail turncam "no scroll output"; return ;; esac
  set -- $sc
  [ "$1" = "$2" ] || { fail turncam "camera after the enemy turn $1, on the hero $2"; return; }
  ok turncam
}

# 16. A hero strikes only from aim mode (right button, 0x4563e0 → 0x4524d0 →
#     0x452660 → 0x47c120): a left click on an enemy in normal mode (0x455200 →
#     0x455650, an empty `ret 4`) does nothing; after `aim` the same click strikes.
aimclick() {
  sdl_env
  OPENGORKY_SAVES="$TMP/saves" OPENGORKY_MUTE=1 "$VIEWER" "$G" 01__port_park/sprite.dat --level --heroes --play \
    --input "w 700;x put 01pr_hornet05 5 15;x tile 6 16;w 120;x fighters;x aim;x tile 6 16;w 200;x fighters;q" >"$TMP/aimclick.log" 2>&1 ||
    { fail aimclick "viewer failed"; return; }
  grep -q 'console: 01pr_hornet05 -> 5,15: ok' "$TMP/aimclick.log" || { fail aimclick "hornet not placed next to Sullivan"; return; }
  acted=$(sed -n 's/.*console: sullivan hero .* acted \([a-z]*\).*/\1/p' "$TMP/aimclick.log" | tr '\n' ' ')
  case $acted in
    "false true ") ok aimclick ;;
    "true "*) fail aimclick "a left click on an enemy without aiming struck" ;;
    *) fail aimclick "no strike after aiming (acted: $acted)" ;;
  esac
}

# 17. Barrel chain (object tick 0x4ce1b0: −1, strike at zero; 15 — 0x49204b).
#     Objects update after the battle step, from the head of list
#     0x63bcb8: a barrel blown by its neighbour ticks in the same pass only if its
#     weapon is further down the list (created earlier). 01__port_bulldozer2:
#     barrel2 → barrel1 after 14 ticks, barrel1 → barrel2 after 15.
barrelchain() {
  play barrelchain passive blog level:01__port_bulldozer2 cmd:explode+01b2_barrel2 trace:40 ||
    { fail barrelchain "play failed"; return; }
  got=$(sed -n 's/^  tick \([0-9]*\): blast \(01b2_barrel[12]\)_explode/\1:\2/p' "$TMP/barrelchain.log" | tr '\n' ' ')
  case $got in "15:01b2_barrel2 29:01b2_barrel1 ") ;; *) fail barrelchain "barrel2 → barrel1: $got, expected 15 and 29"; return ;; esac
  play barrelchain passive blog level:01__port_bulldozer2 cmd:explode+01b2_barrel1 trace:40 ||
    { fail barrelchain "play failed"; return; }
  got=$(sed -n 's/^  tick \([0-9]*\): blast \(01b2_barrel[12]\)_explode/\1:\2/p' "$TMP/barrelchain.log" | tr '\n' ' ')
  case $got in "15:01b2_barrel1 30:01b2_barrel2 ") ;; *) fail barrelchain "barrel1 → barrel2: $got, expected 15 and 30"; return ;; esac
  ok barrelchain
}

# 18. A barrel blast is credited to whoever blew it up (barrel +0x24aec → weapon
#     +0x1ab0, 0x492055; strike 0x4ce217): +5 exp (0x4ce1d7) plus exp for damage,
#     the chain too.
barrelexp() {
  play barrelexp passive blog level:01__port_bulldozer2 cmd:put+01b2_fang+7+6 cmd:attack+ovitz+cw_pistol+01b2_barrel2 trace:80 ||
    { fail barrelexp "play failed"; return; }
  n=$(grep -c '^  ovitz: +[0-9]* exp' "$TMP/barrelexp.log")
  [ "$n" = 2 ] || { fail barrelexp "shooter exp for two blasts: $n time(s), expected 2"; return; }
  ok barrelexp
}

# 18b. A blast that hits nobody still transfers the shooter's pending exp (0x4cf2af →
#      0x4cf48a → 0x4cf490): barrel1 goes off after Fang is already hit, +5 exp.
barrelnovictim() {
  play barrelnovictim passive blog level:01__port_bulldozer2 cmd:attack+ovitz+cw_pistol+01b2_barrel2 trace:80 ||
    { fail barrelnovictim "play failed"; return; }
  n=$(grep -c '^  ovitz: +[0-9]* exp' "$TMP/barrelnovictim.log")
  [ "$n" = 2 ] || { fail barrelnovictim "shooter exp lines: $n, expected 2 (one for the empty blast)"; return; }
  ok barrelnovictim
}

# 18c. Every destroyed barrel gets its visual blast at once (0x492067 → 0x4ceb40):
#      a grenade blowing up both barrels, and a barrel blowing up its neighbour.
barrelfx() {
  play barrelfx passive blog level:01__port_bulldozer2 cmd:attack+ovitz+cw_grenade+01b2_barrel2 trace:200 ||
    { fail barrelfx "play failed"; return; }
  n=$(grep -c '^  01b2_barrel[12] explodes (explosion)' "$TMP/barrelfx.log")
  [ "$n" = 2 ] || { fail barrelfx "grenade: $n barrel explosion(s), expected 2"; return; }
  play barrelfx passive blog level:01__port_bulldozer2 cmd:explode+01b2_barrel2 trace:40 ||
    { fail barrelfx "play failed"; return; }
  grep -q '^  01b2_barrel1 explodes (explosion)' "$TMP/barrelfx.log" ||
    { fail barrelfx "chain: barrel1 blown up by barrel2 has no explosion"; return; }
  ok barrelfx
}

# 19. AI scoring with a decoy: 2000·ai_opponent_distance_weight·path (unreachable —
#     10000) overflows i32 — the exe's imul just wraps, we used to panic.
decoy() {
  "$TOOL" decoytest "$G" 01__port_park 5,5 3 >"$TMP/decoy.log" 2>&1 ||
    { fail decoy "auto-battle with a decoy crashed"; return; }
  ok decoy
}

# 19b. Incubus ball (class 0x4a5840, kind 0): on arrival no strike, it lies with
#      countdown attack_ball_exp (0) + 3 (0x4a6056); −1 at each enemy turn start
#      (+0xc0, 0x49844c); at 1 it blows up there (+0xc4 → weapon +0xf0, 0x498650).
#      Every ball placed in enemy turn N blasts at the start of enemy turn N+2.
ballcharge() {
  "$TOOL" battle "$G" 05__lab_incubus 6 >"$TMP/ballcharge.log" 2>&1 ||
    { fail ballcharge "battle failed"; return; }
  res=$(awk '/^turn [0-9]+: ball of .* lies/ { sub(":", "", $2); l[$2]++; n++ }
    /^turn [0-9]+: ball of .* blasts/ { sub(":", "", $2); b[$2]++ }
    END {
      if (n == 0) print "no ball lies"
      for (t in l) if (t + 2 <= 6 && l[t] != b[t + 2]) print "turn " t ": " l[t] " placed, " b[t + 2] + 0 " blasted on turn " t + 2
      for (t in b) if (b[t] != l[t - 2]) print "turn " t ": " b[t] " blasted, " l[t - 2] + 0 " placed on turn " t - 2
    }' "$TMP/ballcharge.log")
  [ -z "$res" ] || { fail ballcharge "$(echo $res)"; return; }
  ok ballcharge
}

# 20. No import cycles, no entry-file bypass, no unused pub.
deps() {
  python3 -I scripts/deps.py . file >"$TMP/deps.log" 2>&1 ||
    { fail deps "import cycle or entry bypass: $(head -1 "$TMP/deps.log")"; return; }
  python3 -I scripts/deps.py . group >"$TMP/deps.log" 2>&1 ||
    { fail deps "folder import cycle: $(head -1 "$TMP/deps.log")"; return; }
  python3 -I scripts/pubcheck.py . >"$TMP/deps.log" 2>&1 ||
    { fail deps "unused pub: $(head -1 "$TMP/deps.log")"; return; }
  ok deps
}

# The reference's generated catalog (docs/og-script.md §13: the built-in traits, their
# methods, the combine rules) is what gorky-tool traits-doc makes from foundation/traits.ogs.
traitsdoc() {
  "$TOOL" traits-doc docs/og-script.md --check >"$TMP/traitsdoc.log" 2>&1 ||
    { fail traitsdoc "$(head -1 "$TMP/traitsdoc.log")"; return; }
  ok traitsdoc
}

# The OG pair: the hand-written OpenGorky project (src/tests/og/port)
# read and written back by the OG writer gives the same bytes.
ogroundtrip() {
  "$TOOL" og-roundtrip src/tests/og/port >"$TMP/ogroundtrip.log" 2>&1 ||
    { fail ogroundtrip "$(head -1 "$TMP/ogroundtrip.log")"; return; }
  ok ogroundtrip
}

# The OG reader: the hand-written OpenGorky project
# (src/tests/og/port, its game $G) plays. Battle 01__port_citadel: the game block's hero
# and the block's fighters with their nested weapons, placed by the battle's code
# (OnRestore), fight by the project's rows to an end. Location 01_port: its objects
# from the block, Sullivan placed by its code; the viewer draws it.
ogplay() {
  sdl_env
  # Each into its own file: the tools write from the start of their output file.
  { OPENGORKY_GAME=$G "$TOOL" battle src/tests/og/port 01__port_citadel 30 1 >"$TMP/ogplay.log" 2>&1 &&
    OPENGORKY_GAME=$G "$TOOL" world src/tests/og/port 01_port 10 >"$TMP/ogplay.world" 2>&1 &&
    cat "$TMP/ogplay.world" >>"$TMP/ogplay.log" &&
    OPENGORKY_GAME=$G "$TOOL" world src/tests/og/port 01__port_citadel 1 >"$TMP/ogplay.bworld" 2>&1; } ||
    { fail ogplay "tool failed: $(tail -1 "$TMP/ogplay.log")"; return; }
  grep -q '^Sullivan *hero  tile 1,1 size 1 hp 130 move 4 weapon gs_fist_all$' "$TMP/ogplay.log" || { fail ogplay "no hero from the game block"; return; }
  # Placement, looks and weapons as data: tiles, `placement`, the archetype's
  # nested weapon (grandma_gun, grandma_child1_gun), an instance's own over it (grandma_child2's).
  grep -q '^grandma *enemy tile 2,9 size 2 hp 200 move 3 weapon grandma_gun$' "$TMP/ogplay.log" || { fail ogplay "grandma not from her archetype"; return; }
  grep -q '^grandma_child2 enemy tile 4,8 size 1 hp 25 move 3 weapon grandma_child2_gun$' "$TMP/ogplay.log" || { fail ogplay "an instance's own weapon not over its archetype's"; return; }
  # The looks: the enemies and the hero animate, placed where the Classic battle puts them.
  grep -q "^  grandma  *actor  *on   mesh grandma placed at -1242,1923,-331 angle 4.69 anim '[a-z0-9]" "$TMP/ogplay.bworld" &&
    grep -q "^  grandma_child1  *actor  *on   mesh wnuczek placed at -1269,1847,-331 angle 4.69 anim '[a-z0-9]" "$TMP/ogplay.bworld" &&
    grep -q "^  Sullivan  *actor  *on   mesh Sulivan placed at -1327,1491,-331 angle 1.55 anim 'su_" "$TMP/ogplay.bworld" || { fail ogplay "no look animations or tiles in the battle: $(grep grandma "$TMP/ogplay.bworld" | head -1)"; return; }
  grep -q '^grandma_child1 enemy tile 2,8 size 1 hp 40 move 3 weapon grandma_child1_gun$' "$TMP/ogplay.log" || { fail ogplay "the instance's own hp lost"; return; }
  grep -q '^turn [0-9]*: [A-Za-z_0-9]* hits ' "$TMP/ogplay.log" || { fail ogplay "nobody hits"; return; }
  grep -q '^result: \(won\|lost\) on turn' "$TMP/ogplay.log" || { fail ogplay "the battle did not end"; return; }
  grep -q '^  Sullivan .* mesh Sulivan placed at ' "$TMP/ogplay.log" || { fail ogplay "Sullivan not placed in 01_port"; return; }
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$VIEWER" src/tests/og/port 01_port/sprite.dat --level --heroes --shot "$TMP/ogplay.png" >>"$TMP/ogplay.log" 2>&1 &&
    [ -s "$TMP/ogplay.png" ] || { fail ogplay "viewer failed"; return; }
  # The build on a copy (it writes dist/): the package plays the same
  # battle as src/; Play from it (gorky-tool play --start) in the viewer, the test room too;
  # a project without a single-record row is an error naming it, not a panic.
  rm -rf "$TMP/ogp" && cp -R src/tests/og/port "$TMP/ogp" && rm -rf "$TMP/ogp/dist"
  OPENGORKY_GAME=$G "$TOOL" build "$TMP/ogp" >"$TMP/ogplay.build" 2>&1 &&
    grep -q '^OK   build: dist/port.ogp, 35 entries, 35 rebuilt$' "$TMP/ogplay.build" || { fail ogplay "build: $(head -1 "$TMP/ogplay.build")"; return; }
  OPENGORKY_GAME=$G "$TOOL" battle "$TMP/ogp/dist/port.ogp" 01__port_citadel 30 1 >"$TMP/ogplay.pkg" 2>&1 &&
    OPENGORKY_GAME=$G "$TOOL" battle src/tests/og/port 01__port_citadel 30 1 >"$TMP/ogplay.src" 2>&1 &&
    cmp -s "$TMP/ogplay.pkg" "$TMP/ogplay.src" || { fail ogplay "the package's battle differs from src/'s"; return; }
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$TOOL" play "$TMP/ogp" --start location:01_port --shot "$TMP/ogplay_pkg.png" >"$TMP/ogplay.play" 2>"$TMP/ogplay.play.err" &&
    [ -s "$TMP/ogplay_pkg.png" ] && grep -q ', 0 rebuilt$' "$TMP/ogplay.play" || { fail ogplay "play --start from the package: $(tail -1 "$TMP/ogplay.play")"; return; }
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$TOOL" play "$TMP/ogp" --start test-room:characters::grandma_child --shot "$TMP/ogplay_room.png" >"$TMP/ogplay.room" 2>&1 &&
    [ -s "$TMP/ogplay_room.png" ] && [ -s "$TMP/ogp/dist/play.ogp" ] || { fail ogplay "test room: $(tail -1 "$TMP/ogplay.room")"; return; }
  # The viewer's own --start: at an area (the party on its points); an unknown one is said.
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$TOOL" play "$TMP/ogp" --start location:01_port@capt_start --shot "$TMP/ogplay_area.png" >"$TMP/ogplay.area" 2>&1 &&
    [ -s "$TMP/ogplay_area.png" ] && ! grep -q 'no area' "$TMP/ogplay.area" || { fail ogplay "--start at an area: $(tail -1 "$TMP/ogplay.area")"; return; }
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$VIEWER" "$TMP/ogp/dist/port.ogp" --start location:01_port@nowhere --shot "$TMP/ogplay_none.png" >"$TMP/ogplay.none" 2>&1
  grep -q -- '--start: no area nowhere in 01_port' "$TMP/ogplay.none" || { fail ogplay "an unknown --start area not said: $(tail -1 "$TMP/ogplay.none")"; return; }
  perl -ni -e 'print unless /^    start = /' "$TMP/ogp/src/game.ogs"
  ! OPENGORKY_GAME=$G "$TOOL" build "$TMP/ogp" >"$TMP/ogplay.nocamp" 2>/dev/null &&
    grep -q '^src/game.ogs:0: error: no game start' "$TMP/ogplay.nocamp" || { fail ogplay "a missing game start: $(head -1 "$TMP/ogplay.nocamp")"; return; }
  OPENGORKY_GAME=$G "$TOOL" world "$TMP/ogp" 01_port 1 >/dev/null 2>"$TMP/ogplay.nocamp"
  grep -q 'no game start' "$TMP/ogplay.nocamp" && ! grep -q panic "$TMP/ogplay.nocamp" || { fail ogplay "the reader on a missing game start: $(head -1 "$TMP/ogplay.nocamp")"; return; }
  # A package for a newer engine: refused by its own manifest (not opened as a folder).
  sed 's/^engine = .*/engine = 99.0/' "$TMP/ogp/opengorky.mod" >"$TMP/ogplay.mod" && cp "$TMP/ogplay.mod" "$TMP/ogp/opengorky.mod"
  cp src/tests/og/port/src/game.ogs "$TMP/ogp/src/" && OPENGORKY_GAME=$G "$TOOL" build "$TMP/ogp" >/dev/null 2>&1
  OPENGORKY_GAME=$G OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$VIEWER" "$TMP/ogp/dist/port.ogp" --start location:01_port --shot "$TMP/ogplay_new.png" >"$TMP/ogplay.new" 2>&1
  grep -q 'needs OpenGorky 99.0 or newer' "$TMP/ogplay.new" || { fail ogplay "a newer package not refused: $(tail -1 "$TMP/ogplay.new")"; return; }
  ok ogplay
}

# OG Script types (docs/og-script.md §10.5–10.8): the test project's battle attaches
# Reinforcements(waves = [Wave(turn = 3, …), Wave(turn = 5, …)]) (struct, enum, list<T>
# params); its OnTurnStart spawns enemies of an archetype (battle::SpawnEnemy(~c"…")) on
# the enemies' turns 3 and 5. Sullivan made tougher in a copy so the battle gets there.
reinforce() {
  rm -rf "$TMP/rf" && cp -R src/tests/og/port "$TMP/rf" && rm -rf "$TMP/rf/dist"
  sed 's/^        hp = 130;/        hp = 1000;/; s/^        max_hp = 130;/        max_hp = 1000;/' src/tests/og/port/src/characters/Sullivan.ogs >"$TMP/rf/src/characters/Sullivan.ogs"
  OPENGORKY_GAME=$G "$TOOL" battle "$TMP/rf" 01__port_citadel 60 1 >"$TMP/reinforce.log" 2>&1 || { fail reinforce "tool failed: $(tail -1 "$TMP/reinforce.log")"; return; }
  grep '^  spawn ' "$TMP/reinforce.log" >"$TMP/reinforce.spawns"
  printf '  spawn grandma_child enemy at 5,2 on turn 3\n  spawn grandma_child_2 enemy at 4,2 on turn 5\n  spawn grandma_child_3 enemy at 3,2 on turn 5\n' | cmp -s - "$TMP/reinforce.spawns" ||
    { fail reinforce "spawns: $(tr '\n' ';' <"$TMP/reinforce.spawns")"; return; }
  grep -q '^turn [0-9]*: [A-Za-z_0-9]* hits grandma_child\(_[23]\)\? ' "$TMP/reinforce.log" || { fail reinforce "nobody fights the reinforcements"; return; }
  ok reinforce
}

# The converter: the game converted into a new
# OpenGorky project (twice the same bytes, built with no errors), read back by the OG
# writer the same, every location's objects and variables as Classic's (convert-check),
# and battles from its package byte for byte as Classic's. A subset of the 132 logs
# (scripts/convert-regress.sh runs them all; any difference fails, animation data too).
convert() {
  LEVELS="01__port_park 01__port_store 03__museum_chopper 04__city_hotelentrance 05__lab_group3" TMPDIR="$TMP" \
    sh scripts/convert-regress.sh "$G" 1 7 >"$TMP/convert.log" 2>&1 || { fail convert "$(tail -1 "$TMP/convert.log")"; return; }
  grep -q '^convert-check: locations 67 (0 do not start converted), objects [0-9]* (0 missing), values [0-9]*: 0 differ, animation data 0 differ$' "$TMP/convert.log" ||
    { fail convert "convert-check: $(grep convert-check "$TMP/convert.log" | tail -1)"; return; }
  ok convert
}

# 21. Every gorky-tool command runs once on real data without an error exit or panic
#     (most commands are not covered by the playthrough).
toolsmoke() {
  a="$G/dat/04__city_passing/sprite.dat"
  set -- "list $a" "extract $a $TMP/smoke-ex" "export $a $TMP/smoke-png" "check $G" \
    "scripts $G" "scripts $G --api" "world $G 01_port_store 10" "battle $G 01__port_park 1" \
    "battle $G 01__port_park 1 1 --sounds" "decoytest $G 01__port_park 5,5 1" "play $G 01_port_store" \
    "scenes $G 01_port_silos:port-silos_hounds" "walk $G 01_port_store 320,240 330,250" \
    "paths $G 01_port_store" "items $G 01_port_store" "use $G 01_port_store su_matches box01_store_itm" \
    "voices $G" "listen $G 01_port_store 1 $TMP/smoke.wav" "models $G" "anims $G cpt boxing" \
    "model $G cpt boxing 0 $TMP/smoke.png"
  for c in "$@"; do
    # shellcheck disable=SC2086
    "$TOOL" $c >"$TMP/toolsmoke.log" 2>&1 ||
      { fail toolsmoke "gorky-tool $(echo "$c" | cut -d' ' -f1) exited with an error: $(tail -1 "$TMP/toolsmoke.log")"; return; }
  done
  ok toolsmoke
}

# 24. Opening boat (01_port init: WalkOnSceneryTrack("ponton","ponton",0.0,5), stop on
#     HeroInArea("ponton_stop")): the first actor tick only starts the queued track
#     (0x4265bc), so the boat moves from tick 2, stops at 1670,229 and the arrival scene
#     starts on tick 214.
boat() {
  play boat wait:250 obj:ponton || { fail boat "play failed"; return; }
  grep -q "^\[   214\] 01_port: scene 'port-arriv_at_port'" "$TMP/boat.log" || { fail boat "arrival scene not on tick 214"; return; }
  grep -q "^  ponton: actor .* at 1670,229$" "$TMP/boat.log" || { fail boat "boat did not stop at 1670,229"; return; }
  ok boat
}

# 25. Scenes play once: the exe has no "played" flag — scripts guard scenes with their
#     own state (level vars, party, adv var), kept by level records and saves. The whole
#     playthrough with a full save/load after every switch to a non-battle level:
#     no scene starts twice (except those the scripts re-trigger on every use).
sceneonce() {
  # shellcheck disable=SC2086
  play sceneonce oncecheck autosaveload $STEPS || { fail sceneonce "play failed: $(grep -E 'SCENE TWICE|LOOP' "$TMP/sceneonce.log" | head -1)"; return; }
  grep -q "end of game" "$TMP/sceneonce.log" || { fail sceneonce "the playthrough did not finish"; return; }
  ok sceneonce
}

# 18. GUI modes on top of the field (0x651cbc): with the Esc menu open, game keys
#     (E — end turn) and panel clicks (hand button → aim) must not reach the battle;
#     the level-up window swallows Esc. A new game during the battle transition
#     drops the transition (no endless saw); a failed load returns to the main menu.
menublock() {
  # 800: the hornets' appearance (walk + appearEnd) ends at ~750; Esc/E before it are ignored/skip the turn.
  view menublock "w 800;p Escape;w 2;p E;w 2;c 119,444;w 30;p Escape;w 5;x fighters;x aim;q" ||
    { fail menublock "viewer failed"; return; }
  grep -q 'console: phase player' "$TMP/menublock.log" || { fail menublock "E under the menu ended the turn"; return; }
  grep -q 'console: aim on' "$TMP/menublock.log" || { fail menublock "panel click under the menu switched aim on"; return; }
  view menublock "w 800;x exp Sullivan;x attack Sullivan gs_fist_all 01pr_hornet05;w 200;p Escape;w 5;x ui;q" ||
    { fail menublock "viewer failed (level-up)"; return; }
  grep -q 'console: ui menu false .* modal true' "$TMP/menublock.log" || { fail menublock "Esc opened the menu over the level-up window"; return; }
  view menublock "w 60;x level 01__port_park;w 5;p Escape;w 2;p Down;p Return;w 10;p Escape;w 300;x ui;x whereami;q" 01_port/sprite.dat ||
    { fail menublock "viewer failed (transition)"; return; }
  grep -q 'console: ui menu false .* transition false' "$TMP/menublock.log" || { fail menublock "transition survived a new game"; return; }
  grep -q 'console: level 01_port, tick [1-9]' "$TMP/menublock.log" || { fail menublock "the new game's world does not tick"; return; }
  play menublock wait:30 "savefile:$TMP/menublock.ogsave" || { fail menublock "could not write the save"; return; }
  mkdir -p "$TMP/saves"
  sed -e 's/ 01_port$/ 99_nowhere/' -e 's/ 01_port / 99_nowhere /g' "$TMP/menublock.ogsave" >"$TMP/saves/slot1.ogsave"
  view menublock "w 30;p Escape;w 2;p Down;p Return;w 5;p Return;w 30;x ui;q" 01_port/sprite.dat ||
    { fail menublock "viewer failed (load)"; return; }
  rm -f "$TMP/saves/slot1.ogsave"
  grep -q 'console: ui menu true screen main level none' "$TMP/menublock.log" || { fail menublock "a failed load left no menu"; return; }
  ok menublock
}

# 22. Battle-entry saw like the exe (0x41f0b0): 9 squeeze ticks, then the level loads
#     on the first whole saw turn after ≥ 10 saw ticks (pila.spr has 20 frames: 28 ticks).
sawtime() {
  view sawtime "w 60;x level 01__port_park;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;x ui;q" 01_port/sprite.dat ||
    { fail sawtime "viewer failed"; return; }
  grep -q 'transition true (27)' "$TMP/sawtime.log" && ! grep -q 'transition true (29)' "$TMP/sawtime.log" &&
    grep -q 'level 01__port_park transition false' "$TMP/sawtime.log" || { fail sawtime "transition not 28 ticks: $(grep -o 'transition true ([0-9]*)' "$TMP/sawtime.log" | tail -1)"; return; }
  ok sawtime
}

# Strike waits run alongside the async strike animation (command 0x14, 0x428980):
# control returns hit wait + after wait after the strike, not after the animation.
# Uzi (0x48c8b5): chaingun_hit_delay 40 + flash_timeout 80; Cutter Pill claw lift
# (0x489afd): its 14-tick turn to the target + 37 + 15 + 50 + 80. Before: 230 and 319.
strike_ticks() { # log → ticks from the first "pending attack" to the first "pending none"
  awk '/console: phase .* pending attack/ && !a { a = $NF } /console: phase .* pending none/ && a { print $NF - a; exit }' "$1"
}
strikewait() {
  steps() { s="$1"; i=0; while [ $i -lt "$2" ]; do s="$s;w 1;x fighters"; i=$((i + 1)); done; echo "$s;q"; }
  view strikewait_uzi "$(steps 'w 800;x attack sullivan cw_chaingun 01pr_hornet05' 200)" ||
    { fail strikewait "viewer failed (uzi)"; return; }
  view strikewait_claw "$(steps 'w 900;x attack 03cr_cutterpill1 03cr_cutterpill1_sa sullivan' 260)" 03__museum_corner/sprite.dat ||
    { fail strikewait "viewer failed (claw)"; return; }
  u=$(strike_ticks "$TMP/strikewait_uzi.log"); k=$(strike_ticks "$TMP/strikewait_claw.log")
  [ "$u" = 120 ] && [ "$k" = 196 ] || { fail strikewait "uzi $u ticks (120), claw $k ticks (196)"; return; }
  ok strikewait
}

# Objects with classic_id -1 are not picked (0x450fa0: `cmp [+0x58], -1; jle`): the decor
# barrel 03mf_beczka gets no hint or cursor; the yellow card next to it does.
decorpick() {
  view decorpick "w 30;x where 03mf_beczka;x where 03mf_cardyellow;q" 03_museum_forgotten/sprite.dat ||
    { fail decorpick "viewer failed"; return; }
  grep 'console: bg 1158,220' "$TMP/decorpick.log" | grep -q 'pick false' &&
    grep 'console: bg 1152,177' "$TMP/decorpick.log" | grep -q 'pick true' || { fail decorpick "decor barrel pickable or card not"; return; }
  ok decorpick
}

# Sullivan's radio in the museum NATO scene (museum-fakenato): WEAPON("Sullivan",
# "transmitter") puts transmitter.msh on his one_hand point for the radio
# lines; WEAPON("Sullivan") takes it away. Sampled every 100 ticks: the lines' timing
# differs by edition (voice lengths), so only the order is checked.
radio() {
  view radio "w 30;x scene museum-fakenato$(i=0; while [ $i -lt 32 ]; do printf ';w 100;x where Sullivan'; i=$((i + 1)); done);q" 03_museum/sprite.dat ||
    { fail radio "viewer failed"; return; }
  grep -a 'console: bg' "$TMP/radio.log" | awk "/weapon 'transmitter'/ { on = 1 } on && /weapon ''/ { off = 1 } END { exit !off }" ||
    { fail radio "the transmitter was not taken and put away: $(grep -a 'console: bg' "$TMP/radio.log" | grep -o "weapon '[a-z]*'" | uniq | tr '\n' ' ')"; return; }
  ok radio
}

# Effects of a deleted actor die with it (the exe's +0x30 pass, 0x420349), not in the
# left level: Esc on museum-medusa_crazy kept Medusa's current (VOLTAGE) in the
# observatory after her battle; on lab-lamare_dying BT's morph glow played again in
# lab-the_end.
leftfx() {
  name=$1
  shift
  play "$name" "$@" scene || { fail "$name" "play failed"; return; }
  grep -q "  skipped" "$TMP/$name.log" || { fail "$name" "scene not skipped"; return; }
  grep -q "transition 05__lab_thelastbattle -> \|transition 03__museum_medusa'sdeath -> " "$TMP/$name.log" || { fail "$name" "battle not passed"; return; }
  grep -q "leftover fx" "$TMP/$name.log" && { fail "$name" "$(grep "leftover fx" "$TMP/$name.log")"; return; }
  ok "$name"
}
medusafx() {
  leftfx medusafx $(prefix goto:cutscene_medusa) scene goto:exit2ships wait:60 goto:MapGoUp \
    goto:exit2observatory wait:60 pclick:1420,380 esc:museum-medusa_crazy
}
morphfx() { leftfx morphfx $(prefix use:matrix:work_station) esc:lab-lamare_dying; }

# A location left before a save is entered with the party: its restore() places the
# selected hero (01_port_chief: PlaceActor(GUI_GetSelectedHero(),"capt_start"),
# DisableHeroes). The save's stale copy kept Cole in the booth while Thierry, selected,
# went unplaced and could not be moved.
booth() {
  play booth wait:300 scene hero:Sullivan level:01_port_chief wait:30 level:01_port wait:30 \
    savefile:"$TMP/booth.sav" loadsave:"$TMP/booth.sav" hero:Trantigne level:01_port_chief wait:30 heroes ||
    { fail booth "play failed"; return; }
  grep -q "  trantigne (selected): on bg" "$TMP/booth.log" && grep -q "  sullivan: off" "$TMP/booth.log" ||
    { fail booth "$(grep -A3 '^> heroes' "$TMP/booth.log" | tr '\n' ' ')"; return; }
  ok booth
}

# Classic export: every game script and class function
# round-trips through the importer, the Classic printer and the exporter — unchanged
# exports write nothing, IR printed as Classic text imports back the same, and each test
# mutation rewrites only its own file (a literal or call only its own bytes); creation
# events lift to model data and back unchanged, a changed model value is written over its
# literal only and lifts back; the host schemas are the base classes' fields.
roundtrip() {
  "$TOOL" roundtrip "$G" >"$TMP/roundtrip.log" 2>&1 || { fail roundtrip "export round trip broke: $(grep -v '^  ' "$TMP/roundtrip.log" | grep -v ' 0 failed' | head -1)"; return; }
  grep -q '^mutation branch .* 0 failed' "$TMP/roundtrip.log" || { fail roundtrip "no mutation summary"; return; }
  grep -q '^lifted: .* with data .* 0 failed; .* 0 failed$' "$TMP/roundtrip.log" || { fail roundtrip "no lift summary"; return; }
  ok roundtrip
}

# The lifted model runs as the code: every location started with
# its creation events as code and as model data plus the rest — every object's variables
# and the actors' animation slots, idles, walk speeds, scale and offsets the same.
lift() {
  "$TOOL" lift "$G" >"$TMP/lift.log" 2>&1 || { fail lift "lifted model differs from init(): $(grep -A2 'differs at' "$TMP/lift.log" | head -3 | tr '\n' ' ')"; return; }
  grep -q 'lifted events run [1-9].*: 0 differ' "$TMP/lift.log" || { fail lift "nothing lifted"; return; }
  ok lift
}

# One way to open a document (doctabs.show): the tree (its row as its tab's click), an
# Info link and a go-to end on the same shown document — the tree's highlight follows it.
opening() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  cp -cR "$G" "$TMP/og" 2>/dev/null || cp -R "$G" "$TMP/og"
  HOME="$TMP" "$ED" "$TMP/og" --open locations 03_museum_observator --active \
    --open scenes museum-medusa_crazy --info 1 --active --goto 03_museum_observator: --active \
    --open scenes museum-medusa_crazy --active --goto scene:museum-medusa_crazy --active >"$TMP/opening.log" 2>&1 ||
    { fail opening "editor failed"; return; }
  n=$(grep '^active' "$TMP/opening.log" | sort | uniq -c | awk '{ print $1 }' | tr '\n' ' ')
  [ "$n" = "3 2 " ] || { fail opening "shown documents differ: $(grep '^active' "$TMP/opening.log" | tr '\n' ';')"; return; }
  ok opening
}

# Caches key on Store.rev: a video's Info built after an edit (01__port_citadel plays it),
# then the edit undone and another file edited (as many steps as before, no frame
# between) — the Info is read again: no level plays it any more (row 1 no link).
staleinfo() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  HOME="$TMP" "$ED" "$G" --replace '01__port_citadel/other.dat:01__port_citadel.lev' GRADMA.avi INTRO.avi \
    --open videos intro.asf --info 1 --active --open videos intro.asf --key cmd+z \
    --replace 'common/other.dat:scriptlets\lab-the_end.scr' '// lab - the end' '// lab - the end!' \
    --open videos intro.asf --info 1 --active >"$TMP/staleinfo.log" 2>&1 || { fail staleinfo "editor failed"; return; }
  n=$(grep '^active' "$TMP/staleinfo.log" | tr '\n' ';')
  [ "$n" = "active battles 01__port_citadel ;active videos intro.asf ;" ] || { fail staleinfo "Info not read again: $n"; return; }
  ok staleinfo
}

# What is open stays open when the catalog is read again: another tab's edits discarded
# (Discard reads everything again) keep the open character shown; a copied scene saved
# stays the scene shown (the catalog sorts it in; the open scene is kept by name).
reopen() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  cp -cR "$G" "$TMP/ro" 2>/dev/null || cp -R "$G" "$TMP/ro"
  HOME="$TMP" OPENGORKY_MUTE=1 "$ED" "$TMP/ro" --open battles 01__port_park --move 01pr_hornet03 6 5 \
    --open characters garcia --active --tab-close-at 0 discard --active \
    --tree-dup scene:museum-medusa_crazy --active --save-now --active >"$TMP/reopen.log" 2>&1 ||
    { fail reopen "editor failed"; return; }
  a=$(grep '^active' "$TMP/reopen.log" | uniq | tr '\n' ';')
  [ "$a" = "active characters common/other.dat|classes\\ft_garcia.ss ;active scenes museum-medusa_crazy_copy ;" ] ||
    { fail reopen "shown documents: $a"; return; }
  ok reopen
}

# ogproject NAME — the game converted into the new OpenGorky project $TMP/NAME (its src/
# read as it is: the scenarios add their texts, gorky-tool plays the folder).
ogproject() {
  # rules/: where the checks add their own rows (a converted Gorky 17 has no file there).
  "$TOOL" convert "$G" "$TMP/$1" >"$TMP/$1.convert" 2>&1 && mkdir -p "$TMP/$1/src/rules"
}

# The rules seam: the converted project plays as Classic (scripts/convert-regress.sh: every
# battle, three seeds, the five districts, the playthrough start, no Classic path taken).
rules() {
  sh scripts/convert-regress.sh "$G" >"$TMP/rules.log" 2>&1 || { fail rules "classic and converted differ: $(grep -E 'FAIL|differ' "$TMP/rules.log" | head -1)"; return; }
  ok rules
}

# OpenGorky: extra abilities given in the editor (--ability, the "Extra abilities"
# block) on the converted project — a hero by its archetype, an enemy by a battle's fighter
# block (keyed by its object's name, as its page keys it) — written as their own Abilities
# rows into src/rules/fighters.ogs and read by the battle: Sullivan (double_turn) moves twice
# per round, the hornet 01pr_hornet02 (immobile) never leaves its tile.
abilities() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  ogproject ab || { fail abilities "convert failed: $(tail -1 "$TMP/ab.convert")"; return; }
  { OPENGORKY_MUTE=1 "$ED" "$TMP/ab" --ability sullivan double_turn + --ability 'battles/01__port_park/battle.ogs#01pr_hornet02' immobile + --save &&
    "$TOOL" build "$TMP/ab" && "$TOOL" battle "$TMP/ab" 01__port_park 60 1; } >"$TMP/abilities.log" 2>&1 ||
    { fail abilities "editor or tool failed"; return; }
  grep -qE '^Abilities\(fighter = ~c"characters::sullivan", (class = 0, )?double_turn = true\);' "$TMP/ab/src/rules/fighters.ogs" || { fail abilities "no hero row"; return; }
  grep -qE '^Abilities\(fighter = "01pr_hornet02", (class = 0, )?immobile = true\);' "$TMP/ab/src/rules/fighters.ogs" || { fail abilities "no enemy row"; return; }
  # Two plans of Sullivan before his final tile; hornet02's final tile its start, it plans.
  twice=$(awk '/^  AI sullivan at/ { n++ } /^  AI final sullivan/ { if (n == 2) k++; n = 0 } END { print k + 0 }' "$TMP/abilities.log")
  moved=$(awk '/^  AI 01pr_hornet02 at/ { t = $4; sub(":", "", t); at = t } /^  AI final 01pr_hornet02/ { if (at != "" && at != $4) m++; k++ } END { print m + 0 " " k + 0 }' "$TMP/abilities.log")
  [ "$twice" -gt 0 ] && [ "${moved% *}" = 0 ] && [ "${moved#* }" -gt 0 ] || { fail abilities "sullivan twice $twice, hornet02 moves/plans $moved"; return; }
  ok abilities
}

# OpenGorky: the test room (--test-room) of the converted project is the build's
# (dist/play.ogp): 04__city_passing bare (no dialogue, no code of its own) with its fighter
# made of the archetype (Sullivan's size and hp), the test kit's heroes (the game's party by
# default) on its heroes' tiles; it plays to its end.
testroom() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  ogproject tr || { fail testroom "convert failed: $(tail -1 "$TMP/tr.convert")"; return; }
  { OPENGORKY_MUTE=1 "$ED" "$TMP/tr" --test-room sullivan && "$TOOL" battle "$TMP/tr/dist/play.ogp" 04__city_passing 60 1; } >"$TMP/testroom.log" 2>&1 ||
    { fail testroom "editor or tool failed"; return; }
  grep -qE '^puppet +enemy tile 3,6 size 1 hp 130 ' "$TMP/testroom.log" || { fail testroom "the room's fighter is not Sullivan's archetype"; return; }
  for h in ovitz sullivan trantigne; do grep -qE "^$h +hero " "$TMP/testroom.log" || { fail testroom "no $h in the room"; return; }; done
  grep -q '^result: ' "$TMP/testroom.log" || { fail testroom "battle did not end"; return; }
  ok testroom
}

# OpenGorky: a character made from scratch (--char-new) on the converted project:
# src/characters/new_character_1.ogs (a copy of an enemy archetype, its own look and classic_id)
# with its rows by its class (its strikes, own Abilities, roles); then edited after a reload
# (roles both, hp, move_locked) and fought in the test room (the build's): the room's fighter is
# it (hp 99), it never leaves its tile.
newchar() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  ogproject nc || { fail newchar "convert failed: $(tail -1 "$TMP/nc.convert")"; return; }
  C=characters/new_character_1.ogs
  { OPENGORKY_MUTE=1 "$ED" "$TMP/nc" --char-new --save &&
    OPENGORKY_MUTE=1 "$ED" "$TMP/nc" --roles new_character_1 both --og-set $C hp 99 --og-set $C move_locked 1 --test-room new_character_1 &&
    "$TOOL" battle "$TMP/nc/dist/play.ogp" 04__city_passing 60 1; } >"$TMP/newchar.log" 2>&1 ||
    { fail newchar "editor or tool failed"; return; }
  grep -q '^    fighter new_character_1 {' "$TMP/nc/src/$C" && grep -q '^        look = looks::new_character_1;' "$TMP/nc/src/$C" &&
    [ -e "$TMP/nc/src/looks/new_character_1.ogs" ] || { fail newchar "no archetype or look file"; return; }
  grep -q '^Character(fighter = ~c"characters::new_character_1", as_hero = true, as_enemy = true);' "$TMP/nc/src/rules/fighters.ogs" || { fail newchar "no roles row"; return; }
  grep -q '^Abilities(fighter = ~c"characters::new_character_1"' "$TMP/nc/src/rules/fighters.ogs" || { fail newchar "no own Abilities row"; return; }
  grep -qE '^puppet +enemy .* hp 99 ' "$TMP/newchar.log" || { fail newchar "not in the test room as itself"; return; }
  moved=$(awk '/^  AI puppet at/ { at = $4; sub(":", "", at) } /^  AI final puppet/ { n++; if (at != $4) m++ } END { print n + 0, m + 0 }' "$TMP/newchar.log")
  case $moved in 0\ *|*\ [1-9]*) fail newchar "move_locked: plans and moves $moved"; return ;; esac
  ok newchar
}

# OpenGorky: the test kit (--test-kit, testkit.zig) of the converted project, in
# .og/testkit.txt: the game's party with their start's things by default, Sullivan's a
# shotgun in hand and 30 rounds more; in the test room (the build's dist/play.ogp) he holds
# it and none of the start's own things is there; the project's package has none of it; its
# page draws.
testkit() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  ogproject tk || { fail testkit "convert failed: $(tail -1 "$TMP/tk.convert")"; return; }
  { OPENGORKY_MUTE=1 "$ED" "$TMP/tk" --test-kit "sullivan weapons::shotgun 1 hand" --test-kit "sullivan items::shotgun_ammo 30" --save &&
    OPENGORKY_MUTE=1 "$ED" "$TMP/tk" --test-room sullivan --open testkit "" --size 800x600 --shot "$TMP/testkit.png" &&
    "$TOOL" build "$TMP/tk" >"$TMP/testkit.build" 2>&1 && "$TOOL" battle "$TMP/tk/dist/play.ogp" 04__city_passing 60 1 &&
    "$TOOL" battle "$TMP/tk/dist/gorky.ogp" 01__port_barge 60 1 >"$TMP/testkit.pkg" 2>&1; } >"$TMP/testkit.log" 2>&1 ||
    { fail testkit "editor or tool failed"; return; }
  # His weapon the kit's, with more rounds than a pistol's 12: the shotgun.
  held=$(awk '/^sullivan +hero / { print $NF; exit }' "$TMP/testkit.log")
  rounds=$(awk -v w="$held" '$1 == w ":" && $2 == "ammo" { print $3; exit }' "$TMP/testkit.log")
  case $held in og_tk_*) ;; *) fail testkit "Sullivan holds no kit weapon ($held)"; return ;; esac
  [ "${rounds:-0}" -gt 12 ] || { fail testkit "Sullivan's weapon is not the shotgun ($held, $rounds rounds)"; return; }
  grep -qE 'su_|ov_|tr_' "$TMP/testkit.log" && { fail testkit "the start's own things are there"; return; }
  grep -q '^sullivan weapons::shotgun 1 hand' "$TMP/tk/.og/testkit.txt" && grep -q '^hero sullivan' "$TMP/tk/.og/testkit.txt" || { fail testkit "kit file gone"; return; }
  grep -q 'og_tk_' "$TMP/testkit.pkg" && { fail testkit "package has the kit"; return; }
  [ -s "$TMP/testkit.png" ] || { fail testkit "kit page not drawn"; return; }
  ok testkit
}

# OpenGorky: a walk path (`01_port.ap` and `deska.pth` → the level's `path deska` block in
# paths.ogs: its link, points and OnNode; the game's `.ap` not read) walks Ovitz over the plank as Classic does (walk_footbridge, then the
# interpolation wait): the plank scene goes on in the next level on the same tick, its
# shotgun ammo in Ovitz's backpack.
pathscript() {
  ogproject ps || { fail pathscript "convert failed: $(tail -1 "$TMP/ps.convert")"; return; }
  grep -q '^    path deska {' "$TMP/ps/src/locations/01_port/paths.ogs" && grep -q 'PathPoint(x = 1460, y = 180' "$TMP/ps/src/locations/01_port/paths.ogs" &&
    grep -q 'path::SetWalkAnimation("walk_footbridge")' "$TMP/ps/src/locations/01_port/paths.ogs" || { fail pathscript "no path deska block with its points and code"; return; }
  set -- new autorefill autolevel autoequip wait:300 scene loot goto:trupy scene use:decha:brzeg_na_deske scene inv
  "$TOOL" play "$G" "$@" >"$TMP/pathscript.classic" 2>&1
  OPENGORKY_GAME="$G" "$TOOL" play "$TMP/ps" "$@" >"$TMP/pathscript.og" 2>&1
  c=$(LC_ALL=C grep -a "port-deska' (continued)" "$TMP/pathscript.classic")
  o=$(LC_ALL=C grep -a "port-deska' (continued)" "$TMP/pathscript.og")
  [ -n "$c" ] && [ "$c" = "$o" ] || { fail pathscript "Classic \"$c\", OpenGorky \"$o\""; return; }
  # The scene's shotgun ammo (item::Give) is Ovitz's though he has no empty start pack of it.
  LC_ALL=C grep -aq '^  01p_shotgun_ammo: ovitz, place 1' "$TMP/pathscript.og" || { fail pathscript "Ovitz lost the scene's shotgun ammo"; return; }
  ok pathscript
}

# OpenGorky: a battle without its own post-processing takes that of the location
# whose code starts it (the OG reader's starts, loaders/ogs.zig scanStarts): 01_port (its
# scene::Start of "port-out bt", which LOADLEVELs 01__port_park) and 03_museum_observator (its
# level::Load of 03__museum_chopper; not 03_museum, as a name rule would give) get a step,
# then one added on each battle makes its own row a copy of that chain plus it.
postchain() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  ogproject pc || { fail postchain "convert failed: $(tail -1 "$TMP/pc.convert")"; return; }
  OPENGORKY_MUTE=1 "$ED" "$TMP/pc" --post-for 01_port --post add grade - --post-for 01__port_park --post add vignette - \
    --post add hsl - --post 2 rgb "[1.4, 1.5, 0.9]" --post 2 k 0.8 \
    --post-for 03_museum_observator --post add scanlines - --post-for 03__museum_chopper --post add vignette - --save >"$TMP/postchain.log" 2>&1 ||
    { fail postchain "editor failed"; return; }
  # A row too long for a line is on several (the OG printer): read it flattened.
  tr -d ' \n' <"$TMP/pc/src/rules/fx.ogs" | grep -qE 'PostChain\(level="01__port_park"[^;]*Post\(program=grade\),Post\(program=vignette' ||
    { fail postchain "the battle's chain is not its location's"; return; }
  tr -d ' \n' <"$TMP/pc/src/rules/fx.ogs" | grep -qE 'PostChain\(level="03__museum_chopper"[^;]*Post\(program=scanlines,k=0.5\),Post\(program=vignette' ||
    { fail postchain "03__museum_chopper's chain is not 03_museum_observator's"; return; }
  # The battle's chain (grade, vignette, hsl): on the GPU renderer its shader (frame.zig
  # applyPost) changes the frame; on the CPU one it is ignored (scripts/pngdiff.py: the
  # frames differ). No GPU: skipped.
  for r in cpu gpu; do
    OPENGORKY_MUTE=1 perl -e 'alarm 90; exec @ARGV' "$TOOL" play "$TMP/pc" --start battle:01__port_park --renderer $r --time 1000 --shot "$TMP/postchain_$r.png" >"$TMP/postchain_$r.log" 2>&1 ||
      { cp "$TMP/postchain_$r.log" "$TMP/postchain.log"; fail postchain "play failed ($r)"; return; }
  done
  grep -q 'post-processing off: not the GPU renderer' "$TMP/postchain_cpu.log" || { fail postchain "the CPU renderer did not turn post-processing off"; return; }
  if grep -q 'post-processing: GPU shader' "$TMP/postchain_gpu.log"; then
    ! python3 -I scripts/pngdiff.py "$TMP/postchain_cpu.png" "$TMP/postchain_gpu.png" >>"$TMP/postchain.log" 2>&1 ||
      { fail postchain "the GPU frame is not post-processed: $(tail -1 "$TMP/postchain.log")"; return; }
  fi
  ok postchain
}

# OpenGorky: scripted edits of OG blocks (scripts/editor-golden-og.sh) write only
# the changed statements, and the edited project still builds and plays (its checks).
ogedit() {
  sh scripts/editor-golden-og.sh "$G" >"$TMP/ogedit.log" 2>&1 || { fail ogedit "$(grep FAIL "$TMP/ogedit.log" | head -1)"; return; }
  ok ogedit
}

# OpenGorky: scripted abilities (combat/events.zig; docs/og-script.md §15, its
# components and rows taken from there) in the converted game. Garcia: Reflect (half of a
# hit back to the hitter) and Invulnerable for its first turn (the heroes' first-turn hits
# on it come to 0); Grandma's children count their deaths (battle::AddVar), Grandma sets
# her target and rages at two (OnVar). An OnHit that keeps the damage has no `return` (nil:
# unchanged, dispatch.zig). The same battles before the components are attached show none.
scripted() {
  ogproject sc || { fail scripted "convert failed: $(tail -1 "$TMP/sc.convert")"; return; }
  awk '/^## 15\. / { f = 1 } f && /^```ogs/ { p = 1; next } p && /^```/ { exit } p' docs/og-script.md >"$TMP/sc/src/components/scripted.ogs"
  # Appended one by one: the battle tool writes from the start of its output file.
  log() { "$@" >"$TMP/scripted.one" 2>&1; k=$?; cat "$TMP/scripted.one" >>"$TMP/scripted.log"; return $k; }
  : >"$TMP/scripted.log"
  { log env OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/sc" 01__port_park 60 1 && log env OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/sc" 01__port_citadel 60 1; } ||
    { fail scripted "tool failed"; return; }
  grep -q -e '^  OnHit ' -e ' reflect damage ' -e '^  var grandma_kids' "$TMP/scripted.log" && { fail scripted "effects without the components"; return; }
  grep -q '^component Reflect for fighter {' "$TMP/sc/src/components/scripted.ogs" || { fail scripted "no components in docs/og-script.md §15"; return; }
  # Both Garcias (classic_id 101), not the example's one by name.
  awk '/^## 15\. / { f = 1 } f && /^```ogs/ { n++; p = n == 2; next } p && /^```/ { exit } p' docs/og-script.md |
    sed 's/fighter = "01pr_garcia1"/fighter = ~c"characters::garcia"/' >"$TMP/sc/src/rules/scripted.ogs"
  : >"$TMP/scripted.log"
  { log env OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/sc" 01__port_park 60 1 && log env OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/sc" 01__port_citadel 60 1; } ||
    { fail scripted "tool failed"; return; }
  # Invulnerable: a hit on Garcia comes to 0 (its first turn), later ones go through.
  grep -q '^  OnHit 01pr_garcia[12] <- [A-Za-z]*: [1-9][0-9]* -> 0$' "$TMP/scripted.log" || { fail scripted "Garcia not invulnerable"; return; }
  grep -q '^  01pr_garcia[12]: -[1-9]' "$TMP/scripted.log" || { fail scripted "Garcia never hurt after its first turn"; return; }
  # Reflect: the hitter takes half (fighter::Damage, then its damage line).
  grep -A1 '^  [A-Za-z]*: reflect damage [1-9]' "$TMP/scripted.log" | grep -q '^  [A-Za-z]*: -[1-9]' || { fail scripted "no reflected damage"; return; }
  grep -q '^  grandma: target [A-Za-z]' "$TMP/scripted.log" && grep -q '^  var grandma_kids = 2$' "$TMP/scripted.log" &&
    grep -q '^  grandma: rage 99$' "$TMP/scripted.log" || { fail scripted "Grandma's children: no target, counter or rage"; return; }
  ok scripted
}

# OpenGorky: the battle's decision points in 01__port_park of the converted game
# through scripted abilities on the heroes (classic_id 20–22) and the hornets (128) and Garcias
# (101): every point answering nil plays the battle as without them (only the hot points'
# call counts are new lines); numbers change it, each point noted (`  Armor x: 0 -> 1`), the
# events seen (battle::SetVar), the AI's ScoreTarget calls counted, and the same seed plays
# the same again. CounterChance 1000: more counter-attacks than the heroes' own 10% (a play
# with rifles in hand).
points() {
  ogproject pt || { fail points "convert failed: $(tail -1 "$TMP/pt.convert")"; return; }
  # By archetype: a converted project has no classic_id (the heroes, the hornets, the Garcias).
  printf '%s\n' 'Abilities(fighter = ~c"characters::sullivan", class = 0, scripts = list(HeroPoints()));' 'Abilities(fighter = ~c"characters::ovitz", class = 0, scripts = list(HeroPoints()));' \
    'Abilities(fighter = ~c"characters::trantigne", class = 0, scripts = list(HeroPoints()));' 'Abilities(fighter = ~c"characters::hornet", class = 0, scripts = list(EnemyPoints()));' \
    'Abilities(fighter = ~c"characters::garcia", class = 0, scripts = list(EnemyPoints()));' >"$TMP/points.rows"
  cat >"$TMP/points-nil.ogs" <<'OGS'
component HeroPoints for fighter {
    fn HitChance(target, weapon, chance) { } fn ChanceToBeHit(attacker, weapon, chance) { } fn Armor(attacker, weapon, armor) { }
    fn WalkRange(range) { } fn ExperienceGain(amount) { } fn CounterChance(attacker, chance) { }
}
component EnemyPoints for fighter {
    fn HitChance(target, weapon, chance) { } fn ChanceToBeHit(attacker, weapon, chance) { } fn Armor(attacker, weapon, armor) { }
    fn WalkRange(range) { } fn KillReward(killer, amount) { } fn PreferTarget() { } fn ScoreTarget(occupant, weapon, score) { }
}
OGS
  cat >"$TMP/points-num.ogs" <<'OGS'
component HeroPoints for fighter {
    fn HitChance(target, weapon, chance) { return chance + 5; }
    fn ChanceToBeHit(attacker, weapon, chance) { return chance - 5; }
    fn Armor(attacker, weapon, armor) { return armor + 1; }
    fn WalkRange(range) { return range + 1; }
    fn ExperienceGain(amount) { return amount + 1000; }
    fn OnLevelUp(level) { battle::SetVar("level_" + host.name, level); }
    fn OnSkillUp(weapon, level) { battle::SetVar("skill_" + host.name, level); }
    fn CounterChance(attacker, chance) { return 1000; }
    fn OnDamageDealt(target, weapon, lost) { battle::AddVar("dealt", lost); }
}
component EnemyPoints for fighter {
    fn HitChance(target, weapon, chance) { return chance - 5; }
    fn ChanceToBeHit(attacker, weapon, chance) { return chance + 5; }
    fn Armor(attacker, weapon, armor) { return armor + 1; }
    fn WalkRange(range) { if (range > 1) return range - 1; }
    fn KillReward(killer, amount) { return amount + 50; }
    fn PreferTarget() { return @Sullivan; }
    fn ScoreTarget(occupant, weapon, score) { if (occupant.side == foundation::Side::hero) return score + 7; }
}
OGS
  B="01__port_park 60 1"
  export OPENGORKY_GAME="$G"
  # shellcheck disable=SC2086
  { "$TOOL" battle "$TMP/pt" $B >"$TMP/points.none" 2>&1 && cp "$TMP/points.rows" "$TMP/pt/src/rules/points.ogs" &&
    cp "$TMP/points-nil.ogs" "$TMP/pt/src/components/points.ogs" && "$TOOL" battle "$TMP/pt" $B >"$TMP/points.nil" 2>&1 &&
    cp "$TMP/points-num.ogs" "$TMP/pt/src/components/points.ogs" &&
    "$TOOL" battle "$TMP/pt" $B >"$TMP/points.log" 2>&1 && "$TOOL" battle "$TMP/pt" $B >"$TMP/points.again" 2>&1; } ||
    { fail points "tool failed"; return; }
  grep -q -E '^  ScoreTarget 01pr_hornet[0-9]+: [0-9]+ calls$' "$TMP/points.nil" || { fail points "nil ScoreTarget not counted"; return; }
  grep -v -E '^  (ScoreTarget|CanAim) [^ ]+: [0-9]+ calls$' "$TMP/points.nil" | cmp -s - "$TMP/points.none" || { fail points "nil changed the battle"; return; }
  cmp -s "$TMP/points.log" "$TMP/points.none" && { fail points "the numbers changed nothing"; return; }
  cmp -s "$TMP/points.log" "$TMP/points.again" || { fail points "the same seed played otherwise"; return; }
  for p in '  HitChance [Ss]ullivan: ' '  ChanceToBeHit 01pr_hornet' '  Armor ' '  WalkRange ' '  ExperienceGain ' '  var level_' '  var skill_' \
    '  var dealt = ' '  KillReward 01pr_' '  PreferTarget 01pr_[a-z0-9]*: [Ss]ullivan$' '  ScoreTarget 01pr_hornet[0-9]*: [1-9][0-9]* calls$'; do
    grep -q -e "^$p" "$TMP/points.log" || { fail points "no \"$p\""; return; }
  done
  set -- autoequip blog passive counters level:01__port_park cmd:pick+su_rifle cmd:pick+ov_rifle cmd:pick+tr_rifle wait:3000
  "$TOOL" play "$G" 01_port "$@" >"$TMP/points.counter0" 2>&1 && "$TOOL" play "$TMP/pt" 01_port "$@" >"$TMP/points.counter" 2>&1 ||
    { fail points "play failed"; return; }
  n0=$(grep -c ': counterattack$' "$TMP/points.counter0")
  n=$(grep -c ': counterattack$' "$TMP/points.counter")
  grep -q '^  CounterChance [A-Za-z]*: [0-9]* -> 1000$' "$TMP/points.counter" && [ "$n" -gt "$n0" ] ||
    { fail points "CounterChance 1000: $n counter-attacks, $n0 without"; return; }
  ok points
}

# OpenGorky: a boss with phases (docs/og-script.md §15.1, its Phoenix taken from there) in
# 01__port_park of the converted game: Garcia refuses to die while phases remain (CanDie),
# its guardians come (battle::SpawnEnemy: two hornets, then two Garcias of their archetypes,
# armed as the level's), it rises when they are dead, the first time as a hornet
# (fighter::Transform: the full health its script set kept, Phoenix kept with its phase),
# then dies for good; the heroes strike ×4 (Mighty) to end it in time. The same seed plays
# the same again (the guardians: the converted characters::hornet and ::garcia).
phoenix() {
  ogproject ph || { fail phoenix "convert failed: $(tail -1 "$TMP/ph.convert")"; return; }
  { awk '/^### 15\.1/ { f = 1 } f && /^```ogs/ { p = 1; next } p && /^```/ { exit } p' docs/og-script.md
    echo 'component Mighty for fighter { fn OnStrike(target, weapon, amount) { return amount * 4; } }'; } >"$TMP/ph/src/components/phoenix.ogs"
  { awk '/^### 15\.1/ { f = 1 } f && /^```ogs/ { n++; p = n == 2; next } p && /^```/ { exit } p' docs/og-script.md
    printf '%s\n' 'Abilities(fighter = "sullivan", class = 0, scripts = list(Mighty()));' 'Abilities(fighter = "ovitz", class = 0, scripts = list(Mighty()));' \
      'Abilities(fighter = "trantigne", class = 0, scripts = list(Mighty()));'; } >"$TMP/ph/src/rules/phoenix.ogs"
  { OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/ph" 01__port_park 60 1 >"$TMP/phoenix.log" 2>&1 && OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/ph" 01__port_park 60 1 >"$TMP/phoenix.again" 2>&1; } ||
    { fail phoenix "tool failed"; return; }
  grep -q '^component Phoenix for fighter' "$TMP/ph/src/components/phoenix.ogs" || { fail phoenix "no Phoenix in docs/og-script.md §15.1"; return; }
  # The order of events: down, its two hornets die, it rises as one; down, two Garcias die; dies.
  seq=$(awk '/^  01pr_garcia1: CanDie false$/ { printf "D" } /^  var guard_hornet[_0-9]* = 1$/ { printf "h" } /^  var guard_garcia[_0-9]* = 2$/ { printf "g" }
    /^  (hornet|garcia)[_0-9]* dies$/ { printf "x" } /^  01pr_garcia1: transform$/ { printf "T" } /^  01pr_garcia1 dies$/ { printf "!" } /^result: won/ { printf "W" }' "$TMP/phoenix.log")
  [ "$seq" = "hhDxxTggDxx!W" ] || { fail phoenix "events \"$seq\", expected hhDxxTggDxx!W"; return; }
  # Risen: the last blow found it above 1 hp (the health set after the transform kept).
  last=$(grep -B1 '^  01pr_garcia1 dies$' "$TMP/phoenix.log" | sed -n 's/^  01pr_garcia1: -\([0-9]*\) .*, left \(-*[0-9]*\)$/\1 \2/p')
  [ -n "$last" ] && [ $(( ${last% *} + ${last#* } )) -gt 1 ] || { fail phoenix "not risen before its death ($last)"; return; }
  grep -q -E '^turn [0-9]+: (hornet|garcia)[_0-9]* hits ' "$TMP/phoenix.log" || { fail phoenix "the guardians never struck (no weapons)"; return; }
  # Its script's fighter::SetHp on rising is in the battle log, twice (two phases).
  [ "$(grep -c '^  01pr_garcia1: hp set [0-9]*$' "$TMP/phoenix.log")" -eq 2 ] || { fail phoenix "fighter::SetHp not logged twice"; return; }
  cmp -s "$TMP/phoenix.log" "$TMP/phoenix.again" || { fail phoenix "the same seed played otherwise"; return; }
  ok phoenix
}

# OpenGorky: events between components (docs/og-script.md §14.1, its example and rows taken
# from there) in 01__port_citadel of the converted game: each of Grandma's children emits
# child_died at its death, Grandma (subscribed in OnSpawn) turns on the killer and rages at
# the second, then unsubscribes, so the third is heard by nobody; each Emit is a battle log
# line. The same seed plays the same again.
events() {
  ogproject ev || { fail events "convert failed: $(tail -1 "$TMP/ev.convert")"; return; }
  awk '/^### 14\.1/ { f = 1 } f && /^```ogs/ { p = 1; next } p && /^```/ { exit } p' docs/og-script.md >"$TMP/ev/src/components/events.ogs"
  awk '/^### 14\.1/ { f = 1 } f && /^```ogs/ { n++; p = n == 2; next } p && /^```/ { exit } p' docs/og-script.md >"$TMP/ev/src/rules/events.ogs"
  { OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/ev" 01__port_citadel 60 1 >"$TMP/events.log" 2>&1 && OPENGORKY_GAME="$G" "$TOOL" battle "$TMP/ev" 01__port_citadel 60 1 >"$TMP/events.again" 2>&1; } ||
    { fail events "tool failed"; return; }
  grep -q '^component Grandma for fighter' "$TMP/ev/src/components/events.ogs" && grep -q "Grandma()" "$TMP/ev/src/rules/events.ogs" || { fail events "no example in docs/og-script.md §14.1"; return; }
  # Two deaths heard by Grandma alone (n=1 each: a target set, rage at the second), the
  # third by nobody (she unsubscribed: n=0). Each death first sets her target in the
  # child's own OnDeath (the converted avenger: target, then the turn ends).
  seq=$(awk '/^  grandma: target [A-Za-z]/ { printf "t" } /^  grandma: rage 99$/ { printf "R" } /^  emit child_died n=1$/ { printf "e" } /^  emit child_died n=0$/ { printf "0" } /^  emit / && !/n=[01]$/ { printf "?" }' "$TMP/events.log")
  [ "$seq" = "ttettRet0" ] || { fail events "events \"$seq\", expected ttettRet0"; return; }
  cmp -s "$TMP/events.log" "$TMP/events.again" || { fail events "the same seed played otherwise"; return; }
  ok events
}

# A Classic script edited as OG Script: a statement
# typed into the OG Script view of a level script comes back through the Classic exporter as
# one line of the original's language (sound::Play as the exe's PlaySound), nothing else
# changed; an OG Script-only value (nil) is refused and nothing is written.
ogsview() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  cp -cR "$G" "$TMP/ov" 2>/dev/null || cp -R "$G" "$TMP/ov"
  { OPENGORKY_MUTE=1 "$ED" "$TMP/ov" --level 01__port_park --code lev --code-view ogs --code-at 9 5 --type 'sound::Play("a"); $' --save &&
    OPENGORKY_MUTE=1 "$ED" "$TMP/ov" --level 01__port_park --code lev --code-view ogs --code-at 9 5 --type 'sound::Play(nil); $' --save &&
    mkdir -p "$TMP/ov_a" "$TMP/ov_b" && "$TOOL" extract "$G/dat/01__port_park/other.dat" "$TMP/ov_a" 01__port_park.lev &&
    "$TOOL" extract "$TMP/ov/dat/01__port_park/other.dat" "$TMP/ov_b" 01__port_park.lev; } >"$TMP/ogsview.log" 2>&1 ||
    { fail ogsview "editor or tool failed"; return; }
  d=$(diff "$TMP/ov_a/01__port_park.lev" "$TMP/ov_b/01__port_park.lev" | tr -d '\r')
  [ "$d" = "$(printf '11a12\n>     PlaySound("a");')" ] || { fail ogsview "unexpected change: $d"; return; }
  ok ogsview
}

# A frame series (--frames N --frames-dir DIR) on its own, without --shot: the run writes
# N frames and exits (it used to fall into the interactive loop of the hidden window and
# never return); --frames without a level fails at once.
frames() {
  sdl_env
  mkdir -p "$TMP/frames"
  # a hang fails after 60 s instead of blocking the suite
  OPENGORKY_MUTE=1 perl -e 'alarm 60; exec @ARGV' "$VIEWER" "$G" 01__port_park/sprite.dat --level --heroes --frames 20 --frames-dir "$TMP/frames" >"$TMP/frames.log" 2>&1 ||
    { fail frames "viewer failed"; return; }
  n=$(ls "$TMP/frames" | grep -c '\.png$')
  [ "$n" = 20 ] || { fail frames "$n frames written, expected 20"; return; }
  OPENGORKY_MUTE=1 "$VIEWER" "$G" 01__port_park/sprite.dat --frames 20 --frames-dir "$TMP/frames" >>"$TMP/frames.log" 2>&1 &&
    { fail frames "--frames without --level did not fail"; return; }
  ok frames
}

# OpenGorky: the editor converts the game it has open (--convert-to: Settings →
# "Convert to OpenGorky…", the folder chosen, the run waited for), builds dist/ and
# starts anew on the new project: its shot is of the summary window. The project is the same
# bytes as gorky-tool convert's (dist/ too); the game is not written; a canceled run leaves
# the folder empty, a folder with anything in it is refused.
convert_ui() {
  ED=${EDITOR_BIN:-./zig-out/bin/opengorky-editor}
  sdl_env
  touch "$TMP/cu.stamp"
  OPENGORKY_MUTE=1 "$ED" "$G" --lang en --convert-to "$TMP/cu" --shot "$TMP/cu.png" >"$TMP/convert-ui.log" 2>&1 || { fail convert-ui "the editor failed"; return; }
  grep -q '^Converted to OpenGorky: converted: objects [0-9]*,' "$TMP/convert-ui.log" || { fail convert-ui "no summary in the new project's session"; return; }
  [ -s "$TMP/cu.png" ] && [ -f "$TMP/cu/dist/gorky.ogp" ] && grep -q '^format = ogs' "$TMP/cu/opengorky.mod" || { fail convert-ui "no project, package or shot"; return; }
  "$TOOL" convert "$G" "$TMP/cu_tool" >>"$TMP/convert-ui.log" 2>&1 || { fail convert-ui "gorky-tool convert failed"; return; }
  diff -r "$TMP/cu" "$TMP/cu_tool" >>"$TMP/convert-ui.log" 2>&1 || { fail convert-ui "the editor's project differs from gorky-tool convert's"; return; }
  [ -z "$(find "$G" -newer "$TMP/cu.stamp" | head -1)" ] || { fail convert-ui "the game was written"; return; }
  OPENGORKY_MUTE=1 "$ED" "$G" --lang en --convert-cancel "$TMP/cc" >>"$TMP/convert-ui.log" 2>&1 && [ -z "$(ls -A "$TMP/cc")" ] || { fail convert-ui "a canceled run left files"; return; }
  OPENGORKY_MUTE=1 "$ED" "$G" --convert-to "$TMP/cu" >>"$TMP/convert-ui.log" 2>&1 && { fail convert-ui "a folder with files was not refused"; return; }
  grep -q 'FolderNotEmpty' "$TMP/convert-ui.log" || { fail convert-ui "no FolderNotEmpty"; return; }
  ok convert-ui
}

# Release: saves of an OpenGorky project. The converted game played with a save and load
# at every location (autosaveload) and the game-over "Yes" in every battle (battlereload: the
# "battle" save) through the port, two battles and a location change; then saved in the
# silos, loaded in a fresh run and played on into the sewers. Each log is the Classic game's
# with the same commands (the converted plays as Classic, `rules`): the save restores the
# project's objects from their blocks and archetypes (no "class og" missing), its values too.
ogsave() {
  ogproject os || { fail ogsave "convert failed: $(tail -1 "$TMP/os.convert")"; return; }
  run="battlereload autosaveload $(prefix goto:store_enter) loot goto:exit2port goto:fight11_place scene wait:600"
  # shellcheck disable=SC2086
  { "$TOOL" play "$TMP/os" 01_port $run "savefile:$TMP/os.sav" >"$TMP/ogsave.log" 2>&1 &&
    "$TOOL" play "$G" 01_port $run "savefile:$TMP/osc.sav" >"$TMP/ogsave.cl" 2>&1 &&
    "$TOOL" play "$TMP/os" 01_port "loadsave:$TMP/os.sav" goto:exit2sewers wait:300 scene >"$TMP/ogsave.load" 2>&1 &&
    "$TOOL" play "$G" 01_port "loadsave:$TMP/osc.sav" goto:exit2sewers wait:300 scene >"$TMP/ogsave.loadcl" 2>&1; } ||
    { fail ogsave "play failed"; return; }
  [ "$(grep -c '] saveload ' "$TMP/ogsave.log")" -ge 10 ] && [ "$(grep -c '] battle reload ' "$TMP/ogsave.log")" -ge 8 ] &&
    grep -q 'transition 01_port_silos' "$TMP/ogsave.load" || { fail ogsave "too few saves, reloads or no way on after the load"; return; }
  grep -q '^not implemented: .*class' "$TMP/ogsave.log" "$TMP/ogsave.load" && { fail ogsave "objects not made again: $(grep -h '^not implemented' "$TMP/ogsave.log" | head -1)"; return; }
  # Scene names keep the case of the text that starts them (port-out bt / BT).
  for x in log:cl load:loadcl; do
    LC_ALL=C tr A-Z a-z <"$TMP/ogsave.${x%:*}" | grep -v '^> loadsave:\|^> savefile:\|^  saved ' >"$TMP/ogsave.a"
    LC_ALL=C tr A-Z a-z <"$TMP/ogsave.${x#*:}" | grep -v '^> loadsave:\|^> savefile:\|^  saved ' >"$TMP/ogsave.b"
    cmp -s "$TMP/ogsave.a" "$TMP/ogsave.b" || { fail ogsave "differs from Classic (${x%:*}): $(diff "$TMP/ogsave.a" "$TMP/ogsave.b" | sed -n 2p)"; return; }
  done
  # Values changed in play that a line of their own cannot hold (save.zig `v:`): a list with
  # a nested list and a reference, a list of records, a record, a reference, nil. Through a
  # save in memory and a file read by a new process they come back, the references live
  # (`==` the object); one to an object not in the world (the file edited) comes back nil.
  sed -i.bak 's/^    var int isMatrixDisc;$/&\
    var o_list = [1, 2]; var o_places; var o_rec; var o_who; var o_nil = 5; var o_lost; var o_live;/' "$TMP/os/src/locations/01_port/level.ogs"
  sed -i.bak 's/^level "01_port" {$/&\
    fn OgSet() {\
        o_list = [3, 4, [5], @Ovitz, 2.0]; o_rec = foundation::Place(who = @Ovitz, tile = [7, 8]);\
        o_places = [foundation::Place(who = @Sullivan, tile = [1, 2]), foundation::Place(who = @Trantigne, at = "capt_start1", point = 1)];\
        o_who = @Sullivan; o_nil = nil; o_lost = [@Trantigne];\
    }\
    fn OgCheck() { o_live = [o_who == @Sullivan, o_list[3] == @Ovitz]; }/' "$TMP/os/src/locations/01_port/logic.ogs"
  get=""; for v in list places rec who nil lost; do get="$get cmd:get+01_port+o_$v"; done
  # shellcheck disable=SC2086
  "$TOOL" play "$TMP/os" 01_port cmd:call+01_port+OgSet saveload $get "savefile:$TMP/ov.sav" >"$TMP/ogsave.vset" 2>&1 &&
    sed -i.bak '/^var o_lost /s/@"trantigne"/@"nobody"/' "$TMP/ov.sav" &&
    "$TOOL" play "$TMP/os" 01_port "loadsave:$TMP/ov.sav" $get cmd:call+01_port+OgCheck cmd:get+01_port+o_live >"$TMP/ogsave.vload" 2>&1 ||
    { fail ogsave "play failed (values)"; return; }
  grep '^01_port\.o_' "$TMP/ogsave.vset" | sed 's/^01_port.o_lost = .*/01_port.o_lost = [nil]/' >"$TMP/ogsave.a"
  echo '01_port.o_live = [true, true]' >>"$TMP/ogsave.a"
  grep '^01_port\.o_' "$TMP/ogsave.vload" >"$TMP/ogsave.b"
  [ "$(grep -c '^01_port\.o_' "$TMP/ogsave.a")" = 7 ] && grep -q '^01_port.o_list = \[3, 4, \[5\], @ovitz, 2\]$' "$TMP/ogsave.a" ||
    { fail ogsave "values not set in play: $(head -1 "$TMP/ogsave.a")"; return; }
  cmp -s "$TMP/ogsave.a" "$TMP/ogsave.b" || { fail ogsave "values after the load: $(diff "$TMP/ogsave.a" "$TMP/ogsave.b" | sed -n 2p)"; return; }
  # A component instance's vars (OgComp, attached to the level: a count, a reference) and
  # its subscription come back through a save in memory and a file read by a new process
  # (OgPing heard after each); a hero's var holding an object of 01_port (ponton) is that
  # location's in the store (`@01_port::ponton`, also in the file) and the object again
  # once the party is back. The file edited (no OgComp, no such host): the component keeps
  # its defaults and nobody hears og_ping.
  sed -i.bak 's/^    var int isMatrixDisc;$/&\
    var o_far;/' "$TMP/os/src/locations/01_port/level.ogs"
  sed -i.bak 's/^        var int dx = 1;$/&\
        var o_pal;/' "$TMP/os/src/characters/sullivan.ogs"
  sed -i.bak 's/^    var o_far;$/&\
    attach locations::_01_port::OgComp();/' "$TMP/os/src/locations/01_port/level.ogs"
  cat >>"$TMP/os/src/locations/01_port/logic.ogs" <<'EOF'
module locations::_01_port {
    component OgComp for level {
        var c_n = 0; var c_who;
        fn OgSub() { c_n = 7; c_who = @ponton; events::Subscribe("og_ping", "OgPing"); @Sullivan.o_pal = @ponton; }
        fn OgPing() { c_n += 10; }
        fn OgFar() { events::Emit("og_ping"); o_far = [c_n, c_who == @ponton, @Sullivan.o_pal == @ponton, object::IsHere(@Sullivan.o_pal)]; }
    }
}
EOF
  "$TOOL" play "$TMP/os" 01_port cmd:call+01_port+OgSub saveload cmd:call+01_port+OgFar cmd:get+01_port+o_far \
    level:01_port_store cmd:get+Sullivan+o_pal "savefile:$TMP/of.sav" >"$TMP/ogsave.fset" 2>&1 &&
    "$TOOL" play "$TMP/os" 01_port "loadsave:$TMP/of.sav" cmd:get+Sullivan+o_pal level:01_port cmd:get+Sullivan+o_pal \
      cmd:call+01_port+OgFar cmd:get+01_port+o_far >"$TMP/ogsave.fload" 2>&1 &&
    sed -e 's/^comp OgComp$/comp Nope/' -e 's/^sub 01_port#OgComp /sub nobody#OgComp /' "$TMP/of.sav" >"$TMP/ofx.sav" &&
    "$TOOL" play "$TMP/os" 01_port "loadsave:$TMP/ofx.sav" level:01_port cmd:call+01_port+OgFar cmd:get+01_port+o_far >"$TMP/ogsave.fx" 2>&1 ||
    { fail ogsave "play failed (components, far)"; return; }
  printf '%s\n' '01_port.o_far = [17, true, true, true]' 'sullivan.o_pal = @01_port::ponton' >"$TMP/ogsave.a"
  printf '%s\n' 'sullivan.o_pal = @01_port::ponton' 'sullivan.o_pal = @ponton' '01_port.o_far = [27, true, true, true]' >>"$TMP/ogsave.a"
  echo '01_port.o_far = [0, false, true, true]' >>"$TMP/ogsave.a"
  cat "$TMP/ogsave.fset" "$TMP/ogsave.fload" "$TMP/ogsave.fx" | grep '^01_port\.o_far \|^sullivan\.o_pal ' >"$TMP/ogsave.b"
  cmp -s "$TMP/ogsave.a" "$TMP/ogsave.b" && grep -q '^var o_pal v:@"01_port::ponton"$' "$TMP/of.sav" && grep -q '^sub 01_port#OgComp OgPing og_ping$' "$TMP/of.sav" &&
    grep -q 'has no component Nope' "$TMP/ogsave.fx" ||
    { fail ogsave "components, far references: $(diff "$TMP/ogsave.a" "$TMP/ogsave.b" | sed -n 2p)"; return; }
  # A hero's component instance (a counter and its subscription) and his pistol's go with
  # the party as his own vars do: changed in 01_port, kept in the store, back in 01_port (its
  # stale copy replaced, the event heard once), then through a save in a new process and
  # into the store again (101, 201, 301: one og_hero heard per OgHcGet).
  sed -i.bak 's/^        var int dx = 1;$/&\
        var o_hc; var o_pi;/' "$TMP/os/src/characters/sullivan.ogs"
  # A component of its own (its instance's variable c_hc), attached to the hero (whose class
  # code is in its block, so not this one).
  sed -i.bak 's/^        var int dx = 1;$/&\
        attach og_hc();/; s/^module characters {$/&\
    component og_hc for fighter {\
        var c_hc = 0;\
        fn OgHc() { c_hc += 1; events::Subscribe("og_hero", "OgHeard"); }\
        fn OgHeard() { c_hc += 100; }\
        fn OgHcGet() { events::Emit("og_hero"); host.o_hc = c_hc; }\
    }/' "$TMP/os/src/characters/sullivan.ogs"
  sed -i.bak 's/^        class = pistol;$/&\
        attach og_pi();/; s/^module weapons {$/&\
    component og_pi for weapon {\
        var c_pi = 0;\
        fn OgPi() { c_pi = 5; }\
        fn OgPiGet() { @Sullivan.o_pi = c_pi; }\
    }/' "$TMP/os/src/weapons/pistol.ogs"
  hc="cmd:call+Sullivan+OgHcGet cmd:call+su_pistol+OgPiGet cmd:get+Sullivan+o_hc cmd:get+Sullivan+o_pi"
  # shellcheck disable=SC2086
  "$TOOL" play "$TMP/os" 01_port cmd:call+Sullivan+OgHc cmd:call+su_pistol+OgPi level:01_port_store $hc level:01_port $hc \
    "savefile:$TMP/oh.sav" >"$TMP/ogsave.hset" 2>&1 &&
    "$TOOL" play "$TMP/os" 01_port "loadsave:$TMP/oh.sav" level:01_port_store $hc >"$TMP/ogsave.hload" 2>&1 ||
    { fail ogsave "play failed (hero components)"; return; }
  for n in 101 201 301; do printf 'sullivan.o_hc = %s\nsullivan.o_pi = 5\n' $n; done >"$TMP/ogsave.a"
  cat "$TMP/ogsave.hset" "$TMP/ogsave.hload" | grep '^sullivan\.o_[hp][ci] ' >"$TMP/ogsave.b"
  cmp -s "$TMP/ogsave.a" "$TMP/ogsave.b" && grep -q '^sub sullivan#og_hc OgHeard og_hero$' "$TMP/oh.sav" ||
    { fail ogsave "hero components across locations: $(diff "$TMP/ogsave.a" "$TMP/ogsave.b" | sed -n 2p)"; return; }
  ok ogsave
}

# The code editor's probe (editor/codeprobe.zig) on the Classic game and the converted
# project: the share of names Go to, the tip and completion know, per kind of name, may not
# drop below scripts/code-probe.base (by more than 0.3), and opening a text stays under 5 ms
# on average. CODEPROBE_UPDATE=1 writes the base again (after a gain).
codeprobe() {
  ogproject cpr || { fail codeprobe "convert failed: $(tail -1 "$TMP/cpr.convert")"; return; }
  sdl_env
  { OPENGORKY_MUTE=1 "$EDITOR_BIN" "$G" --code-probe "" >"$TMP/codeprobe.classic" 2>&1 &&
    OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/cpr" --code-probe "src:" >"$TMP/codeprobe.og" 2>&1; } >"$TMP/codeprobe.log" 2>&1 ||
    { fail codeprobe "editor failed"; return; }
  # `<project> <kind> <def|tip|comp> <percent>` lines, and each project's average open.
  for p in classic og; do
    awk -v p=$p '/^SUMMARY [a-z]+ +names=/ { gsub(/= +/, "="); for (i = 3; i <= NF; i++) if ($i ~ /^(def|tip|comp)=/) { split($i, x, "="); sub(/%/, "", x[2]); print p, $2, x[1], x[2] } }' "$TMP/codeprobe.$p"
  done >"$TMP/codeprobe.now"
  if [ -n "$CODEPROBE_UPDATE" ]; then cp "$TMP/codeprobe.now" scripts/code-probe.base; ok "codeprobe (base written)"; return; fi
  [ -s "$TMP/codeprobe.now" ] || { fail codeprobe "no SUMMARY lines"; return; }
  drop=$(awk 'NR == FNR { b[$1" "$2" "$3] = $4; next } ($1" "$2" "$3) in b && $4 < b[$1" "$2" "$3] - 0.3 { printf "%s %s %s %s%% (was %s%%); ", $1, $2, $3, $4, b[$1" "$2" "$3] }' scripts/code-probe.base "$TMP/codeprobe.now")
  [ -z "$drop" ] || { fail codeprobe "$drop"; return; }
  for p in classic og; do
    slow=$(awk '/^FILE / { for (i = 1; i <= NF; i++) if ($i ~ /^open=/) { sub(/open=/, "", $i); s += $i; n++ } } END { if (n && s / n > 5) printf "%.1f", s / n }' "$TMP/codeprobe.$p")
    [ -z "$slow" ] || { fail codeprobe "$p: opening a text takes $slow ms on average"; return; }
  done
  ok codeprobe
}

# OpenGorky: a model added first (the tree's Models, --glb-new), saved into src/assets/;
# a look then wears it and is put back: the old model untouched, the new one still packed.
ogmodel() {
  ogproject om || { fail ogmodel "convert failed: $(tail -1 "$TMP/om.convert")"; return; }
  sdl_env
  { OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --glb-export shotgun "$TMP/om.glb" &&
    OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --glb-new "$TMP/om.glb" --save; } >"$TMP/ogmodel.log" 2>&1 || { fail ogmodel "editor failed: $(tail -1 "$TMP/ogmodel.log")"; return; }
  m=$(ls "$TMP/om/src/assets/models/" 2>/dev/null | sed -n 's/\.msh$//p' | head -1)
  [ -n "$m" ] || { fail ogmodel "no model in src/assets/models"; return; }
  grep -q "\"$m\"" "$TMP"/om/src/looks/*.ogs && { fail ogmodel "a look wears $m before it is picked"; return; }
  OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --og-set looks/squeaker.ogs mesh "\"$m\"" --save --show squeaker --shot "$TMP/ogmodel.png" >>"$TMP/ogmodel.log" 2>&1 &&
    grep -q "mesh = \"$m\"" "$TMP/om/src/looks/squeaker.ogs" || { fail ogmodel "the look does not wear $m"; return; }
  grep -q "model $m: " "$TMP/ogmodel.log" && { fail ogmodel "the saved $m is not found on reopening"; return; }
  # …and in the game (its package's models over the installed game's).
  OPENGORKY_MUTE=1 perl -e 'alarm 90; exec @ARGV' "$TOOL" play "$TMP/om" --start test-room:characters::squeaker --shot "$TMP/ogmodel_play.png" >"$TMP/ogmodel.play" 2>&1 || { fail ogmodel "play failed: $(tail -1 "$TMP/ogmodel.play")"; return; }
  grep -q "model $m: " "$TMP/ogmodel.play" && { fail ogmodel "the game does not find $m: $(grep "model $m: " "$TMP/ogmodel.play" | head -1)"; return; }
  OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --og-set looks/squeaker.ogs mesh '"squeaker"' --save >>"$TMP/ogmodel.log" 2>&1 &&
    "$TOOL" build "$TMP/om" >>"$TMP/ogmodel.log" 2>&1 || { fail ogmodel "build failed: $(tail -1 "$TMP/ogmodel.log")"; return; }
  grep -aq "src/assets/models/$m.msh" "$TMP/om/dist/"*.ogp || { fail ogmodel "$m not in the package"; return; }
  # Unworn again: deleted from the project (its texture too); a game model is not.
  OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --model-delete shotgun >>"$TMP/ogmodel.log" 2>&1 && { fail ogmodel "a game model was deleted"; return; }
  OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --model-delete "$m" --save >>"$TMP/ogmodel.log" 2>&1 || { fail ogmodel "delete failed: $(tail -1 "$TMP/ogmodel.log")"; return; }
  left=$(find "$TMP/om/src/assets" -type f -name "$m*" | head -1)
  [ -z "$left" ] || { fail ogmodel "$left left after the delete"; return; }
  # A fighter's model (its look's) out to glTF and back in: the look wears the new one.
  { OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --glb-export squeaker "$TMP/om_sq.glb" &&
    OPENGORKY_MUTE=1 "$EDITOR_BIN" "$TMP/om" --glb-import squeaker "$TMP/om_sq.glb" --save; } >>"$TMP/ogmodel.log" 2>&1 || { fail ogmodel "fighter glb failed: $(tail -1 "$TMP/ogmodel.log")"; return; }
  grep -q 'mesh = "squeaker_[0-9]*"' "$TMP/om/src/looks/squeaker.ogs" || { fail ogmodel "the look does not wear the imported fighter model"; return; }
  ok ogmodel
}

# The GPU renderer (--renderer gpu: models, shadows, ice, shock, flashes, billboards on SDL
# GPU) against the CPU one: the same battle frame — a frozen hornet, a shocked one,
# Sullivan's chaingun flash — differs only by texels (the GPU picks mip levels per pixel,
# the CPU per triangle): scripts/pngdiff.py's 4×4 block means. Skipped where the viewer
# has no GPU device (it logs that and draws on the CPU).
gpuview() {
  sdl_env
  for r in cpu gpu; do
    OPENGORKY_MUTE=1 perl -e 'alarm 90; exec @ARGV' "$VIEWER" "$G" 01__port_park/sprite.dat --level --heroes --play --renderer $r \
      --input "w 800;x state 01pr_hornet02 freeze;x fxstate 01pr_hornet05 shock;x attack sullivan cw_chaingun 01pr_hornet05;w 38;s $TMP/gpuview_$r.png;q" >"$TMP/gpuview_$r.log" 2>&1 ||
      { cp "$TMP/gpuview_$r.log" "$TMP/gpuview.log"; fail gpuview "viewer failed ($r)"; return; }
  done
  cp "$TMP/gpuview_gpu.log" "$TMP/gpuview.log"
  if ! grep -q 'renderer: gpu' "$TMP/gpuview.log" || grep -q 'GPU models off' "$TMP/gpuview.log"; then ok "gpuview (no GPU device: skipped)"; return; fi
  python3 -I scripts/pngdiff.py "$TMP/gpuview_cpu.png" "$TMP/gpuview_gpu.png" >>"$TMP/gpuview.log" 2>&1 ||
    { fail gpuview "GPU frame differs from the CPU one: $(tail -1 "$TMP/gpuview.log")"; return; }
  ok gpuview
}

ALL="boat medusa medusaload medusafirst matrixload sawtime bt ladder ladderclick labload sideline counterkill counterhand tranq scenewalk natohp natothreat recharge levelup shadowfloor badsave turncam aimclick barrelchain barrelexp barrelnovictim barrelfx decorpick radio strikewait decoy ballcharge toolsmoke sceneonce menublock medusafx morphfx booth roundtrip lift deps opening reopen staleinfo rules abilities testroom newchar testkit postchain ogedit scripted points phoenix events ogsview frames traitsdoc ogroundtrip ogplay pathscript reinforce convert convert-ui ogsave codeprobe ogmodel gpuview"
# (A scenario's function: its name with `_` for `-`.)
[ $# -gt 0 ] && { for t in "$@"; do $(echo "$t" | tr - _); done; exit $FAILED; }
# All scenarios: side by side ($JOBS, default the CPU count), each a run of this
# script in its own HOME; output in the listed order.
export G
echo $ALL | tr ' ' '\n' | xargs -n 1 -P "${JOBS:-$(getconf _NPROCESSORS_ONLN)}" sh -c '
  mkdir -p "$0/$1.home" && HOME="$0/$1.home" sh scripts/regress.sh "$G" "$1" >"$0/$1.out" 2>&1' "$TMP" || FAILED=1
for t in $ALL; do cat "$TMP/$t.out"; done
exit $FAILED
