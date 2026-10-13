class_name DotBotSurfPlanner
extends RefCounted

## Finds a way down a surf ramp by trying inputs on the real motor, offline, and grows the cache
## a [DotBotSurfPilot] rides from.
##
## [b]A beam search over held actions.[/b] From the start, every action in
## [constant DotBotSurfPilot.ACTIONS] is held for [member hold] ticks on a copy of each state in
## the beam; a child that enters a pit or falls below the course is dropped, one that reaches the
## goal ends the search, and the rest are ranked by the course's score (progress plus energy) and
## cut back to [member width]. All children are the same age, so the first to arrive is the
## fastest the beam found.
##
## [b]One survivor per cell.[/b] Without it the beam fills with copies of the one line that is
## ahead right now -- all on the same face, a centimetre apart -- and when that line turns out to
## end in a pit there is nothing else left. Children are bucketed by position (a [member cell]
## grid), speed and whether they are on the ground, and only the best of each bucket survives,
## which keeps the other face and the slower, higher lines alive long enough to be needed.
##
## [b]Why search, and not learn.[/b] The simulator is the motor (dot-player-controller's
## [code]DotFpsSimulator[/code]) and the motor is deterministic, so a found sequence of actions
## is a proof that the ramp can be ridden, not an estimate; the cost is paid once per map by a
## tool, not per bot. [method build]'s repair rounds are the learning: they search again from the
## states the pilot itself fails from, which no search from the start visits (imitation learning's
## "train on the states the student reaches", with no training). game-dev/docs/surf-bots-study.md
## has the comparison with recorded demonstrations and with reinforcement learning.
##
## Costs, measured on game-g2gfast's surf_beginner stage 1: a search is about 10 s and 96,000
## motor ticks; a stage's cache (6 starts, 3 repair rounds of 48) 21 minutes on one core.

# No log channel: [method build] reports through the caller's `say`.

## Beam width: states kept after each step.
var width: int = 32
## Ticks each action is held.
var hold: int = 8
## Bucket size for the one-per-cell rule in metres (48 genre units), and the speed bucket in m/s
## (100 u/s).
var cell: float = 0.9144
var speed_bucket: float = 1.905
## Give up after this many seconds of simulated ride.
var seconds: float = 20.0
## Ticks back from a failure a repair search starts (a second at 128 Hz).
var repair_back: int = 128
## Ranked children examined, for the report.
var expanded: int = 0


## Searches from [param start] (not changed). Returns `{"found": bool, "actions":
## PackedByteArray (one per held step), "ticks": int (to the goal), "why": String}`.
func search(start: Variant, course: DotBotSurfCourse, sim: Variant) -> Dictionary:
	var reference := course.reference_yaw()
	var beam: Array = [{"state": start.duplicate_state(), "actions": PackedByteArray(), "score": 0.0}]
	var delta: float = sim.delta
	var steps := int(seconds / (delta * float(hold)))
	var deaths := 0
	for depth in range(steps):
		var best: Dictionary = {}
		for node: Dictionary in beam:
			for action in range(DotBotSurfPilot.ACTIONS.size()):
				var s: Variant = node["state"].duplicate_state()
				var event := 0
				var t := 0
				while t < hold:
					event = sim.step(s, DotBotSurfPilot.command_for(sim, action, s, reference))
					t += 1
					if event != DotBotSurfCourse.EVENT_NONE:
						break
				expanded += 1
				var actions: PackedByteArray = (node["actions"] as PackedByteArray).duplicate()
				actions.append(action)
				if event == DotBotSurfCourse.EVENT_GOAL:
					return {"found": true, "actions": actions, "ticks": depth * hold + t, "why": ""}
				if event != DotBotSurfCourse.EVENT_NONE:
					deaths += 1
					continue
				var key := _key(s)
				var score := course.score(s)
				if not best.has(key) or float(best[key]["score"]) < score:
					best[key] = {"state": s, "actions": actions, "score": score}
		if best.is_empty():
			return {"found": false, "actions": PackedByteArray(), "ticks": depth * hold,
				"why": "every line ended in a pit after %.2f s (%d deaths)" % [depth * hold * delta, deaths]}
		var ranked: Array = best.values()
		ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
		beam = ranked.slice(0, width)
	return {"found": false, "actions": PackedByteArray(), "ticks": steps * hold,
		"why": "no line reached the goal in %.0f s" % seconds}


## The ride [param actions] makes from [param start], tick by tick, until it reaches the goal:
## `{"entries": PackedFloat32Array (x, y, z, vx, vy, vz, action per tick, metres), "ticks": int,
## "event": int}`. The search's answer replayed, which is the same ride because the motor is
## deterministic, and what the pilot learns from.
static func trajectory(start: Variant, actions: PackedByteArray, hold_ticks: int, course: DotBotSurfCourse, sim: Variant) -> Dictionary:
	var reference := course.reference_yaw()
	var s: Variant = start.duplicate_state()
	var entries := PackedFloat32Array()
	var event := 0
	var ticks := 0
	for action: int in actions:
		for _t in range(hold_ticks):
			var p: Vector3 = s.position
			var v: Vector3 = s.velocity
			entries.append_array([p.x, p.y, p.z, v.x, v.y, v.z, float(action)])
			event = sim.step(s, DotBotSurfPilot.command_for(sim, action, s, reference))
			ticks += 1
			if event != DotBotSurfCourse.EVENT_NONE:
				return {"entries": entries, "ticks": ticks, "event": event}
	return {"entries": entries, "ticks": ticks, "event": event}


func _key(s: Variant) -> Vector4i:
	var p: Vector3 = s.position
	var v: Vector3 = s.velocity
	var u := p / cell
	return Vector4i(int(floor(u.x)), int(floor(u.y)), int(floor(u.z)),
		int(v.length() / speed_bucket) * 2 + (1 if s.is_grounded() else 0))


## Builds a ride's cache: a ride searched from each of [param starts], then up to [param rounds]
## rounds of repair. A round rides the pilot (on what is in the cache so far, veto and all) from
## each of [param repairs] on [param ride_sim]; for every ride that does not arrive it searches
## again from the state [member repair_back] ticks before the failure (then twice that, then the
## ride's start) and adds what it finds. The cache grows exactly where the pilot goes wrong, and
## stops growing when a round fails nowhere. [param say] gets one line per search; [param pilot]
## is the pilot to measure with (its settings are kept, its cache replaced), a default one when
## null.
##
## Returns `{"rides": PackedFloat32Array (the entries), "lengths": PackedInt32Array (entries per
## ride), "seconds": Array (each ride's length), "searches": int, "found": int, "rounds": Array
## (failures per round)}`.
func build(starts: Array, repairs: Array, rounds: int, course: DotBotSurfCourse, sim: Variant,
		ride_sim: Variant, say: Callable, pilot: DotBotSurfPilot = null) -> Dictionary:
	var rides := PackedFloat32Array()
	var lengths := PackedInt32Array()
	var ride_seconds: Array = []
	var searches := 0
	var found_count := 0
	var per_round: Array = []
	var delta: float = sim.delta
	for i in range(starts.size()):
		searches += 1
		var t0 := Time.get_ticks_msec()
		var ride := _search_ride(starts[i], course, sim)
		if ride.is_empty():
			say.call("start %d: no ride, %.1f s searching" % [i, (Time.get_ticks_msec() - t0) / 1000.0])
			continue
		found_count += 1
		rides.append_array(ride["entries"])
		lengths.append(int(ride["ticks"]))
		ride_seconds.append(snappedf(float(ride["ticks"]) * delta, 0.01))
		say.call("start %d: a ride of %.2f s, %.1f s searching" % [i, float(ride["ticks"]) * delta, (Time.get_ticks_msec() - t0) / 1000.0])
	var max_ticks := int(seconds / delta)
	if pilot == null:
		pilot = DotBotSurfPilot.new()
	for round in range(rounds):
		if lengths.is_empty():
			break
		pilot.load_entries(rides, lengths, course.reference_yaw())
		pilot.sim = sim
		pilot.score = course.score
		var failures := 0
		for j in range(repairs.size()):
			var r := pilot.ride(repairs[j], ride_sim, max_ticks)
			if int(r["event"]) == DotBotSurfCourse.EVENT_GOAL:
				continue
			failures += 1
			var trail: Array = r["trail"]
			var at := trail.size() - 1
			for back in [repair_back, repair_back * 2, 1 << 30]:
				var k := maxi(0, at - back / 16)
				searches += 1
				var t0 := Time.get_ticks_msec()
				var ride := _search_ride(trail[k], course, sim)
				if ride.is_empty():
					if k == 0:
						say.call("round %d, ride %d: failed and no ride from its start either" % [round, j])
						break
					continue
				found_count += 1
				rides.append_array(ride["entries"])
				lengths.append(int(ride["ticks"]))
				ride_seconds.append(snappedf(float(ride["ticks"]) * delta, 0.01))
				# The next ride of this round already learns from this repair.
				pilot.load_entries(rides, lengths, course.reference_yaw())
				say.call("round %d, ride %d: %s at %.2f s; a ride of %.2f s from %.2f s in, %.1f s searching" % [
					round, j, "fell" if int(r["event"]) != DotBotSurfCourse.EVENT_NONE else "stalled",
					float(r["ticks"]) * delta, float(ride["ticks"]) * delta, float(k * 16) * delta,
					(Time.get_ticks_msec() - t0) / 1000.0])
				break
		per_round.append(failures)
		say.call("round %d: %d of %d rides failed; the cache has %d entries" % [round, failures, repairs.size(), rides.size() / DotBotSurfPilot.STRIDE])
		if failures == 0:
			break
	return {"rides": rides, "lengths": lengths, "seconds": ride_seconds, "searches": searches, "found": found_count, "rounds": per_round}


## One search and its replay, or {} when the search found nothing.
func _search_ride(from: Variant, course: DotBotSurfCourse, sim: Variant) -> Dictionary:
	var found := search(from, course, sim)
	if not bool(found["found"]):
		return {}
	var ride := trajectory(from, found["actions"], hold, course, sim)
	if int(ride["event"]) != DotBotSurfCourse.EVENT_GOAL:
		push_error("a found ride did not replay to the goal: the simulator is not deterministic")
		return {}
	return ride


func describe() -> Dictionary:
	return {"width": width, "hold": hold, "cell": cell, "speed_bucket": speed_bucket, "seconds": seconds, "expanded": expanded}
