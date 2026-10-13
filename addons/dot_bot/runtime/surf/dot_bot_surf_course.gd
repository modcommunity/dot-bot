class_name DotBotSurfCourse
extends RefCounted

## One surf ride as a bot sees it: where it starts, what counts as arriving, what counts as
## falling, and how far along a state is. The planner searches against it and the pilot's veto
## asks it what a simulated future ended in.
##
## [b]A game fills it, from what its map already says.[/b] A timer map's stage is its zones
## (game-g2gfast: the stage's destination is the start, the next stage's zone the goal, every
## respawn zone a pit); a combat surf map's ride is an edge from one standable platform to
## another, with the map's teleports as pits (game-arena). Either sets [member goals] and
## [member pits] as boxes, or overrides [method event_at], then calls [method settle].
##
## [b]Progress is distance along the line from the start to the goal, plus energy.[/b] On a
## ramp every action goes roughly the same way, and what separates a good state from a doomed
## one is how much height and speed it still has. Energy is height plus v²/2g, in metres: a ride
## converts one into the other without changing it, a scrub or a clip loses it, an air strafe
## adds it. A ride whose line bends far from the straight one (a 180-degree turn) wants
## [member guide], a polyline the progress is measured along instead.
##
## Units are metres and the state is whatever the game's simulator steps (dot-player-
## controller's [code]DotFpsState[/code]): read by duck typing, `position` and `velocity`.

# No log channel: answers questions.

## What a state is in, by number. The same numbers as dot-player-controller's
## [code]DotFpsSimulator.EVENT_*[/code], so an oracle can return either.
const EVENT_NONE := 0
const EVENT_GOAL := 1
const EVENT_PIT := 2
const EVENT_BELOW := 3

## How much one metre of energy is worth against one metre of progress.
var energy_weight: float = 0.5
## Gravity the energy is measured under, m/s².
var gravity: float = 15.24
## How far under the lowest goal a state is past saving, metres (1024 genre units).
var below_margin: float = 19.5

## Where a ride starts, and the view there (degrees, the command's convention).
var start: Vector3 = Vector3.ZERO
var start_yaw: float = 0.0
## Where the straight line aims; set by [method settle] from the nearest goal unless given.
var goal_centre: Vector3 = Vector3.INF
## Arriving inside any of these is the goal; falling into any of these is a pit.
var goals: Array[AABB] = []
var pits: Array[AABB] = []
## `func(state) -> bool`, beside or instead of [member goals]: a goal that is not a box (a
## platform's polygons, grounded on it).
var goal_fn: Callable = Callable()
## `func(state) -> bool`, beside [member pits].
var pit_fn: Callable = Callable()
## Below this height a state has fallen. Set by [method settle] when left at -INF.
var floor_y: float = -INF
## Points from the start to the goal that progress is measured along; empty for the straight
## line.
var guide: PackedVector3Array = PackedVector3Array()
## `func(state) -> bool`: whether nothing under the state could hold it (no ramp, no platform,
## only the pit). Such a state scores [member unsupported_penalty] metres less. Unset, none is.
##
## [b]Why.[/b] A combat surf map's spawn sits on top of a long ramp with nothing beside it but
## the drop to the floor teleport. A line that leaves the ramp toward the goal makes progress
## faster than one riding it, and keeps all of its energy until it lands in the pit seconds later;
## by then the beam had dropped every rider for it and every line died at once (game-arena's
## surf_10x_reloaded_fixed, 2026-10-13). A staged map's pits sit right under its ramps, so
## game-g2gfast never needed it.
var unsupported_fn: Callable = Callable()
## Progress as how much nearer the goal (flat) a state is than the start, rather than how far
## along the start-to-goal line: a line past the goal is not ahead of one at it. A staged
## map's pits catch an overshoot; a combat surf map's open floor let a line falling past its
## landing outscore every rider.
var toward_goal: bool = false
var unsupported_penalty: float = 20.0

var _dir: Vector3 = Vector3.FORWARD


## Works out the line and the floor from what is set. Call after filling the course.
func settle() -> DotBotSurfCourse:
	if goal_centre == Vector3.INF:
		var best := INF
		for goal in goals:
			var d := goal.get_center().distance_to(start)
			if d < best:
				best = d
				goal_centre = goal.get_center()
	if goal_centre == Vector3.INF:
		goal_centre = start + _forward(start_yaw) * 10.0
	if floor_y == -INF:
		var lowest := minf(start.y, goal_centre.y)
		for goal in goals:
			lowest = minf(lowest, goal.position.y)
		floor_y = lowest - below_margin
	var flat := Vector3(goal_centre.x - start.x, 0.0, goal_centre.z - start.z)
	_dir = flat.normalized() if flat.length() > 0.01 else _forward(start_yaw)
	return self


## What [param state] is in: the goal, a pit, below the course, or none of those. Override for
## a course whose goal or pits are not boxes and callables.
func event_at(state: Variant) -> int:
	var p: Vector3 = state.position
	if p.y < floor_y:
		return EVENT_BELOW
	for goal in goals:
		if goal.has_point(p):
			return EVENT_GOAL
	if goal_fn.is_valid() and bool(goal_fn.call(state)):
		return EVENT_GOAL
	for pit in pits:
		if pit.has_point(p):
			return EVENT_PIT
	if pit_fn.is_valid() and bool(pit_fn.call(state)):
		return EVENT_PIT
	return EVENT_NONE


## How far along [param state] is, in metres of progress plus weighted energy.
func score(state: Variant) -> float:
	var p: Vector3 = state.position
	var v: Vector3 = state.velocity
	var energy := p.y + v.length_squared() / (2.0 * gravity)
	var penalty := unsupported_penalty if unsupported_fn.is_valid() and bool(unsupported_fn.call(state)) else 0.0
	return progress(p) + energy_weight * energy - penalty


## Metres along the line (or [member guide]) from the start.
func progress(p: Vector3) -> float:
	if toward_goal and guide.size() < 2:
		var flat_start := Vector2(goal_centre.x - start.x, goal_centre.z - start.z).length()
		return flat_start - Vector2(goal_centre.x - p.x, goal_centre.z - p.z).length()
	if guide.size() < 2:
		return (p - start).dot(_dir)
	var best_d := INF
	var best := 0.0
	var along := 0.0
	for i in range(guide.size() - 1):
		var a := guide[i]
		var b := guide[i + 1]
		var seg := b - a
		var length := seg.length()
		var t := clampf((p - a).dot(seg) / maxf(length * length, 0.0001), 0.0, 1.0)
		var d := p.distance_squared_to(a + seg * t)
		if d < best_d:
			best_d = d
			best = along + t * length
		along += length
	return best


## The yaw from the start toward the goal: what "forward" is before there is a velocity.
func reference_yaw() -> float:
	return rad_to_deg(atan2(-_dir.x, -_dir.z))


## The horizontal direction the straight line runs.
func direction() -> Vector3:
	return _dir


static func _forward(yaw: float) -> Vector3:
	var y := deg_to_rad(yaw)
	return Vector3(-sin(y), 0.0, -cos(y))


func describe() -> Dictionary:
	return {"start": start, "goal": goal_centre, "goals": goals.size(), "pits": pits.size(),
		"floor_y": snappedf(floor_y, 0.01), "guide": guide.size()}
