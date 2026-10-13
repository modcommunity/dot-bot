extends Node

## dot-bot's suite: the presets, the cvars, the names, the roster, and a bot's senses, aim and
## fighting measured rather than read.
##
## [codeblock]
## godot --headless --path . res://examples/bot_selftest.tscn
## [/codeblock]
##
## [b]The numbers a player feels are measured here, per preset:[/b] how long a bot takes from
## first seeing somebody to its first shot, how far off its first shot is, what its aim settles
## to, how fast its view turns, and its kill/death ratio against one scripted opponent that
## never changes. The bands are what "easy", "medium", "hard" and "nightmare" promise; a
## change to the brain that moves a preset out of its band fails here before a player says the
## bots are too hard.

const CHECKS := 152

## Sections entered against sections that ran to their last line. A runtime error inside a
## section aborts that function and nothing says so.
const SECTIONS := 18

const TICK := 1.0 / 64.0

## K/D against the scripted opponent ([method _duel]), per preset: [low, high].
##
## Medium is the default and sits a little under an ordinary player; hard is a good player,
## who wins most fights against an ordinary one; nightmare wins nearly all of them.
const KD_BANDS := {
	"easy": [0.0, 0.35],
	"medium": [0.35, 1.5],
	"hard": [2.0, 30.0],
	"nightmare": [8.0, 1000.0],
}

## Rounds per preset in the duel.
const DUELS := 100

## The scripted opponent of [method _duel]: reaction, opening aim error, its floor, and the
## seconds the error takes to halve.
var OPP_REACTION := 0.35
var OPP_ERROR := 4.0
var OPP_FLOOR := 1.5
var OPP_SETTLE := 0.7

## The last duel's engagement, for a probe.
var last_engagement := {}

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


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


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-bot self-test")
	print("")

	_test_profile()
	_test_settings()
	_test_cvars()
	_test_console()
	_test_names()
	_test_roster()
	_test_intent()
	_test_aim()
	_test_senses()
	_test_turning()
	_test_reaction_and_aim()
	_test_duels()
	_test_hiding()
	_test_search()
	_test_route()
	await _test_nav()
	_test_surf()
	await _test_ride_edges()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	print("%d of %d sections ran to their last line" % [_completed, _entered])

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- Hiding, searching, walking ------------------------------------------------

## A wall from (0, 0, -5) to (0, 0, 5), two metres high: what [method _wall_los] answers.
static func _wall_los(a: Vector3, b: Vector3) -> bool:
	if signf(a.x) == signf(b.x) or a.x == 0.0 or b.x == 0.0:
		return true
	var f := a.x / (a.x - b.x)
	var hit := a.lerp(b, f)
	return hit.y > 2.0 or absf(hit.z) > 5.0


func _test_hiding() -> void:
	_section("hiding: out of sight lines, apart, and away")
	# Watchers all on the west of the wall; one spot behind it, one in front.
	var watchers := PackedVector3Array()
	for i in range(10):
		watchers.append(Vector3(-6.0, 1.6, -4.0 + i))
	var spots := DotBotHiding.survey(PackedVector3Array([Vector3(2.0, 0.0, 0.0), Vector3(-2.0, 0.0, 0.0), Vector3(2.0, 0.0, 12.0)]), watchers, _wall_los)
	_check(is_zero_approx(float(spots[0]["exposure"])) and is_equal_approx(float(spots[1]["exposure"]), 1.0),
		"a spot behind the wall is hidden from every watcher, one in front from all", "%s" % [spots.map(func(s: Dictionary) -> float: return s["exposure"])])
	_check(float(spots[2]["exposure"]) > 0.5, "and one past the wall's end is seen round it")
	var stream := DotRandomStream.new(7)
	var best := DotBotHiding.choose(spots, Vector3.ZERO, PackedVector3Array([Vector3(-8.0, 0.0, 0.0)]), PackedVector3Array(), stream, 1.0)
	_check((best["at"] as Vector3).is_equal_approx(Vector3(2.0, 0.0, 0.0)), "a skilled hider picks the hidden one")
	var apart := DotBotHiding.choose(spots, Vector3.ZERO, PackedVector3Array(), PackedVector3Array([Vector3(2.0, 0.0, 0.5)]), stream, 1.0)
	_check(not (apart["at"] as Vector3).is_equal_approx(Vector3(2.0, 0.0, 0.0)), "but not the one beside a spot another hider took")
	var none := DotBotHiding.choose(spots, Vector3.ZERO, PackedVector3Array(), PackedVector3Array(), stream, 1.0, func(_at: Vector3) -> bool: return false)
	_check(none.is_empty(), "and nothing when nothing is reachable")
	var away := DotBotHiding.flee_spot(spots, Vector3(0.5, 0.0, -2.5), Vector3(-3.0, 0.0, -3.0), Vector3(-3.0, 1.6, -3.0), _wall_los, PackedVector3Array(), 25.0, 2.0)
	_check(not away.is_empty() and (away["at"] as Vector3).x > 0.0, "running from a seeker goes behind the wall, not past it")
	_done()


func _test_search() -> void:
	_section("searching: likely places first, crossed off once seen, a sound brings them back")
	var search := DotBotSearch.new()
	search.setup([{"at": Vector3(0.0, 0.0, -8.0), "exposure": 0.0}, {"at": Vector3(0.0, 0.0, 8.0), "exposure": 1.0}], 0.5)
	var stream := DotRandomStream.new(3)
	var first := search.next(Vector3.ZERO, 0.0, PackedVector3Array(), stream)
	_check((first["at"] as Vector3).z < 0.0, "with map knowledge the hidden place is first")
	var claimed := search.next(Vector3.ZERO, 0.0, PackedVector3Array([Vector3(0.0, 0.0, -8.0)]), stream)
	_check((claimed["at"] as Vector3).z > 0.0, "and another seeker's place is left to them")
	var seen := search.observe(Vector3(0.0, 1.6, 0.0), Vector3(0.0, 0.0, -1.0), 110.0, 50.0, func(_a: Vector3, _b: Vector3) -> bool: return true, 1.0)
	_check(seen == 1 and search.unlooked(1.0) == 1, "looking at it crosses it off, and only what is in the cone")
	search.heard(Vector3(0.0, 0.0, -7.0), 2.0)
	_check(search.unlooked(2.0) == 2, "a sound near it puts it back")
	_done()


## A roaming bot with one place to go, walked at 4 m/s for [param seconds]: where it went.
func _walk_roam(world: DotBotWorld, seconds: float) -> PackedVector3Array:
	var me := DotBotContact.make(1, Vector3.ZERO)
	world.contacts_fn = func() -> Array: return [me]
	var brain := DotBotBrain.new(5)
	var trail := PackedVector3Array()
	var t := 0.0
	while t < seconds:
		var intent := brain.think(me, world, t)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		var y := deg_to_rad(intent.yaw)
		var forward := Vector3(-sin(y), 0.0, -cos(y))
		var right := Vector3(cos(y), 0.0, -sin(y))
		me.position += (right * intent.move.x + forward * intent.move.y) * 4.0 * TICK
		trail.append(me.position)
		t += TICK
	return trail


func _test_route() -> void:
	_section("roaming: a route from the world is walked corner by corner")
	var goal := Vector3(10.0, 0.0, 0.0)
	var straight := DotBotWorld.new()
	straight.waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([goal])
	var plain := _walk_roam(straight, 1.5)
	var off_line := 0.0
	for at in plain:
		off_line = maxf(off_line, absf(at.z))
	_check(plain[plain.size() - 1].x > 4.0 and off_line < 1.0, "with no route it walks straight at the waypoint", "x %.1f, %.1f m off the line" % [plain[plain.size() - 1].x, off_line])

	var asked := [0]
	var routed := DotBotWorld.new()
	routed.waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([goal])
	# Round the end of a wall standing between the bot and the waypoint.
	routed.route_fn = func(_from: Vector3, to: Vector3) -> PackedVector3Array:
		asked[0] += 1
		return PackedVector3Array([Vector3(0.0, 0.0, 6.0), Vector3(8.0, 0.0, 6.0), to])
	var trail := _walk_roam(routed, 7.0)
	var rounded := false
	var arrived := false
	for at in trail:
		rounded = rounded or (at.z > 5.0 and at.x < 1.5)
		arrived = arrived or (rounded and at.distance_to(goal) < 2.5)
	_check(rounded, "with a route it goes to the first corner first, not at the waypoint")
	_check(arrived and asked[0] == 1, "and on to the waypoint, asking for the route once", "asked %d" % asked[0])
	_done()


func _test_nav() -> void:
	_section("walking: a mesh baked from colliders, a path round a wall")
	var root := Node3D.new()
	add_child(root)
	var still := StaticBody3D.new()
	root.add_child(still)
	for part: Array in [[Vector3(30.0, 0.2, 30.0), Vector3(0.0, -0.1, 0.0)], [Vector3(0.4, 3.0, 20.0), Vector3(0.0, 1.5, -4.0)]]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = part[0]
		shape.shape = box
		shape.position = part[1]
		still.add_child(shape)
	# A "door" body across the gap: not passed in, so not baked.
	var door := StaticBody3D.new()
	root.add_child(door)
	var panel := CollisionShape3D.new()
	var slab := BoxShape3D.new()
	slab.size = Vector3(0.4, 3.0, 8.0)
	panel.shape = slab
	panel.position = Vector3(0.0, 1.5, 10.0)
	door.add_child(panel)
	await get_tree().physics_frame
	var nav := DotBotNav.new()
	var baked := nav.bake(root, {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [still])
	_check(baked.ok and nav.is_ready(), "it bakes and is ready on the same tick", str(baked.error.message if not baked.ok else ""))
	var length := nav.path_length(Vector3(-5.0, 0.0, -10.0), Vector3(5.0, 0.0, -10.0))
	_check(length > 12.0 and length < INF, "the path goes round the wall's end, not through it (10 m straight)", "%.1f m" % length)
	var through := nav.path_length(Vector3(-5.0, 0.0, 10.0), Vector3(5.0, 0.0, 10.0))
	_check(through < 12.0, "and through the doorway whose door was left out of the bake", "%.1f m" % through)
	var a := nav.random_point(DotRandomStream.new(9))
	var b := nav.random_point(DotRandomStream.new(9))
	_check(a.is_equal_approx(b) and absf(a.y) < 0.5, "a random point is on the floor, the same for the same seed")
	var polygons := nav.mesh.get_polygon_count()
	nav.clear()

	# In the background: nothing until it lands, then the same mesh, on the main thread.
	var landed: Array = []
	var started := nav.bake_in_background(root, {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [still],
		func(res: DotResult) -> void: landed.append([res.ok, OS.get_thread_caller_id() == OS.get_main_thread_id()]))
	var waiting := nav.is_baking() and nav.path(Vector3(-5.0, 0.0, -10.0), Vector3(5.0, 0.0, -10.0)).is_empty()
	_check(started.ok and (waiting or not DotPlatform.has_threads()), "a background bake starts, and answers no path before it lands")
	var frames := 0
	while landed.is_empty() and frames < 600:
		await get_tree().process_frame
		frames += 1
	_check(landed.size() == 1 and landed[0][0] and landed[0][1] and not nav.is_baking(),
		"it lands once, on the main thread", "%s after %d frames" % [str(landed), frames])
	var round_length := nav.path_length(Vector3(-5.0, 0.0, -10.0), Vector3(5.0, 0.0, -10.0))
	_check(nav.mesh.get_polygon_count() == polygons and round_length > 12.0 and round_length < INF,
		"the same mesh, and the same way round the wall", "%d polygons, %.1f m" % [nav.mesh.get_polygon_count(), round_length])

	# A bake cleared before it lands is dropped, never taken in over what replaced it.
	var stale: Array = []
	var _again := nav.bake_in_background(root, {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [still],
		func(res: DotResult) -> void: stale.append(res.ok))
	nav.clear()
	for i in 60:
		await get_tree().process_frame
	_check(stale.is_empty() and not nav.is_baked() and not nav.is_baking(), "a bake cleared before it lands is dropped", str(stale))
	root.queue_free()
	_done()


# --- Profile ---------------------------------------------------------------------

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


# --- Settings ---------------------------------------------------------------------

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


# --- Names and the roster -------------------------------------------------------------

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


# --- Aim alone ---------------------------------------------------------------------

## DotBotAim on its own, the way a game with its own decisions uses it.
func _test_aim() -> void:
	_section("DotBotAim on its own")

	var s := DotBotSettings.new()
	var aim := DotBotAim.new(5, s)
	var eye := Vector3(0, 1.6, 0)
	var chest := Vector3(0, 1.25, -12)
	_check(aim.engage(9, eye, chest, 0.0), "a first sight starts an engagement")
	_check(not aim.engage(9, eye, chest, 0.05), "seeing it again next tick continues it")
	_check(not aim.engage(9, eye, chest, 0.05 + 0.2), "and at 5 ticks a second too (no new reaction every tick)")
	var react := aim.react_at
	var t := 0.25
	var fired_early := false
	var first := NAN
	while t < 3.0:
		var _seen := aim.engage(9, eye, chest, t)
		var _v := aim.track(eye, chest, Vector3.ZERO, t, 1.0 / 64.0)
		var down := aim.trigger(t, 12.0)
		if down and t < react:
			fired_early = true
		if down and is_nan(first):
			first = t
		t += 1.0 / 64.0
	_check(not fired_early and not is_nan(first), "never fires before its reaction, then does", "%.3f vs %.3f" % [first, react])

	aim.release()
	_check(not aim.engage(9, eye, chest, 3.5) and aim.react_at - 3.5 <= s.profile.reaction * 0.6,
		"back in sight within 1.5 s: the same engagement, half the reaction", "%.3f" % (aim.react_at - 3.5))
	_check(aim.engage(9, eye, chest, 9.0), "back after its memory: a new engagement")

	# Bursts beyond burst_range: the trigger comes and goes.
	var far := Vector3(0, 1.25, -30)
	var _e := aim.engage(10, eye, far, 20.0)
	var changes := 0
	var was := false
	t = 20.0
	while t < 24.0:
		var _v := aim.track(eye, far, Vector3.ZERO, t, 1.0 / 64.0)
		var down := aim.trigger(t, 30.0)
		if down != was:
			changes += 1
		was = down
		t += 1.0 / 64.0
	_check(changes >= 6, "beyond burst_range it fires in bursts", "%d changes" % changes)

	var settled := aim.error_deg(24.0)
	aim.hurt()
	_check(aim.error_deg(24.0) > settled + s.profile.flinch * 0.9, "a hit adds bot_flinch to the aim error")
	_done()


# --- Senses -------------------------------------------------------------------------

## A bot at the origin facing -Z, and one enemy.
func _scene(enemy_at: Vector3, wall: bool = false) -> Array:
	var me := DotBotContact.make(1, Vector3.ZERO)
	var enemy := DotBotContact.make(2, enemy_at)
	var world := DotBotWorld.new()
	world.contacts_fn = func() -> Array: return [me, enemy]
	world.line_of_sight_fn = func(_a: Vector3, _b: Vector3) -> bool: return not wall
	return [me, enemy, world]


func _run_bot(brain: DotBotBrain, me: DotBotContact, world: DotBotWorld, seconds: float, start: float = 0.0) -> Array:
	var out: Array = []
	var t := start
	while t < start + seconds:
		var intent := brain.think(me, world, t)
		out.append(intent)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		t += TICK
	return out


func _test_senses() -> void:
	_section("senses: no walls, a view cone, hearing")

	var s := DotBotSettings.new()
	s.set_difficulty("nightmare")

	var sc := _scene(Vector3(0, 0, -15), true)
	var brain := DotBotBrain.new(1, s)
	var intents := _run_bot(brain, sc[0], sc[2], 3.0)
	_check(intents.all(func(i: DotBotIntent) -> bool: return not i.fire and i.target_id == -1),
		"a nightmare bot never targets or fires at somebody behind a wall in front of it")

	sc = _scene(Vector3(0, 0, 15))
	brain = DotBotBrain.new(1, s)
	intents = _run_bot(brain, sc[0], sc[2], 0.5)
	_check((intents[0] as DotBotIntent).target_id == -1, "somebody directly behind, in the open, is not seen on the first tick")

	sc = _scene(Vector3(0, 0, 15))
	var world: DotBotWorld = sc[2]
	brain = DotBotBrain.new(1, s)
	var _first := brain.think(sc[0], world, 0.0)
	world.emit_sound(Vector3(0, 0, 15), 1.0, 2, 0.01)
	intents = _run_bot(brain, sc[0], world, 2.0, TICK)
	var turned := intents.any(func(i: DotBotIntent) -> bool: return i.target_id == 2)
	_check(turned, "a gunshot behind turns it round, and then it sees who fired")

	# Made on the same timestamp as the bot's last think: a time comparison missed this one, and
	# a bot with its back to the shooter died without turning (the duel below found it).
	sc = _scene(Vector3(0, 0, 15))
	world = sc[2]
	brain = DotBotBrain.new(1, s)
	_first = brain.think(sc[0], world, 0.5)
	world.emit_sound(Vector3(0, 0, 15), 1.0, 2, 0.5)
	_check(brain.think(sc[0], world, 0.5 + TICK).state == &"listen", "a sound made on the tick the bot last thought is still heard")

	sc = _scene(Vector3(0, 0, 100))
	world = sc[2]
	brain = DotBotBrain.new(1, s)
	_first = brain.think(sc[0], world, 0.0)
	world.emit_sound(Vector3(0, 0, 100), 1.0, 2, 0.01)
	intents = _run_bot(brain, sc[0], world, 0.5, TICK)
	_check(intents.all(func(i: DotBotIntent) -> bool: return i.state == &"roam"), "a gunshot past its hearing is not heard")

	sc = _scene(Vector3(0, 0, -15))
	brain = DotBotBrain.new(1, s)
	var a := _run_bot(brain, sc[0], sc[2], 1.0)
	sc = _scene(Vector3(0, 0, -15))
	var b := _run_bot(DotBotBrain.new(1, s), sc[0], sc[2], 1.0)
	var same := true
	for k in range(a.size()):
		same = same and (a[k] as DotBotIntent).yaw == (b[k] as DotBotIntent).yaw and (a[k] as DotBotIntent).fire == (b[k] as DotBotIntent).fire
	_check(same, "the same id and inputs play the same bot")

	# Killed in plain view: the bot moves on rather than pre-aiming the body.
	sc = _scene(Vector3(0, 0, -10))
	brain = DotBotBrain.new(1, s)
	intents = _run_bot(brain, sc[0], sc[2], 1.0)
	(sc[1] as DotBotContact).alive = false
	intents = _run_bot(brain, sc[0], sc[2], 0.2, 1.0)
	_check((intents.back() as DotBotIntent).state == &"roam", "a target killed in view is not searched for", str((intents.back() as DotBotIntent).state))

	var hurt := _scene(Vector3(0, 0, 40), true)
	brain = DotBotBrain.new(1, s)
	_first = brain.think(hurt[0], hurt[2], 0.0)
	brain.hurt(Vector3(0, 0, 40), 0.0)
	intents = _run_bot(brain, hurt[0], hurt[2], 1.0, TICK)
	_check((intents.back() as DotBotIntent).state == &"listen" and absf(wrapf((intents.back() as DotBotIntent).yaw - 180.0, -180.0, 180.0)) < 10.0,
		"being shot from behind turns it toward the shooter without seeing them")
	_done()


func _test_turning() -> void:
	_section("the view turns no faster than bot_turn_rate")

	for preset in DotBotProfile.PRESETS:
		var s := DotBotSettings.new()
		s.set_difficulty(preset)
		var sc := _scene(Vector3(1.5, 0, 1.0))
		var brain := DotBotBrain.new(1, s)
		var intents := _run_bot(brain, sc[0], sc[2], 1.5)
		var fastest := 0.0
		for k in range(1, intents.size()):
			var step := absf(wrapf((intents[k] as DotBotIntent).yaw - (intents[k - 1] as DotBotIntent).yaw, -180.0, 180.0))
			fastest = maxf(fastest, step / TICK)
		print("       %-9s fastest turn %4.0f deg/s (limit %4.0f)" % [preset, fastest, s.profile.turn_rate])
		_check(fastest <= s.profile.turn_rate * 1.01, "%s turns at most %d deg/s" % [preset, int(s.profile.turn_rate)], str(fastest))
	_done()


## The first-shot numbers, per preset, over many engagements: a stationary target appears
## 15 m away somewhere inside the view cone.
func _test_reaction_and_aim() -> void:
	_section("reaction time and aim error, measured")

	var previous_reaction := INF
	for preset in DotBotProfile.PRESETS:
		var s := DotBotSettings.new()
		s.set_difficulty(preset)
		var p := s.profile
		var reactions: Array[float] = []
		var first_errors: Array[float] = []
		var settled: Array[float] = []
		for trial in range(40):
			var off := deg_to_rad(-30.0 + 60.0 * float(trial) / 39.0)
			var at := Vector3(-sin(off), 0.0, -cos(off)) * 15.0
			var sc := _scene(at)
			var brain := DotBotBrain.new(1000 + trial, s)
			var intents := _run_bot(brain, sc[0], sc[2], 2.5)
			var e := brain.engagement()
			if not is_nan(float(e["first_shot_at"])):
				reactions.append(float(e["first_shot_at"]) - float(e["seen_at"]))
				first_errors.append(float(e["first_shot_error_deg"]))
			var me: DotBotContact = sc[0]
			var last := intents.back() as DotBotIntent
			settled.append(rad_to_deg(last.forward().angle_to((sc[1] as DotBotContact).aim_point() - me.eye())))
		var r := _mean(reactions)
		var fe := _mean(first_errors)
		var se := _mean(settled)
		print("       %-9s reaction %.3f s (setting %.2f), first-shot error %.2f deg, after 2.5 s %.2f deg (floor %.2f), %d/40 fired" % [
			preset, r, p.reaction, fe, se, p.aim_floor, reactions.size()])
		_check(reactions.size() == 40, "%s fires in every engagement" % preset, str(reactions.size()))
		_check(r >= p.reaction * 0.85 and r <= p.reaction + p.notice * 0.4 + 0.25, "%s reacts in about its bot_reaction" % preset, "%.3f" % r)
		_check(r < previous_reaction, "%s reacts faster than the preset before it" % preset)
		_check(fe <= p.aim_error * 1.25 + p.fire_cone, "%s opens no worse than its aim error allows" % preset, "%.2f" % fe)
		_check(se <= p.aim_floor * 1.1 + 0.3, "%s settles to its aim floor" % preset, "%.2f" % se)
		previous_reaction = r
	_done()


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


# --- Duels ----------------------------------------------------------------------------

## Kill/death ratio per preset against one scripted opponent, in a world of rays and no
## walls: both fire 10 rounds a second, five hits kill, a hit is a ray passing within
## 0.3 m of the chest.
##
## [b]The opponent is fixed, so the number moves only with the bot.[/b] It is an ordinary
## player: reacts in 0.35 s, aims 4 degrees off (a steady, drifting offset, not a fresh
## miss each round) and settles to 1.5, fires half-second
## bursts, strafes at 4 m/s
## changing direction every 0.7 s.
func _test_duels() -> void:
	_section("kill/death against a scripted opponent")

	var previous := -1.0
	for preset in DotBotProfile.PRESETS:
		var s := DotBotSettings.new()
		s.set_difficulty(preset)
		var kills := 0
		var deaths := 0
		for round_ in range(DUELS):
			var outcome := _duel(s, round_)
			if outcome > 0:
				kills += 1
			elif outcome < 0:
				deaths += 1
		var kd := float(kills) / float(maxi(deaths, 1))
		var band: Array = KD_BANDS[preset]
		print("       %-9s %2d kills, %2d deaths, K/D %.2f (band %.1f..%.1f)" % [preset, kills, deaths, kd, band[0], band[1]])
		_check(kd >= float(band[0]) and kd <= float(band[1]), "%s K/D inside its band" % preset, "%.2f" % kd)
		_check(kd > previous, "%s beats the preset before it" % preset)
		previous = kd
	_done()


## One round: +1 the bot won, -1 it lost, 0 nobody died in ten seconds.
func _duel(s: DotBotSettings, round_: int) -> int:
	var rng := DotRandomStream.new(round_).stream(&"duel")
	# Who has the drop varies, as it does in a match: the bot may face the opponent or have
	# its back to them (and then only hears the first shots), and the opponent's own reaction
	# varies from round to round around OPP_REACTION.
	var distance := rng.next_range_f(6.0, 35.0)
	var off := deg_to_rad(rng.next_range_f(-150.0, 150.0))
	# The opponent faces somewhere too: up to 150 degrees off the bot, which costs it a turn
	# (a person flicks round at about 600 degrees a second) before its reaction counts.
	var their_off := absf(rng.next_range_f(-150.0, 150.0))
	var their_reaction := OPP_REACTION * rng.next_range_f(0.7, 1.5) + their_off / 600.0
	var me := DotBotContact.make(1, Vector3.ZERO)
	var them := DotBotContact.make(2, Vector3(-sin(off), 0.0, -cos(off)) * distance)
	var world := DotBotWorld.new()
	world.contacts_fn = func() -> Array: return [me, them]
	var brain := DotBotBrain.new(round_ * 7 + 3, s)

	var my_hp := 5
	var their_hp := 5
	var my_cooldown := 0.0
	var their_cooldown := 0.0
	var my_bloom := 0.0
	var their_bloom := 0.0
	var their_seen_at := 0.0
	var strafe_dir := 1.0
	var t := 0.0
	while t < 10.0:
		var intent := brain.think(me, world, t)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch

		# The bot's move, at 5 m/s.
		var yr := deg_to_rad(intent.yaw)
		var fwd := Vector3(-sin(yr), 0.0, -cos(yr))
		var right := Vector3(cos(yr), 0.0, -sin(yr))
		me.velocity = (right * intent.move.x + fwd * intent.move.y) * 5.0 * (0.5 if intent.crouch else 1.0)
		me.position += me.velocity * TICK

		# The opponent strafes across the bot.
		if fmod(t, 0.7) < TICK:
			strafe_dir = -strafe_dir
		var to_me := (me.position - them.position)
		var across := Vector3(-to_me.z, 0.0, to_me.x).normalized()
		them.velocity = across * 4.0 * strafe_dir
		them.position += them.velocity * TICK

		# Both shoot. Sustained fire blooms half a degree a round up to four, and recovers at
		# eight a second, so a burst is worth something here as it is in a real weapon.
		my_cooldown -= TICK
		their_cooldown -= TICK
		my_bloom = maxf(my_bloom - 8.0 * TICK, 0.0)
		their_bloom = maxf(their_bloom - 8.0 * TICK, 0.0)
		if intent.fire and my_cooldown <= 0.0:
			my_cooldown = 0.1
			var spread := (0.6 if me.velocity.length() > 1.0 else 0.0) + my_bloom
			my_bloom = minf(my_bloom + 0.5, 4.0)
			if _hits(me.eye(), _wobble(intent.forward(), spread, rng), them.aim_point()):
				their_hp -= 1
		var age := t - their_seen_at - their_reaction + OPP_REACTION
		# The opponent fires half-second bursts with a third of a second between.
		var bursting := fmod(age - OPP_REACTION, 0.8) < 0.5
		if age >= OPP_REACTION and bursting and their_cooldown <= 0.0:
			their_cooldown = 0.1
			var err := OPP_FLOOR + (OPP_ERROR - OPP_FLOOR) * pow(0.5, age / OPP_SETTLE)
			var dir := (me.aim_point() - them.eye()).normalized()
			var aim := _offset(dir, err * (0.55 + 0.45 * sin(t * 2.1)), t * 1.3 + float(round_))
			world.emit_sound(them.eye(), 1.0, them.id, t)
			if _hits(them.eye(), _wobble(aim, 0.6 + their_bloom, rng), me.aim_point()):
				my_hp -= 1
			their_bloom = minf(their_bloom + 0.5, 4.0)
		if their_hp <= 0 or my_hp <= 0:
			last_engagement = brain.engagement()
			last_engagement["t"] = t
			last_engagement["dist"] = snappedf(distance, 0.1)
			last_engagement["off"] = snappedf(rad_to_deg(off), 1)
			last_engagement["hp"] = [my_hp, their_hp]
			return 1 if their_hp <= 0 else -1
		t += TICK
	return 0


## [param dir] turned [param degrees] off itself, toward [param angle] around it: an aim
## that is off by a steady, drifting amount, the way a person's is.
func _offset(dir: Vector3, degrees: float, angle: float) -> Vector3:
	var right := dir.cross(Vector3.UP).normalized()
	var up := right.cross(dir).normalized()
	var axis := (right * cos(angle) + up * sin(angle)).normalized()
	return dir.rotated(axis, deg_to_rad(degrees))


func _wobble(dir: Vector3, degrees: float, rng: DotRandomStream) -> Vector3:
	if degrees <= 0.0:
		return dir
	return rng.next_cone(dir, degrees)


func _hits(from: Vector3, dir: Vector3, chest: Vector3) -> bool:
	var to := chest - from
	var along := to.dot(dir)
	if along <= 0.0:
		return false
	return (to - dir * along).length() <= 0.3


# --- Harness --------------------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)



# --- Surfing ------------------------------------------------------------------------

## A body for the surf section: the shape of dot-player-controller's state, and a motor that is
## not one (a point that accelerates along the wish up to a speed), so the planner and the pilot
## are tested here without the addon they reach by duck typing. The real motor is game-g2gfast's
## and game-arena's suites.
class ToyState:
	extends RefCounted
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	func duplicate_state() -> ToyState:
		var s := ToyState.new()
		s.position = position
		s.velocity = velocity
		return s
	func is_grounded() -> bool:
		return false


class ToyCommand:
	extends RefCounted
	var yaw := 0.0
	var move := Vector2.ZERO
	var jump := false


class ToySim:
	extends RefCounted
	var delta := 1.0 / 64.0
	var course: DotBotSurfCourse = null
	var steps := 0
	func command(yaw: float, move: Vector2, jump: bool) -> ToyCommand:
		var c := ToyCommand.new()
		c.yaw = yaw
		c.move = move
		c.jump = jump
		return c
	func step(s: ToyState, c: ToyCommand) -> int:
		steps += 1
		var y := deg_to_rad(c.yaw)
		var wish := Vector3(cos(y), 0.0, -sin(y)) * c.move.x + Vector3(-sin(y), 0.0, -cos(y)) * c.move.y
		s.velocity = (s.velocity + wish * 6.0 * delta).limit_length(6.0)
		s.position += s.velocity * delta
		return course.event_at(s) if course != null else 0


## A corridor along -z that turns right at its end: straight on is a pit, the goal is round the
## corner.
func _toy_course() -> DotBotSurfCourse:
	var course := DotBotSurfCourse.new()
	course.start = Vector3.ZERO
	course.goals.append(AABB(Vector3(4.0, -1.0, -24.0), Vector3(6.0, 2.0, 6.0)))
	course.pits.append(AABB(Vector3(-50.0, -1.0, -50.0), Vector3(48.0, 2.0, 100.0)))  # x < -2
	course.pits.append(AABB(Vector3(12.0, -1.0, -50.0), Vector3(40.0, 2.0, 100.0)))   # x > 12
	course.pits.append(AABB(Vector3(-2.0, -1.0, -50.0), Vector3(14.0, 2.0, 26.0)))    # z < -24
	course.pits.append(AABB(Vector3(2.0, -1.0, -12.0), Vector3(10.0, 2.0, 12.0)))     # the wall beside the corridor
	course.floor_y = -5.0
	return course.settle()


func _toy_starts(count: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in range(count):
		var s := ToyState.new()
		s.position = Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.5, 0.5))
		var a := rng.randf_range(-0.6, 0.6)
		s.velocity = Vector3(sin(a), 0.0, -cos(a)) * rng.randf_range(0.0, 3.0)
		out.append(s)
	return out


func _test_surf() -> void:
	_section("surfing: a ride searched on a simulator, a cache from it, a pilot riding it")
	var course := _toy_course()
	var sim := ToySim.new()
	sim.course = course
	var planner := DotBotSurfPlanner.new()
	planner.seconds = 12.0
	var start: ToyState = _toy_starts(1, 1)[0]
	var found := planner.search(start, course, sim)
	_check(bool(found["found"]), "the beam finds a way round the corner", str(found["why"]))
	var ride := DotBotSurfPlanner.trajectory(start, found.get("actions", PackedByteArray()), planner.hold, course, sim)
	_check(int(ride["event"]) == DotBotSurfCourse.EVENT_GOAL and int(ride["ticks"]) == int(found["ticks"]),
		"and its actions replayed arrive on the same tick (the simulator is deterministic)", "%d and %d ticks" % [ride["ticks"], found["ticks"]])

	var lines: Array[String] = []
	var built := planner.build(_toy_starts(4, 2), _toy_starts(16, 3), 3, course, sim, sim,
		func(line: String) -> void: lines.append(line))
	_check(int(built["found"]) >= 3 and (built["lengths"] as PackedInt32Array).size() == int(built["found"]),
		"a cache is built from several starts and repair rounds", "%d rides, failures per round %s" % [built["found"], str(built["rounds"])])

	# Saved and read back as a game's file keeps it, in units of 2 cm.
	var rows := DotBotSurfPilot.entries_to_rows(built["rides"], 0.02)
	var pilot := DotBotSurfPilot.new()
	pilot.load_stage({"entries": rows, "lengths": Array(built["lengths"]), "reference_yaw": course.reference_yaw()}, 0.02)
	_check(pilot.size() == (built["rides"] as PackedFloat32Array).size() / DotBotSurfPilot.STRIDE,
		"the cache reads back from its rows", "%d entries" % pilot.size())
	pilot.sim = sim
	pilot.score = course.score

	var tries := _toy_starts(20, 4)
	var arrived := [0, 0]
	var cost := [0, 0]
	var ridden := [0, 0]
	for mode in [0, 1]:
		pilot.rolling = mode == 1
		pilot.lookahead_ticks = 0
		for s: ToyState in tries:
			var r := pilot.ride(s, sim, 64 * 12)
			arrived[mode] += 1 if int(r["event"]) == DotBotSurfCourse.EVENT_GOAL else 0
			ridden[mode] += int(r["ticks"])
		cost[mode] = pilot.lookahead_ticks
	var plain_cost := float(cost[0]) / maxf(1.0, ridden[0])
	var rolling_cost := float(cost[1]) / maxf(1.0, ridden[1])
	_check(arrived[0] >= 16 and arrived[1] >= 16, "the pilot arrives from most perturbed starts, either veto",
		"%d and %d of 20" % [arrived[0], arrived[1]])
	_check(pilot.resyncs == 0, "on an exact simulator a kept forecast never stops matching", "%d resyncs" % pilot.resyncs)
	_check(rolling_cost < plain_cost * 0.5, "and keeping the forecast costs under half the lookahead of running it afresh",
		"%.2f against %.2f simulated ticks a ridden tick; %s" % [rolling_cost, plain_cost, str(pilot.describe())])

	# Riding while aiming elsewhere: the keys are turned for the view, and the wish is the same.
	var heading_view := DotBotSurfPilot.move_toward(30.0, 30.0)
	var turned := DotBotSurfPilot.move_toward(30.0, 120.0)
	var wish_a := _wish(30.0, heading_view)
	var wish_b := _wish(120.0, turned)
	_check(heading_view.is_equal_approx(Vector2(0.0, 1.0)) and wish_a.is_equal_approx(wish_b),
		"a wish is held from any view (the keys turn, the direction does not)", "%s and %s" % [str(wish_a), str(wish_b)])
	_done()


static func _wish(view_yaw: float, move: Vector2) -> Vector3:
	var y := deg_to_rad(view_yaw)
	return Vector3(cos(y), 0.0, -sin(y)) * move.x + Vector3(-sin(y), 0.0, -cos(y)) * move.y


## A route over a ride edge: the mesh holds two floors with a gap no walk crosses, a ride edge
## joins them, the route goes over it and says where, and the brain says when it gets there.
func _test_ride_edges() -> void:
	_section("riding: a ride edge joins two islands, a route crosses it, the brain hands it over")
	var root := Node3D.new()
	add_child(root)
	var still := StaticBody3D.new()
	root.add_child(still)
	for centre: Vector3 in [Vector3(0.0, -0.1, 0.0), Vector3(20.0, -0.1, 0.0)]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10.0, 0.2, 10.0)
		shape.shape = box
		shape.position = centre
		still.add_child(shape)
	await get_tree().physics_frame
	var nav := DotBotNav.new()
	var baked := nav.bake(root, {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [still])
	var islands := nav.islands()
	_check(baked.ok and islands.size() == 2 and nav.island_at(Vector3(0.0, 0.0, 0.0)) != nav.island_at(Vector3(20.0, 0.0, 0.0)),
		"two floors with a gap are two islands", "%d islands, at %d and %d, %s" % [islands.size(), nav.island_at(Vector3(0.0, 0.0, 0.0)), nav.island_at(Vector3(20.0, 0.0, 0.0)), str(islands.map(func(i: Dictionary) -> String: return str(i["bounds"])))])
	var far := nav.island_at(Vector3(20.0, 0.0, 0.0))
	_check(nav.on_island(far, Vector3(21.0, 0.1, 1.0)) and not nav.on_island(far, Vector3(1.0, 0.1, 1.0))
		and not nav.on_island(far, Vector3(21.0, 3.0, 1.0)), "a point is on the far island only over it and near its floor")
	var walked := nav.route(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0))
	var walked_points: PackedVector3Array = walked["points"]
	_check(walked_points.is_empty() or walked_points[walked_points.size() - 1].x < 6.0,
		"with no ride edge a route cannot reach the far floor", "%d points" % walked_points.size())
	nav.add_ride(Vector3(4.0, 0.0, 0.0), Vector3(16.0, 0.0, 0.0), 7)
	var way := nav.route(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0))
	var points: PackedVector3Array = way["points"]
	var rides: PackedInt32Array = way["rides"]
	var at := rides.find(7)
	_check(points.size() >= 3 and points[points.size() - 1].distance_to(Vector3(22.0, 0.0, 0.0)) < 0.6
		and at >= 0 and at + 1 < points.size() and points[at].distance_to(Vector3(4.0, 0.0, 0.0)) < 0.6
		and points[at + 1].distance_to(Vector3(16.0, 0.0, 0.0)) < 0.6,
		"with one the route reaches it and marks where the ride starts and ends", "%s %s" % [str(points), str(rides)])

	# The brain walks the route and says when it is at the ride's start.
	var world := DotBotWorld.new()
	world.waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([Vector3(22.0, 0.0, 0.0)])
	world.route_detail_fn = nav.route
	var me := DotBotContact.make(1, Vector3(-2.0, 0.0, 0.0))
	world.contacts_fn = func() -> Array: return [me]
	var brain := DotBotBrain.new(5)
	var said := -1
	var where := Vector3.ZERO
	var t := 0.0
	while t < 4.0 and said < 0:
		var intent := brain.think(me, world, t)
		if intent.ride >= 0:
			said = intent.ride
			where = me.position
		me.view_yaw = intent.yaw
		var y := deg_to_rad(intent.yaw)
		me.position += (Vector3(cos(y), 0.0, -sin(y)) * intent.move.x + Vector3(-sin(y), 0.0, -cos(y)) * intent.move.y) * 4.0 * TICK
		t += TICK
	_check(said == 7 and where.distance_to(Vector3(4.0, 0.0, 0.0)) < 1.2, "the brain says ride 7 at its start",
		"ride %d at %s" % [said, str(where)])

	# A ride: the pilot's legs into the brain's intent, the view left alone, and the landing told.
	var course := DotBotSurfCourse.new()
	course.start = Vector3(4.0, 0.0, 0.0)
	course.goals.append(AABB(Vector3(15.0, -1.0, -5.0), Vector3(10.0, 2.0, 10.0)))
	course.floor_y = -5.0
	var _settled := course.settle()
	var sim := ToySim.new()
	var cache := DotBotSurfPilot.new()
	cache.load_entries(PackedFloat32Array([4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 4.0]), PackedInt32Array([1]), course.reference_yaw())
	var ride := DotBotSurfRide.new().begin(cache, course, null, 0)
	var s := ToyState.new()
	s.position = Vector3(4.0, 0.0, 0.0)
	var status := DotBotSurfRide.RIDING
	var tick := 0
	var view_kept := true
	while status == DotBotSurfRide.RIDING and tick < 64 * 10:
		var intent := DotBotIntent.new()
		intent.yaw = 180.0  # looking back the way it came, at somebody
		status = ride.steer(s, intent, tick)
		if status != DotBotSurfRide.RIDING:
			break
		view_kept = view_kept and intent.yaw == 180.0
		var _e := sim.step(s, sim.command(intent.yaw, intent.move, intent.jump))
		tick += 1
	_check(status == DotBotSurfRide.LANDED and view_kept, "a ride steers to the far floor while looking the other way",
		"status %d after %d ticks at %s" % [status, tick, str(s.position)])
	brain.ride_ended(true)
	me.position = s.position
	var after := brain.think(me, world, t)
	_check(after.ride == -1 and brain._route.size() >= 1 and brain._route[brain._route.size() - 1].x > 15.0,
		"and after it the brain asks for its route again, from the far floor", "%d corners" % brain._route.size())
	nav.clear()
	root.queue_free()
	_done()
