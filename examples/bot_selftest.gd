extends "res://examples/selftest/config_tests.gd"

## dot-bot's suite (`godot --headless --path . res://examples/bot_selftest.tscn`): presets, cvars, names, roster, and a bot's senses, aim and fights measured rather than read.
## The numbers a player feels are measured per preset (time to first shot, aim error, turn speed, K/D against one fixed opponent); the bands are what the presets promise.

const CHECKS := 292

## Of CHECKS, the ones that need dot-sql and the SQLite extension linked into this project.
const SQL_CHECKS := 0

## Sections entered against sections that ran to their last line. A runtime error inside a
## section aborts that function and nothing says so.
const SECTIONS := 33


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
	_test_personas()
	_test_roster()
	_test_intent()
	_test_aim()
	_test_fire_mode()
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
	await _test_links()
	await _test_unlock_export()
	await _test_ladders()
	await _test_kill_avoidance()
	_test_harvest_verify()
	await _test_harvest_store()
	_test_ride_book()
	await _test_ride_book_store()
	_test_ride_pick()
	_test_aim_solver()
	_test_humanisation()
	_test_tricks()
	_test_utility_grenades()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	print("%d of %d sections ran to their last line" % [_completed, _entered])

	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d sections entered and %d completed, %d expected." % [_entered, _completed, SECTIONS])
		get_tree().quit(1)
		return
	var expected := CHECKS - (0 if _sql_ran else SQL_CHECKS)
	if _passed + _failed != expected:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, expected])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


class FakeVolume extends RefCounted:
	var kind := ""
	var spawnflags := 1
	var filter := ""
	var target := ""
	var entity := -1
	var record := {}
	var box := AABB()

	func bounds() -> AABB:
		return box


class FakeNode extends RefCounted:
	var volume: FakeVolume = null
	var entity: Object = null
	var on := true

	func active() -> bool:
		return on


class FakeMover extends RefCounted:
	var touch := true


class FakeEntity extends RefCounted:
	var mover: FakeMover = FakeMover.new()
	var index := 0
	var hit_half := Vector3.ZERO
	var hit_frame := Transform3D.IDENTITY


class FakeIo extends RefCounted:
	var destinations := {}
	var entities: Array = []


class FakeWorld extends RefCounted:
	var io := FakeIo.new()
	var volumes := FakeVolumes.new()
	var ladders: Array[AABB] = []

	func ladder_boxes() -> Array[AABB]:
		return ladders


class FakeVolumes extends RefCounted:
	var nodes: Array = []


static func _fake_volume(world: FakeWorld, kind: String, box: AABB, fields: Dictionary = {}, on: bool = true) -> void:
	var v := FakeVolume.new()
	v.kind = kind
	v.box = box
	v.entity = world.volumes.nodes.size()
	for k: String in fields:
		if k == "damage":
			v.record = {"damage": fields[k]}
		else:
			v.set(k, fields[k])
	var n := FakeNode.new()
	n.volume = v
	n.on = on
	world.volumes.nodes.append(n)


func _floors(centres: Array, size: Vector3) -> Array:
	var root := Node3D.new()
	add_child(root)
	var still := StaticBody3D.new()
	root.add_child(still)
	for centre: Vector3 in centres:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(size.x, 0.2, size.z)
		shape.shape = box
		shape.position = centre + Vector3(0.0, -0.1, 0.0)
		still.add_child(shape)
	await get_tree().physics_frame
	return [root, still]


## Teleports and touch doors read from a map's entities; a teleport is an edge the path crosses.
func _test_links() -> void:
	_section("links: a map's teleports join the mesh, touch doors are found, what a runner cannot fire is left out")
	var made := await _floors([Vector3(0.0, 0.0, 0.0), Vector3(30.0, 0.0, 0.0)], Vector3(10.0, 0.0, 10.0))
	var world := FakeWorld.new()
	world.io.destinations = {"far": {"at": [30.0, 0.05, 0.0]}, "air": {"at": [30.0, 20.0, 0.0]}}
	_fake_volume(world, "teleport", AABB(Vector3(3.0, 0.0, -1.0), Vector3(1.0, 2.0, 2.0)), {"target": "far"})
	_fake_volume(world, "teleport", AABB(Vector3(-3.0, 0.0, -1.0), Vector3(1.0, 2.0, 2.0)), {"target": "far"}, false)
	_fake_volume(world, "teleport", AABB(Vector3(-3.0, 0.0, 3.0), Vector3(1.0, 2.0, 1.0)), {"target": "far", "filter": "terrorists"})
	_fake_volume(world, "teleport", AABB(Vector3(-3.0, 0.0, -4.0), Vector3(1.0, 2.0, 1.0)), {"target": "far", "spawnflags": 2})
	_fake_volume(world, "teleport", AABB(Vector3(-3.0, 0.0, 2.0), Vector3(1.0, 2.0, 1.0)), {"target": "nowhere"})
	_fake_volume(world, "teleport", AABB(Vector3(0.0, 8.0, 0.0), Vector3(1.0, 2.0, 1.0)), {"target": "far"})
	_fake_volume(world, "teleport", AABB(Vector3(1.0, 0.0, 3.0), Vector3(1.0, 2.0, 1.0)), {"target": "air"})
	var door := FakeEntity.new()
	door.index = 41
	door.hit_half = Vector3(0.1, 1.5, 1.0)
	door.hit_frame = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, -4.0))
	world.io.entities.append(door)
	var button := FakeEntity.new()
	button.mover.touch = false
	button.hit_half = Vector3.ONE
	world.io.entities.append(button)

	var links := DotBotLinks.read(world)
	_check(links.teleports.size() == 3 and links.skipped == {"disabled": 1, "filtered": 1, "flags": 1, "no_destination": 1},
		"read: three teleports a runner can fire, four left out with their reasons", str(links.describe()))
	_check(links.doors.size() == 1 and int(links.doors[0]["index"]) == 41, "read: one touch door; a mover that is not touched is not one")
	_check(links.doors_touched(Vector3(0.0, 0.0, -3.5), 0.35, 1.8) == PackedInt32Array([41])
		and links.doors_touched(Vector3(0.0, 0.0, 0.0), 0.35, 1.8).is_empty(), "a body walking into the door touches it, one across the room does not")

	var nav := DotBotNav.new()
	var baked := nav.bake(made[0], {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [made[1]])
	var goal := Vector3(30.0, 0.0, 0.0)
	var before := nav.path(Vector3(-2.0, 0.0, 0.0), goal)
	_check(baked.ok and (before.is_empty() or before[before.size() - 1].x < 6.0), "without the links the far floor is out of reach")
	var stats := links.join(nav)
	_check(int(stats.get("joined", 0)) == 1 and int(stats.get("off_mesh", 0)) == 1 and int(stats.get("stranded", 0)) == 1, "join: the one on the floor joins, the one in mid-air has no floor, the one landing in mid-air is stranded", str(stats))
	var after := nav.path(Vector3(-2.0, 0.0, 0.0), goal)
	_check(not after.is_empty() and after[after.size() - 1].distance_to(goal) < 0.8, "with them the path reaches the far floor")
	var hop := nav.route(Vector3(-2.0, 0.0, 0.0), goal)
	var mark := (hop["rides"] as PackedInt32Array).find(DotBotLinks.TELEPORT_ID)
	var points: PackedVector3Array = hop["points"]
	_check(mark >= 0 and points[mark].x > 2.9 and points[mark].x < 4.1 and points[mark + 1].distance_to(Vector3(30.0, 0.05, 0.0)) < 0.6,
		"the route says where the teleport starts (inside its box) and lands", str(hop["rides"]))
	var empty := DotBotLinks.read(null)
	_check(empty.teleports.is_empty() and empty.kills.is_empty() and empty.doors.is_empty(), "no map, no links")
	nav.clear()
	made[0].queue_free()
	_done()


## One roaming bot on a toy body for [param seconds]: ground below x 0, a platform 4 m up from x 0, a ladder on its face.
## The body climbs as dot-player-controller's ladder mode does: forward into the ladder's face is up.
func _ladder_run(world: DotBotWorld, ladder: AABB, seconds: float) -> Dictionary:
	var me := DotBotContact.make(1, Vector3(-6.0, 0.0, 0.0))
	me.view_yaw = 90.0
	me.view_pitch = 0.0
	world.contacts_fn = func() -> Array: return [me]
	var brain := DotBotBrain.new(5)
	var t := 0.0
	var top := 0.0
	var climbed := false
	while t < seconds:
		var intent := brain.think(me, world, t)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		var y := deg_to_rad(intent.yaw)
		var forward := Vector3(-sin(y), 0.0, -cos(y))
		var right := Vector3(cos(y), 0.0, -sin(y))
		var wish := (right * intent.move.x + forward * intent.move.y) * 3.81
		var hull := AABB(me.position - Vector3(0.4, 0.0, 0.4), Vector3(0.8, 1.8, 0.8))
		var away := Vector3(-1.0, 0.0, 0.0)
		if hull.intersects(ladder) and -wish.dot(away) > 0.1 and me.position.y < 4.0:
			me.position.y += -wish.dot(away) * TICK
			climbed = true
		else:
			me.position += wish * TICK
			if me.position.y < 3.9:
				me.position.x = minf(me.position.x, -0.55)
			var floor_y := 4.0 if me.position.y >= 3.9 and me.position.x > -0.6 else 0.0
			me.position.y = maxf(floor_y, me.position.y - 10.0 * TICK)
		top = maxf(top, me.position.y)
		t += TICK
	return {"position": me.position, "top": top, "climbed": climbed}


## A bot reaches a platform only a ladder leads to: the nav links it, the brain walks to its foot, climbs and steps off.
func _test_ladders() -> void:
	_section("ladders: a platform only a ladder reaches is reached")
	var made := await _floors([Vector3(-5.0, 0.0, 0.0), Vector3(5.0, 4.0, 0.0)], Vector3(10.0, 0.0, 10.0))
	var ladder := AABB(Vector3(-0.2, 0.0, -0.5), Vector3(0.2, 4.0, 1.0))
	var fake := FakeWorld.new()
	fake.ladders.append(ladder)
	fake.ladders.append(AABB(Vector3(-0.2, 0.0, 3.0), Vector3(0.2, 0.5, 1.0)))
	var links := DotBotLinks.read(fake)
	var nav := DotBotNav.new()
	var baked := nav.bake(made[0], {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [made[1]])
	var goal := Vector3(5.0, 4.0, -3.0)
	var walked := nav.path(Vector3(-6.0, 0.0, 0.0), goal)
	_check(baked.ok and (walked.is_empty() or walked[walked.size() - 1].distance_to(goal) > 1.0), "without ladder links the platform is out of reach")
	var world := DotBotWorld.new()
	world.waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([goal])
	world.route_detail_fn = func(from: Vector3, to: Vector3) -> Dictionary: return nav.route(from, to)
	var without := _ladder_run(world, ladder, 30.0)
	_check(not without["climbed"] and (without["top"] as float) < 0.5, "with no ladder links a bot never leaves the floor", str(without))
	var stats := links.join(nav)
	_check(links.ladders.size() == 2 and int(stats.get("ladders", 0)) == 1, "one of two ladders joins: the stub that rises under a metre does not", str(stats))
	var route := nav.route(Vector3(-6.0, 0.0, 0.0), goal)
	var rides: PackedInt32Array = route["rides"]
	var points: PackedVector3Array = route["points"]
	var mark := rides.find(DotBotLinks.LADDER_ID)
	_check(mark >= 0 and points[mark].y < 0.5 and points[mark + 1].y > 3.5, "the route crosses the ladder from its foot to its top", str(rides))
	_check(not links.ladder_of(DotBotLinks.LADDER_ID).is_empty() and links.ladder_of(DotBotLinks.LADDER_ID + 1).is_empty(), "ladder_of answers for the joined ladder only")

	world.ladder_fn = links.ladder_of
	var run := _ladder_run(world, ladder, 30.0)
	var at: Vector3 = run["position"]
	_check(run["climbed"] and at.y > 3.9 and at.x > 0.3, "with it the bot climbs and is on the platform", str(run))
	nav.clear()
	made[0].queue_free()
	_done()


## A shot button from dot-map's export is a gadget only when a game applies the export.
func _test_unlock_export() -> void:
	_section("unlock export: opt-in shoot gadgets and door hints")
	var made := await _floors([Vector3(0.0, 0.0, 0.0)], Vector3(20.0, 0.0, 6.0))
	var nav := DotBotNav.new()
	var baked := nav.bake(made[0], {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [made[1]])
	var export := {"openers": {7: {"index": 7, "kind": "shoot", "name": "job", "box": AABB(Vector3(4.0, 0.0, -1.0), Vector3(1.0, 1.0, 1.0))}},
		"doors": [{"entity": 9, "box": AABB(Vector3(8.0, 0.0, -1.0), Vector3(0.2, 2.0, 2.0)), "opens": "output", "opened_by": [{"index": 7, "kind": "shoot", "hops": 2}]}],
		"teleports": []}
	var plain := DotBotLinks.read(FakeWorld.new())
	_check(baked.ok and plain.gadgets.is_empty() and plain.next_gadget(nav, Vector3(-6.0, 0.0, 0.0), {}, true).is_empty(), "without the export nothing is added")
	var links := DotBotLinks.read(FakeWorld.new(), {"nav_export": export})
	_check(links.gadgets.size() == 1 and links.gadgets[0]["kind"] == "shoot" and (links.gadgets[0]["feeds"] as PackedInt32Array) == PackedInt32Array([9]),
		"with it the shot button is a gadget that feeds the door", str(links.gadgets))
	_check(links.unlock_doors.size() == 1 and int(links.unlock_doors[0]["entity"]) == 9, "the door keeps its opener hint")
	var next := links.next_gadget(nav, Vector3(-6.0, 0.0, 0.0), {}, true)
	_check(not next.is_empty() and int(next["index"]) == 7, "a blocked bot is sent to it", str(next))
	_check(links.next_gadget(nav, Vector3(-6.0, 0.0, 0.0), {}).is_empty(), "it is not wanted for a teleport, so only the blocked pass takes it")
	_check(links.at_gadget(links.gadgets[0], Vector3(3.0, 0.0, 0.0)) and not links.at_gadget(links.gadgets[0], Vector3(-6.0, 0.0, 0.0)), "in reach of the shot, and not far off")
	nav.clear()
	made[0].queue_free()
	_done()


## Kill volumes cut out of the mesh: a path stops short of one, a harmless volume is not cut.
func _test_kill_avoidance() -> void:
	_section("kill avoidance: a path ends short of a kill volume")
	var made := await _floors([Vector3(0.0, 0.0, 0.0)], Vector3(40.0, 0.0, 6.0))
	var world := FakeWorld.new()
	_fake_volume(world, "hurt", AABB(Vector3(-1.0, -0.2, -4.0), Vector3(2.0, 1.0, 8.0)), {"damage": 1000.0})
	_fake_volume(world, "hurt", AABB(Vector3(8.0, -0.2, -4.0), Vector3(2.0, 1.0, 8.0)), {"damage": 10.0})
	_fake_volume(world, "hurt", AABB(Vector3(14.0, -0.2, -4.0), Vector3(2.0, 1.0, 8.0)), {"damage": 1000.0}, false)
	_fake_volume(world, "hurt", AABB(Vector3(-12.0, 6.0, -4.0), Vector3(2.0, 1.0, 8.0)), {"damage": 1000.0})
	var links := DotBotLinks.read(world)
	_check(links.kills.size() == 2 and links.skipped == {"disabled": 1}, "read: only enabled volumes that kill count (the weak and the disabled do not)", str(links.describe()))
	_check(is_equal_approx(links.kills[0].size.x, 2.8), "a kill box is grown by the margin", str(links.kills[0]))

	var plain := DotBotNav.new()
	var open := plain.bake(made[0], {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [made[1]])
	var end := Vector3(15.0, 0.0, 0.0)
	var through := plain.path(Vector3(-15.0, 0.0, 0.0), end)
	_check(open.ok and not through.is_empty() and through[through.size() - 1].distance_to(end) < 0.6, "without avoidance the path crosses the kill volume")
	plain.clear()

	var nav := DotBotNav.new()
	links.carve(nav)
	var baked := nav.bake(made[0], {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [made[1]])
	var stopped := nav.path(Vector3(-15.0, 0.0, 0.0), end)
	var last: Vector3 = stopped[stopped.size() - 1] if not stopped.is_empty() else Vector3.INF
	_check(baked.ok and not stopped.is_empty() and last.x < -1.0 and last.x > -3.5, "with it the path stops short of the volume", str(last))
	var same_side := nav.path(Vector3(-15.0, 0.0, 0.0), Vector3(-6.0, 0.0, 2.0))
	_check(not same_side.is_empty() and same_side[same_side.size() - 1].distance_to(Vector3(-6.0, 0.0, 2.0)) < 0.6, "and its own side of the floor is still walked")
	var weak := nav.path(Vector3(5.0, 0.0, 0.0), Vector3(12.0, 0.0, 0.0))
	_check(not weak.is_empty() and weak[weak.size() - 1].distance_to(Vector3(12.0, 0.0, 0.0)) < 0.6, "a volume that does not kill is walked through")
	_check(nav.describe()["avoid"] == 2, "describe counts the boxes avoided")
	nav.clear()
	made[0].queue_free()
	_done()


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


## A bot at the origin facing -Z, and one enemy.
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
