class_name DotBotPersonaPool
extends RefCounted

## The personas a server draws from, and who got which.
##
## [b]Weighted, with a per-server override.[/b] Each persona's `weight` is its chance; an
## operator's override (`id:weight,id:weight`, see [method parse_override]) replaces those
## weights and drops every persona it does not name, so a server can run only medics. With
## no personas at all the pool holds one balanced character, never nothing.

const CHANNEL := "dot.bot"

var personas: Array[DotBotPersona] = []
## id -> weight from [method parse_override]; empty for the personas' own.
var override: Dictionary = {}

var _given: Dictionary = {}


## Replaces the personas with those of [param set] (a dot-profile set of kind `bot`, reached by duck typing); disabled ones are left out.
func load_from(set: Object) -> int:
	personas.clear()
	if set != null:
		for id: String in set.call(&"list_ids"):
			var res: Variant = set.call(&"load_profile", id)
			if res == null or not res.ok:
				DotLog.warn(CHANNEL, "bot persona skipped", {"id": id})
				continue
			var values: Dictionary = res.value.values
			if bool(values.get("enabled", true)):
				personas.append(DotBotPersona.from_values(id, values))
	return personas.size()


## `"medic:3,scout:1"` into `{medic: 3.0, scout: 1.0}`; bad pieces are skipped. A bare id weighs 1.
static func parse_override(text: String) -> Dictionary:
	var out := {}
	for piece in text.split(",", false):
		var parts := piece.strip_edges().split(":")
		if parts[0].strip_edges() == "":
			continue
		var w := parts[1].strip_edges().to_float() if parts.size() > 1 and parts[1].strip_edges().is_valid_float() else 1.0
		out[StringName(parts[0].strip_edges())] = maxf(w, 0.0)
	return out


func set_override(text: String) -> void:
	override = parse_override(text)


## The weight [param persona] has now.
func weight_of(persona: DotBotPersona) -> float:
	if override.is_empty():
		return persona.weight
	return float(override.get(persona.id, 0.0))


## The personas that can be drawn, in order.
func candidates() -> Array[DotBotPersona]:
	var out: Array[DotBotPersona] = []
	for p in personas:
		if weight_of(p) > 0.0:
			out.append(p)
	if out.is_empty():
		out.append(DotBotPersona.new())
	return out


## One persona by weight; [param roll] is 0 to 1.
func draw(roll: float) -> DotBotPersona:
	var list := candidates()
	var total := 0.0
	for p in list:
		total += weight_of(p) if not personas.is_empty() else 1.0
	var point := clampf(roll, 0.0, 0.999999) * total
	for p in list:
		point -= weight_of(p) if not personas.is_empty() else 1.0
		if point < 0.0:
			return p
	return list[list.size() - 1]


## The persona for [param bot]: kept for as long as the bot lasts, drawn with [param rng] the first time.
func assign(bot: StringName, rng: RandomNumberGenerator) -> DotBotPersona:
	if _given.has(bot):
		return _given[bot]
	var p := draw(rng.randf())
	_given[bot] = p
	DotLog.debug(CHANNEL, "bot persona drawn", {"bot": String(bot), "persona": String(p.id)})
	return p


func release(bot: StringName) -> void:
	_given.erase(bot)


## Forgets who has what, so the next draw is new (after the personas or the override changed).
func reset_assignments() -> void:
	_given.clear()


func describe() -> Dictionary:
	var given := {}
	for bot in _given:
		given[String(bot)] = String((_given[bot] as DotBotPersona).id)
	return {"personas": personas.size(), "override": override.duplicate(), "given": given}
