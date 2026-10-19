#!/bin/sh
# Regression suite: short gorky-tool play scenarios through places that broke
# before. Each scenario prints OK or FAIL; the
# exit code is non-zero if any failed.
#
# No saves needed: each scenario starts with the full-playthrough steps
# (scripts/fullgame.sh) up to the place it needs, then does what a player does.
# play itself fails on a loop (the same scene or battle 3+ times in a row — "LOOP").
#
#   scripts/regress.sh <game dir> [scenario…]
# $GORKY_TOOL — another gorky-tool, $VIEWER — another viewer.
G=${1:?game dir}
shift
cd "$(dirname "$0")/.."
TOOL=${GORKY_TOOL:-./zig-out/bin/gorky-tool}
VIEWER=${VIEWER:-./zig-out/bin/opengorky-viewer}
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
    cmd:set+sullivan+counterAttack+100 cmd:set+ovitz+counterAttack+100 cmd:set+trantigne+counterAttack+100 \
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

# Counter-attack roll needs a weapon in hand (0x491444: +0x3250 and vfunc +0x6c):
# a bandage in Sullivan's hand never rolls, even with counterAttack 100.
counterhand() {
  play counterhand blog passive level:01__port_park cmd:pick+su_bandage1 \
    cmd:set+sullivan+counterAttack+100 cmd:set+sullivan+hp+5000 cmd:set+ovitz+hp+5000 \
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
#     is the counterattack in that enemy turn (heroes auto-play, godmode), and turn 5
#     shows the full 4 again. A counterattack with a recharging weapon does not fire:
#     the player gets "Recharging" (0x47c2a6), autoCounter skips.
recharge() {
  play recharge blog godmode level:01__port_park cmd:attack+sullivan+cw_ion_rifle+01pr_garcia1 wait:4000 ||
    { fail recharge "play failed"; return; }
  # Strike on the first battle tick (before the enemies finish entering): the entry completes, no hang.
  ! grep -q "stuck" "$TMP/recharge.log" || { fail recharge "battle stuck: an enemy never entered"; return; }
  shots=$(awk '/^turn [0-9]+: sullivan hits .* with dbg_1_cw_ion_rifle/ { sub(":", "", $2); printf "%s ", $2 }' "$TMP/recharge.log")
  left=$(awk '/^turn [0-9]+: dbg_1_cw_ion_rifle.s recharging/ { sub(":", "", $2); printf "%s:%s ", $2, $NF }' "$TMP/recharge.log")
  case $shots in "1 4 "*) ;; *) fail recharge "shots on turns $shots, expected 1 4 …"; return ;; esac
  case $left in "2:3 3:2 4:1 5:4 "*) ;; *) fail recharge "recharge by turn $left, expected 2:3 3:2 4:1 5:4 …"; return ;; esac
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
  grep -q 'console: popup "Level up" delay 0 state [123]' "$TMP/levelup.log" ||
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
#     Objects update (0x420303) after the battle step, from the head of list
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

# 19. AI scoring (0x499170) with a decoy: 2000·aicPlayerDist·path (unreachable —
#     10000) overflows i32 — the exe's imul just wraps, we used to panic.
decoy() {
  "$TOOL" decoytest "$G" 01__port_park 5,5 3 >"$TMP/decoy.log" 2>&1 ||
    { fail decoy "auto-battle with a decoy crashed"; return; }
  ok decoy
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
  view menublock "w 700;p Escape;w 2;p E;w 2;c 119,444;w 30;p Escape;w 5;x fighters;x aim;q" ||
    { fail menublock "viewer failed"; return; }
  grep -q 'console: phase player' "$TMP/menublock.log" || { fail menublock "E under the menu ended the turn"; return; }
  grep -q 'console: aim on' "$TMP/menublock.log" || { fail menublock "panel click under the menu switched aim on"; return; }
  view menublock "w 700;x exp Sullivan;x attack Sullivan gs_fist_all 01pr_hornet05;w 200;p Escape;w 5;x ui;q" ||
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
  view strikewait_uzi "$(steps 'w 700;x attack sullivan cw_chaingun 01pr_hornet05' 200)" ||
    { fail strikewait "viewer failed (uzi)"; return; }
  view strikewait_claw "$(steps 'w 900;x attack 03cr_cutterpill1 03cr_cutterpill1_sa sullivan' 260)" 03__museum_corner/sprite.dat ||
    { fail strikewait "viewer failed (claw)"; return; }
  u=$(strike_ticks "$TMP/strikewait_uzi.log"); k=$(strike_ticks "$TMP/strikewait_claw.log")
  [ "$u" = 120 ] && [ "$k" = 196 ] || { fail strikewait "uzi $u ticks (120), claw $k ticks (196)"; return; }
  ok strikewait
}

# Objects with nameID -1 are not picked (0x450fa0: `cmp [+0x58], -1; jle`): the decor
# barrel 03mf_beczka gets no hint or cursor; the yellow card next to it does.
decorpick() {
  view decorpick "w 30;x where 03mf_beczka;x where 03mf_cardyellow;q" 03_museum_forgotten/sprite.dat ||
    { fail decorpick "viewer failed"; return; }
  grep 'console: bg 1158,220' "$TMP/decorpick.log" | grep -q 'pick false' &&
    grep 'console: bg 1152,177' "$TMP/decorpick.log" | grep -q 'pick true' || { fail decorpick "decor barrel pickable or card not"; return; }
  ok decorpick
}

# Sullivan's radio in the museum NATO scene (museum-fakenato): WEAPON("Sullivan",
# "transmitter") (0x478500) puts transmitter.msh on his one_hand point for the radio
# lines; WEAPON("Sullivan") takes it away.
radio() {
  view radio "w 30;x scene museum-fakenato;w 1600;x where Sullivan;w 600;x where Sullivan;q" 03_museum/sprite.dat ||
    { fail radio "viewer failed"; return; }
  grep 'console: bg' "$TMP/radio.log" | head -1 | grep -q "weapon 'transmitter'" &&
    grep 'console: bg' "$TMP/radio.log" | tail -1 | grep -q "weapon ''" || { fail radio "$(grep 'console: bg' "$TMP/radio.log" | tr '\n' ' ')"; return; }
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

ALL="boat medusa medusaload matrixload sawtime bt ladder ladderclick labload sideline counterkill counterhand tranq scenewalk natohp natothreat recharge levelup shadowfloor badsave turncam aimclick barrelchain barrelexp barrelnovictim barrelfx decorpick radio strikewait decoy toolsmoke sceneonce menublock medusafx morphfx deps"
for t in ${*:-$ALL}; do $t; done
exit $FAILED
