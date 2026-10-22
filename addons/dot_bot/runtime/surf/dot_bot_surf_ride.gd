class_name DotBotSurfRide
extends RefCounted

## One bot riding one ride edge: the legs are the surf pilot's, the view and the trigger stay the
## brain's. What a game holds per bot between [member DotBotIntent.ride] and the landing.
##
## [codeblock]
## # The brain's route reached a ride edge:
## if intent.ride >= 0 and ride == null:
##     ride = DotBotSurfRide.new().begin(edge_pilot, edge_course, sim, now_tick)
## if ride != null:
##     var status := ride.steer(bot_state, intent, now_tick)    # rewrites intent.move and its buttons
##     if status != DotBotSurfRide.RIDING:
##         brain.ride_ended(status == DotBotSurfRide.LANDED)
##         ride = null
## intent.write_move(command)
## [/codeblock]
##
## [b]Surfing while aiming.[/b] The pilot's action is a wish direction relative to the velocity,
## and in the air the motor reads nothing of the view but the wish it makes with the keys. So the
## keys are worked out for the brain's own view ([method DotBotSurfPilot.move_toward]): the bot
## looks at its target and still holds the ramp. On the ground the view also scales a backward
## key, so for the run to the ramp the view is the ride's own; it is the brain's again from the
## moment the bot leaves the ground.

# No log channel: the game says what a ride did.

const RIDING := 0
## In the course's goal: the far platform.
const LANDED := 1
## In a pit, below the course, or put somewhere else by the game (a teleport).
const FELL := 2
## Neither, for longer than the course allows.
const TIMED_OUT := 3

## A position this far from the last tick's, metres, was put there (a teleport), not ridden.
const JUMPED := 6.0

## A ride that stays within this radius, metres, off the ground for [member stall_ticks] (STALL_SECONDS) is wedged in geometry, and ends as [constant TIMED_OUT]. On the ground it may be waiting.
const STALL_RADIUS := 0.5
const STALL_SECONDS := 8.0

var pilot: DotBotSurfPilot = null
var course: DotBotSurfCourse = null
## The game's tick when the ride began, and how long it may run.
var began: int = 0
var max_ticks: int = 64 * 20
## How it ended, once it has.
var status: int = RIDING
var ticks: int = 0

## The recorded ride being played back, and the host's [code]func(action: PackedFloat32Array, state, intent)[/code] that applies a row.
var recorded: Dictionary = {}
var decode: Callable = Callable()
## The book entry this ride was picked from.
var picked: Dictionary = {}

var stall_ticks: int = 64 * 8

var _last: Vector3 = Vector3.INF
var _anchor: Vector3 = Vector3.INF
var _anchor_tick: int = 0


## Starts a ride on [param p_course] with a pilot sharing [param cache]'s rides, vetoing on
## [param sim] (null for no veto). [param seconds] is the longest the ride may take at
## [param tick_rate].
func begin(cache: DotBotSurfPilot, p_course: DotBotSurfCourse, sim: Variant, now_tick: int,
		tick_rate: float = 64.0, seconds: float = 20.0) -> DotBotSurfRide:
	pilot = DotBotSurfPilot.new().share_cache(cache)
	pilot.horizon = cache.horizon
	pilot.check_every = cache.check_every
	pilot.rolling = cache.rolling
	pilot.sim = sim
	if sim == null:
		pilot.horizon = 0
	pilot.score = p_course.score
	pilot.reset()
	course = p_course
	began = now_tick
	max_ticks = int(seconds * tick_rate)
	stall_ticks = int(STALL_SECONDS * tick_rate)
	_anchor = Vector3.INF
	status = RIDING
	ticks = 0
	return self


## One of [param key]'s saved rides from [param book], weighted by success from the bot's [param rng]; empty with none.
static func pick(book: DotBotRideBook, key: String, rng: DotRandomStream) -> Dictionary:
	return book.choose(key, rng)


## Starts the ride [param entry] (from [method pick]). A recording is played back through [param p_decode]; a seed rides as [method begin] does, on its own pilot (entry data) or [param cache].
func begin_picked(entry: Dictionary, cache: DotBotSurfPilot, p_course: DotBotSurfCourse, sim: Variant, now_tick: int,
		p_decode: Callable = Callable(), tick_rate: float = 64.0, seconds: float = 20.0) -> DotBotSurfRide:
	picked = entry
	var data: Variant = entry.get("data")
	if entry.get("source", "") == DotBotRideBook.RECORDED and data is Dictionary and p_decode.is_valid():
		begin(cache, p_course, sim, now_tick, tick_rate, seconds)
		recorded = data
		decode = p_decode
		return self
	recorded = {}
	return begin(data if data is DotBotSurfPilot else cache, p_course, sim, now_tick, tick_rate, seconds)


## This tick's legs for a bot in [param state] (its real one, after the last tick), written into
## [param intent] in place: the move for the intent's own view, jump as the action says, never
## crouch or walk (either changes the hull or the speed the rides were planned with). Returns
## [constant RIDING] or how the ride ended (and then writes nothing).
func steer(state: Variant, intent: DotBotIntent, now_tick: int) -> int:
	if status != RIDING:
		return status
	var p: Vector3 = state.position
	if _last != Vector3.INF and p.distance_to(_last) > JUMPED:
		return _end(FELL)
	_last = p
	match course.event_at(state):
		DotBotSurfCourse.EVENT_GOAL:
			return _end(LANDED)
		DotBotSurfCourse.EVENT_PIT, DotBotSurfCourse.EVENT_BELOW:
			return _end(FELL)
	if now_tick - began > max_ticks:
		return _end(TIMED_OUT)
	if _anchor == Vector3.INF or p.distance_to(_anchor) > STALL_RADIUS or (state.has_method(&"is_grounded") and state.is_grounded()):
		_anchor = p
		_anchor_tick = now_tick
	elif now_tick - _anchor_tick > stall_ticks:
		return _end(TIMED_OUT)
	if not recorded.is_empty() and (recorded["actions"] as PackedFloat32Array).size() >= int(recorded["action_size"]):
		var size: int = recorded["action_size"]
		var actions: PackedFloat32Array = recorded["actions"]
		var row := mini(ticks / int(recorded["hold"]), actions.size() / size - 1)
		decode.call(actions.slice(row * size, (row + 1) * size), state, intent)
		ticks += 1
		return RIDING
	var action := pilot.action(state)
	if DotBotSurfPilot.jumps(action) or (state.has_method(&"is_grounded") and state.is_grounded()):
		# Running to the ramp, and jumping, the view goes where the legs go: on the ground a key
		# held backward is slower, and a jump beside a wall pushes off along the view (a wall
		# jump), so either made for a view elsewhere is not the ride that was planned, and it
		# fell (game-arena's surf_ski_2, whose wall moves are on).
		intent.yaw = DotBotSurfPilot.heading_of(state, pilot.reference_yaw)
	intent.move = DotBotSurfPilot.move_toward(DotBotSurfPilot.wish_yaw(action, state, pilot.reference_yaw), intent.yaw)
	intent.jump = DotBotSurfPilot.jumps(action)
	intent.crouch = false
	intent.walk = false
	ticks += 1
	return RIDING


func _end(how: int) -> int:
	status = how
	return how


func describe() -> Dictionary:
	return {"status": ["riding", "landed", "fell", "timed out"][status], "ticks": ticks,
		"source": picked.get("source", "") if not picked.is_empty() else "",
		"pilot": pilot.describe() if pilot != null else {}}
