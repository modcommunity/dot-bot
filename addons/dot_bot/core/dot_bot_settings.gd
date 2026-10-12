class_name DotBotSettings
extends RefCounted

## The live bot settings of one game: the chosen preset, the individual overrides, and the
## cvars or console variables that change them.
##
## [codeblock]
## bot_difficulty   easy | medium | hard | nightmare   (default medium)
## bot_<field>      every row of DotBotProfile.SPEC: bot_reaction, bot_aim_error, ...
## bot_settings     (command) every value, overridden ones marked
## bot_settings_reset (command) drop the overrides, back to the preset's values
## [/codeblock]
##
## [b]An override outlives a preset change.[/b] A server's config sets cvars in the order
## its file lists them, and an owner who wrote `bot_reaction 0.4` above `bot_difficulty hard`
## meant both. So choosing a preset rewrites every setting the owner has NOT set; the ones
## they set stay, and `bot_settings_reset` is how they go back. The cvars themselves always
## hold the value the bots use, so `bot_reaction` typed alone answers truthfully.
##
## [b]Server and solo, one object.[/b] [method bind_cvars] takes dot-server's
## `DotModule.add_cvar` and [method bind_console] dot-console's `DotConsoleLocal`, both by
## duck typing, so this addon depends on dot-core alone and a solo game with no server in
## the process has the same names.
##
## [b]Per game, never per process.[/b] [method attach] puts it on a node as metadata, never
## in [DotRegistry], because this family runs two servers in one process in its suites and
## they must not share a difficulty.

const CHANNEL := "dot.bot"

## Where [method attach] keeps this on a node.
const META := &"dot_bot_settings"

const CVAR_DIFFICULTY := "bot_difficulty"
const COMMAND_SHOW := "bot_settings"
const COMMAND_RESET := "bot_settings_reset"

## Emitted after anything changed.
signal changed

## The values every bot uses now: the preset with the overrides on top. Never replaced, so a
## brain may hold it.
var profile: DotBotProfile = DotBotProfile.preset(DotBotProfile.DEFAULT_PRESET)

## Fields set by hand, field -> value. They survive a preset change.
var overrides: Dictionary = {}

## Bumped on every change. A brain compares it rather than connecting a signal per bot.
var revision: int = 0

## The cvar objects [method bind_cvars] made, name -> object, so a preset can write them.
var _cvars: Dictionary = {}

## True while this writes its own cvars, so their `changed` is not taken for an override.
var _writing: bool = false


## The settings on [param node], made (at the default preset) and attached if missing.
static func of(node: Object) -> DotBotSettings:
	if node == null:
		return DotBotSettings.new()
	if node.has_meta(META):
		var held: Variant = node.get_meta(META)
		if held is DotBotSettings:
			return held
	var made := DotBotSettings.new()
	node.set_meta(META, made)
	return made


## Puts [param settings] on [param node], replacing what was there.
static func attach(node: Object, settings: DotBotSettings) -> DotBotSettings:
	if node != null:
		node.set_meta(META, settings)
	return settings


func difficulty() -> String:
	return profile.preset_name


## Chooses a preset. Every setting not overridden takes the preset's value.
func set_difficulty(name: String) -> DotResult:
	var fresh := DotBotProfile.preset(name)
	if fresh == null:
		return DotResult.fail(DotError.CODE_INVALID, "bot_difficulty is %s, not '%s'." % [", ".join(DotBotProfile.PRESETS), name])

	var _applied := profile.apply_preset(name)
	for field: String in overrides:
		profile.set(StringName(field), float(overrides[field]))

	_write_cvars()
	_bump()
	DotLog.info(CHANNEL, "bot difficulty", {"preset": profile.preset_name, "overrides": overrides.keys()})
	return DotResult.success(profile.preset_name)


## Overrides one setting. [param field] is a SPEC field, without the `bot_` prefix.
func set_value(field: String, text: String) -> DotResult:
	var res := profile.set_field(field, text)
	if not res.ok:
		return res
	overrides[field] = float(res.value)
	_write_cvar(field)
	_bump()
	DotLog.debug(CHANNEL, "bot setting overridden", {"field": field, "value": res.value})
	return res


## Drops every override; the preset's values come back.
func reset_overrides() -> void:
	overrides.clear()
	var _res := set_difficulty(profile.preset_name)


func is_overridden(field: String) -> bool:
	return overrides.has(field)


# --- Server cvars ---------------------------------------------------------------

## Registers `bot_difficulty` and every `bot_<field>` through [param add], which is called as
## [code]add(name, default, description, flags)[/code] and returns the cvar (dot-server's
## [code]DotModule.add_cvar[/code]), and the two commands through [param add_command] when it
## is valid ([code]add_command(name, handler, description)[/code], the handler taking a
## context with [code]reply[/code]). Returns the cvars made.
##
## The cvar's value is read back after registering: a server config that ran before the
## module did leaves a value waiting, and this is how it reaches the bots.
func bind_cvars(add: Callable, flags: int = 0, add_command: Callable = Callable()) -> Array:
	var made: Array = []

	var diff: Variant = add.call(
		CVAR_DIFFICULTY, profile.preset_name,
		"Bot difficulty preset: %s. Sets every bot_* setting not overridden by hand." % ", ".join(DotBotProfile.PRESETS),
		flags
	)
	if diff is Object and diff != null:
		var cv := diff as Object
		if cv.has_method(&"with_validator"):
			# A static method, not a lambda: a lambda's script can be gone before the console
			# that holds it at engine teardown, which aborts the process at exit.
			cv.call(&"with_validator", DotBotSettings._valid_preset)
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_difficulty_cvar.bind(cv))
		_cvars[CVAR_DIFFICULTY] = cv
		made.append(cv)

	for row: Array in DotBotProfile.SPEC:
		var field := String(row[DotBotProfile.COL_FIELD])
		var cvar_name := "bot_" + field
		var c: Variant = add.call(cvar_name, DotBotProfile._fmt(profile.get_field(field)), String(row[DotBotProfile.COL_HELP]), flags)
		if not (c is Object) or c == null:
			continue
		var cv := c as Object
		if cv.has_method(&"with_range"):
			cv.call(&"with_range", float(row[DotBotProfile.COL_MIN]), float(row[DotBotProfile.COL_MAX]))
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_field_cvar.bind(field, cv))
		_cvars[cvar_name] = cv
		made.append(cv)

	if add_command.is_valid():
		add_command.call(COMMAND_SHOW, _cmd_show, "Every bot setting; * marks one set by hand.")
		add_command.call(COMMAND_RESET, _cmd_reset, "Drop the hand-set bot settings, back to the preset.")

	# Values a config set before this registered. All read before any is applied: choosing
	# the preset writes every setting's cvar, which would wipe a waiting override.
	var waiting := _cvar_string(CVAR_DIFFICULTY)
	var waiting_fields := {}
	for row: Array in DotBotProfile.SPEC:
		var field := String(row[DotBotProfile.COL_FIELD])
		var text := _cvar_string("bot_" + field)
		if text != "" and text.is_valid_float() and not is_equal_approx(text.to_float(), profile.get_field(field)):
			waiting_fields[field] = text
	if waiting != "" and waiting != profile.preset_name:
		var _res := set_difficulty(waiting)
	for field: String in waiting_fields:
		var _set := set_value(field, waiting_fields[field])

	return made


static func _valid_preset(value: String) -> DotResult:
	if DotBotProfile.preset_column(value) >= 0:
		return DotResult.success(value.strip_edges().to_lower())
	return DotResult.fail(DotError.CODE_INVALID, "bot_difficulty is %s." % ", ".join(DotBotProfile.PRESETS))


func _on_difficulty_cvar(_old: String, new_value: String, _cv: Object) -> void:
	if _writing:
		return
	var _res := set_difficulty(new_value)


func _on_field_cvar(_old: String, new_value: String, field: String, _cv: Object) -> void:
	if _writing:
		return
	var _res := set_value(field, new_value)


func _cmd_show(ctx: Object) -> void:
	for line in describe_lines():
		if ctx != null and ctx.has_method(&"reply"):
			ctx.call(&"reply", line)


func _cmd_reset(ctx: Object) -> void:
	reset_overrides()
	if ctx != null and ctx.has_method(&"reply"):
		ctx.call(&"reply", "bot settings back to %s" % profile.preset_name)


func _cvar_string(cvar_name: String) -> String:
	var cv: Variant = _cvars.get(cvar_name)
	if cv is Object and cv != null and (cv as Object).has_method(&"get_string"):
		return String((cv as Object).call(&"get_string"))
	return ""


func _write_cvars() -> void:
	if _cvars.has(CVAR_DIFFICULTY):
		_force(_cvars[CVAR_DIFFICULTY], profile.preset_name)
	for field in DotBotProfile.fields():
		_write_cvar(field)


func _write_cvar(field: String) -> void:
	var cv: Variant = _cvars.get("bot_" + field)
	if cv is Object and cv != null:
		_force(cv, DotBotProfile._fmt(profile.get_field(field)))


func _force(cv: Object, text: String) -> void:
	if cv.has_method(&"get_string") and String(cv.call(&"get_string")) == text:
		return
	_writing = true
	if cv.has_method(&"force_set"):
		cv.call(&"force_set", text)
	elif cv.has_method(&"set_value"):
		cv.call(&"set_value", text)
	_writing = false


# --- Solo console ---------------------------------------------------------------

## Adds `bot_difficulty`, every `bot_<field>` and the two commands to [param local], anything
## with dot-console's [code]add_var(name, help, get, set)[/code] and
## [code]add_command(name, help, fn)[/code]. False when it has neither.
func bind_console(local: Object) -> bool:
	if local == null or not local.has_method(&"add_var"):
		return false

	local.call(&"add_var", StringName(CVAR_DIFFICULTY),
		"Bot difficulty preset: %s." % ", ".join(DotBotProfile.PRESETS),
		func() -> Variant: return profile.preset_name,
		func(v: Variant) -> Variant: return set_difficulty(str(v))
	)

	for row: Array in DotBotProfile.SPEC:
		var field := String(row[DotBotProfile.COL_FIELD])
		local.call(&"add_var", StringName("bot_" + field), String(row[DotBotProfile.COL_HELP]),
			func() -> Variant: return DotBotProfile._fmt(profile.get_field(field)),
			func(v: Variant) -> Variant: return set_value(field, str(v))
		)

	if local.has_method(&"add_command"):
		local.call(&"add_command", StringName(COMMAND_SHOW), "Every bot setting; * marks one set by hand.",
			func(_a: PackedStringArray) -> Variant: return describe_lines()
		)
		local.call(&"add_command", StringName(COMMAND_RESET), "Drop the hand-set bot settings, back to the preset.",
			func(_a: PackedStringArray) -> Variant:
				reset_overrides()
				return "bot settings back to %s" % profile.preset_name
		)
	return true


# --- Reading it ----------------------------------------------------------------

func _bump() -> void:
	revision += 1
	changed.emit()


func describe() -> Dictionary:
	return {"difficulty": profile.preset_name, "overrides": overrides.duplicate(), "revision": revision}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["bot_difficulty %s" % profile.preset_name])
	for field in DotBotProfile.fields():
		out.append("%s bot_%-14s %s" % ["*" if overrides.has(field) else " ", field, DotBotProfile._fmt(profile.get_field(field))])
	return out
