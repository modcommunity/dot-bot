extends Node

## Native against script brains (`godot --headless --path . res://examples/native_parity.tscn`):
## two brains with the same id in two copies of the same scripted fights, one thinking through
## dot_sim's DotSimBotMind and one in GDScript, compared to the bit every tick (intent, view,
## engagement, strafe, the random streams and the aim's private state). Needs the dot_sim
## extension; without it there is nothing to compare and the scene says so and passes.

const TICK := 1.0 / 30.0
const ROUNDS := 12
const SECONDS := 14.0

var _ticks := 0
var _fights := 0
var _fires := 0
var _failed := ""
var _usec := [0, 0]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	if not DotBotAim.native_available():
		print("native parity: DotSimBotMind not loaded, nothing to compare (skipped)")
		get_tree().quit(0)
		return
	var presets := ["easy", "medium", "hard", "nightmare"]
	for round_ in ROUNDS:
		_round(round_, presets[round_ % presets.size()])
		if _failed != "":
			break
	if _failed == "" and (_fights < 100 or _fires < 20):
		_failed = "too little fighting to compare: %d fight ticks, %d shots" % [_fights, _fires]
	if _failed != "":
		print("native parity: FAIL ", _failed)
		get_tree().quit(1)
		return
	print("native parity: ok, %d ticks over %d rounds (%d fighting, %d firing), native and script identical; think %.1f us native, %.1f us script" % [_ticks, ROUNDS, _fights, _fires, float(_usec[0]) / _ticks, float(_usec[1]) / _ticks])
	get_tree().quit(0)


func _settings(preset: String, round_: int) -> DotBotSettings:
	var s := DotBotSettings.new()
	s.set_difficulty(preset)
	var p := s.profile
	# Every branch of the fight step: strafe lengths eased or not, overshoot, lagged tracking,
	# stopping and crouching to shoot, retreating when hurt.
	p.strafe_jitter = 0.0 if round_ % 3 == 0 else 0.7
	p.overshoot = 0.0 if round_ % 4 == 1 else 0.5
	p.track_lag = 0.0 if round_ % 5 == 2 else 0.12
	if round_ % 2 == 0:
		p.stop_to_shoot = 0.8
		p.crouch = 0.8
		p.cover = 1.0
	return s


func _round(round_: int, preset: String) -> void:
	var rng := DotRandomStream.new(round_).stream(&"parity")
	var distance := rng.next_range_f(5.0, 40.0)
	var off := deg_to_rad(rng.next_range_f(-170.0, 170.0))
	var start := Vector3(-sin(off), 0.0, -cos(off)) * distance
	var sides: Array = []
	for native in [true, false]:
		var me := DotBotContact.make(1, Vector3.ZERO)
		var them := DotBotContact.make(2, start)
		var world := DotBotWorld.new()
		var wall := [false]
		world.contacts_fn = func() -> Array: return [me, them]
		world.line_of_sight_fn = func(_a: Vector3, _b: Vector3) -> bool: return not wall[0]
		var brain := DotBotBrain.new(round_ * 13 + 5, _settings(preset, round_))
		if not native:
			brain.aim._demote()
		sides.append({"me": me, "them": them, "world": world, "wall": wall, "brain": brain})
	if not (sides[0].brain as DotBotBrain).aim.is_native() or (sides[1].brain as DotBotBrain).aim.is_native():
		_failed = "round %d: could not set up one native and one script brain" % round_
		return

	var t := 0.0
	var dir := 1.0
	while t < SECONDS:
		if fmod(t, 0.9) < TICK:
			dir = -dir
		var rows: Array = []
		for k in sides.size():
			var side: Dictionary = sides[k]
			var me: DotBotContact = side.me
			var them: DotBotContact = side.them
			var brain: DotBotBrain = side.brain
			# Out of sight for a while (search, look round), then back.
			side.wall[0] = t > 6.0 and t < 7.5
			if absf(t - 3.0) < TICK * 0.5 or absf(t - 9.0) < TICK * 0.5:
				brain.hurt(them.eye(), t)
				me.health = 0.3 if t > 8.0 else 0.6
			var t0 := Time.get_ticks_usec()
			var intent := brain.think(me, side.world, t)
			_usec[k] += Time.get_ticks_usec() - t0
			me.view_yaw = intent.yaw
			me.view_pitch = intent.pitch
			var yr := deg_to_rad(intent.yaw)
			var fwd := Vector3(-sin(yr), 0.0, -cos(yr))
			var right := Vector3(cos(yr), 0.0, -sin(yr))
			me.velocity = (right * intent.move.x + fwd * intent.move.y) * 5.0
			me.position += me.velocity * TICK
			var across := (me.position - them.position).cross(Vector3.UP).normalized()
			them.velocity = across * 4.0 * dir
			them.position += them.velocity * TICK
			rows.append(_row(brain, intent))
		var why := _differs(rows[0], rows[1])
		if why != "":
			_failed = "round %d (%s) t=%.3f: %s" % [round_, preset, t, why]
			return
		_ticks += 1
		if (sides[0].brain as DotBotBrain).last.state in [&"fight", &"retreat"]:
			_fights += 1
		if (sides[0].brain as DotBotBrain).last.fire:
			_fires += 1
		t += TICK


func _row(brain: DotBotBrain, intent: DotBotIntent) -> Array:
	var a := brain.aim
	var row: Array = [
		intent.state, intent.yaw, intent.pitch, intent.fire, intent.crouch, intent.jump,
		intent.move.x, intent.move.y, intent.throw, intent.target_id,
		a.target_id, a.react_at, a.engaged_at, a.seen_at, a.last_seen_at, a.first_shot_at, a.first_shot_error,
		brain._rng._counter, brain._strafe, brain._strafe_until, brain._strafe_eased, brain._scene,
	]
	row.append_array(_aim_state(a))
	return row


## The aim's private state in DotSimBotMind.state()'s order, wherever it lives.
func _aim_state(a: DotBotAim) -> Array:
	if a._n != null:
		return Array(a._n.state())
	return [
		a._err_mag0, a._err_angle, a._err_spin, a._over.x, a._over.y,
		a._vel_est.x, a._vel_est.y, a._vel_est.z, a._prev_gap, a._flinch,
		a._want.x, a._want.y, a._want_prev.x, a._want_prev.y,
		1.0 if a._in_burst else 0.0, a._burst_until, a._pause_until, float(a._rng._counter),
	]


const NAMES := [
	"state", "yaw", "pitch", "fire", "crouch", "jump", "move.x", "move.y", "throw", "intent.target",
	"aim.target", "react_at", "engaged_at", "seen_at", "last_seen_at", "first_shot_at", "first_shot_error",
	"brain counter", "strafe", "strafe_until", "strafe_eased", "scene",
	"err_mag0", "err_angle", "err_spin", "over.x", "over.y", "vel_est.x", "vel_est.y", "vel_est.z",
	"prev_gap", "flinch", "want.x", "want.y", "want_prev.x", "want_prev.y", "in_burst",
	"burst_until", "pause_until", "aim counter",
]


func _differs(n: Array, s: Array) -> String:
	for i in n.size():
		var x: Variant = n[i]
		var y: Variant = s[i]
		if typeof(x) == TYPE_INT and typeof(y) == TYPE_FLOAT or typeof(x) == TYPE_FLOAT and typeof(y) == TYPE_INT:
			x = float(x)
			y = float(y)
		if typeof(x) == TYPE_FLOAT and typeof(y) == TYPE_FLOAT:
			if is_nan(x) and is_nan(y):
				continue
			if x == y:
				continue
		elif typeof(x) == typeof(y) and x == y:
			continue
		return "%s native %s script %s" % [NAMES[i] if i < NAMES.size() else str(i), var_to_str(x), var_to_str(y)]
	return ""
