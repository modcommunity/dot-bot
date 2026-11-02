class_name DotBotUnstick
extends RefCounted

## Notices a bot that pushes to move and gets nowhere, and escalates: re-plan and hop, then crouch-hop and side-step, then a nudge toward the nearest standable point.

## Seconds of no progress that raise the level one step, and the distance that counts as progress.
const WINDOW := 1.0
const PROGRESS := 0.45
## From this level the bot is walked toward a standable point.
const NUDGE_LEVEL := 3

var level: int = 0
## What the brain does this tick; read after [method step].
var jump := false
var crouch := false
var strafe := 0.0
var replan := false
var nudge_to := Vector3.INF
## Times a window ended stuck, over the bot's life.
var total: int = 0

var _anchor: Vector3 = Vector3.INF
var _anchor_at: float = 0.0
var _pushed: float = 0.0
var _seen: float = 0.0
var _side: float = 1.0
var _rng: DotRandomStream = null


func _init(p_rng: DotRandomStream = null) -> void:
	_rng = p_rng


## [param pushing] is whether the intent walks this tick. Returns the level, 0 when free.
func step(position: Vector3, pushing: bool, now: float, world: DotBotWorld) -> int:
	jump = false
	crouch = false
	strafe = 0.0
	replan = false
	nudge_to = Vector3.INF
	if _anchor == Vector3.INF:
		reset(position, now)
	_seen += 1.0
	_pushed += 1.0 if pushing else 0.0
	if now - _anchor_at >= WINDOW:
		var moved := position.distance_to(_anchor)
		if _pushed / maxf(_seen, 1.0) > 0.6 and moved < PROGRESS:
			level += 1
			total += 1
			_side = -_side
		elif moved >= PROGRESS * 2.0:
			level = 0
		_anchor = position
		_anchor_at = now
		_pushed = 0.0
		_seen = 0.0
	if level == 0 or not pushing:
		return level
	replan = true
	jump = true
	if level >= 2:
		crouch = int(now * 4.0) % 2 == 0
		strafe = _side
	if level >= NUDGE_LEVEL and world != null:
		var near := world.walkable_near(position)
		if near != Vector3.INF and Vector2(near.x - position.x, near.z - position.z).length() > 0.35:
			nudge_to = near
		elif _rng != null:
			var a := _rng.next_range_f(0.0, TAU)
			nudge_to = position + Vector3(cos(a), 0.0, sin(a)) * 3.0
	return level


## Forget the history: a respawn, a teleport, a finished ride or ladder.
func reset(position: Vector3 = Vector3.INF, now: float = 0.0) -> void:
	level = 0
	_anchor = position
	_anchor_at = now
	_pushed = 0.0
	_seen = 0.0
