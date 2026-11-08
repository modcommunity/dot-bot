class_name DotBotThinkTier
extends RefCounted

## Think-rate tiers for a crowd of bots: which bots run their brain every tick and which every few ticks.
##
## A bot a person can see, is fighting, or is near runs every tick, so the aim a person meets is the full one.
## The rest (bots fighting bots out of sight, bots roaming) think every [member near_every] ticks within
## [member far_range] of a person and every [member far_every] beyond, up to the beat [method until_beat] gives, so the
## thinkers spread over the ticks. Plain data in, a period out: the game's loop and a native brain share it.

## Players above which tiers apply; at or below it every bot thinks every tick. Negative: never.
var above: int = 16
## Period of an unwatched bot within [member far_range] metres of a person, and beyond it (or with no person).
var near_every: int = 2
var far_every: int = 4
var far_range: float = 40.0
## Within this many metres of a person a bot is full rate whatever the person faces.
var close_range: float = 12.0
## This many bots nearest each person are full rate.
var nearest: int = 3
## Period of a bot that fights a person but is farther than [member engaged_range] and outside every person's view
## cone: it cannot be seen shooting, and a person meets its aim only once it is seen or near. 1 (the default): a fighting
## bot is always full rate.
var engaged_far_every: int = 1
## Metres: a fighting bot nearer than this to a person is full rate whatever the person faces.
var engaged_range: float = 25.0
## Multiplies every period above 1 (the tiers under load): a game that measures its tick running over its budget raises
## it, 1 is the periods as set. Full-rate bots stay full rate, and no period passes [constant MAX_PERIOD].
var load_scale: float = 1.0
## The longest period [member load_scale] may stretch a tier to: a bot that sits out more ticks than this cannot steer.
const MAX_PERIOD := 8
## A bot within [member view_range] metres and inside a person's view cone (half angle [member view_half_angle]
## degrees) is full rate. A cone and no ray: a bot behind a wall counts as seen, which only costs time.
var view_range: float = 60.0
var view_half_angle: float = 60.0:
	set(value):
		view_half_angle = value
		_view_cos = cos(deg_to_rad(clampf(value, 0.0, 180.0)))

var _view_cos: float = cos(deg_to_rad(60.0))
var _eyes := PackedVector3Array()
var _looks := PackedVector3Array()
var _pinned: Dictionary = {}
var _on: bool = false
## Answers of [method period] since the tier was made, by reason, for a profile: off, engaged, pinned, close, view, near, far.
var counts: Dictionary = {}


## Whether tiers apply to a game of [param players] players.
func applies(players: int) -> bool:
	return above >= 0 and players > above and maxi(near_every, far_every) > 1


## Starts a tick: the people's eyes and unit view directions (parallel), and the bots' ids and positions
## (parallel) for the nearest-bots rule. [param players] is everyone in the game, for [method applies].
func begin(players: int, eyes: PackedVector3Array, looks: PackedVector3Array, bot_ids: PackedInt32Array, bot_positions: PackedVector3Array) -> void:
	_on = applies(players)
	_eyes = eyes
	_looks = looks
	_pinned.clear()
	if not _on or nearest <= 0:
		return
	var k := mini(nearest, bot_ids.size())
	for e in eyes.size():
		var best_d := PackedFloat32Array()
		var best_i := PackedInt32Array()
		for i in bot_ids.size():
			var d := bot_positions[i].distance_squared_to(eyes[e])
			if best_d.size() == k and d >= best_d[k - 1]:
				continue
			var at := best_d.size()
			while at > 0 and best_d[at - 1] > d:
				at -= 1
			best_d.insert(at, d)
			best_i.insert(at, i)
			if best_d.size() > k:
				best_d.resize(k)
				best_i.resize(k)
		for i in best_i:
			_pinned[bot_ids[i]] = true


## Whether the last [method begin] turned tiers on.
func is_on() -> bool:
	return _on


## Ticks between thinks for bot [param id] at [param position] (1 = every tick). [param engaged] is the game's
## word that it fights a person or was just hurt by one.
func period(id: int, position: Vector3, engaged: bool) -> int:
	if not _on:
		return _count(&"off", 1)
	if engaged and engaged_far_every <= 1:
		return _count(&"engaged", 1)
	if _pinned.has(id):
		return _count(&"pinned", 1)
	var best := INF
	var close_sq := close_range * close_range
	var view_sq := view_range * view_range
	var reach := maxf(engaged_range, close_range)
	var engaged_sq := reach * reach
	for e in _eyes.size():
		var to := position - _eyes[e]
		var d_sq := to.length_squared()
		if d_sq < close_sq:
			return _count(&"close", 1)
		if engaged and d_sq < engaged_sq:
			return _count(&"engaged", 1)
		if d_sq < view_sq and to.dot(_looks[e]) >= _view_cos * sqrt(d_sq):
			return _count(&"view", 1)
		best = minf(best, d_sq)
	if engaged:
		return _count(&"engaged_far", _scaled(engaged_far_every))
	if best < far_range * far_range:
		return _count(&"near", _scaled(near_every))
	return _count(&"far", _scaled(far_every))


## [param every] stretched by [member load_scale]; 1 stays 1.
func _scaled(every: int) -> int:
	if every <= 1:
		return 1
	return clampi(ceili(float(every) * maxf(load_scale, 1.0) - 0.001), 1, maxi(MAX_PERIOD, every))


func _count(reason: StringName, every: int) -> int:
	counts[reason] = int(counts.get(reason, 0)) + 1
	return every


## Ticks from a think at [param tick] to the next beat of a bot with [param seed] at period [param every] (1..every):
## the bot sits out the ticks between. Counting to a beat, not a full period, keeps the bots spread over the ticks
## when a bot's period changes or it thinks off its beat.
static func until_beat(tick: int, seed: int, every: int) -> int:
	return 1 if every <= 1 else every - posmod(tick + seed, every)


func describe() -> Dictionary:
	return {"above": above, "near_every": near_every, "far_every": far_every, "far_range": far_range,
		"close_range": close_range, "engaged_far_every": engaged_far_every, "engaged_range": engaged_range, "load_scale": load_scale, "nearest": nearest, "view_range": view_range,
		"view_half_angle": view_half_angle, "on": _on, "people": _eyes.size(), "pinned": _pinned.size(), "counts": counts}
