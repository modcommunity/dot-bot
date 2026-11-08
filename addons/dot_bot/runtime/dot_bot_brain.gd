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
## The first four are [DotBotAim], which a game with decisions of its own uses by itself.
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

## A hunting bot heads for the place nearest its prey, or the prey itself if no place is this close.
const HUNT_PLACE_NEAR := 6.0

const CHANNEL := "dot.bot"

## Within this distance a body is noticed whatever way the bot faces: somebody touching you.
const CLOSE_NOTICE := 2.0

## Health fraction under which a bot that rolled [member DotBotProfile.cover] backs out.
const RETREAT_HEALTH := 0.35
## Seconds a bot may fight within [constant STALE_MOVE] metres of one spot, against anybody, before it pushes in.
const STALE_FIGHT := 8.0
## How far a fighting bot has to get from where it stood for its fight to count as moving, metres.
const STALE_MOVE := 3.0
## How close a pushing bot walks in, metres.
const STALE_CLOSE := 3.0

## Seconds a bot that is not going after a sound or a lost target spends looking toward it.
const GLANCE := 1.2

## How long a line-of-sight answer for one target is reused, seconds. Sight is the dearest part of
## a tick (up to two ray casts per enemy in the cone), and a person's eyes do not change their
## mind about a doorway in 40 ms either.
const SIGHT_REUSE := 0.045

## Whether a bot that sees its target tests that body alone before scanning every body (the same
## choice either way); a suite turns it off to compare.
static var target_first: bool = true
var _one: Array = [null]

## Longest gap between thinks that is integrated as one step, seconds.
const MAX_STEP := 0.25

## Metres from a route's corner at which it counts as passed.
const CORNER := 1.0

var id: int = 0
var settings: DotBotSettings = null

## The view, the aim error, the reaction and the trigger.
var aim: DotBotAim = null

## The latest intent, for describe().
var last: DotBotIntent = null

# The target, as perceived.
var target_id: int = -1
var _visible: bool = false

## Per target id: [time asked, answer] of the last line-of-sight test, see [constant SIGHT_REUSE].
var _sight_cache: Dictionary = {}
var _roll_stop: bool = false
var _roll_crouch: bool = false
var _roll_cover: bool = false

## Slide, wall run and the rest; the scenario and the target's height over the bot are set by whichever of fight, search, listen or roam ran this tick.
var tricks := DotBotTricks.new()
var _scene: StringName = &"roam"
var _scene_up: float = 0.0

var _last_seen_pos: Vector3 = Vector3.INF
var _last_seen_vel: Vector3 = Vector3.ZERO
var _last_seen_at: float = -INF
var _lost_at: float = -INF
var _peeking: bool = false
var _chase_lost: bool = false
var _grenade_ready: bool = false
## Fetching a better weapon from the floor; see [DotBotPickup].
var pickup := DotBotPickup.new()
## The job in a flag mode, planned from [member DotBotWorld.objective]; idle without one.
var goal: DotBotGoal = null
## The cloned policy, or null; it drives this bot only when [method DotBotPolicy.active] says so (`bot_policy` above 0, a passing gate for the map).
var policy: DotBotPolicy = null

# Sound and pain.
var _heard_pos: Vector3 = Vector3.INF
var _heard_at: float = -INF
var _chase_sound: bool = false
var _heard_seq: int = 0
var _hurt_from: Vector3 = Vector3.INF
var _hurt_at: float = -INF
var _hurt_pending_at: float = INF
var _hurt_pending_from: Vector3 = Vector3.INF
var _known_enemy: Vector3 = Vector3.INF
var _blind_until: float = -INF

# Movement.
var _strafe: float = 0.0
var _strafe_until: float = -INF
var _strafe_eased: float = 0.0
var _hesitate_until: float = -INF
# Where the bot has been fighting since when, for a standoff that never moves; reset by a pause in the fighting.
var _fight_spot: Vector3 = Vector3.INF
var _fight_since: float = -INF
var _fight_last: float = -INF
var _glance_next: float = 0.0
var _glance_until: float = -INF
var _glance_off: float = 0.0
var _waypoint: Vector3 = Vector3.INF
# The world's route to where the bot is walking, corner by corner, and the goal it was asked for.
var _route: PackedVector3Array = PackedVector3Array()
# Per corner of _route, the ride edge that starts there, or -1.
var _route_rides: PackedInt32Array = PackedInt32Array()
var _route_goal: Vector3 = Vector3.INF
# The ride a corner just reached, for this tick's intent.
var _ride_reached: int = -1
# The ladder being climbed, or null.
var _climb: DotBotClimb = null
var _unstick: DotBotUnstick = null

var _now: float = NAN
var _was_alive: bool = true
var _rng: DotRandomStream = null
var _fight_io := PackedFloat64Array()


func _init(p_id: int = 0, p_settings: DotBotSettings = null) -> void:
	id = p_id
	settings = p_settings if p_settings != null else DotBotSettings.new()
	aim = DotBotAim.new(p_id, settings)
	_rng = DotRandomStream.new(p_id).stream(&"dot_bot")
	aim._set_brain_key(_rng._key)
	_unstick = DotBotUnstick.new(_rng)
	goal = DotBotGoal.new(p_id)


## What this bot does this tick.
func think(me: DotBotContact, world: DotBotWorld, now: float) -> DotBotIntent:
	var p := settings.profile
	var dt := 0.0 if is_nan(_now) else clampf(now - _now, 0.0, MAX_STEP)
	_now = now
	var out := DotBotIntent.new()

	if me == null or not me.alive:
		_was_alive = false
		_forget_target()
		tricks.reset()
		out.state = &"dead"
		out.yaw = aim.yaw
		out.pitch = aim.pitch
		last = out
		return out

	if not _was_alive:
		# A respawn: a new life starts with no target, no plan and the view the spawn gave.
		_was_alive = true
		_forget_target()
		_waypoint = Vector3.INF
		_route_goal = Vector3.INF
		_ride_reached = -1
		_climb = null
		_heard_at = -INF
		_hurt_at = -INF
		_hurt_pending_at = INF
		goal.reset()

	aim.view_from(me.view_yaw, me.view_pitch)

	if now >= _hurt_pending_at:
		# The shooter is only noticed a moment after the hit: pain first, then the turn.
		_hurt_from = _hurt_pending_from
		_hurt_at = now
		_known_enemy = _hurt_pending_from
		_hurt_pending_at = INF

	if world != null:
		world.prune_sight_blockers(now)
	var all := world.contacts() if world != null else []
	var seen := _perceive(me, all, world, p, now)
	if world != null:
		_hear(me, all, world, p, now)
		if world.objective != null and goal.due(now):
			goal.plan(me, world.objective, world, p, _rng, now)
	# A carrier runs home and a defender keeps to its post rather than chase what it lost.
	var tethered := goal.urgent or goal.strays(me.position)

	_scene = &"roam"
	_scene_up = 0.0
	if seen != null or not _quiet(now, p):
		pickup.cancel()
	if seen != null:
		_fight(me, seen, world, p, now, dt, out)
	elif not tethered and _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		_search(me, p, now, dt, out)
	elif not tethered and maxf(_heard_at, _hurt_at) > -INF and now - maxf(_heard_at, _hurt_at) <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at):
		_listen(me, world, p, now, dt, out)
	else:
		_roam(me, world, p, now, dt, out)

	out.yaw = aim.yaw
	out.pitch = aim.pitch
	tricks.apply(me, world, p, _rng, _scene, _scene_up, aim.yaw, now, dt, out)
	out.target_id = target_id if _visible else -1
	if policy != null and _climb == null and _ride_reached < 0 and policy.active(p, id):
		policy.apply(me, world, p, dt, out)
		# The view stays the brain's: its aim carries on from where the policy turned it.
		aim.yaw = out.yaw
		aim.pitch = out.pitch
	if _climb != null:
		_climb_step(me, now, out)
		_unstick.reset(me.position, now)
	else:
		_free_if_stuck(me, world, now, out)
	out.ride = _ride_reached
	_ride_reached = -1
	last = out
	return out


## The game's rider is done with a ride ([member DotBotIntent.ride]): [param arrived] or not, the
## route is asked for again from where the bot is now, because a ride lands anywhere on the far
## platform (or, failing, wherever the pit sent it).
func ride_ended(_arrived: bool) -> void:
	_route_goal = Vector3.INF
	_route = PackedVector3Array()
	_route_rides = PackedInt32Array()
	_unstick.reset()


## How long a lost target or a sound holds the bot's attention: its whole memory when it is
## going after it or re-peeking, and a glance otherwise. A bot that stands staring at a wall
## for four seconds because it heard a shot behind it reads as stuck, not as cautious.
func _hold_time(p: DotBotProfile, committed: bool) -> float:
	return p.memory if committed else minf(p.memory, GLANCE)


## Being hit. [param from] is where the shot came from (INF when unknown).
func hurt(from: Vector3, now: float) -> void:
	aim.hurt()
	if from != Vector3.INF and settings.profile.hurt_delay > 0.0:
		_hurt_pending_from = from
		_hurt_pending_at = now + settings.profile.hurt_delay * (0.6 + 0.8 * _rng.next_unit())
	elif from != Vector3.INF:
		_hurt_from = from
		_hurt_at = now
		_known_enemy = from


## Flashed: sees nothing for [param seconds] (hearing and pain still work). [param from] is where the
## flash went off, so the bot turns toward it afterwards (INF when unknown).
func blind_for(now: float, seconds: float, from: Vector3 = Vector3.INF) -> void:
	_blind_until = maxf(_blind_until, now + seconds)
	if from != Vector3.INF:
		_known_enemy = from


func is_blind(now: float) -> bool:
	return now < _blind_until


## The current or last engagement, for a suite: when the target was first seen, when the bot
## could first fire, when it first did, and how far off the target its view was then.
func engagement() -> Dictionary:
	var out := aim.engagement()
	out["aim_error_deg"] = aim.error_deg(_now if not is_nan(_now) else 0.0)
	return out


# --- Seeing ---------------------------------------------------------------------

func _perceive(me: DotBotContact, all: Array, world: DotBotWorld, p: DotBotProfile, now: float) -> DotBotContact:
	if now < _blind_until:
		if _visible:
			_lose(p, now)
		return null
	var eye := me.eye()
	var forward := DotBotAim.direction(aim.yaw, aim.pitch)
	var half := p.fov * 0.5
	var current: DotBotContact = null
	var best: DotBotContact = null
	var best_score := INF
	var through := p.through_walls >= 0.5 or world == null
	# Candidates inside range and cone come first; the sight test is the dear part, so it is
	# asked of the current target and then of the best score only until one is seen.
	var scores := PackedFloat32Array()
	# A bot that still sees its target keeps it whoever else is in view, so the target alone is
	# tested first and the scan over every body runs only when that fails (most thinks of a fight).
	if target_first and _visible:
		var held := world.contact_of(all, target_id) if world != null else DotBotWorld.find(all, target_id)
		if held != null and held.alive:
			_one[0] = held
			if not _candidates(me, _one, p, eye, forward, half, scores).is_empty() and (through or _sees(world, eye, held, now)):
				current = held
			_one[0] = null
			scores.clear()
	var cand: Array[DotBotContact] = []
	if current == null:
		var senses := world.senses(all) if world != null else null
		cand = _candidates_native(senses, world, me, p, eye, forward, half, scores) if senses != null else _candidates(me, all, p, eye, forward, half, scores)
		if _visible:
			for i in cand.size():
				if cand[i].id == target_id:
					if through or _sees(world, eye, cand[i], now):
						current = cand[i]
					scores[i] = INF
					break
	if current == null:
		while true:
			var bi := -1
			best_score = INF
			for i in cand.size():
				if scores[i] < best_score:
					best_score = scores[i]
					bi = i
			if bi < 0:
				break
			if through or _sees(world, eye, cand[bi], now):
				best = cand[bi]
				break
			scores[bi] = INF

	var chosen := current if current != null else best

	if chosen == null:
		if _visible:
			_lose(p, now)
		return null

	if aim.engage(chosen.id, eye, chosen.aim_point(), now):
		# A new engagement: how this fight will go, rolled once.
		_roll_stop = _rng.next_unit() < p.stop_to_shoot
		_roll_crouch = _rng.next_unit() < p.crouch
		_roll_cover = _rng.next_unit() < p.cover
		if p.hesitate > 0.0:
			_hesitate_until = now + p.hesitate * (0.3 + 0.7 * _rng.next_unit())
		DotLog.trace(CHANNEL, "bot acquires a target", {"bot": id, "target": chosen.id})

	_visible = true
	target_id = chosen.id
	_last_seen_pos = chosen.position
	_last_seen_vel = chosen.velocity
	_last_seen_at = now
	_known_enemy = chosen.position
	return chosen


## Enemies inside range and cone (or already being fought), appended to the result with their closeness score in [param scores].
func _candidates(me: DotBotContact, all: Array, p: DotBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[DotBotContact]:
	var cand: Array[DotBotContact] = []
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
		cand.append(c)
		scores.append(d * (1.0 + off / 60.0))
	return cand


## [method _candidates] by dot-sim's native scan over the tick's packed bodies: the same list, scores and forgetting.
func _candidates_native(senses: Object, world: DotBotWorld, me: DotBotContact, p: DotBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[DotBotContact]:
	var cand: Array[DotBotContact] = []
	var idx: PackedInt32Array = senses.call(&"candidates", me.id, me.team, eye, forward, half, p.sight, CLOSE_NOTICE, target_id, _visible)
	if senses.call(&"target_dead"):
		_forget_target()
	if idx.is_empty():
		return cand
	var list := world.sensed()
	for i in idx:
		cand.append(list[i])
	scores.append_array(senses.call(&"scores"))
	return cand


## Whether [param c] is in line of sight from [param eye]: the chest or the head, reused for [constant SIGHT_REUSE].
func _sees(world: DotBotWorld, eye: Vector3, c: DotBotContact, now: float) -> bool:
	var stamp := world.sight_stamp()
	var held: Variant = _sight_cache.get(c.id)
	if not (held is Array):
		var first := world.line_of_sight(eye, c.aim_point()) or world.line_of_sight(eye, c.eye())
		_sight_cache[c.id] = [now, first, stamp]
		return first
	var row := held as Array
	var at: float = row[0]
	if row[2] == stamp and now >= at and now - at < SIGHT_REUSE:
		return row[1]
	var seen := world.line_of_sight(eye, c.aim_point()) or world.line_of_sight(eye, c.eye())
	# The row is this brain's own: written in place, a sight test allocates nothing after the first.
	row[0] = now
	row[1] = seen
	row[2] = stamp
	return seen


func _lose(p: DotBotProfile, now: float) -> void:
	_visible = false
	_lost_at = now
	aim.release()
	_peeking = _rng.next_unit() < p.peek
	_chase_lost = _rng.next_unit() < p.aggression
	_grenade_ready = _rng.next_unit() < p.grenades


func _forget_target() -> void:
	target_id = -1
	_visible = false
	_last_seen_pos = Vector3.INF
	_last_seen_at = -INF
	aim.forget()


# --- Hearing --------------------------------------------------------------------

func _hear(me: DotBotContact, all: Array, world: DotBotWorld, p: DotBotProfile, now: float) -> void:
	var newest := world.last_sound()
	if newest == _heard_seq:
		return
	var heard := world.sounds_after(_heard_seq, now)
	_heard_seq = newest
	var my_id := me.id
	var here := me.position
	var reach := p.hearing
	for s in heard:
		var source := int(s.get("source", 0))
		if source == my_id:
			continue
		var at: Vector3 = s.get("position", Vector3.INF)
		if at == Vector3.INF:
			continue
		var d := here.distance_to(at)
		if d > reach * float(s.get("loudness", 1.0)):
			continue
		# Asked last: most sounds are out of earshot, and whose they are is the dear question.
		var who := world.contact_of(all, source)
		if who != null and not me.is_enemy(who):
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
	var speed := world.projectile_speed(me) if world != null else 0.0
	if aim._n != null and not aim.aim_solver.is_valid() and _fight_native(me, c, eye, speed, p, now, dt, out):
		return
	var _view := aim.track(eye, c.aim_point(), c.velocity, now, dt, speed)

	var flat := Vector2(c.position.x - me.position.x, c.position.z - me.position.z)
	var dist := flat.length()
	var trigger := aim.trigger(now, dist)
	out.fire = trigger
	if trigger:
		aim.note_shot(eye, c.aim_point(), now)

	# Distance and strafing.
	var dir := flat / dist if dist > 0.01 else Vector2(0.0, -1.0)
	var forward := 0.0
	if dist > p.range * 1.3:
		forward = 1.0
	elif dist < p.range * 0.7:
		forward = -0.7

	var retreat := _roll_cover and me.health < RETREAT_HEALTH
	if now - _fight_last > 2.0 or me.position.distance_to(_fight_spot) > STALE_MOVE:
		_fight_spot = me.position
		_fight_since = now
	_fight_last = now
	# A standoff nobody wins, one target or several: the bot walks in instead of trading misses from one spot.
	var push := not retreat and dist > STALE_CLOSE and now - _fight_since > STALE_FIGHT
	if push:
		forward = 1.0
	if retreat:
		forward = -1.0
	out.state = &"retreat" if retreat else &"fight"
	_scene = &"flee" if retreat else (&"close" if dist > p.range * 1.3 else &"fight")
	_scene_up = c.position.y - me.position.y

	if now >= _strafe_until:
		_strafe = (1.0 if _rng.next_unit() < 0.5 else -1.0) if _rng.next_unit() < p.strafe else 0.0
		if p.strafe_jitter > 0.0:
			# Uneven lengths (many short, a few long) and now and then a stop to aim.
			var u := _rng.next_unit()
			_strafe_until = now + p.strafe_time * lerpf(0.5 + _rng.next_unit(), 0.2 + 2.0 * u * u, p.strafe_jitter)
			if _strafe != 0.0 and _rng.next_unit() < 0.25 * p.strafe_jitter:
				_strafe = 0.0
		else:
			_strafe_until = now + p.strafe_time * (0.5 + _rng.next_unit())
	var side := _strafe
	if p.strafe_jitter > 0.0:
		# A body does not reverse at once: it brakes through zero.
		_strafe_eased = move_toward(_strafe_eased, _strafe, dt * 5.0)
		side = _strafe_eased
	if now < _hesitate_until:
		forward = 0.0
		side = 0.0

	var long_burst := trigger and dist > p.burst_range * 0.6
	if long_burst and _roll_stop and not retreat and not push:
		forward = 0.0
		side = 0.0
	out.crouch = trigger and _roll_crouch and dist > p.burst_range and not retreat
	if out.crouch:
		side = 0.0
	if not out.crouch and dist < p.burst_range and dt > 0.0 and _rng.next_unit() < p.jump * dt:
		out.jump = true

	if goal.urgent and goal.dest != Vector3.INF:
		# A flag carrier shoots on the move and keeps running home.
		out.crouch = false
		_set_move(out, _toward(me, world, goal.dest) + Vector2(-dir.y, dir.x) * side * 0.35)
		return
	_set_move(out, dir * forward + Vector2(-dir.y, dir.x) * side)


## [method _fight] in one call to the aim's native mind: the same arithmetic, rolls and random
## draws, so the intent, the aim and the stream come back as the script would have left them.
## False (the script then runs) if the mind refused the call.
func _fight_native(me: DotBotContact, c: DotBotContact, eye: Vector3, speed: float, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> bool:
	var io := _fight_io
	_fight_io = PackedFloat64Array()  # one owner, so the writes below do not copy
	if io.size() != 35:
		io.resize(35)
	io[0] = aim.yaw
	io[1] = aim.pitch
	io[2] = aim.react_at
	io[3] = aim.engaged_at
	io[4] = aim.first_shot_at
	io[5] = aim.first_shot_error
	io[6] = _rng._counter
	io[7] = now
	io[8] = dt
	io[9] = speed
	io[10] = me.health
	io[11] = 1.0 if _roll_stop else 0.0
	io[12] = 1.0 if _roll_crouch else 0.0
	io[13] = 1.0 if _roll_cover else 0.0
	io[14] = _hesitate_until
	io[15] = _strafe
	io[16] = _strafe_until
	io[17] = _strafe_eased
	io = aim._pack_profile(io, 18)
	io[30] = p.range
	io[31] = p.strafe
	io[32] = p.strafe_jitter
	io[33] = p.strafe_time
	io[34] = p.jump
	_fight_io = io
	var r: PackedFloat64Array = aim._n.fight(eye, c.aim_point(), c.velocity, me.position, c.position, io)
	if r.size() < 15:
		aim._demote()
		return false
	aim.yaw = r[0]
	aim.pitch = r[1]
	aim.first_shot_at = r[2]
	aim.first_shot_error = r[3]
	_rng._counter = int(r[4])
	out.fire = r[5] != 0.0
	out.crouch = r[6] != 0.0
	out.jump = r[7] != 0.0
	out.move = Vector2(r[8], r[9])
	var retreat := r[11] != 0.0
	out.state = &"retreat" if retreat else &"fight"
	_scene = &"flee" if r[10] == 2.0 else (&"close" if r[10] == 1.0 else &"fight")
	_scene_up = c.position.y - me.position.y
	_strafe = r[12]
	_strafe_until = r[13]
	_strafe_eased = r[14]
	return true


func _search(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"search"
	_scene = &"cover" if _peeking else &"chase"
	var since := now - _lost_at
	# Where it went, as far as the bot can guess: along the way it was moving, for a moment.
	var guess := _last_seen_pos + _last_seen_vel * minf(since, 1.0) * p.prediction * 0.5
	var flat := Vector2(guess.x - me.position.x, guess.z - me.position.z)
	var dist := flat.length()

	if _grenade_ready and since >= 0.4 and since <= 3.0 and dist >= 6.0 and dist <= 25.0:
		# Lobbed: a little above the spot, so it carries.
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * (1.0 + dist * 0.15), dt)
		out.throw = true
		_grenade_ready = false
		return

	if dist < 1.5:
		_last_seen_pos = Vector3.INF
		return

	var dir := flat / dist if dist > 0.01 else Vector2.ZERO
	if _peeking:
		# Pre-aimed at the corner, shuffling in and out of it.
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * 1.25, dt)
		var side := 1.0 if fmod(since, 1.2) < 0.6 else -1.0
		_set_move(out, dir * (0.6 if _chase_lost else 0.0) + Vector2(-dir.y, dir.x) * side * 0.8)
	elif _chase_lost:
		var _v := aim.look_at_point(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y), dt)
		_set_move(out, dir)
	else:
		var _v := aim.look_at_point(me.eye(), guess + Vector3.UP * 1.25, dt)


func _listen(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"listen"
	_scene = &"chase" if _chase_sound else &"cover"
	var at := _hurt_from if _hurt_at >= _heard_at else _heard_pos
	if at == Vector3.INF:
		return
	var _v := aim.look_at_point(me.eye(), at + Vector3.UP * 1.25, dt)
	var flat := Vector2(at.x - me.position.x, at.z - me.position.z)
	if (_chase_sound or _hurt_at >= _heard_at) and flat.length() > 2.0:
		_set_move(out, _toward(me, world, at))
	elif flat.length() <= 2.0:
		_heard_at = -INF
		_hurt_at = -INF


func _roam(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	out.state = &"roam"
	var here := Vector2(me.position.x, me.position.z)
	if not goal.urgent and _fetch(me, world, p, now, dt, out):
		return

	if goal.dest != Vector3.INF:
		out.state = goal.kind
		if goal.arrived(me.position) and not goal.urgent:
			_hold(me, p, now, dt, out)
			return
		_walk(me, world, p, goal.dest, now, dt, out)
		return

	if _waypoint == Vector3.INF or here.distance_to(Vector2(_waypoint.x, _waypoint.z)) < 2.0:
		_waypoint = _pick_waypoint(me, world, p)

	if _waypoint == Vector3.INF:
		# Nowhere to go: look about.
		_drift(40.0, dt)
		return
	_walk(me, world, p, _waypoint, now, dt, out)


## Walks toward [param dest], looking where it goes.
func _walk(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, dest: Vector3, now: float, dt: float, out: DotBotIntent) -> void:
	var dir := _toward(me, world, dest)
	# Looking where it walks, with the glance to either side a person checking corners has.
	var look := DotBotAim.angles_to(me.eye(), me.eye() + Vector3(dir.x, 0.0, dir.y))
	look.x += 25.0 * sin(now * 0.8 + float(id % 97))
	look.y = 0.0
	if p.glance > 0.0:
		if now >= _glance_next and now >= _glance_until:
			# Turn the head to one side, hold the look, then carry on: a person checking a doorway.
			_glance_off = (1.0 if _rng.next_unit() < 0.5 else -1.0) * (35.0 + 70.0 * _rng.next_unit())
			_glance_until = now + 0.35 + 0.6 * _rng.next_unit()
			_glance_next = _glance_until + (1.5 + 4.0 * _rng.next_unit()) / (0.3 + p.glance)
		if now < _glance_until:
			look.x += _glance_off
	aim.turn_to(look, dt)
	_set_move(out, dir)


## Turns the view [param rate] deg/s on for [param dt] seconds. A thinned bot thinks every few ticks, and the
## smoothing in [method DotBotAim.turn_to] is quadratic in dt, so a long dt runs as steps of at most 1/60 s:
## the turn per elapsed second is the same however often the bot thinks (one step, as before, up to 1/60 s).
func _drift(rate: float, dt: float) -> void:
	var n := maxi(1, ceili(dt * 60.0 - 0.01))
	var sub := dt / float(n)
	for _i in n:
		aim.turn_to(Vector2(aim.yaw + rate * sub, 0.0), sub)


## At its post: stands, watching the way an enemy would come, glancing to either side.
func _hold(me: DotBotContact, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> void:
	var look := Vector2(aim.yaw, 0.0)
	if goal.face == Vector3.INF:
		_drift(30.0, dt)
		_set_move(out, Vector2.ZERO)
		return
	if goal.face != Vector3.INF:
		look = DotBotAim.angles_to(me.eye(), Vector3(goal.face.x, me.eye().y, goal.face.z))
		look.y = 0.0
		look.x += 50.0 * sin(now * 0.5 + float(id % 89)) * (0.3 + p.glance)
	aim.turn_to(look, dt)
	_set_move(out, Vector2.ZERO)


## True when a weapon on the floor has this tick: walk to it, look at it, press use near it.
func _fetch(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, dt: float, out: DotBotIntent) -> bool:
	var plan := pickup.step(me, world, p, now, true)
	if plan.is_empty():
		return false
	var at: Vector3 = plan["position"]
	out.state = &"pickup"
	var _v := aim.look_at_point(me.eye(), at + Vector3.UP * 0.2, dt)
	if bool(plan["use"]):
		out.use = true
		_set_move(out, Vector2.ZERO)
	else:
		_set_move(out, _toward(me, world, at))
	return true


## No enemy in mind: nothing seen, remembered, heard or felt lately.
func _quiet(now: float, p: DotBotProfile) -> bool:
	if _last_seen_pos != Vector3.INF and now - _last_seen_at <= _hold_time(p, _peeking or _chase_lost):
		return false
	var last_noise := maxf(_heard_at, _hurt_at)
	return not (last_noise > -INF and now - last_noise <= _hold_time(p, _chase_sound or _hurt_at >= _heard_at))


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
	# Hunting: no lead, but a body somewhere on the map; head for the place nearest the closest one.
	if _rng.next_unit() < p.map_knowledge * 0.4:
		var prey := _nearest_enemy(me, world)
		if prey != Vector3.INF:
			var near := far[0]
			for point in far:
				if point.distance_to(prey) < near.distance_to(prey):
					near = point
			# A sparse mesh leaves the nearest place far from the prey; walk at the prey then.
			return near if near.distance_to(prey) <= HUNT_PLACE_NEAR else prey
	return far[_rng.next_range_i(0, far.size() - 1)]


func _nearest_enemy(me: DotBotContact, world: DotBotWorld) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for item in world.contacts():
		var c := item as DotBotContact
		if c == null or not c.alive or not me.is_enemy(c):
			continue
		var d := c.position.distance_to(me.position)
		if d < best_d:
			best_d = d
			best = c.position
	return best


# --- Moving --------------------------------------------------------------------

## The flat direction to walk toward [param goal]: along the world's route to it when the world
## has one ([method DotBotWorld.route]), straight at it when not. The route is asked for once per
## goal and walked corner by corner; a corner within [constant CORNER] metres is passed.
func _toward(me: DotBotContact, world: DotBotWorld, goal: Vector3) -> Vector2:
	if goal != _route_goal:
		_route_goal = goal
		var detail := world.route_detail(me.position, goal) if world != null else {}
		_route = detail.get("points", PackedVector3Array())
		_route_rides = detail.get("rides", PackedInt32Array())
	var here := Vector2(me.position.x, me.position.z)
	while not _route.is_empty() and here.distance_to(Vector2(_route[0].x, _route[0].z)) < CORNER:
		# A corner that starts a ride edge: say so, and the game takes the legs from here.
		if not _route_rides.is_empty():
			var ride := _route_rides[0]
			var ladder := world.ladder(ride) if ride >= 0 and world != null else {}
			if not ladder.is_empty():
				_climb = DotBotClimb.begin(ladder, _now)
			elif ride >= 0:
				_ride_reached = ride
			_route_rides.remove_at(0)
		_route.remove_at(0)
		if _climb != null:
			break
	var at := _route[0] if not _route.is_empty() else goal
	var flat := Vector2(at.x, at.z) - here
	return flat.normalized() if flat.length() > 0.01 else Vector2.ZERO

## A bot that pushes and does not move, in any state: re-plan, hop, crouch-hop and side-step, then walk to the nearest standable point.
func _free_if_stuck(me: DotBotContact, world: DotBotWorld, now: float, out: DotBotIntent) -> void:
	# A duel strafes on the spot by design; only travelling can be stuck.
	var pushing := out.move.length() > 0.3 and out.state != &"dead" and out.state != &"fight" and out.state != &"retreat"
	if _unstick.step(me.position, pushing, now, world) == 0:
		return
	if _unstick.replan:
		_waypoint = Vector3.INF
		_route_goal = Vector3.INF
	out.jump = out.jump or _unstick.jump
	out.crouch = out.crouch or _unstick.crouch
	if _unstick.strafe != 0.0:
		out.move = Vector2(_unstick.strafe, out.move.y).limit_length(1.0)
	if _unstick.nudge_to != Vector3.INF:
		var d := Vector2(_unstick.nudge_to.x, _unstick.nudge_to.z) - Vector2(me.position.x, me.position.z)
		if d.length() > 0.01:
			_set_move(out, d.normalized())


## Overrides this tick's legs while a ladder is climbed; the view and trigger stay the brain's.
func _climb_step(me: DotBotContact, now: float, out: DotBotIntent) -> void:
	var r := _climb.step(me.position, now)
	if r["done"]:
		_end_climb()
		return
	if not is_nan(float(r["yaw"])):
		aim.view_from(float(r["yaw"]), 0.0)
	out.yaw = aim.yaw
	out.pitch = 0.0
	out.move = r["move"]
	out.jump = r["jump"]
	out.crouch = false
	out.state = &"climb"


func _end_climb() -> void:
	_climb = null
	_route_goal = Vector3.INF


func _set_move(out: DotBotIntent, world_dir: Vector2) -> void:
	var y := deg_to_rad(aim.yaw)
	var forward := Vector2(-sin(y), -cos(y))
	var right := Vector2(cos(y), -sin(y))
	out.move = Vector2(world_dir.dot(right), world_dir.dot(forward)).limit_length(1.0)


func describe() -> Dictionary:
	return {
		"id": id,
		"difficulty": settings.profile.preset_name,
		"state": last.state if last != null else &"",
		"target": target_id,
		"visible": _visible,
		"yaw": snappedf(aim.yaw, 0.1),
		"aim_error_deg": snappedf(aim.error_deg(_now if not is_nan(_now) else 0.0), 0.01),
		"role": goal.role,
		"goal": goal.kind,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var d := describe()
	for key in d:
		out.append("%s: %s" % [key, str(d[key])])
	return out
