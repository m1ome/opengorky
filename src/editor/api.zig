//! Script functions the engine runs (src/builtins.zig — every one the game's scripts
//! call), for the code editor's help: parameters with a sample value each (`?` —
//! optional) and what the function does.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Fn = struct {
    name: []const u8,
    /// `type name=sample, ?type name=sample`; samples hold no commas.
    params: []const u8,
    en: []const u8,
    ru: []const u8,
};

pub const Param = struct {
    optional: bool,
    /// `int x`.
    decl: []const u8,
    sample: []const u8,
};

pub fn find(name: []const u8) ?*const Fn {
    for (&all) |*f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    return null;
}

/// The parameters of `f` (up to `buf.len`).
pub fn params(f: *const Fn, buf: []Param) []Param {
    var n: usize = 0;
    if (f.params.len == 0) return buf[0..0];
    var it = std.mem.splitSequence(u8, f.params, ", ");
    while (it.next()) |p| {
        if (n == buf.len) break;
        const opt = p[0] == '?';
        const s = p[@intFromBool(opt)..];
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse s.len;
        buf[n] = .{ .optional = opt, .decl = s[0..eq], .sample = if (eq < s.len) s[eq + 1 ..] else "0" };
        n += 1;
    }
    return buf[0..n];
}

/// The arguments a new call gets: the samples of the required parameters.
pub fn sampleArgs(a: Allocator, f: *const Fn) ![]const u8 {
    var buf: [12]Param = undefined;
    var out: std.ArrayList(u8) = .empty;
    for (params(f, &buf)) |p| {
        if (p.optional) break;
        if (out.items.len > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, p.sample);
    }
    return out.items;
}

pub const all = [_]Fn{
    .{ .name = "ABA_Impulse", .params = "string object=\"09_sejf\"", .en = "Triggers one playback of an active bitmap animation object (e.g. a lever or smoke puff). Ignored for other object kinds.", .ru = "Запускает однократное проигрывание объекта активной битмап-анимации (рычаг, клуб дыма). Для других объектов ничего не делает." },
    .{ .name = "ActivateLink", .params = "string point=\"pila prawa\", string mesh=\"pila\", ?int flag=1", .en = "Shows a mesh on a link point of the current actor (Headnail's saws). The third argument is ignored by the port.", .ru = "Показывает меш на точке связи текущего актёра (пилы Headnail). Третий аргумент порт игнорирует." },
    .{ .name = "Actor_ActivateLink", .params = "string actor=\"Sullivan\", string item=\"decha\"", .en = "Shows the item's mesh in the actor's hand (two_hands point for two-handed items, else one_hand).", .ru = "Показывает меш предмета в руке актёра (точка two_hands для двуручных, иначе one_hand)." },
    .{ .name = "Actor_DeactivateAllLinks", .params = "string actor=\"Sullivan\"", .en = "Removes all meshes attached to the actor's link points.", .ru = "Убирает все меши, прикреплённые к точкам связи актёра." },
    .{ .name = "Actor_GORunFun", .params = "string actor=\"Sullivan\", string object=\"decha\", string function=\"UniversalTake\"", .en = "Immediately calls the object's script function with the actor's name (not through the queue).", .ru = "Сразу вызывает функцию скрипта объекта с именем актёра (не через очередь)." },
    .{ .name = "Actor_HaveAmmoForWeapon", .params = "string actor=\"Sullivan\", string weapon=\"su_rifle\"", .en = "Returns 1 if the actor owns an item whose nameID matches the weapon's ammoUsed and whose counter is above 0, otherwise 0.", .ru = "Возвращает 1, если у актёра есть предмет с nameID, равным ammoUsed оружия, и счётчиком больше 0, иначе 0." },
    .{ .name = "Actor_QueueDelay", .params = "string actor=\"Sullivan\", int ticks=65", .en = "Adds a pause of ticks to the actor's command queue.", .ru = "Добавляет в очередь команд актёра паузу на ticks тиков." },
    .{ .name = "Actor_QueueJustifyPosition", .params = "string actor=\"Sullivan\"", .en = "When the actor's command queue reaches this entry, shifts the actor by the offset of the shown pose from the last frame of its current animation; the next animation starts without blending.", .ru = "Когда очередь команд актёра дойдёт до этой записи, сдвигает актёра на смещение показанной позы от последнего кадра текущей анимации; следующая анимация начнётся без сглаживания." },
    .{ .name = "Actor_QueuePlace", .params = "string actor=\"Sullivan\", string area=\"capt_start\", int index=0", .en = "When the actor's command queue reaches this entry, puts the actor at point index of the area (floor 0) and drops the rest of its queue; the next animation starts without blending.", .ru = "Когда очередь команд актёра дойдёт до этой записи, ставит актёра в точку index области (этаж 0) и сбрасывает остаток очереди; следующая анимация начнётся без сглаживания." },
    .{ .name = "Actor_QueueState", .params = "string actor=\"Sullivan\", int state=1", .en = "Adds a hold state change to the actor's command queue; in battle 0 and 1 become 7 and 8, state 4 also takes the meshes off the link points. Not used by the game's scripts.", .ru = "Добавляет в очередь команд актёра смену стойки; в бою 0 и 1 становятся 7 и 8, стойка 4 ещё снимает меши с точек связи. В скриптах игры не используется." },
    .{ .name = "Actor_QueueGOScriptFunc", .params = "string actor=\"Sullivan\", string object=\"03m_monitors\", string function=\"CardSound\"", .en = "When the actor's command queue reaches this entry, calls the object's script function with the actor's name.", .ru = "Когда очередь команд актёра дойдёт до этой записи, вызывает функцию скрипта объекта с именем актёра." },
    .{ .name = "Actor_SetAnimation", .params = "string actor=\"Sullivan\", string anim=\"idle\", ?int noBlend=1", .en = "Queues a one-shot animation on the actor after its current commands; \"idle\" means the idle of the current state. noBlend = 1 starts it without blending from the previous animation.", .ru = "Ставит в очередь актёра разовую анимацию после текущих команд; \"idle\" — idle текущего состояния. noBlend = 1 — без сглаживания с предыдущей анимацией." },
    .{ .name = "Actor_SetAsyncAnimation", .params = "string actor=\"Sullivan\", string anim=\"box\", ?int noBlend=0, ?int reverse=1", .en = "Queues a one-shot animation on the actor without waiting for its end; reverse plays it from the last frame. noBlend = 1 starts it without blending from the previous animation.", .ru = "Ставит в очередь актёра разовую анимацию без ожидания её конца; reverse проигрывает с последнего кадра. noBlend = 1 — без сглаживания с предыдущей анимацией." },
    .{ .name = "Actor_SetState", .params = "string actor=\"Sullivan\", int state=2, ?int flag=1", .en = "Sets the actor's hold state and, if it is not busy, picks a new idle. flag = 1: the next animation starts without blending.", .ru = "Задаёт состояние актёра и, если он не занят, выбирает новый idle. flag = 1 — следующая анимация без сглаживания." },
    .{ .name = "Actor_TextEffect", .params = "string actor=\"Sullivan\", int text=513", .en = "Shows a popup with string.tab text number text over a placed actor (like \"No ammo\" in battle) and plays battle_noammo.", .ru = "Показывает над поставленным актёром всплывающий текст из string.tab с номером text (как \"No ammo\" в бою) и проигрывает battle_noammo." },
    .{ .name = "ActorAdjustAngle", .params = "", .en = "Path script: turns the path's actor to the current path point's angle (the last point's at the path end).", .ru = "Скрипт пути: поворачивает актёра на угол текущей точки пути (в конце пути — последней точки)." },
    .{ .name = "ActorAnimation", .params = "string anim=\"ladder_start\", ?int a=1, ?int b=0, ?int reverse=1", .en = "Path script: plays a one-shot animation and movement waits for its end; reverse = 1 plays it backwards. a = 1: no blending into it, b = 1: none into the next one.", .ru = "Скрипт пути: разовая анимация, движение ждёт её конца; reverse = 1 — задом наперёд. a = 1 — без сглаживания в неё, b = 1 — в следующую." },
    .{ .name = "ActorAsyncAnimation", .params = "string anim=\"walk\", ?int a=0, ?int b=1, ?int reverse=0", .en = "Path script: plays a one-shot animation without stopping movement; flags as in ActorAnimation.", .ru = "Скрипт пути: разовая анимация без остановки движения; флаги как в ActorAnimation." },
    .{ .name = "ActorAsyncWalkAnimation", .params = "?int a=0, ?int b=1", .en = "Path script: starts the walk animation at once (the one queued by ActorQueueWalkAnimation if any, else the current walk) without stopping movement. a = 1: no blending into it, b = 1: none into the next one.", .ru = "Скрипт пути: сразу запускает анимацию ходьбы (поставленную ActorQueueWalkAnimation, если есть, иначе текущую) без остановки движения. a = 1 — без сглаживания в неё, b = 1 — в следующую." },
    .{ .name = "ActorDelay", .params = "int ticks=60", .en = "Path script: pauses the path's actor for ticks.", .ru = "Скрипт пути: приостанавливает актёра на ticks тиков." },
    .{ .name = "ActorDisableInterpolation", .params = "", .en = "Path script: the next animation starts without blending from the previous one.", .ru = "Скрипт пути: следующая анимация начнётся без сглаживания с предыдущей." },
    .{ .name = "ActorEnableRotation", .params = "int enable=0", .en = "Path script: 0 stops the actor turning toward path points, 1 turns it again.", .ru = "Скрипт пути: 0 — актёр не поворачивается к точкам пути, 1 — снова поворачивается." },
    .{ .name = "ActorInArea", .params = "string actor=\"Sullivan\", string area=\"capt_start\"", .en = "Returns 1 if the actor's background position is inside the area, else 0.", .ru = "Возвращает 1, если позиция актёра на фоне внутри области, иначе 0." },
    .{ .name = "ActorModifyScale", .params = "float k=1.15", .en = "Multiplies the current actor's model scale by k.", .ru = "Умножает масштаб модели текущего актёра на k." },
    .{ .name = "ActorPutBackItem", .params = "string actor=\"Sullivan\"", .en = "Queues putting the two-handed weapon in hand on the back: \"hide_back\", the meshes off the link points, the weapon on \"back\", state 0. Does nothing without a two-handed item in hand. Not used by the game's scripts.", .ru = "Ставит в очередь убрать двуручное оружие из рук за спину: \"hide_back\", меши с точек связи снимаются, оружие на \"back\", стойка 0. Без двуручного предмета в руке ничего не делает. В скриптах игры не используется." },
    .{ .name = "ActorPutFrontItem", .params = "string actor=\"Sullivan\"", .en = "Queues taking the two-handed weapon from the back: after the animation blend, the meshes off the link points, state 1, \"hide_back\" backwards without waiting, 30 ticks, the weapon on \"two_hands\". Not used by the game's scripts.", .ru = "Ставит в очередь достать двуручное оружие из-за спины: после смешивания анимаций меши снимаются с точек связи, стойка 1, \"hide_back\" задом наперёд без ожидания, 30 тиков, оружие на \"two_hands\". В скриптах игры не используется." },
    .{ .name = "ActorQueueDelay", .params = "int ticks=60", .en = "Path script: pauses the actor's path movement for ticks (the same handler as ActorDelay). Not used by the game's scripts.", .ru = "Скрипт пути: приостанавливает движение актёра по пути на ticks тиков (тот же обработчик, что у ActorDelay). В скриптах игры не используется." },
    .{ .name = "ActorQueueWaitForAnimation", .params = "?string anim=\"stepping\"", .en = "Path script: movement along the path waits until the current one-shot animation ends. The optional name only lets the queue go on in the same tick when it is the animation that ended.", .ru = "Скрипт пути: движение по пути ждёт окончания текущей разовой анимации. Необязательное имя лишь даёт очереди продолжить в тот же тик, если закончилась именно эта анимация." },
    .{ .name = "ActorQueueWaitForInterpolation", .params = "", .en = "Path script: movement waits for the animation blend to finish.", .ru = "Скрипт пути: движение ждёт окончания сглаживания анимации." },
    .{ .name = "ActorQueueWalkAnimation", .params = "string anim=\"ladder_end\", ?int a=0, ?int b=1, ?int reverse=1", .en = "Path script: queues a one-shot animation for the next path segment; a = 1 plays it without blending, reverse = 1 backwards.", .ru = "Скрипт пути: ставит разовую анимацию на следующий отрезок пути; a = 1 — без сглаживания, reverse = 1 — задом наперёд." },
    .{ .name = "ActorSetWalkAnimation", .params = "string anim=\"ladder_walk\", ?int reverse=0", .en = "Path script: the path's actor walks the rest of the path with this animation and its speed; non-zero reverse plays it backwards (going down a ladder).", .ru = "Скрипт пути: актёр идёт остаток пути с этой анимацией и её скоростью; ненулевой reverse проигрывает её задом наперёд (спуск по лестнице)." },
    .{ .name = "ActorSetWalkSpeed", .params = "string anim=\"walk\", float speed=3.6", .en = "Sets the current actor's movement speed for a walk animation, in world pixels per tick; speed must be a float.", .ru = "Задаёт текущему актёру скорость движения для анимации ходьбы, в пикселях мира за тик; speed должен быть float." },
    .{ .name = "AdjustAngle", .params = "float degrees=180.0", .en = "Sets the current actor's model orientation correction in degrees; float only.", .ru = "Задаёт поправку ориентации модели текущего актёра в градусах; только float." },
    .{ .name = "AIEnemyAppear", .params = "string name=\"01pr_sfinks2\", int x0=7, int y0=33, int x1=7, int y1=30", .en = "The enemy is placed at tile (x0, y0), often outside the grid, and walks to (x1, y1) at battle start.", .ru = "Враг ставится на клетку (x0, y0), часто за краем сетки, и в начале боя идёт на (x1, y1)." },
    .{ .name = "AIFreeTile", .params = "int x=18, int y=6", .en = "Returns 1 if the battle grid tile is inside the grid, open and unoccupied, otherwise 0 (also 0 outside battle).", .ru = "Возвращает 1, если клетка боевой сетки внутри сетки, проходима и свободна, иначе 0 (вне боя тоже 0)." },
    .{ .name = "AIGetTurnNo", .params = "", .en = "Returns the current battle turn number, or 0 outside battle.", .ru = "Возвращает номер текущего хода боя, вне боя 0." },
    .{ .name = "AIGuardPoint", .params = "string fighter=\"03lr_jetelmer1\", int x=6, int y=2", .en = "The fighter holds the battle tile (x, y) (sets aiMode 3).", .ru = "Боец удерживает клетку боя (x, y) (ставит aiMode 3)." },
    .{ .name = "AITargetLock", .params = "string fighter=\"03lr_siner1\", string target=\"03lr_barrel1\"", .en = "The fighter attacks only this target (sets aiMode 1).", .ru = "Боец атакует только эту цель (ставит aiMode 1)." },
    .{ .name = "AllowWalkInArea", .params = "string area=\"kladka\", ?int floor=0", .en = "Opens the walk map cells inside the area polygon on floor 0 (.wm) or 1 (.wm2).", .ru = "Открывает клетки карты ходьбы внутри полигона зоны на этаже 0 (.wm) или 1 (.wm2)." },
    .{ .name = "Ambient_New", .params = "string name=\"05lr_reactor_snd\", int x=320, int y=240, string wav=\"inside_reactor_loop.wav\"", .en = "Creates an ambient object: a looping sound at background point (x, y). Does nothing if an object with that name already exists.", .ru = "Создаёт ambient-объект: зацикленный звук в точке фона (x, y). Ничего не делает, если объект с таким именем уже есть." },
    .{ .name = "AnyHero_HaveAmmoForWeapon", .params = "string weapon=\"su_rifle\"", .en = "Returns 1 if any party hero has ammo for the weapon (same test as Actor_HaveAmmoForWeapon), otherwise 0.", .ru = "Возвращает 1, если у кого-то из героев отряда есть патроны к оружию (та же проверка, что в Actor_HaveAmmoForWeapon), иначе 0." },
    .{ .name = "AnyHero_HaveItem", .params = "string item=\"04c_adv_rocket\"", .en = "Returns 1 if the item's owner is a party hero, otherwise 0.", .ru = "Возвращает 1, если владелец предмета герой отряда, иначе 0." },
    .{ .name = "AttachActors", .params = "string parent=\"ponton\", string actor=\"Sullivan\", float a=0.0, float b=10.0, float c=5.0, float angle=0.0", .en = "Attaches an actor to the parent at the given offset, so it moves with the parent: a and b horizontal in the parent's axes, c height, world units; angle is added to the parent's. All four must be floats. Not used by the game's scripts.", .ru = "Прикрепляет актёра к родителю с заданным смещением, и он движется вместе с ним: a и b по горизонтали в осях родителя, c по высоте, в мировых единицах; angle прибавляется к углу родителя. Все четыре должны быть float. В скриптах игры не используется." },
    .{ .name = "AttachActorsByLink", .params = "string parent=\"ponton\", string actor=\"Sullivan\", string point=\"Sullivan\"", .en = "Attaches an actor to a link point of the parent's mesh, so it moves with the parent. Does nothing if the point is missing.", .ru = "Прикрепляет актёра к точке связи меша родителя, и он движется вместе с ним. Ничего не делает, если точки нет." },
    .{ .name = "AVI_Play", .params = "string file=\"Stingermus.avi\", int x=0, int y=60, int double=1", .en = "Plays a video (e.g. before a boss battle) at screen position (x, y); double 1 shows it at double size.", .ru = "Проигрывает видео (например, перед боем с боссом) в позиции экрана (x, y); double 1 показывает его в двойном размере." },
    .{ .name = "DeactivateLink", .params = "string point=\"pila prawa\"", .en = "Takes the mesh off a link point of the current actor (the opposite of ActivateLink). Not used by the game's scripts.", .ru = "Снимает меш с точки связи текущего актёра (обратное ActivateLink). В скриптах игры не используется." },
    .{ .name = "DeleteObject", .params = "string object=\"Slavsky\"", .en = "Disables the named object and marks it deleted.", .ru = "Выключает указанный объект и помечает его удалённым." },
    .{ .name = "DetachActorsFrom", .params = "string parent=\"ponton\"", .en = "Detaches all actors attached to the parent and clears their model offsets.", .ru = "Открепляет всех актёров, прикреплённых к родителю, и сбрасывает смещения их моделей." },
    .{ .name = "DialogInit", .params = "string name=\"lab-after_teleport\", string file=\"lab-after_teleport.dlg\"", .en = "Shows a whole dialog from the .dlg file, line by line.", .ru = "Показывает весь диалог из файла .dlg, реплику за репликой." },
    .{ .name = "Disable", .params = "", .en = "Disables the current actor (the one whose script runs).", .ru = "Выключает текущего актёра (того, чей скрипт выполняется)." },
    .{ .name = "DisableHeroes", .params = "", .en = "Disables every party hero except the selected one. Called right after LEVEL_Load it applies to the new level.", .ru = "Выключает всех героев отряда, кроме выбранного. Сразу после LEVEL_Load действует на новом уровне." },
    .{ .name = "DisableObject", .params = "string object=\"Trantigne\"", .en = "Disables the named object; it stays in the level and can be enabled again.", .ru = "Выключает указанный объект; он остаётся на уровне, его можно включить снова." },
    .{ .name = "EnableHeroes", .params = "", .en = "Enables all heroes that do not have avoidEnumerate set (party members).", .ru = "Включает всех героев без флага avoidEnumerate (членов отряда)." },
    .{ .name = "EnableObject", .params = "string object=\"01pr_sfinks2\"", .en = "Enables the named object (it becomes active and visible again).", .ru = "Включает указанный объект (он снова активен и виден)." },
    .{ .name = "EndTurnGlobal", .params = "", .en = "Ends the current side's turn in battle.", .ru = "Завершает ход текущей стороны в бою." },
    .{ .name = "FadeIn", .params = "", .en = "Fades the screen in from black. After LEVEL_Load it applies to the new level.", .ru = "Плавно проявляет экран из чёрного. После LEVEL_Load действует на новом уровне." },
    .{ .name = "FighterGetHp", .params = "string fighter=\"Sullivan\"", .en = "Returns the fighter's current hit points (0 if the object is not found).", .ru = "Возвращает текущие очки здоровья бойца (0, если объект не найден)." },
    .{ .name = "FighterSetHp", .params = "string fighter=\"Sullivan\", int hp=50", .en = "Sets the fighter's hit points. Only an integer value is accepted; there is no upper clamp.", .ru = "Задаёт очки здоровья бойца. Принимается только целое число; верхнего предела нет." },
    .{ .name = "FighterSetLevel", .params = "string fighter=\"Slavsky\", int level=5", .en = "Sets the fighter's level and its experience to that level's threshold.", .ru = "Задаёт бойцу уровень и опыт, равный порогу этого уровня." },
    .{ .name = "FighterSetWeaponSkillLevel", .params = "string fighter=\"Slavsky\", int weapon=76, int level=8", .en = "Sets the fighter's skill level for the weapon with this nameID, adding the skill if missing.", .ru = "Задаёт бойцу уровень владения оружием с этим nameID; если навыка нет, добавляет его." },
    .{ .name = "ForbidWalkInArea", .params = "string area=\"ciuch_blokada\", ?int floor=0", .en = "Blocks the walk map cells inside the area polygon on floor 0 (.wm) or 1 (.wm2).", .ru = "Закрывает клетки карты ходьбы внутри полигона зоны на этаже 0 (.wm) или 1 (.wm2)." },
    .{ .name = "GetName", .params = "", .en = "Returns the name of the object whose script is running.", .ru = "Возвращает имя объекта, чей скрипт выполняется." },
    .{ .name = "GetNameID", .params = "string object=\"Lucy\"", .en = "Returns the object's nameID (heroes: 20 Sullivan, 21 Ovitz, 22 Trantigne, 24 Lucy); \"this\" means the caller. Returns -1 if there is no such object.", .ru = "Возвращает nameID объекта (герои: 20 Sullivan, 21 Ovitz, 22 Trantigne, 24 Lucy); \"this\" — вызывающий. Возвращает -1, если объекта нет." },
    .{ .name = "GO_RunFun", .params = "string object=\"04_city\", string function=\"EnableFactoryOut\"", .en = "Calls the object's function (extra arguments are passed on), also on objects of other loaded levels. Returns the function's result, or 0.", .ru = "Вызывает функцию объекта (дополнительные аргументы передаются дальше), в том числе у объектов других загруженных уровней. Возвращает результат функции или 0." },
    .{ .name = "GUI_Disable", .params = "int mode=2", .en = "0 returns to normal mode, 1 turns panorama off, 2 enters scene mode (no player control, automatic camera).", .ru = "0 возвращает обычный режим, 1 выключает панораму, 2 включает режим сцены (без управления, автокамера)." },
    .{ .name = "GUI_GetSelectedHero", .params = "", .en = "Returns the name of the currently selected hero.", .ru = "Возвращает имя выбранного сейчас героя." },
    .{ .name = "GUI_IsHero", .params = "string name=\"Slavsky\"", .en = "Returns 1 if the hero is in the party (on the panel) and enabled, otherwise 0.", .ru = "Возвращает 1, если герой в отряде (на панели) и включён, иначе 0." },
    .{ .name = "GUI_Panorama", .params = "int on=1", .en = "Turns panorama mode on (non-zero) or off (0).", .ru = "Включает (не 0) или выключает (0) режим панорамы." },
    .{ .name = "GUI_SelectMode", .params = "string mode=\"GUI_Staging\"", .en = "\"GUI_Staging\" starts the battle with the enemy turn (enemies walk in); \"GUI_SafeBox\" opens the safe keypad for the calling area.", .ru = "\"GUI_Staging\" начинает бой с хода врагов (они входят на поле); \"GUI_SafeBox\" открывает кодовый замок сейфа для вызывающей зоны." },
    .{ .name = "HERO_EnableEnumerate", .params = "string hero=\"MacFadden\", int on=1", .en = "The hero joins (1) or leaves (0) the party; sets avoidEnumerate to the opposite.", .ru = "Герой вступает в отряд (1) или уходит из него (0); avoidEnumerate ставится в обратное значение." },
    .{ .name = "HeroInArea", .params = "string area=\"fight_01\"", .en = "Returns 1 if any enabled, placed hero stands inside the area polygon (by background point), otherwise 0.", .ru = "Возвращает 1, если хоть один включённый и размещённый герой стоит внутри полигона зоны (по точке на фоне), иначе 0." },
    .{ .name = "IsObject", .params = "string name=\"Sullivan\"", .en = "Returns 1 if an object with this name exists, else 0.", .ru = "Возвращает 1, если объект с таким именем существует, иначе 0." },
    .{ .name = "Item_Animation", .params = "string item=\"this\", string anim=\"box\", int reverse=0", .en = "Plays the item model's animation once and holds the last frame; reverse 1 plays it backwards (a box closes with \"box\" reversed).", .ru = "Проигрывает анимацию модели предмета один раз и держит последний кадр; reverse 1 играет её задом наперёд (ящик закрывается обратной \"box\")." },
    .{ .name = "Item_DisableWalkCircle", .params = "string item=\"this\"", .en = "Blocks the .wm walk cells within the item's radius (background pixels, if 2 or more).", .ru = "Закрывает клетки .wm в пределах radius предмета (пиксели фона, если не меньше 2)." },
    .{ .name = "Item_EnableWalkCircle", .params = "string item=\"this\"", .en = "Makes the .wm walk cells within the item's radius (background pixels, if 2 or more) walkable.", .ru = "Делает проходимыми клетки .wm в пределах radius предмета (пиксели фона, если не меньше 2)." },
    .{ .name = "Item_GetNameID", .params = "string item=\"03mf_matrix\"", .en = "Returns the item's nameID, or -1 if the object is missing or not an item.", .ru = "Возвращает nameID предмета или -1, если объекта нет или это не предмет." },
    .{ .name = "Item_GetPlace", .params = "string item=\"03mf_matrix\"", .en = "Returns the item's place (0 = ground), or -1 if the object is missing or not an item.", .ru = "Возвращает место предмета (0 = земля) или -1, если объекта нет или это не предмет." },
    .{ .name = "Item_GetType", .params = "string item=\"decha\"", .en = "Returns the item's type field, or -1 if the object is missing or not an item.", .ru = "Возвращает поле type предмета или -1, если объекта нет или это не предмет." },
    .{ .name = "Item_New", .params = "string name=\"su_am_pistol\", string class=\"ca_pistolammo.s\", string owner=\"Sullivan\", ?int count=12", .en = "Creates an item object of the class. A string third argument is the owner, a number is the counter; the fourth argument, if any, is the counter (e.g. ammo amount).", .ru = "Создаёт предмет этого класса. Третий аргумент-строка это владелец, число это счётчик; четвёртый аргумент, если есть, это счётчик (например, число патронов)." },
    .{ .name = "Item_SetAngle", .params = "string item=\"tlen\", float angle=1.57", .en = "Sets the item's rotation angle in radians.", .ru = "Задаёт угол поворота предмета в радианах." },
    .{ .name = "Item_SetFuncID", .params = "string item=\"tlen\", int funcID=-1", .en = "Sets the item's funcID.", .ru = "Задаёт предмету funcID." },
    .{ .name = "Item_SetNameID", .params = "string item=\"decha\", int nameID=-1", .en = "Sets the item's nameID (its name/type id).", .ru = "Задаёт предмету nameID (идентификатор имени/типа)." },
    .{ .name = "Item_SetPlace", .params = "string item=\"tlen\", int place=0", .en = "Sets the item's place; 0 (ground) on an owned item clears its owner, and a hero holding it in hand goes unarmed.", .ru = "Задаёт место предмета; 0 (земля) у предмета с владельцем снимает владельца, а герой, державший его в руке, остаётся без оружия." },
    .{ .name = "Item_SetPos", .params = "string item=\"decha\", float x=1455.0, float y=-394.0, float z=128.0", .en = "Moves the item to world coordinates. Alternative form (item, \"area\", point, z): puts it at an area polygon point (-1 = control point) on the floor raised by z.", .ru = "Переносит предмет в мировые координаты. Другая форма (item, \"area\", point, z): ставит его в точку полигона зоны (-1 = контрольная точка) на полу, поднятым на z." },
    .{ .name = "Item_SetVisible", .params = "string item=\"Nota2\", int visible=1", .en = "Shows (1) or hides (0) the item.", .ru = "Показывает (1) или прячет (0) предмет." },
    .{ .name = "LEVEL_DecAdvVar", .params = "", .en = "Subtracts 1 from the level progress counter (advVar).", .ru = "Вычитает 1 из счётчика прогресса уровня (advVar)." },
    .{ .name = "LEVEL_GetAdvVar", .params = "", .en = "Returns the level progress counter (advVar), 0 if there is no level object.", .ru = "Возвращает счётчик прогресса уровня (advVar), 0 если объекта уровня нет." },
    .{ .name = "LEVEL_IncAdvVar", .params = "", .en = "Adds 1 to the level progress counter (advVar of the level object, saved with it).", .ru = "Прибавляет 1 к счётчику прогресса уровня (advVar объекта уровня, сохраняется вместе с ним)." },
    .{ .name = "LEVEL_Load", .params = "string level=\"05__lab_incubus\"", .en = "Queues a move to the named level. Some later calls in the same script call (FadeIn, PlaceHeroes, DisableHeroes) are deferred and apply to the new level.", .ru = "Ставит в очередь переход на указанный уровень. Некоторые следующие вызовы в том же вызове скрипта (FadeIn, PlaceHeroes, DisableHeroes) откладываются и действуют уже на новом уровне." },
    .{ .name = "LEVEL_LoadAB", .params = "string level=\"03_museum\"", .en = "Same as LEVEL_Load, but the new level then gets AfterBattle(previous level name), as after a battle.", .ru = "То же, что LEVEL_Load, но новый уровень затем получает AfterBattle(имя прошлого уровня), как после боя." },
    .{ .name = "LEVEL_SetAdvVar", .params = "int value=10", .en = "Sets the level progress counter (advVar).", .ru = "Задаёт счётчик прогресса уровня (advVar)." },
    .{ .name = "LinkActor", .params = "string point=\"pilot1\", string actor=\"smoke_pilot_1\"", .en = "The actor rides the calling object at that link point of its mesh, drawn with it in its own animations (the Smoke Rider's pilots).", .ru = "Актёр едет на вызывающем объекте в этой точке связи его меша и рисуется вместе с ним в своих анимациях (пилоты Smoke Rider)." },
    .{ .name = "NotInPlaceAnimation", .params = "string anim=\"pontA_out\"", .en = "Marks an animation of the current actor as moving (not in place): its offsets count from the reference animation.", .ru = "Помечает анимацию текущего актёра как смещающую (не на месте): её смещения считаются от опорной анимации." },
    .{ .name = "PlaceActor", .params = "string name=\"Trantigne\", string area=\"capt_start\", int index=1, ?int floor=0", .en = "Puts an enabled actor at point index of an area (angle from the point), on floor 0 or 1; the alternative form PlaceActor(name, x, y[, dir]) puts it on battle grid tile (x, y) with dir in eighths of a turn. Returns 1 if the placement was reached.", .ru = "Ставит включённого актёра в точку index области (угол берётся из точки), на этаж 0 или 1; вариант PlaceActor(name, x, y[, dir]) ставит на клетку боевой сетки (x, y), dir — восьмые доли оборота. Возвращает 1, если дошло до расстановки." },
    .{ .name = "PlaceCombatActor", .params = "string actor=\"01pr_a_logs1\", float x=12.5, float y=23.0, float angle=10", .en = "Places a battle prop at a fractional grid tile (not snapped to the tile centre), rotated by angle in degrees. Returns 1 on success, 0 otherwise.", .ru = "Ставит боевой объект на дробную клетку сетки (без привязки к центру клетки), с поворотом angle в градусах. Возвращает 1 при успехе, иначе 0." },
    .{ .name = "PlaceHeroes", .params = "string area=\"capt_start\", ?int floor=0", .en = "Places the heroes in the area on floor 0 or 1 and snaps the camera. Returns 1; after LEVEL_Load it applies to the new level.", .ru = "Расставляет героев в зоне на этаже 0 или 1 и сразу переводит камеру. Возвращает 1; после LEVEL_Load действует на новом уровне." },
    .{ .name = "PlayRandomSound2D", .params = "int x=936, int y=1674, string sounds=\"crow1\", ?int chance=800", .en = "Plays one sound picked at random from a comma-separated list (up to 10) at background point (x, y). With chance > 0 it plays only with probability 1/chance.", .ru = "Проигрывает в точке фона (x, y) случайный звук из списка через запятую (до 10). При chance > 0 звучит лишь с вероятностью 1/chance." },
    .{ .name = "PlaySound", .params = "string sound=\"opentreasure\", ?int loop=0", .en = "Plays a sound at the calling object's position; non-zero loop makes it loop.", .ru = "Проигрывает звук в позиции вызывающего объекта; ненулевой loop зацикливает его." },
    .{ .name = "print", .params = "string text=\"Hello!\"", .en = "Writes each argument to the engine log, prefixed with the calling object's name. Returns 0.", .ru = "Пишет каждый аргумент в лог движка с именем вызывающего объекта. Возвращает 0." },
    .{ .name = "PutLargeTimeBomb", .params = "int x=5, int y=8", .en = "Places a large time bomb on the battle tile; after 6 enemy turns it explodes and everyone dies. Returns 1 if placed, 0 if the tile is off the map.", .ru = "Ставит большую бомбу с таймером на клетку боя; через 6 ходов врагов она взрывается и все гибнут. Возвращает 1, если поставлена, 0 если клетка вне карты." },
    .{ .name = "ReferenceAnimation", .params = "string anim=\"su_idle\"", .en = "Sets the current actor's reference animation; offsets of not-in-place animations count from its first frame.", .ru = "Задаёт опорную анимацию текущего актёра; смещения анимаций не на месте отсчитываются от её первого кадра." },
    .{ .name = "RegisterAnimation", .params = "int state=0, string logical=\"defend\", string anim=\"unik\"", .en = "Maps a logical animation name to a real animation for hold state 0..8 of the current actor.", .ru = "Сопоставляет логическое имя анимации реальной анимации для состояния 0..8 текущего актёра." },
    .{ .name = "RegisterExtraBody", .params = "int slot=0, int still=0, string mesh=\"pila\"", .en = "Gives the current actor an extra body: mesh drawn in the actor's place in slot 0…3 (replacing the slot's old one); still 0 plays the actor's animations on it, else it stays on its first frame. Types must be int, int, string. Not used by the game's scripts.", .ru = "Даёт текущему актёру дополнительное тело: меш, рисуемый на месте актёра, в слоте 0…3 (заменяет прежний); still 0 — на нём играют анимации актёра, иначе он стоит на первом кадре. Типы строго int, int, string. В скриптах игры не используется." },
    .{ .name = "RegisterIdleAnimation", .params = "int state=0, string anim=\"idle\", int weight=100", .en = "Adds an idle animation for hold state 0..8 of the current actor with a random-pick weight. Without a weight nothing is registered.", .ru = "Добавляет текущему актёру idle-анимацию для состояния 0..8 с весом случайного выбора. Без веса ничего не регистрируется." },
    .{ .name = "s_stricmp", .params = "string a=\"05__lab_lamare\", string b=\"04__city_mfd\"", .en = "Case-insensitive string comparison. Returns 0 if equal, otherwise the difference of the first differing characters (or of the lengths).", .ru = "Сравнивает строки без учёта регистра. Возвращает 0 при равенстве, иначе разницу первых различающихся символов (или длин)." },
    .{ .name = "SetActorAddVariables", .params = "string actor=\"01bg_msm\", float x=-50.0, float y=10.0, float z=65.0", .en = "Sets the actor's model offset from its position; only float arguments change the corresponding axis.", .ru = "Задаёт смещение модели актёра от его позиции; меняются только оси, переданные как float." },
    .{ .name = "SetActorMap", .params = "string actor=\"Sullivan\", int floor=1", .en = "Puts the actor on floor 1 (.wm2) if floor is 1, otherwise on floor 0 (.wm).", .ru = "Ставит актёра на этаж 1 (.wm2), если floor равен 1, иначе на этаж 0 (.wm)." },
    .{ .name = "SetActorState", .params = "int state=2", .en = "Sets the hold state of the current actor (selects its animation set).", .ru = "Задаёт состояние текущего актёра (выбирает набор его анимаций)." },
    .{ .name = "SetAddonScriptlet", .params = "string scene=\"lab-enter\"", .en = "If a scene is running, queues this scene to run after it (replacing any queued one); otherwise starts it at once.", .ru = "Если идёт сцена, ставит эту сцену в очередь после неё (заменяя уже поставленную); иначе запускает сразу." },
    .{ .name = "SetGlobalStringVariable", .params = "string name=\"HERO1\", string value=\"Sullivan\"", .en = "No-op in this port: the game's scenes only read #HERO_SELECTED and #LAST_ACTION_HERO, which come from world state.", .ru = "В порте ничего не делает: сцены игры читают только #HERO_SELECTED и #LAST_ACTION_HERO, а они берутся из состояния мира." },
    .{ .name = "Signature", .params = "int frame=1", .en = "Shows a date caption (frame of intro.spr) at the bottom of the screen; -1 removes it.", .ru = "Показывает подпись с датой (кадр intro.spr) внизу экрана; -1 убирает её." },
    .{ .name = "StartScriptlet", .params = "string scene=\"port-silos\"", .en = "Starts the named scene (scriptlet) at once.", .ru = "Сразу запускает сцену (скриптлет) с этим именем." },
    .{ .name = "StopActor", .params = "string actor=\"ponton\"", .en = "Stops the actor: clears its command queue, path and current command.", .ru = "Останавливает актёра: очищает очередь команд, путь и текущую команду." },
    .{ .name = "TestActorMapChange", .params = "string area=\"MapGoUp\", int floor=1", .en = "Heroes standing in the area switch to floor 0 (.wm) or 1 (.wm2). Called from the level's update() every tick.", .ru = "Герои, стоящие в зоне, переходят на этаж 0 (.wm) или 1 (.wm2). Вызывается из update() уровня каждый тик." },
    .{ .name = "Vibrato", .params = "string actor=\"ponton\", float amplitude=2.0, float step=0.10", .en = "Makes the actor wobble with the given amplitude and phase step per tick; both must be floats.", .ru = "Заставляет актёра покачиваться с заданной амплитудой и шагом фазы за тик; оба должны быть float." },
    .{ .name = "WalkOnSceneryTrack", .params = "string actor=\"ponton\", string track=\"ponton\", ?float height=0.0, ?int start=5", .en = "Puts the actor at point start of area track at the given height and moves it along the remaining points at walk speed, turning as it goes.", .ru = "Ставит актёра в точку start области track на заданной высоте и ведёт по остальным точкам со скоростью ходьбы, поворачивая по пути." },
    .{ .name = "Weapon_New", .params = "string name=\"su_rifle\", string class=\"cw_riffle.s\", string owner=\"Sullivan\", ?int count=12", .en = "Creates a weapon object of the class. A string third argument is the owner, a number is the counter; the fourth argument, if any, is the counter.", .ru = "Создаёт оружие этого класса. Третий аргумент-строка это владелец, число это счётчик; четвёртый аргумент, если есть, это счётчик." },
};

/// The original exe's builtins: its 117 registrations (`call 0x4c2270`, name → handler),
/// in its order. A function in `all` missing here works only in the port.
const exe_names = [_][]const u8{
    "print",                      "FighterGetHp",              "FighterSetHp",               "FighterSetLevel",         "FighterSetWeaponSkillLevel",     "EndTurnGlobal",
    "FadeIn",                     "PutLargeTimeBomb",          "AIEnemyAppear",              "AIFreeTile",              "AITargetLock",                   "AIGuardPoint",
    "AIGetTurnNo",                "SetActorAddVariables",      "AllowWalkInArea",            "ForbidWalkInArea",        "TestActorMapChange",             "SetActorMap",
    "PlaceActor",                 "PlaceHeroes",               "PlaceCombatActor",           "RegisterIdleAnimation",   "RegisterAnimation",              "RegisterExtraBody",
    "ActorInArea",                "StartScriptlet",            "SetAddonScriptlet",          "SetActorState",           "ActivateLink",                   "DeactivateLink",
    "SetGlobalStringVariable",    "AttachActors",              "AttachActorsByLink",         "ActorDelay",              "ActorAnimation",                 "ActorAsyncAnimation",
    "ActorAsyncWalkAnimation",    "ActorModifyScale",          "ActorAdjustAngle",           "ActorSetWalkAnimation",   "ActorQueueWalkAnimation",        "ActorSetWalkSpeed",
    "ActorEnableRotation",        "ActorDisableInterpolation", "ActorQueueWaitForAnimation", "ActorQueueDelay",         "ActorQueueWaitForInterpolation", "ActorPutBackItem",
    "ActorPutFrontItem",          "WalkOnSceneryTrack",        "Vibrato",                    "HeroInArea",              "DetachActorsFrom",               "ABA_Impulse",
    "LEVEL_Load",                 "LEVEL_LoadAB",              "LEVEL_IncAdvVar",            "LEVEL_DecAdvVar",         "LEVEL_SetAdvVar",                "LEVEL_GetAdvVar",
    "EnableObject",               "DisableObject",             "Disable",                    "DeleteObject",            "s_stricmp",                      "StopActor",
    "GetNameID",                  "Actor_SetState",            "Actor_SetAnimation",         "Actor_SetAsyncAnimation", "Actor_QueueDelay",               "Actor_QueueState",
    "Actor_QueueJustifyPosition", "Actor_QueuePlace",          "Actor_QueueGOScriptFunc",    "Actor_GORunFun",          "Actor_ActivateLink",             "Actor_DeactivateAllLinks",
    "Actor_HaveAmmoForWeapon",    "Actor_TextEffect",          "AnyHero_HaveAmmoForWeapon",  "AnyHero_HaveItem",        "Item_SetPlace",                  "Item_SetNameID",
    "Item_SetPos",                "Item_SetAngle",             "Item_SetFuncID",             "Item_SetVisible",         "Item_GetType",                   "Item_GetNameID",
    "Item_GetPlace",              "Item_Animation",            "Item_EnableWalkCircle",      "Item_DisableWalkCircle",  "Weapon_New",                     "Item_New",
    "Ambient_New",                "Signature",                 "IsObject",                   "DialogInit",              "AdjustAngle",                    "GUI_Panorama",
    "GUI_Disable",                "GUI_SelectMode",            "GUI_GetSelectedHero",        "GUI_IsHero",              "ReferenceAnimation",             "NotInPlaceAnimation",
    "HERO_EnableEnumerate",       "EnableHeroes",              "DisableHeroes",              "PlaySound",               "PlayRandomSound2D",              "LinkActor",
    "GO_RunFun",                  "GetName",                   "AVI_Play",
};

/// Whether the original exe registers `name` (its calls ignore case).
fn inExe(name: []const u8) bool {
    for (exe_names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// A port-only extension: the port runs it, the original exe does not know it.
pub fn portOnly(f: *const Fn) bool {
    return !inExe(f.name);
}

/// Whether the port or the exe registers `name` (a call to anything else, not defined in
/// the scripts either, does nothing in both).
pub fn known(name: []const u8) bool {
    return find(name) != null or inExe(name);
}

test "api: every entry's parameters parse" {
    var buf: [12]Param = undefined;
    for (&all) |*f| {
        var seen_opt = false;
        for (params(f, &buf)) |p| {
            try std.testing.expect(std.mem.indexOfScalar(u8, p.decl, ' ') != null);
            if (seen_opt) try std.testing.expect(p.optional);
            seen_opt = seen_opt or p.optional;
        }
        try std.testing.expect(f.en.len > 0 and f.ru.len > 0);
    }
}

test "api: one entry per builtin the port registers (src/builtins.zig), no others" {
    const src = @embedFile("builtins_src");
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, ".{ \"")) |i| {
        const a = i + 4;
        const e = std.mem.indexOfScalarPos(u8, src, a, '"') orelse break;
        pos = e;
        if (find(src[a..e]) == null) std.debug.print("api.zig: no entry for builtin {s}\n", .{src[a..e]});
        try std.testing.expect(find(src[a..e]) != null);
        n += 1;
    }
    try std.testing.expectEqual(all.len, n);
}
