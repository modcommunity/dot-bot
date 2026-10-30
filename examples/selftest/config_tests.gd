extends "res://examples/selftest/trick_tests.gd"
## The profile, settings, cvar, console, names and roster sections of the bot suite.

## A command shaped like dot-player-controller's, for write_move.
class FakeMove:
	extends RefCounted
	const BUTTON_JUMP := 1 << 0
	const BUTTON_CROUCH := 1 << 1
	const BUTTON_WALK := 1 << 3
	var move := Vector2.ZERO
	var yaw := 0.0
	var pitch := 0.0
	var buttons := 0

	func set_button(button: int, pressed: bool) -> void:
		buttons = (buttons | button) if pressed else (buttons & ~button)


## A command shaped like dot-weapon's, for write_fire.
class FakeFire:
	extends RefCounted
	const BUTTON_ATTACK := 1 << 0
	const BUTTON_USER_0 := 1 << 8
	var yaw := 0.0
	var pitch := 0.0
	var buttons := 0

	func set_button(button: int, pressed: bool) -> void:
		buttons = (buttons | button) if pressed else (buttons & ~button)


## A cvar shaped like dot-server's DotConVar.
class FakeCvar:
	extends RefCounted
	signal changed(old_value: String, new_value: String)
	var name := ""
	var value := ""
	var lo := -INF
	var hi := INF
	var validator := Callable()

	func with_range(a: float, b: float) -> FakeCvar:
		lo = a
		hi = b
		return self

	func with_validator(v: Callable) -> FakeCvar:
		validator = v
		return self

	func get_string() -> String:
		return value

	func set_value(text: String) -> DotResult:
		var t := text.strip_edges()
		if t.is_valid_float() and (lo > -INF or hi < INF):
			t = str(clampf(t.to_float(), lo, hi))
		if validator.is_valid():
			var r: DotResult = validator.call(t)
			if not r.ok:
				return r
		force_set(t)
		return DotResult.success(t)

	func force_set(text: String) -> void:
		var old := value
		value = text
		if old != value:
			changed.emit(old, value)


## A console shaped like dot-console's DotConsoleLocal.
class FakeLocal:
	extends RefCounted
	var vars := {}
	var commands := {}

	func add_var(n: StringName, _help: String, get_fn: Callable, set_fn: Callable) -> FakeLocal:
		vars[String(n)] = [get_fn, set_fn]
		return self

	func add_command(n: StringName, _help: String, fn: Callable) -> FakeLocal:
		commands[String(n)] = fn
		return self

	func get_var(n: String) -> String:
		return str((vars[n][0] as Callable).call())

	func set_var(n: String, v: String) -> Variant:
		return (vars[n][1] as Callable).call(v)


func _test_profile() -> void:
	_section("presets are bundles of settings")

	var probe := DotBotProfile.new()
	var names := {}
	for property in probe.get_property_list():
		names[String(property["name"])] = true
	var all_read := true
	for field in DotBotProfile.fields():
		if not names.has(field):
			all_read = false
			print("       SPEC names %s, which the profile does not have" % field)
	_check(all_read, "every SPEC row is a profile property")
	_check(DotBotProfile.fields().size() >= 25, "at least twenty-five individual settings", str(DotBotProfile.fields().size()))

	var fresh := DotBotProfile.new()
	var medium := DotBotProfile.preset("medium")
	var same := true
	for field in DotBotProfile.fields():
		if not is_equal_approx(fresh.get_field(field), medium.get_field(field)):
			same = false
			print("       a new profile's %s is %s, medium's %s" % [field, fresh.get_field(field), medium.get_field(field)])
	_check(same and fresh.preset_name == "medium", "a new profile is medium, the default")

	var in_range := true
	for row: Array in DotBotProfile.SPEC:
		for col in range(DotBotProfile.COL_FIRST_PRESET, DotBotProfile.COL_FIRST_PRESET + 4):
			if float(row[col]) < float(row[DotBotProfile.COL_MIN]) or float(row[col]) > float(row[DotBotProfile.COL_MAX]):
				in_range = false
				print("       %s column %d out of range" % [row[0], col])
	_check(in_range, "every preset value is inside its setting's range")

	var easy := DotBotProfile.preset("easy")
	var hard := DotBotProfile.preset("hard")
	var nightmare := DotBotProfile.preset("nightmare")
	_check(easy.reaction > medium.reaction and medium.reaction > hard.reaction and hard.reaction > nightmare.reaction,
		"reaction gets quicker preset by preset")
	_check(easy.aim_error > medium.aim_error and medium.aim_error > hard.aim_error and hard.aim_error > nightmare.aim_error,
		"opening aim error shrinks preset by preset")
	_check(easy.turn_rate < medium.turn_rate and medium.turn_rate < hard.turn_rate and hard.turn_rate < nightmare.turn_rate,
		"turn rate rises preset by preset")
	_check(hard.reaction >= 0.18 and hard.reaction <= 0.25, "hard reacts like a good person (0.18 to 0.25 s)", str(hard.reaction))
	_check(nightmare.reaction >= 0.1 and nightmare.aim_floor > 0.0, "nightmare is beyond human, not a machine: reaction and aim floor above zero")
	var walls := true
	for preset in DotBotProfile.PRESETS:
		walls = walls and DotBotProfile.preset(preset).through_walls == 0.0
	_check(walls, "no preset sees through walls")

	_check(DotBotProfile.preset("HARD ").preset_name == "hard", "preset names ignore case and spaces")
	_check(DotBotProfile.preset("brutal") == null, "an unknown preset is null")
	var p := DotBotProfile.preset("medium")
	_check(not p.apply_preset("brutal").ok and p.preset_name == "medium", "applying an unknown preset changes nothing")
	_check(p.set_field("reaction", "0.5").ok and is_equal_approx(p.reaction, 0.5), "a field set from text")
	_check(p.set_field("reaction", "99").ok and is_equal_approx(p.reaction, 3.0), "and clamped to its range")
	_check(not p.set_field("reaction", "fast").ok, "a non-number is refused")
	_check(not p.set_field("wallhack", "1").ok, "an unknown field is refused")
	var c := p.copy()
	c.reaction = 1.0
	_check(not is_equal_approx(p.reaction, 1.0), "a copy shares nothing")
	_check(p.describe_lines().size() == DotBotProfile.fields().size() + 1, "describe_lines lists every setting")
	_done()


func _test_settings() -> void:
	_section("bot_difficulty and overrides")

	var s := DotBotSettings.new()
	_check(s.difficulty() == "medium", "medium by default")
	var rev := s.revision
	_check(s.set_difficulty("hard").ok and is_equal_approx(s.profile.reaction, DotBotProfile.preset_value("hard", "reaction")),
		"hard sets hard's reaction")
	_check(s.revision > rev, "a change bumps the revision")
	_check(not s.set_difficulty("brutal").ok and s.difficulty() == "hard", "an unknown preset is refused and nothing changes")

	var held := s.profile
	_check(s.set_value("reaction", "0.6").ok and is_equal_approx(s.profile.reaction, 0.6), "an override sets one setting")
	_check(s.is_overridden("reaction"), "and is remembered as set by hand")
	_check(s.set_difficulty("easy").ok and is_equal_approx(s.profile.reaction, 0.6), "an override outlives a preset change")
	_check(is_equal_approx(s.profile.aim_error, DotBotProfile.preset_value("easy", "aim_error")), "while everything else follows the preset")
	_check(s.profile == held, "the profile object is never replaced, so a brain may hold it")
	s.reset_overrides()
	_check(is_equal_approx(s.profile.reaction, DotBotProfile.preset_value("easy", "reaction")) and s.overrides.is_empty(),
		"bot_settings_reset puts the preset's value back")

	var node := Node.new()
	var a := DotBotSettings.of(node)
	_check(DotBotSettings.of(node) == a, "of() keeps one per node")
	var other := Node.new()
	_check(DotBotSettings.of(other) != a, "and two nodes (two servers in one process) never share one")
	node.free()
	other.free()
	_check(s.describe_lines()[0] == "bot_difficulty easy", "describe_lines starts with the preset")
	_done()


func _test_cvars() -> void:
	_section("server cvars, both ways")

	var made := {}
	var add := func(n: String, value: String, _help: String, _flags: int) -> Object:
		var c := FakeCvar.new()
		c.name = n
		c.value = value
		made[n] = c
		return c
	var commands := {}
	var add_command := func(n: String, handler: Callable, _help: String) -> void:
		commands[n] = handler

	var s := DotBotSettings.new()
	var list := s.bind_cvars(add, 0, add_command)
	_check(list.size() == DotBotProfile.fields().size() + 1, "bot_difficulty and one cvar per setting", str(list.size()))
	_check(commands.has("bot_settings") and commands.has("bot_settings_reset"), "and the two commands")
	_check((made["bot_difficulty"] as FakeCvar).value == "medium", "bot_difficulty starts at medium")

	var diff := made["bot_difficulty"] as FakeCvar
	var reaction := made["bot_reaction"] as FakeCvar
	_check(diff.set_value("nightmare").ok and s.difficulty() == "nightmare", "setting the cvar chooses the preset")
	_check(reaction.value.to_float() == DotBotProfile.preset_value("nightmare", "reaction"), "and writes every setting's cvar", reaction.value)
	_check(not diff.set_value("brutal").ok and s.difficulty() == "nightmare", "the cvar refuses an unknown preset")
	_check(reaction.set_value("0.45").ok and is_equal_approx(s.profile.reaction, 0.45) and s.is_overridden("reaction"),
		"a setting's cvar overrides it")
	_check(diff.set_value("easy").ok and reaction.value.to_float() == 0.45, "and the override survives the next preset, in the cvar too")
	_check(not s.is_overridden("aim_error"), "a cvar this wrote is not taken for an override")
	_check(reaction.set_value("50").ok and is_equal_approx(s.profile.reaction, 3.0), "the cvar's range clamps")

	# A config that ran before the module registered leaves values waiting.
	var waiting := func(n: String, value: String, _help: String, _flags: int) -> Object:
		var c := FakeCvar.new()
		c.value = "hard" if n == "bot_difficulty" else ("0.45" if n == "bot_reaction" else value)
		return c
	var t := DotBotSettings.new()
	var _l := t.bind_cvars(waiting)
	_check(t.difficulty() == "hard" and is_equal_approx(t.profile.reaction, 0.45) and t.is_overridden("reaction"),
		"values a config set before registering reach the bots")
	_done()


func _test_console() -> void:
	_section("solo console variables")

	var s := DotBotSettings.new()
	var local := FakeLocal.new()
	_check(s.bind_console(local), "binds to anything with add_var")
	_check(local.vars.has("bot_difficulty") and local.vars.size() == DotBotProfile.fields().size() + 1, "every name a server has, in solo")
	_check(local.commands.has("bot_settings") and local.commands.has("bot_settings_reset"), "and the two commands")
	_check(local.get_var("bot_difficulty") == "medium", "reads medium")
	var res: Variant = local.set_var("bot_difficulty", "hard")
	_check(res is DotResult and (res as DotResult).ok and s.difficulty() == "hard", "bot_difficulty hard in solo")
	_check(local.get_var("bot_aim_error") == DotBotProfile._fmt(DotBotProfile.preset_value("hard", "aim_error")), "reads the preset's value back")
	var _r: Variant = local.set_var("bot_aim_error", "7")
	_check(is_equal_approx(s.profile.aim_error, 7.0), "an individual variable overrides")
	var bad: Variant = local.set_var("bot_difficulty", "brutal")
	_check(bad is DotResult and not (bad as DotResult).ok, "and refuses an unknown preset with a reason")
	_check(not s.bind_console(null), "false for nothing to bind to")
	_done()


func _test_names() -> void:
	_section("names from a pool")

	var taken: Array = []
	var unique := true
	for i in range(DotBotNames.POOL.size() + 10):
		var n := DotBotNames.pick(taken, i)
		if taken.has(n):
			unique = false
		taken.append(n)
	_check(unique, "never two bots with one name, past the end of the pool too")
	var plain := true
	for n in taken.slice(0, DotBotNames.POOL.size()):
		var lower := String(n).to_lower()
		if lower.begins_with("bot") or lower.contains("stand-in") or String(n).is_valid_int():
			plain = false
	_check(plain, "no Bot N, no Stand-in N")
	_check(DotBotNames.pick([], 7) == DotBotNames.pick([], 7), "the same salt gives the same name")
	_check(DotBotNames.pick([], 7, [], "[BOT] ").begins_with("[BOT] "), "a prefix when a game wants one")
	_check(DotBotNames.pick(["Ann"], 3, ["Ann", "Bea"]) == "Bea", "a game's own pool")
	_done()


func _test_personas() -> void:
	_section("personas: a mix that never idles, a weighted pool, a server override")

	var medic := DotBotPersona.from_values("medic", {"support": 8.0, "hunt": 1.0, "loot": 0.0, "hold": 0.0, "scout": 0.0, "weight": 3.0})
	var seen := {}
	for i in 200:
		seen[medic.pick(float(i) / 200.0)] = true
	_check(seen.has(DotBotPersona.SUPPORT) and seen.has(DotBotPersona.HUNT), "a mix picks from its weighted behaviours")
	_check(not seen.has(DotBotPersona.LOOT) and not seen.has(&"idle") and not seen.has(&""), "a zero weight is never picked, and idle is not a behaviour")
	var zero := DotBotPersona.from_values("zero", {"hunt": 0.0, "loot": 0.0, "hold": 0.0, "support": 0.0, "scout": 0.0})
	var any := {}
	for i in 100:
		any[zero.pick(float(i) / 100.0)] = true
	_check(any.size() == DotBotPersona.BEHAVIOURS.size(), "an all-zero mix counts every behaviour equal rather than idling")
	var repeats := 0
	for i in 100:
		if medic.pick(float(i) / 100.0, DotBotPersona.SUPPORT) == DotBotPersona.SUPPORT:
			repeats += 1
	_check(repeats == 0, "the last behaviour is not repeated while another has weight")
	var only := DotBotPersona.from_values("only", {"hunt": 5.0, "loot": 0.0, "hold": 0.0, "support": 0.0, "scout": 0.0})
	_check(only.pick(0.5, DotBotPersona.HUNT) == DotBotPersona.HUNT, "a one-behaviour mix repeats rather than idles")

	var pool := DotBotPersonaPool.new()
	_check(pool.draw(0.3).id == &"balanced" and pool.candidates().size() == 1, "an empty pool still holds one balanced persona")
	pool.personas = [medic, DotBotPersona.from_values("scout", {"weight": 1.0}), DotBotPersona.from_values("off", {"weight": 0.0})]
	var counts := {}
	for i in 400:
		var p := pool.draw((float(i) + 0.5) / 400.0)
		counts[p.id] = int(counts.get(p.id, 0)) + 1
	_check(counts.get(&"medic", 0) == 300 and counts.get(&"scout", 0) == 100 and not counts.has(&"off"), "weights 3:1 give 300:100 and a zero weight never")
	pool.set_override("scout:1, bogus:x ,medic:0")
	_check(pool.override == {&"scout": 1.0, &"bogus": 1.0, &"medic": 0.0}, "an override parses (a bare or bad weight is 1)")
	var forced := {}
	for i in 50:
		forced[pool.draw(float(i) / 50.0).id] = true
	_check(forced.keys() == [&"scout"], "an override replaces the weights and drops what it does not name")
	pool.set_override("")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var first := pool.assign(&"b1", rng)
	_check(pool.assign(&"b1", rng) == first, "a bot keeps its persona")
	var varied := {}
	for i in 24:
		varied[pool.assign(StringName("x%d" % i), rng).id] = true
	_check(varied.size() >= 2, "bots drawn from the pool differ")
	pool.release(&"b1")
	_check(not pool.describe()["given"].has("b1"), "released")

	var base := DotBotProfile.preset("medium")
	_check(DotBotPersona.from_values("p", {}).profile_over(base) == null, "no skill stated shares the game's settings")
	var sharp := DotBotPersona.from_values("sharp", {"difficulty": "hard", "skill": {"reaction": 0.5}}).profile_over(base)
	_check(sharp != null and sharp.preset_name == "hard" and is_equal_approx(sharp.reaction, 0.5) and is_equal_approx(sharp.fov, 120.0), "a persona's difficulty and skill values")
	var schema_names: Array = []
	for f: Dictionary in DotBotPersona.schema():
		schema_names.append(f["name"])
	_check(schema_names.has("hunt") and schema_names.has("support") and schema_names.has("weight") and schema_names.has("skill"), "the profile schema names the mix, weight and skill")
	_done()


func _test_roster() -> void:
	_section("the roster keeps a count")

	var roster := DotBotRoster.new()
	var made: Array = []
	var removed: Array = []
	var next_id := [100]
	var add := func(n: String) -> int:
		next_id[0] += 1
		made.append(n)
		return next_id[0]
	var remove := func(id: int) -> void:
		removed.append(id)

	var ids := roster.keep(3, [], add, remove, ["Player"])
	_check(ids.size() == 3 and made.size() == 3, "three bots added", str(ids))
	_check(not made.has("Player"), "never a person's name")
	ids = roster.keep(1, ids, add, remove)
	_check(ids == [101] and removed == [103, 102], "newest out first", "%s %s" % [ids, removed])
	var refuse := func(_n: String) -> int: return 0
	_check(roster.keep(4, ids, refuse, remove).size() == 1, "a refusal stops adding")
	_check(DotBotRoster.solo_wanted(4) == 3 and DotBotRoster.solo_wanted(0) == 0, "solo fill: bot_quota 4 is three bots and you")
	_done()


func _test_intent() -> void:
	_section("an intent is the commands a client sends")

	var i := DotBotIntent.new()
	i.yaw = 30.0
	i.pitch = -5.0
	i.move = Vector2(2.0, 0.0)
	i.fire = true
	i.crouch = true
	i.throw = true
	var m := FakeMove.new()
	var f := FakeFire.new()
	i.write_move(m)
	i.write_fire(f, "BUTTON_USER_0")
	_check(m.yaw == 30.0 and m.pitch == -5.0 and f.yaw == 30.0, "the view in both commands")
	_check(is_equal_approx(m.move.length(), 1.0), "movement never longer than a stick")
	_check(m.buttons == FakeMove.BUTTON_CROUCH, "crouch from the command's own constant", str(m.buttons))
	_check(f.buttons == (FakeFire.BUTTON_ATTACK | FakeFire.BUTTON_USER_0), "trigger and the game's throw button", str(f.buttons))
	_check(DotBotIntent.direction(0.0, 0.0).is_equal_approx(Vector3(0, 0, -1)), "yaw 0 looks down -Z")
	_check(DotBotIntent.direction(90.0, 0.0).is_equal_approx(Vector3(-1, 0, 0)), "yaw 90 looks down -X")
	_done()


func _test_fire_mode() -> void:
	_section("DotBotFireMode picks by range")
	var f := DotBotFireMode.new()
	var all := PackedStringArray(["auto", "semi", "burst"])
	_check(f.pick(5.0, all) == "auto" and f.pick(20.0, all) == "burst" and f.pick(50.0, all) == "semi", "auto close, burst mid, semi far")
	_check(f.pick(50.0, PackedStringArray(["auto", "burst"])) == "burst" and f.pick(5.0, PackedStringArray(["auto"])) == "", "falls to what the gun has; one mode picks nothing")
	f.rule = func(_d: float, _m: PackedStringArray) -> String: return "semi"
	_check(f.pick(1.0, all) == "semi", "a rule overrides")
	_done()
