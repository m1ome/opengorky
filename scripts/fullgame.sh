#!/bin/sh
# Full playthrough; prints the log.
# $GORKY_TOOL — another gorky-tool (absolute path, e.g. a build in another mode).
G=${1:?game dir}
cd "$(dirname "$0")/.."
${GORKY_TOOL:-./zig-out/bin/gorky-tool} play $G 01_port autorefill autolevel autoequip wait:300 scene loot goto:trupy scene \
  goto:fight2_place goto:garcia_place goto:cutscene_trabant scene goto:fight5_place \
  goto:fight6_place goto:fight8_place goto:drzwi_barak goto:drzwi_barak loot \
  goto:worker_exit use:Gloves:furtka scene goto:fight9_place loot \
  use:GrandHand:Identyficator scene goto:fight10_place goto:cutscene_thiefs scene \
  goto:store_enter loot goto:exit2port goto:fight11_place scene wait:600 scene loot \
  goto:exit2sewers wait:300 scene \
  wait:60 loot goto:cutscene1 scene \
  goto:switch scene goto:zawor1 scene goto:zawor2 scene goto:fight_01 \
  goto:exit_museum wait:200 scene \
  wait:60 loot goto:szafka loot \
  goto:fight_01 goto:fight_02 goto:exit_to_museum wait:60 loot goto:cutscene_nato scene \
  use:03mf_CardYellow:monitors scene goto:exit2ships wait:60 loot goto:cutscene_girl scene \
  click:1160,300 wait:30 goto:exit2observatory wait:60 loot use:03mo_CardOrange:CardChecker scene goto:wajcha scene \
  goto:cutscene_base scene goto:fight_stinger loot goto:enter2domek scene \
  use:03mob_stun_bomb1:enter2domek scene goto:exit2old_ship goto:MapGoDown \
  goto:exit2museum wait:60 scene goto:cutscene_medusa scene use:03mob_CardRed:monitors scene \
  goto:fight_stairs scene goto:exit2city wait:100 scene \
  loot godmode goto:cutscene_specnaz scene goto:cutscene_specnaz scene nogodmode \
  goto:exit2tenement goto:exit2tenement wait:60 loot goto:exit2city wait:60 \
  use:03ct_key:brama wait:100 goto:exit2factory wait:60 loot goto:exit_two2city wait:60 \
  goto:pokrywa wait:100 loot goto:exit_sec2factory wait:60 goto:exit2city wait:60 \
  goto:fight_factory scene goto:exit2garage wait:60 loot goto:exit2city wait:60 \
  goto:exit2shop wait:60 loot goto:exit2city wait:60 \
  use:04c_rocket_launcher:exit2entrance scene goto:exit2entrance wait:60 scene \
  goto:przycisk scene wait:100 scene goto:exit2winda wait:60 op:przycisk:1 scene \
  wait:100 scene goto:exit2laboratory wait:100 scene wait:300 scene \
  loot godmode goto:cutscene_nato scene nogodmode goto:cutscene_teleport scene \
  goto:reactor_door goto:reactor_door wait:60 goto:main_computer scene goto:exit2lab wait:60 \
  goto:enter2duty wait:60 goto:dzwignia scene goto:exit2lab wait:60 scene \
  godmode goto:teleport scene nogodmode goto:teleport_switch scene goto:fight_right scene \
  goto:MapGoUp wait:30 goto:fight_generator scene goto:generator scene goto:MapGoDown wait:30 \
  goto:computer_center scene use:matrix:work_station scene wait:300 scene wait:300 scene
