class_name DotBotRideQuantiser
extends RefCounted

## Turns a recorded ride into a pilot cache: each kept sample's command becomes the nearest [constant DotBotSurfPilot.ACTIONS] entry for that sample's velocity.
##
## The recording's schema names its fields [code]position[/code] and [code]velocity[/code] (3 each, metres and m/s) as observation and [code]yaw[/code] (degrees), [code]move[/code] (2: x right, y forward) and [code]jump[/code] (1) as action. [method layout] finds them, so a game may add fields around them.

const POSITION := "position"
const VELOCITY := "velocity"
const YAW := "yaw"
const MOVE := "move"
const JUMP := "jump"

## A stick shorter than this is no movement key.
const DEAD_ZONE := 0.1

## Index of [constant DotBotSurfPilot.ACTIONS] that jumps with the wish along the heading.
const JUMP_ACTION := 8


## Offsets of the five fields in a frame, or a failure naming the first one missing.
static func layout(schema: Variant) -> DotResult:
	var at := {}
	var offset := 0
	for group: Array in [schema.observation, schema.action]:
		for row: Array in group:
			at[String(row[0])] = offset
			offset += int(row[1])
	for field in [POSITION, VELOCITY, YAW, MOVE, JUMP]:
		if not at.has(field):
			return DotResult.fail(DotError.CODE_INVALID, "The ride schema has no '%s' field to quantise." % field)
	return DotResult.success(at)


## The pilot action nearest to a command: view [param yaw] degrees, stick [param move], [param jump], for a player moving at [param velocity].
static func action_for(yaw: float, move: Vector2, jump: bool, velocity: Vector3, reference: float) -> int:
	if jump:
		return JUMP_ACTION
	if move.length() < DEAD_ZONE:
		return 0
	# The stick's angle off the view, the inverse of DotBotSurfPilot.move_toward.
	var wish := yaw + rad_to_deg(atan2(-move.x, move.y))
	var probe := _Probe.new()
	probe.velocity = velocity
	var best := 0
	var best_d := INF
	for a in range(1, DotBotSurfPilot.ACTIONS.size()):
		if DotBotSurfPilot.jumps(a):
			continue
		var d := absf(wrapf(DotBotSurfPilot.wish_yaw(a, probe, reference) - wish, -180.0, 180.0))
		if d < best_d - 0.001:
			best_d = d
			best = a
	return best


## The pilot cache rows of [param ep] ([constant DotBotSurfPilot.STRIDE] floats: position, velocity, action), or an empty array when the schema lacks a field.
##
## The pilot reads its cache as one row a simulator tick (tracking looks [member DotBotSurfPilot.track_every] rows ahead), but a recording keeps a sample every [param hold] ticks, so each gap becomes [param hold] rows: position and velocity interpolated between the two samples, the action the first one's (it was held over the gap).
static func entries(ep: Variant, schema: Variant, reference: float, hold: int = 1) -> PackedFloat32Array:
	var found := layout(schema)
	var out := PackedFloat32Array()
	if not found.ok:
		return out
	var at: Dictionary = found.value
	var fs: int = ep.frame_size
	var t: PackedFloat32Array = ep.ticks
	var count: int = ep.sample_count()
	var steps := maxi(1, hold)
	for i in count:
		var o: int = i * fs
		var p := Vector3(t[o + at[POSITION]], t[o + at[POSITION] + 1], t[o + at[POSITION] + 2])
		var v := Vector3(t[o + at[VELOCITY]], t[o + at[VELOCITY] + 1], t[o + at[VELOCITY] + 2])
		var a := action_for(t[o + at[YAW]], Vector2(t[o + at[MOVE]], t[o + at[MOVE] + 1]), t[o + at[JUMP]] > 0.5, v, reference)
		var n := o + fs
		var p2 := p
		var v2 := v
		if i + 1 < count:
			p2 = Vector3(t[n + at[POSITION]], t[n + at[POSITION] + 1], t[n + at[POSITION] + 2])
			v2 = Vector3(t[n + at[VELOCITY]], t[n + at[VELOCITY] + 1], t[n + at[VELOCITY] + 2])
		for k in (steps if i + 1 < count else 1):
			var f := float(k) / steps
			var pk := p.lerp(p2, f)
			var vk := v.lerp(v2, f)
			out.append_array(PackedFloat32Array([pk.x, pk.y, pk.z, vk.x, vk.y, vk.z, float(a)]))
	return out


## A pilot carrying [param ep] as its only ride, tracking, and (with [param sim]) vetoing. [param setup] (the host's, may be invalid) gets the pilot first, to set what only a game knows: the reference yaw and the course's score.
static func pilot_for(ep: Variant, schema: Variant, sim: Variant, setup: Callable, tracking: bool, horizon: int, hold: int = 1) -> DotBotSurfPilot:
	var pilot := DotBotSurfPilot.new()
	if setup.is_valid():
		setup.call(pilot, ep)
	var rows := entries(ep, schema, pilot.reference_yaw, hold)
	pilot.load_entries(rows, PackedInt32Array([rows.size() / DotBotSurfPilot.STRIDE]), pilot.reference_yaw)
	pilot.sim = sim
	pilot.tracking = tracking
	pilot.horizon = horizon if sim != null else 0
	return pilot


class _Probe:
	extends RefCounted
	var velocity := Vector3.ZERO
