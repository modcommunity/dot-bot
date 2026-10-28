class_name DotBotAim
extends RefCounted

## A bot's eyes and trigger finger: how it turns its view, how far off its aim is, when it may
## shoot. The part of [DotBotBrain] a game with its own decisions uses on its own.
##
## [b]Why it is separate.[/b] Most games here already decide what their bots do (a stand-in
## that revives friends, a hunter that sweeps a room, a runner that follows a course), and
## what made all of them read as machines was the same few lines: the view set straight onto
## the target every tick, a sine-wave wobble for aim error, and a trigger held from the tick
## the target appeared. This is those lines done once, read from the same
## [DotBotSettings] as the brain, so `bot_difficulty` moves every game's bots the same way:
##
## [codeblock]
## var aim := DotBotAim.new(bot_id, DotBotSettings.of(game))
## aim.view_from(state.yaw, state.pitch)                  # the view going into the tick
## if aim.engage(zombie_id, eye, chest, now):             # a new target: reaction starts
##     pass
## var view := aim.track(eye, chest, zombie_velocity, now, dt)
## command.yaw = view.x; command.pitch = view.y
## fire = aim.trigger(now, eye.distance_to(chest))        # reacted, on aim, in range, bursts
## [/codeblock]
##
## Everything is in the command's degrees: yaw 0 looks down -Z, positive turns left.

# No log channel: arithmetic over the settings. The brain logs decisions.

## Seconds of a target's velocity error that bot_track_lag turns into aim error.
const LAG_REACH := 0.15

## Seconds a bot with no prediction trails a moving target by: about how far behind a person
## tracking by eye is. bot_prediction takes it to nothing.
const TRACK_LAG := 0.08

## Seconds a flinch takes to halve.
const FLINCH_HALF_LIFE := 0.3

## Asked again for the same target within this many seconds, the engagement simply goes on: a
## caller engages every tick it sees the target, and a game ticking 20 times a second must not
## look like a new sighting each time.
const CONTINUE_WINDOW := 0.25

## Within this many seconds of losing a target, seeing it again continues the engagement:
## the error keeps settling and the reaction is halved, which is what a held angle is.
const RESUME_WINDOW := 1.5

var settings: DotBotSettings = null

## Optional `func(eye: Vector3, point: Vector3, velocity: Vector3) -> Vector3` returning the point to
## aim at (lead and drop). Unset (the default) keeps the plain aim; see [DotBotAimSolver].
var aim_solver: Callable = Callable()

## The view, command degrees. The caller syncs it with [method view_from] each tick.
var yaw: float = 0.0
var pitch: float = 0.0

## Whom it is engaged with, or -1.
var target_id: int = -1

var react_at: float = INF
var engaged_at: float = -INF
var seen_at: float = NAN
var last_seen_at: float = -INF
var first_shot_at: float = NAN
var first_shot_error: float = NAN

var _err_mag0: float = 0.0
var _err_angle: float = 0.0
var _err_spin: float = 1.0
var _over: Vector2 = Vector2.ZERO
var _vel_est: Vector3 = Vector3.INF
var _prev_gap: float = 0.0
var _flinch: float = 0.0
var _want: Vector2 = Vector2(NAN, NAN)
var _want_prev: Vector2 = Vector2(NAN, NAN)
var _in_burst: bool = false
var _burst_until: float = -INF
var _pause_until: float = -INF
var _rng: DotRandomStream = null


func _init(id: int = 0, p_settings: DotBotSettings = null) -> void:
	settings = p_settings if p_settings != null else DotBotSettings.new()
	_rng = DotRandomStream.new(id).stream(&"dot_bot_aim")


## The view going into this tick, from the body.
func view_from(p_yaw: float, p_pitch: float) -> void:
	if not is_nan(p_yaw):
		yaw = p_yaw
		pitch = p_pitch


## Commits to [param id] at [param point], seen from [param eye]. True when this starts a new
## engagement (the reaction clock starts); false when it continues the current one or resumes
## one lost within [constant RESUME_WINDOW].
func engage(id: int, eye: Vector3, point: Vector3, now: float) -> bool:
	if id == target_id and now - last_seen_at <= CONTINUE_WINDOW:
		last_seen_at = now
		return false

	var p := settings.profile
	var jitter := 0.85 + 0.3 * _rng.next_unit()
	var resumed := id == target_id and now - last_seen_at <= minf(p.memory, RESUME_WINDOW)
	var off := rad_to_deg(direction(yaw, pitch).angle_to(point - eye)) if eye.distance_to(point) > 0.01 else 0.0
	target_id = id
	last_seen_at = now
	_in_burst = false

	if resumed:
		react_at = now + p.reaction * jitter * 0.5
		return false

	if p.react_jitter > 0.0:
		# Skewed, never faster: most sightings are quick, now and then one is slow (looking elsewhere).
		var u := _rng.next_unit()
		jitter *= 1.0 + p.react_jitter * 1.2 * u * u
	react_at = now + p.reaction * jitter + p.notice * clampf(off / 90.0, 0.0, 2.0)
	engaged_at = now
	seen_at = now
	first_shot_at = NAN
	first_shot_error = NAN
	_err_mag0 = p.aim_error * (0.75 + 0.5 * _rng.next_unit())
	_err_angle = _rng.next_unit() * TAU
	_err_spin = (0.6 + _rng.next_unit()) * (1.0 if _rng.next_unit() < 0.5 else -1.0)
	_want_prev = Vector2(NAN, NAN)
	_over = Vector2.ZERO
	_prev_gap = 0.0
	_vel_est = Vector3.INF
	return true


## Lets the target go (out of sight, dead, or something else matters more).
func release() -> void:
	_in_burst = false
	_over = Vector2.ZERO
	_want = Vector2(NAN, NAN)


## Forgets the target entirely: the next sight of it is a new engagement.
func forget() -> void:
	release()
	target_id = -1
	last_seen_at = -INF
	_want_prev = Vector2(NAN, NAN)


## A hit: the aim gets worse for a moment.
func hurt() -> void:
	_flinch += settings.profile.flinch


## Turns the view onto [param point] (the target's chest, say) as the settings allow, with
## the engagement's aim error, and returns the new (yaw, pitch). [param velocity] is the
## target's; [param projectile_speed] is 0 for a hitscan weapon.
func track(eye: Vector3, point: Vector3, velocity: Vector3, now: float, dt: float, projectile_speed: float = 0.0) -> Vector2:
	var p := settings.profile
	_decay(dt)
	var aim := point - velocity * (1.0 - p.prediction) * TRACK_LAG
	if p.track_lag > 0.0:
		# The bot's idea of the target's velocity trails the real one, so a reversal (a strafe
		# turning round) is aimed with the old direction for a moment; a steady course is not.
		if _vel_est.is_finite() and dt > 0.0:
			_vel_est = _vel_est.lerp(velocity, 1.0 - exp(-dt / p.track_lag))
		else:
			_vel_est = velocity
		aim += (_vel_est - velocity) * LAG_REACH
	if aim_solver.is_valid():
		aim = aim_solver.call(eye, aim, velocity)
	elif projectile_speed > 0.0:
		aim += velocity * (eye.distance_to(aim) / projectile_speed) * p.prediction
	var want := angles_to(eye, aim)
	_err_angle += _err_spin * dt
	var e := error_deg(now) * (0.55 + 0.45 * sin(_err_angle * 1.7 + 0.3))
	want += Vector2(e * cos(_err_angle), e * sin(_err_angle) * 0.6)
	if p.overshoot > 0.0:
		want += _overshoot(want, dt)
	_want = want
	turn_to(want, dt)
	return Vector2(yaw, pitch)


## The extra offset of a flick: a sudden large gap opens an offset past the target, held while
## the view is still travelling and let go once it has arrived, so the view swings past and back.
func _overshoot(want: Vector2, dt: float) -> Vector2:
	var gap := Vector2(wrapf(want.x - yaw, -180.0, 180.0), want.y - pitch)
	var size := gap.length()
	if size > 20.0 and _prev_gap < 10.0 and _over == Vector2.ZERO:
		_over = gap.normalized() * minf(size, 90.0) * settings.profile.overshoot * (0.1 + 0.2 * _rng.next_unit())
	elif (size < 6.0 or gap.dot(_over) < 0.0) and dt > 0.0:
		_over *= pow(0.5, dt / 0.12)
		if _over.length() < 0.05:
			_over = Vector2.ZERO
	_prev_gap = size
	return _over


## Turns the view toward [param point] with no aim error (looking, not shooting).
func look_at_point(eye: Vector3, point: Vector3, dt: float) -> Vector2:
	_decay(dt)
	_want = Vector2(NAN, NAN)
	turn_to(angles_to(eye, point), dt)
	return Vector2(yaw, pitch)


## Whether the trigger is down this tick: reacted, the view on its aim (within bot_fire_cone),
## within bot_max_range, and in a burst beyond bot_burst_range. Call once a tick, after
## [method track]; [param distance] is to the target.
func trigger(now: float, distance: float) -> bool:
	var p := settings.profile
	var can := now >= react_at and on_aim() and distance <= p.max_range
	var down := false
	if can and distance > p.burst_range:
		if not _in_burst and now >= _pause_until:
			_in_burst = true
			_burst_until = now + p.burst * (0.8 + 0.4 * _rng.next_unit())
		if _in_burst and now >= _burst_until:
			_in_burst = false
			_pause_until = now + p.burst_pause * (0.8 + 0.4 * _rng.next_unit())
		down = _in_burst
	elif can:
		down = true
		_in_burst = false
	else:
		_in_burst = false
	return down


## Records a shot at [param point] from [param eye], for [method engagement].
func note_shot(eye: Vector3, point: Vector3, now: float) -> void:
	if is_nan(first_shot_at):
		first_shot_at = now
		first_shot_error = rad_to_deg(direction(yaw, pitch).angle_to(point - eye))


## Whether the view is within bot_fire_cone of where the bot means to aim.
func on_aim() -> bool:
	if is_nan(_want.x):
		return false
	return rad_to_deg(direction(yaw, pitch).angle_to(direction(_want.x, _want.y))) <= settings.profile.fire_cone


## Degrees of aim error now: the opening error halving every aim_settle seconds down to the
## floor, plus whatever being hit added.
func error_deg(now: float) -> float:
	var p := settings.profile
	var age := maxf(now - engaged_at, 0.0) if engaged_at > -INF else 0.0
	var settled := p.aim_floor + maxf(_err_mag0 - p.aim_floor, 0.0) * pow(0.5, age / maxf(p.aim_settle, 0.01))
	return settled + _flinch


## Turns the view toward [param want] (yaw, pitch): the target's own motion carried as far as
## prediction lets it, the rest closed smoothly, and the whole step no faster than turn_rate.
func turn_to(want: Vector2, dt: float) -> void:
	var p := settings.profile
	if dt <= 0.0:
		_want_prev = want
		return
	var carry := Vector2.ZERO
	if not is_nan(_want_prev.x):
		# Everybody follows at least half of a target's motion by eye; prediction is the rest.
		carry = Vector2(wrapf(want.x - _want_prev.x, -180.0, 180.0), want.y - _want_prev.y) * (0.5 + 0.5 * p.prediction)
	_want_prev = want

	var diff := Vector2(wrapf(want.x - yaw, -180.0, 180.0), want.y - pitch)
	var k := clampf(p.turn_smooth * dt * 12.0, 0.0, 1.0)
	var step := carry + (diff - carry) * k
	if step.length() > diff.length():
		step = diff
	var limit := p.turn_rate * dt
	if step.length() > limit:
		step = step.normalized() * limit
	yaw = wrapf(yaw + step.x, -180.0, 180.0)
	pitch = clampf(pitch + step.y, -85.0, 85.0)


func _decay(dt: float) -> void:
	if dt > 0.0:
		_flinch *= pow(0.5, dt / FLINCH_HALF_LIFE)


func engagement() -> Dictionary:
	return {
		"target": target_id,
		"seen_at": seen_at,
		"react_at": react_at,
		"first_shot_at": first_shot_at,
		"first_shot_error_deg": first_shot_error,
	}


## (yaw, pitch) in command degrees from [param from] toward [param to].
static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := to - from
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(atan2(d.y, Vector2(d.x, d.z).length())))


## The direction a (yaw, pitch) looks along, -Z forward at yaw 0.
static func direction(p_yaw: float, p_pitch: float) -> Vector3:
	var y := deg_to_rad(p_yaw)
	var p := deg_to_rad(p_pitch)
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))


func describe() -> Dictionary:
	return {"target": target_id, "yaw": snappedf(yaw, 0.1), "pitch": snappedf(pitch, 0.1), "aim_error_deg": snappedf(error_deg(0.0 if is_nan(seen_at) else seen_at), 0.01)}
