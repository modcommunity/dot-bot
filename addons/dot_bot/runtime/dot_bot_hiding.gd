class_name DotBotHiding
extends RefCounted

## Where to hide: places scored by how few of the map's sight lines reach them, picked apart
## from each other, and where to run to when somebody comes.
##
## [b]Out of sight lines, measured on the map.[/b] A spot is good when few of the places a
## seeker will walk can see it. [method survey] asks a game's line of sight from a sample of
## those places (watchers: points across the walkable floor, at a standing eye) to each candidate
## spot (at a crouched head), and records the share that see it: a cupboard is 0, the middle of
## a field nearly 1. That is the map's shape, the same for everybody, and costs one ray per pair
## once per map, not per bot per tick.
##
## [b]Apart.[/b] Hiders who pick the best spot each pick the same spot, and the first play test's
## bots stood together and were caught inside one second. [method choose] scores a spot down for
## every spot already taken near it, and down again for being near where the seekers start.
##
## [b]The skill is how far down the list it looks.[/b] A good player knows the best spots; a new
## one takes the first cupboard it sees. [param skill] (0..1, dot-bot's `bot_map_knowledge`)
## picks among the best two at 1 and among the better third at 0, always from the bot's own
## [DotRandomStream].
##
## Pure: everything comes in as arguments (spots, positions, a line-of-sight callable), so a
## prop-hunt or any hiding game can use it with its own map.

## Metres; a watcher further from a spot than this does not count for or against it.
const REACH := 30.0

## A spot taken by another hider within this many metres costs a spot its score. Wide, because
## a hider caught becomes a seeker where it stands, next to anybody hidden near it.
const SPREAD := 12.0


## For each of [param candidates] (feet positions), the share of [param watchers] within
## [param reach] whose eye sees a head at [param head] over the feet. [param los] is
## `(from: Vector3, to: Vector3) -> bool`. Returns `[{at, exposure, seen_by}]`.
static func survey(candidates: PackedVector3Array, watchers: PackedVector3Array, los: Callable,
		reach: float = REACH, head: float = 0.8) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for at in candidates:
		var near := 0
		var seen := 0
		var target := at + Vector3(0.0, head, 0.0)
		for eye in watchers:
			var d := eye.distance_to(target)
			if d > reach or d < 1.0:
				continue
			near += 1
			if bool(los.call(eye, target)):
				seen += 1
		# A spot nobody is within reach of is as hidden as it is unvisited: count it as seen by
		# half, so a far corner of a field does not beat a cupboard.
		var exposure := float(seen) / float(near) if near > 0 else 0.5
		out.append({"at": at, "exposure": exposure, "seen_by": seen})
	return out


## The spot a hider at [param me] goes to: low exposure, apart from [param taken] (other hiders'
## spots), away from [param threats] (where seekers are or start), and reachable when
## [param reachable] (`(spot: Vector3) -> bool`, e.g. a path short enough for the time left)
## says so. [param skill] 0..1. An empty dictionary when nothing qualifies.
static func choose(spots: Array, me: Vector3, threats: PackedVector3Array, taken: PackedVector3Array,
		stream: DotRandomStream, skill: float, reachable: Callable = Callable(), spread: float = SPREAD) -> Dictionary:
	var scored: Array = []
	for spot: Dictionary in spots:
		var at: Vector3 = spot["at"]
		var score := (1.0 - float(spot["exposure"])) * 3.0
		for threat in threats:
			score += minf(at.distance_to(threat), 35.0) / 35.0 * 2.0 / maxf(float(threats.size()), 1.0)
		for other in taken:
			var d := at.distance_to(other)
			if d < spread:
				score -= (spread - d) / spread * 4.0
		scored.append([score, spot])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])

	# How far down the list: the best two at skill 1, the better third at 0 (medium's 0.4 looks
	# at about the best fifth).
	var depth := maxi(1, roundi(lerpf(float(scored.size()) / 3.0, 2.0, clampf(skill, 0.0, 1.0))))
	var tries := 0
	while tries < 24 and not scored.is_empty():
		tries += 1
		var pick: Array = scored[stream.next_range_i(0, mini(depth, scored.size()) - 1)]
		var spot: Dictionary = pick[1]
		if not reachable.is_valid() or bool(reachable.call(spot["at"])):
			return spot
		scored.erase(pick)
	return {}


## Where to run from [param threat] (its eye at [param threat_eye]): a spot it cannot see, at
## least [param clear] metres from it, not behind it, and as near [param me] as allows; empty
## when there is none within [param within].
static func flee_spot(spots: Array, me: Vector3, threat: Vector3, threat_eye: Vector3, los: Callable,
		taken: PackedVector3Array, within: float = 25.0, clear: float = 9.0, head: float = 0.8) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	var away := Vector3(me.x - threat.x, 0.0, me.z - threat.z).normalized()
	for spot: Dictionary in spots:
		var at: Vector3 = spot["at"]
		var from_me := at.distance_to(me)
		if from_me > within or from_me < 2.0 or at.distance_to(threat) < clear:
			continue
		var dir := Vector3(at.x - me.x, 0.0, at.z - me.z).normalized()
		# Never run past the seeker to get there.
		if dir.dot(away) < -0.2:
			continue
		var crowded := false
		for other in taken:
			if at.distance_to(other) < 3.0:
				crowded = true
				break
		if crowded:
			continue
		var score := (1.0 - float(spot["exposure"])) * 2.0 + dir.dot(away) - from_me / within
		if score <= best_score:
			continue
		if bool(los.call(threat_eye, at + Vector3(0.0, head, 0.0))):
			continue
		best_score = score
		best = spot
	return best


## Whether an eye at [param eye] looking along [param forward] with a cone of [param fov]
## degrees and [param sight] metres sees [param target] past the world ([param los]).
static func sees(eye: Vector3, forward: Vector3, fov: float, sight: float, target: Vector3, los: Callable) -> bool:
	var to := target - eye
	var d := to.length()
	if d > sight:
		return false
	if d > 0.01 and rad_to_deg(forward.angle_to(to / d)) > fov * 0.5:
		return false
	return bool(los.call(eye, target))
