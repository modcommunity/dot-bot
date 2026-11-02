class_name DotBotPickup
extends RefCounted

## A quiet bot with a worse or empty weapon, or low ammunition, notices a better one lying about,
## walks to it and presses the use key. Pure like the brain: it returns what to do, the game's
## own use path (hold to swap) does the taking, so nothing is teleported.
##
## Which weapon is better is the game's rating ([member DotBotContact.loadout], [method DotBotWorld.drops]);
## a game with its own idea of a goal subclasses and overrides [method gain].

const CHANNEL := "dot.bot"

## Least gain worth a walk.
const MIN_GAIN := 0.1
## Under this fraction of ammunition a bot wants more of the same slot.
const LOW_AMMO := 0.3
## Flat metres from the weapon at which the bot stops and presses.
const REACH := 1.1
## Seconds a goal may take before it is given up.
const GIVE_UP := 12.0
## Seconds a goal that was tried or given up is left alone.
const RETRY := 20.0
## Seconds without a step after which the plan is forgotten (a fight came between).
const STALE := 0.5

## Seconds the use key stays down: past the game's hold-to-swap time.
var hold_time: float = 0.8

var _goal: int = -1
var _noticed_at: float = 0.0
var _pressed_at: float = -1.0
var _last: float = -INF
var _skip: Dictionary = {}


## The plan this tick: [code]{position, use}[/code], or empty when the bot has nothing to fetch.
## [param quiet] false (a fight, a sound, a hit) cancels it.
func step(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, now: float, quiet: bool) -> Dictionary:
	if now - _last > STALE:
		cancel()
	_last = now
	if not quiet or p.pickup_weapons < 0.5 or world == null:
		cancel()
		return {}
	var drops := world.drops()
	var drop := _find(drops, _goal)
	if _goal != -1 and drop.is_empty():
		cancel()
		return {}
	if drop.is_empty():
		drop = _choose(me, world, p, drops, now)
		if drop.is_empty():
			return {}
		_goal = int(drop["id"])
		_noticed_at = now
	if now - _noticed_at > GIVE_UP:
		return _drop(now)
	if now - _noticed_at < p.reaction:
		return {}
	var at: Vector3 = drop["position"]
	var plan := {"position": at, "use": false}
	if absf(at.y - me.position.y) < 2.0 and Vector2(at.x - me.position.x, at.z - me.position.z).length() < REACH:
		if _pressed_at < 0.0:
			_pressed_at = now
		elif now - _pressed_at > hold_time:
			return _drop(now)
		plan["use"] = true
	return plan


## How much better a drop is than what [param me] holds in its slot (0.1 is worth a walk).
func gain(me: DotBotContact, drop: Dictionary) -> float:
	var mine: Variant = me.loadout.get(int(drop.get("slot", 0)))
	var value := float(drop.get("value", 0.0))
	if not (mine is Dictionary):
		return value
	var g := value - float(mine.get("value", 0.0))
	if float(mine.get("ammo", 1.0)) < LOW_AMMO and float(drop.get("ammo", 0.0)) > float(mine.get("ammo", 1.0)) + 0.3:
		g = maxf(g, -0.05) + 0.15
	return g


func cancel() -> void:
	_goal = -1
	_pressed_at = -1.0


## The weapon being fetched, or -1.
func goal() -> int:
	return _goal


func _drop(now: float) -> Dictionary:
	_skip[_goal] = now + RETRY
	cancel()
	return {}


func _choose(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, drops: Array, now: float) -> Dictionary:
	var best := {}
	var best_score := -INF
	for d: Dictionary in drops:
		if float(_skip.get(int(d["id"]), -INF)) > now:
			continue
		var at: Vector3 = d["position"]
		var dist := me.position.distance_to(at)
		if dist > p.pickup_range:
			continue
		var g := gain(me, d)
		if g < MIN_GAIN:
			continue
		if p.through_walls < 0.5 and not world.line_of_sight(me.eye(), at + Vector3.UP * 0.3):
			continue
		var score := g - dist * 0.02
		if score > best_score:
			best_score = score
			best = d
	return best


static func _find(drops: Array, id: int) -> Dictionary:
	for d: Dictionary in drops:
		if int(d["id"]) == id:
			return d
	return {}
