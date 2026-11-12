class_name DotBotThinkTier
extends RefCounted

## Think-rate tiers for a crowd of bots: which bots run their brain every tick and which every few ticks.
##
## A bot a person can see, is fighting, or is near runs every tick, so the aim a person meets is the full one.
## The rest (bots fighting bots out of sight, bots roaming) think every [member near_every] ticks within
## [member far_range] of a person and every [member far_every] beyond, up to the beat [method until_beat] gives, so the
## thinkers spread over the ticks. Plain data in, a period out: the game's loop and a native brain share it.
##
## What a thinned bot skips is its brain, never its body: the game moves it every tick on the commands of its last think
## (held buttons, the view carried towards where it last looked), so its walk, its hitboxes and lag compensation are the
## same at any period. A bot a person was just hurt by, or that turns on a person, is full rate on its next think.
##
## Body tiers (API 22, off by default) go one step further for the bots nobody can meet: [method body_period] is how
## many ticks apart the game may run the motor of a bot that is near or far by the rules above (not seen, not fighting a
## person, not close or nearest), the game making the ticks up in one longer motor tick. Such a bot walks in steps and
## its hitboxes jump, which no person sees; anything the game cannot carry over (a jump, a push, the air) is its call.

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
## Period of an idle bot (the game's word: it has no target, or it is dead) that is in a person's view cone but is
## neither within [member close_range] nor among the [member nearest]: in sight it shows only its walk, which the game
## carries between thinks, and the tick it picks a target it is no longer idle. Not stretched by [member load_scale].
## 1: a seen bot is full rate whatever it does (the tiers before API 21).
var idle_view_every: int = 2
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

## Ticks between motor ticks of a bot [method period] calls near, and far ([method body_period]); 1, the default:
## every bot's body moves every tick. Never stretched by [member load_scale], capped at [constant MAX_PERIOD].
var body_near_every: int = 1
var body_far_every: int = 1

var _view_cos: float = cos(deg_to_rad(60.0))
var _eyes := PackedVector3Array()
var _looks := PackedVector3Array()
var _pinned: Dictionary = {}
var _on: bool = false
## Answers of [method period] since the tier was made, by reason, for a profile: off, engaged, pinned, close, view,
## idle_view, engaged_far, near, far.
var counts: Dictionary = {}
## Answers of [method body_period] above 1, by reason (near, far).
var body_counts: Dictionary = {}
## The reason and the nearest person's squared distance of the last [method _classify].
var _reason: StringName = &"off"
var _best_sq: float = INF
var _seen: bool = false


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
## word that it fights a person or was just hurt by one; [param idle] that it has no target at all, or is dead (a bot
## fighting another bot is neither). Engaged wins over idle.
func period(id: int, position: Vector3, engaged: bool, idle: bool = false) -> int:
	_classify(id, position, engaged, idle)
	var every := 1
	match _reason:
		&"idle_view":
			# Never slower than the same bot out of sight.
			every = mini(idle_view_every, _unseen_every())
		&"engaged_far":
			every = _scaled(engaged_far_every)
		&"near", &"far":
			every = _unseen_every()
	return _count(_reason, every)


## Ticks between motor ticks for the same bot as [method period] (1 = every tick): above 1 only for a bot near or far,
## at [member body_near_every] or [member body_far_every]. Counted in [member body_counts], not [member counts].
func body_period(id: int, position: Vector3, engaged: bool, idle: bool = false) -> int:
	if maxi(body_near_every, body_far_every) <= 1:
		return 1
	_classify(id, position, engaged, idle)
	var every := 1
	if _reason == &"near":
		every = clampi(body_near_every, 1, MAX_PERIOD)
	elif _reason == &"far":
		every = clampi(body_far_every, 1, MAX_PERIOD)
	if every > 1:
		body_counts[_reason] = int(body_counts.get(_reason, 0)) + 1
	return every


## Sets [member _reason] (and [member _best_sq]) for [method period] and [method body_period].
func _classify(id: int, position: Vector3, engaged: bool, idle: bool) -> void:
	_best_sq = INF
	_seen = false
	if not _on:
		_reason = &"off"
		return
	if engaged and engaged_far_every <= 1:
		_reason = &"engaged"
		return
	if _pinned.has(id):
		_reason = &"pinned"
		return
	var close_sq := close_range * close_range
	var view_sq := view_range * view_range
	var reach := maxf(engaged_range, close_range)
	var engaged_sq := reach * reach
	for e in _eyes.size():
		var to := position - _eyes[e]
		var d_sq := to.length_squared()
		if d_sq < close_sq:
			_reason = &"close"
			return
		if engaged and d_sq < engaged_sq:
			_reason = &"engaged"
			return
		if d_sq < view_sq and to.dot(_looks[e]) >= _view_cos * sqrt(d_sq):
			if engaged or not idle or idle_view_every <= 1:
				_reason = &"view"
				return
			_seen = true
		_best_sq = minf(_best_sq, d_sq)
	if _seen:
		_reason = &"idle_view"
	elif engaged:
		_reason = &"engaged_far"
	else:
		_reason = &"near" if _best_sq < far_range * far_range else &"far"


## The think period of an unseen bot at [member _best_sq].
func _unseen_every() -> int:
	return _scaled(near_every) if _best_sq < far_range * far_range else _scaled(far_every)


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
		"close_range": close_range, "engaged_far_every": engaged_far_every, "engaged_range": engaged_range, "idle_view_every": idle_view_every, "load_scale": load_scale, "nearest": nearest, "view_range": view_range,
		"view_half_angle": view_half_angle, "body_near_every": body_near_every, "body_far_every": body_far_every, "body_counts": body_counts, "on": _on, "people": _eyes.size(), "pinned": _pinned.size(), "counts": counts}
