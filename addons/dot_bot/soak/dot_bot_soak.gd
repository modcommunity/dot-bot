class_name DotBotSoak
extends RefCounted

## Drives a game's bots for a stretch of simulated time, samples what goes wrong, and fails with reasons.
##
## The host sets callables, then calls [method advance] each tick (or awaits [method run]) and
## reads [method finish]. A watch with the [code]DotSpawnWatch[/code] methods is optional.

const CHANNEL := "bot"
const SCHEMA := 1
const CATEGORY_NAMES := ["fell_out", "stuck", "off_nav", "unreachable", "far"]

var config: DotBotSoakConfig
## () -> Array of {id, position: Vector3, kind: StringName, has_goal: bool}, one per live mover.
var movers_fn: Callable = Callable()
## () -> Dictionary of running totals {kills, deaths, damage}. Unset skips the combat checks.
var stats_fn: Callable = Callable()
## (delta: float) -> void, steps the host's world; its cost is the tick cost. Unset: the host steps itself.
var step_fn: Callable = Callable()
## () -> float, milliseconds the last tick cost, when step_fn is unset. Default is the engine's process time.
var tick_cost_fn: Callable = Callable()
## () -> PackedVector3Array, living players, for the watch's far and unreachable verdicts.
var players_fn: Callable = Callable()
## () -> int, replaces the engine object count (for a host that counts its own).
var object_count_fn: Callable = Callable()
## Optional DotSpawnWatch (or anything with report, advance, set_players); duck typed.
var watch: Object = null
## Name -> Callable returning String or PackedStringArray, e.g. the AI scheduler's describe_lines.
var describers: Dictionary = {}

var time: float = 0.0
var ticks: int = 0

var _tick_ms: PackedFloat32Array = PackedFloat32Array()
var _interval_ms: PackedFloat32Array = PackedFloat32Array()
var _samples: Array = []
var _next_sample: float = 0.0
var _interval_ids := {"stuck": {}, "fell_out": {}, "off_nav": {}, "unreachable": {}}
var _ever := {"stuck": {}, "fell_out": {}, "off_nav": {}, "unreachable": {}}
var _max_stuck: float = 0.0
var _max_stuck_id: Variant = null
var _last_stats := {"kills": 0, "deaths": 0, "damage": 0.0}
var _base_objects: int = -1
var _base_mem: int = -1
var _base_time: float = 0.0
var _bots_seen: int = 0


func _init(p_config: DotBotSoakConfig = null) -> void:
	config = p_config if p_config != null else DotBotSoakConfig.new()
	_next_sample = config.sample_sec


## True once the configured simulated time has passed.
func is_done() -> bool:
	return time >= config.minutes * 60.0


## One tick: steps the host if step_fn is set, feeds the watch, and samples when due.
func advance(delta: float) -> void:
	var cost_ms := -1.0

	if step_fn.is_valid():
		var t0 := Time.get_ticks_usec()
		step_fn.call(delta)
		cost_ms = float(Time.get_ticks_usec() - t0) / 1000.0

	time += delta
	ticks += 1
	_feed_watch(delta)

	if cost_ms < 0.0:
		cost_ms = float(tick_cost_fn.call()) if tick_cost_fn.is_valid() else _engine_cost_ms()

	_tick_ms.append(cost_ms)
	_interval_ms.append(cost_ms)

	if time >= _next_sample:
		_next_sample += config.sample_sec
		_take_sample()


## Advances on physics frames until done; returns the finished report.
func run(tree: SceneTree) -> Dictionary:
	var delta := 1.0 / float(Engine.physics_ticks_per_second)

	while not is_done():
		await tree.physics_frame
		advance(delta)

	return finish()


## Builds the report: pass or fail with reasons, totals, samples and the describe output.
func finish() -> Dictionary:
	var stats := _read_stats()
	var growth_o := _growth(_base_objects, _last_objects())
	var growth_m := _growth(_base_mem, _last_mem())
	var report := {
		"schema": SCHEMA,
		"duration_sec": snappedf(time, 0.001),
		"ticks": ticks,
		"bots": config.bots,
		"movers_seen": _bots_seen,
		"watch": watch != null,
		"totals": {
			"kills": int(stats.get("kills", 0)),
			"deaths": int(stats.get("deaths", 0)),
			"damage": float(stats.get("damage", 0.0)),
			"stuck_movers": _ever["stuck"].size(),
			"max_stuck_sec": snappedf(_max_stuck, 0.01),
			"fell_out": _ever["fell_out"].size(),
			"off_nav": _ever["off_nav"].size(),
			"unreachable": _ever["unreachable"].size(),
		},
		"tick_ms": {"mean": snappedf(_mean(_tick_ms), 0.001), "p95": snappedf(_p95(_tick_ms), 0.001), "max": snappedf(_max(_tick_ms), 0.001)},
		"memory": {
			"objects_base": _base_objects, "objects_last": _last_objects(), "object_growth_pct": snappedf(growth_o, 0.01),
			"static_base": _base_mem, "static_last": _last_mem(), "static_growth_pct": snappedf(growth_m, 0.01),
		},
		"samples": _samples.duplicate(true),
		"describe": _describe(),
	}
	var reasons := _judge(report, stats)
	report["ok"] = reasons.is_empty()
	report["reasons"] = reasons
	report["config"] = config.to_dictionary()
	return report


## Short text summary of a report from [method finish].
static func summary(report: Dictionary) -> String:
	var t: Dictionary = report["totals"]
	var tm: Dictionary = report["tick_ms"]
	var m: Dictionary = report["memory"]
	var lines := PackedStringArray()
	lines.append("soak %s: %.0fs, %d bots, %d ticks" % ["PASS" if report["ok"] else "FAIL", report["duration_sec"], report["bots"], report["ticks"]])
	lines.append("  kills %d deaths %d damage %.0f | stuck %d (max %.1fs) fell %d off-nav %d unreachable %d" % [
		t["kills"], t["deaths"], t["damage"], t["stuck_movers"], t["max_stuck_sec"], t["fell_out"], t["off_nav"], t["unreachable"]])
	lines.append("  tick mean %.2f p95 %.2f max %.2f ms | objects %d -> %d (%+.1f%%) static %+.1f%%" % [
		tm["mean"], tm["p95"], tm["max"], m["objects_base"], m["objects_last"], m["object_growth_pct"], m["static_growth_pct"]])

	for reason in report["reasons"]:
		lines.append("  FAIL: %s" % reason)

	return "\n".join(lines)


## One log line, "SOAK " plus the report without its samples, for a CI log to grep.
static func report_line(report: Dictionary) -> String:
	var slim := report.duplicate()
	slim.erase("samples")
	slim.erase("describe")
	return "SOAK " + JSON.stringify(slim)


## Writes the full report as JSON; returns the error code.
func write_report(report: Dictionary, path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)

	if f == null:
		return FileAccess.get_open_error()

	f.store_string(JSON.stringify(report, "  "))
	return OK


func _feed_watch(delta: float) -> void:
	var movers: Array = movers_fn.call() if movers_fn.is_valid() else []
	_bots_seen = maxi(_bots_seen, movers.size())

	if watch == null:
		return

	if players_fn.is_valid():
		watch.call("set_players", players_fn.call())

	for m in movers:
		watch.call("report", m["id"], m["position"], StringName(m.get("kind", &"bot")), bool(m.get("has_goal", true)))

	var verdicts: Array = watch.call("advance", delta)

	for v in verdicts:
		var cat := int(v.category)
		var name: String = CATEGORY_NAMES[cat] if cat >= 0 and cat < CATEGORY_NAMES.size() else "other"

		if not _ever.has(name):
			continue

		_interval_ids[name][v.id] = true
		_ever[name][v.id] = true

		if name == "stuck" and float(v.seconds) > _max_stuck:
			_max_stuck = float(v.seconds)
			_max_stuck_id = v.id


func _take_sample() -> void:
	var stats := _read_stats()
	var objects := _last_objects()
	var mem := _last_mem()

	if _base_objects < 0 and time >= config.warmup_sec:
		_base_objects = objects
		_base_mem = mem
		_base_time = time

	_samples.append({
		"t": snappedf(time, 0.001),
		"stuck": _interval_ids["stuck"].size(),
		"fell_out": _interval_ids["fell_out"].size(),
		"off_nav": _interval_ids["off_nav"].size(),
		"unreachable": _interval_ids["unreachable"].size(),
		"kills": int(stats.get("kills", 0)) - int(_last_stats["kills"]),
		"deaths": int(stats.get("deaths", 0)) - int(_last_stats["deaths"]),
		"damage": float(stats.get("damage", 0.0)) - float(_last_stats["damage"]),
		"tick_p95_ms": snappedf(_p95(_interval_ms), 0.001),
		"objects": objects,
		"static_bytes": mem,
	})
	_last_stats = stats
	_interval_ms = PackedFloat32Array()

	for k in _interval_ids:
		_interval_ids[k] = {}


func _judge(report: Dictionary, stats: Dictionary) -> Array:
	var r: Array = []
	var t: Dictionary = report["totals"]

	if watch != null and t["max_stuck_sec"] > config.max_stuck_sec:
		r.append("stuck: %s stuck %.1fs (limit %.1fs)" % [_max_stuck_id, t["max_stuck_sec"], config.max_stuck_sec])

	for pair in [["fell_out", config.max_fell_out], ["off_nav", config.max_off_nav], ["unreachable", config.max_unreachable]]:
		if watch != null and pair[1] >= 0 and t[pair[0]] > pair[1]:
			r.append("%s: %d movers (limit %d)" % [pair[0], t[pair[0]], pair[1]])

	var m: Dictionary = report["memory"]
	var measured: bool = _base_objects >= 0 and time - _base_time >= config.sample_sec * 2.0

	if measured and config.max_object_growth_pct > 0.0 and m["object_growth_pct"] > config.max_object_growth_pct:
		r.append("leak: object count grew %.1f%% (%d -> %d, limit %.1f%%)" % [m["object_growth_pct"], m["objects_base"], m["objects_last"], config.max_object_growth_pct])

	if measured and config.max_memory_growth_pct > 0.0 and m["static_growth_pct"] > config.max_memory_growth_pct:
		r.append("leak: static memory grew %.1f%% (limit %.1f%%)" % [m["static_growth_pct"], config.max_memory_growth_pct])

	if config.max_tick_p95_ms > 0.0 and report["tick_ms"]["p95"] > config.max_tick_p95_ms:
		r.append("tick cost: p95 %.2f ms (limit %.2f ms)" % [report["tick_ms"]["p95"], config.max_tick_p95_ms])

	if stats_fn.is_valid() and config.require_kills_after_sec >= 0.0 and time >= config.require_kills_after_sec and int(t["kills"]) == 0:
		r.append("combat: zero kills in %.0fs" % time)

	return r


func _describe() -> Dictionary:
	var out := {}

	if watch != null and watch.has_method("describe_lines"):
		out["watch"] = Array(watch.call("describe_lines"))

	for key in describers:
		var v: Variant = (describers[key] as Callable).call()
		out[str(key)] = Array(v) if v is PackedStringArray else [str(v)]

	return out


func _read_stats() -> Dictionary:
	return (stats_fn.call() as Dictionary).duplicate() if stats_fn.is_valid() else _last_stats.duplicate()


func _last_objects() -> int:
	return int(object_count_fn.call()) if object_count_fn.is_valid() else int(Performance.get_monitor(Performance.OBJECT_COUNT))


func _last_mem() -> int:
	return OS.get_static_memory_usage()


func _engine_cost_ms() -> float:
	return (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0


static func _growth(base: int, last: int) -> float:
	return 0.0 if base <= 0 else (float(last) - float(base)) / float(base) * 100.0


static func _mean(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0

	var s := 0.0

	for x in a:
		s += x

	return s / float(a.size())


static func _max(a: PackedFloat32Array) -> float:
	var m := 0.0

	for x in a:
		m = maxf(m, x)

	return m


static func _p95(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0

	var s := a.duplicate()
	s.sort()
	return s[mini(s.size() - 1, int(ceilf(float(s.size()) * 0.95)) - 1)]
