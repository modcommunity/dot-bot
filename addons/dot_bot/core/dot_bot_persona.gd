@tool
class_name DotBotPersona
extends RefCounted

## One kind of bot character: how often it picks each behaviour with nothing in front of it, how likely a server is to give it out, and how well it shoots.
##
## Idle is never a behaviour: the next of [constant BEHAVIOURS] is drawn from this mix. The data is a profile (kind `bot`, [method schema]), editable live in dot-workbench.

const KIND := "bot"
const HUNT := &"hunt"
const LOOT := &"loot"
const HOLD := &"hold"
const SUPPORT := &"support"
const SCOUT := &"scout"
## Hunt the remaining enemies, loot boxes and weapon sites, hold a chokepoint, revive and escort, scout the map.
const BEHAVIOURS: Array[StringName] = [HUNT, LOOT, HOLD, SUPPORT, SCOUT]

var id: StringName = &"balanced"
var display_name: String = "Balanced"
## Chance weight in the server's pool; 0 keeps it out.
var weight: float = 1.0
## Weight of each behaviour, in [constant BEHAVIOURS].
var mix: Dictionary = {HUNT: 1.0, LOOT: 1.0, HOLD: 1.0, SUPPORT: 1.0, SCOUT: 1.0}
## A [constant DotBotProfile.PRESETS] name, or "" for the server's difficulty.
var difficulty: String = ""
## `bot_<field>` values over the difficulty ([DotBotProfile.SPEC] fields).
var skill: Dictionary = {}
## `<field>` -> multiplier on the server's value, so a persona stays relative to bot_difficulty.
var scale: Dictionary = {}
## 0 to 0.5: each bot of this persona gets its own seeded jitter of up to this fraction on [constant SPREAD_FIELDS].
var spread: float = 0.0

## The fields [member spread] jitters: how fast and how well a bot sees and aims.
const SPREAD_FIELDS: PackedStringArray = ["reaction", "aim_error", "aim_floor", "aim_settle", "turn_smooth", "prediction", "react_jitter", "track_lag"]


## The `bot` profile schema as plain dictionaries (the shape of dot-profile's field()), so dot-bot needs no dot-profile.
static func schema() -> Array:
	var out: Array = [
		{"name": "name", "type": "string", "default": ""},
		{"name": "weight", "type": "float", "default": 1.0, "min": 0.0, "max": 1000.0},
		{"name": "difficulty", "type": "string", "default": "", "enum": ["", "easy", "medium", "hard", "nightmare"]},
		{"name": "skill", "type": "dict", "default": {}},
		{"name": "scale", "type": "dict", "default": {}},
		{"name": "spread", "type": "float", "default": 0.0, "min": 0.0, "max": 0.5},
		{"name": "enabled", "type": "bool", "default": true},
	]
	for b in BEHAVIOURS:
		out.append({"name": String(b), "type": "float", "default": 1.0, "min": 0.0, "max": 100.0})
	return out


## Kind to schema for dot-profile's profile_check.
static func profile_schemas() -> Dictionary:
	return {KIND: {"schema": schema(), "children": {}}}


## A persona from [param values] (a profile's `values` dictionary); unknown keys are ignored.
static func from_values(p_id: String, values: Dictionary) -> DotBotPersona:
	var out := DotBotPersona.new()
	out.id = StringName(p_id)
	out.display_name = str(values.get("name", "")) if str(values.get("name", "")) != "" else p_id.capitalize()
	out.weight = maxf(float(values.get("weight", 1.0)), 0.0)
	out.difficulty = str(values.get("difficulty", ""))
	var raw: Variant = values.get("skill", {})
	out.skill = (raw as Dictionary).duplicate() if raw is Dictionary else {}
	var raw_scale: Variant = values.get("scale", {})
	out.scale = (raw_scale as Dictionary).duplicate() if raw_scale is Dictionary else {}
	out.spread = clampf(float(values.get("spread", 0.0)), 0.0, 0.5)
	for b in BEHAVIOURS:
		out.mix[b] = maxf(float(values.get(String(b), 1.0)), 0.0)
	return out


## The next behaviour from the mix. Never idle: an all-zero mix counts every behaviour equal. [param last] is
## skipped when anything else has weight, so a bot does not repeat itself; [param roll] is 0 to 1.
func pick(roll: float, last: StringName = &"") -> StringName:
	var weights: Array[float] = []
	var total := 0.0
	for b in BEHAVIOURS:
		var w := float(mix.get(b, 0.0))
		weights.append(w)
		total += w
	if total <= 0.0:
		for i in weights.size():
			weights[i] = 1.0
		total = float(weights.size())
	var others := total
	var at := BEHAVIOURS.find(last)
	if at >= 0 and total - weights[at] > 0.0:
		others = total - weights[at]
		weights[at] = 0.0
	var point := clampf(roll, 0.0, 0.999999) * others
	for i in BEHAVIOURS.size():
		point -= weights[i]
		if point < 0.0:
			return BEHAVIOURS[i]
	return BEHAVIOURS[BEHAVIOURS.size() - 1]


## A [DotBotProfile] for this persona over [param base]: its difficulty (the base's when blank) and skill values.
## Null when the persona states neither, so the bot keeps sharing the game's live settings.
func profile_over(base: DotBotProfile) -> DotBotProfile:
	if difficulty == "" and skill.is_empty():
		return null
	var out: DotBotProfile = DotBotProfile.preset(difficulty) if difficulty != "" else base.copy()
	if out == null:
		out = base.copy()
	for field in skill:
		out.set_field(str(field), str(skill[field]))
	return out


## Writes this persona's profile for one bot into [param out], in place: [param base] (or the persona's
## difficulty), its skill values, its scale, then the bot's own [member spread] drawn from [param bot_seed].
## turn_rate never rises above the base's: bot_turn_rate is the server's promise of the fastest view.
func derive_into(out: DotBotProfile, base: DotBotProfile, bot_seed: int) -> void:
	var start: DotBotProfile = DotBotProfile.preset(difficulty) if difficulty != "" else null
	out.copy_from(start if start != null else base)
	for field in skill:
		out.set_number(str(field), float(skill[field]))
	for field in scale:
		var name := str(field)
		if not DotBotProfile.spec_for(name).is_empty():
			out.set_number(name, out.get_field(name) * maxf(float(scale[field]), 0.0))
	if spread > 0.0:
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([String(id), bot_seed])
		for name in SPREAD_FIELDS:
			out.set_number(name, out.get_field(name) * (1.0 + rng.randf_range(-spread, spread)))
	out.turn_rate = minf(out.turn_rate, base.turn_rate)


## True when [method derive_into] would change anything over the base.
func shapes_skill() -> bool:
	return difficulty != "" or not skill.is_empty() or not scale.is_empty() or spread > 0.0


## How much this persona leans to defending, attacking and supporting (x, y, z, each 0 to 1), from its mix:
## holding leans to defence, hunting and scouting to attack, supporting to support.
func role_bias() -> Vector3:
	var total := 0.0
	for b in BEHAVIOURS:
		total += maxf(0.0, float(mix.get(b, 0.0)))
	if total <= 0.0:
		return Vector3.ZERO
	var hold := maxf(0.0, float(mix.get(HOLD, 0.0)))
	var attack := maxf(0.0, float(mix.get(HUNT, 0.0))) + maxf(0.0, float(mix.get(SCOUT, 0.0)))
	var support := maxf(0.0, float(mix.get(SUPPORT, 0.0)))
	return (Vector3(hold, attack, support) / total).clamp(Vector3.ZERO, Vector3.ONE)


func describe() -> Dictionary:
	return {"id": String(id), "weight": weight, "difficulty": difficulty, "mix": mix.duplicate(), "skill": skill.duplicate(), "scale": scale.duplicate(), "spread": spread}
