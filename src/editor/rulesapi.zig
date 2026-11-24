//! The calls of the rules files (`rules\*.ss`: the rows of src/rules/rows.zig and the
//! core modules' records, core/modules.zig `Tables`) for the code editor's help, as
//! api.zig is for the scripts: what each call and each of its fields is (English,
//! Russian; from the row types' `doc`), the words a word field takes, what a number
//! field names (`Ref`). A field's type and default come from the row type itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const rules = og.rules;
const modules = og.core.modules;
const codec = og.loaders.codec;

/// English, Russian.
pub const Doc = @import("text.zig").Msg;

/// A value a word field takes and what it means.
const Word = struct { name: []const u8, doc: Doc };

/// What a number field names (its meaning shown beside it).
pub const Ref = enum {
    none,
    /// A classic_id (or a "1 2 3" list of them): a class's or hero's name.
    name_id,
    /// A fighter classType (battle/fighter.zig Class, factory 0x4bc6c0).
    fighter_class,
    /// A weapon class: its name (WeaponClass, Pattern; factory 0x4b4c00).
    weapon_class,
    /// A string.tab number.
    text,
};

/// WeaponClass and Pattern: the class's name and the exe's number.
const class_name: Field = .{ .name = "name", .ref = .weapon_class, .doc = .{ .en = "the class's name, as weapons name it (class = pistol)", .ru = "имя класса, так его называет оружие (class = pistol)" } };
const class_number: Field = .{ .name = "classic_id", .doc = .{ .en = "the exe's classType (only the built-in classes need it; a new name gets a free number)", .ru = "classType у exe (нужен только встроенным классам; новое имя получает свободный номер)" } };

pub const Field = struct { name: []const u8, doc: Doc, ref: Ref = .none, words: []const Word = &.{} };

pub const Call = struct { name: []const u8, doc: Doc, fields: []const Field };

pub fn find(name: []const u8) ?*const Call {
    for (&all) |*c| if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    return null;
}

pub fn field(c: *const Call, name: []const u8) ?*const Field {
    for (c.fields) |*f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    return null;
}

/// Word `value` of field `f` (quotes aside), if it is one.
pub fn word(f: *const Field, value: []const u8) ?*const Word {
    const v = std.mem.trim(u8, value, "\" ");
    for (f.words) |*w| if (std.ascii.eqlIgnoreCase(w.name, v)) return w;
    return null;
}

/// The row type of call `name` handed to `ctx.with(Row)`; false for no table's.
fn withRow(name: []const u8, ctx: anytype) bool {
    inline for (.{ rules.Set, modules.Tables }) |S| inline for (@typeInfo(S).@"struct".field_names) |n| {
        const Row = @typeInfo(@FieldType(S, n)).pointer.child;
        if (std.ascii.eqlIgnoreCase(name, Row.call)) {
            ctx.with(Row);
            return true;
        }
    };
    return false;
}

/// Field `f` of call `c`: its type as the file writes it and its default ("" when it
/// has none: the call must write it, or `optional`: left out, the built-in row's stays).
const Shape = struct { ty: []const u8 = "", default: []const u8 = "", optional: bool = false };

pub fn shape(a: Allocator, c: []const u8, f: []const u8) Shape {
    if (std.ascii.eqlIgnoreCase(c, "adjust")) return .{ .ty = if (std.mem.eql(u8, f, "name")) "string" else "int" };
    const Ctx = struct {
        a: Allocator,
        f: []const u8,
        out: Shape = .{},
        fn with(self: *@This(), comptime Row: type) void {
            const info = @typeInfo(Row).@"struct";
            inline for (info.field_names, info.field_types, info.field_attrs) |n, T, attrs| if (std.mem.eql(u8, n, self.f)) {
                self.out.ty = comptime typeName(T) ++ (if (@hasField(Row, n ++ "_class")) " | \"class\"" else "");
                if (attrs.defaultValue(T)) |d| {
                    var aw: std.Io.Writer.Allocating = .init(self.a);
                    codec.writeValue(T, &aw.writer, d) catch {};
                    self.out.optional = @typeInfo(T) == .optional and d == null;
                    if (!self.out.optional) self.out.default = aw.written();
                }
            };
        }
    };
    var ctx: Ctx = .{ .a = a, .f = f };
    _ = withRow(c, &ctx);
    return ctx.out;
}

/// A field type as the rules files write it.
fn typeName(comptime T: type) []const u8 {
    const rows = rules.rows;
    return comptime switch (T) {
        bool => "0 | 1",
        []const u8 => "string",
        []const i32 => "\"n n …\"",
        rows.Num => "n | adjust(\"name\", n) + n",
        rows.Flags => "\"word word …\"",
        rows.Rays, rows.Effects => "\"pattern\"",
        og.core.effect.Val => "n | Val(…)",
        else => switch (@typeInfo(T)) {
            .int => "int",
            .float => "float",
            .optional => |o| typeName(o.child),
            .@"enum" => |e| blk: {
                var out: []const u8 = "";
                for (e.field_names, 0..) |n, k| out = out ++ (if (k > 0) " | " else "") ++ "\"" ++ n ++ "\"";
                break :blk out;
            },
            .array => |r| std.fmt.comptimePrint("list({d} × {s})", .{ r.len, typeName(r.child) }),
            .pointer => |p| "list(" ++ typeName(p.child) ++ ", …)",
            .@"union" => "kind(…)",
            .@"struct" => short(T) ++ "(…)",
            else => @typeName(T),
        },
    };
}

fn short(comptime T: type) []const u8 {
    const n = @typeName(T);
    return n[if (comptime std.mem.lastIndexOfScalar(u8, n, '.')) |k| k + 1 else 0..];
}

// ---------------------------------------------------------------- words

const evals = [_]Word{
    .{ .name = "generic", .doc = .{ .en = "an ordinary monster's scoring (0x499170)", .ru = "оценка обычного монстра (0x499170)" } },
    .{ .name = "a", .doc = .{ .en = "\"scoring A\" (0x4dcb40): Stinger, Fatman, Puppet, the Judge", .ru = "«оценка A» (0x4dcb40): Жало, Толстяк, Кукла, Судья" } },
    .{ .name = "garcia", .doc = .{ .en = "Garcia: the long weapon only below half health", .ru = "Гарсия: дальнее оружие только при здоровье меньше половины" } },
    .{ .name = "smokerider", .doc = .{ .en = "Smoke Rider: tries its weapons even asleep, in a π/4 cone", .ru = "Курильщик: пробует оружие даже во сне, в конусе π/4" } },
    .{ .name = "grandma", .doc = .{ .en = "Grandma: only her child's killer", .ru = "Бабушка: только убийца её ребёнка" } },
    .{ .name = "grandma_child", .doc = .{ .en = "Grandma's child: stays within 3 tiles of her", .ru = "Ребёнок Бабушки: держится в 3 клетках от неё" } },
    .{ .name = "incubus", .doc = .{ .en = "Incubus: scores the hit tiles whole (0x4e2b50)", .ru = "Инкуб: оценивает клетки удара целиком (0x4e2b50)" } },
    .{ .name = "cripple", .doc = .{ .en = "Cripple: scoring A without the AITargetLock bonus", .ru = "Калека: оценка A без бонуса AITargetLock" } },
    .{ .name = "guard", .doc = .{ .en = "Guard (0x4e2260): melee on sleepers, the sleep shot on the awake", .ru = "Страж (0x4e2260): ближний бой по спящим, усыпляющий выстрел по бодрствующим" } },
    .{ .name = "schizo", .doc = .{ .en = "Schizo: +10 a hero, −100 others; the first weapon only", .ru = "Шизо: +10 за героя, −100 за остальных; только первое оружие" } },
    .{ .name = "messiah", .doc = .{ .en = "Messiah: opponents only, not the hand a box blocks", .ru = "Мессия: только противники, не рука, закрытая ящиком" } },
};

const parts = [_]Word{
    .{ .name = "attach", .doc = .{ .en = "an effect on a link point of the model", .ru = "эффект на точке связи модели" } },
    .{ .name = "bitmap", .doc = .{ .en = "an animated bitmap at a point", .ru = "анимированный битмап в точке" } },
    .{ .name = "explosion", .doc = .{ .en = "an explosion at the target, this much higher", .ru = "взрыв у цели, на столько выше" } },
    .{ .name = "light", .doc = .{ .en = "a light", .ru = "свет" } },
    .{ .name = "beam", .doc = .{ .en = "a beam between two points", .ru = "луч между двумя точками" } },
    .{ .name = "sound", .doc = .{ .en = "a sound at the striker after `ticks`", .ru = "звук у атакующего через `ticks`" } },
    .{ .name = "shake", .doc = .{ .en = "screen shake for this many ticks", .ru = "тряска экрана столько тиков" } },
    .{ .name = "emitter", .doc = .{ .en = "flame particles (mods: spread, gravity, drag, look)", .ru = "частицы пламени (моды: spread, gravity, drag, look)" } },
    .{ .name = "ribbon", .doc = .{ .en = "a stream between two points (the blaster's)", .ru = "поток между двумя точками (как у бластера)" } },
    .{ .name = "mesh", .doc = .{ .en = "a spinning mesh", .ru = "вращающийся меш" } },
    .{ .name = "cloud", .doc = .{ .en = "gas on the target", .ru = "газ на цели" } },
    .{ .name = "code", .doc = .{ .en = "a built-in preset by name (older files; dumped as data)", .ru = "встроенная заготовка по имени (старые файлы; выгружается данными)" } },
};

const resists = [_]Word{
    .{ .name = "fire", .doc = .{ .en = "fire", .ru = "огонь" } },
    .{ .name = "electricity", .doc = .{ .en = "electricity", .ru = "электричество" } },
    .{ .name = "attract", .doc = .{ .en = "decoys", .ru = "приманки" } },
    .{ .name = "energy", .doc = .{ .en = "energy weapons", .ru = "энергетическое оружие" } },
    .{ .name = "freeze", .doc = .{ .en = "cold", .ru = "холод" } },
    .{ .name = "tranq", .doc = .{ .en = "tranquilizers, sleep", .ru = "транквилизаторы, сон" } },
    .{ .name = "gas", .doc = .{ .en = "gas", .ru = "газ" } },
    .{ .name = "flammable", .doc = .{ .en = "fuel", .ru = "горючее" } },
};

const effects = [_]Word{
    .{ .name = "burn", .doc = .{ .en = "sets on fire", .ru = "поджигает" } },
    .{ .name = "freeze", .doc = .{ .en = "freezes", .ru = "замораживает" } },
    .{ .name = "gas", .doc = .{ .en = "gasses", .ru = "травит газом" } },
    .{ .name = "soak", .doc = .{ .en = "soaks with fuel (burning: 3 more turns of fire)", .ru = "обливает горючим (горящему — ещё 3 хода огня)" } },
    .{ .name = "defend", .doc = .{ .en = "defence stance", .ru = "стойка защиты" } },
    .{ .name = "sleep", .doc = .{ .en = "puts to sleep", .ru = "усыпляет" } },
    .{ .name = "bite", .doc = .{ .en = "the Invisible's incurable poison", .ru = "неизлечимый яд Невидимки" } },
};

const damage_kinds = [_]Word{
    .{ .name = "none", .doc = .{ .en = "the weapon's own", .ru = "своё у оружия" } },
    .{ .name = "fire", .doc = .{ .en = "fire", .ru = "огонь" } },
    .{ .name = "freeze", .doc = .{ .en = "cold", .ru = "холод" } },
    .{ .name = "electricity", .doc = .{ .en = "electricity", .ru = "электричество" } },
    .{ .name = "teargas", .doc = .{ .en = "tear gas", .ru = "слезоточивый газ" } },
    .{ .name = "gas", .doc = .{ .en = "gas", .ru = "газ" } },
    .{ .name = "bullet", .doc = .{ .en = "bullets", .ru = "пули" } },
    .{ .name = "melee", .doc = .{ .en = "melee", .ru = "ближний бой" } },
    .{ .name = "tranq", .doc = .{ .en = "tranquilizer", .ru = "снотворное" } },
    .{ .name = "energy", .doc = .{ .en = "energy", .ru = "энергия" } },
    .{ .name = "attract", .doc = .{ .en = "decoy", .ru = "приманка" } },
    .{ .name = "explosion", .doc = .{ .en = "explosion", .ru = "взрыв" } },
    .{ .name = "flammable", .doc = .{ .en = "fuel", .ru = "горючее" } },
};

const device_kinds = [_]Word{
    .{ .name = "time_bomb", .doc = .{ .en = "a hero's time bomb", .ru = "бомба героя с часами" } },
    .{ .name = "large_bomb", .doc = .{ .en = "the large bomb (PutLargeTimeBomb)", .ru = "большая бомба (PutLargeTimeBomb)" } },
    .{ .name = "decoy", .doc = .{ .en = "a decoy", .ru = "приманка" } },
    .{ .name = "blast", .doc = .{ .en = "the bomb's blast weapon", .ru = "оружие взрыва бомбы" } },
};

const medicine_kinds = [_]Word{
    .{ .name = "heal", .doc = .{ .en = "heals", .ru = "лечит" } },
    .{ .name = "rage", .doc = .{ .en = "enrages", .ru = "приводит в ярость" } },
    .{ .name = "calm", .doc = .{ .en = "calms", .ru = "успокаивает" } },
    .{ .name = "ungas", .doc = .{ .en = "cures gas", .ru = "снимает отравление газом" } },
    .{ .name = "wake", .doc = .{ .en = "wakes", .ru = "будит" } },
};

const action_kinds = [_]Word{
    .{ .name = "call", .doc = .{ .en = "only calls the function", .ru = "только вызывает функцию" } },
    .{ .name = "take", .doc = .{ .en = "Take, else UniversalTake (ammo merged)", .ru = "Take, иначе UniversalTake (патроны складываются)" } },
    .{ .name = "explore", .doc = .{ .en = "the box window", .ru = "окно ящика" } },
};

const consts = [_]Word{
    .{ .name = "idle_ticks", .doc = .{ .en = "ticks without input before the idle chatter", .ru = "тиков без ввода до праздной реплики" } },
    .{ .name = "party_max", .doc = .{ .en = "heroes in the party at most (the exe's 6)", .ru = "героев в отряде не больше (в exe 6)" } },
    .{ .name = "kill_exp_pm", .doc = .{ .en = "exp for a kill, per mille of the victim's max_hp (the exe's 200: 0.2)", .ru = "опыт за убийство, промилле от max_hp жертвы (в exe 200: 0.2)" } },
    .{ .name = "level_points", .doc = .{ .en = "stat points per level gained (the exe's 5)", .ru = "очков характеристик за уровень (в exe 5)" } },
    .{ .name = "stat_cap", .doc = .{ .en = "luck, accuracy and counterattack at most in the points window (the exe's 100)", .ru = "удача, меткость и контратака не больше в окне очков (в exe 100)" } },
    .{ .name = "skill_step", .doc = .{ .en = "weapon skill percent per skill level (the exe's 10)", .ru = "процент владения оружием за уровень навыка (в exe 10)" } },
    .{ .name = "crit_pm", .doc = .{ .en = "luck crit damage factor, per mille (the exe's 1200: x1.2)", .ru = "множитель урона удачного удара, промилле (в exe 1200: x1.2)" } },
    .{ .name = "rage_pm", .doc = .{ .en = "rage damage factor, per mille (the exe's 2000: x2)", .ru = "множитель урона в ярости, промилле (в exe 2000: x2)" } },
    .{ .name = "side_bonus", .doc = .{ .en = "damage bonus of a strike from the side (the exe's 2)", .ru = "прибавка урона при ударе сбоку (в exe 2)" } },
    .{ .name = "back_bonus", .doc = .{ .en = "damage bonus of a strike from the back (the exe's 4)", .ru = "прибавка урона при ударе в спину (в exe 4)" } },
    .{ .name = "counter_step", .doc = .{ .en = "counter-attack roll: rand % 1000 <= counterAttack x this (the exe's 10)", .ru = "бросок контратаки: rand % 1000 <= counterAttack x это (в exe 10)" } },
    .{ .name = "lose_on_hero_death", .doc = .{ .en = "1: any hero's death loses the battle (the exe); 0: only the whole party's", .ru = "1: смерть любого героя проигрывает бой (как exe); 0: только гибель всего отряда" } },
};

const weapon_kinds = [_]Word{
    .{ .name = "plain", .doc = .{ .en = "no code of its own", .ru = "без своего кода" } },
    .{ .name = "satellite", .doc = .{ .en = "any open tile of the field, 100 % (class 8)", .ru = "любая открытая клетка поля, 100 % (класс 8)" } },
    .{ .name = "time_bomb", .doc = .{ .en = "planted on a free neighbouring tile, explodes later (class 9)", .ru = "ставится рядом, взрывается позже (класс 9)" } },
    .{ .name = "decoy", .doc = .{ .en = "no skill; places a decoy on a free tile (class 18)", .ru = "без навыка; ставит приманку на свободную клетку (класс 18)" } },
    .{ .name = "napalm", .doc = .{ .en = "sets every hit tile on fire for 3 turns (class 16)", .ru = "поджигает все задетые клетки на 3 хода (класс 16)" } },
    .{ .name = "barrel", .doc = .{ .en = "barrel blast: no exp, sets off barrels (class 17)", .ru = "взрыв бочки: без опыта, взрывает бочки (класс 17)" } },
    .{ .name = "nitrogen", .doc = .{ .en = "puts out fire before the cold check (class 19)", .ru = "тушит огонь до проверки на холод (класс 19)" } },
    .{ .name = "energy", .doc = .{ .en = "stopped by resistance to energy (classes 6, 7)", .ru = "гасится сопротивлением энергии (классы 6, 7)" } },
    .{ .name = "sleep_ball", .doc = .{ .en = "the Stinger's ball: only sleep, no damage (class 1005)", .ru = "шар Жала: только сон, без урона (класс 1005)" } },
    .{ .name = "messiah_left", .doc = .{ .en = "Messiah's left arm: held by (10, 19) (class 1019)", .ru = "левая рука Мессии: держит (10, 19) (класс 1019)" } },
    .{ .name = "messiah_right", .doc = .{ .en = "Messiah's right arm: held by (10, 17) (class 1020)", .ru = "правая рука Мессии: держит (10, 17) (класс 1020)" } },
};

const keeps = [_]Word{
    .{ .name = "all", .doc = .{ .en = "plans with all its weapons", .ru = "планирует со всем оружием" } },
    .{ .name = "by_health", .doc = .{ .en = "the long weapon only below half health (Garcia)", .ru = "дальнее оружие только при здоровье меньше половины (Гарсия)" } },
    .{ .name = "first", .doc = .{ .en = "only the first weapon (Schizo)", .ru = "только первое оружие (Шизо)" } },
    .{ .name = "free_arms", .doc = .{ .en = "not an arm a box blocks (Messiah)", .ru = "не рука, закрытая ящиком (Мессия)" } },
};

const occupants = [_]Word{
    .{ .name = "generic", .doc = .{ .en = "the ordinary monster's worth: +5 damage, a monitor ×2, an ally −10×", .ru = "ценность обычного монстра: +5 к урону, монитор ×2, союзник −10×" } },
    .{ .name = "a", .doc = .{ .en = "\"scoring A\" (0x4dcb40)", .ru = "«оценка A» (0x4dcb40)" } },
    .{ .name = "no_lock", .doc = .{ .en = "scoring A without the AITargetLock ×100 (Cripple)", .ru = "оценка A без AITargetLock ×100 (Калека)" } },
    .{ .name = "avenge", .doc = .{ .en = "only its target (Grandma)", .ru = "только её цель (Бабушка)" } },
    .{ .name = "sleep_hunter", .doc = .{ .en = "sleeping heroes for melee, awake ones for the sleep shot", .ru = "спящие герои — для ближнего боя, бодрствующие — для усыпляющего выстрела" } },
    .{ .name = "heroes_only", .doc = .{ .en = "+10 a hero, −100 others", .ru = "+10 за героя, −100 за остальных" } },
    .{ .name = "foes", .doc = .{ .en = "damage × pct / 100, opponents only (Messiah)", .ru = "урон × pct / 100, только противники (Мессия)" } },
    .{ .name = "none", .doc = .{ .en = "0", .ru = "0" } },
};

const tiles = [_]Word{
    .{ .name = "occupants", .doc = .{ .en = "scores who stands on the hit tiles", .ru = "оценивает тех, кто стоит на клетках удара" } },
    .{ .name = "whole", .doc = .{ .en = "scores the hit tiles whole (Incubus)", .ru = "оценивает клетки удара целиком (Инкуб)" } },
};

const buttons = [_]Word{
    .{ .name = "inventory", .doc = .{ .en = "inventory", .ru = "инвентарь" } },
    .{ .name = "give", .doc = .{ .en = "give", .ru = "передать" } },
    .{ .name = "hand", .doc = .{ .en = "the item in hand", .ru = "предмет в руке" } },
    .{ .name = "short_list", .doc = .{ .en = "the quick list", .ru = "быстрый список" } },
    .{ .name = "push", .doc = .{ .en = "push", .ru = "толкнуть" } },
    .{ .name = "defend", .doc = .{ .en = "defend", .ru = "защита" } },
    .{ .name = "turn", .doc = .{ .en = "turn", .ru = "поворот" } },
    .{ .name = "end_turn", .doc = .{ .en = "end the turn", .ru = "конец хода" } },
    .{ .name = "skills", .doc = .{ .en = "the skills window", .ru = "окно навыков" } },
    .{ .name = "stats", .doc = .{ .en = "the stats window", .ru = "окно характеристик" } },
    .{ .name = "portrait0", .doc = .{ .en = "portrait slot k (portrait0, portrait1, …): the k-th hero in panel order", .ru = "слот портрета k (portrait0, portrait1, …): k-й герой в порядке панели" } },
};

const programs = [_]Word{
    .{ .name = "none", .doc = .{ .en = "no program: colour, alpha, blend only", .ru = "без программы: только цвет, прозрачность, смешивание" } },
    .{ .name = "dissolve", .doc = .{ .en = "pixels whose noise is below k drop out", .ru = "пиксели с шумом ниже k пропадают" } },
    .{ .name = "heat", .doc = .{ .en = "the texture ripples, k its phase", .ru = "текстура дрожит, k — фаза" } },
    .{ .name = "tint", .doc = .{ .en = "the texture greyed by k, so rgb colours it", .ru = "текстура обесцвечена на k, rgb её окрашивает" } },
};

const blends = [_]Word{
    .{ .name = "add", .doc = .{ .en = "additive", .ru = "сложение" } },
    .{ .name = "alpha", .doc = .{ .en = "alpha blending", .ru = "по прозрачности" } },
    .{ .name = "screen", .doc = .{ .en = "screen", .ru = "осветление (screen)" } },
};

// ---------------------------------------------------------------- shared fields

fn key(comptime name: []const u8, comptime what: Doc) Field {
    return .{ .name = name, .ref = .name_id, .doc = .{
        .en = what.en ++ " classic_id, or its class script as a string (OpenGorky: \"ft_wasp\", \"cw_laser\", \"ovitz\")",
        .ru = what.ru ++ ": classic_id или класс строкой (OpenGorky: \"ft_wasp\", \"cw_laser\", \"ovitz\")",
    } };
}

const fighter_key = key("fighter", .{ .en = "the fighter's", .ru = "боец" });
const weapon_key = key("weapon", .{ .en = "the weapon's", .ru = "оружие" });
const hero_key = key("hero", .{ .en = "the hero's", .ru = "герой" });

fn stage(comptime name: []const u8, comptime what: Doc) Field {
    return .{ .name = name, .ref = .name_id, .doc = .{
        .en = "the game weapon whose " ++ what.en ++ " it has: its classic_id or archetype (~w\"weapons::rocket_launcher\"); -1: none; 0: its own",
        .ru = "игровое оружие, чей " ++ what.ru ++ " берётся: его classic_id или архетип (~w\"weapons::rocket_launcher\"); -1: нет; 0: свой",
    } };
}

fn partsField(comptime name: []const u8, comptime what: Doc) Field {
    return .{ .name = name, .doc = what, .words = &parts };
}

fn file(comptime name: []const u8, comptime what: Doc) Field {
    return .{ .name = name, .doc = what };
}

// ---------------------------------------------------------------- calls

pub const all = [_]Call{
    .{ .name = "adjust", .doc = .{ .en = "A tuning value by name (a Setting row of rules\\adjust.ss), with the default when there is none: a number that follows it (adjust(\"name\", 25) + 5). Files written by older versions; the rules now hold plain numbers.", .ru = "Настройка по имени (строка Setting из rules\\adjust.ss), с умолчанием, если её нет: число, следующее за ней (adjust(\"name\", 25) + 5). Так писали файлы старых версий; теперь в правилах просто числа." }, .fields = &.{
        .{ .name = "name", .doc = .{ .en = "the setting's name", .ru = "имя настройки" } },
        .{ .name = "default", .doc = .{ .en = "the value when there is no such setting", .ru = "значение, если такой настройки нет" } },
    } },
    .{ .name = "Setting", .doc = .{ .en = "An engine tuning value: one row per name, typed int = n, float = x or rgba = list(r, g, b). A name without a row is the engine's built-in value.", .ru = "Настройка движка: одна строка на имя, с типом int = n, float = x или rgba = list(r, g, b). Имя без строки — встроенное значение движка." }, .fields = &.{
        .{ .name = "name", .doc = .{ .en = "the setting's name (Reference: Settings)", .ru = "имя настройки (Справка: Настройки)" } },
        .{ .name = "weapon", .ref = .name_id, .doc = .{ .en = "a weapon's own value (its block's flame = Flame(…)); none: the project's", .ru = "собственное значение оружия (из его блока: flame = Flame(…)); без него — общее проекта" } },
        .{ .name = "int", .doc = .{ .en = "an integer value", .ru = "целое значение" } },
        .{ .name = "float", .doc = .{ .en = "a fractional value", .ru = "дробное значение" } },
        .{ .name = "rgba", .doc = .{ .en = "a colour, list(r, g, b), each 0…255", .ru = "цвет, list(r, g, b), каждый 0…255" } },
    } },
    .{ .name = "MonsterAttack", .doc = .{ .en = "A monster's strike (0x4896b0, table 0x48d618) by fighter and weapon classic_id. A fighter with any row here uses this table, others the HeroAttack one.", .ru = "Удар монстра (0x4896b0, таблица 0x48d618) по classic_id бойца и оружия. Боец с любой строкой здесь бьёт по этой таблице, остальные — по HeroAttack." }, .fields = &.{
        fighter_key,
        .{ .name = "weapon", .ref = .name_id, .doc = .{ .en = "the weapon classic_id or class (0: any other weapon)", .ru = "classic_id или класс оружия (0: любое другое оружие)" } },
        .{ .name = "anim", .doc = .{ .en = "the logical animation of the strike", .ru = "логическая анимация удара" } },
        .{ .name = "hit_delay", .doc = .{ .en = "ticks until the hit", .ru = "тиков до попадания" } },
        .{ .name = "after_delay", .doc = .{ .en = "wait after the hit until the attack ends", .ru = "ожидание после попадания до конца атаки" } },
        .{ .name = "second_delay", .doc = .{ .en = "a second hit that many ticks later (0: none)", .ru = "второе попадание через столько тиков (0: нет)" } },
        .{ .name = "react_delay", .doc = .{ .en = "the target's reaction again, without damage, that many ticks later", .ru = "повторная реакция цели без урона через столько тиков" } },
        .{ .name = "flash_delay", .doc = .{ .en = "the flash or beam at that tick before the hit", .ru = "вспышка или луч на этом тике до попадания" } },
        .{ .name = "vanish_delay", .doc = .{ .en = "the Invisible fades out that many ticks after the hit", .ru = "Невидимка исчезает через столько тиков после попадания" } },
        .{ .name = "lift_delay", .doc = .{ .en = "the victim lifted on \"hand\" at that tick", .ru = "жертва поднята на «hand» на этом тике" } },
        .{ .name = "drop_delay", .doc = .{ .en = "the lifted victim dropped that many ticks after the hit", .ru = "поднятая жертва брошена через столько тиков после попадания" } },
        .{ .name = "strike", .ref = .name_id, .doc = .{ .en = "the fighter whose own effects the strike has (Medusa's beam, the Guard's lasers, Headnail's saws): its classic_id or archetype (~c\"characters::medusa\"); 0: its own", .ru = "боец, чьи собственные эффекты у удара (луч Медузы, лазеры Стража, пилы Гвоздеголового): его classic_id или архетип (~c\"characters::medusa\"); 0: свои" } },
        .{ .name = "gas", .doc = .{ .en = "the aimed tile and its 8 neighbours get gas (Schizo)", .ru = "клетка прицела и 8 соседних получают газ (Шизо)" } },
        .{ .name = "linked_anim", .doc = .{ .en = "its second linked actor plays this animation (Smoke Rider)", .ru = "второй связанный актёр играет эту анимацию (Курильщик)" } },
        .{ .name = "give", .doc = .{ .en = "OpenGorky: the fighter gets this weapon (a wp_ class) at battle entry: a new attack", .ru = "OpenGorky: боец получает это оружие (класс wp_) при входе в бой — новая атака" } },
        stage("effects_from", .{ .en = "effects (flash, projectile, hit, sound)", .ru = "набор эффектов (вспышка, снаряд, попадание, звук)" }),
        stage("flash_from", .{ .en = "flash", .ru = "вспышка" }),
        stage("launch_from", .{ .en = "projectile", .ru = "снаряд" }),
        stage("hit_from", .{ .en = "hit effects", .ru = "эффект попадания" }),
        .{ .name = "sound", .doc = .{ .en = "OpenGorky: the hit's sound", .ru = "OpenGorky: звук попадания" } },
        .{ .name = "attack_zone", .ref = .weapon_class, .doc = .{ .en = "OpenGorky: the weapon class (its name) whose reach and hit tiles it uses", .ru = "OpenGorky: класс оружия (его имя), чья дальность и клетки поражения берутся" } },
        .{ .name = "max_damage", .doc = .{ .en = "OpenGorky: the weapon's max_damage", .ru = "OpenGorky: max_damage оружия" } },
        .{ .name = "damage_kind", .doc = .{ .en = "OpenGorky: the weapon's damage type (none: the weapon's own)", .ru = "OpenGorky: тип урона оружия (none: свой у оружия)" }, .words = &damage_kinds },
        .{ .name = "recharge_turns", .doc = .{ .en = "OpenGorky: turns after a shot", .ru = "OpenGorky: ходов перезарядки после выстрела" } },
        .{ .name = "range", .doc = .{ .en = "OpenGorky: the AI strikes only within that many tiles", .ru = "OpenGorky: ИИ бьёт только в пределах стольких клеток" } },
    } },
    .{ .name = "HeroAttack", .doc = .{ .en = "A hero's strike (0x48bda2) by weapon classic_id; the exe ignores the weapon's useAnim. OpenGorky: a weapon class's fields override a row.", .ru = "Удар героя (0x48bda2) по classic_id оружия; useAnim оружия exe не смотрит. OpenGorky: поля класса оружия перекрывают строку." }, .fields = &.{
        .{ .name = "weapon", .ref = .name_id, .doc = .{ .en = "the weapon classic_id or class (0: every other weapon)", .ru = "classic_id или класс оружия (0: любое другое)" } },
        .{ .name = "hero", .ref = .name_id, .doc = .{ .en = "only this attacker (classic_id or class; 0: anyone)", .ru = "только этот атакующий (classic_id или класс; 0: любой)" } },
        .{ .name = "anim", .doc = .{ .en = "the animation of the strike", .ru = "анимация удара" } },
        .{ .name = "wait", .doc = .{ .en = "ticks until the hit", .ru = "тиков до попадания" } },
        .{ .name = "extra", .doc = .{ .en = "added to wait for the WdelayHero heroes only", .ru = "добавка к wait только для героев WdelayHero" } },
        .{ .name = "until_end", .doc = .{ .en = "the hit after the animation ends, then animation `then`", .ru = "попадание после конца анимации, затем анимация `then`" } },
        .{ .name = "then", .doc = .{ .en = "the animation after the hit (with until_end)", .ru = "анимация после попадания (с until_end)" } },
        .{ .name = "after", .doc = .{ .en = "wait after the hit (flashes)", .ru = "ожидание после попадания (вспышки)" } },
        .{ .name = "pre", .doc = .{ .en = "the beam's tick before the hit (ion rifle, blaster)", .ru = "тик луча до попадания (ионная винтовка, бластер)" } },
    } },
    .{ .name = "WdelayHero", .doc = .{ .en = "Heroes whose HeroAttack waits take `extra` (McFadden 24, Hutchens 29).", .ru = "Герои, у которых к ожиданию HeroAttack добавляется `extra` (Макфадден 24, Хатченс 29)." }, .fields = &.{hero_key} },
    .{ .name = "Resist", .doc = .{ .en = "Monster resistances (table 0x6d2070) by fighter classic_id. The table's order is the saves' (discovered bits).", .ru = "Сопротивления монстров (таблица 0x6d2070) по classic_id бойца. Порядок таблицы — порядок в сохранениях (открытые биты)." }, .fields = &.{
        fighter_key,
        .{ .name = "resist", .doc = .{ .en = "a list: resist = [fire, gas] (Resistance)", .ru = "список: resist = [fire, gas] (Resistance)" }, .words = &resists },
        .{ .name = "armor", .doc = .{ .en = "armour class: -1 light, -2 medium, -3 heavy (0: none)", .ru = "класс брони: -1 лёгкая, -2 средняя, -3 тяжёлая (0: нет)" } },
    } },
    .{ .name = "KillIcon", .doc = .{ .en = "Kill icons of the after-battle report (table 0x523f00) by fighter classic_id; a fighter missing here shows none.", .ru = "Значки убитых в отчёте после боя (таблица 0x523f00) по classic_id бойца; без строки значка нет." }, .fields = &.{
        fighter_key,
        .{ .name = "icon", .doc = .{ .en = "the icon's sprite name", .ru = "имя спрайта значка" } },
    } },
    .{ .name = "Glow", .doc = .{ .en = "An actor's glow (0x42a620, the Incubus's): a bitmap effect on its model's link points.", .ru = "Свечение актёра (0x42a620, у Инкуба): битмап-эффект на точках привязки его модели." }, .fields = &.{
        fighter_key,
        .{ .name = "effect", .doc = .{ .en = "the bitmap effect", .ru = "битмап-эффект" } },
        .{ .name = "links", .doc = .{ .en = "the model's link points, by spaces (\"t1 t2\")", .ru = "точки привязки модели через пробел (\"t1 t2\")" } },
        .{ .name = "size", .doc = .{ .en = "half-size, by the actor scale", .ru = "половина размера, с масштабом актёра" } },
        .{ .name = "rgb", .doc = .{ .en = "colour, 0–1 each", .ru = "цвет, каждая доля 0–1" } },
    } },
    .{ .name = "SkillIcon", .doc = .{ .en = "Weapon skills window rows (table 0x52a3a8) by weapon classic_id: a weapon without an icon here is not listed.", .ru = "Строки окна навыков (таблица 0x52a3a8) по classic_id оружия: оружие без значка здесь не показывается." }, .fields = &.{
        weapon_key,
        .{ .name = "icon", .doc = .{ .en = "the row's icon", .ru = "значок строки" } },
    } },
    .{ .name = "WeaponSound", .doc = .{ .en = "Weapon sounds at the hit by weapon classic_id (after FxAs, a weapon's effects_from).", .ru = "Звук оружия при попадании по classic_id оружия (после FxAs, effects_from оружия)." }, .fields = &.{
        weapon_key,
        .{ .name = "sound", .doc = .{ .en = "the sound (sound bank name)", .ru = "звук (имя в звуковом банке)" } },
    } },
    .{ .name = "FxAs", .doc = .{ .en = "Classic only: a weapon gets another game weapon's effects (flash, projectile, hit, sound); each stage alone too. In OpenGorky there is no such row: the weapon's own fields effects_from, flash_from, launch_from, hit_from (a weapon reference ~w\"weapons::x\" or classic_id), hit_sound; the converter moves the rows there.", .ru = "Только Classic: оружие получает эффекты другого игрового оружия (вспышка, снаряд, попадание, звук); можно и по отдельности. В OpenGorky такой строки нет: это поля самого оружия effects_from, flash_from, launch_from, hit_from (ссылка на оружие ~w\"weapons::x\" или classic_id), hit_sound; конвертер переносит строки туда." }, .fields = &.{
        weapon_key,
        .{ .name = "as", .ref = .name_id, .doc = .{ .en = "the game weapon classic_id whose effects it has", .ru = "classic_id игрового оружия, чьи эффекты берутся" } },
        stage("flash", .{ .en = "flash", .ru = "вспышка" }),
        stage("launch", .{ .en = "projectile", .ru = "снаряд" }),
        stage("hit", .{ .en = "hit effects", .ru = "эффект попадания" }),
        .{ .name = "sound", .doc = .{ .en = "the hit's sound (else WeaponSound)", .ru = "звук попадания (иначе WeaponSound)" } },
    } },
    .{ .name = "WeaponClass", .doc = .{ .en = "Weapon class (classType; factory 0x4b4c00) properties by name (a weapon: class = pistol); a class missing here has every property off.", .ru = "Свойства класса оружия (classType; фабрика 0x4b4c00) по имени (у оружия: class = pistol); у класса без строки все свойства выключены." }, .fields = &.{
        class_name,
        class_number,
        .{ .name = "rolls_to_hit", .doc = .{ .en = "firearms: rolls to hit", .ru = "огнестрел: бросок на попадание" } },
        .{ .name = "effect", .doc = .{ .en = "the state a hit applies", .ru = "состояние, которое накладывает попадание" }, .words = &effects },
        .{ .name = "effects", .doc = .{ .en = "OpenGorky: the states a hit applies, in order (effects = [sleep, burn]); over effect", .ru = "OpenGorky: состояния, которые накладывает попадание, по порядку (effects = [sleep, burn]); вместо effect" }, .words = &effects },
        .{ .name = "recharge", .doc = .{ .en = "turns after a shot", .ru = "ходов перезарядки после выстрела" } },
        .{ .name = "ignites_soaked", .doc = .{ .en = "sets a fuel-soaked target on fire", .ru = "поджигает облитую горючим цель" } },
        .{ .name = "kind", .doc = .{ .en = "the class's own battle code", .ru = "собственный боевой код класса" }, .words = &weapon_kinds },
    } },
    .{ .name = "WeaponFlags", .doc = .{ .en = "What the exe's battle code does by weapon classic_id (a weapon missing here: none of it).", .ru = "Что боевой код exe делает по classic_id оружия (оружие без строки: ничего)." }, .fields = &.{
        weapon_key,
        .{ .name = "no_counter", .doc = .{ .en = "in a hero's hand: no counter-attack roll", .ru = "в руке героя: без броска контратаки" } },
        .{ .name = "shock", .doc = .{ .en = "a hit puts \"current\" on the target", .ru = "попадание вешает на цель «current»" } },
        .{ .name = "sparks", .doc = .{ .en = "a hit gives the flare's sparks", .ru = "попадание даёт искры фальшфейера" } },
        .{ .name = "silent_frames", .doc = .{ .en = "a hero's strike mutes the animation's frame sounds", .ru = "удар героя глушит звуки кадров анимации" } },
    } },
    .{ .name = "Pattern", .doc = .{ .en = "Weapon class reach and hit tiles by the class's name (factory 0x4b4c00, pattern writer 0x4b6340).", .ru = "Дальность и клетки поражения класса оружия по имени класса (фабрика 0x4b4c00, 0x4b6340)." }, .fields = &.{
        class_name,
        class_number,
        .{ .name = "wide", .doc = .{ .en = "a two-tile-wide ray (2×2 fighters)", .ru = "луч шириной в две клетки (бойцы 2×2)" } },
        .{ .name = "rays", .doc = .{ .en = "\"dx,dy,kind,effect,pct …\" from the shooter; kind s: a ray start, c: continues it, x/y: a wide fighter's second tile; effect: the hit tile set; pct: damage percent", .ru = "\"dx,dy,kind,effect,pct …\" от стрелка; kind s — начало луча, c — продолжение, x/y — вторая клетка широкого бойца; effect — набор клеток поражения; pct — процент урона" } },
        .{ .name = "effects", .doc = .{ .en = "up to 4 hit tile sets \"dx,dy … | dx,dy …\" from the target tile", .ru = "до 4 наборов клеток поражения \"dx,dy … | dx,dy …\" от клетки цели" } },
    } },
    .{ .name = "Medicine", .doc = .{ .en = "Medicine effects (0x48ff50) by item classic_id; any other medicine heals.", .ru = "Действие лекарств (0x48ff50) по classic_id предмета; любое другое лекарство лечит." }, .fields = &.{
        .{ .name = "item", .ref = .name_id, .doc = .{ .en = "the item classic_id or class", .ru = "classic_id или класс предмета" } },
        .{ .name = "kind", .doc = .{ .en = "what it does", .ru = "что делает" }, .words = &medicine_kinds },
        .{ .name = "random", .ref = .name_id, .doc = .{ .en = "acts as one of these items, at random (item classic_ids)", .ru = "действует как один из этих предметов, случайно (classic_id предметов)" } },
    } },
    .{ .name = "HealBonus", .doc = .{ .en = "Character bonuses: a healer heals floor(hp × pct / 100) more (McFadden 15%). OpenGorky adds hit, damage, walk.", .ru = "Бонусы персонажа: лекарь лечит на floor(hp × pct / 100) больше (Макфадден 15%). OpenGorky добавляет hit, damage, walk." }, .fields = &.{
        key("healer", .{ .en = "the hero's", .ru = "герой" }),
        .{ .name = "pct", .doc = .{ .en = "percent more healing; not 0: \"special skill: healing +pct%\" in its stats", .ru = "процент к лечению; не 0 — «особый навык: лечение +pct%» в характеристиках" } },
        .{ .name = "hit", .doc = .{ .en = "OpenGorky: points added to its hit chance", .ru = "OpenGorky: очки к шансу попадания" } },
        .{ .name = "damage", .doc = .{ .en = "OpenGorky: percent more damage on its hits", .ru = "OpenGorky: процент к урону его попаданий" } },
        .{ .name = "walk", .doc = .{ .en = "OpenGorky: tiles more of its walk range in battle", .ru = "OpenGorky: на столько клеток дальше ходит в бою" } },
    } },
    .{ .name = "Action", .doc = .{ .en = "Item and area actions by name (0x4564b0): the menu row and what it does. A new name is a new row; objects name it in action (action1… an area's further rows).", .ru = "Действия предметов и зон по имени (0x4564b0): строка меню и что она делает. Новое имя — новая строка; объекты называют его в action (action1… — следующие строки меню зоны)." }, .fields = &.{
        .{ .name = "name", .doc = .{ .en = "the row's key, as objects name it (action = Take); the script function it calls on the object (with the hero's name); the row's text when string.tab has none", .ru = "ключ строки, так её называют объекты (action = Take); функция скрипта объекта, которую вызывает (с именем героя); текст строки, если в string.tab его нет" } },
        .{ .name = "classic_id", .doc = .{ .en = "the exe's number of the action (Classic objects name it so: funcID); only the built-in actions need it, a new one gets a free number", .ru = "номер действия у exe (так его называют объекты Classic: funcID); нужен только встроенным действиям, новое получает свободный номер" } },
        .{ .name = "text", .ref = .text, .doc = .{ .en = "the menu row's string.tab number (0: the built-in classic_id's own, a new action's name)", .ru = "номер текста строки меню в string.tab (0: свой у встроенного classic_id, у нового действия — имя)" } },
        .{ .name = "label", .doc = .{ .en = "OpenGorky: the menu row's text by interface key (\"open\", a UiText row's key)", .ru = "OpenGorky: текст строки меню по ключу текста интерфейса (\"open\", ключ строки UiText)" } },
        .{ .name = "kind", .doc = .{ .en = "what it does besides the call", .ru = "что делает помимо вызова" }, .words = &action_kinds },
        .{ .name = "auto_open", .doc = .{ .en = "on an object with items no examine menu: the box window opens after the action", .ru = "у объекта с предметами без меню осмотра: окно ящика открывается после действия" } },
        .{ .name = "on_exit", .doc = .{ .en = "on an exit the action runs instead of LevelSwitch", .ru = "на выходе действие выполняется вместо LevelSwitch" } },
        .{ .name = "walk_click", .doc = .{ .en = "a left click on an area only walks there", .ru = "левый щелчок по зоне только ведёт туда" } },
    } },
    .{ .name = "ExpLevel", .doc = .{ .en = "Exp thresholds (table 0x528c3c): the level grows while exp exceeds its level's.", .ru = "Пороги опыта (таблица 0x528c3c): уровень растёт, пока опыт больше порога уровня." }, .fields = &.{
        .{ .name = "level", .doc = .{ .en = "the hero level", .ru = "уровень героя" } },
        .{ .name = "exp", .doc = .{ .en = "the exp it takes", .ru = "нужный опыт" } },
    } },
    .{ .name = "IdleChatter", .doc = .{ .en = "Idle lines (0x451110): after idle_ticks without input the selected hero plays anim, then says dialog.", .ru = "Праздные реплики (0x451110): после idle_ticks без ввода выбранный герой играет anim и говорит dialog." }, .fields = &.{
        hero_key,
        .{ .name = "dialog", .doc = .{ .en = "the dialog it says", .ru = "диалог, который он говорит" } },
        .{ .name = "anim", .doc = .{ .en = "the animation before it", .ru = "анимация перед ним" } },
    } },
    .{ .name = "HiddenWeapons", .doc = .{ .en = "Weapons a fighter can't use or draw in hand (table 0x5270a0).", .ru = "Оружие, которое боец не может взять и показать в руке (таблица 0x5270a0)." }, .fields = &.{
        hero_key,
        .{ .name = "weapons", .ref = .name_id, .doc = .{ .en = "weapon classic_ids \"n n …\"", .ru = "classic_id оружия \"n n …\"" } },
    } },
    .{ .name = "Value", .doc = .{ .en = "Special IDs, limits and battle formula numbers the exe keeps in its code.", .ru = "Особые ID, пределы и числа формул боя, зашитые в код exe." }, .fields = &.{
        .{ .name = "name", .doc = .{ .en = "which value", .ru = "какое значение" }, .words = &consts },
        .{ .name = "value", .doc = .{ .en = "its value", .ru = "значение" } },
    } },
    .{ .name = "AiProfile", .doc = .{ .en = "Battle AI (0x498d30) by fighter classType (table 0x4bcbb0; class 0: every class not listed, an ordinary monster). A row by fighter (OpenGorky) writes its fields over its class's.", .ru = "ИИ в бою (0x498d30) по classType бойца (таблица 0x4bcbb0; class 0 — все не перечисленные, обычный монстр). Строка по бойцу (OpenGorky) пишет свои поля поверх строки класса." }, .fields = &.{
        .{ .name = "fighter", .ref = .name_id, .doc = .{ .en = "OpenGorky: one fighter (its archetype ~c\"characters::garcia\" or classic_id) over its class's row; an enemy's only, as the class's", .ru = "OpenGorky: один боец (его архетип ~c\"characters::garcia\" или classic_id) поверх строки класса; только враг, как и у строки класса" } },
        .{ .name = "class", .ref = .fighter_class, .doc = .{ .en = "the fighter classType (its scripts' classType; 0: every other class)", .ru = "classType бойца (classType в его скрипте; 0: все остальные)" } },
        .{ .name = "class_name", .doc = .{ .en = "OpenGorky: the class by name (a fighter's battle_class = stinger)", .ru = "OpenGorky: класс по имени (battle_class = stinger у бойца)" } },
        .{ .name = "generic_ai", .doc = .{ .en = "the generic fighter's ai (focused, sleep_hunter) that takes this row", .ru = "ai общего бойца (focused, sleep_hunter), который берёт эту строку" } },
        .{ .name = "profile", .doc = .{ .en = "OpenGorky: the ai_profile block the row is made of (ai::garcia); written by the loader", .ru = "OpenGorky: блок ai_profile, из которого сделана строка (ai::garcia); пишет загрузчик" } },
        .{ .name = "scoring", .doc = .{ .en = "the tile scoring (AiScoring)", .ru = "оценка клеток (AiScoring)" }, .words = &evals },
        .{ .name = "attack_weight", .doc = .{ .en = "over the fighter's ai_attack_weight", .ru = "вместо ai_attack_weight бойца" } },
        .{ .name = "threat_weight", .doc = .{ .en = "over the fighter's ai_threat_weight", .ru = "вместо ai_threat_weight бойца" } },
        .{ .name = "opponent_distance_weight", .doc = .{ .en = "over the fighter's ai_opponent_distance_weight", .ru = "вместо ai_opponent_distance_weight бойца" } },
        .{ .name = "guard_distance_weight", .doc = .{ .en = "over the fighter's ai_guard_distance_weight", .ru = "вместо ai_guard_distance_weight бойца" } },
        .{ .name = "mode", .doc = .{ .en = "over the fighter's ai_mode", .ru = "вместо ai_mode бойца" } },
        .{ .name = "damage_bonus", .doc = .{ .en = "added to max_damage (ordinary: 5)", .ru = "добавка к max_damage (обычный: 5)" } },
        .{ .name = "ally_penalty", .doc = .{ .en = "an ally on a hit tile scores −that/100 of it (10)", .ru = "союзник на клетке удара даёт −столько/100 (10)" } },
        .{ .name = "lock", .doc = .{ .en = "the AITargetLock target × that/100 (100)", .ru = "цель AITargetLock × столько/100 (100)" } },
        .{ .name = "monitor", .doc = .{ .en = "a monitor (classType 5) × that (ordinary: 2)", .ru = "монитор (classType 5) × столько (обычный: 2)" } },
        .{ .name = "decoy_pull", .doc = .{ .en = "a decoy's path weight (2000)", .ru = "вес пути к приманке (2000)" } },
        .{ .name = "decoys", .doc = .{ .en = "attracted by decoys", .ru = "идёт на приманки" } },
        .{ .name = "step_away", .doc = .{ .en = "steps away after a strike", .ru = "отходит после удара" } },
        .{ .name = "threat", .doc = .{ .en = "weighs the threat map (0x494f90)", .ru = "учитывает карту угроз (0x494f90)" } },
    } },
    .{ .name = "Campaign", .doc = .{ .en = "The campaign: what a new game starts with and the main menu's shell (one row; a file's row writes its fields over the built-in one).", .ru = "Кампания: с чего начинается новая игра и оболочка главного меню (одна строка; строка файла пишет поля поверх встроенной)." }, .fields = &.{
        file("level", .{ .en = "the location a new game opens", .ru = "локация, с которой начинается игра" }),
        file("leader", .{ .en = "the hero selected at the start", .ru = "герой, выбранный в начале" }),
        file("party", .{ .en = "hero scripts from the start, \"a.hro b.hro\" (\"\": every gamestart\\*.hro, as the exe)", .ru = "скрипты героев с начала, \"a.hro b.hro\" (\"\": все gamestart\\*.hro, как в exe)" }),
        file("panel_first", .{ .en = "heroes (object names) the party panel shows first, \"Sullivan Ovitz Trantigne\"; then those who joined", .ru = "герои (имена объектов), которых панель отряда показывает первыми, \"Sullivan Ovitz Trantigne\"; затем присоединившиеся" }),
        file("area", .{ .en = "the party put at this area's points on arrival (\"\": the location's own init)", .ru = "отряд ставится в точки этой зоны при входе (\"\": как в init локации)" }),
        file("point", .{ .en = "the first point of `area`", .ru = "первая точка `area`" }),
        file("scene", .{ .en = "a scriptlet started then", .ru = "сценка, запускаемая тогда же" }),
        file("intro", .{ .en = "videos before a new game (\"a.avi b.mp4\")", .ru = "видео перед новой игрой (\"a.avi b.mp4\")" }),
        file("startup", .{ .en = "videos before the main menu", .ru = "видео перед главным меню" }),
        file("menu_logo", .{ .en = "the menu logo texture (gfx_3d\\textures)", .ru = "текстура логотипа меню (gfx_3d\\textures)" }),
        file("menu_music", .{ .en = "the main menu's music track", .ru = "музыка главного меню" }),
        file("credits_music", .{ .en = "the credits' music track", .ru = "музыка титров" }),
        file("credits", .{ .en = "the credits text (common/lang.dat)", .ru = "текст титров (common/lang.dat)" }),
        file("credits_video", .{ .en = "a video before the credits (\"\": none)", .ru = "видео перед титрами (\"\": нет)" }),
    } },
    .{ .name = "WeaponFx", .doc = .{ .en = "What a strike shows, by the game weapon classic_id a stage names (FxAs, MonsterAttack effects_from/flash_from/launch_from/hit_from): lists of parts per stage.", .ru = "Что показывает удар, по classic_id игрового оружия, на которое ссылается стадия (FxAs, MonsterAttack fx/flash/launch/hit): списки частей по стадиям." }, .fields = &.{
        .{ .name = "id", .ref = .name_id, .doc = .{ .en = "the game weapon classic_id", .ru = "classic_id игрового оружия" } },
        .{ .name = "who", .ref = .name_id, .doc = .{ .en = "only for this attacker classic_id (0: any; the first matching record wins)", .ru = "только для этого classic_id атакующего (0: любой; побеждает первая подходящая)" } },
        partsField("pre", .{ .en = "parts before the hit", .ru = "части до попадания" }),
        partsField("shot", .{ .en = "parts at the hit, before the fighter's own: the monster's shot flash", .ru = "части при попадании до своих бойца: вспышка выстрела монстра" }),
        partsField("flash", .{ .en = "parts at the hit, after them: the hero's muzzle flash", .ru = "части при попадании после них: вспышка дула героя" }),
        partsField("hit", .{ .en = "the hit's own parts (after the sound)", .ru = "части самого попадания (после звука)" }),
        .{ .name = "launch", .doc = .{ .en = "the projectile: Launch(pr = Projectile(…), set = …)", .ru = "снаряд: Launch(pr = Projectile(…), set = …)" } },
    } },
    .{ .name = "FighterFx", .doc = .{ .en = "A fighter's own effects (MonsterAttack special) with a weapon classic_id (0: any).", .ru = "Собственные эффекты бойца (MonsterAttack special) с classic_id оружия (0: любое)." }, .fields = &.{
        .{ .name = "fighter", .ref = .name_id, .doc = .{ .en = "the fighter classic_id (MonsterAttack special)", .ru = "classic_id бойца (MonsterAttack special)" } },
        .{ .name = "weapon", .ref = .name_id, .doc = .{ .en = "the weapon classic_id (0: any)", .ru = "classic_id оружия (0: любое)" } },
        partsField("pre", .{ .en = "parts instead of the weapon's pre", .ru = "части вместо pre оружия" }),
        partsField("hit", .{ .en = "parts at the hit", .ru = "части при попадании" }),
        partsField("second", .{ .en = "the second hit of a series (empty: hit)", .ru = "второе попадание серии (пусто: hit)" }),
    } },
    .{ .name = "Character", .doc = .{ .en = "A character's roles (OpenGorky) by its class script: enemy, hero or both (one class, rules by class shared). Without a row: its files' roles.", .ru = "Роли персонажа (OpenGorky) по его скрипту класса: враг, герой или оба (один класс, правила по классу общие). Без строки — роли по его файлам." }, .fields = &.{
        .{ .name = "fighter", .ref = .name_id, .doc = .{ .en = "the character's class script (\"ft_wasp\") or classic_id", .ru = "скрипт класса персонажа (\"ft_wasp\") или classic_id" } },
        .{ .name = "as_hero", .doc = .{ .en = "may be a hero (a .hro includes its class)", .ru = "может быть героем (.hro включает его класс)" } },
        .{ .name = "as_enemy", .doc = .{ .en = "may be an enemy (a battle's .ftr includes its class)", .ru = "может быть врагом (.ftr боя включает его класс)" } },
    } },
    .{ .name = "Abilities", .doc = .{ .en = "A fighter's extra abilities in battle, hero or enemy alike: the ordinary fighter plus the parts set (the original's: the exe's code by classType, factory 0x4bc6c0, and by classic_id or object name). A row by fighter is that fighter's whole own, over its classType's.", .ru = "Доп. способности бойца в бою, героя и врага одинаково: обычный боец плюс заданные части (у оригинала — код exe по classType, фабрика 0x4bc6c0, и по classic_id или имени объекта). Строка по бойцу — вся его собственная, поверх строки его classType." }, .fields = &.{
        .{ .name = "fighter", .ref = .name_id, .doc = .{ .en = "one fighter's own row: classic_id, class (\"ft_wasp\") or a placed object's name; 0: by classType", .ru = "своя строка одного бойца: classic_id, класс (\"ft_wasp\") или имя объекта на уровне; 0: по classType" } },
        .{ .name = "class", .ref = .fighter_class, .doc = .{ .en = "the fighter classType", .ru = "classType бойца" } },
        .{ .name = "class_name", .doc = .{ .en = "OpenGorky: the class by name (a fighter's battle_class = puppet)", .ru = "OpenGorky: класс по имени (battle_class = puppet у бойца)" } },
        .{ .name = "double_turn", .doc = .{ .en = "acts twice per turn (Incubus, Cripple); a hero the player leads: two strikes", .ru = "действует дважды за ход (Инкуб, Калека); герой игрока: два удара" } },
        .{ .name = "first_in_mode", .doc = .{ .en = "acts first on a level of this levelMode (Grandma: 2; 0: list order)", .ru = "ходит первым на уровне с этим levelMode (Бабушка: 2; 0: по списку)" } },
        .{ .name = "immobile", .doc = .{ .en = "never walks (nailed down)", .ru = "никогда не ходит (прибит к месту)" } },
        .{ .name = "stand", .doc = .{ .en = "the angle it stands at (radians; left out: faces the nearest opponent)", .ru = "угол, под которым стоит (радианы; не задан — к ближайшему противнику)" } },
        .{ .name = "stand_after_move", .doc = .{ .en = "stands at that angle after its own move too", .ru = "встаёт под этим углом и после своего хода" } },
        .{ .name = "guard", .doc = .{ .en = "Guard(div, min, cone): damage /div, at least min, from the front cone (Puppet)", .ru = "Guard(div, min, cone): урон /div, не меньше min, спереди в конусе (Кукла)" } },
        .{ .name = "open_from", .doc = .{ .en = "struck only from this tile list(right, ahead) of its own (by its stand angle, else its facing), else a miss (Messiah: list(0, 1))", .ru = "уязвим только с этой своей клетки list(вправо, вперёд) (по углу stand, иначе по взгляду), иначе промах (Мессия: list(0, 1))" } },
        .{ .name = "dodge", .doc = .{ .en = "the dodge animation before a shot from elsewhere", .ru = "анимация уклонения от выстрела с другой клетки" } },
        .{ .name = "arms", .doc = .{ .en = "Arms(left, right, blocked): arm tiles list(right, ahead) of its own a box blocks, the animation when both are", .ru = "Arms(left, right, blocked): свои клетки рук list(вправо, вперёд), закрываемые ящиком, и анимация, если закрыты обе" } },
        .{ .name = "monitor", .doc = .{ .en = "a monitor: a hit only deals damage (no side bonus, reaction, blood)", .ru = "монитор: попадание только наносит урон (без бонуса сбоку, реакции, крови)" } },
        .{ .name = "kill_credit", .doc = .{ .en = "its kill counts: exp bonus and the report line", .ru = "его убийство засчитывается: бонус опыта и строка отчёта" } },
        .{ .name = "pairs", .doc = .{ .en = "weapon classic_id pairs it strikes with by its counter (Schizo)", .ru = "пары classic_id оружия по его счётчику (Шизо)" } },
        .{ .name = "double_strike", .doc = .{ .en = "strikes twice into one tile", .ru = "бьёт дважды в одну клетку" } },
        .{ .name = "heals", .doc = .{ .en = "heals the fighter of this object name by the damage it deals (the Judge's child)", .ru = "лечит бойца с этим именем объекта на нанесённый урон (ребёнок Судьи)" } },
        .{ .name = "avenger", .doc = .{ .en = "its death makes its killer the target of the fighter of this object name (Grandma)", .ru = "его смерть делает убийцу целью бойца с этим именем объекта (Бабушка)" } },
        .{ .name = "invisible", .doc = .{ .en = "starts the battle unseen, never highlighted (the Invisible)", .ru = "начинает бой невидимым, не подсвечивается (Невидимка)" } },
        .{ .name = "leaves", .doc = .{ .en = "leaves the battle after each enemy round, not a death (04mf_invisible1)", .ru = "уходит из боя после каждого раунда врагов, это не смерть (04mf_invisible1)" } },
        .{ .name = "no_push", .doc = .{ .en = "pushes nothing (Medusa)", .ru = "не толкает (Медуза)" } },
        .{ .name = "no_hands", .doc = .{ .en = "gives and takes no items, no fist when unarmed (Medusa)", .ru = "не даёт и не берёт предметы, без оружия нет кулака (Медуза)" } },
        .{ .name = "battle_only", .doc = .{ .en = "never picked outside a battle (Medusa)", .ru = "вне боя не выбирается (Медуза)" } },
        .{ .name = "scripts", .doc = .{ .en = "OpenGorky: scripted abilities, list(Name(param = value, …), …) — the project's OGS components `for fighter` (rules\\abilities.ss), attached for each battle in this order; params by name, the rest at their defaults (a fighter param: an object name)", .ru = "OpenGorky: скриптовые способности, list(Имя(параметр = значение, …), …) — компоненты OGS проекта `for fighter` (rules\\abilities.ss), подключаются в каждом бою в этом порядке; параметры по имени, остальные — по умолчанию (параметр-боец — имя объекта)" } },
    } },
    .{ .name = "FighterStrike", .doc = .{ .en = "A fighter's own strike (MonsterAttack special) in its own code: saws spun on its model's link points (Headnail).", .ru = "Собственный удар бойца (MonsterAttack special) в его коде: пилы, вращаемые на точках связи модели (Гвоздеголовый)." }, .fields = &.{
        .{ .name = "special", .ref = .name_id, .doc = .{ .en = "the fighter: its archetype (~c\"characters::headnail\") or classic_id (MonsterAttack special)", .ru = "боец: его архетип (~c\"characters::headnail\") или classic_id (MonsterAttack special)" } },
        .{ .name = "spins", .doc = .{ .en = "list(Spin(link = \"point\", at = tick, anim = \"obrot\"), …): the link's mesh plays `anim` at a strike tick (saws)", .ru = "list(Spin(link = \"точка\", at = тик, anim = \"obrot\"), …): меш точки играет `anim` на тике удара (пилы)" } },
    } },
    .{ .name = "AiScoring", .doc = .{ .en = "The AI's tile scoring by AiProfile eval (method +0xe0 by classType): the pieces combat/ai.zig runs.", .ru = "Оценка клеток ИИ по eval из AiProfile (метод +0xe0 по classType): части, которые выполняет combat/ai.zig." }, .fields = &.{
        .{ .name = "eval", .doc = .{ .en = "the scoring this row is", .ru = "какая это оценка" }, .words = &evals },
        .{ .name = "keep", .doc = .{ .en = "the weapons it plans with", .ru = "с каким оружием планирует" }, .words = &keeps },
        .{ .name = "occupant", .doc = .{ .en = "a fighter's worth on a hit tile", .ru = "ценность бойца на клетке удара" }, .words = &occupants },
        .{ .name = "tile", .doc = .{ .en = "what of a hit tile it scores", .ru = "что оценивает на клетке удара" }, .words = &tiles },
        .{ .name = "script", .doc = .{ .en = "a component of the project's code (for Enemy) attached to a fighter of this scoring in battle: its ScoreTile scores the hit tiles (the converter's: ai_scoring::Avenge, SleepHunter, HeroesOnly, WholeTile)", .ru = "компонент кода проекта (for Enemy), который подключается в бою бойцу с этой оценкой: его ScoreTile оценивает клетки удара (у конвертера: ai_scoring::Avenge, SleepHunter, HeroesOnly, WholeTile)" } },
        .{ .name = "wakeful", .doc = .{ .en = "plans asleep too, in a ±π/4 cone (Smoke Rider)", .ru = "планирует и во сне, в конусе ±π/4 (Курильщик)" } },
        .{ .name = "near", .doc = .{ .en = "stays within 3 tiles of the fighter of this object name", .ru = "держится в 3 клетках от бойца с этим именем объекта" } },
    } },
    .{ .name = "PanelPlace", .doc = .{ .en = "The party panel's places in the exe's order (table 0x52b388: hit test and drawing go in it).", .ru = "Места панели отряда в порядке exe (таблица 0x52b388: в нём проверка нажатий и рисование)." }, .fields = &.{
        .{ .name = "button", .doc = .{ .en = "a control or portrait slot \"portrait0\"…", .ru = "кнопка или слот портрета \"portrait0\"…" }, .words = &buttons },
        .{ .name = "rect", .doc = .{ .en = "its rectangle list(x0, y0, x1, y1) from the panel's top", .ru = "прямоугольник list(x0, y0, x1, y1) от верха панели" } },
        .{ .name = "hint", .doc = .{ .en = "its hint: an interface text key (\"hint_inventory\", a UiText row's key; \"\": none; a portrait shows the hero's name)", .ru = "подсказка: ключ текста интерфейса (\"hint_inventory\", ключ строки UiText; \"\": нет; портрет показывает имя героя)" } },
        .{ .name = "pressed", .doc = .{ .en = "Pressed(frame, dx): the frame drawn pressed and its x offset", .ru = "Pressed(frame, dx): кадр нажатой кнопки и его сдвиг по x" } },
        .{ .name = "shutter", .doc = .{ .en = "the shutter frames list(min, max) over it while inactive", .ru = "кадры шторки list(min, max) поверх неактивной" } },
    } },
    .{ .name = "Windows", .doc = .{ .en = "The sliding windows: skills and stats (where opened, slid from, their size), their places in the inventory and with level-up points.", .ru = "Выезжающие окна: навыки и характеристики (где открыты, откуда выезжают, размер), их места в инвентаре и при очках уровня." }, .fields = &.{
        .{ .name = "skills", .doc = .{ .en = "the weapon skills window: Window(at, from, size)", .ru = "окно навыков: Window(at, from, size)" } },
        .{ .name = "skills_inventory", .doc = .{ .en = "the skills window's place in the inventory", .ru = "место окна навыков в инвентаре" } },
        .{ .name = "stats", .doc = .{ .en = "the hero stats window: Window(at, from, size)", .ru = "окно характеристик: Window(at, from, size)" } },
        .{ .name = "stats_inventory", .doc = .{ .en = "the stats window's place in the inventory", .ru = "место окна характеристик в инвентаре" } },
        .{ .name = "level_up", .doc = .{ .en = "the stats window's place with level-up points", .ru = "место окна характеристик при очках уровня" } },
    } },
    .{ .name = "MainMenu", .doc = .{ .en = "The main menu's scene (0x4134e0): its model and animation, textures (gfx_3d\\textures), fonts and the item spacing.", .ru = "Сцена главного меню (0x4134e0): модель и анимация, текстуры (gfx_3d\\textures), шрифты и шаг пунктов." }, .fields = &.{
        file("model", .{ .en = "the model (gfx_3d\\<model>.msh)", .ru = "модель (gfx_3d\\<model>.msh)" }),
        file("anim", .{ .en = "the model's animation", .ru = "анимация модели" }),
        file("light", .{ .en = "the flashlight texture", .ru = "текстура фонаря" }),
        file("circle", .{ .en = "the light circle texture", .ru = "текстура светового круга" }),
        file("flare", .{ .en = "the flare texture", .ru = "текстура блика" }),
        file("lens", .{ .en = "the lens texture", .ru = "текстура линзы" }),
        file("lens2", .{ .en = "the second lens texture", .ru = "текстура второй линзы" }),
        file("arrow", .{ .en = "the arrow texture", .ru = "текстура стрелки" }),
        file("cursor", .{ .en = "the cursor texture", .ru = "текстура курсора" }),
        file("font", .{ .en = "the items' font (<font>_<n> by the language's letters)", .ru = "шрифт пунктов (<font>_<n> по буквам языка)" }),
        file("glow", .{ .en = "the selected item's glow font", .ru = "шрифт свечения выбранного пункта" }),
        file("start_y", .{ .en = "the first item's y: Adj(name = a setting's name, d = default)", .ru = "y первого пункта: Adj(name = имя настройки, d = умолчание)" }),
        file("h_space", .{ .en = "the item spacing: Adj(name, d)", .ru = "шаг пунктов: Adj(name, d)" }),
    } },
    .{ .name = "ExeVideo", .doc = .{ .en = "Where the exe shows a video of its own (0x413386, 0x40fd06): screen place, doubled.", .ru = "Где exe показывает своё видео (0x413386, 0x40fd06): место на экране, удвоение." }, .fields = &.{
        file("name", .{ .en = "the video file", .ru = "файл видео" }),
        file("x", .{ .en = "its x on the screen", .ru = "x на экране" }),
        file("y", .{ .en = "its y on the screen", .ru = "y на экране" }),
        file("double", .{ .en = "drawn at double size", .ru = "рисуется вдвое больше" }),
        file("caption", .{ .en = "the caption over it (intro.spr frame 0)", .ru = "подпись поверх (intro.spr, кадр 0)" }),
    } },
    .{ .name = "ExeMusic", .doc = .{ .en = "Music the exe names in its code.", .ru = "Музыка, которую exe называет в коде." }, .fields = &.{
        file("level_up", .{ .en = "the level-up points window's music", .ru = "музыка окна очков уровня" }),
        file("battle_enter", .{ .en = "entering a battle from a location (the saw transition)", .ru = "вход в бой из локации (переход «пила»)" }),
        file("victory", .{ .en = "the jingle of a battle won", .ru = "джингл выигранного боя" }),
        file("game_over", .{ .en = "the jingle of a battle lost and of the game-over screen", .ru = "джингл проигранного боя и экрана конца игры" }),
        file("statistics", .{ .en = "the after-battle report's music", .ru = "музыка отчёта после боя" }),
        file("battle", .{ .en = "a battle's music without its own or a district's: one drawn, \"a b\" (rand() % count)", .ru = "музыка боя без своей и без районной: одна по жребию, \"a b\" (rand() % число)" }),
        file("boss", .{ .en = "the battle music of a boss level (bossmonsterLevel)", .ru = "музыка боя на уровне с боссом (bossmonsterLevel)" }),
        file("enemy_suffix", .{ .en = "the drawn battle music's enemy turn track: its name and this (\"\": none)", .ru = "дорожка хода врага у музыки боя по жребию: её имя и это (\"\": нет)" }),
    } },
    .{ .name = "Canvas", .doc = .{ .en = "The interface's canvas: the logical frame (at least 640×480) the world and the interface are drawn in, scaled to the window. The exe's art keeps its pixels: the interface's 640×480 box (the panel at its bottom) stands at the canvas's bottom centre; the world fills the canvas.", .ru = "Холст интерфейса: логический кадр (не меньше 640×480), в котором рисуются мир и интерфейс, масштабируется под окно. Графика exe сохраняет свои пиксели: прямоугольник интерфейса 640×480 (панель внизу него) стоит по центру у нижнего края холста; мир заполняет весь холст." }, .fields = &.{
        file("width", .{ .en = "its width in logical pixels (640 the exe's)", .ru = "ширина в логических пикселях (640 — как в exe)" }),
        file("height", .{ .en = "its height (480 the exe's)", .ru = "высота (480 — как в exe)" }),
    } },
    .{ .name = "DistrictMusic", .doc = .{ .en = "A district's shared music (0x41f9b0): a level without its own whose name contains the prefix plays the track; the first row that fits.", .ru = "Общая музыка района (0x41f9b0): уровень без своей музыки, в имени которого есть префикс, играет дорожку; первая подходящая строка." }, .fields = &.{
        file("prefix", .{ .en = "part of the levels' names (\"01_port_\")", .ru = "часть имени уровней (\"01_port_\")" }),
        file("level", .{ .en = "OpenGorky: one level by name, not a prefix (a level's own music = \"…\")", .ru = "OpenGorky: один уровень по имени, не префикс (поле уровня music = \"…\")" }),
        file("track", .{ .en = "the music they play", .ru = "музыка, которую они играют" }),
    } },
    .{ .name = "UiSounds", .doc = .{ .en = "Sounds the exe names in its code, by what plays them (one row; a file's row writes its fields over the built-in one).", .ru = "Звуки, которые exe называет в коде, по тому, что их играет (одна строка; строка файла пишет поля поверх встроенной)." }, .fields = &.{
        file("select_hero", .{ .en = "a hero selected", .ru = "выбран герой" }),
        file("give", .{ .en = "an item given or worn", .ru = "предмет отдан или надет" }),
        file("item_choose", .{ .en = "an item picked up in the inventory", .ru = "предмет взят в инвентаре" }),
        file("item_put", .{ .en = "an item put down in the inventory", .ru = "предмет положен в инвентаре" }),
        file("item_select", .{ .en = "an item selected (give, box)", .ru = "предмет выбран (передача, ящик)" }),
        file("weapons_tab", .{ .en = "the inventory's weapons tab", .ru = "вкладка оружия в инвентаре" }),
        file("items_tab", .{ .en = "the inventory's items tab", .ru = "вкладка предметов в инвентаре" }),
        file("keys_tab", .{ .en = "the inventory's keys tab", .ru = "вкладка ключей в инвентаре" }),
        file("explosion", .{ .en = "an explosion: a barrel, a bomb, a scene's rocket", .ru = "взрыв: бочка, бомба, ракета сцены" }),
        file("no_ammo", .{ .en = "a strike without ammo", .ru = "удар без патронов" }),
        file("set_points", .{ .en = "a stat point set", .ru = "очко характеристики вложено" }),
        file("take_items", .{ .en = "a box emptied", .ru = "ящик опустошён" }),
        file("safe_key", .{ .en = "a safe's key pressed", .ru = "нажата клавиша сейфа" }),
        file("heal", .{ .en = "a man healed (sex 0)", .ru = "лечение мужчины (sex 0)" }),
        file("menu_slide_in", .{ .en = "a battle window slides in", .ru = "окно боя выезжает" }),
        file("menu_slide_out", .{ .en = "a battle window slides out", .ru = "окно боя уезжает" }),
        file("push_barrel", .{ .en = "pushing an explosive obstacle", .ru = "толкание взрывоопасного препятствия" }),
        file("push_box", .{ .en = "pushing any other obstacle", .ru = "толкание другого препятствия" }),
        file("click", .{ .en = "a menu item clicked", .ru = "щелчок по пункту меню" }),
        file("keyboard", .{ .en = "typing a save's name", .ru = "ввод имени сохранения" }),
        file("menu_open", .{ .en = "the game menu opens", .ru = "открывается меню игры" }),
        file("key_accept", .{ .en = "a save slot accepted", .ru = "слот сохранения принят" }),
        file("miss", .{ .en = "a miss: one of these at random, by spaces", .ru = "промах: один из них наугад, через пробел" }),
        file("walk_ok", .{ .en = "a walk click the hero can go to", .ru = "щелчок туда, куда герой может пройти" }),
        file("walk_bad", .{ .en = "a walk click the hero cannot go to", .ru = "щелчок туда, куда герой пройти не может" }),
        file("inventory_open", .{ .en = "the inventory opens", .ru = "инвентарь открывается" }),
        file("inventory_close", .{ .en = "the inventory closes", .ru = "инвентарь закрывается" }),
        file("blood", .{ .en = "blood spilt: one of these at random, by spaces", .ru = "брызги крови: один из них наугад, через пробел" }),
        file("silence", .{ .en = "an animation's sound cue that plays nothing (a placeholder)", .ru = "звуковая метка анимации, которая ничего не играет (заглушка)" }),
    } },
    .{ .name = "UiEffects", .doc = .{ .en = "Effects the exe draws by name in its code (one row).", .ru = "Эффекты, которые exe рисует по имени в коде (одна строка)." }, .fields = &.{
        file("morph_sparks", .{ .en = "a morph's sparks (the effect)", .ru = "искры превращения (эффект)" }),
        file("morph_sparks_size", .{ .en = "their half size, by the actor scale", .ru = "их половина размера, с масштабом актёра" }),
        file("morph_sparks_rgb", .{ .en = "their colour, 0–1 each", .ru = "их цвет, каждая доля 0–1" }),
        file("effect_mesh", .{ .en = "the mesh an effect frame is drawn on (a rocket's body, its exhaust)", .ru = "меш, на котором рисуется кадр эффекта (корпус ракеты, выхлоп)" }),
        file("explosion", .{ .en = "an explosion's bitmap effect", .ru = "битмап-эффект взрыва" }),
        file("select_marker", .{ .en = "texture: the selected hero's sparks in battle", .ru = "текстура: искры под выбранным героем в бою" }),
        file("facing_arrow", .{ .en = "texture: the facing arrows beside the hero", .ru = "текстура: стрелки поворота вокруг героя" }),
        file("click_marker", .{ .en = "texture: the click marker, the speaker's", .ru = "текстура: метка щелчка, говорящего" }),
        file("area_marker", .{ .en = "texture: an active area's arrows", .ru = "текстура: стрелки активной области" }),
        file("shock", .{ .en = "texture: a shocked fighter's current", .ru = "текстура: разряд на оглушённом бойце" }),
        file("grid", .{ .en = "texture: the battle grid", .ru = "текстура: сетка боя" }),
    } },
    .{ .name = "UiAssets", .doc = .{ .en = "The interface's sprites and fonts the exe loads by name (one row; sprites: asset paths).", .ru = "Спрайты и шрифты интерфейса, которые exe грузит по имени (одна строка; спрайты: пути ассетов)." }, .fields = &.{
        file("panel", .{ .en = "the party panel", .ru = "панель отряда" }),
        file("cursor", .{ .en = "the mouse cursor", .ru = "курсор мыши" }),
        file("fighter_info", .{ .en = "the fighter info box", .ru = "окно сведений о бойце" }),
        file("border", .{ .en = "the selected hero's frame", .ru = "рамка выбранного героя" }),
        file("spinner", .{ .en = "the loading saw", .ru = "пила загрузки" }),
        file("atlas", .{ .en = "the glyph atlas of the bitmap fonts", .ru = "атлас символов растровых шрифтов" }),
        file("skills", .{ .en = "the weapon skills window", .ru = "окно навыков оружия" }),
        file("intro", .{ .en = "the video caption", .ru = "подпись видео" }),
        file("hero_stats", .{ .en = "the hero stats window", .ru = "окно характеристик героя" }),
        file("dialog_box", .{ .en = "the dialog box", .ru = "окно диалога" }),
        file("report", .{ .en = "the battle report", .ru = "отчёт о бое" }),
        file("item_list", .{ .en = "the item list (a box's, a short list)", .ru = "список предметов (ящика, быстрый)" }),
        file("scrollbar", .{ .en = "the scroll bar", .ru = "полоса прокрутки" }),
        file("inventory", .{ .en = "the inventory", .ru = "инвентарь" }),
        file("give_man", .{ .en = "the give window's figure", .ru = "фигура в окне передачи" }),
        file("examine", .{ .en = "the examine window", .ru = "окно осмотра" }),
        file("examine_box", .{ .en = "the examine text box", .ru = "поле текста осмотра" }),
        file("safe", .{ .en = "the safe's keypad", .ru = "кодовый замок сейфа" }),
        file("save", .{ .en = "the save slot's frame", .ru = "рамка слота сохранения" }),
        file("credits", .{ .en = "the credits background", .ru = "фон титров" }),
        file("hp_font", .{ .en = "font: health digits (fonts/<name>.fnt)", .ru = "шрифт: цифры здоровья (fonts/<имя>.fnt)" }),
        file("safe_font", .{ .en = "font: the safe's", .ru = "шрифт: сейфа" }),
        file("msg_font", .{ .en = "font set: 3D messages (<name>_1 and the language's letters)", .ru = "набор шрифтов: 3D-сообщения (<имя>_1 и буквы языка)" }),
        file("credits_font", .{ .en = "font set: the credits", .ru = "набор шрифтов: титры" }),
        file("dialog_font", .{ .en = "font set: the dialog's", .ru = "набор шрифтов: диалог" }),
        file("small_font", .{ .en = "font set: the small interface text", .ru = "набор шрифтов: мелкий текст интерфейса" }),
        file("system_font", .{ .en = "font set: the system text", .ru = "набор шрифтов: системный текст" }),
    } },
    .{ .name = "ExeAnims", .doc = .{ .en = "Animations the exe plays by name (one row).", .ru = "Анимации, которые exe играет по имени (одна строка)." }, .fields = &.{
        file("fight_look", .{ .en = "a hero selected in battle looks around; the party stops (STOP_HEROES)", .ru = "выбранный в бою герой оглядывается; отряд останавливается (STOP_HEROES)" }),
        file("fight_look_two_handed", .{ .en = "the same with a two-handed weapon in hand", .ru = "то же с двуручным оружием в руке" }),
        file("hide_back", .{ .en = "a two-handed weapon put on the back, taken back (played backwards)", .ru = "двуручное оружие убирают за спину и достают (наоборот)" }),
    } },
    .{ .name = "HoldPoints", .doc = .{ .en = "The model's hold points (.msh hold modes) the exe puts a weapon on (one row).", .ru = "Точки хвата модели (режимы хвата .msh), куда exe вешает оружие (одна строка)." }, .fields = &.{
        file("one_hand", .{ .en = "a one-handed weapon in hand", .ru = "одноручное оружие в руке" }),
        file("two_hands", .{ .en = "a two-handed weapon in hand", .ru = "двуручное оружие в руках" }),
        file("back", .{ .en = "a two-handed weapon on the back", .ru = "двуручное оружие за спиной" }),
    } },
    .{ .name = "Speaker", .doc = .{ .en = "A dialog speaker without an actor on the level: its portrait (0x459180); the first row that fits.", .ru = "Говорящий в диалоге без актёра на уровне: его портрет (0x459180); первая подходящая строка." }, .fields = &.{
        file("name", .{ .en = "the speaker's name in the dialog", .ru = "имя говорящего в диалоге" }),
        file("portrait", .{ .en = "the portrait (icons\\<portrait>.spr)", .ru = "портрет (icons\\<portrait>.spr)" }),
        file("prefix", .{ .en = "any speaker whose name starts with the name", .ru = "любой говорящий, чьё имя начинается с этого имени" }),
    } },
    .{ .name = "GridFloor", .doc = .{ .en = "A battle level's grid floor for the cell highlights (0x454e6e).", .ru = "Пол сетки боя для подсветки клеток (0x454e6e)." }, .fields = &.{
        file("level", .{ .en = "the battle level", .ru = "уровень боя" }),
        file("z", .{ .en = "added to the grid's height", .ru = "прибавка к высоте сетки" }),
    } },
    .{ .name = "Transform", .doc = .{ .en = "A fighter's transformation in a battle of a levelMode: the first hero strike on a non-hero arms the clock, then the fighter is freed and morphs; a dialog later.", .ru = "Превращение бойца в бою с levelMode: первый удар героя по не-герою заводит часы, затем боец освобождается и превращается; позже — диалог." }, .fields = &.{
        file("mode", .{ .en = "the battle's levelMode", .ru = "levelMode боя" }),
        file("who", .{ .en = "the fighter (object name)", .ru = "боец (имя объекта)" }),
        file("into", .{ .en = "what it turns into (.mtm)", .ru = "во что превращается (.mtm)" }),
        file("anim", .{ .en = "the transformation's animation", .ru = "анимация превращения" }),
        file("idle", .{ .en = "the idle after it", .ru = "покой после неё" }),
        file("sound", .{ .en = "its sound (\"\": none)", .ru = "его звук (\"\": нет)" }),
        file("delay", .{ .en = "ticks from the strike to the morph", .ru = "тиков от удара до превращения" }),
        file("dialog", .{ .en = "the dialog's scene (\"\": none)", .ru = "сцена диалога (\"\": нет)" }),
        file("dialog_file", .{ .en = "the dialog's file (.dlg)", .ru = "файл диалога (.dlg)" }),
        file("dialog_delay", .{ .en = "ticks from the morph to the dialog", .ru = "тиков от превращения до диалога" }),
    } },
    .{ .name = "RepeatTrim", .doc = .{ .en = "A port fix: in a scene waiting for an actor, the repeats of its animation are cut.", .ru = "Поправка порта: в сцене, ждущей актёра, повторы его анимации обрезаются." }, .fields = &.{
        file("scene", .{ .en = "the scene", .ru = "сцена" }),
        file("actor", .{ .en = "the actor it waits for (object name)", .ru = "актёр, которого она ждёт (имя объекта)" }),
        file("anim", .{ .en = "its animation whose repeats are cut", .ru = "его анимация, повторы которой обрезаются" }),
    } },
    .{ .name = "MidDialog", .doc = .{ .en = "A dialog in a battle of a levelMode after an enemy turn.", .ru = "Диалог в бою с levelMode после хода врага." }, .fields = &.{
        file("mode", .{ .en = "the battle's levelMode", .ru = "levelMode боя" }),
        file("turn", .{ .en = "after this enemy turn (turn)", .ru = "после этого хода врага (turn)" }),
        file("dialog", .{ .en = "the dialog's scene", .ru = "сцена диалога" }),
        file("dialog_file", .{ .en = "the dialog's file (.dlg)", .ru = "файл диалога (.dlg)" }),
    } },
    .{ .name = "Device", .doc = .{ .en = "A device the battle places: object <prefix><N> of a script; a bomb explodes after its timer.", .ru = "Устройство, которое ставит бой: объект <prefix><N> из скрипта; бомба взрывается по таймеру." }, .fields = &.{
        .{ .name = "kind", .doc = .{ .en = "what it is", .ru = "что это" }, .words = &device_kinds },
        file("archetype", .{ .en = "its script (ft_time_bomb.ss)", .ru = "его скрипт (ft_time_bomb.ss)" }),
        file("prefix", .{ .en = "its objects' name before the number", .ru = "имя его объектов перед номером" }),
        file("timer", .{ .en = "a bomb's enemy turns to the blast", .ru = "ходов врага до взрыва бомбы" }),
    } },
    .{ .name = "StateEffect", .doc = .{ .en = "A fighter state: how many turns it lasts (one more applied in the enemy turn) and its damage at each turn start.", .ru = "Состояние бойца: сколько ходов длится (на ход дольше, если наложено в ход врага) и урон в начале каждого хода." }, .fields = &.{
        .{ .name = "effect", .doc = .{ .en = "the state", .ru = "состояние" }, .words = &effects },
        file("turns", .{ .en = "turns it lasts (0: the battle, as a bite)", .ru = "сколько ходов длится (0: весь бой, как укус)" }),
        file("damage", .{ .en = "damage at the turn starts, list(first, second, …); without turns: every turn the first", .ru = "урон в начале ходов, list(первый, второй, …); без ходов — каждый ход первый" }),
    } },
    .{ .name = "Material", .doc = .{ .en = "A material a part names (material = \"name\"): its colour, alpha and k over the part's life, a blend and a CPU program (the battle layer, the editor's preview).", .ru = "Материал, который называет часть (material = \"name\"): цвет, прозрачность и k за жизнь части, смешивание и CPU-программа (слой боя, превью редактора)." }, .fields = &.{
        file("name", .{ .en = "the name parts use", .ru = "имя, по которому ссылаются части" }),
        .{ .name = "program", .doc = .{ .en = "the CPU program", .ru = "CPU-программа" }, .words = &programs },
        .{ .name = "blend", .doc = .{ .en = "the blend (left out: the part's own)", .ru = "смешивание (не задано: как у части)" }, .words = &blends },
        file("rgb", .{ .en = "three Track(v, rate, min, max): the colour by age", .ru = "три Track(v, rate, min, max): цвет по возрасту" }),
        file("alpha", .{ .en = "Track: the alpha by age", .ru = "Track: прозрачность по возрасту" }),
        file("k", .{ .en = "Track: the program's strength by age", .ru = "Track: сила программы по возрасту" }),
    } },
    .{ .name = "PostChain", .doc = .{ .en = "The frame's post-processing (OpenGorky): steps over the drawn world, before the interface; a level's own row, else (a battle) its location's, else the global one. CPU only.", .ru = "Постобработка кадра (OpenGorky): шаги поверх нарисованного мира, до интерфейса; своя строка уровня, иначе (бой) строка его локации, иначе общая. Только CPU." }, .fields = &.{
        file("level", .{ .en = "the level this chain is for (\"01_port\"; a battle is a level of its own, without one it takes its location's: 01_port for every 01__… battle); \"\": every level without its own", .ru = "уровень, для которого эта цепочка (\"01_port\"; бой — отдельный уровень, без своей берёт цепочку локации: 01_port для всех боёв 01__…); \"\": все уровни без своей" }),
        file("steps", .{ .en = "list(Post(program = grade | vignette | scanlines | hsl, k, rgb), …), in order", .ru = "list(Post(program = grade | vignette | scanlines | hsl, k, rgb), …), по порядку" }),
    } },
};

test "rulesapi: every rules call and every field it takes has docs in both languages" {
    for (og.loaders.rules_text.calls) |name| {
        const c = find(name) orelse {
            std.debug.print("rulesapi.zig: no entry for {s}\n", .{name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(c.doc.en.len > 0 and c.doc.ru.len > 0);
        for (c.fields) |f| try std.testing.expect(f.doc.en.len > 0 and f.doc.ru.len > 0);
        const names = fieldsOf(name) orelse continue;
        var n: usize = 0;
        for (names) |fname| {
            // The comment and a key's class (written as the key) are no fields of the file.
            if (std.mem.eql(u8, fname, "note") or (std.mem.endsWith(u8, fname, "_class") and has(names, fname[0 .. fname.len - 6]))) continue;
            n += 1;
            if (field(c, fname) == null) std.debug.print("rulesapi.zig: {s} has no doc for {s}\n", .{ name, fname });
            try std.testing.expect(field(c, fname) != null);
        }
        // No doc of a field the call lacks.
        try std.testing.expectEqual(n, c.fields.len);
    }
    try std.testing.expectEqual(og.loaders.rules_text.calls.len, all.len);
}

fn has(names: []const []const u8, n: []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

test "rulesapi: a word field's words are its enum's, each described" {
    inline for (.{ rules.Set, modules.Tables }) |S| inline for (@typeInfo(S).@"struct".field_names) |sn| {
        const Row = @typeInfo(@FieldType(S, sn)).pointer.child;
        const c = find(Row.call).?;
        inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |n, T| {
            const E = switch (@typeInfo(T)) {
                .optional => |o| o.child,
                else => T,
            };
            if (@typeInfo(E) == .@"enum") {
                const f = field(c, n).?;
                inline for (@typeInfo(E).@"enum".field_names) |tag| {
                    if (word(f, tag) == null) std.debug.print("rulesapi.zig: {s}.{s} has no word {s}\n", .{ Row.call, n, tag });
                    try std.testing.expect(word(f, tag) != null);
                }
                for (f.words) |w| try std.testing.expect(w.doc.en.len > 0 and w.doc.ru.len > 0);
            }
        }
    };
}

test "rulesapi: Resist's resist takes the resistance words (rows.Flags)" {
    const f = field(find("Resist").?, "resist").?;
    try std.testing.expectEqual(rules.rows.Flags.words.len, f.words.len);
    for (rules.rows.Flags.words, f.words) |w, x| try std.testing.expectEqualStrings(w, x.name);
}

test "rulesapi: types and defaults from the rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = shape(arena.allocator(), "AiProfile", "class");
    try std.testing.expectEqualStrings("int", s.ty);
    try std.testing.expectEqualStrings("0", s.default);
    try std.testing.expect(shape(arena.allocator(), "AiProfile", "scoring").optional);
    try std.testing.expectEqualStrings("\"add\" | \"alpha\" | \"screen\"", shape(arena.allocator(), "Material", "blend").ty);
    try std.testing.expectEqualStrings("", shape(arena.allocator(), "MonsterAttack", "anim").default);
    try std.testing.expectEqualStrings("int | \"class\"", shape(arena.allocator(), "Resist", "fighter").ty);
}

/// The fields table row call `name` takes (`Resist` → its row's fields); null for another
/// (the docs test: every one documented).
fn fieldsOf(name: []const u8) ?[]const []const u8 {
    inline for (@typeInfo(og.rules.Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(og.rules.Set, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(name, Row.call)) return fieldNames(Row);
    }
    inline for (@typeInfo(og.core.modules.Tables).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(og.core.modules.Tables, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(name, Row.call)) return fieldNames(Row);
    }
    return null;
}

fn fieldNames(comptime Row: type) []const []const u8 {
    const out = comptime blk: {
        var o: []const []const u8 = &.{};
        for (@typeInfo(Row).@"struct".field_names) |n| o = o ++ &[_][]const u8{n};
        break :blk o;
    };
    return out;
}
