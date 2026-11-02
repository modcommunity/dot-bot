class_name DotBotArms
extends RefCounted

## The generic half of feeding [DotBotPickup]: rates weapons by damage per second and builds a contact's [member DotBotContact.loadout] and the world's [member DotBotWorld.drops_fn]
## from a dot-weapon arsenal and drop set. Duck typed (no dot-weapon class is named), so dot-bot compiles without it.
## Wire it with [code]DotBotArms.wire(world, drops_fn, arsenal_fn)[/code] and [code]contact.loadout = DotBotArms.loadout_of(player.arsenal)[/code].

## Damage per second that rates 1.0.
const FULL_DPS := 12.0 * 20.0
## Ticks per second the weapon definition's intervals are in.
const TICK_RATE := 20.0


## Damage per second of a weapon definition, 0 to 1: crude on purpose, a game with a better idea
## passes its own rating to [method loadout_of] and [method drops_of].
static func rate(def: Object) -> float:
	if def == null:
		return 0.0
	var damage := 10.0
	var pellets := 1.0
	var tuning: Variant = def.get("tuning")
	if tuning is Object:
		var t: Object = tuning
		if t.get("damage") != null:
			damage = float(t.get("damage"))
		if t.get("pellets") != null:
			pellets = float(t.get("pellets"))
	var interval := maxi(int(def.get("use_interval_ticks")), 1)
	return clampf(damage * pellets * TICK_RATE / float(interval) / FULL_DPS, 0.0, 1.0)


## Fraction of a full load a weapon has: magazine plus reserve against its caps.
static func ammo_fraction(def: Object, magazine: int, reserve: int) -> float:
	if def == null or bool(def.get("infinite_reserve")):
		return 1.0
	var full := int(def.get("magazine")) + int(def.call("reserve_cap"))
	return clampf(float(magazine + reserve) / float(maxi(full, 1)), 0.0, 1.0)


## [code]{slot: {value, ammo}}[/code] for what [param arsenal] carries; empty when it has none.
## [param rater] is [code]Callable(def) -> float[/code], [method rate] when invalid.
static func loadout_of(arsenal: Object, rater: Callable = Callable()) -> Dictionary:
	var out := {}
	if arsenal == null:
		return out
	var ammo: Object = arsenal.call("ammo")
	for slot in range(1, 10):
		var held: Object = arsenal.call("slot_at", slot)
		if held == null or held.get("def") == null:
			continue
		var def: Object = held.get("def")
		var type: StringName = def.get("ammo_type")
		var reserve: int = int(ammo.call("count", type)) if ammo != null and type != &"" else 0
		out[slot] = {"value": rater.call(def) if rater.is_valid() else rate(def),
			"ammo": ammo_fraction(def, int(held.get("magazine")), reserve)}
	return out


## The weapons lying in [param drops] in the shape [member DotBotWorld.drops_fn] wants; the
## definitions come from [param arsenal]'s catalogue.
static func drops_of(drops: Object, arsenal: Object, rater: Callable = Callable()) -> Array:
	var out := []
	if drops == null or arsenal == null or arsenal.get("catalogue") == null:
		return out
	var catalogue: Object = arsenal.get("catalogue")
	for d: Dictionary in drops.call("snapshot"):
		var state: Dictionary = d["state"]
		var def: Object = catalogue.call("get_def", StringName(state["id"]))
		if def == null:
			continue
		out.append({"id": d["id"], "position": (d["at"] as Transform3D).origin, "slot": int(def.get("slot")),
			"value": rater.call(def) if rater.is_valid() else rate(def),
			"ammo": ammo_fraction(def, int(state.get("magazine", 0)), int(state.get("reserve", 0)))})
	return out


## Sets [member DotBotWorld.drops_fn]. [param drops_source] returns the drop set (or null),
## [param arsenal_source] any arsenal whose catalogue knows the weapons.
static func wire(world: DotBotWorld, drops_source: Callable, arsenal_source: Callable, rater: Callable = Callable()) -> void:
	world.drops_fn = func() -> Array: return drops_of(drops_source.call(), arsenal_source.call(), rater)
