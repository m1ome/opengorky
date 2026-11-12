//! Interface strings in English (default) and Russian. A `Msg` holds both texts at
//! comptime, so formatted messages keep checked format strings in every language.

const std = @import("std");

pub const Lang = enum { en, ru };

pub const langs = [_]struct { lang: Lang, name: []const u8 }{
    .{ .lang = .en, .name = "English" },
    .{ .lang = .ru, .name = "Русский" },
};

/// The interface language (the UI is single-threaded).
pub var lang: Lang = .en;

/// The engine's doc pair (script/traits.zig documents its built-in methods so).
pub const Msg = @import("opengorky").script.traits.Doc;

pub fn get(m: Msg) []const u8 {
    return switch (lang) {
        .en => m.en,
        .ru => m.ru,
    };
}

pub fn print(buf: []u8, comptime m: Msg, args: anytype) []const u8 {
    const r = switch (lang) {
        .en => std.fmt.bufPrint(buf, m.en, args),
        .ru => std.fmt.bufPrint(buf, m.ru, args),
    };
    return r catch buf[0..0];
}

/// Message `m` in both languages, for a label kept past the session (an undo step, the
/// save log's): `label` shows the interface language's, whatever it was when made.
pub fn both(a: std.mem.Allocator, comptime m: Msg, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, m.en ++ "\x1f" ++ m.ru, args ++ args) catch "";
}

/// Label `s` in the interface language (made by `both`; any other as it is: names,
/// arrows, an older save log's).
pub fn label(s: []const u8) []const u8 {
    const k = std.mem.indexOfScalar(u8, s, 0x1f) orelse return s;
    return if (lang == .ru) s[k + 1 ..] else s[0..k];
}

test both {
    var buf: [64]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const s = both(fba.allocator(), .{ .en = "{s}: frame {d}", .ru = "{s}: кадр {d}" }, .{ "a", 2 });
    lang = .ru;
    defer lang = .en;
    try std.testing.expectEqualStrings("a: кадр 2", label(s));
    lang = .en;
    try std.testing.expectEqualStrings("a: frame 2", label(s));
    try std.testing.expectEqualStrings("+ b.s", label("+ b.s"));
}

/// Message `m` for the game's own files (a new weapon's name): in the edition's language
/// (`cyrillic`: the Russian one), not the interface's.
/// Message `m` in the game's language, unformatted (its `{d}` kept).
pub fn gameText(cyrillic: bool, m: Msg) []const u8 {
    return if (cyrillic) m.ru else m.en;
}

pub fn game(a: std.mem.Allocator, cyrillic: bool, comptime m: Msg, args: anytype) []const u8 {
    return (if (cyrillic) std.fmt.allocPrint(a, m.ru, args) else std.fmt.allocPrint(a, m.en, args)) catch "";
}

pub fn alloc(a: std.mem.Allocator, comptime m: Msg, args: anytype) []const u8 {
    const r = switch (lang) {
        .en => std.fmt.allocPrint(a, m.en, args),
        .ru => std.fmt.allocPrint(a, m.ru, args),
    };
    return r catch "";
}

// Window and tabs.
pub const title: Msg = .{ .en = "OpenGorky — level editor", .ru = "OpenGorky — редактор уровней" };
pub const tab_history: Msg = .{ .en = "History", .ru = "История" };
pub const tab_settings: Msg = .{ .en = "Settings", .ru = "Настройки" };
pub const unsaved: Msg = .{ .en = "Unsaved", .ru = "Не сохранено" };
pub const pick_level: Msg = .{ .en = "Pick a level on the left", .ru = "Выберите уровень слева" };
pub const no_level: Msg = .{ .en = "No level open", .ru = "Нет открытого уровня" };

// Panels.
pub const scripted: Msg = .{ .en = "script", .ru = "скрипт" };
pub const new: Msg = .{ .en = "new", .ru = "новый" };
pub const built: Msg = .{ .en = "not in the game's battles", .ru = "в боях игры нет" };
pub const later: Msg = .{ .en = "reinforcement", .ru = "подкрепление" };
pub const later_alt: Msg = .{ .en = "reinforcement, fallback tile", .ru = "подкрепление, запасная клетка" };
pub const params_of: Msg = .{ .en = "Parameters · {s}", .ru = "Параметры · {s}" };
pub const scope_one_hint: Msg = .{ .en = "This enemy's own values over its class (× returns the class value); every such enemy: the menu's Open", .ru = "Свои значения этого врага поверх класса (× — вернуть классу); всех таких — «Открыть» в меню" };
pub const damage_of: Msg = .{ .en = "Damage: {s}", .ru = "Урон: {s}" };

// Parameters.
pub const p_hp: Msg = .{ .en = "HP", .ru = "HP" };
pub const p_armor: Msg = .{ .en = "Armor", .ru = "Броня" };
pub const p_walk: Msg = .{ .en = "Move, tiles", .ru = "Ход, клеток" };
pub const p_accuracy: Msg = .{ .en = "Accuracy", .ru = "Меткость" };
pub const p_luck: Msg = .{ .en = "Luck", .ru = "Удача" };
pub const p_calmness: Msg = .{ .en = "Calmness", .ru = "Спокойствие" };
pub const p_ai_attack: Msg = .{ .en = "AI: attack", .ru = "ИИ: атака" };
pub const p_ai_defense: Msg = .{ .en = "AI: defense", .ru = "ИИ: защита" };
pub const p_ai_player: Msg = .{ .en = "AI: player distance", .ru = "ИИ: дист. до игрока" };
pub const p_ai_guard: Msg = .{ .en = "AI: guard distance", .ru = "ИИ: дист. охраны" };
pub const p_fire: Msg = .{ .en = "Resist: fire", .ru = "Защита: огонь" };
pub const p_elect: Msg = .{ .en = "Resist: electric", .ru = "Защита: электр." };
pub const p_dist: Msg = .{ .en = "Resist: ranged", .ru = "Защита: дальн." };
pub const p_energy: Msg = .{ .en = "Resist: energy", .ru = "Защита: энергия" };
pub const p_freeze: Msg = .{ .en = "Resist: freeze", .ru = "Защита: холод" };
pub const p_tranq: Msg = .{ .en = "Resist: tranquilizer", .ru = "Защита: транкв." };
pub const p_gas: Msg = .{ .en = "Resist: gas", .ru = "Защита: газ" };

// Settings page.
pub const s_language: Msg = .{ .en = "Language", .ru = "Язык" };
pub const s_ui_scale: Msg = .{ .en = "Interface scale (Cmd + / − / 0)", .ru = "Масштаб интерфейса (Cmd + / − / 0)" };
pub const s_game: Msg = .{ .en = "Game folder", .ru = "Папка игры" };
pub const s_game_hint: Msg = .{ .en = "Edited in place: its .dat archives are rewritten on save, so pick a copy of the game, not the one you play", .ru = "Правится на месте: архивы .dat перезаписываются при сохранении, поэтому выберите копию игры, а не ту, в которую играете" };
pub const s_no_game: Msg = .{ .en = "not chosen", .ru = "не выбрана" };
pub const s_pick_game: Msg = .{ .en = "Choose…", .ru = "Выбрать…" };
pub const st_no_dat: Msg = .{ .en = "the chosen folder has no dat folder: it is not Gorky 17", .ru = "в выбранной папке нет папки dat: это не Gorky 17" };
pub const st_save_first: Msg = .{ .en = "save or undo the edits first: another folder opens the editor anew", .ru = "сначала сохраните или откатите правки: другая папка открывает редактор заново" };
pub const s_file: Msg = .{ .en = "Settings file", .ru = "Файл настроек" };
pub const s_no_file: Msg = .{ .en = "— (no settings folder, not saved)", .ru = "— (нет папки настроек, не сохраняются)" };
pub const s_levels: Msg = .{ .en = "Levels", .ru = "Уровни" };
pub const s_levels_n: Msg = .{ .en = "{d} battles, {d} locations, {d} enemy classes to add", .ru = "боёв {d}, локаций {d}, классов врагов для добавления {d}" };

// Status line.
pub const st_open_failed: Msg = .{ .en = "{s}: cannot open ({t})", .ru = "{s}: не удалось открыть ({t})" };
pub const st_battle: Msg = .{ .en = "{s}: battle, {d} objects, {d} movable — to change them: Edit the level", .ru = "{s}: бой, объектов {d}, можно двигать {d} — чтобы менять: «Редактировать уровень»" };
pub const st_location: Msg = .{ .en = "{s}: background {d}×{d}, {d} objects", .ru = "{s}: фон {d}×{d}, объектов {d}" };
pub const st_og_read_only: Msg = .{ .en = "not saved: {s} is the installed game's (an OpenGorky project writes only its src/ folder; edited assets go to src/assets/)", .ru = "не сохранено: {s} — файл установленной игры (проект OpenGorky пишет только свою папку src/; изменённые ассеты — в src/assets/)" };
pub const og_scene_on: Msg = .{ .en = "Scene on", .ru = "Сцена включена" };
pub const og_scene_on_note: Msg = .{ .en = "Off: enabled = false in its block, the game never starts it (as a Classic scene whose starts are commented out).", .ru = "Выключена: enabled = false в её блоке, игра её не запускает (как сцена Classic с закомментированными запусками)." };
pub const st_og_fighter: Msg = .{ .en = "New fighter {s}", .ru = "Новый боец {s}" };
pub const st_save_failed: Msg = .{ .en = "cannot save ({t})", .ru = "не удалось сохранить ({t})" };
pub const st_saved: Msg = .{ .en = "Saved: {d} files written into the game archives", .ru = "Сохранено: {d} файлов записано в архивы игры" };
pub const st_saved_og: Msg = .{ .en = "Saved: {d} files written into the project's src/, {d} into .og/ (the editor's: history, test kit); the installed game untouched", .ru = "Сохранено: файлов в src/ проекта — {d}, в .og/ (файлы редактора: история, тестовый набор) — {d}; установленная игра не тронута" };
pub const st_remove_failed: Msg = .{ .en = "cannot remove: {t}", .ru = "не удалось убрать: {t}" };
pub const st_removed: Msg = .{ .en = "{s} removed from the level (Ctrl+Z brings it back before saving)", .ru = "{s} убран с уровня (Ctrl+Z — вернуть до сохранения)" };
pub const st_undo_failed: Msg = .{ .en = "undo: {t}", .ru = "отмена: {t}" };
pub const st_undone: Msg = .{ .en = "Undone", .ru = "Отменено" };
pub const st_no_tile: Msg = .{ .en = "the tile is taken or blocked", .ru = "клетка занята или непроходима" };
pub const st_too_many: Msg = .{ .en = "the battle already has {d} fighters, the game holds no more", .ru = "в бою уже {d} участников — больше игра не держит" };
pub const st_not_walkable: Msg = .{ .en = "not walkable here: only walkable floor (green or blue) takes it", .ru = "здесь непроходимо: ставить можно только на проходимую (зелёную или синюю) область" };
pub const menu_walk_in: Msg = .{ .en = "Walk in at the battle start (from the nearest edge)", .ru = "Входит в начале боя (с ближнего края)" };
pub const menu_place_now: Msg = .{ .en = "Stand on the tile from the start", .ru = "Стоит на клетке сразу" };
pub const menu_add_enemy: Msg = .{ .en = "Add enemy", .ru = "Добавить врага" };
pub const ob_wcrate: Msg = .{ .en = "Wooden crate", .ru = "Деревянный ящик" };
pub const ob_mcrate: Msg = .{ .en = "Metal crate", .ru = "Металлический ящик" };
pub const ob_barrel: Msg = .{ .en = "Barrel (explodes)", .ru = "Бочка (взрывается)" };
pub const st_placed: Msg = .{ .en = "{s} placed; Ctrl+Z removes it", .ru = "{s} поставлен; Ctrl+Z — убрать" };
pub const menu_turn: Msg = .{ .en = "Turn ({d}°) by {s}°", .ru = "Повернуть ({d}°) на {s}°" };
pub const pr_barrier: Msg = .{ .en = "Barrier", .ru = "Заграждение" };
pub const pr_pipe: Msg = .{ .en = "Pipe", .ru = "Труба" };
pub const pr_logs: Msg = .{ .en = "Bales (not in the game's battles)", .ru = "Тюки (в боях игры нет)" };
pub const pr_fcrate: Msg = .{ .en = "Crate (not in the game's battles)", .ru = "Ящик (в боях игры нет)" };
pub const pr_bathtub: Msg = .{ .en = "Bathtub", .ru = "Ванна" };
pub const pr_corpse: Msg = .{ .en = "Corpse trolley", .ru = "Каталка с телом" };
pub const pr_automat: Msg = .{ .en = "Machine (automat)", .ru = "Автомат" };
pub const st_add_failed: Msg = .{ .en = "cannot add {s}: {t}", .ru = "не удалось добавить {s}: {t}" };
pub const st_added: Msg = .{ .en = "{s} ({s} from {s}) placed at {d},{d} — drag it into place", .ru = "{s} ({s} из {s}) поставлен на {d},{d} — перетащите на место" };
pub const st_no_fighter: Msg = .{ .en = "{s}: no fighter file ({t})", .ru = "{s}: нет файла бойца ({t})" };
pub const st_set_failed: Msg = .{ .en = "cannot change: {t}", .ru = "не удалось изменить: {t}" };
pub const st_text_lost: Msg = .{ .en = "Changed, but some characters have no letter in the game's code page and became \"?\"", .ru = "Изменено, но для некоторых символов нет буквы в кодировке игры: они стали «?»" };
pub const st_text_unshown: Msg = .{ .en = "Changed, but the game's font has no \"{s}\": the game shows nothing in its place", .ru = "Изменено, но в шрифте игры нет «{s}»: игра на его месте ничего не покажет" };
pub const st_move_failed: Msg = .{ .en = "cannot move: {t}", .ru = "не удалось переместить: {t}" };

// Enemies, items, heroes.
pub const pick_entry: Msg = .{ .en = "Pick one on the left", .ru = "Выберите слева" };
pub const copy_of: Msg = .{ .en = "copy of {s}", .ru = "копия {s}" };
pub const make_copy: Msg = .{ .en = "Make a copy", .ru = "Создать копию" };
pub const hint_enemy: Msg = .{ .en = "Class values: every enemy of this class in every battle (an enemy's own values in a battle override them)", .ru = "Значения класса: все враги этого класса во всех боях (свои значения врага в бою важнее)" };
pub const hint_item: Msg = .{ .en = "Class values: every such item in the game", .ru = "Значения класса: все такие предметы в игре" };
pub const hint_attack: Msg = .{ .en = "Class values: every enemy with this attack in the game's battles", .ru = "Значения класса: все враги с этой атакой в боях игры" };
pub const hint_hero: Msg = .{ .en = "Starting values of the hero (a new game)", .ru = "Стартовые значения героя (новая игра)" };
pub const hint_copy_enemy: Msg = .{ .en = "A new class: add it to battles from the ADD ENEMY list. Its look (act_*.ss) is its own; its model is shared until a texture or glb import. It keeps the original's classic_id {d}: the exe gives monsters their strikes, resistances and report icon by classic_id (100–139), and its name in battle is that string.tab row, so renaming it renames the original too", .ru = "Новый класс: добавляется в бои из списка ДОБАВИТЬ ВРАГА. Внешний вид (act_*.ss) свой; модель общая, пока не импортированы текстура или glb. classic_id {d} — как у оригинала: удары, сопротивления и иконку отчёта exe даёт монстрам по classic_id (100–139), а имя в бою — эта строка string.tab, так что переименование переименует и оригинал" };
pub const hint_copy_same: Msg = .{ .en = "The same item to the exe (classic_id {d}, the original's): its name and description rows (renaming renames both), what the exe does by classic_id (a weapon's strike, flash, projectile, sound; a medicine's effect), and it stacks with the original. Change its look and values freely", .ru = "Для exe это тот же предмет (classic_id {d}, как у оригинала): общие название и описание (переименование меняет оба), всё, что exe делает по classic_id (удар, вспышка, снаряд и звук оружия; действие лекарства), и складывается с оригиналом. Внешний вид и значения меняйте свободно" };
pub const hint_copy_new_weapon: Msg = .{ .en = "Own classic_id {d}: own name and description, does not stack. The exe has no rules for it: the strike is always attack_rifle, with no flash, projectile or sound, and the skills window does not list it (0x48bda2, 0x52a3a8)", .ru = "Свой classic_id {d}: своё название и описание, не складывается. Правил для него в exe нет: удар всегда attack_rifle, без вспышки, снаряда и звука, в окне навыков его нет (0x48bda2, 0x52a3a8)" };
pub const hint_copy_new_item: Msg = .{ .en = "Own classic_id {d}: own name and description, does not stack with the original. What the exe does by classic_id is not done for it (the medicines 1043, 83, 1044, 1047, 1049: 0x48ff50)", .ru = "Свой classic_id {d}: своё название и описание, не складывается с оригиналом. То, что exe делает по classic_id, для него не делается (лекарства 1043, 83, 1044, 1047, 1049: 0x48ff50)" };
pub const hint_copy_new_ammo: Msg = .{ .en = "Own classic_id {d}: own name and description, does not stack. No weapon fires it until a weapon's Ammo is set to it", .ru = "Свой classic_id {d}: своё название и описание, не складывается. Им не стреляет ни одно оружие, пока в «Патронах» оружия не выбран он" };
pub const hint_copy_hero_party: Msg = .{ .en = "A new hero (classic_id {d}: own name; outside 100–139, the monsters'; no idle chatter, which is Sullivan's, Ovitz's and Trantigne's). In the party from a new game (gamestart\\); a trigger's Hero leaves the party takes it out. Its model is the original's until a texture or glb import", .ru = "Новый герой (classic_id {d}: своё имя; вне 100–139, номеров монстров; без реплик в простое — они у Салливана, Овица и Трантиня). В отряде с новой игры (gamestart\\); убирает его «Герой уходит из отряда» триггера. Модель — как у оригинала, пока не импортированы текстура или glb" };
pub const hint_copy_hero_level: Msg = .{ .en = "A new hero (classic_id {d}: own name; outside 100–139, the monsters'). Hidden in its level until a trigger's Hero joins the party (the level's post_init disables it). Its model is the original's until a texture or glb import", .ru = "Новый герой (classic_id {d}: своё имя; вне 100–139, номеров монстров). Скрыт на своём уровне, пока триггер «Герой вступает в отряд» его не покажет (его выключает post_init уровня). Модель — как у оригинала, пока не импортированы текстура или glb" };
pub const copy_same: Msg = .{ .en = "Copy (same item to the exe)", .ru = "Копия (тот же предмет для exe)" };
pub const c_attack_anim: Msg = .{ .en = "Strike animation", .ru = "Анимация удара" };
pub const anim_strike_own: Msg = .{ .en = "the strike's own (rules)", .ru = "своя у удара (правила)" };
pub const anim_fork: Msg = .{ .en = "Fork the strike of {s}", .ru = "Взять удар {s} как свой" };
pub const st_strike_forked: Msg = .{ .en = "The strike of {s} is now {s}'s own rows; saved with Ctrl+S", .ru = "Удар {s} записан строками {s}; сохраняется по Ctrl+S" };
pub const lv_blank_size: Msg = .{ .en = "Picture", .ru = "Картинка" };
pub const lv_blank_size_classic: Msg = .{ .en = "640×480 to 2600×1916 (the game's own sizes), multiples of 8; the camera widens to its aspect.", .ru = "От 640×480 до 2600×1916 (размеры самой игры), кратно 8; камера расширяется под её пропорции." };
pub const lv_blank_size_og: Msg = .{ .en = "640×480 to 8192×8192 (the port's limit), multiples of 8; the camera widens to its aspect.", .ru = "От 640×480 до 8192×8192 (предел порта), кратно 8; камера расширяется под её пропорции." };
pub const new_weapon: Msg = .{ .en = "New weapon from scratch", .ru = "Новое оружие с нуля" };
pub const new_character: Msg = .{ .en = "New character", .ru = "Новый персонаж" };
pub const b_in_battle: Msg = .{ .en = "In battle", .ru = "В бой" };
pub const st_test_room: Msg = .{ .en = "Test room {s}: {s} fights there (a hidden battle: not in the level lists nor in the mod package)", .ru = "Комната для боя {s}: там дерётся {s} (скрытый бой: его нет в списках уровней и в пакете мода)" };
pub const st_test_room_failed: Msg = .{ .en = "test room not made: {t}", .ru = "комната для боя не создана: {t}" };
pub const sec_testkit: Msg = .{ .en = "Test kit", .ru = "Снаряжение для теста" };
pub const sum_testkit: Msg = .{ .en = "{d} things", .ru = "вещей: {d}" };
pub const kit_hint: Msg = .{ .en = "What the heroes carry into battles played from the editor and into the test room, and who fights there: the editor's own (.og/testkit.txt); not in the mod package, the campaign nor the saves.", .ru = "С чем герои идут в бои, запущенные из редактора, и в тестовую комнату, и кто там дерётся: настройка редактора (.og/testkit.txt); в пакет мода, кампанию и сохранения не попадает." };
pub const kit_enemy: Msg = .{ .en = "Enemy's weapon", .ru = "Оружие врага" };
pub const kit_enemy_hint: Msg = .{ .en = "For any enemy tried in the test room; an attack's page still uses that attack's weapon.", .ru = "Для любого врага, проверяемого в комнате для боя; со страницы атаки берётся оружие этой атаки." };
pub const kit_party: Msg = .{ .en = "Test party", .ru = "Тестовая команда" };
pub const kit_room: Msg = .{ .en = "Test room", .ru = "Тестовая комната" };
pub const kit_room_hint: Msg = .{ .en = "A bare battle (no dialogue, no script of its own) where the enemy picked fights the heroes ticked below, with their things; the enemy keeps its own weapons.", .ru = "Голый бой (без диалога и своего кода боя), где выбранный враг дерётся с отмеченными ниже героями и их вещами; оружие у врага своё." };
pub const kit_fighter: Msg = .{ .en = "Enemy", .ru = "Враг" };
pub const kit_party_hint: Msg = .{ .en = "Their things are what they carry in every battle played from the editor (in place of the start's); the ticked ones go into the test room.", .ru = "Их вещи — то, с чем они идут в любой бой, запущенный из редактора (вместо стартовых); отмеченные галочкой идут в тестовую комнату." };
pub const kit_hero_add: Msg = .{ .en = "+ fighter", .ru = "+ боец" };
pub const sum_kit_heroes: Msg = .{ .en = "{d} fighters", .ru = "бойцов: {d}" };
pub const kit_enemy_own: Msg = .{ .en = "Its own", .ru = "Своё" };
pub const kit_add: Msg = .{ .en = "+ weapon, ammo, item", .ru = "+ оружие, патроны, предмет" };
pub const kit_hand: Msg = .{ .en = "In hand", .ru = "В руках" };
pub const kit_extra: Msg = .{ .en = "The character on the heroes' side (as_hero)", .ru = "Персонаж на стороне героев (as_hero)" };
pub const st_char_new: Msg = .{ .en = "{s} created: fill its slots (look, model, AI, roles, stats); battles and scripts place it in the game. Saved with Ctrl+S", .ru = "{s} создан: заполните его слоты (облик, модель, ИИ, роли, параметры); в игру его ставят бои и скрипты. Сохраняется по Ctrl+S" };
pub const game_new_weapon: Msg = .{ .en = "New weapon {d}", .ru = "Новое оружие {d}" };
pub const game_new_char: Msg = .{ .en = "New character {d}", .ru = "Новый персонаж {d}" };
pub const st_weapon_new_og: Msg = .{ .en = "{s} created with its own ammo items::{s} (its ammo field picks any other); saved with Ctrl+S", .ru = "{s} создано со своими патронами items::{s} (в поле «Патроны» можно выбрать любые другие); сохраняется по Ctrl+S" };
pub const og_look_slots: Msg = .{ .en = "Slots (models on the body)", .ru = "Слоты (модели на теле)" };
pub const og_look_idles: Msg = .{ .en = "Idles", .ru = "Ожидания" };
pub const og_look_walk: Msg = .{ .en = "Walk speeds", .ru = "Скорости ходьбы" };
pub const og_look_not_in_place: Msg = .{ .en = "Animations not in place", .ru = "Анимации не на месте" };
pub const og_ammo_none: Msg = .{ .en = "None (needs no ammo)", .ru = "Нет (патроны не нужны)" };
pub const og_ammo_thrown: Msg = .{ .en = "Thrown (spent itself)", .ru = "Бросается (тратится само)" };
pub const game_new_ammo: Msg = .{ .en = "New weapon {d} ammo", .ru = "Патроны к новому оружию {d}" };
pub const copy_new: Msg = .{ .en = "Copy as a new item", .ru = "Копия как новый предмет" };
pub const copy_party: Msg = .{ .en = "Copy: in the party from a new game", .ru = "Копия: в отряде с новой игры" };
pub const copy_level: Msg = .{ .en = "Copy: joins in this level", .ru = "Копия: вступает на этом уровне" };
pub const own_portraits: Msg = .{ .en = "Own portraits", .ru = "Свои портреты" };
pub const st_portraits_copied: Msg = .{ .en = "Own portraits {s}: paint them in the sprite page; saved with Ctrl+S", .ru = "Свои портреты {s}: рисуются на странице спрайта; сохраняются по Ctrl+S" };
pub const c_visual: Msg = .{ .en = "Look (model, animations)", .ru = "Внешний вид (модель, анимации)" };
pub const c_icon: Msg = .{ .en = "Icon", .ru = "Иконка" };
pub const c_portrait_hero: Msg = .{ .en = "Portraits", .ru = "Портреты" };
pub const b_edit_icon: Msg = .{ .en = "Edit…", .ru = "Редактировать…" };
pub const spr_hint: Msg = .{ .en = "Left button draws, right button picks a colour; a stroke is one step (Ctrl+Z), Save writes it.", .ru = "Левая кнопка рисует, правая берёт цвет; мазок — один шаг (Ctrl+Z), записывает «Сохранить»." };
pub const spr_frame: Msg = .{ .en = "Frame {d} · {d}×{d}", .ru = "Кадр {d} · {d}×{d}" };
pub const spr_frame_word: Msg = .{ .en = "frame", .ru = "кадр" };
pub const step_spr_frame: Msg = .{ .en = "{s}: frame {d}", .ru = "{s}: кадр {d}" };
pub const step_anim_auto: Msg = .{ .en = "animation bindings: auto-bind", .ru = "привязки анимаций: автопривязка" };
pub const step_anim_bind: Msg = .{ .en = "animation binding", .ru = "привязка анимации" };
pub const step_anim_removed: Msg = .{ .en = "animation binding removed", .ru = "привязка анимации убрана" };
pub const step_anim_added: Msg = .{ .en = "animation binding added", .ru = "привязка анимации добавлена" };
pub const step_placed: Msg = .{ .en = "{s}: place", .ru = "{s}: место" };
pub const step_discarded: Msg = .{ .en = "{s}: discarded", .ru = "{s}: отменено" };
pub const step_restored: Msg = .{ .en = "restored {s}", .ru = "восстановлен {s}" };
pub const spr_from_png: Msg = .{ .en = "From PNG…", .ru = "Из PNG…" };
pub const spr_to_png: Msg = .{ .en = "To PNG…", .ru = "В PNG…" };
pub const spr_pencil: Msg = .{ .en = "Pencil", .ru = "Карандаш" };
pub const spr_eraser: Msg = .{ .en = "Eraser", .ru = "Ластик" };
pub const spr_picker: Msg = .{ .en = "Eyedropper", .ru = "Пипетка" };
pub const st_frame_set: Msg = .{ .en = "Frame {d} replaced; Save writes it", .ru = "Кадр {d} заменён; записывает «Сохранить»" };
pub const c_report_icon: Msg = .{ .en = "Battle report icon", .ru = "Иконка в отчёте о бое" };
pub const report_none: Msg = .{ .en = "none: the exe picks it by classic_id from a fixed table, this classic_id isn't in it", .ru = "нет: exe берёт её по classic_id из своей таблицы, этого classic_id в ней нет" };
pub const c_mesh: Msg = .{ .en = "Model in hand", .ru = "Модель в руке" };
pub const c_model: Msg = .{ .en = "Model", .ru = "Модель" };
pub const hero_class_look: Msg = .{ .en = "The look comes from the enemy class this hero #includes: change it on the class's page.", .ru = "Внешний вид берётся из класса врага, который герой подключает через #include: меняется на странице класса." };
pub const c_effect: Msg = .{ .en = "Effect on hit", .ru = "Эффект при попадании" };
pub const c_damage: Msg = .{ .en = "Damage type", .ru = "Тип урона" };
pub const cancel: Msg = .{ .en = "Cancel", .ru = "Отмена" };
pub const st_copied: Msg = .{ .en = "{s} created (a copy of {s}); saved with Ctrl+S", .ru = "{s} создан (копия {s}); сохраняется по Ctrl+S" };
pub const st_copy_failed: Msg = .{ .en = "cannot copy: {t}", .ru = "не удалось скопировать: {t}" };

pub const e_burn: Msg = .{ .en = "set on fire", .ru = "поджигает" };
pub const e_freeze: Msg = .{ .en = "freezes", .ru = "замораживает" };
pub const e_poison: Msg = .{ .en = "poisons", .ru = "отравляет" };
pub const e_sleep: Msg = .{ .en = "puts to sleep", .ru = "усыпляет" };
pub const e_soak: Msg = .{ .en = "soaks with fuel", .ru = "обливает горючим" };
pub const e_class: Msg = .{ .en = "by its class: {s}", .ru = "по классу оружия: {s}" };

pub const d_fire: Msg = .{ .en = "fire", .ru = "огонь" };
pub const d_freeze: Msg = .{ .en = "cold", .ru = "холод" };
pub const d_electricity: Msg = .{ .en = "electricity", .ru = "электричество" };
pub const d_teargas: Msg = .{ .en = "tear gas", .ru = "слезоточивый газ" };
pub const d_gas: Msg = .{ .en = "gas", .ru = "газ" };
pub const d_bullet: Msg = .{ .en = "bullet", .ru = "пуля" };
pub const d_melee: Msg = .{ .en = "melee", .ru = "холодное оружие" };
pub const d_tranq: Msg = .{ .en = "tranquilizer", .ru = "транквилизатор" };
pub const d_energy: Msg = .{ .en = "energy", .ru = "энергия" };
pub const d_attract: Msg = .{ .en = "decoy", .ru = "приманка" };
pub const d_explosion: Msg = .{ .en = "explosion", .ru = "взрыв" };
pub const d_flammable: Msg = .{ .en = "fuel", .ru = "горючее" };

pub const f_damage: Msg = .{ .en = "Damage", .ru = "Урон" };
pub const f_light: Msg = .{ .en = "Vs light armor", .ru = "Против лёгкой брони" };
pub const f_medium: Msg = .{ .en = "Vs medium armor", .ru = "Против средней брони" };
pub const f_heavy: Msg = .{ .en = "Vs heavy armor", .ru = "Против тяжёлой брони" };
pub const f_exp: Msg = .{ .en = "Extra experience", .ru = "Доп. опыт" };
pub const f_ammo: Msg = .{ .en = "Ammo", .ru = "Патроны" };
pub const f_count: Msg = .{ .en = "Count", .ru = "Количество" };
pub const f_class: Msg = .{ .en = "Behaviour (classType)", .ru = "Поведение (classType)" };
pub const f_recharge: Msg = .{ .en = "Recharge, turns", .ru = "Перезарядка, ходов" };
pub const f_recharge_class: Msg = .{ .en = "as its class (exe)", .ru = "как у класса (из exe)" };
pub const a_none: Msg = .{ .en = "none", .ru = "не нужны" };
pub const a_self: Msg = .{ .en = "the item itself (used up)", .ru = "сам предмет (расходуется)" };
pub const w_class_fmt: Msg = .{ .en = "{d} · {s}", .ru = "{d} · {s}" };
pub const w_class_word: Msg = .{ .en = "{s} · {s}", .ru = "{s} · {s}" };
pub const w_pistol: Msg = .{ .en = "pistol", .ru = "пистолет" };
pub const w_rifle: Msg = .{ .en = "rifle", .ru = "винтовка" };
pub const w_dartgun: Msg = .{ .en = "dart gun (sleep)", .ru = "транквилизатор (сон)" };
pub const w_flame: Msg = .{ .en = "flamethrower (fire, recharge 3)", .ru = "огнемёт (огонь, перезарядка 3)" };
pub const w_rocket: Msg = .{ .en = "rocket launcher", .ru = "ракетомёт" };
pub const w_ion: Msg = .{ .en = "ion rifle (recharge 4)", .ru = "ионная винтовка (перезарядка 4)" };
pub const w_blaster: Msg = .{ .en = "blaster (recharge 3)", .ru = "бластер (перезарядка 3)" };
pub const w_satellite: Msg = .{ .en = "satellite strike", .ru = "удар со спутника" };
pub const w_time_bomb: Msg = .{ .en = "time bomb", .ru = "бомба с часовым механизмом" };
pub const w_melee: Msg = .{ .en = "melee", .ru = "ближний бой" };
pub const w_grenade: Msg = .{ .en = "grenade, explosives", .ru = "граната, взрывчатка" };
pub const w_knife: Msg = .{ .en = "throwing knife", .ru = "метательный нож" };
pub const w_chaingun: Msg = .{ .en = "chaingun", .ru = "пулемёт" };
pub const w_shotgun: Msg = .{ .en = "shotgun", .ru = "дробовик" };
pub const w_molotov: Msg = .{ .en = "molotov (fire)", .ru = "коктейль Молотова (огонь)" };
pub const w_napalm: Msg = .{ .en = "napalm launcher (fire)", .ru = "напалмомёт (огонь)" };
pub const w_barrel: Msg = .{ .en = "barrel blast", .ru = "взрыв бочки" };
pub const w_decoy: Msg = .{ .en = "decoy", .ru = "приманка" };
pub const w_nitrogen: Msg = .{ .en = "nitrogen gun (freeze, recharge 3)", .ru = "азотная пушка (заморозка, перезарядка 3)" };
pub const w_bottle: Msg = .{ .en = "bottle (soak)", .ru = "бутылка (обливает)" };
pub const w_matches: Msg = .{ .en = "matches (ignite)", .ru = "спички (поджог)" };
pub const w_stun: Msg = .{ .en = "stun bomb (sleep)", .ru = "оглушающая граната (сон)" };
pub const w_gas: Msg = .{ .en = "gas grenade (poison)", .ru = "газовая граната (отравление)" };
pub const w_shocker: Msg = .{ .en = "shocker (sleep, recharge 4)", .ru = "шокер (сон, перезарядка 4)" };
pub const f_rage: Msg = .{ .en = "Max rage", .ru = "Макс. ярость" };
pub const f_counter: Msg = .{ .en = "Counter-attack", .ru = "Контратака" };
pub const f_experience: Msg = .{ .en = "Experience", .ru = "Опыт" };
pub const f_level: Msg = .{ .en = "Level", .ru = "Уровень" };

// Level right-click menu.
pub const menu_add_at: Msg = .{ .en = "Tile {d},{d}", .ru = "Клетка {d},{d}" };

// Box window.
pub const box_title: Msg = .{ .en = "Box: {s}", .ru = "Ящик: {s}" };
pub const box_hint: Msg = .{ .en = "Applies to a new game: a save already holds the contents of the boxes it has seen. Shift+click: ±10", .ru = "Действует в новой игре: в сохранении содержимое уже виденных ящиков записано. Shift+клик: ±10" };
pub const box_contents: Msg = .{ .en = "Contents ({d})", .ru = "Содержимое ({d})" };
pub const box_empty: Msg = .{ .en = "Empty", .ru = "Пусто" };
pub const box_add: Msg = .{ .en = "ADD", .ru = "Добавить" };
pub const ck_title: Msg = .{ .en = "Mod check: {d} problems", .ru = "Проверка мода: проблем — {d}" };
pub const ck_again: Msg = .{ .en = "Check again", .ru = "Проверить снова" };
pub const ck_ok: Msg = .{ .en = "Nothing the original game would stumble on: archives, scripts (#include, #inherit), models and their textures, texture sizes, LEVEL_Load targets are all in order.", .ru = "Ничего, на чём споткнётся оригинальная игра: архивы, скрипты (#include, #inherit), модели и их текстуры, размеры текстур, цели LEVEL_Load — всё в порядке." };
pub const ck_ok_og: Msg = .{ .en = "Nothing the port would stumble on (OpenGorky limits): archives, scripts (#include, #inherit), models and their textures, textures up to 4096 with power-of-two sides, layer videos it plays, LEVEL_Load targets are all in order.", .ru = "Ничего, на чём споткнётся порт (пределы OpenGorky): архивы, скрипты (#include, #inherit), модели и их текстуры, текстуры до 4096 со сторонами-степенями двойки, видео слоя, которые он играет, цели LEVEL_Load — всё в порядке." };
pub const ck_unsaved: Msg = .{ .en = "There are unsaved changes: the check reads the game folder as saved, so save first to include them.", .ru = "Есть несохранённые изменения: проверка читает папку игры как сохранено — сохраните, чтобы они тоже проверились." };
pub const ck_failed: Msg = .{ .en = "The check failed: {t}", .ru = "Проверка не удалась: {t}" };
pub const st_playing: Msg = .{ .en = "The port is starting {s} with the starting party", .ru = "Порт запускает {s} со стартовым отрядом" };
pub const st_playing_built: Msg = .{ .en = "Built {s} ({d} of {d} entries rebuilt); the port is starting {s}", .ru = "Собран {s} (пересобрано записей: {d} из {d}); порт запускает {s}" };
pub const st_built: Msg = .{ .en = "Built {s} without errors ({d} of {d} entries rebuilt)", .ru = "{s} собран без ошибок (пересобрано записей: {d} из {d})" };
pub const st_build_errors: Msg = .{ .en = "The build found {d} errors: nothing to play (see the list)", .ru = "Сборка нашла ошибок: {d} — играть нечего (см. список)" };
pub const st_build_failed: Msg = .{ .en = "Couldn't build the project: {t}", .ru = "Не удалось собрать проект: {t}" };
pub const bd_title: Msg = .{ .en = "Build: {d} problems", .ru = "Сборка: проблем — {d}" };
pub const bd_warning: Msg = .{ .en = "warning: {s}", .ru = "предупреждение: {s}" };
pub const st_play_failed: Msg = .{ .en = "Couldn't start the port: {t} (see Settings → Port (viewer))", .ru = "Не удалось запустить порт: {t} (см. Настройки → Порт (viewer))" };
pub const st_level_step: Msg = .{ .en = "New level {s}", .ru = "Новый уровень {s}" };
pub const st_level_unmade: Msg = .{ .en = "Level {s} undone: its folder deleted", .ru = "Уровень {s} отменён: его папка удалена" };
pub const lp_objects_tool: Msg = .{ .en = "Objects", .ru = "Объекты" };
pub const lp_objects_hint: Msg = .{ .en = "Drag items to move them; right click on the map or a row: add a box, an item, a prop; edit a box's contents; remove. Delete removes the picked one.", .ru = "Перетаскивайте предметы; правый клик по карте или строке: добавить ящик, предмет, проп, изменить содержимое ящика, удалить. Delete удаляет выбранное." };
pub const lp_objects_hint_battle: Msg = .{ .en = "Drag fighters, boxes and props to move them, the arrows by a prop turn it; right click on the map or a row: add an enemy, a hero, a box, a prop, edit contents, remove. Enemies can also be added from the list on the left. Delete removes the picked one.", .ru = "Перетаскивайте бойцов, ящики и пропы, стрелки у пропа его поворачивают; правый клик по карте или строке: добавить врага, своего героя, ящик, проп, изменить содержимое, удалить. Врагов можно добавить и из списка слева. Delete удаляет выбранное." };
pub const at_title: Msg = .{ .en = "Project assets", .ru = "Ассеты проекта" };
pub const at_search: Msg = .{ .en = "Search assets…", .ru = "Поиск ассетов…" };
// The tree's groups by tier (kinds.Tier).
pub const tier_assembly: Msg = .{ .en = "Assemblies", .ru = "Сборки" };
pub const tier_component: Msg = .{ .en = "Components", .ru = "Компоненты" };
pub const tier_asset: Msg = .{ .en = "Assets", .ru = "Ассеты" };
pub const tier_project: Msg = .{ .en = "Project", .ru = "Проект" };
pub const at_locations: Msg = .{ .en = "Locations", .ru = "Локации" };
pub const at_battles: Msg = .{ .en = "Battles", .ru = "Бои" };
pub const at_characters: Msg = .{ .en = "Characters", .ru = "Персонажи" };
pub const at_items: Msg = .{ .en = "Items", .ru = "Предметы" };
pub const at_weapons: Msg = .{ .en = "Weapons", .ru = "Оружие" };
pub const at_ammo: Msg = .{ .en = "Ammo", .ru = "Патроны" };
pub const at_things: Msg = .{ .en = "Items", .ru = "Предметы" };
pub const at_attacks: Msg = .{ .en = "Enemy attacks", .ru = "Атаки врагов" };
pub const at_scenes: Msg = .{ .en = "Scenes", .ru = "Сцены" };
pub const at_sounds: Msg = .{ .en = "Sounds", .ru = "Звуки" };
pub const sb_problems: Msg = .{ .en = "Mod check: {d} problems", .ru = "Проверка мода: проблем — {d}" };
pub const tb_play: Msg = .{ .en = "Play", .ru = "Играть" };
pub const sb_saved: Msg = .{ .en = "Saved", .ru = "Сохранено" };
pub const tb_fit: Msg = .{ .en = "Fit", .ru = "Вписать" };
pub const st_layer_locked: Msg = .{ .en = "The layer is locked: open its lock to paint", .ru = "Слой заблокирован: снимите замок, чтобы рисовать" };
pub const ok_heroes: Msg = .{ .en = "Allies", .ru = "Свои" };
pub const ok_enemies: Msg = .{ .en = "Enemies", .ru = "Враги" };
pub const ok_neutral: Msg = .{ .en = "Neutral", .ru = "Нейтральные" };
pub const ok_actors: Msg = .{ .en = "Characters", .ru = "Персонажи" };
pub const ok_items: Msg = .{ .en = "Items and boxes", .ru = "Предметы и ящики" };
pub const ok_props: Msg = .{ .en = "Props", .ru = "Пропы" };
pub const ok_areas: Msg = .{ .en = "Triggers and exits", .ru = "Триггеры и выходы" };
pub const cam_position: Msg = .{ .en = "Position", .ru = "Позиция" };
pub const cam_target: Msg = .{ .en = "Target", .ru = "Цель" };
pub const cam_fov: Msg = .{ .en = "Field of view", .ru = "Угол обзора" };
pub const cam_floor: Msg = .{ .en = "Floor height", .ru = "Высота пола" };
pub const cam_bank: Msg = .{ .en = "Bank", .ru = "Крен" };
pub const sb_view: Msg = .{ .en = "LMB pick · RMB / middle drag pan · wheel zoom", .ru = "ЛКМ — выбрать · ПКМ / средняя — двигать вид · колесо — масштаб" };
pub const sb_objects: Msg = .{ .en = "LMB pick, drag · RMB menu · Delete remove · wheel zoom", .ru = "ЛКМ — выбрать, тащить · ПКМ — меню · Delete — удалить · колесо — масштаб" };
pub const sb_hand: Msg = .{ .en = "LMB drag the view or an area · wheel zoom", .ru = "ЛКМ — двигать вид или область · колесо — масштаб" };
pub const sb_brush: Msg = .{ .en = "LMB paint · RMB drag pan · Ctrl+Z undo a stroke", .ru = "ЛКМ — рисовать · ПКМ — двигать вид · Ctrl+Z — отменить мазок" };
pub const sb_light: Msg = .{ .en = "LMB pick, drag a lamp or add one", .ru = "ЛКМ — выбрать, тащить лампу или добавить новую" };
pub const sb_area: Msg = .{ .en = "LMB add a corner · Enter close · Backspace last corner · Esc drop", .ru = "ЛКМ — угол · Enter — замкнуть · Backspace — убрать угол · Esc — сбросить" };
pub const sb_points: Msg = .{ .en = "LMB put the picked scene point", .ru = "ЛКМ — поставить выбранную точку сцены" };
pub const sb_camera: Msg = .{ .en = "Drag the rings to orbit · centre to pan · wheel over the gizmo nearer", .ru = "Тяните кольца — вращение · центр — сдвиг · колесо над гизмо — ближе" };
pub const sb_pos: Msg = .{ .en = "Position: {d}, {d}", .ru = "Позиция: {d}, {d}" };
pub const sb_zoom: Msg = .{ .en = "Zoom: {d:.0}%", .ru = "Масштаб: {d:.0}%" };
pub const chip_enemy: Msg = .{ .en = "Enemy", .ru = "Враг" };
pub const chip_hero: Msg = .{ .en = "Hero", .ru = "Герой" };
pub const chip_weapon: Msg = .{ .en = "Weapon", .ru = "Оружие" };
pub const chip_ammo: Msg = .{ .en = "Ammo", .ru = "Патроны" };
pub const chip_item: Msg = .{ .en = "Item", .ru = "Предмет" };
pub const chip_attack: Msg = .{ .en = "Enemy attack", .ru = "Атака врага" };
pub const sec_look: Msg = .{ .en = "Look", .ru = "Внешний вид" };
pub const sec_model: Msg = .{ .en = "Model", .ru = "Модель" };
pub const sec_textures: Msg = .{ .en = "Textures", .ru = "Текстуры" };
pub const sec_anims: Msg = .{ .en = "Animations", .ru = "Анимации" };
pub const an_unbound: Msg = .{ .en = "not bound", .ru = "не привязана" };
pub const an_frames: Msg = .{ .en = "{d} fr.", .ru = "{d} кадр." };
pub const an_broken_title: Msg = .{ .en = "Bound, but not in the model", .ru = "Привязаны, но в модели их нет" };
pub const an_idle: Msg = .{ .en = "idle (random)", .ru = "idle (случайная)" };
pub const an_missing: Msg = .{ .en = "The model has no such animation: the game plays nothing new, the one shown before runs to its end and stays.", .ru = "В модели нет такой анимации: игра ничего не проиграет, предыдущая доиграет до конца и замрёт." };
pub const an_missing_og: Msg = .{ .en = "The model has no such animation: the game shows the idle instead (OpenGorky).", .ru = "В модели нет такой анимации: вместо неё игра покажет idle (OpenGorky)." };
pub const an_lifted: Msg = .{ .en = "Lifted by enemy", .ru = "Поднят врагом" };
pub const an_lifted_og: Msg = .{ .en = "Built in until bound: the game takes {s}.", .ru = "Встроенная, пока не привязана: игра берёт {s}." };
pub const an_add: Msg = .{ .en = "+ Bind a slot to {s}…", .ru = "+ Привязать слот к {s}…" };
pub const an_autobind: Msg = .{ .en = "Auto-bind missing", .ru = "Привязать недостающие" };
pub const st_autobind: Msg = .{ .en = "{s}: {d} bindings now name the model's animation of the slot's name, {d} still name none", .ru = "{s}: привязок к анимации с именем слота: {d}, без анимации осталось: {d}" };
pub const an_hint: Msg = .{ .en = "The model's animations live in its .ani (list on the left; new ones come from .glb). The script binds the names the game asks for (walk, death…) to them.", .ru = "Анимации модели лежат в её .ani (список слева; новые — импортом из .glb). Скрипт привязывает к ним имена, которые просит игра (walk, death…)." };
pub const sec_base: Msg = .{ .en = "Base stats", .ru = "Основные" };
pub const sec_ai: Msg = .{ .en = "AI", .ru = "ИИ" };
pub const part_anims_n: Msg = .{ .en = "Animations ({d})", .ru = "Анимации ({d})" };
pub const anim_search: Msg = .{ .en = "Search animations…", .ru = "Поиск анимаций…" };
pub const pv_reset: Msg = .{ .en = "Reset view", .ru = "Сбросить вид" };
pub const pv_texture: Msg = .{ .en = "Texture", .ru = "Текстура" };
pub const pv_wire: Msg = .{ .en = "Wireframe", .ru = "Каркас" };
pub const lp_brush_size: Msg = .{ .en = "Brush size", .ru = "Размер кисти" };
pub const lp_brush_mode: Msg = .{ .en = "Brush mode", .ru = "Режим кисти" };
pub const lp_overlay: Msg = .{ .en = "Overlay opacity", .ru = "Прозрачность слоя" };
pub const close: Msg = .{ .en = "Close", .ru = "Закрыть" };

// Enemy preview.
pub const no_model: Msg = .{ .en = "No model for this look", .ru = "Нет модели для этого вида" };
pub const anim_hint: Msg = .{ .en = "Drag the model to turn and tilt it, wheel to zoom, right or middle drag to move; the animation is picked below on the left. Pane edges drag too.", .ru = "Тяните модель мышью, чтобы повернуть и наклонить, колесо — масштаб, правая или средняя кнопка — сдвиг; анимация выбирается слева внизу. Границы частей тоже тянутся." };
pub const model_hint: Msg = .{ .en = "Drag the model to turn and tilt it, wheel to zoom, right or middle drag to move.", .ru = "Тяните модель мышью, чтобы повернуть и наклонить, колесо — масштаб, правая или средняя кнопка — сдвиг." };
pub const search_hint: Msg = .{ .en = "Type to search (name or id)", .ru = "Поиск: начните печатать (название или id)" };

// Art import.
pub const b_icon_png: Msg = .{ .en = "New icon from PNG…", .ru = "Новая иконка из PNG…" };
pub const b_new_texture: Msg = .{ .en = "New texture from PNG…", .ru = "Новая текстура из PNG…" };
pub const b_export_texture: Msg = .{ .en = "Texture to PNG…", .ru = "Текстура в PNG…" };
pub const st_icon_added: Msg = .{ .en = "Icon {s} added; saved with Ctrl+S", .ru = "Иконка {s} добавлена; сохраняется по Ctrl+S" };
pub const st_look_added: Msg = .{ .en = "New look {s}: a copy of the model with the texture; saved with Ctrl+S", .ru = "Новый вид {s}: копия модели с этой текстурой; сохраняется по Ctrl+S" };
pub const st_exported: Msg = .{ .en = "Texture written to {s}: paint over it (keep the layout) and load it back", .ru = "Текстура записана в {s}: рисуйте поверх (сохраняя развёртку) и загружайте обратно" };
pub const st_import_failed: Msg = .{ .en = "cannot use the file: {t}", .ru = "не удалось использовать файл: {t}" };

// Models as glTF (.glb) and their fields.
pub const b_glb_out: Msg = .{ .en = "Export model (.glb)…", .ru = "Экспорт модели (.glb)…" };
pub const b_glb_in: Msg = .{ .en = "Import model (.glb)…", .ru = "Импорт модели (.glb)…" };
pub const b_anims_in: Msg = .{ .en = "Import animations (.glb)…", .ru = "Импорт анимаций (.glb)…" };
pub const chip_texture: Msg = .{ .en = "Texture", .ru = "Текстура" };
pub const at_looks: Msg = .{ .en = "Models and animations", .ru = "Модели и анимации" };
pub const at_models: Msg = .{ .en = "Models", .ru = "Модели" };
pub const sum_used: Msg = .{ .en = "used by: {d}", .ru = "где используется: {d}" };
pub const look_used_none: Msg = .{ .en = "Nothing wears it", .ru = "Никем не используется" };
pub const tex_none: Msg = .{ .en = "The texture can't be read", .ru = "Текстуру не прочитать" };
pub const b_tex_in: Msg = .{ .en = "Replace from PNG…", .ru = "Заменить из PNG…" };
pub const tex_shared: Msg = .{ .en = "A game texture: the game's models share it, so it stays as it is. A new one comes as a new look, from a character's Look block.", .ru = "Текстура игры: её делят модели игры, поэтому она не меняется. Новая — новым обликом, из блока «Внешний вид» персонажа." };
pub const st_tex_in: Msg = .{ .en = "Texture {s} replaced (the editor made it, no game model wears it); saved with Ctrl+S", .ru = "Текстура {s} заменена (сделана редактором, модели игры её не носят); сохраняется по Ctrl+S" };
pub const sec_new_look: Msg = .{ .en = "New look", .ru = "Новый облик" };
pub const look_new_note: Msg = .{ .en = "A copy of the model wearing a PNG, or a model from .glb: this character takes it, the model and textures above stay as they are. They are edited on their own pages (the arrow buttons).", .ru = "Копия модели с текстурой из PNG или модель из .glb: её получает этот персонаж, модель и текстуры выше не меняются. Сами они правятся на своих страницах (кнопки со стрелкой)." };
pub const b_new_texture_of: Msg = .{ .en = "New {s} from PNG…", .ru = "Новая {s} из PNG…" };
pub const st_glb_out: Msg = .{ .en = "Model written to {s} (textures, skeleton, animations, attach points)", .ru = "Модель записана в {s} (текстуры, скелет, анимации, точки крепления)" };
pub const st_glb_in: Msg = .{ .en = "New model {s} from the .glb ({d} textures); the entry uses it; saved with Ctrl+S", .ru = "Новая модель {s} из .glb (текстур: {d}); запись использует её; сохраняется по Ctrl+S" };
pub const st_glb_new: Msg = .{ .en = "New model {s} from the .glb ({d} textures); nothing wears it yet: pick it as a look's or weapon's Model; saved with Ctrl+S", .ru = "Новая модель {s} из .glb (текстур: {d}); пока никем не используется: выберите её в поле «Модель» внешности или оружия; сохраняется по Ctrl+S" };
pub const mdl_import_new: Msg = .{ .en = "Import a model (.glb)…", .ru = "Импорт модели (.glb)…" };
pub const mdl_own: Msg = .{ .en = "project", .ru = "проект" };
pub const mdl_own_unused: Msg = .{ .en = "project · not used", .ru = "проект · не используется" };
pub const mdl_delete: Msg = .{ .en = "Delete from the project", .ru = "Удалить из проекта" };
pub const mdl_delete_note: Msg = .{ .en = "The project's own model and nothing wears it: deleting takes its files and the textures only it has out of src/assets/ on save (Ctrl+Z brings it back).", .ru = "Своя модель проекта, никто её не носит: удаление убирает её файлы и текстуры, которые есть только у неё, из src/assets/ при сохранении (Ctrl+Z вернёт)." };
pub const st_mdl_deleted: Msg = .{ .en = "Model {s} deleted from the project ({d} files); src/assets/ loses them on save, Ctrl+Z brings it back", .ru = "Модель {s} удалена из проекта (файлов: {d}); из src/assets/ они уйдут при сохранении, Ctrl+Z вернёт" };
pub const st_glb_fit: Msg = .{ .en = "New model {s} from the .glb ({d} textures); it had no height: {d} makes it as large as the old model (Model height); the entry uses it; saved with Ctrl+S", .ru = "Новая модель {s} из .glb (текстур: {d}); высоты в нём не было: {d} делает её размером со старую модель (Высота модели); запись использует её; сохраняется по Ctrl+S" };
pub const st_anims_in: Msg = .{ .en = "{s}: added {d} ({s}), replaced {d} ({s}); saved with Ctrl+S", .ru = "{s}: добавлено {d} ({s}), заменено {d} ({s}); сохраняется по Ctrl+S" };
pub const st_glb_failed: Msg = .{ .en = "cannot import the .glb: {s} ({t})", .ru = "не удалось импортировать .glb: {s} ({t})" };
pub const glb_verts: Msg = .{ .en = "a part has more than 1024 vertices or 2048 triangles (the game's limit); split it", .ru = "у части больше 1024 вершин или 2048 треугольников (предел игры); разделите её" };
pub const glb_tri: Msg = .{ .en = "a triangle repeats a vertex or points past the part", .ru = "треугольник повторяет вершину или ссылается за пределы части" };
pub const glb_name: Msg = .{ .en = "a part, texture, attach point or animation name is too long (31 characters, textures 47)", .ru = "слишком длинное имя части, текстуры, точки крепления или анимации (31 символ, текстуры 47)" };
pub const glb_bone: Msg = .{ .en = "a bone index is outside the skeleton", .ru = "номер кости вне скелета" };
pub const glb_skin: Msg = .{ .en = "too many bone weights, or several skins (one armature only)", .ru = "слишком много весов костей или несколько скинов (нужен один скелет)" };
pub const glb_skel: Msg = .{ .en = "the skeleton differs from the model's (bone count)", .ru = "скелет не совпадает со скелетом модели (число костей)" };
pub const glb_file: Msg = .{ .en = "not a self-contained .glb (export glTF Binary with embedded textures)", .ru = "это не цельный .glb (экспортируйте glTF Binary со встроенными текстурами)" };
pub const glb_anim: Msg = .{ .en = "an animation has no frames or runs past them", .ru = "у анимации нет кадров или она выходит за них" };
pub const glb_size: Msg = .{ .en = "a texture's size is not one the game takes (power-of-two sides up to 256, at most 8:1)", .ru = "размер текстуры игре не подходит (стороны — степени двойки до 256, не больше 8:1)" };
pub const glb_other: Msg = .{ .en = "the file has data the game cannot use", .ru = "в файле данные, которые игра не может использовать" };
pub const m_height_note: Msg = .{ .en = "The model {s}'s: every character wearing it grows with it.", .ru = "Модели {s}: с ней меняются все персонажи в ней." };
pub const sec_size: Msg = .{ .en = "Size", .ru = "Размер" };
pub const p_char_size: Msg = .{ .en = "Size (charSize)", .ru = "Размер (charSize)" };
pub const char_size_note: Msg = .{ .en = "Takes {d}×{d} tiles in battle (9 and more: 3×3, 4 and more: 2×2); the bigger, the easier to hit.", .ru = "Занимает в бою {d}×{d} клеток (9 и больше — 3×3, 4 и больше — 2×2); чем больше, тем легче попасть." };
pub const p_ai_mode: Msg = .{ .en = "AI mode", .ru = "Режим ИИ" };
pub const ai_mode_0: Msg = .{ .en = "0 · ordinary", .ru = "0 · обычный" };
pub const ai_mode_1: Msg = .{ .en = "1 · only its AITargetLock target", .ru = "1 · только цель AITargetLock" };
pub const ai_mode_2: Msg = .{ .en = "2 · skips its turns", .ru = "2 · пропускает ходы" };
pub const ai_mode_3: Msg = .{ .en = "3 · keeps to its guard point", .ru = "3 · держится точки охраны" };
pub const ai_unset: Msg = .{ .en = "— (not set)", .ru = "— (не задано)" };
pub const ai_mode_note: Msg = .{ .en = "ai_mode: 0 ordinary, 1 only its AITargetLock target, 2 skips its turns, 3 keeps to its guard point.", .ru = "ai_mode: 0 обычный, 1 только цель AITargetLock, 2 пропускает ходы, 3 держится точки охраны." };
pub const p_rage_start: Msg = .{ .en = "Rage at start", .ru = "Ярость в начале" };
pub const p_rage_note: Msg = .{ .en = "rage: each hit taken adds 1; at the max (max_rage above 0) it fills and starts again from 0.", .ru = "rage: каждое полученное попадание прибавляет 1; на максимуме (max_rage больше 0) ярость срабатывает и копится с 0." };
pub const sec_moves: Msg = .{ .en = "Moves and locks", .ru = "Движение и запреты" };
pub const p_rot_speed: Msg = .{ .en = "Turn speed (rotSpeed)", .ru = "Скорость поворота (rotSpeed)" };
pub const p_move_lock: Msg = .{ .en = "Stays put (moveLock)", .ru = "Не ходит (moveLock)" };
pub const p_move_lock_n: Msg = .{ .en = "Never walks in battle until the victory clears it (scripts set and clear it: wall bosses).", .ru = "Не ходит в бою, пока победа не снимет запрет (скрипты ставят и снимают его: боссы у стен)." };
pub const p_attack_lock: Msg = .{ .en = "Never strikes (attackLock)", .ru = "Не атакует (attackLock)" };
pub const p_attack_lock_n: Msg = .{ .en = "Takes no strike and no counter-attack until the victory clears it.", .ru = "Не наносит ударов и не контратакует, пока победа не снимет запрет." };
pub const p_ally: Msg = .{ .en = "AI ally (avoidEnumerate)", .ru = "Союзник под ИИ (avoidEnumerate)" };
pub const p_ally_n: Msg = .{ .en = "Not one of the party the player leads: fights on the heroes' side by itself (Medusa).", .ru = "Не в отряде игрока: сражается на стороне героев сама, под ИИ (Медуза)." };
pub const p_woman_n: Msg = .{ .en = "1: a woman: pushes no boxes, no health2 voice.", .ru = "1 — женщина: не толкает ящики, без голоса health2." };
pub const p_sex: Msg = .{ .en = "Woman (sex)", .ru = "Женщина (sex)" };
pub const p_class_type: Msg = .{ .en = "Battle class (classType)", .ru = "Боевой класс (classType)" };
pub const p_class_type_n: Msg = .{ .en = "The exe's own behaviour by it (the Monitor's, Grandma's…), its base AI profile and extra abilities; 0: an ordinary fighter.", .ru = "По нему — особое поведение из exe (мониторы, Бабка…), базовый профиль ИИ и доп. способности; 0 — обычный боец." };
pub const class_plain: Msg = .{ .en = "0 · ordinary", .ru = "0 · обычный" };
pub const ai_fields_note: Msg = .{ .en = "The fighter's own numbers (ai_*_weight): its AI profile's, where it sets them, win over them.", .ru = "Собственные числа бойца (ai_*_weight): если профиль ИИ задаёт их, действуют числа профиля." };
pub const ai_hero_note: Msg = .{ .en = "Only when the AI leads the hero: an ally (avoidEnumerate) or the autobattle. With attack, defense and player distance all 0 it acts as an ordinary monster.", .ru = "Только когда героем управляет ИИ: союзник (avoidEnumerate) или автобой. Если атака, защита и дистанция до игрока равны 0, действует как обычный монстр." };
pub const sec_leftovers: Msg = .{ .en = "Other fields", .ru = "Прочие поля" };
pub const leftovers_note: Msg = .{ .en = "Set by the script but not read for this fighter: enemies resist by the table and Resist rows, a hero's armour is its worn items' pr*, movable and explosive are obstacles', experience and level heroes'.", .ru = "Скрипт их задаёт, но для этого бойца они не читаются: враги сопротивляются по таблице и строкам Resist, броня героя — pr* надетых вещей, movable и explosive — поля препятствий, опыт и уровень — героев." };
pub const p_act_rot: Msg = .{ .en = "Model turn (actRot)", .ru = "Поворот модели (actRot)" };
pub const p_movable: Msg = .{ .en = "Pushable (movable)", .ru = "Толкаемый (movable)" };
pub const p_explosive: Msg = .{ .en = "Explodes (explosive)", .ru = "Взрывается (explosive)" };
pub const p_explode_weapon: Msg = .{ .en = "Blast weapon (explodeWeapon)", .ru = "Оружие взрыва (explodeWeapon)" };
pub const p_pr: Msg = .{ .en = "Armour field {s}", .ru = "Поле брони {s}" };
pub const m_height: Msg = .{ .en = "Model height", .ru = "Высота модели" };
pub const m_center: Msg = .{ .en = "Model centre", .ru = "Центр модели" };
pub const m_bone: Msg = .{ .en = "bone", .ru = "кость" };
pub const m_angle: Msg = .{ .en = "rot {s}", .ru = "пов {s}" };
pub const m_rotation: Msg = .{ .en = "Model rotation (a weapon's pose in the hand)", .ru = "Поворот модели (у оружия — как оно лежит в руке)" };
pub const m_attach_hint: Msg = .{ .en = "The game looks points up by exact name: one_hand (a one-handed weapon in the hand), two_hands (a two-handed one), default. Offset from the bone's joint, angles in radians.", .ru = "Игра ищет точки по точному имени: one_hand (одноручное оружие в руке), two_hands (двуручное), default. Сдвиг от сустава кости, углы в радианах." };
pub const m_attach_add: Msg = .{ .en = "+ {s}", .ru = "+ {s}" };
pub const st_tex_replaced: Msg = .{ .en = "{s}: texture {s} replaced (a model the editor made, not shared with the game's); saved with Ctrl+S", .ru = "{s}: текстура {s} заменена (модель сделана редактором, игра её не делит); сохраняется по Ctrl+S" };
pub const st_mesh_set: Msg = .{ .en = "{s}: {s} set (every entry with this model)", .ru = "{s}: {s} изменено (у всех записей с этой моделью)" };

// Resistances, enemy weapons.
pub const r_title: Msg = .{ .en = "Resistances", .ru = "Сопротивления" };
pub const r_game: Msg = .{ .en = "as in the game (exe table)", .ru = "как в игре (таблица exe)" };
pub const r_rows: Msg = .{ .en = "rules resist.ss by {s} (a tick writes it)", .ru = "правила resist.ss по {s} (галочка записывает)" };
pub const r_scope: Msg = .{ .en = "Ticks write", .ru = "Галочки пишут" };
pub const r_scope_obj: Msg = .{ .en = "This fighter", .ru = "Этому бойцу" };
pub const r_scope_class: Msg = .{ .en = "Whole class", .ru = "Всему классу" };
pub const r_decoy: Msg = .{ .en = "Resist: decoy", .ru = "Защита: приманка" };
pub const r_flammable: Msg = .{ .en = "Resist: fuel", .ru = "Защита: горючее" };
pub const wp_built: Msg = .{ .en = "not in the game's battles: the editor gives this close attack to each one it adds (its .wpn in the battle)", .ru = "в боях игры нет: редактор даёт эту ближнюю атаку каждому, кого добавляет (его .wpn в бою)" };
pub const wp_class_of: Msg = .{ .en = "class {s} · {s}", .ru = "класс {s} · {s}" };
pub const wp_change: Msg = .{ .en = "change (this enemy)", .ru = "сменить (этому врагу)" };
pub const wp_option: Msg = .{ .en = "{s} · damage {d}", .ru = "{s} · урон {d}" };
pub const wp_change_class: Msg = .{ .en = "change (every enemy of the class)", .ru = "сменить (всем врагам класса)" };
pub const st_weapon_class: Msg = .{ .en = "{s} → {s}: {d} weapons of the class's enemies", .ru = "{s} → {s}: оружий у врагов класса — {d}" };
pub const wp_title: Msg = .{ .en = "Weapons", .ru = "Оружие" };
pub const sec_arsenal: Msg = .{ .en = "Weapons & attacks", .ru = "Оружие и атаки" };
pub const wp_hint: Msg = .{ .en = "Assigned here, edited on the weapon's page (the arrow): its class, damage, effects and each enemy's strike with it.", .ru = "Здесь только назначается, правится на странице оружия (стрелка): класс, урон, эффекты и удар каждого врага им." };
pub const sum_arsenal: Msg = .{ .en = "{d} · AI: {s}", .ru = "{d} · ИИ: {s}" };
pub const wa_weapon: Msg = .{ .en = "Weapon", .ru = "Оружие" };
pub const wa_attack: Msg = .{ .en = "Attack", .ru = "Атака" };
pub const wa_damage: Msg = .{ .en = "Own damage", .ru = "Свой урон" };
pub const wa_ai: Msg = .{ .en = "For the AI", .ru = "Для ИИ" };
pub const wa_hero_table: Msg = .{ .en = "by the hero table (no MonsterAttack row)", .ru = "по таблице героев (нет строки MonsterAttack)" };
pub const wa_hit_at: Msg = .{ .en = "{s} · hit at tick {d}", .ru = "{s} · попадание на тике {d}" };
pub const wa_second: Msg = .{ .en = " · 2nd hit +{d}", .ru = " · 2-е попадание +{d}" };
pub const wa_special: Msg = .{ .en = " · own code of {d}", .ru = " · свой код {d}" };
pub const wa_given: Msg = .{ .en = " · given by a rule", .ru = " · выдаётся правилом" };
pub const wa_dmg_class: Msg = .{ .en = "{s}: the class {s}'s, for every enemy holding it ({d}); edited on its page. A number here is this character's alone.", .ru = "{s}: значение класса {s} для всех врагов с ним ({d}); правится на его странице. Число здесь — только у этого персонажа." };
pub const wa_dmg_class_classic: Msg = .{ .en = "{s}: the class {s}'s, for every enemy holding it ({d}); edited on its page.", .ru = "{s}: значение класса {s} для всех врагов с ним ({d}); правится на его странице." };
pub const wa_dmg_own: Msg = .{ .en = "{d}: this character's own (its attack row); the class {s} has {s}. Empty: the class's again.", .ru = "{d}: свой у этого персонажа (его строка атаки); у класса {s} — {s}. Пусто: снова как у класса." };
pub const wa_worth: Msg = .{ .en = "worth {d} per foe hit at 100%", .ru = "стоит {d} за врага при 100%" };
pub const wa_worth_eval: Msg = .{ .en = "worth by its profile's own scoring", .ru = "цена — по собственной оценке профиля" };
pub const wa_range: Msg = .{ .en = " · within {d} tiles", .ru = " · не дальше {d} клеток" };
pub const wa_recharge: Msg = .{ .en = " · out {d} turns after a shot", .ru = " · после выстрела {d} хода недоступно" };
pub const ai_how: Msg = .{ .en = "How the AI chooses", .ru = "Как выбирает ИИ" };
pub const ai_how_try: Msg = .{ .en = "Each turn it tries every tile it can walk to, every ready weapon (ammo, no recharge) at every aim its zone allows. A foe on a hit tile is worth (damage + {d}) × hit % × attack {d}; an ally there costs {d}% of that.", .ru = "Каждый ход он перебирает все клетки, куда может дойти, и каждое готовое оружие (есть патроны, не перезаряжается) во все цели его зоны. Враг на поражённой клетке стоит (урон + {d}) × % попадания × атака {d}; союзник там отнимает {d}% от этого." };
pub const ai_how_try_eval: Msg = .{ .en = "Each turn it tries every tile it can walk to, every ready weapon at every aim its zone allows; what a hit tile is worth is its profile's own scoring ({s}: see the AI profile).", .ru = "Каждый ход он перебирает все клетки, куда может дойти, и каждое готовое оружие во все цели его зоны; цену поражённой клетки задаёт собственная оценка профиля ({s}: см. профиль ИИ)." };
pub const ai_how_place: Msg = .{ .en = "Then {s}; with no strike, minus the distance to the nearest foe × {d} (it closes in){s}.", .ru = "Затем {s}; без удара — минус расстояние до ближайшего врага × {d} (подходит){s}." };
pub const ai_how_danger: Msg = .{ .en = "minus the danger of the tile × defense {d}", .ru = "минус опасность клетки × защита {d}" };
pub const ai_how_no_danger: Msg = .{ .en = "the danger of the tile is not weighed (its profile)", .ru = "опасность клетки не учитывается (его профиль)" };
pub const ai_how_away: Msg = .{ .en = "; after a strike plus that distance (it steps away)", .ru = "; после удара плюс это расстояние (отходит)" };
pub const ai_how_one: Msg = .{ .en = "The highest score wins (a tie: the shorter path): target, weapon and where to stand are one decision.", .ru = "Побеждает наибольшая оценка (при равенстве — короткий путь): цель, оружие и место — одно решение." };
pub const ai_how_skip: Msg = .{ .en = "ai_mode 2: it skips its turns.", .ru = "ai_mode 2: он пропускает ходы." };
pub const ai_how_lock: Msg = .{ .en = "ai_mode 1: only its locked target (AITargetLock) counts as a foe.", .ru = "ai_mode 1: врагом считается только его закреплённая цель (AITargetLock)." };
pub const ai_how_guard: Msg = .{ .en = "ai_mode 3: with no strike it keeps to its guard point instead of closing in.", .ru = "ai_mode 3: без удара держится своей точки охраны, а не подходит." };
pub const ai_how_by_health: Msg = .{ .en = "Its secondaryWeapon only below half health.", .ru = "Его secondaryWeapon — только при здоровье ниже половины." };
pub const ai_how_first: Msg = .{ .en = "It plans with its first weapon only.", .ru = "Планирует только первым оружием." };
pub const ai_how_free_arms: Msg = .{ .en = "Not with an arm a box blocks.", .ru = "Не рукой, которую загораживает ящик." };
pub const ai_how_best: Msg = .{ .en = "Best case: {s} ({d}) whenever a foe is in its reach; the others when it is out of reach or recharging.", .ru = "В лучшем случае: {s} ({d}), когда враг в его зоне; остальные — когда тот вне досягаемости или перезаряжается." };
pub const ai_how_limits: Msg = .{ .en = "A best case per weapon, not a simulation: the attack's animation, timings and damage type do not count.", .ru = "Лучший случай для каждого оружия, не симуляция: анимация атаки, тайминги и тип урона не учитываются." };
pub const wp_none: Msg = .{ .en = "No weapons found in the battles", .ru = "В боях оружие не найдено" };
pub const wp_long: Msg = .{ .en = "ranged", .ru = "дальняя" };
pub const wp_short: Msg = .{ .en = "melee", .ru = "ближняя" };
pub const b_export_icon: Msg = .{ .en = "Icon to PNG…", .ru = "Иконка в PNG…" };
pub const st_box_added: Msg = .{ .en = "Box {s} placed: add its contents on the right; Ctrl+Z takes it away", .ru = "Ящик {s} поставлен: справа добавьте содержимое; Ctrl+Z — убрать" };

// Scenes tab.
pub const sc_skip: Msg = .{ .en = "Shorten: only its changes", .ru = "Сократить: оставить только последствия" };
pub const sc_unskip: Msg = .{ .en = "Shortened — restore it", .ru = "Сокращена — вернуть как было" };
pub const sc_skip_hint: Msg = .{ .en = "dialogue, pauses, fades, animations, camera and sound are commented out (as a skip does), the rest stays; the same in the original game", .ru = "диалоги, паузы, затемнения, анимации, камера и звук закомментированы (как при пропуске), остальное остаётся; так же и в оригинальной игре" };
pub const sc_no_changes: Msg = .{ .en = "Only shows things", .ru = "Только показывает" };
pub const sc_none: Msg = .{ .en = "No level script starts it (another scene does, ADDONSCRIPTLET)", .ru = "Скрипты уровней её не запускают (запускает другая сцена, ADDONSCRIPTLET)" };
pub const sc_game_off: Msg = .{ .en = "commented out in the original", .ru = "закомментировано в оригинале" };
pub const sc_turn_on: Msg = .{ .en = "Off — turn it on again", .ru = "Отключено — включить" };
pub const sc_unsafe: Msg = .{ .en = "shares lines with other code: edit the script by hand", .ru = "делит строки с другим кодом: править скрипт вручную" };
pub const menu_delete_box: Msg = .{ .en = "Delete the box", .ru = "Удалить ящик" };
pub const st_box_deleted: Msg = .{ .en = "Box {s} deleted (Ctrl+Z brings it back)", .ru = "Ящик {s} удалён (Ctrl+Z — вернуть)" };

// Triggers.
pub const menu_trigger: Msg = .{ .en = "Trigger: its script and uses", .ru = "Триггер: скрипт и где используется" };
pub const tr_title: Msg = .{ .en = "Trigger area: {s}", .ru = "Область-триггер: {s}" };
pub const tr_refs: Msg = .{ .en = "Where the level's scripts use it (turning a block off is the same in the original game)", .ru = "Где её используют скрипты уровня (отключение блока работает и в оригинале)" };
pub const tr_no_refs: Msg = .{ .en = "No script names it", .ru = "Скрипты её не упоминают" };
pub const tr_own: Msg = .{ .en = "Its own script ({s})", .ru = "Собственный скрипт ({s})" };
pub const tr_party: Msg = .{ .en = "Party: what walking into it does to a hero", .ru = "Отряд: что вход в неё делает с героем" };
pub const tr_party_hint: Msg = .{ .en = "Adds the game's own calls to the area's block. Joins: EnableObject, HERO_EnableEnumerate 1, as McFadden in the sewers (a hero of this level). Leaves: HERO_EnableEnumerate 0, DeleteObject, as Medusa and Slavsky: gone for good", .ru = "Добавляет в блок области вызовы самой игры. Вступает: EnableObject, HERO_EnableEnumerate 1, как Макфадден в канализации (герой этого уровня). Уходит: HERO_EnableEnumerate 0, DeleteObject, как Медуза и Славски: навсегда" };
pub const tr_party_hint_og: Msg = .{ .en = "Adds the calls to the area's block in the level's logic.ogs. Joins: object::Enable, hero::SetInParty 1 (a hero of this level). Leaves: hero::SetInParty 0, object::Delete: gone for good", .ru = "Добавляет вызовы в блок области в logic.ogs уровня. Вступает: object::Enable, hero::SetInParty 1 (герой этого уровня). Уходит: hero::SetInParty 0, object::Delete: навсегда" };
pub const tr_join: Msg = .{ .en = "Joins", .ru = "Вступает" };
pub const tr_leave: Msg = .{ .en = "Leaves", .ru = "Уходит" };
pub const st_party_call: Msg = .{ .en = "{s}: the party change added to the block of area {s}; Save writes it", .ru = "{s}: смена отряда добавлена в блок области {s}; записывает «Сохранить»" };
pub const tr_refs_og: Msg = .{ .en = "Where the level's OG Script uses it", .ru = "Где её используют скрипты уровня (OG Script)" };
pub const tr_turn_off: Msg = .{ .en = "Turn this block off", .ru = "Отключить блок" };
pub const sc_og_switch: Msg = .{ .en = "switched by the level variable {s}: off when it starts as {s} (level.ogs, «Fields»)", .ru = "переключается переменной уровня {s}: отключено, если её начальное значение {s} (level.ogs, «Поля»)" };
pub const sc_og_no_switch: Msg = .{ .en = "no switch variable of its own (if (ready_x and …)): edit the code to turn it off", .ru = "своей переменной-переключателя нет (if (ready_x and …)): отключается правкой кода" };

// History.
pub const history_n_title: Msg = .{ .en = "Edits of this session ({d}), newest first", .ru = "Правки за сеанс ({d}), новые сверху" };
pub const history_empty: Msg = .{ .en = "No edits yet.", .ru = "Правок пока нет." };
pub const history_pick: Msg = .{ .en = "Click a row to see what it changed. Nothing changes until you press \u{201c}Return to this point\u{201d}.", .ru = "Щёлкните строку, чтобы увидеть, что она изменила. Ничего не меняется, пока вы не нажмёте «Вернуться к этой точке»." };
pub const history_was_saved: Msg = .{ .en = "saved already — returning before it changes the files again on the next save", .ru = "уже сохранено — возврат раньше него изменит файлы при следующем сохранении" };
pub const history_saved: Msg = .{ .en = "— saved here —", .ru = "— здесь сохранено —" };
pub const history_earlier: Msg = .{ .en = "— saved in earlier sessions —", .ru = "— сохранено в прошлых сеансах —" };
pub const history_original: Msg = .{ .en = "Original", .ru = "Оригинал" };
pub const history_original_info: Msg = .{ .en = "The files as the game had them before the editor first changed them.", .ru = "Файлы такими, какими они были в игре до первой правки в редакторе." };
pub const history_return: Msg = .{ .en = "Return to this point", .ru = "Вернуться к этой точке" };
pub const history_here: Msg = .{ .en = "This is how the files are now.", .ru = "Файлы сейчас именно такие." };
pub const history_back_session: Msg = .{ .en = "Undoes the {d} later edits of this session. Saved ones come back as unsaved changes until you Save. This can't be redone.", .ru = "Отменяет {d} более поздних правок этого сеанса. Уже сохранённые станут несохранёнными изменениями до «Сохранить». Повторить их будет нельзя." };
pub const history_back_past: Msg = .{ .en = "Puts back the files changed after this point as unsaved changes: Ctrl+Z takes them back, Save writes them into the game.", .ru = "Возвращает файлы, изменённые после этой точки, как несохранённые изменения: Ctrl+Z вернёт как было, «Сохранить» запишет в игру." };
pub const history_back_past_n: Msg = .{ .en = "First undoes this session's {d} edits (they can't be redone).", .ru = "Сначала отменяет {d} правок этого сеанса (повторить их будет нельзя)." };
pub const st_rolled_back: Msg = .{ .en = "{d} edits undone", .ru = "Отменено правок: {d}" };
pub const st_returned: Msg = .{ .en = "Returned: {d} files put back, not saved yet", .ru = "Возврат: {d} файлов восстановлено, пока не сохранено" };
pub const show_walk: Msg = .{ .en = "Walkable areas", .ru = "Проходимые области" };
pub const info_title: Msg = .{ .en = "Info", .ru = "Инфо" };
pub const info_file: Msg = .{ .en = "Defined in", .ru = "Где определён" };
pub const info_level: Msg = .{ .en = "Level", .ru = "Уровень" };
pub const info_includes: Msg = .{ .en = "Includes (#include, #inherit)", .ru = "Подключает (#include, #inherit)" };
pub const info_name_id: Msg = .{ .en = "classic_id · its string.tab name", .ru = "classic_id · имя в string.tab" };
pub const info_same_name: Msg = .{ .en = "Same classic_id (the same name; items: one inventory row)", .ru = "Тот же classic_id (то же имя; у предметов — одна строка инвентаря)" };
pub const info_fields: Msg = .{ .en = "Identity fields (the exe keys by them)", .ru = "Поля-идентификаторы (по ним выбирает exe)" };
pub const info_refs: Msg = .{ .en = "Names", .ru = "Ссылается на" };
pub const info_party: Msg = .{ .en = "Joins the party", .ru = "Вступает в отряд" };
pub const info_used: Msg = .{ .en = "Where used", .ru = "Где используется" };
pub const info_none: Msg = .{ .en = "Nothing to show", .ru = "Нечего показать" };
pub const info_not_found: Msg = .{ .en = "not found", .ru = "не найден" };
pub const info_strike: Msg = .{ .en = "hero's strike (by classic_id): {s}", .ru = "удар героя (по classic_id): {s}" };
pub const info_party_start: Msg = .{ .en = "In the party from the start (gamestart\\)", .ru = "В отряде с начала игры (gamestart\\)" };
pub const info_party_never: Msg = .{ .en = "No script makes it a party hero", .ru = "Ни один скрипт не делает его героем отряда" };
pub const info_used_none: Msg = .{ .en = "No level's script names it", .ru = "Ни один скрипт уровня его не упоминает" };
pub const unused_title: Msg = .{ .en = "Not used by the game", .ru = "Не используются игрой" };
pub const unused_hint: Msg = .{ .en = "Filled in the game's files, but no code reads them (the original or OpenGorky), so they are not editable: burning and poison always last 3 turns with 15/10/5 damage", .ru = "Заполнены в файлах игры, но их не читает ни оригинал, ни OpenGorky, поэтому не редактируются: горение и яд всегда 3 хода с уроном 15/10/5" };

// Code tab.
pub const code_stale: Msg = .{ .en = "• changed elsewhere too (Save asks first)", .ru = "• изменён и в другом месте (при сохранении — вопрос)" };
pub const code_changed: Msg = .{ .en = "• changed (Save puts it in)", .ru = "• изменено (войдёт при сохранении)" };
pub const code_keys: Msg = .{ .en = "Ctrl+Space completes · Tab next argument · Cmd+F find · Cmd+/ comment · Alt+Up/Down move lines · Cmd+Shift+K delete line · F12 / Cmd+click go to definition · Shift+F12 usages · Cmd+Shift+Z redo", .ru = "Ctrl+Пробел — дополнить · Tab — следующий аргумент · Cmd+F — поиск · Cmd+/ — комментарий · Alt+Вверх/Вниз — перенести строки · Cmd+Shift+K — удалить строку · F12 / Cmd+клик — к определению · Shift+F12 — использования · Cmd+Shift+Z — повтор" };
pub const snd_title: Msg = .{ .en = "Sounds of «{s}» (frame {d}/{d})", .ru = "Звуки «{s}» (кадр {d}/{d})" };
pub const snd_on: Msg = .{ .en = "sound on", .ru = "звук вкл" };
pub const snd_off: Msg = .{ .en = "sound off", .ru = "звук выкл" };
pub const snd_play: Msg = .{ .en = "play", .ru = "играть" };
pub const snd_frame: Msg = .{ .en = "frame {d}", .ru = "кадр {d}" };
pub const snd_add: Msg = .{ .en = "+ add a sound (at frame 0)", .ru = "+ добавить звук (на кадр 0)" };
pub const snd_shared: Msg = .{ .en = "In {s}.ani: for every look with this model. Click a name to swap it; < > move by a frame, « » by 10; several on one frame — the game picks one.", .ru = "В {s}.ani: для всех обликов с этой моделью. Клик по имени — заменить; < > — сдвиг на кадр, « » — на 10; несколько на одном кадре — игра выбирает один." };
pub const snd_import: Msg = .{ .en = "Import a sound…", .ru = "Импорт звука…" };
pub const snd_import_hint: Msg = .{ .en = "A WAV or MP3 goes into common/sound.dat as the game's own sounds are: PCM 16-bit mono 22050 Hz. Then it can be put on animation frames (enemy page, under the model).", .ru = "WAV или MP3 попадает в common/sound.dat в формате звуков игры: PCM 16 бит, моно, 22050 Гц. Потом его можно поставить на кадры анимации (страница врага, под моделью)." };
pub const snd_import_hint_og: Msg = .{ .en = "A WAV or MP3 goes into the project's src/assets/sounds/ as the game's own sounds are: PCM 16-bit mono 22050 Hz (a changed sound of the game too; the installed game is not touched).", .ru = "WAV или MP3 попадает в src/assets/sounds/ проекта в формате звуков игры: PCM 16 бит, моно, 22050 Гц (изменённый звук игры — туда же; установленная игра не трогается)." };
pub const snd_format: Msg = .{ .en = "{d} ch, {d} Hz, {d:.2} s, {d} KB", .ru = "{d} кан., {d} Гц, {d:.2} с, {d} КБ" };
pub const snd_export: Msg = .{ .en = "Save as WAV…", .ru = "Сохранить в WAV…" };
pub const snd_unused: Msg = .{ .en = "No model animation plays it (scripts and the game itself may).", .ru = "Ни одна анимация моделей его не играет (могут скрипты и сама игра)." };
pub const snd_frame_word: Msg = .{ .en = "frame", .ru = "кадр" };
pub const st_sound_saved: Msg = .{ .en = "Sound written to {s}", .ru = "Звук записан в {s}" };
pub const st_sound_added: Msg = .{ .en = "Sound {s} added", .ru = "Звук {s} добавлен" };
pub const at_media: Msg = .{ .en = "Media", .ru = "Медиа" };
pub const at_videos: Msg = .{ .en = "Videos", .ru = "Видео" };
pub const at_scripts: Msg = .{ .en = "Scripts", .ru = "Скрипты" };
pub const at_rules: Msg = .{ .en = "Rules", .ru = "Правила" };
pub const at_src: Msg = .{ .en = "Project files", .ru = "Файлы проекта" };
pub const rules_none: Msg = .{ .en = "No rule rows name it: the port's defaults (a hero's strike, no resistances)", .ru = "Строк правил для него нет: поведение по умолчанию (удар героя, без сопротивлений)" };
pub const sec_identity: Msg = .{ .en = "Identity", .ru = "Идентичность" };
pub const c_class: Msg = .{ .en = "Class", .ru = "Класс" };
pub const c_script: Msg = .{ .en = "Script", .ru = "Скрипт" };
pub const c_roles: Msg = .{ .en = "Roles", .ru = "Роли" };
pub const roles_note: Msg = .{ .en = "As its files have it: an enemy is a fighter class (.ftr), a hero a .hro; a hero including this class script is both.", .ru = "Как в его файлах: враг — класс бойца (.ftr), герой — .hro; герой, включающий этот скрипт класса, — и то и другое." };
pub const roles_og: Msg = .{ .en = "What it may be (its Character row in rules/fighters.ogs): an enemy (a battle's .ftr includes its class), a hero (a .hro includes it), or both, one class with shared rules. Battles and scripts place it.", .ru = "Кем он может быть (его строка Character в rules/fighters.ogs): враг (.ftr боя включает его класс), герой (его включает .hro) или оба — один класс с общими правилами. В игру его ставят бои и скрипты." };
pub const roles_both: Msg = .{ .en = "Both: a hero includes this class script (the arrow: its other page); rules by class are shared.", .ru = "И то и другое: герой включает этот скрипт класса (стрелка — его другая страница); правила по классу общие." };
pub const sec_strikes: Msg = .{ .en = "Strikes", .ru = "Удары" };
pub const attacks_hero_table: Msg = .{ .en = "Strikes by the hero table (no MonsterAttack rows): the class has no own branch in the exe.", .ru = "Бьёт по таблице героев (нет строк MonsterAttack): у класса нет своей ветки в exe." };
pub const attack_given: Msg = .{ .en = "new (given at battle entry)", .ru = "новая (выдаётся при входе в бой)" };
pub const attack_own: Msg = .{ .en = "own row", .ru = "своя строка" };
pub const attack_game: Msg = .{ .en = "the row in force (an edit writes it by class)", .ru = "строка в силе (правка пишет её по классу)" };
pub const attack_show: Msg = .{ .en = "Show strike", .ru = "Показать удар" };
pub const attack_unshow: Msg = .{ .en = "Hide strike", .ru = "Скрыть удар" };
pub const attack_copy: Msg = .{ .en = "Copy", .ru = "Копировать" };
pub const attack_remove: Msg = .{ .en = "Remove own row", .ru = "Убрать свою строку" };
pub const attack_add: Msg = .{ .en = "New attack", .ru = "Новая атака" };
pub const attack_add_pick: Msg = .{ .en = "an enemy weapon class…", .ru = "класс оружия врага…" };
pub const attacks_note: Msg = .{ .en = "Rows by this class in rules/attacks.ogs (MonsterAttack): a field typed writes the whole row; numbers may be adjust(\"name\", default) + n. A new or copied attack is a weapon the fighter gets at battle entry.", .ru = "Строки этого класса в rules/attacks.ogs (MonsterAttack): введённое поле пишет строку целиком; числа могут быть adjust(\"имя\", умолчание) + n. Новая или скопированная атака — оружие, которое боец получает при входе в бой." };
pub const af_anim: Msg = .{ .en = "Animation slot", .ru = "Слот анимации" };
pub const af_wait: Msg = .{ .en = "Hit at (ticks)", .ru = "Удар через (тики)" };
pub const af_after: Msg = .{ .en = "Wait after", .ru = "Ждать после" };
pub const af_second: Msg = .{ .en = "Second hit after", .ru = "Второй удар через" };
pub const af_react: Msg = .{ .en = "Reaction again after", .ru = "Повтор реакции через" };
pub const af_pre: Msg = .{ .en = "Flash before the hit at", .ru = "Вспышка до удара на" };
pub const af_lift: Msg = .{ .en = "Lift the victim at", .ru = "Подъём жертвы на" };
pub const af_fx: Msg = .{ .en = "All effects of weapon", .ru = "Все эффекты оружия" };
pub const af_flash: Msg = .{ .en = "Flash", .ru = "Вспышка" };
pub const af_launch: Msg = .{ .en = "Projectile", .ru = "Снаряд" };
pub const af_hit: Msg = .{ .en = "Hit effect", .ru = "Попадание" };
pub const af_sound: Msg = .{ .en = "Hit sound", .ru = "Звук попадания" };
pub const af_special: Msg = .{ .en = "Specials of (fighter classic_id)", .ru = "Спецэффекты (classic_id бойца)" };
pub const af_zone: Msg = .{ .en = "Zone (weapon class)", .ru = "Зона (класс оружия)" };
pub const af_damage: Msg = .{ .en = "Damage", .ru = "Урон" };
pub const af_dtype: Msg = .{ .en = "Damage type", .ru = "Тип урона" };
pub const af_recharge: Msg = .{ .en = "Recharge (turns)", .ru = "Перезарядка (ходы)" };
pub const af_range: Msg = .{ .en = "AI range (tiles)", .ru = "Дальность для ИИ (клетки)" };
pub const ai_eval: Msg = .{ .en = "Scoring", .ru = "Оценка" };
pub const og_icons: Msg = .{ .en = "Icons", .ru = "Иконки" };
pub const og_code: Msg = .{ .en = "Code", .ru = "Код" };
pub const og_model: Msg = .{ .en = "Model: {s}", .ru = "Модель: {s}" };
pub const og_glb_look_note: Msg = .{ .en = "The model is its look's: an imported one goes into the look, so every character wearing it changes", .ru = "Модель задана во внешности: импортированная встанет туда же и сменится у всех персонажей с этой внешностью" };
pub const og_strikes: Msg = .{ .en = "Strikes with", .ru = "Бьёт оружием" };
pub const og_any_weapon: Msg = .{ .en = "any other weapon", .ru = "любое другое оружие" };
pub const ai_generic: Msg = .{ .en = "For a generic fighter's ai", .ru = "Для ai общего бойца" };
pub const ai_attack: Msg = .{ .en = "Attack weight", .ru = "Вес атаки" };
pub const ai_defense: Msg = .{ .en = "Threat weight", .ru = "Вес угрозы" };
pub const ai_player: Msg = .{ .en = "Distance weight", .ru = "Вес расстояния" };
pub const ai_guard: Msg = .{ .en = "Guard point weight", .ru = "Вес точки охраны" };
pub const ai_mode: Msg = .{ .en = "Mode", .ru = "Режим" };
pub const ai_bonus: Msg = .{ .en = "Damage bonus", .ru = "Прибавка к урону" };
pub const ai_ally: Msg = .{ .en = "Ally penalty", .ru = "Штраф за союзника" };
pub const ai_lock: Msg = .{ .en = "Locked target ×%", .ru = "Цель AITargetLock ×%" };
pub const ai_monitor: Msg = .{ .en = "Monitor ×", .ru = "Монитор ×" };
pub const ai_pull: Msg = .{ .en = "Decoy pull", .ru = "Притяжение приманки" };
pub const ai_decoys: Msg = .{ .en = "Follows decoys", .ru = "Идёт к приманкам" };
pub const ai_step: Msg = .{ .en = "Steps away after a strike", .ru = "Отходит после удара" };
pub const ai_threat: Msg = .{ .en = "Weighs threat", .ru = "Учитывает угрозу" };
pub const ai_note: Msg = .{ .en = "A row by fighter writes its fields over its classType's; empty: its class's value (attack_weight…mode: the fighter's own ai_*_weight, ai_mode).", .ru = "Строка по бойцу пишет свои поля поверх строки его classType; пусто — значение класса (attack_weight…mode — свои поля бойца ai_*_weight, ai_mode)." };
pub const sec_effects: Msg = .{ .en = "Effects", .ru = "Эффекты" };
pub const lv_blank: Msg = .{ .en = "Make a blank one", .ru = "Создать пустой" };
pub const lv_blank_hint: Msg = .{ .en = "Or from no level: a grey picture of the camera's size, a free grid, one light, the entry area capt_start and a clean script (a battle by an NN__ name). Then paint its picture, depth and grid in the level edit mode.", .ru = "Или без уровня-образца: серая картинка размера камеры, свободная сетка, один свет, зона входа capt_start и чистый скрипт (бой — по имени NN__). Затем нарисуйте картинку, глубину и сетку в режиме правки уровня." };
pub const ef_new: Msg = .{ .en = "New effect", .ru = "Новый эффект" };
pub const ef_new_hint: Msg = .{ .en = "A new effect from scratch: one additive frame (a soft dot) to replace and add to from PNGs; parts name it by its folder (an OpenGorky project's effect descriptions).", .ru = "Новый эффект с нуля: один аддитивный кадр (мягкая точка), его заменяют и дополняют из PNG; части эффектов ссылаются на него по имени папки (описания эффектов проекта OpenGorky)." };
pub const st_effect_new: Msg = .{ .en = "Effect {s} made", .ru = "Эффект {s} создан" };
pub const fxd_title: Msg = .{ .en = "Effect description (rules fx.ss WeaponFx)", .ru = "Описание эффекта (правила fx.ss, WeaponFx)" };
pub const fxd_new: Msg = .{ .en = "New effect (own classic_id)", .ru = "Новый эффект (свой classic_id)" };
pub const fxd_none: Msg = .{ .en = "This stage shows nothing (none).", .ru = "У этой стадии нет эффекта." };
pub const fxd_record: Msg = .{ .en = "Record WeaponFx {d}, stage {s}: an edit writes its row (every weapon striking with it shows it).", .ru = "Запись WeaponFx {d}, стадия {s}: правка пишет её строку (её покажет любое оружие с этим эффектом)." };
pub const fxd_own_title: Msg = .{ .en = "Effect description (rules fx.ss WeaponFx, FighterFx)", .ru = "Описание эффекта (правила fx.ss, WeaponFx, FighterFx)" };
pub const fxd_own_record: Msg = .{ .en = "Record FighterFx {d} with weapon {d} (0: any), stage {s}: an edit writes its row (this fighter's own effects).", .ru = "Запись FighterFx {d} с оружием {d} (0: любое), стадия {s}: правка пишет её строку (свои эффекты этого бойца)." };
pub const fxd_copy: Msg = .{ .en = "Copy from built-in", .ru = "Копия встроенной" };
pub const fxd_copy_pick: Msg = .{ .en = "Record…", .ru = "Запись…" };
pub const fxd_empty: Msg = .{ .en = "No parts in this stage.", .ru = "В этой стадии нет частей." };
pub const fxd_add: Msg = .{ .en = "Add a part", .ru = "Добавить часть" };
pub const fxd_add_pick: Msg = .{ .en = "Kind…", .ru = "Вид…" };
pub const fxd_part: Msg = .{ .en = "Part {d}: {s}", .ru = "Часть {d}: {s}" };
pub const fxd_up: Msg = .{ .en = "Earlier", .ru = "Раньше" };
pub const fxd_down: Msg = .{ .en = "Later", .ru = "Позже" };
pub const fxd_remove: Msg = .{ .en = "Remove", .ru = "Убрать" };
pub const fxd_no_launch: Msg = .{ .en = "No projectile: the hit comes at once.", .ru = "Без снаряда: попадание сразу." };
pub const fxd_launch_add: Msg = .{ .en = "Add a projectile", .ru = "Добавить снаряд" };
// Materials (fxmaterial.zig) and the post-processing page (postpage.zig).
pub const mat_title: Msg = .{ .en = "Materials (rules fx.ss Material)", .ru = "Материалы (правила fx.ss, Material)" };
pub const mat_hint: Msg = .{ .en = "A part names one (its material, picked under the part's fields above); the preview draws it at once. CPU only: program and k run on the battle layer and in this preview; the screen pass (off the battle layer) takes only colour, alpha and blend, a dissolve fades by k there.", .ru = "Часть называет материал (поле material под полями части выше); просмотр сразу рисует его. Только CPU: program и k работают в слое боя и в этом просмотре; экранный проход (вне слоя боя) берёт только цвет, прозрачность и смешивание, dissolve там гаснет по k." };
pub const mat_empty: Msg = .{ .en = "No materials yet.", .ru = "Материалов пока нет." };
pub const mat_add: Msg = .{ .en = "New material", .ru = "Новый материал" };
pub const mat_delete: Msg = .{ .en = "Delete", .ru = "Удалить" };
pub const mat_shown: Msg = .{ .en = "Material {s}", .ru = "Материал {s}" };
pub const mat_users: Msg = .{ .en = "Used by", .ru = "Используют" };
pub const mat_unused: Msg = .{ .en = "no part (pick it under a part's fields to see it in the preview)", .ru = "ни одна часть (выберите его в полях части, чтобы увидеть в просмотре)" };
pub const mat_none: Msg = .{ .en = "none", .ru = "нет" };
pub const st_mat_used: Msg = .{ .en = "Material {s} is named by {d} part(s) ({s}…): pick another one on them first", .ru = "Материал {s} называют частей: {d} ({s}…): сначала выберите им другой" };
pub const post_title: Msg = .{ .en = "Post-processing", .ru = "Постобработка" };
pub const post_hint: Msg = .{ .en = "The frame's steps over the drawn world, in order (rules fx.ss PostChain; CPU)", .ru = "Шаги над нарисованным миром кадра, по порядку (правила fx.ss, PostChain; CPU)" };
pub const post_sec: Msg = .{ .en = "Steps", .ru = "Шаги" };
pub const post_preview: Msg = .{ .en = "Preview", .ru = "Просмотр" };
pub const post_empty: Msg = .{ .en = "No steps: the frame as drawn.", .ru = "Шагов нет: кадр как нарисован." };
pub const post_add: Msg = .{ .en = "+ {s}", .ru = "+ {s}" };
pub const post_step: Msg = .{ .en = "Step {d}: {s}", .ru = "Шаг {d}: {s}" };
pub const post_grade: Msg = .{ .en = "grade: colour ×rgb, then saturation ×k (0 grey, 1 as it is).", .ru = "grade: цвет ×rgb, затем насыщенность ×k (0 серый, 1 как есть)." };
pub const post_vignette: Msg = .{ .en = "vignette: darker by k toward the corners.", .ru = "vignette: темнее на k к углам." };
pub const post_scanlines: Msg = .{ .en = "scanlines: every other screen line darker by k.", .ru = "scanlines: каждая вторая строка экрана темнее на k." };
pub const post_before: Msg = .{ .en = "Before", .ru = "До" };
pub const post_after: Msg = .{ .en = "After", .ru = "После" };
pub const post_no_level: Msg = .{ .en = "Open a location or a battle: its background is the preview's picture.", .ru = "Откройте локацию или бой: её фон станет картинкой просмотра." };
pub const post_still: Msg = .{ .en = "The background of {s}; the steps run again only when they change.", .ru = "Фон {s}; шаги считаются заново, только когда меняются." };
pub const post_for: Msg = .{ .en = "Chain", .ru = "Цепочка" };
pub const post_global: Msg = .{ .en = "Global", .ru = "Общая" };
pub const post_global_hint: Msg = .{ .en = "every location without its own", .ru = "все локации без своей" };
pub const post_shared: Msg = .{ .en = "shared", .ru = "общая" };
pub const post_own: Msg = .{ .en = "own (steps: {d})", .ru = "своя (шагов: {d})" };
pub const post_shared_note: Msg = .{ .en = "{s} uses the global chain: an edit here makes it its own.", .ru = "{s} использует общую цепочку: правка здесь сделает её своей." };
pub const post_loc_note: Msg = .{ .en = "{s} uses the chain of {s}, whose scripts start it: an edit here makes it its own.", .ru = "{s} использует цепочку {s} — её скрипты запускают этот бой: правка здесь сделает её своей." };
pub const post_level_hint: Msg = .{ .en = "Own: a copy of the global chain for this location only, edited on the post-processing page (the arrow); shared: the global one.", .ru = "Своя: копия общей цепочки только для этой локации, правится на странице постобработки (стрелка); общая: как у всех." };
pub const post_own_btn: Msg = .{ .en = "Own", .ru = "Своя" };
pub const post_shared_btn: Msg = .{ .en = "Shared", .ru = "Общая" };
pub const post_as_loc: Msg = .{ .en = "as {s}", .ru = "как у {s}" };
pub const post_as_loc_btn: Msg = .{ .en = "As location", .ru = "Как у локации" };
pub const post_battle_hint: Msg = .{ .en = "The scripts of {s} start this battle{s}: without its own chain the battle takes that location's, else the global one; own: a copy of that, edited on the post-processing page (the arrow).", .ru = "Этот бой запускают скрипты {s}{s}: без своей цепочки бой берёт цепочку этой локации, а если у неё нет своей — общую; своя: копия этой, правится на странице постобработки (стрелка)." };
pub const post_battle_more: Msg = .{ .en = " (also {s}: the first by name counts)", .ru = " (а также {s}: берётся первая по имени)" };
pub const post_battle_none: Msg = .{ .en = "No location's scripts start this battle: without its own chain it takes the global one; own: a copy of that, edited on the post-processing page (the arrow).", .ru = "Этот бой не запускают скрипты ни одной локации: без своей цепочки он берёт общую; своя: копия общей, правится на странице постобработки (стрелка)." };
pub const st_fx_set: Msg = .{ .en = "Effect description {d} written (rules/fx.ogs)", .ru = "Описание эффекта {d} записано (rules/fx.ogs)" };
pub const fx_same: Msg = .{ .en = "as the weapon", .ru = "как у оружия" };
pub const fx_none: Msg = .{ .en = "none", .ru = "нет" };
pub const fx_sound_hint: Msg = .{ .en = "the game's (WeaponSound)", .ru = "как в игре (WeaponSound)" };
pub const fx_note: Msg = .{ .en = "The weapon's fields effects_from, flash_from, launch_from, hit_from, hit_sound: each stage is a game weapon's effect, whoever strikes with it.", .ru = "Поля оружия effects_from, flash_from, launch_from, hit_from, hit_sound: каждая стадия — эффект оружия игры, кто бы им ни бил." };
pub const sec_bonuses: Msg = .{ .en = "Character bonuses", .ru = "Бонусы персонажей" };
pub const bn_heal: Msg = .{ .en = "Healing bonus, %", .ru = "Бонус лечения, %" };
pub const bn_hit: Msg = .{ .en = "Hit chance bonus, points", .ru = "Бонус к шансу попадания, очков" };
pub const bn_damage: Msg = .{ .en = "Damage bonus, %", .ru = "Бонус урона, %" };
pub const bn_walk: Msg = .{ .en = "Walk range bonus, tiles", .ru = "Бонус дальности хода, клеток" };
pub const bonus_note: Msg = .{ .en = "Rules items.ss HealBonus row by class: the medicine it uses heals floor(hp × pct / 100) more; not 0 shows \"special skill: healing +pct%\" in its stats window. In battle: hit adds to its hit chance, damage adds that percent to its hits' damage, walk adds tiles to its walk range (0: as the exe).", .ru = "Строка HealBonus в правилах items.ss по классу: применённое им лекарство лечит на floor(hp × pct / 100) больше; не 0 — в окне характеристик строка «особое умение: лечение +pct%». В бою: hit прибавляется к шансу попадания, damage — процент к урону его ударов, walk — клетки к дальности хода (0 — как в exe)." };
pub const sec_party: Msg = .{ .en = "Party", .ru = "Отряд" };
pub const party_rows: Msg = .{ .en = "Party size and idle lines", .ru = "Размер отряда и реплики простоя" };
pub const pr_max: Msg = .{ .en = "Party at most", .ru = "Отряд не больше" };
pub const pr_dialog: Msg = .{ .en = "Idle line (dialog)", .ru = "Реплика простоя (диалог)" };
pub const pr_anim: Msg = .{ .en = "Idle animation", .ru = "Анимация простоя" };
pub const party_note: Msg = .{ .en = "party_max: rules party.ss Value (the exe's 6, the port holds 12; the panel shows its slots); the idle line: this hero's IdleChatter row by class.", .ru = "party_max — Value в правилах party.ss (в exe 6, порт держит 12; панель показывает свои слоты); реплика — строка IdleChatter этого героя по классу." };
pub const st_rule_set: Msg = .{ .en = "Rule {s} of {s} written; saved with Ctrl+S", .ru = "Правило {s} для {s} записано; сохраняется по Ctrl+S" };
pub const st_rule_bad: Msg = .{ .en = "{s}: not a value ({s})", .ru = "{s}: не значение ({s})" };
pub const st_attack_added: Msg = .{ .en = "Attack {s} given to {s} (rules attacks.ss)", .ru = "Атака {s} выдана {s} (правила attacks.ss)" };
pub const st_attack_removed: Msg = .{ .en = "Own row of {s} for {s} removed", .ru = "Своя строка {s} у {s} убрана" };
pub const af_vanish: Msg = .{ .en = "Fade out after", .ru = "Исчезнуть через" };
pub const af_lift_release: Msg = .{ .en = "Drop the victim after", .ru = "Бросить жертву через" };
pub const af_gas: Msg = .{ .en = "Gas around the aimed tile", .ru = "Газ вокруг клетки прицела" };
pub const af_linked: Msg = .{ .en = "Linked actor's animation", .ru = "Анимация связанного актёра" };
pub const sec_hero_strikes: Msg = .{ .en = "Hero strikes", .ru = "Удары героев" };
pub const hs_anyone: Msg = .{ .en = "anyone", .ru = "любой" };
pub const hs_who: Msg = .{ .en = "Who strikes", .ru = "Кто бьёт" };
pub const hs_card: Msg = .{ .en = "{s} · {s}", .ru = "{s} · {s}" };
pub const hs_default: Msg = .{ .en = "the row of every other weapon: an edit writes this weapon's own", .ru = "строка любого другого оружия: правка пишет собственную строку этого" };
pub const hs_extra: Msg = .{ .en = "Extra (slower strikes)", .ru = "Добавка (медленные удары)" };
pub const hs_until: Msg = .{ .en = "Hit after the animation ends", .ru = "Попадание после конца анимации" };
pub const hs_then: Msg = .{ .en = "Then animation", .ru = "Затем анимация" };
pub const hs_add: Msg = .{ .en = "Row for a hero", .ru = "Строка для героя" };
pub const hs_add_pick: Msg = .{ .en = "a hero…", .ru = "герой…" };
pub const hs_wins: Msg = .{ .en = "the weapon's own {s} = {s} wins over this", .ru = "собственное поле оружия {s} = {s} важнее этого" };
pub const hs_note: Msg = .{ .en = "Rules attacks.ss HeroAttack rows of this weapon (by class; who: anyone or one hero's row, it wins). A field typed writes the whole row; numbers may be adjust(\"name\", default) + n.", .ru = "Строки HeroAttack этого оружия в правилах attacks.ss (по классу; кто: любой или строка одного героя, она важнее). Введённое поле пишет строку целиком; числа могут быть adjust(\"имя\", умолчание) + n." };
pub const wc_title: Msg = .{ .en = "Class {d} properties (WeaponClass)", .ru = "Свойства класса {d} (WeaponClass)" };
pub const wc_rolls: Msg = .{ .en = "Rolls to hit (firearm)", .ru = "Бросок на попадание (огнестрел)" };
pub const wc_ignites: Msg = .{ .en = "Ignites a soaked target", .ru = "Поджигает облитую цель" };
pub const wc_shared: Msg = .{ .en = "Changes every weapon of class {d}: {s}", .ru = "Меняет всё оружие класса {d}: {s}" };
pub const wf_title: Msg = .{ .en = "Battle code flags (WeaponFlags)", .ru = "Флаги боевого кода (WeaponFlags)" };
pub const wf_no_counter: Msg = .{ .en = "No counter roll", .ru = "Без контратаки" };
pub const wf_shock: Msg = .{ .en = "Shock", .ru = "Ток" };
pub const wf_sparks: Msg = .{ .en = "Sparks", .ru = "Искры" };
pub const wf_silent: Msg = .{ .en = "Silent frames", .ru = "Тихие кадры" };
pub const c_skill_icon: Msg = .{ .en = "Skills window icon", .ru = "Значок в окне навыков" };
pub const skill_none: Msg = .{ .en = "none: the weapon isn't listed in the skills window", .ru = "нет: оружия нет в окне навыков" };
pub const c_weapon_sound: Msg = .{ .en = "Hit sound (WeaponSound)", .ru = "Звук попадания (WeaponSound)" };
pub const ws_wins: Msg = .{ .en = "the weapon's hit sound above wins over this", .ru = "звук попадания оружия выше важнее этого" };
pub const r_armor: Msg = .{ .en = "Armour class", .ru = "Класс брони" };
pub const r_armor_none: Msg = .{ .en = "none", .ru = "нет" };
pub const r_armor_light: Msg = .{ .en = "light", .ru = "лёгкая" };
pub const r_armor_medium: Msg = .{ .en = "medium", .ru = "средняя" };
pub const r_armor_heavy: Msg = .{ .en = "heavy", .ru = "тяжёлая" };
pub const sec_hero_rules: Msg = .{ .en = "Battle rules", .ru = "Правила боя" };
pub const hr_wdelay: Msg = .{ .en = "Slower strikes (HeroAttack extra applies)", .ru = "Медленные удары (действует добавка HeroAttack)" };
pub const hr_hidden: Msg = .{ .en = "Can't take in hand (HiddenWeapons)", .ru = "Не берёт в руку (HiddenWeapons)" };
pub const hr_note: Msg = .{ .en = "Rules attacks.ss WdelayHero and party.ss HiddenWeapons rows by its class.", .ru = "Строки WdelayHero (attacks.ss) и HiddenWeapons (party.ss) по его классу." };
pub const sec_medicine: Msg = .{ .en = "Medicine", .ru = "Лекарство" };
pub const med_kind: Msg = .{ .en = "Effect", .ru = "Действие" };
pub const med_random: Msg = .{ .en = "Acts as one of (at random)", .ru = "Действует как одно из (случайно)" };
pub const med_note: Msg = .{ .en = "Rules items.ss Medicine row by its class; with items ticked it acts as one of them (rand & 3: the first four).", .ru = "Строка Medicine в правилах items.ss по классу; с отмеченными предметами действует как один из них (rand & 3: первые четыре)." };
pub const rules_values: Msg = .{ .en = "Its rules", .ru = "Его правила" };
pub const rules_shared: Msg = .{ .en = "shared", .ru = "общие" };
pub const rules_own: Msg = .{ .en = "own", .ru = "свои" };
pub const rules_share_note: Msg = .{ .en = "Shared: the rows by classic_id {d} (also: {s}). Own: copied by its class {s}, changed for it alone; a field edited here forks its row by itself.", .ru = "Общие: строки по classic_id {d} (также: {s}). Свои: копия по классу {s}, меняется только у него; поле, изменённое здесь, само становится своим." };
pub const sum_own_rows: Msg = .{ .en = "own {d} · shared {d}", .ru = "своих {d} · общих {d}" };
pub const st_rules_keep_own: Msg = .{ .en = "{s} keeps its own rows: remove them in the rules code (a row opens it) to share again", .ru = "У {s} остаются свои строки: чтобы снова стали общими, удалите их в коде правил (строка открывает его)" };
pub const st_rules_own: Msg = .{ .en = "Own rules of {s} written to the rules files; saved with Ctrl+S", .ru = "Свои правила {s} записаны в файлы правил; сохраняются по Ctrl+S" };
pub const nameid_new: Msg = .{ .en = "+ new text (free number {d})", .ru = "+ новый текст (свободный номер {d})" };
pub const c_same_as: Msg = .{ .en = "One thing with", .ru = "Одно целое с" };
pub const c_same_as_none: Msg = .{ .en = "none: a block's path (characters::nato) or \"level/name\"", .ru = "нет — путь блока (characters::nato) или \"уровень/имя\"" };
pub const same_as_with: Msg = .{ .en = "One thing with it (shared name, texts and rules): {s}", .ru = "С ним одно целое (общие имя, тексты и правила): {s}" };
pub const hint_copy_og: Msg = .{ .en = "Its own classic_id {d}, only for its texts. Its rules are its class's, cloned from the original's (the Rules section; its special effects too, MonsterAttack special): change them freely, the original keeps its own. A victim's lift pose and the rest the Rules don't list stay the port's code by classic_id", .ru = "Свой classic_id {d}, только для текстов. Правила — по его классу, скопированы с оригинала (секция «Правила»; спецэффекты тоже — поле special у MonsterAttack): меняйте свободно, у оригинала свои. Поза поднятой жертвы и прочее, чего нет в правилах, — код порта по classic_id" };
pub const sc_new_script: Msg = .{ .en = "New script", .ru = "Новый скрипт" };
pub const st_script_added: Msg = .{ .en = "Script {s} made: #include {s} in a level or class script takes it in", .ru = "Скрипт {s} создан: #include {s} в скрипте уровня или класса подключает его" };
pub const vid_import: Msg = .{ .en = "Import a video…", .ru = "Импорт видео…" };
pub const vid_import_hint: Msg = .{ .en = "Any video goes into avi/ as the game's own are: ASF, MS-MPEG4 v3, 15 fps, WMA v1 44100 Hz stereo (converted by ffmpeg), so the original plays it too; an OpenGorky project keeps a video the port plays as it is (mp4, mkv, webm, mov… up to 4K). It is written into avi/ on Save (undoable).", .ru = "Любое видео попадает в avi/ в формате роликов игры: ASF, MS-MPEG4 v3, 15 кадров/с, WMA v1 44100 Гц стерео (перекодирует ffmpeg), так что его играет и оригинал; проект OpenGorky оставляет видео, которое играет порт, как есть (mp4, mkv, webm, mov… до 4K). Записывается в avi/ при сохранении (можно отменить)." };
pub const vid_call: Msg = .{ .en = "In a script (x, y on the screen, 1: may be skipped):", .ru = "В скрипте (x, y на экране, 1 — можно пропустить):" };
pub const vid_size: Msg = .{ .en = "{d} KB", .ru = "{d} КБ" };
pub const vid_unused: Msg = .{ .en = "No level or scene script plays it (the game itself may: intro, logos).", .ru = "Его не играет ни один скрипт уровня или сценки (может сама игра: заставка, логотипы)." };
pub const vid_replace: Msg = .{ .en = "Replace with a file…", .ru = "Заменить файлом…" };
pub const vid_replace_hint: Msg = .{ .en = "The file takes this video's place under its name (the scripts and the original exe find it so): converted to the game's ASF (640×480 at most, 15 fps, MS-MPEG4 v3, WMA) for the original; an OpenGorky project keeps a video the port plays as it is. Written on Save (undoable).", .ru = "Файл встаёт на место этого видео под его именем (так его находят скрипты и оригинальный exe): перекодируется в ASF игры (не больше 640×480, 15 кадров/с, MS-MPEG4 v3, WMA) для оригинала; проект OpenGorky оставляет видео, которое играет порт, как есть. Записывается при сохранении (можно отменить)." };
pub const st_video_replaced: Msg = .{ .en = "Video {s} replaced (into avi/ on Save)", .ru = "Видео {s} заменено (в avi/ при сохранении)" };
pub const st_video_added: Msg = .{ .en = "Video {s} added (into avi/ on Save)", .ru = "Видео {s} добавлено (в avi/ при сохранении)" };
pub const st_converting: Msg = .{ .en = "Converting {s}… {d}%", .ru = "Перекодируется {s}… {d}%" };
pub const st_video_failed: Msg = .{ .en = "Not converted: {t}", .ru = "Не перекодировано: {t}" };
pub const atk_info: Msg = .{ .en = "Strike: {s}, the hit at tick {d} · {s}", .ru = "Удар: {s}, попадание на тике {d} · {s}" };
pub const atk_two: Msg = .{ .en = "two-handed", .ru = "двуручное" };
pub const atk_one: Msg = .{ .en = "one-handed", .ru = "одноручное" };
pub const atk_who: Msg = .{ .en = "Who strikes", .ru = "Кто бьёт" };
pub const atk_hint: Msg = .{ .en = "Drag the model to turn and tilt it, wheel to zoom, right or middle drag to move; who strikes is picked below on the left.", .ru = "Тяните модель мышью, чтобы повернуть и наклонить, колесо — масштаб, правая или средняя кнопка — сдвиг; кто бьёт — слева внизу." };
pub const reach_show: Msg = .{ .en = "show the damage zone", .ru = "показать зону поражения" };
pub const reach_hide: Msg = .{ .en = "hide the damage zone", .ru = "скрыть зону поражения" };
pub const view_model: Msg = .{ .en = "Model", .ru = "Модель" };
pub const view_zone: Msg = .{ .en = "Damage zone", .ru = "Зона поражения" };
pub const view_strike: Msg = .{ .en = "Strike", .ru = "Удар" };
pub const atk_by: Msg = .{ .en = "{s} strikes with it ({s}): its first fighter holding it", .ru = "Бьёт {s} ({s}): первый боец, у которого оно есть" };
pub const atk_nobody: Msg = .{ .en = "No enemy strikes with it: its damage zone only", .ru = "Им не бьёт ни один враг: только зона поражения" };
pub const inv_stage: Msg = .{ .en = "As the inventory shows it", .ru = "Так его показывает инвентарь" };
pub const look_new_note_item: Msg = .{ .en = "A copy of the model wearing a PNG, or a model from .glb: this item takes it, the model and textures above stay as they are. They are edited on their own pages (the arrow buttons).", .ru = "Копия модели с текстурой из PNG или модель из .glb: её получает этот предмет, модель и текстуры выше не меняются. Сами они правятся на своих страницах (кнопки со стрелкой)." };
pub const reach_title: Msg = .{ .en = "Damage zone · {s}", .ru = "Зона поражения · {s}" };
pub const reach_hint: Msg = .{ .en = "The exe's pattern for this classType (read only; follows the class picked). Number — damage percent at the tile.{s}{s}", .ru = "Шаблон exe для этого classType (только чтение; следует за выбранным классом). Число — процент урона на клетке.{s}{s}" };
pub const reach_wide: Msg = .{ .en = " The ray is two tiles wide (2×2 fighters).", .ru = " Луч шириной в две клетки (бойцы 2×2)." };
pub const reach_sets: Msg = .{ .en = " Under it — the hit area the tile strikes with.", .ru = " Под ним — область поражения, которой бьёт клетка." };
pub const reach_area: Msg = .{ .en = "Hit area {d}: {d} tiles", .ru = "Область поражения {d}: {d} клеток" };
pub const reach_single: Msg = .{ .en = "Hit area {d}: the target tile only", .ru = "Область поражения {d}: только клетка цели" };
pub const zl_shooter: Msg = .{ .en = "the shooter", .ru = "стреляющий" };
pub const zl_start: Msg = .{ .en = "first tile of a ray", .ru = "первая клетка луча" };
pub const zl_chain: Msg = .{ .en = "along a ray: cut by an obstacle before", .ru = "дальше по лучу: обрывается препятствием" };
pub const zl_side: Msg = .{ .en = "second tile of a wide ray", .ru = "вторая клетка широкого луча" };
pub const zl_target: Msg = .{ .en = "the target tile", .ru = "клетка цели" };
pub const zl_hit: Msg = .{ .en = "tile the hit covers", .ru = "клетка, накрытая попаданием" };
pub const reach_none: Msg = .{ .en = "No pattern for this classType in the exe.", .ru = "Для этого classType в exe шаблона нет." };
pub const reach_satellite: Msg = .{ .en = "Any open tile of the field, 100 %; the hit covers 7×7 around it.", .ru = "Любая свободная клетка поля, 100 %; попадание накрывает 7×7 вокруг." };
pub const reach_bomb: Msg = .{ .en = "Put on a free tile next to the hero (below, above, right, left).", .ru = "Ставится на свободную клетку рядом с героем (снизу, сверху, справа, слева)." };
pub const zn_hint: Msg = .{ .en = "Click a tile to pick it; its settings are beside the grid. Every weapon of this classType strikes so.", .ru = "Щелчок по клетке выбирает её; её настройки — рядом с сеткой. Так бьёт всё оружие этого classType." };
pub const zn_axes: Msg = .{ .en = "Forward is every way: +x is right, +y is down on the battle grid, whichever way the shooter faces; each way is a ray of its own.", .ru = "Вперёд — во все стороны: +x вправо, +y вниз по полю боя, куда бы ни смотрел стреляющий; у каждого направления свой луч." };
pub const zn_wide: Msg = .{ .en = "Two tiles wide (2×2 fighters)", .ru = "В две клетки шириной (бойцы 2×2)" };
pub const zn_pick: Msg = .{ .en = "Pick a tile on the grid to put it in the zone or take it out and to set its kind, hit area and damage.", .ru = "Выберите клетку на сетке, чтобы включить её в зону или убрать и задать её вид, область поражения и урон." };
pub const zn_in: Msg = .{ .en = "In the zone", .ru = "В зоне" };
pub const zn_in_note: Msg = .{ .en = "Not struck. Put in, a tile next to a ray's, farther from the shooter, continues that ray; else it starts a new one.", .ru = "Не поражается. Включённая клетка рядом с клеткой луча, дальше от стреляющего, продолжает этот луч, иначе начинает новый." };
pub const zn_tile_out: Msg = .{ .en = "Tile {d}, {d}", .ru = "Клетка {d}, {d}" };
pub const zn_tile: Msg = .{ .en = "Tile {d}, {d} · entry {d} of {d}", .ru = "Клетка {d}, {d} · запись {d} из {d}" };
pub const zn_kind: Msg = .{ .en = "Kind", .ru = "Вид" };
pub const zn_start: Msg = .{ .en = "ray start (s)", .ru = "начало луча (s)" };
pub const zn_chain: Msg = .{ .en = "continues (c)", .ru = "продолжение (c)" };
pub const zn_side: Msg = .{ .en = "Second tile", .ru = "Вторая клетка" };
pub const zn_side_x: Msg = .{ .en = "right (x)", .ru = "справа (x)" };
pub const zn_side_y: Msg = .{ .en = "below (y)", .ru = "снизу (y)" };
pub const zn_side_none: Msg = .{ .en = "none set: the exe strikes the tile twice", .ru = "не задана: exe бьёт клетку дважды" };
pub const zn_side_note: Msg = .{ .en = "from this ray on, until the next ray that sets it", .ru = "с этого луча и дальше, до луча, задающего свою" };
pub const zn_set: Msg = .{ .en = "Hit area", .ru = "Область поражения" };
pub const zn_pct: Msg = .{ .en = "Damage, %: {d}", .ru = "Урон, %: {d}" };
pub const zn_sets: Msg = .{ .en = "Hit areas: the tiles a hit covers around the target (red); a click puts a tile in or out.", .ru = "Области поражения: клетки вокруг цели (красная), которые накрывает попадание; щелчок включает клетку или убирает." };
pub const st_zn_rays: Msg = .{ .en = "Not changed: at most {d} aimed tiles (a wide ray's count twice) and {d} entries", .ru = "Не изменено: не больше {d} клеток прицела (у широкого луча — по две) и {d} записей" };
pub const st_zn_pct: Msg = .{ .en = "Not changed: damage at most {d} % a tile", .ru = "Не изменено: урон не больше {d} % на клетку" };
pub const st_zn_hits: Msg = .{ .en = "Not changed: at most {d} tiles in a hit area", .ru = "Не изменено: не больше {d} клеток в области поражения" };
pub const orphans: Msg = .{ .en = "Files of fighters nobody places: {s}. The original brings them into the battle at the corner and crashes.", .ru = "Файлы бойцов, которых никто не ставит: {s}. Оригинал выведет их в бой в угол и упадёт." };
pub const orphans_drop: Msg = .{ .en = "Delete their files", .ru = "Удалить их файлы" };
pub const st_referenced: Msg = .{ .en = "{s} stays: {s} names it — remove that first (Open the script)", .ru = "{s} не убран: на него ссылается {s} — сначала уберите ссылку (Открыть скрипт)" };
pub const code_help: Msg = .{ .en = "Functions (F1)", .ru = "Функции (F1)" };
pub const code_help_count: Msg = .{ .en = "{d} functions the game runs; matching the call or word at the cursor. A click inserts one with sample values.", .ru = "Функций, которые выполняет игра: {d}; показаны подходящие к вызову или слову у курсора. Клик вставляет вызов с примерами значений." };
pub const code_help_none: Msg = .{ .en = "No function matches.", .ru = "Подходящих функций нет." };
pub const code_help_ref: Msg = .{ .en = "Open in reference", .ru = "Открыть в справке" };
pub const ref_title: Msg = .{ .en = "Reference", .ru = "Справка" };
pub const ref_hint: Msg = .{ .en = "Script functions, engine callbacks, OpenGorky hooks, rules calls and engine settings — the code editor's hints in full. F1 opens it from anywhere; in the code, F1 on a known word opens its article.", .ru = "Функции скриптов, вызовы движка, хуки OpenGorky, вызовы правил и настройки движка — подсказки редактора кода целиком. F1 открывает её отовсюду; в коде F1 на известном слове открывает его статью." };
pub const ref_search: Msg = .{ .en = "Search names and descriptions", .ru = "Поиск по именам и описаниям" };
pub const ref_found: Msg = .{ .en = "Found: {d}", .ru = "Найдено: {d}" };
pub const ref_nothing: Msg = .{ .en = "Nothing matches.", .ru = "Ничего не найдено." };
pub const ref_pick: Msg = .{ .en = "Pick an article on the left.", .ru = "Выберите статью слева." };
pub const ref_s_builtins: Msg = .{ .en = "Script functions", .ru = "Функции скриптов" };
pub const ref_s_callbacks: Msg = .{ .en = "Engine callbacks", .ru = "Вызовы движка" };
pub const ref_s_hooks: Msg = .{ .en = "OpenGorky hooks", .ru = "Хуки OpenGorky" };
pub const ref_s_rules: Msg = .{ .en = "Rules calls", .ru = "Вызовы правил" };
pub const tip_block_rest: Msg = .{ .en = "  not set here (its kind's defaults; Ctrl+Space at a line's start in the block offers them): {s}", .ru = "  не заданы (умолчания вида; Ctrl+Space в начале строки блока предложит их): {s}" };
pub const ref_s_blocks: Msg = .{ .en = "Block kinds", .ru = "Виды блоков" };
pub const ref_block_desc: Msg = .{ .en = "A data block kind of OG Script: the fields a block of it sets, with their types, defaults and meaning (foundation/hosts.ogs). A field the block does not set keeps its default.", .ru = "Вид блока данных OG Script: поля, которые задаёт такой блок, их типы, умолчания и смысл (foundation/hosts.ogs). Поле, которое блок не задаёт, берёт умолчание." };
pub const ref_block_from: Msg = .{ .en = "from host {s}", .ru = "из host {s}" };
pub const ref_s_settings: Msg = .{ .en = "Engine settings", .ru = "Настройки движка" };
// The script functions' groups: OG Script's packages (refdata.groups).
pub const ref_g_object: Msg = .{ .en = "object — objects by name", .ru = "object — объекты по имени" };
pub const ref_g_sound: Msg = .{ .en = "sound — sounds", .ru = "sound — звуки" };
pub const ref_g_actor: Msg = .{ .en = "actor — actors: model, commands, links", .ru = "actor — актёры: модель, команды, связи" };
pub const ref_g_path: Msg = .{ .en = "path — the actor of a path script", .ru = "path — актёр скрипта пути" };
pub const ref_g_level: Msg = .{ .en = "level — the level", .ru = "level — уровень" };
pub const ref_g_hero: Msg = .{ .en = "hero — the party", .ru = "hero — отряд" };
pub const ref_g_scene: Msg = .{ .en = "scene — scenes, dialogues, video", .ru = "scene — сцены, диалоги, видео" };
pub const ref_g_gui: Msg = .{ .en = "gui — interface modes", .ru = "gui — режимы интерфейса" };
pub const ref_g_item: Msg = .{ .en = "item — items and weapons", .ru = "item — предметы и оружие" };
pub const ref_g_battle: Msg = .{ .en = "battle — the battle", .ru = "battle — бой" };
pub const ref_g_fighter: Msg = .{ .en = "fighter — one fighter", .ru = "fighter — один боец" };
pub const ref_g_events: Msg = .{ .en = "events — events between components", .ru = "events — события между компонентами" };
pub const ref_g_core: Msg = .{ .en = "Core (no package), Classic only", .ru = "Ядро (без пакета), только Classic" };
pub const ref_ogs_name: Msg = .{ .en = "OG Script: {s}", .ru = "OG Script: {s}" };
pub const ref_ogs_none: Msg = .{ .en = "OG Script: none (Classic only)", .ru = "OG Script: нет (только Classic)" };
pub const ref_classic_name: Msg = .{ .en = "Classic: {s}", .ru = "Classic: {s}" };
pub const ref_params: Msg = .{ .en = "Parameters", .ru = "Параметры" };
pub const ref_fields: Msg = .{ .en = "Fields", .ru = "Поля" };
pub const ref_no_params: Msg = .{ .en = "No parameters.", .ru = "Без параметров." };
pub const ref_c_name: Msg = .{ .en = "Name", .ru = "Имя" };
pub const ref_c_type: Msg = .{ .en = "Type", .ru = "Тип" };
pub const ref_c_default: Msg = .{ .en = "Default", .ru = "По умолчанию" };
pub const ref_c_meaning: Msg = .{ .en = "Meaning", .ru = "Значение" };
pub const ref_required: Msg = .{ .en = "required", .ru = "обязателен" };
pub const ref_optional: Msg = .{ .en = "optional", .ru = "необязателен" };
pub const ref_sample: Msg = .{ .en = "e.g. {s}", .ru = "например, {s}" };
pub const ref_examples: Msg = .{ .en = "Examples from the game", .ru = "Примеры из игры" };
pub const ref_examples_none: Msg = .{ .en = "The game's scripts and rules don't use it.", .ru = "В скриптах и правилах игры не встречается." };
pub const ref_examples_note: Msg = .{ .en = "A click opens the line in the code editor, in a tab of its own.", .ru = "Клик открывает строку в редакторе кода, в отдельной вкладке." };
pub const ref_related: Msg = .{ .en = "Related", .ru = "Связанное" };
pub const ref_hook_order: Msg = .{ .en = "The engine calls a hook only in an OpenGorky project and only when it is defined. The current level's script (its .lev) may define it too: its function runs first, then the one of src/game.ogs. OnDamage, OnResist: the level's result comes to hooks.ss as `amount`; OnItemUse: the level's 1 ends it; the others: both run. GetLevel() is the current level's name, GetClass(name) an object's class.", .ru = "Движок вызывает хук только в проекте OpenGorky и только если он определён. Скрипт текущего уровня (его .lev) тоже может его определить: сначала выполняется его функция, затем функция из src/game.ogs. OnDamage, OnResist: результат уровня приходит в hooks.ss как `amount`; OnItemUse: 1 от уровня завершает обработку; у остальных выполняются обе. GetLevel() — имя текущего уровня, GetClass(name) — класс объекта." };
pub const ref_hook_how: Msg = .{ .en = "How hooks run", .ru = "Как вызываются хуки" };
pub const ref_setting_forms: Msg = .{ .en = "Where it is set", .ru = "Где задаётся" };
pub const ref_setting_classic: Msg = .{ .en = "Classic: a line of adjust.kdt in the game folder (the original exe reads it too).", .ru = "Classic: строка adjust.kdt в папке игры (её читает и оригинальный exe)." };
pub const ref_setting_og: Msg = .{ .en = "OpenGorky: a Setting row of rules/settings.ogs (the port's only source).", .ru = "OpenGorky: строка Setting в rules/settings.ogs (единственный источник для порта)." };
pub const ref_setting_now: Msg = .{ .en = "In this project: {s} = {s}", .ru = "В этом проекте: {s} = {s}" };
pub const ref_setting_open: Msg = .{ .en = "Open in Engine settings", .ru = "Открыть в настройках движка" };
pub const code_pos: Msg = .{ .en = "line {d}, column {d}", .ru = "строка {d}, столбец {d}" };
pub const code_open: Msg = .{ .en = "Open the script", .ru = "Открыть скрипт" };
pub const code_level: Msg = .{ .en = "Level script", .ru = "Скрипт уровня" };
pub const code_in_editor: Msg = .{ .en = "In the editor", .ru = "В редакторе" };
pub const st_code_applied: Msg = .{ .en = "{s}: applied (Ctrl+S in the main window saves it into the game)", .ru = "{s}: применено (Ctrl+S в главном окне — сохранить в игру)" };
pub const code_error: Msg = .{ .en = "error in line {d}: {s}", .ru = "ошибка в строке {d}: {s}" };
pub const code_error_force: Msg = .{ .en = "error in line {d}: {s} — Apply again to apply as it is", .ru = "ошибка в строке {d}: {s} — «Применить» ещё раз применит как есть" };
pub const st_code_stale: Msg = .{ .en = "{s} was changed elsewhere since this tab's edits began. Apply again to put this text over it", .ru = "{s} изменён в другом месте после начала правок во вкладке. «Применить» ещё раз — записать этот текст поверх" };
pub const st_code_error: Msg = .{ .en = "Syntax error in line {d}: {s}. Apply again to apply as it is", .ru = "Синтаксическая ошибка в строке {d}: {s}. «Применить» ещё раз — применить как есть" };

// Closing.
pub const q_unsaved: Msg = .{ .en = "There are edits not saved into the game. Save them before closing?", .ru = "Есть правки, не сохранённые в игру. Сохранить перед закрытием?" };
pub const q_save: Msg = .{ .en = "Save", .ru = "Сохранить" };
pub const q_unsaved_tab: Msg = .{ .en = "Save the edits made in “{s}” into the game?", .ru = "Сохранить в игру правки, сделанные в «{s}»?" };
pub const q_discard: Msg = .{ .en = "Don't save", .ru = "Не сохранять" };
pub const inv_open: Msg = .{ .en = "Starting inventory", .ru = "Стартовый инвентарь" };
pub const inv_title: Msg = .{ .en = "Starting inventory: {s}", .ru = "Стартовый инвентарь: {s}" };
pub const inv_hint: Msg = .{ .en = "Applies to a new game (what the hero starts with). Shift+click: ±10", .ru = "Действует в новой игре (с чем герой начинает). Shift+клик: ±10" };

// Level edit mode (paint.zig).
pub const lp_open: Msg = .{ .en = "Edit the level", .ru = "Редактировать уровень" };
pub const lp_title: Msg = .{ .en = "Level layers", .ru = "Слои уровня" };
pub const lp_picture: Msg = .{ .en = "Picture", .ru = "Картинка" };
pub const lp_depth: Msg = .{ .en = "Depth (hides actors)", .ru = "Глубина (прячет героев)" };
pub const lp_walk: Msg = .{ .en = "Walkable", .ru = "Проходимость" };
pub const lp_walk2: Msg = .{ .en = "Walkable, 2nd floor", .ru = "Проходимость, 2 этаж" };
pub const lp_changed: Msg = .{ .en = "changed", .ru = "изменено" };
pub const lp_jpg: Msg = .{ .en = "This room's picture is a JPEG: it is saved again with some loss.", .ru = "Картинка этой комнаты — JPEG: сохраняется заново с небольшой потерей." };
pub const lp_move: Msg = .{ .en = "Hand", .ru = "Рука" };
pub const lp_objects: Msg = .{ .en = "Areas and objects", .ru = "Области и объекты" };
pub const lp_brush: Msg = .{ .en = "Brush", .ru = "Кисть" };
pub const lp_color: Msg = .{ .en = "Colour", .ru = "Цвет" };
pub const lp_walk_on: Msg = .{ .en = "Walkable", .ru = "Можно ходить" };
pub const lp_walk_off: Msg = .{ .en = "Blocked", .ru = "Нельзя" };
pub const lp_hint: Msg = .{ .en = "The hand drags the map (the right button always does), the wheel zooms; the brush paints, a stroke is one step (Ctrl+Z). Done puts the layers into the edits, Save writes them.", .ru = "Рукой карта перетаскивается (правой кнопкой — всегда), колесо — масштаб; кистью рисуют, мазок — один шаг (Ctrl+Z). «Готово» кладёт слои в правки, записывает «Сохранить»." };
pub const lp_done: Msg = .{ .en = "Done", .ru = "Готово" };
pub const lp_step_picture: Msg = .{ .en = "Level picture painted", .ru = "Картинка уровня перерисована" };
pub const lp_step_resize: Msg = .{ .en = "Level resized to {d}×{d} (picture, depth, walk grids, areas)", .ru = "Размер уровня {d}×{d} (картинка, глубина, сетки ходьбы, области)" };
pub const lp_step_depth: Msg = .{ .en = "Level depth painted", .ru = "Глубина уровня перерисована" };
pub const lp_step_walk: Msg = .{ .en = "Walkable cells changed", .ru = "Проходимость изменена" };
pub const lp_step_walk2: Msg = .{ .en = "Walkable cells (2nd floor) changed", .ru = "Проходимость 2 этажа изменена" };
pub const st_layer_set: Msg = .{ .en = "Layer loaded from PNG; Done puts it into the edits", .ru = "Слой загружен из PNG; «Готово» кладёт его в правки" };
pub const st_layer_saved: Msg = .{ .en = "Layer written to {s}", .ru = "Слой записан в {s}" };
pub const st_paint_failed: Msg = .{ .en = "level edit: {t}", .ru = "редактирование уровня: {t}" };
pub const sc_lines: Msg = .{ .en = "Lines (DIALOG_DISPLAY number. speaker: text)", .ru = "Реплики (номер для DIALOG_DISPLAY. кто: текст)" };
pub const sc_edit_lines: Msg = .{ .en = "Edit text", .ru = "Редактировать текст" };
pub const lp_area: Msg = .{ .en = "Trigger area", .ru = "Область-триггер" };
pub const lp_area_hint: Msg = .{ .en = "Click the corners; a click on the first one (or Enter) finishes it, Backspace drops the last, Esc starts over. The area goes into the level's .ar, a once-only HeroInArea block into its .lev, and the code editor opens there: write what happens.", .ru = "Кликайте по углам; клик по первому (или Enter) замыкает, Backspace убирает последний, Esc — заново. Область пишется в .ar уровня, одноразовый блок HeroInArea — в его .lev, и открывается редактор кода на нём: напишите, что происходит." };
pub const lp_area_done: Msg = .{ .en = "Make the trigger", .ru = "Создать триггер" };
pub const st_trigger_added: Msg = .{ .en = "Trigger {s} added: write what happens in the code editor, Save writes it", .ru = "Триггер {s} добавлен: напишите в редакторе кода, что происходит; записывает «Сохранить»" };
pub const vo_missing: Msg = .{ .en = "no recording", .ru = "нет озвучки" };
pub const vo_none: Msg = .{ .en = "no voice (a new line)", .ru = "без озвучки (новая реплика)" };
pub const vo_replace: Msg = .{ .en = "Own file…", .ru = "Свой файл…" };
pub const vo_export: Msg = .{ .en = "To file…", .ru = "В файл…" };
pub const vo_pick: Msg = .{ .en = "Give a recording…", .ru = "Назначить запись…" };
pub const vo_remove: Msg = .{ .en = "Remove", .ru = "Удалить" };
pub const vo_spare: Msg = .{ .en = "Recordings of this dialogue no line plays:", .ru = "Записи этого диалога, которые не звучат ни в одной строке:" };
pub const st_voice_set: Msg = .{ .en = "{s} set; Save writes voice.dat (the original reads it from the registry src folder)", .ru = "{s} назначен; «Сохранить» пишет voice.dat (оригинал берёт его из папки src в реестре)" };
pub const vo_play: Msg = .{ .en = "Listen", .ru = "Слушать" };
pub const sc_battle_lines: Msg = .{ .en = "Before a battle (StartDialog)", .ru = "Перед боем (StartDialog)" };
pub const sc_idle_lines: Msg = .{ .en = "Idle remarks", .ru = "Бездействие" };
pub const sc_no_lines: Msg = .{ .en = "no lines", .ru = "нет реплик" };
pub const sc_battle_hint: Msg = .{ .en = "Said in order before the battle starts (the battle's StartDialog() in after_select_gui); no line numbers in scripts.", .ru = "Звучат по порядку перед началом боя (StartDialog() в after_select_gui боя); номеров в скриптах нет." };
pub const lvl_files: Msg = .{ .en = "Files", .ru = "Файлы" };
pub const sc_battle_hint_og: Msg = .{ .en = "Said in order before the battle starts (StartDialog() in the battle's OnShown); no line numbers in code.", .ru = "Звучат по порядку перед началом боя (StartDialog() в OnShown боя); номеров в коде нет." };
pub const sc_idle_hint: Msg = .{ .en = "Said by a hero left idle for a while; the exe picks the file (idle_<code>_01), only the text and recording change.", .ru = "Говорит герой, если его долго не трогать; файл выбирает exe (idle_<код>_01), меняются только текст и запись." };
pub const sc_new_lines: Msg = .{ .en = "Add lines to this battle", .ru = "Добавить реплики этому бою" };
pub const sc_battle_open: Msg = .{ .en = "Lines before the battle", .ru = "Реплики перед боем" };
pub const st_area_used: Msg = .{ .en = "Area {s} stays: {s} names it — change that script first", .ru = "Область {s} не удалена: на неё ссылается {s} — сначала поправьте этот скрипт" };
pub const st_area_deleted: Msg = .{ .en = "Area {s} removed (with the editor's trigger for it); Save writes it", .ru = "Область {s} удалена (вместе с её триггером из редактора); записывает «Сохранить»" };
pub const st_area_renamed: Msg = .{ .en = "Area {s} is now {s} (in the level's scripts too); Save writes it", .ru = "Область {s} теперь {s} (и в скриптах уровня); записывает «Сохранить»" };
pub const st_area_bad_name: Msg = .{ .en = "\"{s}\": letters, digits and _ only", .ru = "«{s}»: только латинские буквы, цифры и _" };
pub const st_area_taken: Msg = .{ .en = "There is an area {s} already", .ru = "Область {s} уже есть" };
pub const st_area_in_scene: Msg = .{ .en = "Area {s} keeps its name: scene {s} names it (scenes are shared by levels)", .ru = "Область {s} не переименована: её называет сценка {s} (сценки общие для уровней)" };
pub const lp_area_picked: Msg = .{ .en = "Area {s}", .ru = "Область {s}" };
pub const lp_area_rename: Msg = .{ .en = "Rename", .ru = "Переименовать" };
pub const lp_area_delete: Msg = .{ .en = "Delete the area", .ru = "Удалить область" };
pub const menu_add_hero: Msg = .{ .en = "Bring a hero here", .ru = "Перенести героя сюда" };
pub const st_hero_added: Msg = .{ .en = "{s} is on the level, hidden (DisableObject in post_init); joins as McFadden does in 02_serwers.lev: EnableObject(\"{0s}\"); HERO_EnableEnumerate(\"{0s}\",1); then StartScriptlet. Save writes it", .ru = "{s} на уровне, скрыт(а) (DisableObject в post_init); присоединяется как Макфадден в 02_serwers.lev: EnableObject(\"{0s}\"); HERO_EnableEnumerate(\"{0s}\",1); затем StartScriptlet. Записывает «Сохранить»" };
pub const st_hero_there: Msg = .{ .en = "{s} is on this level already", .ru = "{s} уже есть на этом уровне" };
pub const sc_new: Msg = .{ .en = "New scene", .ru = "Новая сценка" };
pub const st_scene_added: Msg = .{ .en = "Scene {s} made: its script is open; points in the level edit mode (\"Scene points\"), lines below", .ru = "Сценка {s} создана: открыт её скрипт; точки — в режиме редактирования уровня («Точки сценки»), реплики — ниже" };
pub const lp_points: Msg = .{ .en = "Scene points", .ru = "Точки сценки" };
pub const lp_points_of: Msg = .{ .en = "Points of scene {s}", .ru = "Точки сценки {s}" };
pub const lp_points_none: Msg = .{ .en = "Pick a scene above (or make one in the Scenes tab): its points are shown and put here.", .ru = "Выберите сценку выше (или создайте во вкладке «Сцены»): здесь видны и ставятся её точки." };
pub const lp_points_hint: Msg = .{ .en = "A click puts a point p1, p2…: the scene's PLACE(\"Hero\",\"p1\"), WALKTO(\"Hero\",\"p2\"), DOLLY(\"p1\",…) name them.", .ru = "Клик ставит точку p1, p2…: на них ссылаются PLACE(\"Герой\",\"p1\"), WALKTO(\"Герой\",\"p2\"), DOLLY(\"p1\",…) в сценке." };
pub const st_no_scene: Msg = .{ .en = "Pick a scene in the Scenes tab first", .ru = "Сначала выберите сценку во вкладке «Сцены»" };
pub const st_point_added: Msg = .{ .en = "Point {s} added to scene {s}", .ru = "Точка {s} добавлена в сценку {s}" };
pub const lp_scenes_all: Msg = .{ .en = "All scenes", .ru = "Все сценки" };
pub const lp_scenes_level: Msg = .{ .en = "This level's scenes", .ru = "Сценки этого уровня" };
pub const st_scene_bad_name: Msg = .{ .en = "\"{s}\": letters, digits, _ and - only", .ru = "«{s}»: только латинские буквы, цифры, _ и -" };
pub const st_scene_taken: Msg = .{ .en = "There is a scene {s} already", .ru = "Сценка {s} уже есть" };
pub const st_scene_renamed: Msg = .{ .en = "Scene {s} is now {s} ({d} scripts starting it changed); Save writes it", .ru = "Сценка {s} теперь {s} (поправлено скриптов, где она запускается: {d}); записывает «Сохранить»" };
pub const sc_rename_hint: Msg = .{ .en = "click the name to rename the scene (its files and every StartScriptlet naming it)", .ru = "клик по имени — переименовать сценку (её файлы и все StartScriptlet с ней)" };
pub const ln_area: Msg = .{ .en = "Area {s} on {s}", .ru = "Область {s} на {s}" };
pub const ln_scene: Msg = .{ .en = "Scene {s}", .ru = "Сценка {s}" };
pub const ln_level: Msg = .{ .en = "Level {s}", .ru = "Уровень {s}" };
pub const st_no_such_scene: Msg = .{ .en = "No scene {s}", .ru = "Сценки {s} нет" };
pub const st_no_such_level: Msg = .{ .en = "No level {s}", .ru = "Уровня {s} нет" };
pub const lp_area_no_scene: Msg = .{ .en = "starts no scene (the level's scripts)", .ru = "сценок не запускает (по скриптам уровня)" };
pub const menu_add_own: Msg = .{ .en = "Add one of ours", .ru = "Добавить своего" };
pub const menu_own_there: Msg = .{ .en = " — already in this battle", .ru = " — уже в этом бою" };
pub const st_own_added: Msg = .{ .en = "{s} placed: PlaceActor in restore(); the game puts the hero there when in the party, skips the line otherwise. Save writes it", .ru = "{s} поставлен(а): PlaceActor в restore(); игра ставит героя сюда, если он в отряде, иначе строку пропускает. Записывает «Сохранить»" };
pub const lp_lights: Msg = .{ .en = "Lights", .ru = "Свет" };
pub const lp_lights_hint: Msg = .{ .en = "The level's lamps (.lts): they light the 3D models (heroes, enemies, items) and set their shadows; the painted picture stays as it is. A click on a lamp picks it (drag to move, its height kept), elsewhere puts a new one over the floor.", .ru = "Лампы уровня (.lts): освещают 3D-модели (героев, врагов, предметы) и задают их тени; нарисованная картинка не меняется. Клик по лампе выбирает её (тяните — двигается, высота сохраняется), в другом месте — ставит новую над полом." };
pub const lp_lights_none: Msg = .{ .en = "This level has no .lts: the game lights its models with the defaults.", .ru = "У уровня нет .lts: игра освещает модели по умолчанию." };
pub const lp_light_n: Msg = .{ .en = "Lamp {d} of {d}", .ru = "Лампа {d} из {d}" };
pub const lp_light_color: Msg = .{ .en = "Colour {s}: {d:.2}", .ru = "Цвет {s}: {d:.2}" };
pub const lp_light_range: Msg = .{ .en = "Range: {d:.0}", .ru = "Радиус: {d:.0}" };
pub const lp_light_height: Msg = .{ .en = "Height: {d:.0}", .ru = "Высота: {d:.0}" };
pub const lp_ambient: Msg = .{ .en = "Ambient {s}: {d:.2}", .ru = "Общий свет {s}: {d:.2}" };
pub const lp_directional: Msg = .{ .en = "Sun {s}: {d:.2}", .ru = "Солнце {s}: {d:.2}" };
pub const lp_shadow_light: Msg = .{ .en = "Shadow light {s}: {d:.0}", .ru = "Источник тени {s}: {d:.0}" };
pub const lp_shadow: Msg = .{ .en = "Shadow: {d:.2}", .ru = "Тень: {d:.2}" };
pub const lp_step_light: Msg = .{ .en = "Lights of {s}", .ru = "Свет {s}" };
pub const st_location_failed: Msg = .{ .en = "Location {s} not made: {t} (a name: 3-24 lower-case letters, digits, single _; a free folder)", .ru = "Локация {s} не создана: {t} (имя: 3-24 строчные латинские буквы, цифры, одиночные _; папка свободна)" };
pub const st_location_made: Msg = .{ .en = "Location {s} made from {s} (written to disk). The party enters at capt_start; a trigger with LEVEL_Load(\"{s}\") somewhere leads here.", .ru = "Локация {s} создана из {s} (уже записана на диск). Отряд входит в capt_start; сюда ведёт триггер с LEVEL_Load(\"{s}\")." };
pub const lv_new: Msg = .{ .en = "New location from this one…", .ru = "Новая локация из этой…" };
/// An OpenGorky project of OG Script: a new level is not made by the editor (it made the
/// Classic archives in the installed game's `dat/`, which a project never writes).
pub const lv_og_new: Msg = .{ .en = "OpenGorky: the level goes into the project — its block into src/locations/<name>/ (a battle: src/battles/<name>/), its picture and maps into src/assets/levels/<name>/; the installed game is not touched.", .ru = "OpenGorky: уровень создаётся в проекте — блок в src/locations/<имя>/ (бой — в src/battles/<имя>/), картинка и карты в src/assets/levels/<имя>/; установленная игра не меняется." };
pub const lv_new_hint: Msg = .{ .en = "Copies the picture, depth, camera, walk grids and lights; scripts, items and areas start clean. Name: lower-case latin, digits, _. Enter makes it.", .ru = "Копирует картинку, глубину, камеру, проходимость и свет; скрипты, предметы и области — с чистого листа. Имя: строчная латиница, цифры, _. Enter — создать." };
pub const lv_make: Msg = .{ .en = "Make", .ru = "Создать" };
pub const st_exit_added: Msg = .{ .en = "Exit {s} added: a click on it walks the party there and loads {s}", .ru = "Выход {s} добавлен: клик по нему ведёт отряд туда и загружает {s}" };
pub const lp_exit: Msg = .{ .en = "Exit", .ru = "Выход" };
pub const lp_exit_hint: Msg = .{ .en = "A clickable exit, as the game's doors: draw its outline as a trigger's. A click on it in the game walks the hero to the nearest walkable spot and loads the level picked below. The hint over it:", .ru = "Кликабельный выход, как двери в игре: обведите его так же, как триггер. Клик по нему в игре ведёт героя к ближайшей проходимой точке и загружает выбранный ниже уровень. Подсказка над ним:" };
pub const lp_exit_pick: Msg = .{ .en = "Pick a level below", .ru = "Выберите уровень ниже" };
pub const lp_exit_go: Msg = .{ .en = "Open {s}", .ru = "Открыть {s}" };
pub const lp_exit_closed: Msg = .{ .en = "The outline is closed: pick the hint and the level, then «Make the exit» (Backspace opens it again, Esc drops it).", .ru = "Контур замкнут: выберите подсказку и уровень, затем «Создать выход» (Backspace — снова открыть, Esc — сбросить)." };
pub const lp_exit_make: Msg = .{ .en = "Make the exit", .ru = "Создать выход" };
pub const tm_open: Msg = .{ .en = "Open", .ru = "Открыть" };
pub const tm_paste: Msg = .{ .en = "Paste (a copy of the copied)", .ru = "Вставить (копию скопированного)" };
pub const tm_k_level: Msg = .{ .en = "Level", .ru = "Уровень" };
pub const tm_k_entry: Msg = .{ .en = "Class", .ru = "Класс" };
pub const tm_k_scene: Msg = .{ .en = "Scene", .ru = "Сценка" };
pub const tm_k_script: Msg = .{ .en = "Script", .ru = "Скрипт" };
pub const tm_k_sound: Msg = .{ .en = "Sound", .ru = "Звук" };
pub const tm_k_video: Msg = .{ .en = "Video", .ru = "Видео" };
pub const st_tree_copied: Msg = .{ .en = "{s} copied: Paste (right click in the tree, Cmd/Ctrl+V) makes a copy of it", .ru = "{s} скопирован: «Вставить» (правый клик в дереве, Cmd/Ctrl+V) создаёт его копию" };
pub const st_tree_made: Msg = .{ .en = "{s} made: a copy of {s} (Ctrl+Z takes it away)", .ru = "{s} создан: копия {s} (Ctrl+Z убирает)" };
pub const st_tree_copy_failed: Msg = .{ .en = "{s} not copied: {t}", .ru = "{s} не скопирован: {t}" };
pub const sc_kind: Msg = .{ .en = "Scene scriptlet · click the name to rename", .ru = "Сценка · клик по имени — переименовать" };
pub const sc_v_overview: Msg = .{ .en = "Overview", .ru = "Обзор" };
pub const sc_v_code: Msg = .{ .en = "Code", .ru = "Код" };
pub const sc_c_where: Msg = .{ .en = "Location > Area", .ru = "Локация > Зона" };
pub const sc_v_lines: Msg = .{ .en = "Lines", .ru = "Реплики" };
pub const sc_c_event: Msg = .{ .en = "Event", .ru = "Событие" };
pub const sc_c_enabled: Msg = .{ .en = "Enabled", .ru = "Включено" };
pub const sc_c_actions: Msg = .{ .en = "Actions", .ru = "Действия" };
pub const sc_entries: Msg = .{ .en = "Entry points", .ru = "Точки входа" };
pub const sc_entries_note: Msg = .{ .en = "Where it starts (turning a start off loses all of the block too)", .ru = "Где запускается (выключение запуска убирает и весь блок)" };
pub const sc_ev_addon: Msg = .{ .en = "After the level's scene", .ru = "После сценки уровня" };
pub const sc_ev_area: Msg = .{ .en = "Hero enters area", .ru = "Герой входит в зону" };
pub const sc_ev_script: Msg = .{ .en = "Level script", .ru = "Скрипт уровня" };
pub const sc_game_off_short: Msg = .{ .en = "off in the game", .ru = "выкл. в игре" };
pub const sc_unsafe_short: Msg = .{ .en = "in code only", .ru = "только в коде" };
pub const sc_show_map: Msg = .{ .en = "Show on map", .ru = "На карте" };
pub const sc_view_code: Msg = .{ .en = "View in code", .ru = "В коде" };
pub const sc_c_type: Msg = .{ .en = "Type", .ru = "Тип" };
pub const sc_c_target: Msg = .{ .en = "Target", .ru = "Цель" };
pub const sc_c_arg: Msg = .{ .en = "Argument", .ru = "Аргумент" };
pub const sc_effects: Msg = .{ .en = "Effects", .ru = "Эффекты" };
pub const sc_effects_note: Msg = .{ .en = "What it changes in the game", .ru = "Что меняет в игре" };
pub const ef_sethero: Msg = .{ .en = "Set hero", .ru = "Сменить героя" };
pub const ef_delete: Msg = .{ .en = "Delete object", .ru = "Удалить объект" };
pub const ef_disable: Msg = .{ .en = "Disable object", .ru = "Выключить объект" };
pub const ef_loadlevel: Msg = .{ .en = "Load level", .ru = "Загрузить уровень" };
pub const ef_prevlevel: Msg = .{ .en = "Previous level", .ru = "Предыдущий уровень" };
pub const ef_runfun: Msg = .{ .en = "Run function", .ru = "Вызвать функцию" };
pub const ef_allow_walk: Msg = .{ .en = "Allow walking", .ru = "Разрешить ходить" };
pub const ef_forbid_walk: Msg = .{ .en = "Forbid walking", .ru = "Запретить ходить" };
pub const ef_item: Msg = .{ .en = "Give item", .ru = "Выдать предмет" };
pub const ef_next: Msg = .{ .en = "Next scene", .ru = "Следующая сценка" };
pub const ef_place: Msg = .{ .en = "Place heroes", .ru = "Поставить героев" };
pub const ef_gameover: Msg = .{ .en = "Game over", .ru = "Конец игры" };
pub const ef_enddemo: Msg = .{ .en = "End of demo", .ru = "Конец демо" };
pub const ef_credits: Msg = .{ .en = "Credits", .ru = "Титры" };
pub const sc_map: Msg = .{ .en = "Map preview", .ru = "Карта" };
pub const sc_show: Msg = .{ .en = "Show:", .ru = "Показать:" };
pub const sc_show_areas: Msg = .{ .en = "Areas", .ru = "Зоны" };
pub const sc_show_objects: Msg = .{ .en = "Objects", .ru = "Объекты" };
pub const sc_show_entries: Msg = .{ .en = "Entry points", .ru = "Точки входа" };
pub const sc_props: Msg = .{ .en = "Scene properties", .ru = "Свойства сценки" };
pub const sc_p_id: Msg = .{ .en = "ID", .ru = "ID" };
pub const sc_utils: Msg = .{ .en = "Utilities", .ru = "Инструменты" };
pub const sc_short_copy: Msg = .{ .en = "Create shortened copy", .ru = "Создать сокращённую копию" };
pub const sc_short_copy_hint: Msg = .{ .en = "Removes presentation commands; keeps gameplay changes.", .ru = "Убирает показ (реплики, камеру, паузы); изменения в игре остаются." };
pub const code_outline: Msg = .{ .en = "Outline", .ru = "Структура" };
pub const code_no_fns: Msg = .{ .en = "No functions", .ru = "Нет функций" };
pub const code_context: Msg = .{ .en = "Context", .ru = "Контекст" };
pub const code_context_none: Msg = .{ .en = "Put the cursor on a word: what it is shows here.", .ru = "Поставьте курсор на слово — здесь будет, что это." };
pub const code_k_name: Msg = .{ .en = "Name", .ru = "Имя" };
pub const code_k_type: Msg = .{ .en = "Type", .ru = "Тип" };
pub const code_t_fn: Msg = .{ .en = "engine function", .ru = "функция движка" };
pub const code_t_game_fn: Msg = .{ .en = "game script function", .ru = "функция скриптов игры" };
pub const code_k_value: Msg = .{ .en = "Value here", .ru = "Значение здесь" };
pub const code_k_uses: Msg = .{ .en = "Uses", .ru = "Упоминаний" };
pub const code_k_file: Msg = .{ .en = "Defined in", .ru = "Файл" };
pub const code_problems: Msg = .{ .en = "Problems ({d})", .ru = "Проблемы ({d})" };
pub const code_refs: Msg = .{ .en = "References ({d})", .ru = "Упоминания ({d})" };
pub const code_no_issues: Msg = .{ .en = "No issues found in this file.", .ru = "В этом файле проблем нет." };
pub const code_not_checked: Msg = .{ .en = "Not a script the engine's parser reads (scene or dialogue): not checked.", .ru = "Это не скрипт для парсера движка (сценка или диалог): не проверяется." };
pub const so_title: Msg = .{ .en = "Selected object", .ru = "Выбранный объект" };
pub const so_tile: Msg = .{ .en = "Tile {d}, {d}", .ru = "Клетка {d}, {d}" };
pub const so_grid: Msg = .{ .en = "Grid {d:.1}, {d:.1}", .ru = "Сетка {d:.1}, {d:.1}" };
pub const so_pos: Msg = .{ .en = "Position {d:.0}, {d:.0} (background pixels)", .ru = "Позиция {d:.0}, {d:.0} (пиксели фона)" };
pub const so_explodable: Msg = .{ .en = "Explodes", .ru = "Взрывается" };
pub const so_contents: Msg = .{ .en = "Contents ({d})", .ru = "Содержимое ({d})" };
pub const at_sprites: Msg = .{ .en = "Sprites", .ru = "Спрайты" };
pub const at_spr_ui: Msg = .{ .en = "Interface", .ru = "Интерфейс" };
pub const at_spr_icons: Msg = .{ .en = "Icons", .ru = "Иконки" };
pub const at_spr_levels: Msg = .{ .en = "Levels", .ru = "Уровни" };
pub const spr_import_new: Msg = .{ .en = "Import PNG…", .ru = "Импорт PNG…" };
pub const spr_add_frame: Msg = .{ .en = "+ Frame from PNG", .ru = "+ Кадр из PNG" };
pub const spr_remove: Msg = .{ .en = "Remove", .ru = "Удалить" };
pub const spr_frame_added: Msg = .{ .en = "frame added", .ru = "кадр добавлен" };
pub const spr_frame_removed: Msg = .{ .en = "frame removed", .ru = "кадр удалён" };
pub const st_sprite_added: Msg = .{ .en = "Sprite {s} added (Ctrl+Z takes it away); scripts name it as spriteFile", .ru = "Спрайт {s} добавлен (Ctrl+Z убирает); скрипты называют его в spriteFile" };
pub const lm_by: Msg = .{ .en = "used by {s}", .ru = "использует {s}" };
pub const lm_unused: Msg = .{ .en = "not named by the level's scripts", .ru = "скрипты уровня его не называют" };
pub const lm_music_own: Msg = .{ .en = "music: its own track", .ru = "музыка: свой трек" };
pub const lm_music_district: Msg = .{ .en = "music: the district's track (no own one)", .ru = "музыка: трек района (своего нет)" };
pub const lm_music_battle: Msg = .{ .en = "battle music: this or the other, drawn at random", .ru = "музыка боя: этот или другой, выбирается случайно" };
pub const lm_music_boss: Msg = .{ .en = "battle music: a boss battle (boss)", .ru = "музыка боя: бой с боссом (boss)" };
pub const lm_music_missing: Msg = .{ .en = "not in common/voice.dat (the game stays silent here)", .ru = "нет в common/voice.dat (здесь игра молчит)" };
pub const lm_music_enemy: Msg = .{ .en = "during the enemies' turn", .ru = "в ход врагов" };
pub const cf_title: Msg = .{ .en = "Delete?", .ru = "Удалить?" };
pub const cf_delete: Msg = .{ .en = "{s} will be deleted.", .ru = "{s} будет удалён." };
pub const cf_frame: Msg = .{ .en = "A frame of {s} will be deleted.", .ru = "Кадр {s} будет удалён." };
pub const cf_purge: Msg = .{ .en = "These fighters' files will be deleted: {s}", .ru = "Будут удалены файлы бойцов: {s}" };
pub const cf_undo: Msg = .{ .en = "Ctrl+Z brings it back until you quit; Save writes it into the game.", .ru = "Ctrl+Z вернёт до выхода; «Сохранить» запишет в игру." };
pub const lp_lamp_word: Msg = .{ .en = "Lamp", .ru = "Лампа" };
pub const sc_v_debug: Msg = .{ .en = "Debug", .ru = "Отладка" };
pub const sc_debug_note: Msg = .{ .en = "A run to the end on its level without a window (the level's own scene skipped)", .ru = "Прогон до конца на её уровне без окна (своя сцена уровня пропускается)" };
pub const sc_debug_nolevel: Msg = .{ .en = "No level script starts it: nowhere to run it (scenes started by other scenes run there).", .ru = "Её не запускает ни один скрипт уровня: негде прогнать (сцены из других сцен идут там)." };
pub const sc_run: Msg = .{ .en = "Run", .ru = "Прогнать" };
pub const sc_play_port: Msg = .{ .en = "Play on {s}", .ru = "Запустить на {s}" };
pub const sc_run_on: Msg = .{ .en = "on {s} (saved first)", .ru = "на {s} (сначала сохранится)" };
pub const sc_run_result: Msg = .{ .en = "{s}: {d} ticks ({d:.1} s)", .ru = "{s}: {d} тиков ({d:.1} с)" };
pub const sc_run_clean: Msg = .{ .en = "Nothing looks wrong.", .ru = "Ничего подозрительного." };
pub const sc_c_tick: Msg = .{ .en = "Tick", .ru = "Тик" };
pub const sc_c_line: Msg = .{ .en = "Line", .ru = "Строка" };
pub const sc_c_cmd: Msg = .{ .en = "Command", .ru = "Команда" };
pub const sc_c_took: Msg = .{ .en = "Took", .ru = "Длилась" };
pub const st_scene_run: Msg = .{ .en = "Scene {s} run: {s}, {d} ticks", .ru = "Сцена {s} прогнана: {s}, {d} тиков" };
pub const sc_r_ok: Msg = .{ .en = "It reached its end.", .ru = "Дошла до конца." };
pub const sc_r_hung: Msg = .{ .en = "Stuck: a command waits for ever (the last row of the list).", .ru = "Застряла: команда ждёт вечно (последняя строка списка)." };
pub const sc_r_moves: Msg = .{ .en = "Stopped at a walk: the run does not walk paths — play it in OpenGorky to see the rest.", .ru = "Остановилась на ходьбе: прогон не ходит по путям — остальное смотрите, запустив в OpenGorky." };
pub const sc_r_level: Msg = .{ .en = "It ends by loading another level.", .ru = "Заканчивается переходом на другой уровень." };
pub const at_texts: Msg = .{ .en = "Texts", .ru = "Тексты" };
pub const at_tx_strings: Msg = .{ .en = "Names and words", .ru = "Имена и слова" };
pub const at_tx_items: Msg = .{ .en = "Item descriptions", .ru = "Описания предметов" };
pub const at_tx_areas: Msg = .{ .en = "Area descriptions", .ru = "Описания зон" };
pub const at_tx_credits: Msg = .{ .en = "Credits", .ru = "Титры" };
pub const tx_strings_hint: Msg = .{ .en = "Names of heroes, monsters, items and areas by classic_id, and the interface's words. New ones get numbers past the game's.", .ru = "Имена героев, монстров, предметов и зон по classic_id и слова интерфейса. Новые получают номера после игровых." };
pub const tx_items_hint: Msg = .{ .en = "What examining an item says: the row's number is the item's classic_id.", .ru = "Что говорит осмотр предмета: номер строки — classic_id предмета." };
pub const tx_areas_hint: Msg = .{ .en = "What examining an area says (doors, machines): the row's number is the area's classic_id.", .ru = "Что говорит осмотр зоны (двери, механизмы): номер строки — classic_id зоны." };
pub const tx_new: Msg = .{ .en = "New row", .ru = "Новая строка" };
pub const tx_new_text: Msg = .{ .en = "New text", .ru = "Новый текст" };
pub const tx_search: Msg = .{ .en = "Search: a word or a number (Enter)", .ru = "Поиск: слово или номер (Enter)" };
pub const st_text_taken: Msg = .{ .en = "Number {d} is taken", .ru = "Номер {d} занят" };
pub const st_text_added: Msg = .{ .en = "{s}: row {d} added — type its text", .ru = "{s}: строка {d} добавлена — впишите текст" };
pub const cf_text_row: Msg = .{ .en = "Row {d} of {s} will be deleted (whatever names it shows nothing then).", .ru = "Строка {d} из {s} будет удалена (то, что на неё ссылается, станет без текста)." };
pub const sec_texts: Msg = .{ .en = "Texts", .ru = "Тексты" };
// The right panel's blocks: titles, subgroups, what a header sums up.
pub const sec_combat: Msg = .{ .en = "Combat", .ru = "Бой" };
pub const sec_damage: Msg = .{ .en = "Damage", .ru = "Урон" };
pub const sec_props: Msg = .{ .en = "Properties", .ru = "Свойства" };
pub const sec_growth: Msg = .{ .en = "Growth", .ru = "Развитие" };
pub const sec_timing: Msg = .{ .en = "Timings", .ru = "Тайминги" };
pub const pu_hand: Msg = .{ .en = "the weapon in the hand, its flash and beam", .ru = "оружие в руке, его вспышка и луч" };
pub const pu_back: Msg = .{ .en = "a two-handed weapon on the back", .ru = "двуручное оружие на спине" };
pub const pu_lift: Msg = .{ .en = "where a lifted victim hangs", .ru = "где висит поднятая жертва" };
pub const pu_ball: Msg = .{ .en = "a projectile held between the hands", .ru = "снаряд между ладонями" };
pub const pu_fx: Msg = .{ .en = "an effect's origin", .ru = "откуда идёт эффект" };
pub const pu_glow: Msg = .{ .en = "the Incubus glow", .ru = "свечение Инкуба" };
pub const pu_default: Msg = .{ .en = "offered by the editor (no game code asks for it)", .ru = "предлагает редактор (код игры её не ищет)" };
pub const pu_rider: Msg = .{ .en = "a rider", .ru = "седок" };
pub const pu_spin: Msg = .{ .en = "a saw spun (FighterStrike {d})", .ru = "вращение пилы (FighterStrike {d})" };
pub const pu_none: Msg = .{ .en = "no use the game's code knows (scripts may name it)", .ru = "код игры её не использует (её могут назвать скрипты)" };
pub const pt_info: Msg = .{ .en = "{s}: {s}. {s}", .ru = "{s}: {s}. {s}" };
pub const pt_drag: Msg = .{ .en = "Drag the point to move it in the picture's plane; the fields below nudge it.", .ru = "Тяните точку, чтобы сдвинуть её в плоскости картинки; поля ниже двигают точно." };
pub const pt_locked: Msg = .{ .en = "The fields below move it.", .ru = "Двигается полями ниже." };
pub const m_points: Msg = .{ .en = "Attach points", .ru = "Точки крепления" };
pub const m_offset: Msg = .{ .en = "offset", .ru = "сдвиг" };
pub const m_angles: Msg = .{ .en = "angles", .ru = "углы" };
pub const copy_menu: Msg = .{ .en = "Copy…", .ru = "Копия…" };
pub const sum_model: Msg = .{ .en = "height {d:.0} · attach points: {d}", .ru = "высота {d:.0} · точек: {d}" };
pub const sum_anims: Msg = .{ .en = "{d} slots", .ru = "слотов: {d}" };
pub const sum_anims_missing: Msg = .{ .en = "{d} slots · {d} missing", .ru = "слотов: {d} · нет в модели: {d}" };
pub const sum_info: Msg = .{ .en = "{s} · levels: {d}", .ru = "{s} · уровней: {d}" };
pub const sum_bonus: Msg = .{ .en = "healing +{d}%", .ru = "лечение +{d}%" };
pub const sum_party: Msg = .{ .en = "party at most {d}", .ru = "отряд до {d}" };
pub const sum_own: Msg = .{ .en = "own: {d}", .ru = "своих: {d}" };
pub const attack_card: Msg = .{ .en = "{s} · {s}", .ru = "{s} · {s}" };
pub const lp_depth_label: Msg = .{ .en = "Depth", .ru = "Глубина" };
pub const lp_depth_row: Msg = .{ .en = "{d} (0 — nearest)", .ru = "{d} (0 — ближе всего)" };
pub const lp_exit_label: Msg = .{ .en = "Hint", .ru = "Подсказка" };
pub const lp_exit_where: Msg = .{ .en = "Leads to", .ru = "Ведёт в" };
pub const lp_scene: Msg = .{ .en = "Scene", .ru = "Сценка" };
pub const s_sec_ui: Msg = .{ .en = "Interface", .ru = "Интерфейс" };
pub const s_sec_project: Msg = .{ .en = "Project", .ru = "Проект" };
pub const s_sec_port: Msg = .{ .en = "Port", .ru = "Порт" };
pub const s_sec_about: Msg = .{ .en = "About", .ru = "Сведения" };
pub const c_name_game: Msg = .{ .en = "Name in the game (string.tab {d})", .ru = "Имя в игре (string.tab {d})" };
pub const c_name_og: Msg = .{ .en = "Name in the game", .ru = "Имя в игре" };
pub const c_name_og_none: Msg = .{ .en = "none: type a name", .ru = "нет — впишите имя" };
pub const c_name_none: Msg = .{ .en = "no text in string.tab", .ru = "нет текста в string.tab" };
pub const c_examine: Msg = .{ .en = "Examining it says", .ru = "При осмотре" };
pub const c_examine_none: Msg = .{ .en = "nothing: type a description", .ru = "ничего — впишите описание" };
pub const st_voices_moved: Msg = .{ .en = "{d} recordings moved with their lines", .ru = "Записей перенесено вместе с репликами: {d}" };
pub const st_dlg_lost: Msg = .{ .en = "{s}: scenes showed the deleted line {d} time(s) — they now show the next one; check them", .ru = "{s}: сцены показывали удалённую реплику ({d} раз) — теперь там следующая; проверьте их" };
pub const at_music: Msg = .{ .en = "Music", .ru = "Музыка" };
pub const mus_import: Msg = .{ .en = "Import music…", .ru = "Импорт музыки…" };
pub const mus_stop: Msg = .{ .en = "Stop", .ru = "Стоп" };
pub const mus_own: Msg = .{ .en = "This level's own music…", .ru = "Своя музыка уровня…" };
pub const mus_hint: Msg = .{ .en = "A file goes into voice.dat as the game's music is: MP3 44100 Hz stereo 128 kbit/s (ffmpeg converts), so the original plays it. A location plays the track named as it (01_port), else its district's; battle, battle2, battle3 (and _enemy) are the battles'; scenes start one with MP3_PLAY(\"name\").", .ru = "Файл попадает в voice.dat в формате музыки игры: MP3 44100 Гц стерео 128 кбит/с (перекодирует ffmpeg), так что его играет и оригинал. Локация играет трек со своим именем (01_port), иначе — трек района; battle, battle2, battle3 (и _enemy) — музыка боёв; сцены включают трек командой MP3_PLAY(\"имя\")." };
pub const mus_district: Msg = .{ .en = " (its district's track)", .ru = " (трек района)" };
pub const mus_battles: Msg = .{ .en = "battles without a track of their own", .ru = "бои без своего трека" };
pub const mus_unused: Msg = .{ .en = "Nothing plays it by name (a scene can: MP3_PLAY).", .ru = "По имени его ничто не играет (может сцена: MP3_PLAY)." };
pub const st_music_added: Msg = .{ .en = "Music {s} added", .ru = "Музыка {s} добавлена" };
pub const st_text_taken_name: Msg = .{ .en = "{s} exists already", .ru = "{s} уже есть" };
pub const an_title: Msg = .{ .en = "Animations", .ru = "Анимации" };
pub const an_active: Msg = .{ .en = "played by scripts", .ru = "по скрипту" };
pub const an_loop: Msg = .{ .en = "loops", .ru = "по кругу" };
pub const an_new: Msg = .{ .en = "New animation from a sprite", .ru = "Новая анимация из спрайта" };
pub const an_sprite: Msg = .{ .en = "Sprite", .ru = "Спрайт" };
pub const an_speed: Msg = .{ .en = "Speed", .ru = "Скорость" };
pub const an_x: Msg = .{ .en = "X", .ru = "X" };
pub const an_y: Msg = .{ .en = "Y", .ru = "Y" };
pub const an_zbuf: Msg = .{ .en = "Depth: {s}.spz (hides heroes behind it)", .ru = "Глубина: {s}.spz (прячет героев за собой)" };
pub const an_edit_sprite: Msg = .{ .en = "Edit the sprite", .ru = "Править спрайт" };
pub const st_anim_novar: Msg = .{ .en = "{s} has no .var in common/other.dat to place it", .ru = "У {s} нет .var в common/other.dat с позицией" };
pub const st_anim_added: Msg = .{ .en = "Animation {s} made: drag it into place (Objects tool)", .ru = "Анимация {s} создана: перетащите её на место (инструмент «Объекты»)" };
pub const lp_paths: Msg = .{ .en = "Paths", .ru = "Пути" };
pub const pa_hint: Msg = .{ .en = "Walk paths (stairs, ladders, footbridges): a hero walking between the start and end cells goes through the nodes. Drag a node; with \"Add nodes\" clicks add them.", .ru = "Пути (лестницы, мостки): герой, идущий между клетками начала и конца, проходит по узлам. Узлы перетаскиваются; с «Добавить узлы» клик добавляет узел." };
pub const pa_nodes: Msg = .{ .en = "{d} nodes", .ru = "узлов: {d}" };
pub const pa_new: Msg = .{ .en = "New path", .ru = "Новый путь" };
pub const pa_add: Msg = .{ .en = "Add nodes", .ru = "Добавить узлы" };
pub const pa_start: Msg = .{ .en = "Start cell", .ru = "Клетка начала" };
pub const pa_end: Msg = .{ .en = "End cell", .ru = "Клетка конца" };
pub const pa_link: Msg = .{ .en = "Cells: start {d},{d} -> end {d},{d} (walk grid, 8 px). Node: x, y, angle, the exe's last number.", .ru = "Клетки: начало {d},{d} -> конец {d},{d} (сетка ходьбы, 8 px). Узел: x, y, угол, последнее число exe." };
pub const pa_script: Msg = .{ .en = "Its script (.pth)", .ru = "Скрипт (.pth)" };
pub const st_path_added: Msg = .{ .en = "Path {s} made: click the map to add its nodes, then set its cells", .ru = "Путь {s} создан: кликайте по карте, чтобы добавить узлы, затем задайте клетки" };
pub const sb_paths: Msg = .{ .en = "LMB node: drag · click (Add nodes): a node · RMB / middle drag: pan", .ru = "ЛКМ по узлу — тащить · клик (Добавить узлы) — узел · ПКМ / средняя — сдвиг" };
pub const cm_add_model: Msg = .{ .en = "Add a 3D model", .ru = "Добавить 3D-модель" };
pub const st_actor_added: Msg = .{ .en = "{s} stands there: drag it (Objects tool); its script sets the model, place and turn", .ru = "{s} поставлен: его можно тащить (инструмент «Объекты»); модель, место и поворот — в его скрипте" };
pub const st_actor_at_area: Msg = .{ .en = "{s} stands at an area point (PlaceActor): move that point with the Hand tool", .ru = "{s} стоит в точке зоны (PlaceActor): двигайте эту точку инструментом «Рука»" };
pub const cam_ortho_hint: Msg = .{ .en = "A location's camera looks straight down at the tilt its picture was drawn at: change it only for a picture drawn at another (3D characters go off it otherwise).", .ru = "Камера локации смотрит под тем наклоном, под которым нарисована картинка: меняйте его только для картинки с другим наклоном (иначе 3D-персонажи с неё съедут)." };
pub const cam_tilt: Msg = .{ .en = "Isometric rotation, °", .ru = "Поворот изометрии, °" };
pub const cam_front: Msg = .{ .en = "Front plane", .ru = "Передняя плоскость" };
pub const cam_back: Msg = .{ .en = "Back plane", .ru = "Задняя плоскость" };
pub const bg_cfg_hint: Msg = .{ .en = "Background .cfg (the exe reads it): how the depth picture becomes floor height (gscale, g0, g1) and the planes; a battle's eye and target.", .ru = "Фон .cfg (его читает exe): как картинка глубины становится высотой пола (gscale, g0, g1) и плоскости; у боя — глаз и цель камеры." };
pub const in_override: Msg = .{ .en = "overridden", .ru = "переопределено" };
pub const in_archetype: Msg = .{ .en = "from the archetype", .ru = "из архетипа" };
pub const in_vars: Msg = .{ .en = "start (.var)", .ru = "старт (.var)" };
pub const host_fighter: Msg = .{ .en = "Fighter", .ru = "Боец" };
pub const host_actor: Msg = .{ .en = "Actor", .ru = "Актёр" };
pub const host_weapon: Msg = .{ .en = "Weapon", .ru = "Оружие" };
pub const host_item: Msg = .{ .en = "Item", .ru = "Предмет" };
pub const host_level: Msg = .{ .en = "Level", .ru = "Уровень" };
pub const host_object: Msg = .{ .en = "Object", .ru = "Объект" };
pub const host_own: Msg = .{ .en = "Its own variables", .ru = "Свои переменные" };
pub const lv_title: Msg = .{ .en = "Variables", .ru = "Переменные" };
pub const lv_hint: Msg = .{ .en = "The level's flags and counters: the value is what it starts with (variables\\<level>.var, before init()).", .ru = "Флаги и счётчики уровня: значение — стартовое (variables\\<уровень>.var, до init())." };
pub const lv_in_init: Msg = .{ .en = "init() sets it to {s} (that wins) · {d}×", .ru = "init() ставит {s} (это главнее) · {d}×" };
pub const at_fonts: Msg = .{ .en = "Fonts", .ru = "Шрифты" };
pub const fn_hint: Msg = .{ .en = "A bitmap font of the game: two colours, the letter and the background. _1 is the base set; _N_xx a language's letters over it (the Russian edition: _5_cz, cp1251).", .ru = "Растровый шрифт игры: два цвета — буква и фон. _1 — основной набор; _N_xx — буквы языка поверх него (русская версия: _5_cz, cp1251)." };
pub const fn_from_ttf: Msg = .{ .en = "From a TrueType font…", .ru = "Из шрифта TTF…" };
pub const fn_char: Msg = .{ .en = "Character {X:0>2} «{c}»", .ru = "Символ {X:0>2} «{c}»" };
pub const fn_narrower: Msg = .{ .en = "Narrower", .ru = "Уже" };
pub const fn_wider: Msg = .{ .en = "Wider", .ru = "Шире" };
pub const fn_make: Msg = .{ .en = "Make this character", .ru = "Создать символ" };
pub const fn_size: Msg = .{ .en = "{d}×{d} px (the game steps width - 1)", .ru = "{d}×{d} px (игра сдвигает на ширину - 1)" };
pub const st_font_made: Msg = .{ .en = "{d} characters drawn from the TrueType font (Ctrl+Z takes them back)", .ru = "Символов нарисовано из TTF: {d} (Ctrl+Z вернёт)" };
pub const at_effects: Msg = .{ .en = "Effects", .ru = "Эффекты" };
pub const ef_hint: Msg = .{ .en = "{d} frames (the .dsc lists them; each a texture beside it). Weapons name the effect in their class (effect).", .ru = "Кадров: {d} (их перечисляет .dsc; каждый — текстура рядом). Оружие называет эффект в своём классе (effect)." };
pub const ef_add: Msg = .{ .en = "Frame from PNG", .ru = "Кадр из PNG" };
pub const st_frame_added: Msg = .{ .en = "Frame added after the last", .ru = "Кадр добавлен в конец" };
pub const spr_depth_hint: Msg = .{ .en = "Depth (.spz): what hides heroes behind the animation. PNG out and in only: yellow is the high byte, blue the low one (comes back exact).", .ru = "Глубина (.spz): что прячет героев за анимацией. Только выгрузка/загрузка PNG: жёлтый — старший байт, синий — младший (возвращается точно)." };
pub const cm_canvas: Msg = .{ .en = "Empty canvas · right-click", .ru = "Пустое место · правый клик" };
pub const cm_add_object: Msg = .{ .en = "Add object", .ru = "Добавить объект" };
pub const cm_container: Msg = .{ .en = "Container (items)", .ru = "Ящик (предметы)" };
pub const cm_add_trigger: Msg = .{ .en = "Add trigger area", .ru = "Добавить зону-триггер" };
pub const cm_add_exit: Msg = .{ .en = "Add exit", .ru = "Добавить выход" };
pub const cm_paste: Msg = .{ .en = "Paste here", .ru = "Вставить сюда" };
pub const cm_center: Msg = .{ .en = "Center view here", .ru = "Центрировать вид здесь" };
pub const cm_edit_contents: Msg = .{ .en = "Edit contents…", .ru = "Изменить содержимое…" };
pub const cm_reveal: Msg = .{ .en = "Reveal in script", .ru = "Показать в скрипте" };
pub const cm_refs: Msg = .{ .en = "Find references", .ru = "Найти упоминания" };
pub const cm_no_refs: Msg = .{ .en = "No script names it in quotes", .ru = "Ни один скрипт не называет его в кавычках" };
pub const cm_duplicate: Msg = .{ .en = "Duplicate", .ru = "Дублировать" };
pub const cm_copy: Msg = .{ .en = "Copy", .ru = "Копировать" };
pub const cm_rename: Msg = .{ .en = "Rename…", .ru = "Переименовать…" };
pub const cm_focus: Msg = .{ .en = "Focus selection", .ru = "Показать выбранное" };
pub const cm_hide: Msg = .{ .en = "Hide in editor", .ru = "Скрыть в редакторе" };
pub const cm_show: Msg = .{ .en = "Show in editor", .ru = "Показать в редакторе" };
pub const cm_lock: Msg = .{ .en = "Lock in editor", .ru = "Заблокировать в редакторе" };
pub const cm_unlock: Msg = .{ .en = "Unlock in editor", .ru = "Разблокировать в редакторе" };
pub const cm_delete: Msg = .{ .en = "Delete", .ru = "Удалить" };
pub const cm_k_box: Msg = .{ .en = "Container", .ru = "Ящик" };
pub const cm_k_enemy: Msg = .{ .en = "Enemy", .ru = "Враг" };
pub const cm_k_hero: Msg = .{ .en = "Hero", .ru = "Герой" };
pub const cm_k_neutral: Msg = .{ .en = "Object", .ru = "Объект" };
pub const cm_k_prop: Msg = .{ .en = "Prop", .ru = "Декорация" };
pub const cm_k_item: Msg = .{ .en = "Item", .ru = "Предмет" };
pub const cm_k_actor: Msg = .{ .en = "Character", .ru = "Персонаж" };
pub const cm_k_area: Msg = .{ .en = "Area", .ru = "Зона" };
pub const st_obj_copied: Msg = .{ .en = "{s} copied: paste it on the map (right click) or with Cmd/Ctrl+V", .ru = "{s} скопирован: вставьте на карте (правый клик) или Cmd/Ctrl+V" };
pub const st_cant_copy: Msg = .{ .en = "{s} cannot be copied (enemies, boxes, obstacles and props can)", .ru = "{s} не копируется (копируются враги, ящики, препятствия и декорации)" };
pub const st_paste_kind: Msg = .{ .en = "This goes into a level of the other kind (battle / location)", .ru = "Это вставляется в уровень другого вида (бой / локация)" };
pub const st_locked: Msg = .{ .en = "{s} is locked in the editor (right click: unlock)", .ru = "{s} заблокирован в редакторе (правый клик — разблокировать)" };
pub const menu_hero_drop: Msg = .{ .en = "Delete the character (and its script lines)", .ru = "Удалить персонажа (и строки скриптов)" };
pub const hero_hidden: Msg = .{ .en = "hidden", .ru = "скрыт" };
pub const st_hero_removed: Msg = .{ .en = "{s} deleted: its .hro, weapons and script lines (Ctrl+Z brings them back)", .ru = "{s} удалён(а): .hro, оружие и строки скриптов (Ctrl+Z вернёт)" };
pub const st_hero_removed_scene: Msg = .{ .en = "{s} deleted; scene {s}, started here, still places it — delete its trigger or edit the scene", .ru = "{s} удалён(а); сценка {s}, которую запускает этот уровень, всё ещё ставит персонажа — удалите её триггер или поправьте сценку" };
pub const st_hero_referenced: Msg = .{ .en = "{s} not deleted: {s} names it in a line that is more than one call — edit that line first", .ru = "{s} не удалён(а): {s} упоминает персонажа не отдельной строкой-вызовом — сначала поправьте эту строку" };
pub const lp_actor_scale: Msg = .{ .en = "Character size: {d:.2} ({d:.0}%)", .ru = "Размер персонажей: {d:.2} ({d:.0}%)" };
pub const lp_exit_unreachable: Msg = .{ .en = "Its walk-to point is on floor cut off from the level or on a ladder/pontoon step (the hero is taken along it instead). Drag the area a little with the hand: the point moves onto plain floor.", .ru = "Точка подхода стоит на отрезанном куске пола или на ступеньке лестницы/понтона (герой уедет по ней вместо выхода). Сдвиньте область рукой хотя бы немного — точка переедет на обычный пол." };
pub const lp_depth_fit: Msg = .{ .en = "Fit to the game's camera", .ru = "Подогнать под камеру игры" };
pub const lp_depth_fit_hint: Msg = .{ .en = "A depth made elsewhere (a render, a depth estimator) has its own scale: the original game hides feet in a floor it takes for nearer. This maps it so the walkable floor is where the game's camera puts it.", .ru = "Глубина, сделанная в другой программе (рендер, нейросеть), в своём масштабе: оригинал прячет ноги в пол, который считает ближе. Кнопка пересчитывает её так, чтобы проходимый пол был там, где его ждёт камера игры." };
pub const st_depth_fit: Msg = .{ .en = "Depth fitted to the game's camera (the floor was off by {d:.1} steps); Done and Save write it", .ru = "Глубина подогнана под камеру игры (пол расходился на {d:.1} шага); «Готово» и «Сохранить» запишут её" };
pub const lv_new_battle: Msg = .{ .en = "New battle from this one…", .ru = "Новый бой из этого…" };
pub const lv_new_battle_hint: Msg = .{ .en = "Copies the picture, depth, camera, battle grid, lights and the heroes' places; enemies start empty (add them with the right button). Name as the game's: lower-case latin, digits, two characters then __ (01__port_ambush). Enter makes it.", .ru = "Копирует картинку, глубину, камеру, боевую сетку, свет и места героев; врагов нет (добавьте правой кнопкой). Имя как у игры: строчная латиница, цифры, __ после двух знаков (01__port_ambush). Enter — создать." };
pub const st_battle_failed: Msg = .{ .en = "Battle {s} not made: {t} (a name: 6-24 lower-case letters, digits, _, as NN__name; a free folder)", .ru = "Бой {s} не создан: {t} (имя: 6-24 строчные латинские буквы, цифры, _, вида NN__имя; папка свободна)" };
pub const st_battle_made: Msg = .{ .en = "Battle {s} made from {s} (written to disk). Add enemies; a location's trigger with LEVEL_Load(\"{s}\") starts it, the game returns there after.", .ru = "Бой {s} создан из {s} (уже на диске). Добавьте врагов; запускает его триггер локации с LEVEL_Load(\"{s}\"), после боя игра вернёт туда." };
pub const lp_grid: Msg = .{ .en = "Battle grid", .ru = "Боевая сетка" };
pub const lp_grid_free: Msg = .{ .en = "Free", .ru = "Свободна" };
pub const lp_grid_blocked: Msg = .{ .en = "Blocked", .ru = "Занята" };
pub const lp_grid_hint: Msg = .{ .en = "The brush makes cells free or blocked (where fighters can stand and walk). Below: where the grid lies over the picture (.cm), to fit a new background.", .ru = "Кисть делает клетки свободными или занятыми (где бойцы могут стоять и ходить). Ниже — где лежит сетка поверх картинки (.cm), чтобы подогнать под новый фон." };
pub const lp_grid_x: Msg = .{ .en = "Centre X: {d:.1}", .ru = "Центр X: {d:.1}" };
pub const lp_grid_y: Msg = .{ .en = "Centre Y: {d:.1}", .ru = "Центр Y: {d:.1}" };
pub const lp_grid_z: Msg = .{ .en = "Floor Z: {d:.1}", .ru = "Пол Z: {d:.1}" };
pub const lp_grid_turn: Msg = .{ .en = "Turn: {d:.2}", .ru = "Поворот: {d:.2}" };
pub const lp_grid_cell: Msg = .{ .en = "Cell: {d:.1}", .ru = "Клетка: {d:.1}" };
pub const lp_grid_w: Msg = .{ .en = "Columns: {d}", .ru = "Столбцов: {d}" };
pub const lp_grid_h: Msg = .{ .en = "Rows: {d}", .ru = "Строк: {d}" };
pub const lp_tiles_clamped: Msg = .{ .en = "{d} PlaceActor tile(s) off the smaller grid moved onto its edge (first: {s}) — check where they stand", .ru = "{d} клеток PlaceActor вне уменьшенной сетки перенесены на её край (первая: {s}) — проверьте, где они стоят" };
pub const lp_step_grid: Msg = .{ .en = "battle grid (.cm)", .ru = "боевая сетка (.cm)" };
pub const lp_grid_split_w: Msg = .{ .en = "Split into columns: {d}", .ru = "Разбить на столбцы: {d}" };
pub const lp_grid_split_h: Msg = .{ .en = "Split into rows: {d}", .ru = "Разбить на строки: {d}" };
pub const lp_cam_tool: Msg = .{ .en = "Camera", .ru = "Камера" };
pub const lp_cam_tool_hint: Msg = .{ .en = "Drag the rings in the middle of the view: green turns the camera round its aim (yellow cross), red raises or lowers it, blue banks it; the centre square moves it. The wheel over the gizmo brings it nearer, Shift+wheel changes the view angle; elsewhere the wheel zooms the view. Written into initCamera() when you let go.", .ru = "Тяните кольца в центре: зелёное вращает камеру вокруг точки взгляда (жёлтый крест), красное поднимает и опускает, синее наклоняет вбок; квадрат в центре сдвигает камеру. Колесо над гизмо — ближе/дальше, Shift+колесо — угол обзора; в стороне колесо масштабирует вид. В initCamera() пишется, когда отпускаете." };
pub const lp_camera: Msg = .{ .en = "Battle camera", .ru = "Камера боя" };
pub const lp_camera_hint: Msg = .{ .en = "initCamera() of the battle script: eye — where the camera stands, target — where it looks, fov — field of view, floor_z — floor height. Change it when the picture was rendered from another angle; the grid and fighters follow. Smaller cells also make the models smaller (xSize/350).", .ru = "initCamera() в скрипте боя: eye — где стоит камера, target — куда смотрит, fov — угол обзора, floor_z — высота пола. Меняйте, если картинка снята под другим углом; сетка и бойцы пересчитываются. Мельче клетки — мельче и модели (xSize/350)." };
pub const code_tasks: Msg = .{ .en = "Add…", .ru = "Добавить…" };
pub const code_format: Msg = .{ .en = "Format", .ru = "Форматировать" };
pub const ct_place: Msg = .{ .en = "Place an actor", .ru = "Поставить актёра" };
pub const ct_level: Msg = .{ .en = "Go to a location / start a battle", .ru = "Перейти в локацию / начать бой" };
pub const ct_scene: Msg = .{ .en = "Start a scene", .ru = "Запустить сценку" };
pub const ct_join: Msg = .{ .en = "A hero joins the party", .ru = "Герой вступает в отряд" };
pub const ct_area: Msg = .{ .en = "When a hero enters an area", .ru = "Когда герой заходит в область" };
pub const ct_heroes: Msg = .{ .en = "Place the party", .ru = "Поставить отряд" };
pub const ct_show: Msg = .{ .en = "Show an object", .ru = "Показать объект" };
pub const ct_hide: Msg = .{ .en = "Hide an object", .ru = "Скрыть объект" };
pub const ct_delete: Msg = .{ .en = "Delete an object", .ru = "Удалить объект" };
pub const ct_sound: Msg = .{ .en = "Play a sound", .ru = "Проиграть звук" };

pub const lt_open: Msg = .{ .en = "Debug", .ru = "Отладка" };
pub const lt_done: Msg = .{ .en = "Level run: {d} ticks, {d} events", .ru = "Уровень прогнан: {d} тиков, {d} событий" };
pub const lt_title: Msg = .{ .en = "Debug run ({d} events)", .ru = "Прогон ({d} событий)" };
pub const lt_events: Msg = .{ .en = "What happened (newest first)", .ru = "Что произошло (новое сверху)" };
pub const lt_cmds: Msg = .{ .en = "Player:", .ru = "Игрок:" };
pub const lt_run: Msg = .{ .en = "Run", .ru = "Прогнать" };
pub const lt_k_input: Msg = .{ .en = "player", .ru = "игрок" };
pub const lt_k_var: Msg = .{ .en = "var", .ru = "перем." };
pub const lt_k_object: Msg = .{ .en = "object", .ru = "объект" };
pub const lt_k_scene: Msg = .{ .en = "scene", .ru = "сцена" };
pub const lt_k_command: Msg = .{ .en = "cmd", .ru = "команда" };
pub const lt_k_line: Msg = .{ .en = "line", .ru = "реплика" };
pub const lt_k_sound: Msg = .{ .en = "sound", .ru = "звук" };
pub const lt_k_music: Msg = .{ .en = "music", .ru = "музыка" };
pub const lt_k_level: Msg = .{ .en = "level", .ru = "уровень" };
pub const props: Msg = .{ .en = "Properties", .ru = "Свойства" };
pub const p_name: Msg = .{ .en = "Name", .ru = "Имя" };
pub const p_file: Msg = .{ .en = "File", .ru = "Файл" };
pub const p_format: Msg = .{ .en = "Format", .ru = "Формат" };
pub const p_size: Msg = .{ .en = "Size", .ru = "Размер" };
pub const p_frames: Msg = .{ .en = "Frames", .ru = "Кадры" };
pub const p_actions: Msg = .{ .en = "Actions", .ru = "Действия" };
pub const p_new: Msg = .{ .en = "Add new", .ru = "Добавить новое" };
pub const fn_glyphs: Msg = .{ .en = "Characters", .ru = "Символы" };
pub const st_packed: Msg = .{ .en = "Mod packed: {d} files into {s} (README.txt says how to install)", .ru = "Мод упакован: {d} файлов в {s} (как ставить — в README.txt)" };
pub const s_pick_viewer: Msg = .{ .en = "Choose…", .ru = "Выбрать…" };
pub const s_package: Msg = .{ .en = "Package mod…", .ru = "Упаковать мод…" };
pub const s_package_hint: Msg = .{ .en = "The files the editor saved in this folder (its history, .opengorky-history) go into the chosen folder, with README.txt and clear-cache.bat for the original game. Changes made outside the editor are not seen.", .ru = "Файлы, которые редактор сохранил в этой папке (его история, .opengorky-history), копируются в выбранную папку, с README.txt и clear-cache.bat для оригинальной игры. Изменения, сделанные не в редакторе, не учитываются." };
pub const lt_k_turn: Msg = .{ .en = "turn", .ru = "ход" };
pub const lt_k_battle: Msg = .{ .en = "battle", .ru = "бой" };
pub const lt_battle_auto: Msg = .{ .en = "Both sides played by the AI, to the end of the battle.", .ru = "Обе стороны ходят за ИИ, до конца боя." };
pub const vid_no_player: Msg = .{ .en = "Cannot play it here: no FFmpeg (built in or the ffmpeg program).", .ru = "Здесь не проиграть: нет FFmpeg (встроенного или программы ffmpeg)." };
pub const vid_play: Msg = .{ .en = "Play", .ru = "Смотреть" };
pub const code_find: Msg = .{ .en = "Find in the file", .ru = "Найти в файле" };
pub const code_matches: Msg = .{ .en = "{d} found", .ru = "найдено: {d}" };
pub const cm_open_entry: Msg = .{ .en = "Open {s}", .ru = "Открыть {s}" };
pub const st_actor_deleted: Msg = .{ .en = "{s} deleted with its .act (Ctrl+Z brings it back)", .ru = "{s} удалён вместе с его .act (Ctrl+Z вернёт)" };
pub const show_rendered: Msg = .{ .en = "Preview", .ru = "Превью" };
pub const st_render_failed: Msg = .{ .en = "The level as in the game could not be drawn: {t}", .ru = "Не получилось нарисовать уровень как в игре: {t}" };
pub const c_flash: Msg = .{ .en = "Muzzle flash", .ru = "Вспышка выстрела" };
pub const flash_none: Msg = .{ .en = "none (the exe gives one only to pistol, revolver, rifle, shotgun, uzi, nitrogen gun — by classic_id)", .ru = "нет (exe даёт её только пистолету, револьверу, винтовке, дробовику, узи, азотной пушке — по classic_id)" };
pub const flash_of: Msg = .{ .en = "{s} on {s}, {d} ticks", .ru = "{s} на {s}, {d} тиков" };
pub const flash_note: Msg = .{ .en = "Fixed in the exe for this classic_id (0x48bda2…0x48ce33): offset {d:.0}, {d:.0}, {d:.0}, scale {d:.1}, mesh chaingun.msh. Its frames are the effect's: edit them there; both games use them.", .ru = "Задано в exe для этого classic_id (0x48bda2…0x48ce33): смещение {d:.0}, {d:.0}, {d:.0}, масштаб {d:.1}, меш chaingun.msh. Кадры — эффекта: правьте их там, их читают обе игры." };
pub const flash_edit: Msg = .{ .en = "Edit the flash effect", .ru = "Править эффект вспышки" };
pub const adj_default: Msg = .{ .en = "Engine default", .ru = "Значение движка" };
pub const adj_title: Msg = .{ .en = "Engine settings", .ru = "Настройки движка" };
pub const adj_hint: Msg = .{ .en = "adjust.kdt in the game folder: the engine's tuning values (attacks, explosions, particles, monsters, menus, sound). The original game reads it at start too, so changes here work in both.", .ru = "adjust.kdt в папке игры: настройки движка (атаки, взрывы, частицы, монстры, меню, звук). Оригинальная игра читает его при запуске, так что правки работают и там, и здесь." };
pub const adj_hint_og: Msg = .{ .en = "The values the engine reads by name (its defaults: the shipped adjust.kdt's). A changed one is written into the settings block (src/rules/settings.ogs, made at the first change); back to its default, it is taken out.", .ru = "Значения, которые движок читает по имени (по умолчанию — как в adjust.kdt игры). Изменённое пишется в блок settings (src/rules/settings.ogs, создаётся при первом изменении); возвращённое к значению движка — убирается." };
pub const adj_note_og: Msg = .{ .en = "Enter applies (one undo step); Save writes rules/settings.ogs. A colour is r,g,b.", .ru = "Enter применяет (один шаг отмены); «Сохранить» записывает rules/settings.ogs. Цвет — r,g,b." };
pub const adj_migrate: Msg = .{ .en = "This project has no rules/settings.ogs (made by an older version): for want of it the port still reads its adjust.kdt (dat/og's, else the game's). Move the values into rules/settings.ogs to edit them here; from then on no adjust.kdt is read.", .ru = "В проекте нет rules/settings.ogs (создан старой версией): пока его нет, порт читает adjust.kdt проекта (из dat/og, иначе игры). Перенесите значения в rules/settings.ogs, чтобы править их здесь; после этого adjust.kdt не читается." };
pub const adj_migrate_do: Msg = .{ .en = "Move into rules/settings.ogs", .ru = "Перенести в rules/settings.ogs" };
pub const adj_search: Msg = .{ .en = "Search a value by name", .ru = "Поиск по имени" };
pub const adj_none: Msg = .{ .en = "No adjust.kdt in the game folder.", .ru = "В папке игры нет adjust.kdt." };
pub const adj_changed: Msg = .{ .en = "changed", .ru = "изменено" };
pub const adj_type: Msg = .{ .en = "Type", .ru = "Тип" };
pub const adj_value: Msg = .{ .en = "Value", .ru = "Значение" };
pub const adj_saved: Msg = .{ .en = "In the file", .ru = "В файле" };
pub const adj_reset: Msg = .{ .en = "Back to the file's value", .ru = "Вернуть значение из файла" };
pub const adj_note: Msg = .{ .en = "Enter applies; Save writes adjust.kdt (encrypted as the game keeps it). A colour is r,g,b.", .ru = "Enter применяет; «Сохранить» записывает adjust.kdt (зашифрованным, как его хранит игра). Цвет — r,g,b." };
pub const st_adj_bad: Msg = .{ .en = "«{s}» is not a {s} value", .ru = "«{s}» — не значение типа {s}" };
pub const adj_about: Msg = .{ .en = "What it does", .ru = "Что делает" };
pub const adj_exe_only: Msg = .{ .en = "exe only", .ru = "только exe" };
pub const adj_not_port: Msg = .{ .en = "Not used by the port: only the original exe reads it (meaning not documented here).", .ru = "Порт не использует: его читает только оригинальный exe (смысл здесь не описан)." };
pub const adj_limits: Msg = .{ .en = "The original exe crashes on more than 1024 lines (no bounds check) and needs each line under 512 characters: Save refuses a file past that ({d} lines now).", .ru = "Оригинальный exe падает, если строк больше 1024 (нет проверки границ), и строка должна быть короче 512 символов: «Сохранить» откажет в таком файле (сейчас строк: {d})." };
pub const adj_dat_warn: Msg = .{ .en = "adjust.dat is in the game folder: the original exe reads it instead of adjust.kdt, so edits here will not reach the original. Delete or rename it.", .ru = "В папке игры есть adjust.dat: оригинальный exe читает его вместо adjust.kdt, и правки отсюда до него не дойдут. Удалите или переименуйте его." };
pub const code_unknown: Msg = .{ .en = "line {d}: {s}() — neither the port nor the original exe registers it and no game script defines it: the call does nothing", .ru = "строка {d}: {s}() — ни порт, ни оригинальный exe её не регистрируют, и ни один скрипт игры её не определяет: вызов ничего не делает" };
pub const code_unknown_scene: Msg = .{ .en = "line {d}: {s} — not a scene command of the exe (its table 0x4763f0): the exe reports a syntax error, the port skips the line", .ru = "строка {d}: {s} — не команда сценки exe (таблица 0x4763f0): exe сообщает о синтаксической ошибке, порт пропускает строку" };
pub const code_t_unknown: Msg = .{ .en = "unknown: nothing registers it", .ru = "неизвестно: никто не регистрирует" };
pub const code_port_only_call: Msg = .{ .en = "line {d}: {s}() — port only: the original exe does not register it, so in this Classic project the call does nothing there", .ru = "строка {d}: {s}() — только в порте: оригинальный exe её не регистрирует, и в этом Classic-проекте вызов там ничего не делает" };
pub const code_port_only: Msg = .{ .en = "port only: the original exe does not have it", .ru = "только в порте: в оригинальном exe нет" };
pub const code_m_goto: Msg = .{ .en = "Jump to definition", .ru = "Перейти к определению" };
pub const code_m_uses: Msg = .{ .en = "Find usages", .ru = "Найти использования" };
pub const code_m_paste: Msg = .{ .en = "Paste", .ru = "Вставить" };
pub const code_goto_pick: Msg = .{ .en = "Go to", .ru = "Перейти" };
pub const code_usages: Msg = .{ .en = "Usages {s} ({d})", .ru = "Использования {s} ({d})" };
pub const code_usages_tab: Msg = .{ .en = "Usages", .ru = "Использования" };
pub const code_usages_none: Msg = .{ .en = "Right-click a word or string: Find usages (Shift+F12) lists where the game's scripts and rules files use it.", .ru = "Правый клик по слову или строке: «Найти использования» (Shift+F12) покажет, где их используют скрипты и файлы правил игры." };
pub const code_bad_args: Msg = .{ .en = "line {d}: {s}() — too few arguments (see its parameters)", .ru = "строка {d}: {s}() — слишком мало аргументов (см. её параметры)" };
pub const code_missing: Msg = .{ .en = "line {d}: \"{s}\" — no such file in the game's archives", .ru = "строка {d}: \"{s}\" — такого файла нет в архивах игры" };
pub const code_rules_row: Msg = .{ .en = "{s}(…) row: its page", .ru = "Строка {s}(…): её страница" };
pub const st_rules_call: Msg = .{ .en = "{s}: {s}", .ru = "{s}: {s}" };
pub const st_hist_back: Msg = .{ .en = "No place to go back to", .ru = "Назад вернуться некуда" };
pub const st_hist_forward: Msg = .{ .en = "No place to go forward to", .ru = "Вперёд идти некуда" };
pub const st_goto_none: Msg = .{ .en = "Nothing named \"{s}\" found", .ru = "Ничего с именем \"{s}\" не найдено" };
pub const st_goto_file: Msg = .{ .en = "{s}: the editor has no page for this file", .ru = "{s}: для этого файла в редакторе нет страницы" };
pub const code_t_rules: Msg = .{ .en = "rules call (a table's row)", .ru = "вызов правил (строка таблицы)" };
pub const code_t_field: Msg = .{ .en = "field of {s}: {s}", .ru = "поле {s}: {s}" };
pub const code_field_opt: Msg = .{ .en = "{s}: {s}, may be left out — {s}", .ru = "{s}: {s}, можно не писать — {s}" };
pub const code_optional: Msg = .{ .en = "left out: the built-in row's (its class's) value", .ru = "не написано: значение встроенной строки (строки класса)" };
pub const code_k_default: Msg = .{ .en = "Default", .ru = "По умолчанию" };
pub const code_k_means: Msg = .{ .en = "Means", .ru = "Значит" };
pub const code_required: Msg = .{ .en = "required", .ru = "обязательно" };
pub const code_field_line: Msg = .{ .en = "{s}: {s} = {s} — {s}", .ru = "{s}: {s} = {s} — {s}" };
pub const code_rules_count: Msg = .{ .en = "{d} rules calls: this file's (all of them when searching by the call or word at the cursor). Each field: type = default — what it is. A click inserts the call.", .ru = "Вызовов правил: {d}; показаны вызовы этого файла (все — при поиске по вызову или слову у курсора). Поле: тип = умолчание — что это. Щелчок вставляет вызов." };
pub const code_class_other: Msg = .{ .en = "every class without a row of its own: an ordinary fighter", .ru = "любой класс без своей строки: обычный боец" };
pub const code_in_game: Msg = .{ .en = "{s} — in this game: {s}", .ru = "{s} — в этой игре: {s}" };
pub const code_none_in_game: Msg = .{ .en = "none", .ru = "нет" };
pub const code_t_scene: Msg = .{ .en = "scene command", .ru = "команда сценки" };
pub const s_viewer: Msg = .{ .en = "Port (viewer)", .ru = "Порт (viewer)" };
pub const s_viewer_auto: Msg = .{ .en = "auto (next to the editor)", .ru = "авто (рядом с редактором)" };
pub const s_viewer_clear: Msg = .{ .en = "Auto", .ru = "Авто" };
pub const s_viewer_hint: Msg = .{ .en = "The opengorky-viewer program (on macOS also OpenGorky.app) that Play runs.", .ru = "Программа opengorky-viewer (на macOS и OpenGorky.app), которую запускает «Играть»." };
pub const s_target: Msg = .{ .en = "Compatibility", .ru = "Совместимость" };
pub const s_game_og_hint: Msg = .{ .en = "An OpenGorky project: the game's own files are read from the installed game (the manifest's game, $OPENGORKY_GAME over it); the project never changes them", .ru = "Проект OpenGorky: файлы самой игры читаются из установленной игры (game в манифесте, $OPENGORKY_GAME важнее); проект их не меняет" };
pub const sb_mode_classic: Msg = .{ .en = "Original (Classic)", .ru = "Оригинал (Classic)" };
pub const sb_mode_og: Msg = .{ .en = "Mod: {s}", .ru = "Мод: {s}" };
pub const s_format_classic: Msg = .{ .en = "Classic: the original exe and the port", .ru = "Classic: оригинальный exe и порт" };
pub const s_format_og: Msg = .{ .en = "OpenGorky (OG Script): the port only", .ru = "OpenGorky (OG Script): только порт" };
pub const s_target_hint: Msg = .{ .en = "The project's format (opengorky.mod in the game folder; none: Classic). Classic keeps what the original exe reads: imported models and textures stay within its limits (1024 vertices and 2048 triangles a part, textures up to 256, 4 bits a channel). Larger ones need an OpenGorky project.", .ru = "Формат проекта (opengorky.mod в папке игры; нет файла — Classic). Classic держит то, что читает оригинальный exe: импортируемые модели и текстуры в его пределах (1024 вершины и 2048 треугольников на часть, текстуры до 256, 4 бита на канал). Для больших нужен проект OpenGorky." };
pub const s_target_port_warn: Msg = .{ .en = "OpenGorky project: OG Script texts in src/ over the installed game, which the original exe can't play. The editor writes only its src/ texts; the installed game stays as it is.", .ru = "Проект OpenGorky: тексты OG Script в src/ поверх установленной игры, её оригинальный exe не играет. Редактор пишет только тексты в src/, установленная игра не меняется." };
pub const wp_fx_as: Msg = .{ .en = "Strike effects as (fx_as)", .ru = "Эффекты удара как (fx_as)" };
pub const glb_classic: Msg = .{ .en = "past the original exe's limits, which a Classic project keeps; convert the game to an OpenGorky project (gorky-tool convert) for models without them", .ru = "за пределами оригинального exe, которые держит проект Classic; сконвертируйте игру в проект OpenGorky (gorky-tool convert) для моделей без них" };
pub const st_engine_too_new: Msg = .{ .en = "{s} needs OpenGorky {d}.{d} or newer: not opened", .ru = "{s} требует OpenGorky {d}.{d} или новее: не открыт" };
pub const s_build_pkg_hint: Msg = .{ .en = "For players: \"Build package\" packs dist/<id>.ogp (no test kit, nothing started); they put it into the game's mods/ folder and choose it in the launcher.", .ru = "Для игроков: «Собрать пакет» собирает dist/<id>.ogp (без тестового набора, ничего не запускает); игрок кладёт его в папку mods/ игры и выбирает в лаунчере." };
pub const s_build_pkg: Msg = .{ .en = "Build package", .ru = "Собрать пакет" };
pub const s_reveal_pkg: Msg = .{ .en = if (@import("builtin").os.tag == .macos) "Show in Finder" else "Show in folder", .ru = if (@import("builtin").os.tag == .macos) "Показать в Finder" else "Показать в папке" };
pub const st_og_art: Msg = .{ .en = " — OpenGorky limits: any vertex count a part, textures 32-bit argb8888 up to 4096 (power-of-two sides, mip-mapped); the original exe can't load them", .ru = " — пределы OpenGorky: любое число вершин в части, текстуры 32-битные argb8888 до 4096 (стороны — степени двойки, с mip-картами); оригинальный exe их не загрузит" };
pub const st_og_video: Msg = .{ .en = " — OpenGorky: kept as is (any format FFmpeg plays: mp4, mkv, webm, mov, asf; up to 4K), scaled to the window; the original exe can't play it", .ru = " — OpenGorky: файл как есть (любой формат FFmpeg: mp4, mkv, webm, mov, asf; до 4K), масштабируется по окну; оригинальный exe его не проиграет" };
pub const st_viewer_missing: Msg = .{ .en = "The port {s} isn't there — choose where it is", .ru = "Порта {s} нет на месте — укажите, где он" };
pub const st_no_viewer: Msg = .{ .en = "The port (OpenGorky) isn't beside the editor — choose where it is", .ru = "Порта (OpenGorky) нет рядом с редактором — укажите, где он" };
pub const st_conv_unreadable: Msg = .{ .en = "Not converted: {s} isn't a video or sound file FFmpeg can read", .ru = "Не перекодировано: {s} — не видео или звук, который читает FFmpeg" };
pub const st_conv_codec: Msg = .{ .en = "Not converted: {s} uses a codec FFmpeg can't decode", .ru = "Не перекодировано: в {s} кодек, который FFmpeg не декодирует" };
pub const st_conv_no_video: Msg = .{ .en = "Not converted: {s} has no video", .ru = "Не перекодировано: в {s} нет видео" };
pub const st_conv_no_audio: Msg = .{ .en = "Not converted: {s} has no sound", .ru = "Не перекодировано: в {s} нет звука" };
pub const st_conv_canceled: Msg = .{ .en = "Converting {s} canceled", .ru = "Перекодирование {s} отменено" };

// Campaign page (campaignpage.zig): the rules' Campaign row and the manifest's title.
pub const camp_title: Msg = .{ .en = "Game", .ru = "Игра" };
pub const camp_hint: Msg = .{ .en = "The game block (src/game.ogs): what a new game starts with, the party, the videos and music, experience, the battle formulas and the fighter states.", .ru = "Блок игры (src/game.ogs): с чего начинается новая игра, отряд, видео и музыка, опыт, формулы боя и состояния бойцов." };
pub const ui_title: Msg = .{ .en = "Interface", .ru = "Интерфейс" };
pub const ui_hint: Msg = .{ .en = "The interface (src/ui.ogs): the main menu, the sliding windows, the bottom panel's buttons, the interface's sounds, effects and sprites.", .ru = "Интерфейс (src/ui.ogs): главное меню, выезжающие окна, кнопки нижней панели, звуки, эффекты и спрайты интерфейса." };
pub const ui_sec_canvas: Msg = .{ .en = "Canvas", .ru = "Холст" };
pub const ui_canvas_size: Msg = .{ .en = "Size", .ru = "Размер" };
pub const ui_canvas_note: Msg = .{ .en = "The logical frame the world and the interface are drawn in, scaled to the window (640×480 the exe's). Larger: more of the levels shows, the interface keeps its pixels — its 640×480 box (the panel at its bottom) stands at the bottom centre; the menu, the inventory and the videos stay 640×480.", .ru = "Логический кадр, в котором рисуются мир и интерфейс, масштабируется под окно (640×480 — как в exe). Больше — видно больше уровня, интерфейс сохраняет пиксели: его прямоугольник 640×480 (панель внизу него) стоит внизу по центру; меню, инвентарь и видео остаются 640×480." };
pub const ui_sec_menu: Msg = .{ .en = "Main menu", .ru = "Главное меню" };
pub const ui_sec_sounds: Msg = .{ .en = "Interface sounds", .ru = "Звуки интерфейса" };
pub const ui_sec_effects: Msg = .{ .en = "Interface effects", .ru = "Эффекты интерфейса" };
pub const ui_sec_assets: Msg = .{ .en = "Sprites and fonts", .ru = "Спрайты и шрифты" };
pub const g_sec_feel: Msg = .{ .en = "Motion and sound", .ru = "Движение и звук" };
pub const g_sub_sound: Msg = .{ .en = "Sound by distance", .ru = "Звук по расстоянию" };
pub const g_sec_effects: Msg = .{ .en = "Effects", .ru = "Эффекты" };
pub const g_effects_note: Msg = .{ .en = "The engine's effect kinds, one value each for every weapon using it (the flame of the flamethrower and the napalm launcher, the trail of every rocket…). A field at the engine's value is not written.", .ru = "Виды эффектов движка, одно значение на все оружия с этим эффектом (огонь огнемёта и напалмомёта, след любой ракеты…). Поле со значением движка не пишется." };
pub const ui_sec_popup: Msg = .{ .en = "Floating numbers", .ru = "Всплывающие числа" };
pub const ui_sub_popup_text: Msg = .{ .en = "Their motion", .ru = "Их движение" };
pub const ui_sec_battle: Msg = .{ .en = "Battle colours and grid", .ru = "Цвета и сетка боя" };
pub const ui_sub_grid: Msg = .{ .en = "Grid", .ru = "Сетка" };
pub const ui_sub_cinema: Msg = .{ .en = "Cinema bars", .ru = "Полосы кино" };
pub const ui_sec_menu_light: Msg = .{ .en = "Menu light, credits, safe lock", .ru = "Свет меню, титры, кодовый замок" };
pub const ui_sub_credits: Msg = .{ .en = "Credits colours", .ru = "Цвета титров" };
pub const ui_sub_safe: Msg = .{ .en = "Safe lock keys", .ru = "Кнопки кодового замка" };
pub const g_sec_video: Msg = .{ .en = "Videos", .ru = "Видео" };
pub const g_sec_music: Msg = .{ .en = "Music", .ru = "Музыка" };
pub const g_sec_states: Msg = .{ .en = "Fighter states", .ru = "Состояния бойцов" };
pub const g_state_turns: Msg = .{ .en = "turns", .ru = "ходов" };
pub const g_state_damage: Msg = .{ .en = "damage by turn", .ru = "урон по ходам" };
pub const g_states_note: Msg = .{ .en = "How many turns a state lasts (one more when applied in the enemy turn) and the damage at each turn start, first turn first (15 10 5); bite: no turns, its damage every turn.", .ru = "Сколько ходов длится состояние (на ход дольше, если наложено в ход врага), и урон в начале каждого хода, с первого (15 10 5); укус — без ходов, его урон каждый ход." };
pub const cp_victory: Msg = .{ .en = "Victory", .ru = "Победа" };
pub const cp_game_over: Msg = .{ .en = "Game over", .ru = "Поражение" };
pub const cp_statistics: Msg = .{ .en = "Battle report", .ru = "Отчёт о бое" };
pub const cp_battle: Msg = .{ .en = "Battle (one drawn)", .ru = "Бой (случайная)" };
pub const cp_boss: Msg = .{ .en = "Boss battle", .ru = "Бой с боссом" };
pub const cp_enemy_suffix: Msg = .{ .en = "Enemy turn suffix", .ru = "Суффикс хода врага" };
pub const camp_sec_start: Msg = .{ .en = "New game", .ru = "Новая игра" };
pub const camp_sec_hooks: Msg = .{ .en = "Script hooks", .ru = "Скриптовые хуки" };
pub const cp_title: Msg = .{ .en = "Title", .ru = "Название" };
pub const cp_level: Msg = .{ .en = "Location", .ru = "Локация" };
pub const cp_leader: Msg = .{ .en = "Selected hero", .ru = "Выбранный герой" };
pub const cp_party: Msg = .{ .en = "Party", .ru = "Отряд" };
pub const cp_party_max: Msg = .{ .en = "At most {d} heroes (party_max on a hero page; the exe's party holds 6).", .ru = "Не больше {d} героев (party_max на странице героя; отряд exe вмещает 6)." };
pub const cp_party_full: Msg = .{ .en = "The party is full: at most {d} heroes (party_max)", .ru = "Отряд полон: не больше {d} героев (party_max)" };
pub const cp_area: Msg = .{ .en = "Arrival area", .ru = "Зона прибытия" };
pub const cp_point: Msg = .{ .en = "Its first point", .ru = "Её первая точка" };
pub const cp_scene: Msg = .{ .en = "Scene on arrival", .ru = "Сцена по прибытии" };
pub const cp_intro: Msg = .{ .en = "Intro videos", .ru = "Вступительные видео" };
pub const cp_startup: Msg = .{ .en = "Videos before the menu", .ru = "Видео перед меню" };
pub const cp_logo: Msg = .{ .en = "Menu logo", .ru = "Логотип меню" };
pub const cp_music: Msg = .{ .en = "Menu music", .ru = "Музыка меню" };
pub const cp_credits_music: Msg = .{ .en = "Credits music", .ru = "Музыка титров" };
pub const cp_credits: Msg = .{ .en = "Credits text", .ru = "Текст титров" };
pub const cp_credits_video: Msg = .{ .en = "Video before the credits", .ru = "Видео перед титрами" };
pub const camp_pick: Msg = .{ .en = "Pick…", .ru = "Выбрать…" };
pub const camp_add_video: Msg = .{ .en = "Add a video…", .ru = "Добавить видео…" };
pub const camp_party_note: Msg = .{ .en = "Every location makes these heroes, in this order (others still join by the levels' scripts); a hero copy is one of them.", .ru = "Каждая локация создаёт этих героев в этом порядке (другие по-прежнему присоединяются скриптами уровней); копия героя — один из них." };
pub const camp_title_note: Msg = .{ .en = "The manifest's title (opengorky.mod): under the logo of the main menu and in the package's README.", .ru = "Название из манифеста (opengorky.mod): под логотипом главного меню и в README пакета." };
pub const camp_hooks_note: Msg = .{ .en = "src/game.ogs: functions the engine calls (only defined ones, only in OpenGorky). The code view's Problems know their names and parameters.", .ru = "src/game.ogs — функции, которые вызывает движок (только определённые и только в OpenGorky). Панель «Проблемы» редактора кода знает их имена и параметры." };
pub const camp_hooks_open: Msg = .{ .en = "Open hooks.ss", .ru = "Открыть hooks.ss" };
pub const camp_hooks_make: Msg = .{ .en = "Make hooks.ss", .ru = "Создать hooks.ss" };
pub const st_camp_set: Msg = .{ .en = "Campaign {s} = {s}; saved with Ctrl+S", .ru = "Кампания: {s} = {s}; сохраняется по Ctrl+S" };
pub const code_hook_unknown: Msg = .{ .en = "line {d}: {s} — the engine calls no such hook (OnDamage, OnResist, OnTurnStart, OnBattleEnd, OnItemUse, OnLevelEnter)", .ru = "строка {d}: {s} — такого хука движок не вызывает (OnDamage, OnResist, OnTurnStart, OnBattleEnd, OnItemUse, OnLevelEnter)" };
pub const code_hook_classic: Msg = .{ .en = "{s}: OpenGorky only: the original never calls it", .ru = "{s}: только OpenGorky: оригинал его никогда не вызывает" };
pub const code_hook_args: Msg = .{ .en = "line {d}: the engine calls {s}", .ru = "строка {d}: движок вызывает {s}" };
pub const code_engine_calls_it: Msg = .{ .en = "Called by the engine: {s}", .ru = "Вызывает движок: {s}" };
pub const code_event_calls_it: Msg = .{ .en = "Fighter event, called by the battle: {s}", .ru = "Событие бойца, его вызывает бой: {s}" };
pub const code_component: Msg = .{ .en = "Component for {s} ({s})", .ru = "Компонент для {s} ({s})" };
pub const code_any_host: Msg = .{ .en = "any host", .ru = "любого хоста" };
pub const code_view_ogs: Msg = .{ .en = "OG Script", .ru = "OG Script" };
pub const st_code_view_none: Msg = .{ .en = "{s}: no function to show as OG Script", .ru = "{s}: нет функций, которые можно показать на OG Script" };
pub const code_view_note: Msg = .{ .en = "OG Script view: Apply writes the original's language back (comments, the header and #include lines live in the Classic text)", .ru = "Вид OG Script: «Применить» записывает обратно на языке оригинала (комментарии, заголовок и строки #include — в тексте Classic)" };
pub const st_code_not_applied: Msg = .{ .en = "{s}: not applied, no text in the original's language: {s}", .ru = "{s}: не применено, на языке оригинала так не записать: {s}" };
pub const st_code_comments: Msg = .{ .en = "{s}: the export re-prints a block and drops {d} comment(s). Apply again to write it anyway", .ru = "{s}: экспорт перепечатывает блок и теряет комментарии ({d}). «Применить» ещё раз — записать всё равно" };
pub const code_not_classic: Msg = .{ .en = "no text in the original's language: {s}", .ru = "на языке оригинала так не записать: {s}" };
pub const code_other_file: Msg = .{ .en = "this changes {s}, which the script includes: edit it there", .ru = "это меняет {s}, который скрипт включает: правьте его там" };
pub const st_code_ogs_error: Msg = .{ .en = "Not applied: line {d}: {s}", .ru = "Не применено: строка {d}: {s}" };
pub const code_note: Msg = .{ .en = "line {d}: {s}", .ru = "строка {d}: {s}" };
pub const code_r_no_field: Msg = .{ .en = "{s} has no field '{s}' — did you mean '{s}'?", .ru = "у {s} нет поля «{s}» — может быть, «{s}»?" };
pub const code_r_no_field_list: Msg = .{ .en = "{s} has no field '{s}' (fields: {s})", .ru = "у {s} нет поля «{s}» (поля: {s})" };
pub const code_r_twice: Msg = .{ .en = "{s}: field '{s}' is written twice (the last one counts)", .ru = "{s}: поле «{s}» записано дважды (действует последнее)" };
pub const code_r_missing: Msg = .{ .en = "{s}: a new row (no built-in one has its keys) must write {s}; the engine skips it", .ru = "{s}: новая строка (ни у одной встроенной нет таких ключей) должна записать {s}; движок её пропускает" };
pub const code_r_word: Msg = .{ .en = "{s} = \"{s}\": not one of {s}", .ru = "{s} = «{s}»: допустимо только {s}" };
pub const code_adjust_origin: Msg = .{ .en = "built in: {s} (a tuning value, Engine settings) {s}", .ru = "встроено: {s} (настройка, «Настройки движка») {s}" };
pub const code_r_adjust: Msg = .{ .en = "adjust(\"{s}\", …) is {d} here: the rules hold plain numbers now, write the number (Engine settings keeps the tuning values)", .ru = "adjust(\"{s}\", …) здесь равно {d}: теперь в правилах просто числа, напишите число (настройки движка — на странице «Настройки движка»)" };
pub const code_r_value: Msg = .{ .en = "{s}: {s} — expected {s}", .ru = "{s}: {s} — ожидается {s}" };
pub const code_r_class: Msg = .{ .en = "{s} = {d}: no fighter classType {1d} is declared; nearest declared: {s}", .ru = "{s} = {d}: classType бойца {1d} нигде не объявлен; ближайшие объявленные: {s}" };
pub const code_r_wclass: Msg = .{ .en = "{s} = {d}: no weapon classType {1d} is declared; nearest declared: {s}", .ru = "{s} = {d}: classType оружия {1d} нигде не объявлен; ближайшие объявленные: {s}" };
pub const code_r_id: Msg = .{ .en = "{s}: no entity has classic_id {d}; nearest: {s}", .ru = "{s}: ни у одной сущности нет classic_id {d}; ближайшие: {s}" };
pub const code_r_effect: Msg = .{ .en = "{s} = {d}: no block has classic_id {1d} and it is no built-in effect (WeaponFx): the stage shows nothing", .ru = "{s} = {d}: ни у одного блока нет classic_id {1d}, и это не встроенный эффект (WeaponFx): стадия ничего не покажет" };
pub const code_r_again: Msg = .{ .en = "{s}: line {d} has a row with the same keys again (its fields override these)", .ru = "{s}: в строке {d} снова строка с теми же ключами (её поля перекрывают эти)" };
pub const code_r_overridden: Msg = .{ .en = "{s}: this row (by classic_id) is overridden by line {d} (by class), for the same fighter", .ru = "{s}: эта строка (по classic_id) перекрыта строкой {d} (по классу) для того же бойца" };
pub const code_r_unarmed: Msg = .{ .en = "{s}: weapon {s} needs ammo {s}, and the fighter has none: it strikes without it (unarmed, as in the exe)", .ru = "{s}: оружию {s} нужны патроны {s}, а у бойца их нет: им он не бьёт (безоружен, как в exe)" };
pub const code_r_key: Msg = .{ .en = "{s}: no class script or entity \"{s}\"", .ru = "{s}: нет скрипта класса или сущности «{s}»" };
pub const code_r_text: Msg = .{ .en = "{s} = {d}: string.tab has no text {1d} (its numbers: {d}…{d})", .ru = "{s} = {d}: в string.tab нет текста {1d} (его номера: {d}…{d})" };
pub const code_no_value: Msg = .{ .en = "{s}(): no {s} \"{s}\" in the game", .ru = "{s}(): в игре нет {s} «{s}»" };
pub const code_use_sigil: Msg = .{ .en = "{s}() takes a {s}: write ~{c}\"{s}\" and the name is checked when the code loads", .ru = "{s}() принимает {s}: напишите ~{c}\"{s}\", и имя проверится при загрузке кода" };
pub const code_engine_calls: Msg = .{ .en = "the engine calls {s} (more parameters get 0 or \"\", another type is converted)", .ru = "движок вызывает {s} (лишние параметры получают 0 или \"\", другой тип преобразуется)" };
pub const code_r_no_table: Msg = .{ .en = "{s} is no rules table: the engine skips the row", .ru = "{s} — не таблица правил: движок пропускает строку" };
pub const code_near_event: Msg = .{ .en = "{s}: no event of {s} — did you mean {s}?", .ru = "{s}: у {s} нет такого события; может быть, {s}?" };
pub const code_r_no_table_near: Msg = .{ .en = "{s} is no rules table — did you mean '{s}'?", .ru = "{s} — не таблица правил; может быть, «{s}»?" };

// Rules pages (rulespages.zig): experience levels, special values, actions.
pub const rp_builtin: Msg = .{ .en = "built-in {d}", .ru = "встроено {d}" };
pub const rp_added: Msg = .{ .en = "added", .ru = "добавлено" };
pub const st_rules_row: Msg = .{ .en = "{s} written; saved with Ctrl+S", .ru = "{s} записано; сохраняется по Ctrl+S" };
pub const xp_title: Msg = .{ .en = "Experience levels", .ru = "Уровни опыта" };
pub const xp_hint: Msg = .{ .en = "The exp a hero needs for each level (rules party.ss ExpLevel; the exe's table 0x528c3c): the level grows while exp exceeds its level's threshold, up to the last level.", .ru = "Сколько опыта герою нужно на каждый уровень (правила party.ss, ExpLevel; таблица exe 0x528c3c): уровень растёт, пока опыт больше порога его уровня, до последнего уровня." };
pub const xp_sec: Msg = .{ .en = "Thresholds", .ru = "Пороги" };
pub const xp_sum: Msg = .{ .en = "up to level {d}", .ru = "до уровня {d}" };
pub const xp_level: Msg = .{ .en = "Level {d}", .ru = "Уровень {d}" };
pub const xp_add: Msg = .{ .en = "Add level", .ru = "Добавить уровень" };
pub const xp_note: Msg = .{ .en = "Thresholds must grow from level to level. A built-in level can't be removed (the rules files only add rows or write over built-in ones), only changed; × removes the last level the project added.", .ru = "Пороги должны расти от уровня к уровню. Встроенный уровень нельзя убрать (файлы правил только добавляют строки или пишут поверх встроенных), только изменить; × убирает последний добавленный проектом уровень." };
pub const st_xp_order: Msg = .{ .en = "Level {d}: {s} refused: thresholds must grow (above the lower levels', below the higher ones')", .ru = "Уровень {d}: {s} не принято — пороги должны расти (выше нижних уровней, ниже верхних)" };
pub const st_xp_removed: Msg = .{ .en = "Level {d} removed; saved with Ctrl+S", .ru = "Уровень {d} убран; сохраняется по Ctrl+S" };
pub const val_title: Msg = .{ .en = "Special values", .ru = "Особые значения" };
pub const val_hint: Msg = .{ .en = "IDs and limits the exe keeps in its code (rules party.ss Value): which fighters (classic_id) behave specially, the idle time before the chatter, the party size, and the growth and battle numbers (kill exp, points per level, stat cap, crit and rage factors, side and back bonuses, the defeat rule).", .ru = "ID и пределы, зашитые в код exe (правила party.ss, Value): какие бойцы (classic_id) ведут себя по-особому, время простоя до праздной реплики, размер отряда, а также числа роста и боя (опыт за убийство, очки за уровень, предел статов, множители крита и ярости, бонусы сбоку и сзади, условие поражения)." };
pub const val_sec_limits: Msg = .{ .en = "Limits", .ru = "Пределы" };
pub const val_none: Msg = .{ .en = "no hero or enemy has this classic_id", .ru = "ни у одного героя или врага нет такого classic_id" };
pub const val_party_note: Msg = .{ .en = "idle_ticks: game ticks; party_max: 3…12, also on every hero page (Party).", .ru = "idle_ticks — игровые тики; party_max — 3…12, есть и на странице каждого героя («Отряд»)." };
pub const act_title: Msg = .{ .en = "Actions", .ru = "Действия" };
pub const act_hint: Msg = .{ .en = "Item and area actions by name (rules actions.ss Action; the exe's 0x4564b0 by classic_id): the menu row and what it does. Objects name them in action, action1…", .ru = "Действия предметов и зон по имени (правила actions.ss, Action; exe 0x4564b0 — по classic_id): строка меню и что она делает. Объекты называют их в action, action1…" };
pub const act_og_hint: Msg = .{ .en = "The game's item and area actions (src/actions.ogs): the menu row and what it does. Objects name an action in action, action1… (walk and none are the engine's).", .ru = "Действия предметов и зон игры (src/actions.ogs): строка меню и что она делает. Объекты называют действие в action, action1… (walk и none — движка)." };
pub const act_pick_note: Msg = .{ .en = "Pick an action on the left.", .ru = "Выберите действие слева." };
pub const act_f_name: Msg = .{ .en = "Name", .ru = "Имя" };
pub const act_name_note: Msg = .{ .en = "What objects write (action = Open) and the method it calls on the object; a rename follows them.", .ru = "Как его пишут объекты (action = Open) и метод, который оно вызывает у объекта; переименование меняет и их." };
pub const act_f_label: Msg = .{ .en = "Menu text", .ru = "Текст в меню" };
pub const act_f_kind: Msg = .{ .en = "Kind", .ru = "Вид" };
pub const act_f_auto_open: Msg = .{ .en = "Opens the box", .ru = "Открывает ящик" };
pub const act_f_on_exit: Msg = .{ .en = "On an exit", .ru = "На выходе" };
pub const act_f_walk_click: Msg = .{ .en = "Click only walks", .ru = "Клик — только идти" };
pub const st_act_new: Msg = .{ .en = "New action {s}", .ru = "Новое действие {s}" };
pub const st_act_renamed: Msg = .{ .en = "Action {s} → {s}: {d} files", .ru = "Действие {s} → {s}: файлов {d}" };
pub const st_act_deleted: Msg = .{ .en = "Action {s} deleted", .ru = "Действие {s} удалено" };
pub const act_new: Msg = .{ .en = "New action", .ru = "Новое действие" };
pub const act_sec: Msg = .{ .en = "By classic_id", .ru = "По classic_id" };
pub const act_sum: Msg = .{ .en = "{d} actions", .ru = "действий: {d}" };
pub const act_props: Msg = .{ .en = "classic_id {d} · {s}", .ru = "classic_id {d} · {s}" };
pub const act_used: Msg = .{ .en = "Item classes using it", .ru = "Классы предметов с ним" };
pub const act_used_none: Msg = .{ .en = "No item class names this action.", .ru = "Ни один класс предмета не называет это действие." };
pub const act_delete: Msg = .{ .en = "Delete action", .ru = "Удалить действие" };
pub const act_reset: Msg = .{ .en = "Back to built-in", .ru = "Вернуть встроенное" };
pub const act_own_note: Msg = .{ .en = "The project's action: deleting it removes its row; objects still naming it get no menu row.", .ru = "Действие проекта: удаление убирает его строку; у объектов, которые его называют, пропадёт строка меню." };
pub const act_builtin_note: Msg = .{ .en = "A built-in action can't be deleted (the rules files only write over built-in rows); Back to built-in drops the project's row.", .ru = "Встроенное действие нельзя удалить (файлы правил только пишут поверх встроенных строк); «Вернуть встроенное» убирает строку проекта." };
pub const st_act_dropped: Msg = .{ .en = "Action {d} ({s}): the project's row removed; saved with Ctrl+S", .ru = "Действие {d} ({s}): строка проекта убрана; сохраняется по Ctrl+S" };
pub const act_levels: Msg = .{ .en = "Search levels", .ru = "Искать в уровнях" };
pub const act_levels_sec: Msg = .{ .en = "Level objects using it", .ru = "Объекты уровней с ним" };
pub const act_levels_none: Msg = .{ .en = "No level object names this action.", .ru = "Ни один объект уровней не называет это действие." };
pub const act_levels_note: Msg = .{ .en = "Levels' objects (areas, boxes, items; action, action1…) after their init(): Search levels reads every level, slower.", .ru = "Объекты уровней (зоны, ящики, предметы; action, action1…) после их init(): «Искать в уровнях» читает каждый уровень, это дольше." };

// The shell and behaviour tables (core/ui.zig, core/behaviour.zig: rules ui.ss, ai.ss, fighters.ss).
pub const camp_sec_windows: Msg = .{ .en = "Sliding windows", .ru = "Выезжающие окна" };
pub const cp_level_up: Msg = .{ .en = "Level-up window", .ru = "Окно очков уровня" };
pub const cp_battle_enter: Msg = .{ .en = "Entering a battle", .ru = "Вход в бой" };
pub const cp_menu_model: Msg = .{ .en = "Model", .ru = "Модель" };
pub const cp_menu_anim: Msg = .{ .en = "Its animation", .ru = "Её анимация" };
pub const cp_menu_light: Msg = .{ .en = "Light", .ru = "Свет" };
pub const cp_menu_circle: Msg = .{ .en = "Circle", .ru = "Круг" };
pub const cp_menu_flare: Msg = .{ .en = "Flare", .ru = "Блик" };
pub const cp_menu_lens: Msg = .{ .en = "Lens", .ru = "Линза" };
pub const cp_menu_lens2: Msg = .{ .en = "Second lens", .ru = "Вторая линза" };
pub const cp_menu_arrow: Msg = .{ .en = "Slider arrow", .ru = "Стрелка ползунка" };
pub const cp_menu_cursor: Msg = .{ .en = "Name cursor", .ru = "Курсор имени" };
pub const cp_menu_font: Msg = .{ .en = "Item font", .ru = "Шрифт пунктов" };
pub const cp_menu_glow: Msg = .{ .en = "Its glow", .ru = "Его свечение" };
pub const cp_menu_start_y: Msg = .{ .en = "First item's y", .ru = "y первого пункта" };
pub const cp_menu_h_space: Msg = .{ .en = "Item spacing", .ru = "Шаг пунктов" };
pub const camp_menu_note: Msg = .{ .en = "Files of common/other.dat: gfx_3d\\<model>.msh with the animation in its .ani, textures gfx_3d\\textures\\*.3df, a font's <font>_1.fnt and its letter sets; a name the game hasn't is refused. y and spacing: pixels of the 640×480 screen (the exe's adjust.kdt MENU_START_Y, MENU_H_SPACE).", .ru = "Файлы common/other.dat: gfx_3d\\<модель>.msh с анимацией в её .ani, текстуры gfx_3d\\textures\\*.3df, у шрифта <шрифт>_1.fnt и наборы букв; имя, которого нет в игре, не принимается. y и шаг — пиксели экрана 640×480 (у exe — MENU_START_Y, MENU_H_SPACE из adjust.kdt)." };
pub const win_skills_at: Msg = .{ .en = "Skills: opened at", .ru = "Навыки: открыто в" };
pub const win_skills_from: Msg = .{ .en = "Skills: slides from (x)", .ru = "Навыки: выезжает из (x)" };
pub const win_skills_size: Msg = .{ .en = "Skills: hit box", .ru = "Навыки: область клика" };
pub const win_skills_inv: Msg = .{ .en = "Skills in the inventory", .ru = "Навыки в инвентаре" };
pub const win_stats_at: Msg = .{ .en = "Stats: opened at", .ru = "Характеристики: открыто в" };
pub const win_stats_from: Msg = .{ .en = "Stats: slides from", .ru = "Характеристики: выезжает из" };
pub const win_stats_size: Msg = .{ .en = "Stats: hit box", .ru = "Характеристики: область клика" };
pub const win_stats_inv: Msg = .{ .en = "Stats in the inventory", .ru = "Характеристики в инвентаре" };
pub const win_level_up: Msg = .{ .en = "Stats with level-up points", .ru = "Характеристики с очками уровня" };
pub const camp_windows_note: Msg = .{ .en = "Places on the 640×480 screen (rules ui.ss Windows): WeaponSkill.spr and HeroStats.spr; the skills window slides along x only.", .ru = "Места на экране 640×480 (правила ui.ss Windows): WeaponSkill.spr и HeroStats.spr; окно навыков выезжает только по x." };
pub const vid_place: Msg = .{ .en = "Placement (ExeVideo)", .ru = "Место (ExeVideo)" };
pub const vid_place_at: Msg = .{ .en = "On the screen", .ru = "На экране" };
pub const vid_place_val: Msg = .{ .en = "{d}, {d} · {s}", .ru = "{d}, {d} · {s}" };
pub const vid_place_dbl: Msg = .{ .en = "Doubled lines", .ru = "Строки удвоены" };
pub const vid_place_single: Msg = .{ .en = "single lines", .ru = "строки не удвоены" };
pub const vid_place_none: Msg = .{ .en = "The exe doesn't show it itself: the campaign's lists play it fitted, scripts at their AVI_Play place.", .ru = "Сам exe его не показывает: списки кампании играют его вписанным, скрипты — в месте из AVI_Play." };
pub const vid_place_add: Msg = .{ .en = "Add a placement", .ru = "Добавить место" };
pub const vid_place_note: Msg = .{ .en = "Where the campaign's videos (intro, startup) show it on the 640×480 screen; the preview shows that screen. Off the screen (logo1: x −1000) it plays unseen.", .ru = "Где видео кампании (intro, startup) показывают его на экране 640×480; превью показывает этот экран. За экраном (logo1: x −1000) оно играет невидимым." };
pub const vid_place_reset: Msg = .{ .en = "Back to the exe's", .ru = "Вернуть как в exe" };
pub const vid_place_remove: Msg = .{ .en = "Remove the placement", .ru = "Убрать место" };
pub const ai_scoring: Msg = .{ .en = "Tile scoring (AiScoring eval = {s})", .ru = "Оценка клеток (AiScoring eval = {s})" };
pub const ai_keep: Msg = .{ .en = "Plans with", .ru = "Планирует с" };
pub const ai_occupant: Msg = .{ .en = "A fighter's worth", .ru = "Ценность бойца" };
pub const ai_tile: Msg = .{ .en = "A hit tile", .ru = "Задетая клетка" };
pub const ai_wakeful: Msg = .{ .en = "Plans asleep (wakeful)", .ru = "Планирует во сне (wakeful)" };
pub const ai_near: Msg = .{ .en = "Stays near", .ru = "Держится рядом с" };
pub const ai_follow_lock: Msg = .{ .en = "Its AITargetLock target first (follow_lock)", .ru = "Сначала цель AITargetLock (follow_lock)" };
pub const ai_score: Msg = .{ .en = "Scores tiles by (a component)", .ru = "Оценивает клетки компонентом" };
pub const ai_other_classes: Msg = .{ .en = "every other class", .ru = "все прочие классы" };
pub const ai_shared: Msg = .{ .en = "Shared by every class with scoring {s}: {s}. A change here changes them all.", .ru = "Общая для всех классов со scoring {s}: {s}. Изменение здесь меняет их все." };
pub const spin_title: Msg = .{ .en = "Spins (FighterStrike special = {d})", .ru = "Вращения (FighterStrike special = {d})" };
pub const spin_n: Msg = .{ .en = "Saw {d}", .ru = "Пила {d}" };
pub const spin_none: Msg = .{ .en = "No saw spins in this strike.", .ru = "В этом ударе пилы не вращаются." };
pub const spin_on: Msg = .{ .en = "{s}, frame {d}", .ru = "{s}, кадр {d}" };
pub const spin_edit: Msg = .{ .en = "On the animation's frames", .ru = "На кадрах анимации" };
pub const spin_lane: Msg = .{ .en = "Spins (FighterStrike {d})", .ru = "Вращения (FighterStrike {d})" };
pub const spin_add_at: Msg = .{ .en = "+ Spin on frame {d}", .ru = "+ Вращение на кадре {d}" };
pub const spin_note: Msg = .{ .en = "A saw spun on the model's link point (its mesh's own \"obrot\") when the strike animation reaches the frame (Headnail 0x48d760); shared by every fighter whose attack has this special. Drag the markers on the animation's timeline.", .ru = "Пила вращается в точке крепления модели (своя анимация меша «obrot»), когда анимация удара доходит до кадра (Headnail 0x48d760); общее для всех бойцов, у чьей атаки этот special. Маркеры двигаются на шкале кадров анимации." };
pub const sec_abilities: Msg = .{ .en = "Components", .ru = "Компоненты" };
pub const ab_note: Msg = .{ .en = "What this fighter does beyond an ordinary one, hero or enemy. A change writes its own Abilities row (by its classic_id or class, a copy of its classType's at first): only this character.", .ru = "Что этот боец умеет сверх обычного — герой он или враг. Изменение пишет его собственную строку Abilities (по classic_id или классу, сначала копию строки его classType): только этот персонаж." };
pub const ab_note_classic: Msg = .{ .en = "What the exe gives this fighter (its code by classType, classic_id or object name).", .ru = "Что даёт этому бойцу exe (его код по classType, classic_id или имени объекта)." };
pub const ab_sum: Msg = .{ .en = "{d}", .ru = "{d}" };
pub const ab_none_sum: Msg = .{ .en = "none", .ru = "нет" };
pub const ab_none: Msg = .{ .en = "None: an ordinary fighter.", .ru = "Нет: обычный боец." };
pub const ab_add: Msg = .{ .en = "+ component", .ru = "+ компонент" };
pub const ab_remove: Msg = .{ .en = "Remove", .ru = "Убрать" };
pub const ab_own: Msg = .{ .en = "own", .ru = "своя" };
pub const ab_by_class: Msg = .{ .en = "classType {d}", .ru = "classType {d}" };
pub const ab_by_id: Msg = .{ .en = "classic_id {d}", .ru = "classic_id {d}" };
pub const ab_double_turn: Msg = .{ .en = "Two moves per turn", .ru = "Два хода за ход" };
pub const ab_double_turn_n: Msg = .{ .en = "Acts twice in a row, a full walk each (Incubus, Cripple); a hero the player leads: two strikes, the walk anew after the first.", .ru = "Действует дважды подряд, каждый раз с полным запасом хода (Инкуб, Калека); герой под управлением игрока: два удара, после первого ход заново." };
pub const ab_immobile: Msg = .{ .en = "Nailed down", .ru = "Прибит к месту" };
pub const ab_immobile_n: Msg = .{ .en = "Never walks; strikes from its tile.", .ru = "Никогда не ходит; бьёт со своей клетки." };
pub const ab_first: Msg = .{ .en = "Acts first", .ru = "Ходит первым" };
pub const ab_first_n: Msg = .{ .en = "First in the enemy turn on a level of this mode (Grandma: 2).", .ru = "Первым в ходе врагов на уровне с этим mode (Бабушка: 2)." };
pub const ab_level_mode: Msg = .{ .en = "mode: {d}", .ru = "mode: {d}" };
pub const ab_stand: Msg = .{ .en = "Stands at an angle", .ru = "Стоит под углом" };
pub const ab_stand_n: Msg = .{ .en = "Stands so instead of facing the nearest opponent; its tiles below are by this stance (Puppet, Messiah).", .ru = "Стоит так, а не лицом к ближайшему противнику; клетки ниже отсчитываются от этой стойки (Кукла, Мессия)." };
pub const ab_angle: Msg = .{ .en = "Angle, rad", .ru = "Угол, рад" };
pub const ab_after_move: Msg = .{ .en = "After its own move too", .ru = "И после своего хода" };
pub const ab_guard: Msg = .{ .en = "Front defence", .ru = "Защита спереди" };
pub const ab_guard_n: Msg = .{ .en = "Struck from the front cone: damage /divisor, at least the minimum (Puppet).", .ru = "Удар спереди в конусе: урон делится, но не меньше минимума (Кукла)." };
pub const ab_div: Msg = .{ .en = "Divisor: {d}", .ru = "Делитель: {d}" };
pub const ab_min: Msg = .{ .en = "At least: {d}", .ru = "Не меньше: {d}" };
pub const ab_cone: Msg = .{ .en = "Cone, rad: {d:.2}", .ru = "Конус, рад: {d:.2}" };
pub const ab_open: Msg = .{ .en = "Struck from one tile only", .ru = "Уязвим только с одной клетки" };
pub const ab_open_n: Msg = .{ .en = "From any other tile a miss, and it dodges the shot (Messiah: the tile in front of him).", .ru = "С любой другой клетки промах, и он уклоняется (Мессия: клетка перед ним)." };
pub const ab_rel_right: Msg = .{ .en = "To its right: {d}", .ru = "Вправо от него: {d}" };
pub const ab_rel_ahead: Msg = .{ .en = "Ahead: {d}", .ru = "Вперёд: {d}" };
pub const ab_dodge: Msg = .{ .en = "Dodge", .ru = "Уклонение" };
pub const ab_arms: Msg = .{ .en = "Arms a box blocks", .ru = "Руки, закрываемые ящиком" };
pub const ab_arms_n: Msg = .{ .en = "No strike with an arm whose tile holds a box; both blocked: the animation after its move (Messiah).", .ru = "Рукой, на клетке которой ящик, не бьёт; обе закрыты — анимация после хода (Мессия)." };
pub const ab_left: Msg = .{ .en = "Left arm", .ru = "Левая рука" };
pub const ab_right_arm: Msg = .{ .en = "Right arm", .ru = "Правая рука" };
pub const ab_blocked: Msg = .{ .en = "Both blocked", .ru = "Обе закрыты" };
pub const ab_monitor: Msg = .{ .en = "Monitor", .ru = "Монитор" };
pub const ab_monitor_n: Msg = .{ .en = "A hit only deals damage: no side bonus, reaction or blood.", .ru = "Попадание только наносит урон: без бонуса сбоку, реакции и крови." };
pub const ab_no_credit: Msg = .{ .en = "Kill not counted", .ru = "Убийство не в счёт" };
pub const ab_no_credit_n: Msg = .{ .en = "Its kill gives no exp bonus and no report line.", .ru = "Его убийство не даёт бонуса опыта и строки отчёта." };
pub const ab_double_strike: Msg = .{ .en = "Strikes twice", .ru = "Бьёт дважды" };
pub const ab_double_strike_n: Msg = .{ .en = "Two strikes into one tile; with weapon pairs (classic_ids) by its counter (Schizo).", .ru = "Два удара в одну клетку; с парами оружия (classic_id) по его счётчику (Шизо)." };
pub const ab_pair_a: Msg = .{ .en = "Pair {d}, first: {d}", .ru = "Пара {d}, первое: {d}" };
pub const ab_pair_b: Msg = .{ .en = "Pair {d}, second: {d}", .ru = "Пара {d}, второе: {d}" };
pub const ab_pair_add: Msg = .{ .en = "+ pair", .ru = "+ пара" };
pub const ab_pair_remove: Msg = .{ .en = "- last pair", .ru = "- последняя пара" };
pub const ab_heals: Msg = .{ .en = "Heals another", .ru = "Лечит другого" };
pub const ab_heals_n: Msg = .{ .en = "Heals this fighter by the damage it deals (the Judge's child).", .ru = "Лечит этого бойца на нанесённый урон (ребёнок Судьи)." };
pub const ab_avenger: Msg = .{ .en = "Avenged", .ru = "За него отомстят" };
pub const ab_avenger_n: Msg = .{ .en = "Its death makes its killer this fighter's target (Grandma's child).", .ru = "Его смерть делает убийцу целью этого бойца (ребёнок Бабушки)." };
pub const ab_fighter: Msg = .{ .en = "Fighter", .ru = "Боец" };
pub const ab_invisible: Msg = .{ .en = "Invisible", .ru = "Невидимый" };
pub const ab_invisible_n: Msg = .{ .en = "Starts the battle unseen and is never highlighted (the Invisible).", .ru = "Начинает бой невидимым и не подсвечивается (Невидимка)." };
pub const ab_leaves: Msg = .{ .en = "Leaves the battle", .ru = "Уходит из боя" };
pub const ab_leaves_n: Msg = .{ .en = "Leaves after the enemy round, not a death (the Invisible in 04__city_mfd).", .ru = "Уходит после раунда врагов, это не смерть (Невидимка в 04__city_mfd)." };
pub const ab_no_push: Msg = .{ .en = "Pushes nothing", .ru = "Не толкает" };
pub const ab_no_push_n: Msg = .{ .en = "No push button (Medusa).", .ru = "Нет кнопки толчка (Медуза)." };
pub const ab_no_hands: Msg = .{ .en = "No hands", .ru = "Без рук" };
pub const ab_no_hands_n: Msg = .{ .en = "Gives and takes no items, no fist when unarmed (Medusa).", .ru = "Не даёт и не берёт предметы, без оружия нет кулака (Медуза)." };
pub const ab_battle_only: Msg = .{ .en = "Battles only", .ru = "Только в бою" };
pub const ab_battle_only_n: Msg = .{ .en = "Never picked outside a battle (Medusa).", .ru = "Вне боя не выбирается (Медуза)." };
pub const ab_script_n: Msg = .{ .en = "Scripted ability: the project's OGS component (src/{s}), its handlers called at the battle's events.", .ru = "Скриптовая способность: компонент OGS проекта (src/{s}), его обработчики вызываются на событиях боя." };
pub const ab_script_pick_n: Msg = .{ .en = "Scripted ability (OGS, src/{s})", .ru = "Скриптовая способность (OGS, src/{s})" };
pub const ab_script_missing: Msg = .{ .en = "No component {s} `for fighter` in the project's rules code: the battle attaches nothing.", .ru = "В коде правил проекта нет компонента {s} `for fighter`: в бою ничего не подключится." };
pub const ab_new: Msg = .{ .en = "+ new ability", .ru = "+ новая способность" };
pub const ab_new_note: Msg = .{ .en = "A new ability: a component from the template (every event commented out) in src/components/<Name>.ogs, opened in the code editor; attach it from the list (+).", .ru = "Новая способность: компонент из шаблона (все события закомментированы) в src/components/<Name>.ogs, открывается в редакторе кода; подключается выбором из списка (+)." };
// Traits and components: the trait page, the component page, the
// character's «Компоненты» groups.
pub const ab_natives: Msg = .{ .en = "Native", .ru = "Нативные" };
pub const ab_scripted: Msg = .{ .en = "Scripted", .ru = "Скриптовые" };
pub const ab_mark: Msg = .{ .en = "mark", .ru = "метка" };
pub const ab_hero_only: Msg = .{ .en = "hero only", .ru = "только у героя" };
pub const ab_enemy_only: Msg = .{ .en = "enemy only", .ru = "только у врага" };
pub const ab_by_trait: Msg = .{ .en = "{s} (implements {s})", .ru = "{s} (реализует {s})" };
pub const ab_pick_role: Msg = .{ .en = "The role is checked in the game", .ru = "Роль проверяется в игре" };
pub const ab_pick_trait: Msg = .{ .en = "A fighter with a component that is {s}", .ru = "Боец с компонентом, который {s}" };
pub const ab_pick_character: Msg = .{ .en = "A character (its archetype)", .ru = "Персонаж (его архетип)" };
// OG layout: a block's page (og_page.zig).
pub const og_stage_file: Msg = .{ .en = "src/{s}", .ru = "src/{s}" };
pub const og_no_block: Msg = .{ .en = "This block's text does not parse: fix it in the code editor.", .ru = "Текст этого блока не разбирается: исправьте его в редакторе кода." };
pub const og_head: Msg = .{ .en = "{s} · src/{s}", .ru = "{s} · src/{s}" };
pub const og_archetype: Msg = .{ .en = "archetype {s}", .ru = "архетип {s}" };
pub const og_fields: Msg = .{ .en = "Fields", .ru = "Поля" };
pub const og_from: Msg = .{ .en = "from {s}", .ru = "из {s}" };
pub const og_default: Msg = .{ .en = "the default", .ru = "по умолчанию" };
pub const og_add_field: Msg = .{ .en = "+ field", .ru = "+ поле" };
pub const og_look: Msg = .{ .en = "Look {s}", .ru = "Облик {s}" };
pub const og_attach: Msg = .{ .en = "Attached components", .ru = "Подключённые компоненты" };
pub const og_inventory: Msg = .{ .en = "Inventory", .ru = "Инвентарь" };
pub const og_inner: Msg = .{ .en = "Blocks inside", .ru = "Вложенные блоки" };
pub const og_objects: Msg = .{ .en = "Objects", .ru = "Объекты" };
pub const og_add_fighter: Msg = .{ .en = "+ fighter", .ru = "+ боец" };
pub const og_inner_fields: Msg = .{ .en = "{s}: fields", .ru = "{s}: поля" };
pub const og_add_weapon: Msg = .{ .en = "+ weapon", .ru = "+ оружие" };
pub const og_add_item: Msg = .{ .en = "+ item", .ru = "+ предмет" };
pub const og_list_head: Msg = .{ .en = "{s} ({d})", .ru = "{s} ({d})" };
pub const og_elem: Msg = .{ .en = "{s} {d}", .ru = "{s} {d}" };
pub const og_add_elem: Msg = .{ .en = "+ {s}", .ru = "+ {s}" };
pub const st_og_bad_value: Msg = .{ .en = "not a value of OG Script: {s}", .ru = "это не значение OG Script: {s}" };

/// Labels of the engine prelude's types (foundation/types.ogs, ASCII English there):
/// `Type.value` of an enum, `Type.field` of a struct. A project's own types show theirs as
/// written.
pub const prelude = [_]struct { key: []const u8, msg: Msg }{
    .{ .key = "ItemPlace.gone", .msg = .{ .en = "Gone", .ru = "Нигде" } },
    .{ .key = "ItemPlace.ground", .msg = .{ .en = "On the ground", .ru = "На земле" } },
    .{ .key = "ItemPlace.backpack", .msg = .{ .en = "In the backpack", .ru = "В рюкзаке" } },
    .{ .key = "ItemPlace.hand", .msg = .{ .en = "In hand", .ru = "В руке" } },
    .{ .key = "ItemPlace.armor", .msg = .{ .en = "Worn", .ru = "Надет" } },
    .{ .key = "ItemPlace.party", .msg = .{ .en = "The party's", .ru = "У отряда" } },
    .{ .key = "Resistance.fire", .msg = .{ .en = "Fire", .ru = "Огонь" } },
    .{ .key = "Resistance.electricity", .msg = .{ .en = "Electricity", .ru = "Электричество" } },
    .{ .key = "Resistance.attract", .msg = .{ .en = "Decoy", .ru = "Приманка" } },
    .{ .key = "Resistance.energy", .msg = .{ .en = "Energy", .ru = "Энергия" } },
    .{ .key = "Resistance.freeze", .msg = .{ .en = "Cold", .ru = "Холод" } },
    .{ .key = "Resistance.tranq", .msg = .{ .en = "Tranquilizer", .ru = "Транквилизатор" } },
    .{ .key = "Resistance.gas", .msg = .{ .en = "Gas", .ru = "Газ" } },
    .{ .key = "Resistance.flammable", .msg = .{ .en = "Fuel", .ru = "Горючее" } },
    .{ .key = "Effect.burn", .msg = .{ .en = "Sets on fire", .ru = "Поджигает" } },
    .{ .key = "Effect.freeze", .msg = .{ .en = "Freezes", .ru = "Замораживает" } },
    .{ .key = "Effect.gas", .msg = .{ .en = "Gasses", .ru = "Травит газом" } },
    .{ .key = "Effect.soak", .msg = .{ .en = "Soaks with fuel", .ru = "Обливает горючим" } },
    .{ .key = "Effect.defend", .msg = .{ .en = "Defence stance", .ru = "Стойка защиты" } },
    .{ .key = "Effect.sleep", .msg = .{ .en = "Puts to sleep", .ru = "Усыпляет" } },
    .{ .key = "Effect.bite", .msg = .{ .en = "Poison bite", .ru = "Ядовитый укус" } },
    .{ .key = "ItemKind.other", .msg = .{ .en = "Other", .ru = "Прочее" } },
    .{ .key = "ItemKind.ammo", .msg = .{ .en = "Ammunition", .ru = "Боеприпасы" } },
    .{ .key = "ItemKind.medicine", .msg = .{ .en = "Medicine", .ru = "Лекарства" } },
    .{ .key = "ItemKind.armor", .msg = .{ .en = "Armour", .ru = "Броня" } },
    .{ .key = "Side.hero", .msg = .{ .en = "Heroes", .ru = "Герои" } },
    .{ .key = "Side.enemy", .msg = .{ .en = "Enemies", .ru = "Враги" } },
    .{ .key = "Side.civilian", .msg = .{ .en = "Civilians", .ru = "Мирные" } },
    .{ .key = "Place.who", .msg = .{ .en = "Who", .ru = "Кто" } },
    .{ .key = "Place.tile", .msg = .{ .en = "Tile", .ru = "Клетка" } },
    .{ .key = "Place.at", .msg = .{ .en = "Area", .ru = "Зона" } },
    .{ .key = "Place.point", .msg = .{ .en = "Point of the area", .ru = "Точка зоны" } },
    .{ .key = "Place.floor", .msg = .{ .en = "Floor", .ru = "Этаж" } },
    .{ .key = "PathPoint.x", .msg = .{ .en = "X", .ru = "X" } },
    .{ .key = "PathPoint.y", .msg = .{ .en = "Y", .ru = "Y" } },
    .{ .key = "PathPoint.angle", .msg = .{ .en = "Angle, rad", .ru = "Угол, рад" } },
    .{ .key = "PathPoint.z", .msg = .{ .en = "Height", .ru = "Высота" } },
    .{ .key = "Line.who", .msg = .{ .en = "Speaker", .ru = "Кто говорит" } },
    .{ .key = "Line.text", .msg = .{ .en = "Text", .ru = "Текст" } },
    .{ .key = "Line.voice", .msg = .{ .en = "Voice (~s\"…\")", .ru = "Голос (~s\"…\")" } },
    .{ .key = "Line.cam", .msg = .{ .en = "Camera at, x and y", .ru = "Камера: x и y" } },
    .{ .key = "Point.name", .msg = .{ .en = "Name", .ru = "Имя" } },
    .{ .key = "Point.x", .msg = .{ .en = "X", .ru = "X" } },
    .{ .key = "Point.y", .msg = .{ .en = "Y", .ru = "Y" } },
    .{ .key = "Point.angle", .msg = .{ .en = "Angle, rad", .ru = "Угол, рад" } },
    .{ .key = "WeaponKind.none", .msg = .{ .en = "None", .ru = "Нет" } },
    .{ .key = "WeaponKind.fire", .msg = .{ .en = "Fire", .ru = "Огонь" } },
    .{ .key = "WeaponKind.freeze", .msg = .{ .en = "Cold", .ru = "Холод" } },
    .{ .key = "WeaponKind.electricity", .msg = .{ .en = "Electricity", .ru = "Электричество" } },
    .{ .key = "WeaponKind.teargas", .msg = .{ .en = "Tear gas", .ru = "Слезоточивый газ" } },
    .{ .key = "WeaponKind.gas", .msg = .{ .en = "Gas", .ru = "Газ" } },
    .{ .key = "WeaponKind.bullet", .msg = .{ .en = "Bullets", .ru = "Пули" } },
    .{ .key = "WeaponKind.melee", .msg = .{ .en = "Melee", .ru = "Рукопашный" } },
    .{ .key = "WeaponKind.tranq", .msg = .{ .en = "Tranquilizer", .ru = "Транквилизатор" } },
    .{ .key = "WeaponKind.energy", .msg = .{ .en = "Energy", .ru = "Энергия" } },
    .{ .key = "WeaponKind.attract", .msg = .{ .en = "Decoy", .ru = "Приманка" } },
    .{ .key = "WeaponKind.explosion", .msg = .{ .en = "Explosion", .ru = "Взрыв" } },
    .{ .key = "WeaponKind.flammable", .msg = .{ .en = "Fuel", .ru = "Горючее" } },
    .{ .key = "ArmorClass.light", .msg = .{ .en = "Light", .ru = "Лёгкая" } },
    .{ .key = "ArmorClass.medium", .msg = .{ .en = "Medium", .ru = "Средняя" } },
    .{ .key = "ArmorClass.heavy", .msg = .{ .en = "Heavy", .ru = "Тяжёлая" } },
    .{ .key = "ArmorClass.none", .msg = .{ .en = "None", .ru = "Нет" } },
    .{ .key = "Gender.male", .msg = .{ .en = "Male", .ru = "Мужской" } },
    .{ .key = "Gender.female", .msg = .{ .en = "Female", .ru = "Женский" } },
    .{ .key = "AiMode.free", .msg = .{ .en = "Free", .ru = "Свободно" } },
    .{ .key = "AiMode.target", .msg = .{ .en = "Only its target", .ru = "Только по цели" } },
    .{ .key = "AiMode.passive", .msg = .{ .en = "Skips its turn", .ru = "Пропускает ход" } },
    .{ .key = "AiMode.guard", .msg = .{ .en = "Guards its tile", .ru = "Охраняет клетку" } },
    .{ .key = "AiProfile.scoring", .msg = .{ .en = "Scoring", .ru = "Оценка" } },
    .{ .key = "AiProfile.attack_weight", .msg = .{ .en = "Attack weight", .ru = "Вес атаки" } },
    .{ .key = "AiProfile.threat_weight", .msg = .{ .en = "Threat weight", .ru = "Вес угрозы" } },
    .{ .key = "AiProfile.opponent_distance_weight", .msg = .{ .en = "Distance weight", .ru = "Вес расстояния" } },
    .{ .key = "AiProfile.guard_distance_weight", .msg = .{ .en = "Guard point weight", .ru = "Вес точки охраны" } },
    .{ .key = "AiProfile.mode", .msg = .{ .en = "Mode", .ru = "Режим" } },
    .{ .key = "AiProfile.damage_bonus", .msg = .{ .en = "Damage bonus", .ru = "Бонус урона" } },
    .{ .key = "AiProfile.ally_penalty", .msg = .{ .en = "Ally penalty", .ru = "Штраф за союзника" } },
    .{ .key = "AiProfile.lock", .msg = .{ .en = "Locked target x%", .ru = "Цель по приказу x%" } },
    .{ .key = "AiProfile.monitor", .msg = .{ .en = "Monitor x", .ru = "Монитор x" } },
    .{ .key = "AiProfile.decoy_pull", .msg = .{ .en = "Decoy pull", .ru = "Тяга приманки" } },
    .{ .key = "AiProfile.decoys", .msg = .{ .en = "Follows decoys", .ru = "Идёт на приманки" } },
    .{ .key = "AiProfile.step_away", .msg = .{ .en = "Steps away after a strike", .ru = "Отходит после удара" } },
    .{ .key = "AiProfile.threat", .msg = .{ .en = "Weighs threat", .ru = "Учитывает угрозу" } },
    .{ .key = "AiProfile.keep", .msg = .{ .en = "Weapons it plans with", .ru = "Чем планирует" } },
    .{ .key = "AiProfile.occupant", .msg = .{ .en = "Worth on a hit tile", .ru = "Ценность на клетке" } },
    .{ .key = "AiProfile.tile", .msg = .{ .en = "What of a hit tile", .ru = "Что на клетке" } },
    .{ .key = "AiProfile.wakeful", .msg = .{ .en = "Plans asleep", .ru = "Планирует во сне" } },
    .{ .key = "AiProfile.near", .msg = .{ .en = "Stays near", .ru = "Держится рядом" } },
    .{ .key = "Camera.perspective", .msg = .{ .en = "Perspective", .ru = "Перспектива" } },
    .{ .key = "Camera.near_plane", .msg = .{ .en = "Near plane", .ru = "Ближняя плоскость" } },
    .{ .key = "Camera.far_plane", .msg = .{ .en = "Far plane", .ru = "Дальняя плоскость" } },
    .{ .key = "Camera.ortho_rotation_radians", .msg = .{ .en = "Isometric rotation, rad", .ru = "Поворот изометрии, рад" } },
    .{ .key = "Camera.eye_x", .msg = .{ .en = "Eye X", .ru = "Глаз X" } },
    .{ .key = "Camera.eye_y", .msg = .{ .en = "Eye Y", .ru = "Глаз Y" } },
    .{ .key = "Camera.eye_z", .msg = .{ .en = "Eye Z", .ru = "Глаз Z" } },
    .{ .key = "Camera.target_x", .msg = .{ .en = "Target X", .ru = "Цель X" } },
    .{ .key = "Camera.target_y", .msg = .{ .en = "Target Y", .ru = "Цель Y" } },
    .{ .key = "Camera.target_z", .msg = .{ .en = "Target Z", .ru = "Цель Z" } },
    .{ .key = "Camera.fov", .msg = .{ .en = "Field of view", .ru = "Угол обзора" } },
    .{ .key = "Camera.floor_z", .msg = .{ .en = "Floor level", .ru = "Уровень пола" } },
    .{ .key = "Camera.camera_scale", .msg = .{ .en = "Scale", .ru = "Масштаб" } },
    .{ .key = "Camera.aspect_ratio", .msg = .{ .en = "Aspect ratio", .ru = "Соотношение сторон" } },
    .{ .key = "Camera.camera_bank", .msg = .{ .en = "Bank", .ru = "Крен" } },
    .{ .key = "Speed.anim", .msg = .{ .en = "Animation", .ru = "Анимация" } },
    .{ .key = "Speed.speed", .msg = .{ .en = "Speed", .ru = "Скорость" } },
    .{ .key = "Idle.state", .msg = .{ .en = "State", .ru = "Состояние" } },
    .{ .key = "Idle.anim", .msg = .{ .en = "Animation", .ru = "Анимация" } },
    .{ .key = "Idle.weight", .msg = .{ .en = "Weight", .ru = "Вес" } },
    .{ .key = "Slot.state", .msg = .{ .en = "State", .ru = "Состояние" } },
    .{ .key = "Slot.name", .msg = .{ .en = "Slot", .ru = "Слот" } },
    .{ .key = "Slot.anim", .msg = .{ .en = "Animation", .ru = "Анимация" } },
};

/// Names of the engine prelude's types as a list editor shows them («Слот 1», «+ Слот»);
/// a project's own types show theirs as declared.
pub const prelude_types = [_]struct { key: []const u8, msg: Msg }{
    .{ .key = "ItemPlace", .msg = .{ .en = "Item place", .ru = "Место предмета" } },
    .{ .key = "ItemKind", .msg = .{ .en = "Item kind", .ru = "Вид предмета" } },
    .{ .key = "WeaponKind", .msg = .{ .en = "Damage kind", .ru = "Вид урона" } },
    .{ .key = "Resistance", .msg = .{ .en = "Resistance", .ru = "Сопротивление" } },
    .{ .key = "Effect", .msg = .{ .en = "Hit effect", .ru = "Эффект попадания" } },
    .{ .key = "ArmorClass", .msg = .{ .en = "Armour class", .ru = "Класс брони" } },
    .{ .key = "Gender", .msg = .{ .en = "Gender", .ru = "Пол" } },
    .{ .key = "AiMode", .msg = .{ .en = "AI mode", .ru = "Режим ИИ" } },
    .{ .key = "Side", .msg = .{ .en = "Side", .ru = "Сторона" } },
    .{ .key = "Place", .msg = .{ .en = "Place", .ru = "Место" } },
    .{ .key = "PathPoint", .msg = .{ .en = "Path point", .ru = "Точка пути" } },
    .{ .key = "Line", .msg = .{ .en = "Dialog line", .ru = "Реплика" } },
    .{ .key = "Point", .msg = .{ .en = "Scene point", .ru = "Точка сцены" } },
    .{ .key = "Camera", .msg = .{ .en = "Camera", .ru = "Камера" } },
    .{ .key = "Speed", .msg = .{ .en = "Walk speed", .ru = "Скорость ходьбы" } },
    .{ .key = "Idle", .msg = .{ .en = "Idle", .ru = "Ожидание" } },
    .{ .key = "Slot", .msg = .{ .en = "Slot", .ru = "Слот" } },
    .{ .key = "AiProfile", .msg = .{ .en = "AI profile", .ru = "Профиль ИИ" } },
};

/// Prelude type `name` in the interface language; null: not the prelude's.
pub fn preludeType(name: []const u8) ?[]const u8 {
    for (prelude_types) |x| if (std.mem.eql(u8, x.key, name)) return get(x.msg);
    return null;
}

/// Prelude label `Type.name` in the interface language; null: not the prelude's.
pub fn preludeLabel(type_name: []const u8, name: []const u8) ?[]const u8 {
    for (prelude) |x| {
        const k = x.key;
        if (k.len == type_name.len + 1 + name.len and std.mem.startsWith(u8, k, type_name) and k[type_name.len] == '.' and std.mem.endsWith(u8, k, name)) return get(x.msg);
    }
    return null;
}
pub const at_traits: Msg = .{ .en = "Traits", .ru = "Трейты" };
pub const at_code_comps: Msg = .{ .en = "Code components", .ru = "Компоненты кода" };
pub const tr_builtin: Msg = .{ .en = "built-in", .ru = "встроенный" };
pub const tr_project: Msg = .{ .en = "project", .ru = "проекта" };
pub const tr_native: Msg = .{ .en = "native", .ru = "нативный" };
pub const tr_kind_host: Msg = .{ .en = "host kind · for {s}", .ru = "вид хоста · for {s}" };
pub const tr_kind_role: Msg = .{ .en = "role: the engine grants it", .ru = "роль: её выдаёт движок" };
pub const tr_kind_mark: Msg = .{ .en = "mark: turns engine code on", .ru = "метка: включает код движка" };
pub const tr_hint_builtin: Msg = .{ .en = "An engine trait (foundation/traits.ogs, as engine.ogs): read only. {s}", .ru = "Трейт движка (foundation/traits.ogs, в редакторе — engine.ogs): только для чтения. {s}" };
pub const tr_hint_script: Msg = .{ .en = "A trait of the project's code ({s}:{d}): edited as code.", .ru = "Трейт кода проекта ({s}:{d}): правится как код." };
pub const tr_supers: Msg = .{ .en = "Supertraits: {s}", .ru = "Супертрейты: {s}" };
pub const tr_methods: Msg = .{ .en = "Methods", .ru = "Методы" };
pub const tr_required: Msg = .{ .en = "required", .ru = "обязательный" };
pub const tr_has_default: Msg = .{ .en = "has a default", .ru = "есть тело по умолчанию" };
pub const tr_engine_method: Msg = .{ .en = "the engine's", .ru = "метод движка" };
pub const tr_not_live: Msg = .{ .en = "not called yet", .ru = "пока не вызывается" };
pub const tr_rule: Msg = .{ .en = "rule: {s}", .ru = "правило: {s}" };
pub const tr_when: Msg = .{ .en = "When: {s}", .ru = "Когда: {s}" };
pub const tr_no_answer: Msg = .{ .en = "Nobody answers: {s}", .ru = "Без ответа: {s}" };
pub const tr_classic: Msg = .{ .en = "Classic: {s}", .ru = "Classic: {s}" };
pub const tr_who: Msg = .{ .en = "Who implements it", .ru = "Кто реализует" };
pub const tr_who_none: Msg = .{ .en = "No component of the project.", .ru = "Ни один компонент проекта." };
pub const tr_prelude: Msg = .{ .en = "engine.ogs", .ru = "engine.ogs" };
pub const tr_open_code: Msg = .{ .en = "Open the code", .ru = "Открыть код" };
pub const tr_missing: Msg = .{ .en = "No {s} in the project's code.", .ru = "В коде проекта нет {s}." };
pub const cp_hint: Msg = .{ .en = "A component of the project's code ({s}:{d}): its methods and params are edited as code; characters attach it in their Components block.", .ru = "Компонент кода проекта ({s}:{d}): методы и параметры правятся в коде; персонажи подключают его в блоке «Компоненты»." };
pub const cp_for: Msg = .{ .en = "for {s}", .ru = "for {s}" };
pub const cp_any_host: Msg = .{ .en = "for any host (no engine events)", .ru = "для любого хоста (без событий движка)" };
pub const cp_implements: Msg = .{ .en = "implements {s}", .ru = "реализует {s}" };
pub const cp_params: Msg = .{ .en = "Params", .ru = "Параметры" };
pub const cp_params_none: Msg = .{ .en = "No params.", .ru = "Параметров нет." };
pub const cp_own: Msg = .{ .en = "own", .ru = "свой" };
pub const cp_from: Msg = .{ .en = "from {s}", .ru = "из {s}" };
pub const cp_override: Msg = .{ .en = "Override", .ru = "Переопределить" };
pub const cp_stub: Msg = .{ .en = "Stub", .ru = "Заготовка" };
pub const cp_implement: Msg = .{ .en = "Implement {s}", .ru = "Реализовать {s}" };
pub const cp_required_by: Msg = .{ .en = "required by {s}: not defined", .ru = "обязателен для {s}: не определён" };
pub const cp_used: Msg = .{ .en = "Where used", .ru = "Где используется" };
pub const cp_used_none: Msg = .{ .en = "No character has it.", .ru = "Ни у одного персонажа." };
pub const nc_hint: Msg = .{ .en = "A native component: the engine's code (core/natives.zig), attached by a character's Abilities row as the object is made; its params are object variables of its instance.", .ru = "Нативный компонент: код движка (core/natives.zig), его подключает строка Abilities персонажа при создании объекта; его параметры — переменные объекта экземпляра." };
pub const nc_implements: Msg = .{ .en = "Implements", .ru = "Реализует" };
pub const camp_sec_panel: Msg = .{ .en = "Bottom panel", .ru = "Нижняя панель" };
pub const camp_panel_none: Msg = .{ .en = "The game has no game_box.spr.", .ru = "В игре нет game_box.spr." };
pub const camp_panel_pick: Msg = .{ .en = "Click a rectangle to pick it, drag it to move it.", .ru = "Щёлкните прямоугольник, чтобы выбрать его, тащите, чтобы сдвинуть." };
pub const camp_panel_add: Msg = .{ .en = "Add a portrait slot", .ru = "Добавить слот портрета" };
pub const camp_panel_note: Msg = .{ .en = "Places on game_box.spr from the panel's top (rules ui.ss PanelPlace), in the exe's order: hit test and drawing go in it. Only a slot the project added can be removed; the controls are the exe's, each once.", .ru = "Места на game_box.spr от верха панели (правила ui.ss PanelPlace) в порядке exe: в нём проверка нажатий и рисование. Убрать можно только слот, добавленный проектом; кнопки — из exe, каждая один раз." };
pub const tag_proto: Msg = .{ .en = "{s} (Prototype)", .ru = "{s} (Прототип)" };
pub const c_name_goto: Msg = .{ .en = "Edit in Texts", .ru = "К текстам" };
pub const c_armor_none: Msg = .{ .en = "{d} · none: full damage", .ru = "{d} · нет: полный урон" };
pub const c_armor_light: Msg = .{ .en = "0 · light: the weapon's lightArmor %", .ru = "0 · лёгкая: lightArmor % оружия" };
pub const c_armor_medium: Msg = .{ .en = "1 · medium: the weapon's mediumArmor %", .ru = "1 · средняя: mediumArmor % оружия" };
pub const c_armor_heavy: Msg = .{ .en = "2 · heavy: the weapon's heavyArmor %", .ru = "2 · тяжёлая: heavyArmor % оружия" };
pub const c_armor_note: Msg = .{ .en = "A monster's armour picks which of the weapon's lightArmor, mediumArmor, heavyArmor percents its damage loses (0x49123e); any other number: none. The Armour class of the resistances below wins when higher.", .ru = "Броня монстра выбирает, какой процент оружия (lightArmor, mediumArmor, heavyArmor) срезается с урона (0x49123e); любое другое число — нет брони. Класс брони сопротивлений ниже побеждает, если выше." };
pub const ai_pick: Msg = .{ .en = "AI profile", .ru = "Профиль ИИ" };
pub const ai_pick_note: Msg = .{ .en = "Its classType's profile, or its own row (by its class) when one is chosen; profiles are edited on the AI profiles page.", .ru = "Профиль её classType или своя строка (по её классу), если выбрана другая; профили меняются на странице «Профили ИИ»." };
pub const ai_own: Msg = .{ .en = "{s} (own row)", .ru = "{s} (своя строка)" };
pub const aip_title: Msg = .{ .en = "AI profiles", .ru = "Профили ИИ" };
pub const aip_og_hint: Msg = .{ .en = "Battle AI profiles (src/ai/*.ogs): a profile is its base's fields with its own over them; a character names its one (ai_profile = ai::garcia), the game its default.", .ru = "Профили боевого ИИ (src/ai/*.ogs): профиль — поля базового и свои поверх; персонаж называет свой (ai_profile = ai::garcia), игра — профиль по умолчанию." };
pub const aip_sub_fighter: Msg = .{ .en = "Over the fighters' own", .ru = "Поверх полей бойца" };
pub const aip_fighter: Msg = .{ .en = "the fighter's {s}", .ru = "у бойца ({s})" };
pub const aip_fighter_note: Msg = .{ .en = "Unset, each fighter uses its own field (its block's ai_mode, ai_attack_weight…); set here, every fighter with this profile uses this one.", .ru = "Не задано — каждый боец берёт своё поле (ai_mode, ai_attack_weight… в его блоке); задано здесь — у всех бойцов с этим профилем будет это значение." };
pub const aip_base: Msg = .{ .en = "Based on", .ru = "Основан на" };
pub const aip_base_note: Msg = .{ .en = "The profile whose fields this one takes where it has none of its own.", .ru = "Профиль, чьи поля этот берёт там, где своих нет." };
pub const aip_reset: Msg = .{ .en = "Reset", .ru = "Сбросить" };
pub const aip_from: Msg = .{ .en = "from {s}", .ru = "из {s}" };
pub const aip_engine: Msg = .{ .en = "the engine's", .ru = "движка" };
pub const aip_score_none: Msg = .{ .en = "the usual formula", .ru = "обычная формула" };
pub const aip_used: Msg = .{ .en = "Used by", .ru = "Используют" };
pub const aip_unused: Msg = .{ .en = "No character or profile names it.", .ru = "Ни один персонаж и профиль его не называет." };
pub const aim_free: Msg = .{ .en = "Free", .ru = "Свободно" };
pub const aim_target: Msg = .{ .en = "Only its target", .ru = "Только своя цель" };
pub const aim_passive: Msg = .{ .en = "Skips its turn", .ru = "Пропускает ход" };
pub const aim_guard: Msg = .{ .en = "Guards its tile", .ru = "Охраняет клетку" };
pub const aip_hint: Msg = .{ .en = "Battle AI by fighter class (AiProfile rows: rules/ai.ogs in OpenGorky, rules\\ai.ss over the exe's table 0x4bcbb0 in Classic) and the tile scoring each one names in scoring (AiScoring). An enemy chooses its profile on its page.", .ru = "ИИ в бою по классу бойца (строки AiProfile: rules/ai.ogs в OpenGorky, rules\\ai.ss поверх таблицы exe 0x4bcbb0 в Classic) и оценка клеток, которую каждый называет в scoring (AiScoring). Враг выбирает профиль на своей странице." };
pub const aip_sec: Msg = .{ .en = "Profiles", .ru = "Профили" };
pub const aip_sum: Msg = .{ .en = "{d} rows", .ru = "строк: {d}" };
pub const aip_pick: Msg = .{ .en = "Pick a profile in the list", .ru = "Выберите профиль в списке" };
pub const chip_ai: Msg = .{ .en = "AI profile", .ru = "Профиль ИИ" };
pub const aip_used_none: Msg = .{ .en = "No enemy uses it", .ru = "Ни один враг его не использует" };
pub const st_ai_profile: Msg = .{ .en = "{s}: AI profile {s}", .ru = "{s}: профиль ИИ {s}" };
pub const wc_kind: Msg = .{ .en = "Battle code", .ru = "Боевой код" };
pub const val_sec_battle: Msg = .{ .en = "Growth and battle", .ru = "Рост и бой" };
pub const val_battle_note: Msg = .{ .en = "Numbers of the exe's exp, level-up and strike formulas; _pm values are per mille (1200 = x1.2).", .ru = "Числа формул опыта, повышения уровня и удара из exe; значения _pm — в промилле (1200 = x1.2)." };
pub const la_chip_location: Msg = .{ .en = "Location", .ru = "Локация" };
pub const la_chip_battle: Msg = .{ .en = "Battle", .ru = "Бой" };
pub const la_campaign_start: Msg = .{ .en = "The campaign starts here (a new game)", .ru = "Здесь начинается кампания (новая игра)" };
pub const la_used_none_battle: Msg = .{ .en = "No level's or scene's script starts it", .ru = "Его не запускает ни один скрипт уровня или сцены" };
pub const la_music: Msg = .{ .en = "Music", .ru = "Музыка" };
pub const la_music_track: Msg = .{ .en = "Track", .ru = "Трек" };
pub const la_music_none: Msg = .{ .en = "No track: the music playing before goes on", .ru = "Трека нет: играет прежняя музыка" };
pub const la_music_hint: Msg = .{ .en = "The game picks it by the level's name; a track picked here is copied as the level's own (<level>.mp3), so the original plays it too.", .ru = "Игра выбирает её по имени уровня; выбранный здесь трек копируется как свой (<уровень>.mp3), так что его играет и оригинал." };
pub const la_scenes: Msg = .{ .en = "Scenes", .ru = "Сцены" };
pub const la_scenes_hint: Msg = .{ .en = "The scenes its scripts start; a start is added on an area's trigger (the edit mode, right click the area).", .ru = "Сцены, которые запускают её скрипты; запуск добавляется в триггере зоны (режим правки, правый клик по зоне)." };
pub const la_chars: Msg = .{ .en = "Characters present", .ru = "Персонажи на карте" };
pub const la_items: Msg = .{ .en = "Items", .ru = "Предметы" };
pub const la_exits: Msg = .{ .en = "Exits", .ru = "Выходы" };
pub const la_exits_hint: Msg = .{ .en = "Drawn with the Exit tool of the edit mode; the arrow opens the level it leads to.", .ru = "Рисуются инструментом «Выход» в режиме правки; стрелка открывает уровень, куда он ведёт." };
pub const la_enemies: Msg = .{ .en = "Enemies", .ru = "Враги" };
pub const la_party: Msg = .{ .en = "Party / heroes", .ru = "Отряд / герои" };
pub const la_none: Msg = .{ .en = "None", .ru = "Нет" };
pub const la_place_hint: Msg = .{ .en = "Placed, moved and turned on the map (the edit mode); the arrow opens its page, where it is edited.", .ru = "Ставятся, двигаются и поворачиваются на карте (режим правки); стрелка открывает его страницу, там он правится." };
pub const la_place_hint_battle: Msg = .{ .en = "Placed, moved and turned on the grid (the edit mode); the arrow opens its character's page; a picked enemy's own values for this battle are in the block under the enemies.", .ru = "Ставятся, двигаются и поворачиваются на сетке (режим правки); стрелка открывает страницу персонажа; свои значения выбранного врага в этом бою — в блоке под врагами." };
pub const la_rules: Msg = .{ .en = "Rules and outcome", .ru = "Правила и исход" };
pub const la_field: Msg = .{ .en = "Battlefield", .ru = "Поле боя" };
pub const la_field_self: Msg = .{ .en = "its own map", .ru = "своя карта" };
pub const la_boss: Msg = .{ .en = "Boss battle", .ru = "Бой с боссом" };
pub const la_yes: Msg = .{ .en = "yes", .ru = "да" };
pub const la_no: Msg = .{ .en = "no", .ru = "нет" };
pub const la_rules_note: Msg = .{ .en = "Set by its script (mode: the exe's mid-battle lines and who acts first; a boss's: its music). Won when every enemy is dead, lost when a hero dies (the exe's; OpenGorky: the core module Battle).", .ru = "Задаются его скриптом (mode — реплики посреди боя и кто ходит первым в exe; босс — его музыка). Победа — все враги мертвы, поражение — погиб герой (как в exe; OpenGorky — модуль ядра Battle)." };
pub const la_play: Msg = .{ .en = "Play the battle", .ru = "Играть бой" };
pub const la_party_hint: Msg = .{ .en = "Placed on the grid (the edit mode); the arrow opens the hero's page.", .ru = "Ставятся на сетку (режим правки); стрелка открывает страницу героя." };

// «Перевести проект в OpenGorky…» (projconvert.zig).
pub const s_convert: Msg = .{ .en = "Convert to OpenGorky…", .ru = "Перевести проект в OpenGorky…" };
pub const cv_title: Msg = .{ .en = "Convert the project to OpenGorky", .ru = "Перевод проекта в OpenGorky" };
pub const cv_intro: Msg = .{ .en = "The project becomes a new OpenGorky project of OG Script in a folder of its own: its src/ texts, the assets it changed, the manifest naming the installed game. This Classic project and the installed game are not changed; the editor then opens the new project and builds its dist/.", .ru = "Проект становится новым проектом OpenGorky на OG Script в своей папке: тексты src/, изменённые им ассеты и манифест с путём к установленной игре. Этот проект Classic и установленная игра не меняются; затем редактор открывает новый проект и собирает его dist/." };
pub const cv_folder: Msg = .{ .en = "Folder to create the new project in", .ru = "Папка, где создать новый проект" };
pub const cv_not_empty: Msg = .{ .en = "This folder has files in it: the converter writes only into a new or empty folder. Choose another one.", .ru = "В этой папке уже есть файлы: конвертер пишет только в новую или пустую папку. Выберите другую." };
pub const cv_go: Msg = .{ .en = "Convert", .ru = "Перевести" };
pub const cv_step: Msg = .{ .en = "Step {d} of {d}: {s}", .ru = "Шаг {d} из {d}: {s}" };
pub const cv_count: Msg = .{ .en = "{d} of {d}", .ru = "{d} из {d}" };
pub const cv_count_open: Msg = .{ .en = "{d} done", .ru = "готово: {d}" };
pub const cv_canceling: Msg = .{ .en = "Canceling…", .ru = "Отмена…" };
pub const cv_running_hint: Msg = .{ .en = "Cancel leaves nothing in the folder.", .ru = "После отмены в папке ничего не останется." };
pub const cv_read: Msg = .{ .en = "reading the Classic project", .ru = "чтение проекта Classic" };
pub const cv_locations: Msg = .{ .en = "locations and battles", .ru = "локации и бои" };
pub const cv_scenes: Msg = .{ .en = "scenes", .ru = "сцены" };
pub const cv_dialogs: Msg = .{ .en = "dialogs", .ru = "диалоги" };
pub const cv_rules: Msg = .{ .en = "rules and texts", .ru = "правила и тексты" };
pub const cv_assets: Msg = .{ .en = "own assets", .ru = "свои ассеты" };
pub const cv_write: Msg = .{ .en = "writing the project", .ru = "запись проекта" };
pub const cv_build: Msg = .{ .en = "building dist/", .ru = "сборка dist/" };
pub const cv_failed_title: Msg = .{ .en = "Not converted", .ru = "Проект не переведён" };
pub const cv_failed_at: Msg = .{ .en = "Failed at «{s}»: {t}", .ru = "Сбой на шаге «{s}»: {t}" };
pub const cv_failed_hint: Msg = .{ .en = "The editor stays in the Classic project; nothing was left in the chosen folder. The run's log:", .ru = "Редактор остаётся в проекте Classic; в выбранной папке ничего не осталось. Журнал хода:" };
pub const cv_done_title: Msg = .{ .en = "Converted to OpenGorky", .ru = "Проект переведён в OpenGorky" };
pub const cv_done_at: Msg = .{ .en = "The new project: {s}", .ru = "Новый проект: {s}" };
pub const cv_done_hint: Msg = .{ .en = "The editor is in it now; dist/ is built.", .ru = "Редактор уже открыт в нём, dist/ собран." };
pub const cv_folder_hint: Msg = .{ .en = "A new folder or an empty one; offered: «<game title> (OpenGorky)» beside the game.", .ru = "Новая или пустая папка; по умолчанию — «<название игры> (OpenGorky)» рядом с игрой." };
pub const cv_n_objects: Msg = .{ .en = "objects", .ru = "объектов" };
pub const cv_n_components: Msg = .{ .en = "components", .ru = "компонентов" };
pub const cv_n_looks: Msg = .{ .en = "looks", .ru = "обликов" };
pub const cv_n_fields: Msg = .{ .en = "fields", .ru = "полей" };
pub const cv_n_vars: Msg = .{ .en = "variables", .ru = "переменных" };
pub const cv_n_scenes: Msg = .{ .en = "scenes", .ru = "сцен" };
pub const cv_n_dialogs: Msg = .{ .en = "dialogs", .ru = "диалогов" };
pub const cv_n_texts: Msg = .{ .en = "texts", .ru = "текстов" };
pub const cv_n_rows: Msg = .{ .en = "rules rows", .ru = "строк правил" };
pub const cv_n_assets: Msg = .{ .en = "own assets", .ru = "своих ассетов" };
pub const cv_n_placed: Msg = .{ .en = "placings as data", .ru = "расстановок данными" };
pub const cv_n_entries: Msg = .{ .en = "files in dist/", .ru = "файлов в dist/" };
pub const cv_g_errors: Msg = .{ .en = "Build errors: {d} — dist/ is not written; see the full list.", .ru = "Ошибок сборки: {d} — dist/ не записан, см. полный список." };
pub const cv_g_notes: Msg = .{ .en = "Files the converter left out: {d} — see the full list.", .ru = "Файлов, которые конвертер пропустил: {d} — см. полный список." };
pub const cv_g_warnings: Msg = .{ .en = "Build warnings: {d}.", .ru = "Предупреждений сборки: {d}." };
pub const cv_g_anims: Msg = .{ .en = "{d} animations named by looks are missing from their models — the original game's too, not an error.", .ru = "Анимаций, которых нет в моделях: {d} — так и в оригинальной игре, это не ошибка." };
pub const cv_g_none: Msg = .{ .en = "No warnings.", .ru = "Предупреждений нет." };
pub const cv_all: Msg = .{ .en = "Full list: the counts, the converter's notes, the build", .ru = "Полный список: счёт, заметки конвертера, сборка" };
pub const st_cv_canceled: Msg = .{ .en = "Conversion canceled", .ru = "Перевод отменён" };
pub const st_cv_failed: Msg = .{ .en = "not converted: {t}", .ru = "не переведено: {t}" };
pub const st_cv_done: Msg = .{ .en = "Converted to OpenGorky: {s}", .ru = "Переведено в OpenGorky: {s}" };
