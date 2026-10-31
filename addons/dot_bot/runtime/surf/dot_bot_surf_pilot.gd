class_name DotBotSurfPilot
extends RefCounted

## Rides a surf ramp from what [DotBotSurfPlanner] found: it does what the nearest remembered
## state did, and looks a second and a half ahead before trusting that.
##
## [b]The cache is rides.[/b] Every tick of every ride the planner found (from perturbed starts,
## and again from wherever an earlier pilot failed) is an entry: position, velocity, the action
## taken. [method nearest] finds the entry closest to the bot's own state -- position, plus
## velocity times [constant VELOCITY_SECONDS], so a state going the wrong way is far from one
## going the right way at the same place.
##
## [b]Copying the nearest action, once the cache is dense; tracking while it is not.[/b] By
## default the bot takes the nearest entry's action ([method policy]): one grid lookup a tick.
## With only the rides searched from the starts that arrived from 15 to 25% of perturbed starts
## on game-g2gfast's surf_beginner, because an action is only right for the state it was taken
## from. [member tracking] fixes that for a sparse cache: every [member track_every] ticks it
## tries each action on the simulator and takes the one ending nearest where the remembered ride
## was that many ticks later, keeping to one ride ([method _follow]); 50 to 80%. Once the repair
## rounds have filled the cache copying beats tracking (92% against 72% of fifty starts) at half
## the cost. The study is game-dev/docs/surf-bots-study.md.
##
## [b]The veto.[/b] The pilot runs its own policy [member horizon] ticks ahead on the simulator.
## If that future ends in a pit or below the course, it tries every action held for
## [member check_every] ticks and then the policy, and holds the one whose future survives with
## the best score. A launch that is going to fall short is decided long before it falls: at 96
## ticks, 118 of 119 vetoes found no action that survived; 192 finds them.
##
## [b]The future is kept, not recomputed[/b] ([member rolling], on by default). The simulator is
## the motor, so while the bot's real state is the state the future predicted for this tick,
## everything after it is still exactly what was simulated, and the only new tick to look at is
## one more at the far end. A ride that goes as foreseen then costs one motor tick a ridden tick
## (the far end) instead of [member horizon] every [member check_every] (eight at the defaults);
## a ride that is pushed off the forecast (another player, a booster the simulation did not run,
## a view the game rotated) recomputes it. Off, the future is run afresh every
## [member check_every] ticks, which is what the study measured.
##
## [b]A simulator is duck typed[/b] (dot-player-controller's [code]DotFpsSimulator[/code]):
## `step(state, command) -> int`, `command(yaw, move, jump)`, `delta`. States are its states:
## `position`, `velocity`, `duplicate_state()`. So this addon names no other.

# No log channel: the game that rides says what happened.

## The actions, by index: [angle off the heading in degrees (+ is left), jump]. NAN is no
## movement key at all. Index 0 is coasting. Kept short on purpose: every action is a branch of
## the planner's search and a candidate in the veto. Relative to the velocity, because the same
## action means the same thing on the left face of a ramp at 600 u/s and at 900 u/s, which is
## what lets one recorded action be reused from a nearby state.
##
## [b]Two more are anchored to the ride, not the velocity[/b] (index [constant ANCHORED_FROM] on):
## a wish square to the course's reference yaw, either side. A wish square to the velocity turns
## the velocity with it, so held for long it circles off a ramp; a surfer holds the face with a
## wish that stays put while the velocity swings under it. On game-g2gfast's stage the beam made
## that by alternating; down game-arena's combat surf ramps, whose first metres are nearly upright,
## it never did, and only a held world-fixed wish landed (2026-10-13). Appended, so a cache's
## action numbers keep their meaning.
const ACTIONS: Array = [
	[NAN, false],
	[-90.0, false], [-60.0, false], [-30.0, false], [0.0, false],
	[30.0, false], [60.0, false], [90.0, false],
	[0.0, true],
	[-90.0, false], [90.0, false],
]

## Actions from this index are anchored to the reference yaw, not the heading.
const ANCHORED_FROM := 9

## Below this horizontal speed (m/s, about 60 genre u/s) the velocity has no direction worth
## steering by, and an action is taken relative to the reference yaw instead.
const HEADING_SPEED := 1.143

## Seconds of velocity weighed against one metre of position in the nearest-state lookup.
const VELOCITY_SECONDS := 0.25
## Grid cell for the lookup, metres (128 genre units).
const CELL := 2.4384
## The far lookup's grid: a cell this many CELLs wide, and the rings of cells it reads at most.
const COARSE_CELLS := 4
const COARSE_RINGS := 3
## Further out than the rings reach, every this-many-th entry is looked at: such a state is
## falling past the ramp, and its action is a guess whichever entry it comes from.
const SPARSE_STRIDE := 16
## Floats per entry: x, y, z, vx, vy, vz, action.
const STRIDE := 7

## How far (metres, and m/s) the real state may be from the forecast and still be it.
const FORECAST_SLACK := 0.01
## Simulator steps a veto spends in all (eight futures), for its latency estimate.
const VETO_STEPS := 2000
## The fewest ticks between two fresh forecasts. A bot whose game turns its keys for its own view
## walks off the forecast on the ground every tick (a backward key is slower there), and a fresh
## 192-tick forecast every tick was half a core (game-arena, 2026-10-13).
const RESYNC_GAP := 16

var entries: PackedFloat32Array = PackedFloat32Array()
## Per entry: the index one past the last entry of its ride.
var _ride_end: PackedInt32Array = PackedInt32Array()
## Cell (Vector3i) -> PackedInt32Array of entry indices.
var _grid: Dictionary = {}
## The same for a state far from every ride: a coarser grid.
var _coarse: Dictionary = {}
## Cells with an entry within two cells of them: a state in any other is far from every ride, and
## goes straight to the coarse grid instead of opening 124 empty cells to find that out.
var _near: Dictionary = {}
var _sparse: PackedInt32Array = PackedInt32Array()
var reference_yaw: float = 0.0
## The simulator tracking and the veto run on. Without one the pilot only copies actions.
var sim: Variant = null
## `func(state) -> float`, higher is further along. The course's [code]score[/code].
var score: Callable = Callable()

## Ticks each tracked action is held, and whether to track at all.
var track_every: int = 8
var tracking: bool = false
## How often a fresh future is asked for, how far ahead it looks (ticks), and whether it is
## kept and extended instead (see the class notes). [member horizon] 0 turns the veto off.
var check_every: int = 24
var horizon: int = 192
var rolling: bool = true
## Most simulator steps one tick spends on a fresh forecast (0 = all of it in one tick). The rest
## resumes on the next ticks and the veto is judged once the forecast completes.
var forecast_budget: int = 24
## The same for a veto (up to eight futures, about 2,000 steps, ~300 ms in one tick). The veto starts
## the ticks it will be late ahead of the real state; 0 runs it all in one tick.
var veto_budget: int = 48

## Statistics: futures run afresh, vetoes taken, how many of those found no way out, and how
## often a kept forecast stopped matching.
var checks: int = 0
var vetoes: int = 0
var hopeless: int = 0
var resyncs: int = 0
## Simulated ticks spent looking ahead (the forecast, or the plain check's future) and spent on
## vetoes (every action's future when the policy's falls): the run-time cost, split.
var lookahead_ticks: int = 0
var veto_ticks: int = 0

var _override: int = -1
var _override_left: int = 0
var _tracked: int = -1
var _tracked_left: int = 0
var _following: int = -1
var _tick: int = 0

# The kept forecast: positions and velocities after each future tick from _pred_head on, the
# state at its far end and how many override ticks that end still had to run.
var _pred_p: PackedVector3Array = PackedVector3Array()
var _pred_v: PackedVector3Array = PackedVector3Array()
var _pred_head: int = 0
var _end: Variant = null
var _end_override: int = -1
var _end_override_left: int = 0
var _end_event: int = 0
var _cooldown: int = 0
var _hopeless_streak: int = 0
var _forecast_tick: int = -1000
var _fc_left: int = 0
var _fc_pending: bool = false
# A veto in progress: the state it started from, the action being tried, that action's future so
# far and the best found.
var _vt_pending: bool = false
var _vt_state: Variant = null
var _vt_a: int = 0
var _vt_s: Variant = null
var _vt_t: int = 0
var _vt_best: int = -1
var _vt_best_score: float = -INF
var _vt_longest: int = -1
var _vt_longest_t: float = -1.0


# --- The cache -------------------------------------------------------------------

## Builds the lookup from [param data] (a cache file's ride entry): `entries` as rows of
## `[x, y, z, vx, vy, vz, action]` in units of [param metres_per_unit] metres, `lengths` (entries
## per ride), `reference_yaw`.
func load_stage(data: Dictionary, metres_per_unit: float = 1.0) -> void:
	var rides := PackedFloat32Array()
	for row: Variant in data.get("entries", []):
		var r: Array = row
		rides.append_array([float(r[0]) * metres_per_unit, float(r[1]) * metres_per_unit, float(r[2]) * metres_per_unit,
			float(r[3]) * metres_per_unit, float(r[4]) * metres_per_unit, float(r[5]) * metres_per_unit, float(r[6])])
	var lengths := PackedInt32Array()
	for n: Variant in data.get("lengths", []):
		lengths.append(int(n))
	load_entries(rides, lengths, float(data.get("reference_yaw", 0.0)))


## Builds the lookup from rides in metres (the planner's), [param lengths] entries each.
func load_entries(rides: PackedFloat32Array, lengths: PackedInt32Array, yaw: float) -> void:
	# A copy: packed arrays are shared by reference, and the planner keeps appending to the one it
	# hands in, which left the ride ends short of the entries (game-dev/docs/gdscript-hazards.md).
	entries = rides.duplicate()
	reference_yaw = yaw
	_ride_end = PackedInt32Array()
	var at := 0
	for n: int in lengths:
		for _i in range(n):
			_ride_end.append(at + n)
		at += n
	while _ride_end.size() < size():
		_ride_end.append(size())
	_grid = {}
	_coarse = {}
	for i in range(size()):
		var ckey := _coarse_cell(Vector3(entries[i * STRIDE], entries[i * STRIDE + 1], entries[i * STRIDE + 2]))
		if not _coarse.has(ckey):
			_coarse[ckey] = PackedInt32Array()
		_coarse[ckey].append(i)
	for i in range(size()):
		var key := _cell(Vector3(entries[i * STRIDE], entries[i * STRIDE + 1], entries[i * STRIDE + 2]))
		# Through the dictionary, never `(_grid[key] as PackedInt32Array).append(i)`: the cast
		# hands back a copy and the append is lost, which left game-g2gfast's prototype with an
		# empty grid and a scan of every entry on every lookup (game-dev/docs/gdscript-hazards.md).
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		_grid[key].append(i)
	_sparse = PackedInt32Array()
	for i in range(0, size(), SPARSE_STRIDE):
		_sparse.append(i)
	_near = {}
	for key: Vector3i in _grid:
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for dz in range(-2, 3):
					_near[key + Vector3i(dx, dy, dz)] = true


## Uses [param other]'s cache, without copying it: many bots riding one ramp share one lookup.
## Neither may load into it afterwards (reload makes new arrays, so the other keeps the old).
func share_cache(other: DotBotSurfPilot) -> DotBotSurfPilot:
	entries = other.entries
	_ride_end = other._ride_end
	_grid = other._grid
	_coarse = other._coarse
	_near = other._near
	_sparse = other._sparse
	reference_yaw = other.reference_yaw
	return self


func size() -> int:
	return entries.size() / STRIDE


## A ride's entries as a cache file keeps them: rows in units of [param metres_per_unit] metres,
## to a tenth of a unit.
static func entries_to_rows(rides: PackedFloat32Array, metres_per_unit: float = 1.0) -> Array:
	var rows: Array = []
	var k := 1.0 / metres_per_unit
	for i in range(rides.size() / STRIDE):
		var o := i * STRIDE
		rows.append([snappedf(rides[o] * k, 0.1), snappedf(rides[o + 1] * k, 0.1), snappedf(rides[o + 2] * k, 0.1),
			snappedf(rides[o + 3] * k, 0.1), snappedf(rides[o + 4] * k, 0.1), snappedf(rides[o + 5] * k, 0.1), int(rides[o + 6])])
	return rows


# --- Actions -------------------------------------------------------------------------

## The direction the player is going, as a yaw: the velocity's, or [param reference] when there
## is too little of it to have one.
static func heading_of(state: Variant, reference: float) -> float:
	var v: Vector3 = state.velocity
	var flat := Vector2(v.x, v.z)
	if flat.length() < HEADING_SPEED:
		return reference
	return rad_to_deg(atan2(-flat.x, -flat.y))


## The yaw the wish of [param action] points along from [param state], or NAN for no key.
static func wish_yaw(action: int, state: Variant, reference: float) -> float:
	var angle: float = ACTIONS[action][0]
	if is_nan(angle):
		return NAN
	return (reference if action >= ANCHORED_FROM else heading_of(state, reference)) + angle


## The stick that points the wish along [param yaw] for a view at [param view_yaw]: (x right,
## y forward). With the view at yaw v, forward is (-sin v, -cos v) and right is (cos v, -sin v);
## a wish at angle r to the left of it is forward*cos(r) - right*sin(r), keys (-sin r, cos r).
## What lets a bot surf and aim elsewhere: the motor only reads the wish direction in the air.
static func move_toward(yaw: float, view_yaw: float) -> Vector2:
	if is_nan(yaw):
		return Vector2.ZERO
	var r := deg_to_rad(yaw - view_yaw)
	return Vector2(-sin(r), cos(r))


## Whether [param action] holds jump.
static func jumps(action: int) -> bool:
	return bool(ACTIONS[action][1])


## The command for [param action] from [param state] on [param p_sim], the view along the heading.
static func command_for(p_sim: Variant, action: int, state: Variant, reference: float) -> Object:
	var heading := heading_of(state, reference)
	var angle: float = ACTIONS[action][0]
	var move := Vector2.ZERO
	if not is_nan(angle):
		# The wish's angle from the view: from the heading, or, anchored, from the reference.
		var a := deg_to_rad(angle + (reference - heading if action >= ANCHORED_FROM else 0.0))
		move = Vector2(-sin(a), cos(a))
	return p_sim.command(heading, move, bool(ACTIONS[action][1]))


# --- Riding --------------------------------------------------------------------------

## Start over (a new ride): nothing held, no forecast.
func reset() -> void:
	_override = -1
	_override_left = 0
	_tracked = -1
	_tracked_left = 0
	_following = -1
	_tick = 0
	_cooldown = 0
	_hopeless_streak = 0
	_forecast_tick = -1000
	_vt_pending = false
	_vt_state = null
	_drop_forecast()


## The index of the entry nearest [param state], or -1 with no entries.
func nearest(state: Variant) -> int:
	var position: Vector3 = state.position
	var velocity: Vector3 = state.velocity
	_scan_best = -1
	_scan_d = INF
	var centre := _cell(position)
	# The bot's own cell first, so the best so far is a near one before any neighbour is opened.
	var own: Variant = _grid.get(centre)
	if own != null:
		_scan(own, position, velocity)
	for radius in ([1, 2] if _near.has(centre) else []):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if dx == 0 and dy == 0 and dz == 0:
						continue
					if radius == 2 and absi(dx) < 2 and absi(dy) < 2 and absi(dz) < 2:
						continue
					var key := centre + Vector3i(dx, dy, dz)
					var bucket: Variant = _grid.get(key)
					if bucket == null:
						continue
					# A cell no entry of which can beat the best so far is skipped: the distance is
					# at least the position part, and that is at least the distance to the cell's
					# box. The answer is the one the full scan gives; on a ride line most
					# of the 26 neighbours hold hundreds of entries and are this far away. It was
					# most of a forecast's cost (game-g2gfast: 390 us a simulated tick, 90 of it
					# the motor).
					if _box_distance_squared(key, position) >= _scan_d:
						continue
					_scan(bucket, position, velocity)
		if _scan_best >= 0:
			return _scan_best
	# Nothing within two cells: the state is off every ride (a veto's candidate gone wrong, a bot
	# knocked away). A scan of every entry was a millisecond a call, and a veto asks for hundreds
	# (game-arena, 2026-10-19: 4 to 12 ms a riding tick, nearly all of it this scan). A coarse grid,
	# ring by ring outward, skipping a cell whose box is further than the best so far and stopping
	# when the next ring cannot hold a nearer entry: the nearest entry. Past the last ring a sample.
	var ccentre := _coarse_cell(position)
	var width := CELL * COARSE_CELLS
	for radius in range(0, COARSE_RINGS):
		var reach := float(radius - 1) * width
		if _scan_best >= 0 and radius >= 2 and reach * reach >= _scan_d:
			break
		for dx in range(-radius, radius + 1):
			var edge_x := absi(dx) == radius
			for dy in range(-radius, radius + 1):
				var edge_xy := edge_x or absi(dy) == radius
				# Inside the shell only the two faces in z are on it.
				for dz in ([-radius, radius] if not edge_xy and radius > 0 else range(-radius, radius + 1)):
					var key := ccentre + Vector3i(dx, dy, dz)
					var bucket: Variant = _coarse.get(key)
					if bucket == null:
						continue
					if _scan_best >= 0 and _coarse_box_distance_squared(key, position) >= _scan_d:
						continue
					_scan(bucket, position, velocity)
	if _scan_best >= 0:
		return _scan_best
	_scan(_sparse, position, velocity)
	return _scan_best


var _scan_best: int = -1
var _scan_d: float = INF


## Folds the entries of [param bucket] into [member _scan_best]. One call a cell, with the
## distance written out: a call and two Vector3s an entry was most of a lookup's cost.
func _scan(bucket: PackedInt32Array, position: Vector3, velocity: Vector3) -> void:
	var e := entries
	var px := position.x
	var py := position.y
	var pz := position.z
	var vx := velocity.x
	var vy := velocity.y
	var vz := velocity.z
	var w := VELOCITY_SECONDS * VELOCITY_SECONDS
	var best := _scan_best
	var best_d := _scan_d
	for i: int in bucket:
		var o := i * STRIDE
		var dx := e[o] - px
		var dy := e[o + 1] - py
		var dz := e[o + 2] - pz
		var d := dx * dx + dy * dy + dz * dz
		if d >= best_d:
			continue
		dx = e[o + 3] - vx
		dy = e[o + 4] - vy
		dz = e[o + 5] - vz
		d += (dx * dx + dy * dy + dz * dz) * w
		if d < best_d:
			best_d = d
			best = i
	_scan_best = best
	_scan_d = best_d


## The action the nearest remembered state took, or 0 (coast) with no entries.
func policy(state: Variant) -> int:
	var i := nearest(state)
	return 0 if i < 0 else int(entries[i * STRIDE + 6])


## This tick's action for a player in [param state]. Call once a tick, in order.
func action(state: Variant) -> int:
	if _vt_pending:
		_veto_run()
		if not _vt_pending and rolling:
			_forecast(state, _override, _override_left)
	elif sim != null and horizon > 0 and not tracking:
		if rolling:
			_keep_forecast(state)
		elif _override_left <= 0 and _tick % check_every == 0:
			_check(state)
	elif sim != null and horizon > 0 and _override_left <= 0 and _tick % check_every == 0:
		_check(state)
	_tick += 1
	if _cooldown > 0:
		_cooldown -= 1
	if _override_left > 0:
		_override_left -= 1
		return _override
	if tracking and sim != null:
		if _tracked_left <= 0:
			_tracked = _track(state)
			_tracked_left = track_every
		_tracked_left -= 1
		return _tracked
	return policy(state)


## This tick's command for a player in [param state], the view along the heading.
func command(state: Variant) -> Object:
	return command_for(sim, action(state), state, reference_yaw)


## Rides from [param start] (not changed) on [param ride_sim] for at most [param max_ticks].
## Returns `{"event": int, "ticks": int, "trail": Array}`, the trail a copy of the state every
## [param keep_every] ticks (the first is the start), which is where the planner's repair starts
## looking from.
func ride(start: Variant, ride_sim: Variant, max_ticks: int, keep_every: int = 16) -> Dictionary:
	reset()
	var s: Variant = start.duplicate_state()
	var trail: Array = []
	var event := 0
	var t := 0
	while t < max_ticks and event == 0:
		if t % keep_every == 0:
			trail.append(s.duplicate_state())
		event = ride_sim.step(s, command_for(ride_sim, action(s), s, reference_yaw))
		t += 1
	return {"event": event, "ticks": t, "trail": trail}


# --- The future --------------------------------------------------------------------

## Runs the policy [param ticks] ahead from a copy of [param state], first holding
## [param first] for [member check_every] ticks when it is not -1. Returns
## `[survived: bool, score (survived) or ticks survived (fell)]`.
func future(state: Variant, first: int, ticks: int) -> Array:
	var s: Variant = state.duplicate_state()
	for t in range(ticks):
		var a := first if first >= 0 and t < check_every else policy(s)
		var event: int = sim.step(s, command_for(sim, a, s, reference_yaw))
		if first >= 0:
			veto_ticks += 1
		else:
			lookahead_ticks += 1
		if event == DotBotSurfCourse.EVENT_GOAL:
			return [true, INF]
		if event != DotBotSurfCourse.EVENT_NONE:
			return [false, float(t)]
	return [true, float(score.call(s)) if score.is_valid() else 0.0]


## The veto: when the policy's own future falls, the action whose future survives best.
func _check(state: Variant) -> void:
	checks += 1
	var plain := future(state, -1, horizon)
	if bool(plain[0]):
		return
	_veto(state)


func _veto(state: Variant) -> void:
	vetoes += 1
	_vt_pending = true
	_vt_state = state.duplicate_state()
	if veto_budget > 0:
		_advance_for_latency(_vt_state)
	_vt_a = 0
	_vt_s = null
	_vt_best = -1
	_vt_best_score = -INF
	_vt_longest = -1
	_vt_longest_t = -1.0
	_veto_run()


## A spread veto answers about VETO_STEPS / [member veto_budget] ticks late, so it starts that many
## ticks ahead (the held action, then the policy) and its answer fits the state it lands on.
func _advance_for_latency(s: Variant) -> void:
	var late := mini(ceili(float(VETO_STEPS) / float(veto_budget)), check_every)
	for i in late:
		var a := _override if i < _override_left else policy(s)
		if sim.step(s, command_for(sim, a, s, reference_yaw)) != DotBotSurfCourse.EVENT_NONE:
			return


## A veto, then the forecast again from its action; with the veto unfinished the forecast waits for it.
func _veto_then_forecast(state: Variant) -> void:
	_veto(state)
	if not _vt_pending:
		_forecast(state, _override, _override_left)


## Runs up to [member forecast_budget] steps of the pending veto: every action's future in turn.
func _veto_run() -> void:
	var n := veto_budget if veto_budget > 0 else 1 << 30
	while _vt_a < ACTIONS.size() and n > 0:
		if _vt_s == null:
			_vt_s = _vt_state.duplicate_state()
			_vt_t = 0
		var a := _vt_a if _vt_t < check_every else policy(_vt_s)
		var event: int = sim.step(_vt_s, command_for(sim, a, _vt_s, reference_yaw))
		veto_ticks += 1
		n -= 1
		_vt_t += 1
		var ended := true
		if event == DotBotSurfCourse.EVENT_GOAL or (event == DotBotSurfCourse.EVENT_NONE and _vt_t >= horizon):
			var sc: float = INF if event == DotBotSurfCourse.EVENT_GOAL else (float(score.call(_vt_s)) if score.is_valid() else 0.0)
			if sc > _vt_best_score:
				_vt_best_score = sc
				_vt_best = _vt_a
		elif event != DotBotSurfCourse.EVENT_NONE:
			if float(_vt_t - 1) > _vt_longest_t:
				_vt_longest_t = float(_vt_t - 1)
				_vt_longest = _vt_a
		else:
			ended = false
		if ended:
			_vt_a += 1
			_vt_s = null
	if _vt_a >= ACTIONS.size():
		_vt_pending = false
		_vt_state = null
		_veto_apply()


func _veto_apply() -> void:
	var best := _vt_best
	if best < 0:
		# No way out in sight: put the fall off as long as possible, which is the most time for
		# the next check to find one.
		hopeless += 1
		_hopeless_streak += 1
		best = _vt_longest
	else:
		_hopeless_streak = 0
	if best >= 0:
		_override = best
		_override_left = check_every
		_tracked_left = 0
	# After a veto that found no way out, the next waits longer (twice, four times, at most eight
	# times as long): a doomed ride vetoing every check_every ticks was most of a hard edge's cost.
	_cooldown = check_every * (1 << mini(_hopeless_streak, 3))


## The rolling veto: keeps the forecast while the real state is on it, extends it by a tick at
## the far end, and vetoes when the far end falls. See the class notes.
func _keep_forecast(state: Variant) -> void:
	if _fc_pending:
		# The real state moves on while the forecast catches up; the head follows it.
		_pred_head += 1
		_run_forecast()
		if not _fc_pending:
			_judge(state)
		return
	var on_it := false
	if _end != null and _pred_head < _pred_p.size():
		var p: Vector3 = state.position
		var v: Vector3 = state.velocity
		on_it = p.distance_to(_pred_p[_pred_head]) <= FORECAST_SLACK and v.distance_to(_pred_v[_pred_head]) <= FORECAST_SLACK * 10.0
		_pred_head += 1
	if _end != null and not on_it and _tick > 0:
		resyncs += 1
	if not on_it:
		if _end != null and (_cooldown > 0 or _tick - _forecast_tick < RESYNC_GAP):
			# Just vetoed, or just forecast: wait, as the plain check does.
			return
		if state.has_method(&"is_grounded") and state.is_grounded():
			# Walking to the ramp: nothing to fall from yet, and the forecast follows when it leaves.
			_drop_forecast()
			return
		_forecast(state, _override if _override_left > 0 else -1, _override_left)
		if not _fc_pending:
			_judge(state)
		return
	# On the forecast: one more tick at the far end, unless it already ended.
	if _end_event != DotBotSurfCourse.EVENT_NONE:
		if _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
			_veto_then_forecast(state)
		return
	var a: int
	if _end_override_left > 0:
		a = _end_override
		_end_override_left -= 1
	else:
		a = policy(_end)
	_end_event = sim.step(_end, command_for(sim, a, _end, reference_yaw))
	lookahead_ticks += 1
	_push(_end)
	if _pred_head > 512:
		_pred_p = _pred_p.slice(_pred_head)
		_pred_v = _pred_v.slice(_pred_head)
		_pred_head = 0
	if _end_event != DotBotSurfCourse.EVENT_NONE and _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
		_veto_then_forecast(state)


## A fresh forecast from [param state]: [param first] held for [param first_left] ticks, then the
## policy, [member horizon] ticks or until it ends.
func _forecast(state: Variant, first: int, first_left: int) -> void:
	checks += 1
	_forecast_tick = _tick
	_drop_forecast()
	_end = state.duplicate_state()
	_end_override = first
	_end_override_left = first_left if first >= 0 else 0
	_fc_left = horizon
	_fc_pending = true
	_run_forecast()


## Vetoes when a completed forecast ends in a fall, then forecasts again from the veto's action.
func _judge(state: Variant) -> void:
	if _end_event != DotBotSurfCourse.EVENT_NONE and _end_event != DotBotSurfCourse.EVENT_GOAL and _cooldown <= 0:
		_veto_then_forecast(state)


## Runs up to [member forecast_budget] steps of the pending forecast.
func _run_forecast() -> void:
	var n := forecast_budget if forecast_budget > 0 else _fc_left
	while _fc_left > 0 and n > 0:
		n -= 1
		_fc_left -= 1
		var a: int
		if _end_override_left > 0:
			a = _end_override
			_end_override_left -= 1
		else:
			a = policy(_end)
		_end_event = sim.step(_end, command_for(sim, a, _end, reference_yaw))
		lookahead_ticks += 1
		_push(_end)
		if _end_event != DotBotSurfCourse.EVENT_NONE:
			_fc_left = 0
	_fc_pending = _fc_left > 0


func _push(s: Variant) -> void:
	_pred_p.append(s.position)
	_pred_v.append(s.velocity)


func _drop_forecast() -> void:
	_pred_p = PackedVector3Array()
	_pred_v = PackedVector3Array()
	_pred_head = 0
	_end = null
	_end_event = DotBotSurfCourse.EVENT_NONE
	_end_override_left = 0
	_fc_left = 0
	_fc_pending = false


# --- Tracking ------------------------------------------------------------------------

## The action whose [member track_every]-tick future ends nearest where the nearest remembered
## ride was that many ticks later. One that reaches the goal wins outright; one that falls is
## never chosen while another does not.
func _track(state: Variant) -> int:
	var i := _follow(state)
	if i < 0:
		return 0
	var target := mini(i + track_every, _ride_end[i] - 1)
	var best := int(entries[i * STRIDE + 6])
	var best_d := INF
	for a in range(ACTIONS.size()):
		var s: Variant = state.duplicate_state()
		var event := 0
		for _t in range(track_every):
			event = sim.step(s, command_for(sim, a, s, reference_yaw))
			if event != 0:
				break
		if event == DotBotSurfCourse.EVENT_GOAL:
			return a
		if event != 0:
			continue
		var d := _distance(target, s.position, s.velocity)
		if d < best_d:
			best_d = d
			best = a
	return best


## How far along its ride (entries) the followed entry may move in one look, how much nearer
## (squared distance, times) another ride must be to switch to it, and a floor under that in
## square metres so two rides a few centimetres apart do not trade places.
const FOLLOW_WINDOW := 48
const SWITCH_RATIO := 4.0
const SWITCH_SLACK := 0.25


## The entry to track from: the next stretch of the ride already being followed, unless another
## ride is much nearer. [b]Sticky, because the rides disagree.[/b] Re-matching to the globally
## nearest entry every 8 ticks hopped between rides on different lines (one face of an A-frame
## ramp and the other), and a mix of two good lines is a bad one.
func _follow(state: Variant) -> int:
	var position: Vector3 = state.position
	var velocity: Vector3 = state.velocity
	var anywhere := nearest(state)
	if anywhere < 0 or _following < 0 or _following >= size():
		_following = anywhere
		return anywhere
	var best := -1
	var best_d := INF
	var end := mini(_ride_end[_following], _following + FOLLOW_WINDOW)
	for i in range(_following, end):
		var d := _distance(i, position, velocity)
		if d < best_d:
			best_d = d
			best = i
	if best < 0 or best_d > SWITCH_RATIO * _distance(anywhere, position, velocity) + SWITCH_SLACK:
		best = anywhere
	_following = best
	return best


func _distance(i: int, position: Vector3, velocity: Vector3) -> float:
	var o := i * STRIDE
	var dp := Vector3(entries[o], entries[o + 1], entries[o + 2]) - position
	var dv := (Vector3(entries[o + 3], entries[o + 4], entries[o + 5]) - velocity) * VELOCITY_SECONDS
	return dp.length_squared() + dv.length_squared()


## The squared distance from [param p] to cell [param key]'s box (0 inside it).
func _box_distance_squared(key: Vector3i, p: Vector3) -> float:
	var lo := Vector3(key) * CELL
	var hi := lo + Vector3(CELL, CELL, CELL)
	var q := p.clamp(lo, hi)
	return q.distance_squared_to(p)


func _coarse_box_distance_squared(key: Vector3i, p: Vector3) -> float:
	var w := CELL * COARSE_CELLS
	var lo := Vector3(key) * w
	return p.clamp(lo, lo + Vector3(w, w, w)).distance_squared_to(p)


func _coarse_cell(p: Vector3) -> Vector3i:
	var w := CELL * COARSE_CELLS
	return Vector3i(int(floor(p.x / w)), int(floor(p.y / w)), int(floor(p.z / w)))


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL)))


func describe() -> Dictionary:
	return {"entries": size(), "tracking": tracking, "horizon": horizon, "rolling": rolling,
		"checks": checks, "vetoes": vetoes, "hopeless": hopeless, "resyncs": resyncs,
		"lookahead_ticks": lookahead_ticks, "veto_ticks": veto_ticks}


func describe_lines() -> PackedStringArray:
	var d := describe()
	return PackedStringArray(["surf pilot  %d entries, horizon %d%s; %d futures, %d vetoes (%d hopeless), %d resyncs" % [
		d["entries"], d["horizon"], " rolling" if rolling else "", d["checks"], d["vetoes"], d["hopeless"], d["resyncs"]]])
