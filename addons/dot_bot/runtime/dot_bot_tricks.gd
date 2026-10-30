class_name DotBotTricks
extends RefCounted

## The movement tricks a bot chains: slide, jump, wall run, wall jump, duck, air-jump.
##
## [b]Pressing buttons a person could.[/b] It only sets [member DotBotIntent.crouch],
## [member DotBotIntent.jump] and [member DotBotIntent.air_jump] (and bends the move while a wall
## is being run), so the motor refuses what a body cannot do, and a game that has a trick off is
## simply never reported its precondition ([member DotBotContact.air_jump_ready]).
## [b]Difficulty is the profile.[/b] How often (slide, wall_run, air_jump, cover_crouch), how well
## chained (trick_chain) and how fast to start (trick_delay) are SPEC rows; the dice are the
## brain's own seeded stream, so two bots on one map do not run the same wall the same way.

const CHANNEL := "dot.bot"

## Flat speed below which no slide or wall run is tried: the motor needs about this much.
const SLIDE_SPEED := 6.5
const WALL_RUN_SPEED := 9.5

## How far to the side a wall is looked for, and how steeply it may meet the heading (sine).
const WALL_REACH := 2.2
const WALL_SHALLOW := 0.6

## Seconds between looks for a chance, and the quiet after a trick ends.
const LOOK_EVERY := 0.35
const COOLDOWN := 1.2

## Scenario weights: how much a situation wants a trick, against 1 for a charge across a map.
const WEIGHTS := {&"close": 1.0, &"chase": 1.0, &"flee": 1.4, &"roam": 0.35}

enum Phase { IDLE, SLIDE_WAIT, SLIDING, AIR, RIDE }

## How many of each the bot started, for describe() and a suite.
var counts: Dictionary = {&"slide": 0, &"hop": 0, &"wall": 0, &"wall_jump": 0, &"crouch": 0, &"air_jump": 0}

var _phase: Phase = Phase.IDLE
var _at: float = 0.0
var _until: float = 0.0
var _look_at: float = 0.0
var _quiet_until: float = 0.0
var _wall: Vector3 = Vector3.ZERO
var _chain: bool = false
var _duck_until: float = -INF
var _duck_next: float = 0.0
var _air_next: float = 0.0
var _was_crouch: bool = false


## Forgets a plan: a respawn, or a trick the world changed under.
func reset() -> void:
	_phase = Phase.IDLE
	_wall = Vector3.ZERO
	_duck_until = -INF


## Adds this tick's tricks to [param out]. [param scenario] is one of close, chase, flee, cover,
## fight or roam; [param up] is how far above the bot its target stands (0 with none).
func apply(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, rng: DotRandomStream, scenario: StringName, up: float, yaw: float, now: float, dt: float, out: DotBotIntent) -> void:
	var flat := Vector2(me.velocity.x, me.velocity.z)
	var speed := flat.length()
	var heading := flat / speed if speed > 1.0 else _heading_of(out, yaw)

	if _phase != Phase.IDLE:
		_step(me, p, rng, heading, speed, now, out)
	else:
		_ground_tricks(me, p, rng, scenario, now, dt, out)
		if now >= _look_at and now >= _quiet_until and not out.crouch:
			_look_at = now + LOOK_EVERY * (0.6 + 0.8 * rng.next_unit())
			_look(me, world, p, rng, scenario, heading, speed, now)
		_air_jump(me, p, rng, scenario, up, now, out)

	# A key is pressed again only after it was let go: a held crouch is no second slide.
	_was_crouch = out.crouch


## Hops while closing a distance, and the duck of a bot waiting in cover.
func _ground_tricks(me: DotBotContact, p: DotBotProfile, rng: DotRandomStream, scenario: StringName, now: float, dt: float, out: DotBotIntent) -> void:
	if me.grounded and dt > 0.0 and (scenario == &"close" or scenario == &"chase") and not out.jump:
		var speed := Vector2(me.velocity.x, me.velocity.z).length()
		if speed > 4.0 and rng.next_unit() < p.jump * 2.5 * p.trick_chain * dt:
			out.jump = true
			counts[&"hop"] += 1

	if now < _duck_until:
		out.crouch = true
		return
	if scenario != &"cover" and scenario != &"flee":
		return
	if now >= _duck_next and me.grounded and Vector2(me.velocity.x, me.velocity.z).length() < 3.5:
		_duck_next = now + 2.0 + 3.0 * rng.next_unit()
		if rng.next_unit() < p.cover_crouch:
			_duck_until = now + p.trick_delay * rng.next_unit() + 0.6 + 1.2 * rng.next_unit()
			counts[&"crouch"] += 1
			out.crouch = true


## The launch: to get away when hurt, or up to a target above. Only when the game says it is ready.
func _air_jump(me: DotBotContact, p: DotBotProfile, rng: DotRandomStream, scenario: StringName, up: float, now: float, out: DotBotIntent) -> void:
	if not me.air_jump_ready or now < _air_next:
		return
	var wants := (scenario == &"flee" and me.health < 0.5) or up > 2.4
	if not wants:
		return
	_air_next = now + 1.0
	if rng.next_unit() < p.air_jump:
		out.air_jump = true
		_air_next = now + 5.0
		counts[&"air_jump"] += 1


## Looks for a chance to start a slide, a slide-jump or a wall run.
func _look(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, rng: DotRandomStream, scenario: StringName, heading: Vector2, speed: float, now: float) -> void:
	if not me.grounded or speed < SLIDE_SPEED or not WEIGHTS.has(scenario):
		return
	var weight: float = WEIGHTS[scenario]
	var wall := Vector3.ZERO
	if world != null and p.wall_run > 0.0:
		wall = _find_wall(me, world, heading)
	if wall != Vector3.ZERO and rng.next_unit() < p.wall_run * weight:
		# A wall run needs more speed than a run: the slide's boost is how a person gets it.
		_wall = wall
		_chain = true
		_start_slide(p, rng, now)
		return
	if rng.next_unit() < p.slide * weight:
		_wall = Vector3.ZERO
		_chain = rng.next_unit() < p.trick_chain
		_start_slide(p, rng, now)


func _start_slide(p: DotBotProfile, rng: DotRandomStream, now: float) -> void:
	_phase = Phase.SLIDE_WAIT
	_at = now + p.trick_delay * (0.4 + 0.8 * rng.next_unit())


## The wall beside the heading that a run could follow, as its normal, or zero.
func _find_wall(me: DotBotContact, world: DotBotWorld, heading: Vector2) -> Vector3:
	var from := me.position + Vector3.UP * 1.0
	var best := Vector3.ZERO
	var best_d := INF
	for sign_x: float in [-1.0, 1.0]:
		var side := Vector2(-heading.y, heading.x) * sign_x
		var hit := world.wall_ahead(from, Vector3(side.x, 0.0, side.y), WALL_REACH)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if absf(n.y) > 0.3 or absf(Vector2(n.x, n.z).normalized().dot(heading)) > WALL_SHALLOW:
			continue
		var d := float(hit["distance"])
		if d < best_d:
			best_d = d
			best = n
	return best


func _step(me: DotBotContact, p: DotBotProfile, rng: DotRandomStream, heading: Vector2, speed: float, now: float, out: DotBotIntent) -> void:
	match _phase:
		Phase.SLIDE_WAIT:
			if now < _at:
				return
			if not me.grounded or speed < SLIDE_SPEED or _was_crouch:
				_end(now)
				return
			out.crouch = true
			counts[&"slide"] += 1
			_until = now + (0.3 + 0.25 * rng.next_unit())
			_phase = Phase.SLIDING
		Phase.SLIDING:
			if not me.grounded:
				_phase = Phase.AIR
				_until = now + 1.0
				return
			if now < _until:
				out.crouch = true
				return
			if _chain:
				out.jump = true
				counts[&"hop"] += 1
				_phase = Phase.AIR
				_until = now + 1.0
			else:
				_end(now)
		Phase.AIR:
			if _wall == Vector3.ZERO:
				if me.grounded or now > _until:
					_end(now)
				return
			if me.wall_running:
				counts[&"wall"] += 1
				_until = now + 0.5 + 0.7 * rng.next_unit()
				_phase = Phase.RIDE
				return
			if me.grounded or now > _until:
				_end(now)
				return
			_steer_along(out, heading)
		Phase.RIDE:
			if not me.wall_running or now > _until + 1.5:
				_end(now)
				return
			_steer_along(out, heading)
			if now >= _until:
				out.jump = rng.next_unit() < p.trick_chain
				if out.jump:
					counts[&"wall_jump"] += 1
				_end(now)


func _end(now: float) -> void:
	_phase = Phase.IDLE
	_wall = Vector3.ZERO
	_quiet_until = now + COOLDOWN


## Bends the move to run along the wall, nudged into it so the run starts and keeps its hold.
func _steer_along(out: DotBotIntent, heading: Vector2) -> void:
	var n := Vector2(_wall.x, _wall.z).normalized()
	var along := Vector2(-n.y, n.x)
	if along.dot(heading) < 0.0:
		along = -along
	var want := (along - n * 0.35).normalized()
	var m := _local(want, out.yaw)
	out.move = m


func _heading_of(out: DotBotIntent, yaw: float) -> Vector2:
	var y := deg_to_rad(yaw)
	var f := Vector2(-sin(y), -cos(y))
	var r := Vector2(cos(y), -sin(y))
	var w := f * out.move.y + r * out.move.x
	return w.normalized() if w.length() > 0.01 else f


static func _local(world_dir: Vector2, yaw: float) -> Vector2:
	var y := deg_to_rad(yaw)
	var f := Vector2(-sin(y), -cos(y))
	var r := Vector2(cos(y), -sin(y))
	return Vector2(world_dir.dot(r), world_dir.dot(f)).limit_length(1.0)
