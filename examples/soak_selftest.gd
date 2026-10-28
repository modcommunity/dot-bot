extends Node

## Proves DotBotSoak's detectors and report against a trivial arena of fake movers: `godot --headless --path . res://examples/soak_selftest.tscn`.

const CHECKS := 45
const SECTIONS := 8
const TICK := 1.0 / 64.0

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures: PackedStringArray = PackedStringArray()


## Stand-in for DotSpawnWatch: the same duck-typed methods and verdict fields.
class FakeWatch extends RefCounted:
	var _pos := {}
	var _anchor := {}
	var _since := {}
	var now := 0.0

	func set_players(_p: PackedVector3Array) -> void:
		pass

	func report(id: Variant, position: Vector3, _kind: StringName, _goal: bool) -> void:
		_pos[id] = position

	func advance(delta: float) -> Array:
		now += delta
		var out: Array = []

		for id in _pos:
			var p: Vector3 = _pos[id]
			var v := FakeVerdict.new()
			v.id = id

			if p.y < -50.0:
				v.category = 0
				out.append(v)
				continue

			if not _anchor.has(id) or p.distance_to(_anchor[id]) > 0.5:
				_anchor[id] = p
				_since[id] = now
			elif now - float(_since[id]) >= 4.0:
				v.category = 1
				v.seconds = now - float(_since[id])
				out.append(v)

		return out

	func describe_lines() -> PackedStringArray:
		return PackedStringArray(["FakeWatch(%d tracked)" % _pos.size()])


class FakeVerdict extends RefCounted:
	var id: Variant
	var category: int = 1
	var seconds: float = 0.0


## A trivial arena: movers walk in lines, optionally one stands still and one falls.
class FakeArena extends RefCounted:
	var bodies := {}
	var kills := 0
	var clock := 0.0
	var stuck_id := -1
	var fall_id := -1
	var kill_every := 2.0
	var leak: Array = []
	var leak_per_tick := 0
	var busy_usec := 0

	func _init(count: int) -> void:
		for i in count:
			bodies[i] = Vector3(float(i), 0.0, 0.0)

	func movers() -> Array:
		var out: Array = []

		for id in bodies:
			out.append({"id": id, "position": bodies[id], "kind": &"bot", "has_goal": true})

		return out

	func step(delta: float) -> void:
		clock += delta

		for id in bodies:
			if id == stuck_id:
				continue

			var p: Vector3 = bodies[id]
			p.z += delta * 3.0
			bodies[id] = p

		if fall_id >= 0 and clock > 3.0:
			bodies[fall_id] = Vector3(0.0, -100.0, 0.0)

		if kill_every > 0.0 and int(clock / kill_every) > kills:
			kills += 1

		for i in leak_per_tick:
			leak.append(RefCounted.new())

		if busy_usec > 0:
			var t0 := Time.get_ticks_usec()
			while Time.get_ticks_usec() - t0 < busy_usec:
				pass

	func stats() -> Dictionary:
		return {"kills": kills, "deaths": kills, "damage": float(kills) * 25.0}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-bot soak self-test")
	_test_clean()
	_test_stuck()
	_test_fell_out()
	_test_leak()
	_test_tick_cost()
	_test_no_kills()
	_test_report()
	_test_config()
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	print("%d of %d sections ran to their last line" % [_completed, _entered])

	if _entered != SECTIONS or _completed != _entered or _passed + _failed != CHECKS:
		print("ERROR: %d sections entered, %d completed (%d expected); %d checks ran (%d expected)." % [_entered, _completed, SECTIONS, _passed + _failed, CHECKS])
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


func _begin(name: String) -> void:
	_entered += 1
	print("  " + name)


func _soak(arena: FakeArena, minutes: float, with_stats: bool = true) -> DotBotSoak:
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = minutes
	cfg.bots = arena.bodies.size()
	var soak := DotBotSoak.new(cfg)
	soak.movers_fn = arena.movers
	soak.step_fn = arena.step
	soak.watch = FakeWatch.new()

	if with_stats:
		soak.stats_fn = arena.stats

	return soak


func _drive(soak: DotBotSoak) -> Dictionary:
	while not soak.is_done():
		soak.advance(TICK)

	return soak.finish()


func _reasons_have(r: Dictionary, prefix: String) -> bool:
	for reason in r["reasons"]:
		if str(reason).begins_with(prefix):
			return true

	return false


func _test_clean() -> void:
	_begin("clean run")
	var arena := FakeArena.new(6)
	var soak := _soak(arena, 2.0)
	var r := _drive(soak)
	_check(r["ok"], "clean run passes: %s" % [r["reasons"]])
	_check(r["reasons"].is_empty(), "clean run has no reasons")
	_check(r["totals"]["kills"] >= 50, "kills counted")
	_check(r["totals"]["stuck_movers"] == 0, "nobody stuck")
	_check(r["samples"].size() == 24, "24 samples in 120 s: %d" % r["samples"].size())
	_check(int(r["duration_sec"]) == 120, "duration")
	_check(r["movers_seen"] == 6, "movers seen")
	_completed += 1


func _test_stuck() -> void:
	_begin("stuck")
	var arena := FakeArena.new(4)
	arena.stuck_id = 2
	var r := _drive(_soak(arena, 1.0))
	_check(not r["ok"], "a stuck bot fails the run")
	_check(_reasons_have(r, "stuck:"), "reason names stuck")
	_check(r["totals"]["stuck_movers"] == 1, "one stuck mover")
	_check(r["totals"]["max_stuck_sec"] > 50.0, "stuck seconds measured: %s" % r["totals"]["max_stuck_sec"])
	_check(str(r["reasons"][0]).contains("2"), "reason names the bot")
	var arena2 := FakeArena.new(4)
	arena2.stuck_id = 2
	var soak2 := _soak(arena2, 1.0)
	soak2.config.max_stuck_sec = 1000.0
	var r2 := _drive(soak2)
	_check(r2["ok"], "a loose threshold passes the same bot")
	_completed += 1


func _test_fell_out() -> void:
	_begin("fell out")
	var arena := FakeArena.new(3)
	arena.fall_id = 1
	var r := _drive(_soak(arena, 0.5))
	_check(not r["ok"] and _reasons_have(r, "fell_out:"), "fall fails with fell_out reason")
	_check(r["totals"]["fell_out"] == 1, "one distinct faller")
	_check(r["samples"][-1]["fell_out"] == 1, "sample records it")
	_completed += 1


func _test_leak() -> void:
	_begin("leak")
	var arena := FakeArena.new(3)
	arena.leak_per_tick = 40
	var soak := _soak(arena, 1.0)
	var r := _drive(soak)
	_check(not r["ok"] and _reasons_have(r, "leak: object count"), "object growth fails: %s" % [r["reasons"]])
	_check(r["memory"]["object_growth_pct"] > 25.0, "growth measured: %s" % r["memory"]["object_growth_pct"])
	_check(r["samples"][-1]["objects"] > r["samples"][0]["objects"], "samples show growth")
	arena.leak.clear()
	var steady := FakeArena.new(3)
	var r2 := _drive(_soak(steady, 1.0))
	_check(r2["memory"]["object_growth_pct"] < 25.0 and not _reasons_have(r2, "leak"), "steady run is no leak")
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = 1.0
	var counter := [1000]
	var s3 := DotBotSoak.new(cfg)
	s3.object_count_fn = func() -> int:
		counter[0] += 100
		return counter[0]
	var r3 := _drive(s3)
	_check(_reasons_have(r3, "leak: object count"), "object_count_fn override is used")
	_completed += 1


func _test_tick_cost() -> void:
	_begin("tick cost")
	var arena := FakeArena.new(2)
	arena.busy_usec = 1500
	var soak := _soak(arena, 0.1)
	soak.config.max_tick_p95_ms = 1.0
	var r := _drive(soak)
	_check(not r["ok"] and _reasons_have(r, "tick cost:"), "slow ticks fail: %s" % [r["reasons"]])
	_check(r["tick_ms"]["p95"] >= 1.5, "p95 measured: %s" % r["tick_ms"]["p95"])
	_check(r["tick_ms"]["max"] >= r["tick_ms"]["p95"], "max at least p95")
	_check(r["tick_ms"]["mean"] > 1.0, "mean measured")
	var fast := _soak(FakeArena.new(2), 0.1)
	fast.config.max_tick_p95_ms = 1.0
	fast.config.require_kills_after_sec = -1.0
	_check(_drive(fast)["ok"], "fast ticks pass the same limit")
	_completed += 1


func _test_no_kills() -> void:
	_begin("zero kills")
	var arena := FakeArena.new(3)
	arena.kill_every = 0.0
	var r := _drive(_soak(arena, 3.0))
	_check(not r["ok"] and _reasons_have(r, "combat:"), "zero kills in a long run fails")
	var short := FakeArena.new(3)
	short.kill_every = 0.0
	_check(_drive(_soak(short, 1.0))["ok"], "zero kills in a short run passes")
	var nostats := FakeArena.new(3)
	nostats.kill_every = 0.0
	_check(_drive(_soak(nostats, 3.0, false))["ok"], "no stats callable skips the combat check")
	_completed += 1


func _test_report() -> void:
	_begin("report")
	var arena := FakeArena.new(2)
	arena.stuck_id = 0
	var soak := _soak(arena, 1.0)
	soak.describers = {"scheduler": func() -> PackedStringArray: return PackedStringArray(["a", "b"])}
	var r := _drive(soak)
	var path := "user://soak_report_test.json"
	_check(soak.write_report(r, path) == OK, "report written")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	_check(parsed is Dictionary, "report parses as JSON")
	var d: Dictionary = parsed
	var keys_ok := true

	for k in ["schema", "ok", "reasons", "duration_sec", "ticks", "bots", "totals", "tick_ms", "memory", "samples", "describe", "config"]:
		keys_ok = keys_ok and d.has(k)

	_check(keys_ok, "every schema key present")
	_check(int(d["schema"]) == DotBotSoak.SCHEMA, "schema version")
	_check(d["reasons"] is Array and d["reasons"].size() >= 1 and d["ok"] == false, "reasons and ok agree")
	var s: Dictionary = d["samples"][0]
	var sample_ok := true

	for k in ["t", "stuck", "fell_out", "off_nav", "unreachable", "kills", "deaths", "damage", "tick_p95_ms", "objects", "static_bytes"]:
		sample_ok = sample_ok and s.has(k)

	_check(sample_ok, "every sample key present")
	_check(d["describe"].has("scheduler") and d["describe"]["scheduler"].size() == 2, "describers captured")
	_check(d["describe"].has("watch"), "watch describe captured")
	var line := DotBotSoak.report_line(r)
	_check(line.begins_with("SOAK ") and JSON.parse_string(line.substr(5)) is Dictionary, "SOAK line parses")
	_check(not line.contains("samples"), "SOAK line leaves samples out")
	_check(DotBotSoak.summary(r).begins_with("soak FAIL") and DotBotSoak.summary(r).contains("FAIL: stuck"), "summary shows the reason")
	_check(DotBotSoak.summary(_drive(_soak(FakeArena.new(2), 0.2))).begins_with("soak PASS"), "summary shows a pass")
	_completed += 1


func _test_config() -> void:
	_begin("config")
	var cfg := DotBotSoakConfig.new()
	cfg.apply_dictionary({"max-stuck-sec": 2.5, "minutes": 3.0, "bots": 12})
	_check(is_equal_approx(cfg.max_stuck_sec, 2.5), "dictionary sets a threshold")
	_check(cfg.bots == 12 and is_equal_approx(cfg.minutes, 3.0), "dictionary sets the run")
	_check(cfg.env_prefix() == "DOT_SOAK_" and cfg.cli_prefix() == "--soak-", "prefixes")
	_check(cfg.validate().ok, "default config validates")
	_completed += 1
