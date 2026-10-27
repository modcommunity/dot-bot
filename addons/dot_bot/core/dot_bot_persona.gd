@tool
class_name DotBotPersona
extends RefCounted

## One kind of bot character: how often it picks each behaviour when nothing is in front of it,
## how likely a server is to give it to a bot, and how well it shoots.
##
## [b]Idle is never a behaviour.[/b] A bot with nothing to shoot used to stand at its post; now
## it picks the next of [constant BEHAVIOURS] from this mix, so a lobby of eight is eight bots
## doing different things. The data is a profile (kind `bot`, [method schema]), so it can be
## added, edited and deleted live in dot-workbench without this addon naming dot-profile.

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


## The `bot` profile schema as plain dictionaries (the shape of dot-profile's field()), so dot-bot needs no dot-profile.
static func schema() -> Array:
	var out: Array = [
		{"name": "name", "type": "string", "default": ""},
		{"name": "weight", "type": "float", "default": 1.0, "min": 0.0, "max": 1000.0},
		{"name": "difficulty", "type": "string", "default": "", "enum": ["", "easy", "medium", "hard", "nightmare"]},
		{"name": "skill", "type": "dict", "default": {}},
		{"name": "enabled", "type": "bool", "default": true},
	]
	for b in BEHAVIOURS:
		out.append({"name": String(b), "type": "float", "default": 1.0, "min": 0.0, "max": 100.0})
	return out


## A persona from [param values] (a profile's `values` dictionary); unknown keys are ignored.
static func from_values(p_id: String, values: Dictionary) -> DotBotPersona:
	var out := DotBotPersona.new()
	out.id = StringName(p_id)
	out.display_name = str(values.get("name", "")) if str(values.get("name", "")) != "" else p_id.capitalize()
	out.weight = maxf(float(values.get("weight", 1.0)), 0.0)
	out.difficulty = str(values.get("difficulty", ""))
	var raw: Variant = values.get("skill", {})
	out.skill = (raw as Dictionary).duplicate() if raw is Dictionary else {}
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


func describe() -> Dictionary:
	return {"id": String(id), "weight": weight, "difficulty": difficulty, "mix": mix.duplicate(), "skill": skill.duplicate()}
