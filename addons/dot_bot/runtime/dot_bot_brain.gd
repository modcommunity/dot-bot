class_name DotBotBrain
extends RefCounted

## One bot's decisions: whom it sees, where it looks, when it pulls the trigger and how it
## moves, as a [DotBotIntent] each tick.
##
## [b]Built to look like a person, not to win.[/b] The four things that make a bot read as a
## machine are the four this models before anything else:
##
## [codeblock]
## 1. seeing through walls      it sees only inside its view cone, past a line-of-sight test
##                              the world answers; anything else it can only hear
## 2. reacting on the tick      bot_reaction, plus bot_notice for somebody off to the side;
##                              half of it for a target it was already pre-aiming
## 3. snapping its aim          the view turns at most bot_turn_rate, closing smoothly
##                              (bot_turn_smooth) and tracking motion only as well as
##                              bot_prediction lets it
## 4. hitting the first shot    aim starts bot_aim_error off, settles by half every
##                              bot_aim_settle seconds to bot_aim_floor, and a hit adds
##                              bot_flinch back
## [/codeblock]
##
## Then the fight itself: a preferred range, strafing that changes direction irregularly,
## bursts at range and a held trigger up close, standing still or crouching for a long burst,
## backing out when badly hurt, pre-aiming and re-peeking a corner a target went behind, a
## grenade at somebody who just took cover, turning to a gunshot or to whoever hit it, and
## roaming toward where it last knew of an enemy. Every one of those is a [DotBotProfile] field.
##
## [b]Pure.[/b] It reads a [DotBotContact] for itself and a [DotBotWorld], and returns an
## intent; it moves nothing. Its randomness is a [DotRandomStream] seeded from [member id], so
## two runs of the same inputs play the same bot, which is what lets a suite hold a bot still.
##
## [codeblock]
## var brain := DotBotBrain.new(bot_id, DotBotSettings.of(game))
## var intent := brain.think(me, world, now)
## intent.write_move(move_command)
## intent.write_fire(fire_command)
## [/codeblock]

const CHANNEL := "dot.bot"

## Within this distance a body is noticed whatever way the bot faces: somebody touching you.
const CLOSE_NOTICE := 2.0

## Health fraction under which a bot that rolled [member DotBotProfile.cover] backs out.
const RETREAT_HEALTH := 0.35

## Seconds a flinch takes to halve.
const FLINCH_HALF_LIFE := 0.3

## Seconds a bot that is not going after a sound or a lost target spends looking toward it.
const GLANCE := 1.2

## Longest gap between thinks that is integrated as one step, seconds.
const MAX_STEP := 0.25

## Seconds a bot with no prediction trails a moving target by: about how far behind a person
## tracking by eye is. bot_prediction takes it to nothing.
const TRACK_LAG := 0.08

var id: int = 0
var settings: DotBotSettings = null

## The latest intent, for describe().
var last: DotBotIntent = null

# The view the brain believes it has, in command degrees.
var _yaw: float = NAN
var _pitch: float = 0.0
var _want_prev: Vector2 = Vector2(NAN, NAN)

# The target and the engagement.
var target_id: int = -1
var _visible: bool = false
var _react_at: float = INF
var _engaged_at: float = -INF
var _seen_at: float = NAN
var _first_shot_at: float = NAN
var _first_shot_error: float = NAN
var _err_mag0: float = 0.0
var _err_angle: float = 0.0
var _err_spin: float = 1.0
var _flinch: float = 0.0
var _roll_stop: bool = false
var _roll_crouch: bool = false
var _roll_cover: bool = false

var _last_seen_pos: Vector3 = Vector3.INF
var _last_seen_vel: Vector3 = Vector3.ZERO
var _last_seen_at: float = -INF
var _lost_at: float = -INF
var _peeking: bool = false
var _chase_lost: bool = false
var _grenade_ready: bool = false

# Sound and pain.
var _heard_pos: Vector3 = Vector3.INF
var _heard_at: float = -INF
var _chase_sound: bool = false
var _heard_seq: int = 0
var _hurt_from: Vector3 = Vector3.INF
var _hurt_at: float = -INF
var _known_enemy: Vector3 = Vector3.INF

# Movement.
var _strafe: float = 0.0
var _strafe_until: float = -INF
var _in_burst: bool = false
var _burst_until: float = -INF
var _pause_until: float = -INF
var _waypoint: Vector3 = Vector3.INF
var _stuck_at: float = 0.0
var _stuck_from: Vector3 = Vector3.INF

var _now: float = NAN
var _was_alive: bool = true
var _rng: DotRandomStream = null


func _init(p_id: int = 0, p_settings: DotBotSettings = null) -> void:
	id = p_id
	settings = p_settings if p_settings != null else DotBotSettings.new()
	_rng = DotRandomStream.new(p_id).stream(&"dot_bot")


## What this bot does this tick.
func think(me: DotBotContact, world: DotBotWorld, now: float) -> DotBotIntent:
	var p := settings.profile
	var dt := 0.0 if is_nan(_now) else clampf(now - _now, 0.0, MAX_STEP)
	_now = now
	var out := DotBotIntent.new()

	if me == null or not me.alive:
		_was_alive = false
		_forget_target()
		out.state = &"dead"
		out.yaw = 0.0 if is_nan(_yaw) else _yaw
		out.pitch = _pitch
		last = out
		return out

	if not _was_alive:
		# A respawn: a new life starts with no target, no plan and the view the spawn gave.
		_was_alive = true
		_forget_target()
		_waypoint = Vector3.INF
		_heard_at = -INF
		_hurt_at = -INF
		_yaw = NAN

	if not is_nan(me.view_yaw):
		_yaw = me.view_yaw
		_pitch = me.view_pitch
	elif is_nan(_yaw):
		_yaw = 0.0

	_flinch *= pow(0.5, dt / FLINCH_HALF_LIFE) if dt > 0.0 else 1.0

	var all := world.contacts() if world != null else []
	var seen := _perceive(me, all, world, p, now)
	if world != null:
		_hear(me, all, world, p, now)

	if seen != null:
		_fight(me, seen, world, p, now, dt, out)
	elif _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		_search(me, p, now, dt, out)
	elif maxf(_heard_at, _hurt_at) > -INF and now - maxf(_heard_at, _hurt_at) <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at):
		_listen(me, p, now, dt, out)
	else:
		_roam(me, world, p, now, dt, out)

	out.yaw = _yaw
	out.pitch = _pitch
	out.target_id = target_id if _visible else -1
	last = out
	return out


## How long a lost target or a sound holds the bot's attention: its whole memory when it is
## going after it or re-peeking, and a glance otherwise. A bot that stands staring at a wall
## for four seconds because it heard a shot behind it reads as stuck, not as cautious.
func _hold_time(p: DotBotProfile, committed: bool) -> float:
	return p.memory if committed else minf(p.memory, GLANCE)


## Being hit. [param from] is where the shot came from (INF when unknown).
func hurt(from: Vector3, now: float) -> void:
	_flinch += settings.profile.flinch
	if from != Vector3.INF:
		_hurt_from = from
		_hurt_at = now
		_known_enemy = from


## The current or last engagement, for a suite: when the target was first seen, when the bot
## could first fire, when it first did, and how far off the target its view was then.
func engagement() -> Dictionary:
	return {
		"target": target_id,
		"seen_at": _seen_at,
		"react_at": _react_at,
		"first_shot_at": _first_shot_at,
		"first_shot_error_deg": _first_shot_error,
		"aim_error_deg": _error_deg(_now if not is_nan(_now) else 0.0, settings.profile),
	}


# --- Seeing ---------------------------------------------------------------------

func _perceive(me: DotBotContact, all: Array, world: DotBotWorld, p: DotBotProfile, now: float) -> DotBotContact:
	var eye := me.eye()
	var forward := DotBotIntent.direction(_yaw, _pitch)
	var half := p.fov * 0.5
	var current: DotBotContact = null
	var best: DotBotContact = null
	var best_score := INF
	var best_off := 0.0
	var current_off := 0.0

	for item in all:
		if not (item is DotBotContact):
			continue
		var c := item as DotBotContact
		if not c.alive and c.id == target_id and _visible:
			# Killed, by this bot or somebody else, in plain view: a person moves on, and does
			# not stand pre-aiming the body for the next four seconds.
			_forget_target()
			continue
		if not c.alive or not me.is_enemy(c):
			continue
		var to := c.aim_point() - eye
		var d := to.length()
		if d > p.sight:
			continue
		var off := rad_to_deg(forward.angle_to(to)) if d > 0.01 else 0.0
		# Somebody the bot is already fighting stays seen while it turns after them; anybody
		# else has to be inside the cone, or close enough to be felt.
		var tracking := _visible and c.id == target_id and off < 90.0
		if off > half and d > CLOSE_NOTICE and not tracking:
			continue
		if p.through_walls < 0.5 and world != null:
			if not world.line_of_sight(eye, c.aim_point()) and not world.line_of_sight(eye, c.eye()):
				continue
		var score := d * (1.0 + off / 60.0)
		if c.id == target_id and _visible:
			current = c
			current_off = off
		if score < best_score:
			best_score = score
			best = c
			best_off = off

	var chosen := current if current != null else best
	var chosen_off := current_off if current != null else best_off

	if chosen == null:
		if _visible:
			_lose(p, now)
		return null

	if chosen.id != target_id or not _visible:
		_acquire(chosen, chosen_off, p, now)

	_visible = true
	target_id = chosen.id
	_last_seen_pos = chosen.position
	_last_seen_vel = chosen.velocity
	_last_seen_at = now
	_known_enemy = chosen.position
	return chosen


func _acquire(c: DotBotContact, off: float, p: DotBotProfile, now: float) -> void:
	var jitter := 0.85 + 0.3 * _rng.next_unit()
	# The same target back within a moment, where the bot was already looking for it: a held
	# angle or a re-peek, and a person is quicker at that than at somebody new.
	var resumed := c.id == target_id and now - _last_seen_at <= minf(p.memory, 1.5)

	if resumed:
		_react_at = now + p.reaction * jitter * 0.5
	else:
		_react_at = now + p.reaction * jitter + p.notice * clampf(off / 90.0, 0.0, 2.0)
		_engaged_at = now
		_seen_at = now
		_first_shot_at = NAN
		_first_shot_error = NAN
		_err_mag0 = p.aim_error * (0.75 + 0.5 * _rng.next_unit())
		_err_angle = _rng.next_unit() * TAU
		_err_spin = (0.6 + _rng.next_unit()) * (1.0 if _rng.next_unit() < 0.5 else -1.0)
		_roll_stop = _rng.next_unit() < p.stop_to_shoot
		_roll_crouch = _rng.next_unit() < p.crouch
		_roll_cover = _rng.next_unit() < p.cover
		_want_prev = Vector2(NAN, NAN)
		DotLog.trace(CHANNEL, "bot acquires a target", {"bot": id, "target": c.id, "off_deg": snappedf(off, 0.1)})


func _lose(p: DotBotProfile, now: float) -> void:
	_visible = false
	_lost_at = now
	_in_burst = false
	_peeking = _rng.next_unit() < p.peek
	_chase_lost = _rng.next_unit() < p.aggression
	_grenade_ready = _rng.next_unit() < p.grenades


func _forget_target() -> void:
	target_id = -1
	_visible = false
	_last_seen_pos = Vector3.INF
	_last_seen_at = -INF
	_in_burst = false
	_want_prev = Vector2(NAN, NAN)


# --- Hearing --------------------------------------------------------------------

func _hear(me: DotBotContact, all: Array, world: DotBotWorld, p: DotBotProfile, now: float) -> void:
	var heard := world.sounds_after(_heard_seq, now)
	_heard_seq = world.last_sound()
	for s in heard:
		var source := int(s.get("source", 0))
		if source == me.id:
			continue
		var who := DotBotWorld.find(all, source)
		if who != null and not me.is_enemy(who):
			continue
		var at: Vector3 = s.get("position", Vector3.INF)
		if at == Vector3.INF:
			continue
		var d := me.position.distance_to(at)
		if d > p.hearing * float(s.get("loudness", 1.0)):
			continue
		# A sound says roughly where, never exactly: the further, the vaguer.
		var spread := d * 0.08
		_heard_pos = at + Vector3((_rng.next_unit() - 0.5) * 2.0 * spread, 0.0, (_rng.next_unit() - 0.5) * 2.0 * spread)
		_heard_at = now
		_chase_sound = _rng.next_unit() < p.aggression
		_known_enemy = _heard_pos


# --- Doing ----------------------------------------------------------------------

func _fight(me: DotBotContact, c: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	var eye := me.eye()
	# Trailing a moving target by what the bot does not predict, leading it by what it does
	# for a weapon that is not instant.
	var aim := c.aim_point() - c.velocity * (1.0 - p.prediction) * TRACK_LAG
	var speed := world.projectile_speed(me) if world != null else 0.0
	if speed > 0.0:
		aim += c.velocity * (eye.distance_to(aim) / speed) * p.prediction

	var want := _angles_to(eye, aim)
	_err_angle += _err_spin * dt
	var e := _error_deg(now, p) * (0.55 + 0.45 * sin(_err_angle * 1.7 + 0.3))
	want += Vector2(e * cos(_err_angle), e * sin(_err_angle) * 0.6)
	_turn_toward(want, p, dt)

	var flat := Vector2(c.position.x - me.position.x, c.position.z - me.position.z)
	var dist := flat.length()
	var on_aim := _angle_between(Vector2(_yaw, _pitch), want) <= p.fire_cone
	var can := now >= _react_at and on_aim and dist <= p.max_range

	var trigger := false
	if can and dist > p.burst_range:
		if not _in_burst and now >= _pause_until:
			_in_burst = true
			_burst_until = now + p.burst * (0.8 + 0.4 * _rng.next_unit())
		if _in_burst and now >= _burst_until:
			_in_burst = false
			_pause_until = now + p.burst_pause * (0.8 + 0.4 * _rng.next_unit())
		trigger = _in_burst
	elif can:
		trigger = true
		_in_burst = false
	else:
		_in_burst = false

	out.fire = trigger
	if trigger and is_nan(_first_shot_at):
		_first_shot_at = now
		_first_shot_error = rad_to_deg(DotBotIntent.direction(_yaw, _pitch).angle_to(c.aim_point() - eye))

	# Distance and strafing.
	var dir := flat / dist if dist > 0.01 else Vector2(0.0, -1.0)
	var forward := 0.0
	if dist > p.range * 1.3:
		forward = 1.0
	elif dist < p.range * 0.7:
		forward = -0.7

	var retreat := _roll_cover and me.health < RETREAT_HEALTH
	if retreat:
		forward = -1.0
	out.state = &"retreat" if retreat else &"fight"

	if now >= _strafe_until:
		_strafe = (1.0 if _rng.next_unit() < 0.5 else -1.0) if _rng.next_unit() < p.strafe else 0.0
		_strafe_until = now + p.strafe_time * (0.5 + _rng.next_unit())
	var side := _strafe

	var long_burst := trigger and dist > p.burst_range * 0.6
	if long_burst and _roll_stop and not retreat:
		forward = 0.0
		side = 0.0
	out.crouch = trigger and _roll_crouch and dist > p.burst_range and not retreat
	if out.crouch:
		side = 0.0
	if not out.crouch and dist < p.burst_range and dt > 0.0 and _rng.next_unit() < p.jump * dt:
		out.jump = true

	_set_move(out, dir * forward + Vector2(-dir.y, dir.x) * side)


func _search(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"search"
	var since := now - _lost_at
	# Where it went, as far as the bot can guess: along the way it was moving, for a moment.
	var guess := _last_seen_pos + _last_seen_vel * minf(since, 1.0) * p.prediction * 0.5
	var flat := Vector2(guess.x - me.position.x, guess.z - me.position.z)
	var dist := flat.length()

	if _grenade_ready and since >= 0.4 and since <= 3.0 and dist >= 6.0 and dist <= 25.0:
		# Lobbed: a little above the spot, so it carries.
		_turn_toward(_angles_to(me.eye(), guess + Vector3.UP * (1.0 + dist * 0.15)), p, dt)
		out.throw = true
		_grenade_ready = false
		return

	if dist < 1.5:
		_last_seen_pos = Vector3.INF
		return

	var dir := flat / dist if dist > 0.01 else Vector2.ZERO
	if _peeking:
		# Pre-aimed at the corner, shuffling in and out of it.
		_turn_toward(_angles_to(me.eye(), guess + Vector3.UP * 1.25), p, dt)
		var side := 1.0 if fmod(since, 1.2) < 0.6 else -1.0
		_set_move(out, dir * (0.6 if _chase_lost else 0.0) + Vector2(-dir.y, dir.x) * side * 0.8)
	elif _chase_lost:
		_turn_toward(_angles_to(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y)), p, dt)
		_set_move(out, dir)
	else:
		_turn_toward(_angles_to(me.eye(), guess + Vector3.UP * 1.25), p, dt)


func _listen(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"listen"
	var at := _hurt_from if _hurt_at >= _heard_at else _heard_pos
	if at == Vector3.INF:
		return
	_turn_toward(_angles_to(me.eye(), at + Vector3.UP * 1.25), p, dt)
	var flat := Vector2(at.x - me.position.x, at.z - me.position.z)
	if (_chase_sound or _hurt_at >= _heard_at) and flat.length() > 2.0:
		_set_move(out, flat.normalized())
	elif flat.length() <= 2.0:
		_heard_at = -INF
		_hurt_at = -INF


func _roam(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"roam"
	var here := Vector2(me.position.x, me.position.z)

	if _waypoint == Vector3.INF or here.distance_to(Vector2(_waypoint.x, _waypoint.z)) < 2.0:
		_waypoint = _pick_waypoint(me, world, p)

	if _waypoint == Vector3.INF:
		# Nowhere to go: look about.
		_turn_toward(Vector2(_yaw + 40.0 * dt, 0.0), p, dt)
		return

	var flat := Vector2(_waypoint.x, _waypoint.z) - here
	var dir := flat.normalized() if flat.length() > 0.01 else Vector2.ZERO
	# Looking where it walks, with the glance to either side a person checking corners has.
	var look := _angles_to(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y))
	look.x += 25.0 * sin(now * 0.8 + float(id % 97))
	look.y = 0.0
	_turn_toward(look, p, dt)
	_set_move(out, dir)

	# Stuck against something: hop, and go somewhere else.
	if now - _stuck_at >= 1.5:
		if _stuck_from != Vector3.INF and me.position.distance_to(_stuck_from) < 0.75:
			out.jump = true
			_waypoint = Vector3.INF
		_stuck_at = now
		_stuck_from = me.position


func _pick_waypoint(me: DotBotContact, world: DotBotWorld, p: DotBotProfile) -> Vector3:
	var points := world.waypoints() if world != null else PackedVector3Array()
	var far: Array[Vector3] = []
	for point in points:
		if point.distance_to(me.position) > 3.0:
			far.append(point)
	if far.is_empty():
		return Vector3.INF
	if _known_enemy != Vector3.INF and _rng.next_unit() < p.map_knowledge:
		var best := far[0]
		for point in far:
			if point.distance_to(_known_enemy) < best.distance_to(_known_enemy):
				best = point
		_known_enemy = Vector3.INF
		return best
	return far[_rng.next_range_i(0, far.size() - 1)]


# --- The view -------------------------------------------------------------------

## Degrees of aim error now: the opening error halving every aim_settle seconds down to the
## floor, plus whatever being hit added.
func _error_deg(now: float, p: DotBotProfile) -> float:
	var age := maxf(now - _engaged_at, 0.0) if _engaged_at > -INF else 0.0
	var settled := p.aim_floor + maxf(_err_mag0 - p.aim_floor, 0.0) * pow(0.5, age / maxf(p.aim_settle, 0.01))
	return settled + _flinch


## Turns the view toward [param want] (yaw, pitch): the target's own motion carried as far as
## prediction lets it, the rest closed smoothly, and the whole step no faster than turn_rate.
func _turn_toward(want: Vector2, p: DotBotProfile, dt: float) -> void:
	if dt <= 0.0:
		_want_prev = want
		return
	var carry := Vector2.ZERO
	if not is_nan(_want_prev.x):
		# Everybody follows at least half of a target's motion by eye; prediction is the rest.
		carry = Vector2(wrapf(want.x - _want_prev.x, -180.0, 180.0), want.y - _want_prev.y) * (0.5 + 0.5 * p.prediction)
	_want_prev = want

	var diff := Vector2(wrapf(want.x - _yaw, -180.0, 180.0), want.y - _pitch)
	var k := clampf(p.turn_smooth * dt * 12.0, 0.0, 1.0)
	var step := carry + (diff - carry) * k
	if step.length() > diff.length():
		step = diff
	var limit := p.turn_rate * dt
	if step.length() > limit:
		step = step.normalized() * limit
	_yaw = wrapf(_yaw + step.x, -180.0, 180.0)
	_pitch = clampf(_pitch + step.y, -85.0, 85.0)


func _set_move(out: DotBotIntent, world_dir: Vector2) -> void:
	var y := deg_to_rad(_yaw)
	var forward := Vector2(-sin(y), -cos(y))
	var right := Vector2(cos(y), -sin(y))
	out.move = Vector2(world_dir.dot(right), world_dir.dot(forward)).limit_length(1.0)


## (yaw, pitch) in command degrees from [param from] toward [param to].
static func _angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := to - from
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length())))


static func _angle_between(a: Vector2, b: Vector2) -> float:
	return rad_to_deg(DotBotIntent.direction(a.x, a.y).angle_to(DotBotIntent.direction(b.x, b.y)))


func describe() -> Dictionary:
	return {
		"id": id,
		"difficulty": settings.profile.preset_name,
		"state": last.state if last != null else &"",
		"target": target_id,
		"visible": _visible,
		"yaw": snappedf(_yaw, 0.1) if not is_nan(_yaw) else NAN,
		"aim_error_deg": snappedf(_error_deg(_now if not is_nan(_now) else 0.0, settings.profile), 0.01),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	for key in d:
		out.append("%s: %s" % [key, str(d[key])])
	return out
