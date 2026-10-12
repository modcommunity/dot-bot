class_name DotBotSearch
extends RefCounted

## A seeker's memory of a map: the places somebody could be, which it has looked at, and which
## to look at next.
##
## [b]It searches, it does not know.[/b] What it is given is the map (the places a person could
## hide, each with how hidden it is, from [DotBotHiding.survey]) and what it sees and hears. A
## place is crossed off when the seeker has had it in view ([method observe]: inside its cone,
## within reach, nothing in the way), never because nobody is there; a sound puts the places
## near it back on the list and up it ([method heard]). Nobody's position comes in any other way.
##
## [b]Likely first, near first, and not where another seeker is going.[/b] [method next] weighs a
## place by how hidden it is (a seeker who knows the map looks in the cupboards before the
## middle of the field; `bot_map_knowledge` is how much), by distance, and down when another
## seeker has claimed somewhere near it, so two seekers split the house rather than walk it
## together.
##
## A place looked at is looked at again only after [member recheck] seconds: hiders move.

## Seconds before a place looked at counts as unlooked again.
var recheck: float = 75.0

## Metres within which [method observe] crosses a place off; a cupboard across a hall has not
## been looked into.
var look_reach: float = 9.0

## `[{at, weight, seen_at, heard_at}]`.
var places: Array[Dictionary] = []


## The places, from a survey (`[{at, exposure}]`). [param knowledge] 0..1: how much the most
## hidden places come first.
func setup(survey: Array, knowledge: float) -> void:
	places.clear()
	for spot: Dictionary in survey:
		var hidden := 1.0 - float(spot.get("exposure", 0.5))
		places.append({
			"at": spot["at"],
			"weight": lerpf(1.0, 0.15 + hidden * 1.7, clampf(knowledge, 0.0, 1.0)),
			"seen_at": -INF,
			"heard_at": -INF,
		})


## Crosses off every place an eye at [param eye], looking along [param forward] with a cone of
## [param fov] degrees, sees within [member look_reach] (and [param sight]) at [param now].
## Returns how many it crossed off.
func observe(eye: Vector3, forward: Vector3, fov: float, sight: float, los: Callable, now: float, head: float = 0.6) -> int:
	var crossed := 0
	var reach := minf(look_reach, sight)
	for place: Dictionary in places:
		if now - float(place["seen_at"]) < recheck * 0.25:
			continue
		var at: Vector3 = place["at"]
		if absf(at.x - eye.x) > reach or absf(at.z - eye.z) > reach:
			continue
		if DotBotHiding.sees(eye, forward, fov, reach, at + Vector3(0.0, head, 0.0), los):
			place["seen_at"] = now
			place["heard_at"] = -INF
			crossed += 1
	return crossed


## A sound at [param at]: the places within [param radius] are unlooked and first.
func heard(at: Vector3, now: float, radius: float = 7.0) -> void:
	for place: Dictionary in places:
		if (place["at"] as Vector3).distance_to(at) < radius:
			place["seen_at"] = -INF
			place["heard_at"] = now


## The place to go and look at next from [param from], or an empty dictionary when every place
## has been looked at lately. [param claimed]: where other seekers are going.
## [param distance] `(a: Vector3, b: Vector3) -> float` (a path length; straight by default).
func next(from: Vector3, now: float, claimed: PackedVector3Array, stream: DotRandomStream, distance: Callable = Callable()) -> Dictionary:
	var best: Dictionary = {}
	var best_score := -INF
	for place: Dictionary in places:
		if now - float(place["seen_at"]) < recheck:
			continue
		var at: Vector3 = place["at"]
		var d := at.distance_to(from)
		var score := float(place["weight"]) / (1.0 + d / 12.0)
		if now - float(place["heard_at"]) < 20.0:
			score += 3.0 / (1.0 + d / 20.0)
		for other in claimed:
			var c := at.distance_to(other)
			if c < 10.0:
				score *= 0.25 + c / 13.3
		score *= stream.next_range_f(0.85, 1.15)
		if score > best_score:
			best_score = score
			best = place
	if not best.is_empty() and distance.is_valid() and is_inf(float(distance.call(from, best["at"]))):
		# Unreachable from here: never pick it again this round.
		best["seen_at"] = INF
		return next(from, now, claimed, stream, distance)
	return best


func unlooked(now: float) -> int:
	var count := 0
	for place: Dictionary in places:
		if now - float(place["seen_at"]) >= recheck:
			count += 1
	return count


func describe() -> Dictionary:
	return {"places": places.size()}
