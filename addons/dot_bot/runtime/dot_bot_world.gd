class_name DotBotWorld
extends RefCounted

## Everything a bot brain may know about the world, and nothing else.
##
## [b]The brain cannot cheat because this is all it has.[/b] It gets the bodies
## ([method contacts]), a line-of-sight answer, the sounds that were made, and places to
## walk to. It does not get the map, the other bots' brains, or anybody's position except
## through a body it can see or a sound it can hear: whether it may see a contact is the
## brain's question, asked of [method line_of_sight], so "no shooting through walls" is
## structural rather than a rule each game remembers.
##
## [b]Subclass or assign.[/b] A game either extends this and overrides the methods, or
## sets the callables on a plain one ([member contacts_fn] and friends); both are the
## family's usual extension point. The defaults see everything (no walls) and know no places,
## which is what a suite with no map wants.
##
## [codeblock]
## var world := DotBotWorld.new()
## world.contacts_fn = func() -> Array: return my_bodies_as_contacts()
## world.line_of_sight_fn = func(a: Vector3, b: Vector3) -> bool: return trace.line_of_sight(a, b)
## world.waypoints_fn = func() -> PackedVector3Array: return spawn_points
## world.emit_sound(shooter.position, 1.0, shooter.id, now)    # a gunshot
## [/codeblock]

# No log channel: answers questions; the brain and the game log.

## How long a sound stays in [member sounds], seconds. Longer than any brain's think interval.
const SOUND_LIFETIME := 1.0

## [code]() -> Array[/code] of [DotBotContact]: every body, the bots included.
var contacts_fn: Callable = Callable()

## [code](from: Vector3, to: Vector3) -> bool[/code].
var line_of_sight_fn: Callable = Callable()

## [code]() -> PackedVector3Array[/code]: places worth walking to (spawns, objectives).
var waypoints_fn: Callable = Callable()

## [code](from: Vector3, dir: Vector3, reach: float) -> Dictionary[/code]: the nearest wall along
## [param dir] (flat, unit) within [param reach] as `{normal, distance}`, or empty. The brain asks
## it beside and ahead of a running bot to find a wall worth running along.
var wall_fn: Callable = Callable()

## [code](shooter: DotBotContact) -> float[/code]: how fast what this body fires travels, m/s;
## 0 for hitscan. The brain leads a target by it.
var projectile_speed_fn: Callable = Callable()

## [code](from: Vector3, to: Vector3) -> PackedVector3Array[/code]: the corners of a walkable way
## from one place to another, [param to] last; empty when the game has no graph or no way. The
## brain walks a route corner by corner where it has one and straight where it has none, so a
## map with walls between its waypoints is not walked into the walls.
var route_fn: Callable = Callable()

## [code](from: Vector3, to: Vector3) -> Dictionary[/code]: a route that may ride, as
## [method DotBotNav.route] answers (`points`, and `rides`: per point the id of the ride edge that
## starts there, -1 for a walked corner). Unset, [method route_detail] is [member route_fn]'s
## corners, every one walked. The brain says when it reaches a ride's start
## ([member DotBotIntent.ride]); the game rides it.
var route_detail_fn: Callable = Callable()

## Recent sounds: dictionaries with position, loudness (1 is a gunshot), source (an id), at
## and seq.
var sounds: Array[Dictionary] = []

## The last sound's number. A brain remembers the last one it heard by this, never by time: a
## sound made at the same timestamp as a brain's last think was missed by a time comparison,
## and a bot with its back to a shooter at that moment died without turning round.
var _seq: int = 0


func contacts() -> Array:
	return contacts_fn.call() if contacts_fn.is_valid() else []


## `{center, radius, until}` per sight blocker (smoke), by id; a segment through one is not clear.
var sight_blockers: Dictionary = {}
var _blocker_seq: int = 0


func line_of_sight(from: Vector3, to: Vector3) -> bool:
	for b: Dictionary in sight_blockers.values():
		if segment_hits_sphere(from, to, b["center"], float(b["radius"])):
			return false
	return bool(line_of_sight_fn.call(from, to)) if line_of_sight_fn.is_valid() else true


## Blocks sight through a sphere until [param until] (game time); returns an id for [method remove_sight_blocker].
func add_sight_blocker(center: Vector3, radius: float, until: float) -> int:
	_blocker_seq += 1
	sight_blockers[_blocker_seq] = {"center": center, "radius": radius, "until": until}
	return _blocker_seq


func remove_sight_blocker(id: int) -> void:
	sight_blockers.erase(id)


## Drops the blockers that ended by [param now]; the brain calls it each think.
func prune_sight_blockers(now: float) -> void:
	for id in sight_blockers.keys():
		if now >= float(sight_blockers[id]["until"]):
			sight_blockers.erase(id)


static func segment_hits_sphere(from: Vector3, to: Vector3, center: Vector3, radius: float) -> bool:
	var d := to - from
	var len2 := d.length_squared()
	var t := 0.0 if len2 < 0.000001 else clampf((center - from).dot(d) / len2, 0.0, 1.0)
	return (from + d * t).distance_squared_to(center) <= radius * radius


func wall_ahead(from: Vector3, dir: Vector3, reach: float) -> Dictionary:
	return wall_fn.call(from, dir, reach) if wall_fn.is_valid() else {}


func waypoints() -> PackedVector3Array:
	return waypoints_fn.call() if waypoints_fn.is_valid() else PackedVector3Array()


func route(from: Vector3, to: Vector3) -> PackedVector3Array:
	return route_fn.call(from, to) if route_fn.is_valid() else PackedVector3Array()


## A route that may ride: see [member route_detail_fn]. A subclass that overrides [method route]
## and not this gets its corners, all walked.
func route_detail(from: Vector3, to: Vector3) -> Dictionary:
	if route_detail_fn.is_valid():
		return route_detail_fn.call(from, to)
	var points := route(from, to)
	var rides := PackedInt32Array()
	rides.resize(points.size())
	rides.fill(-1)
	return {"points": points, "rides": rides}


## The ladder behind a ride id ([constant DotBotLinks.LADDER_ID] up): `{"box": AABB, "to": Vector3}`, or an empty dictionary. Assign [code]links.ladder_of[/code].
var ladder_fn := Callable()


func ladder(ride_id: int) -> Dictionary:
	return ladder_fn.call(ride_id) if ladder_fn.is_valid() else {}


func projectile_speed(shooter: DotBotContact) -> float:
	return float(projectile_speed_fn.call(shooter)) if projectile_speed_fn.is_valid() else 0.0


## Records a sound. [param loudness] scales every bot's hearing distance: 1 a gunshot, about
## 0.3 a footstep, 2 an explosion.
func emit_sound(position: Vector3, loudness: float, source: int, now: float) -> void:
	_seq += 1
	sounds.append({"position": position, "loudness": loudness, "source": source, "at": now, "seq": _seq})
	_prune(now)


## The sounds after number [param after_seq] (0 for all), oldest first.
func sounds_after(after_seq: int, now: float) -> Array[Dictionary]:
	_prune(now)
	var out: Array[Dictionary] = []
	for s in sounds:
		if int(s["seq"]) > after_seq:
			out.append(s)
	return out


## The number of the newest sound.
func last_sound() -> int:
	return _seq


func _prune(now: float) -> void:
	while not sounds.is_empty() and now - float(sounds[0]["at"]) > SOUND_LIFETIME:
		sounds.pop_front()


## The contact with [param id] in [param list], or null.
static func find(list: Array, id: int) -> DotBotContact:
	for c in list:
		if c is DotBotContact and (c as DotBotContact).id == id:
			return c
	return null


func describe() -> Dictionary:
	return {"sounds": sounds.size(), "waypoints": waypoints().size()}
