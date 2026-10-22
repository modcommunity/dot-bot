class_name DotBotDemoConfig
extends DotConfig

## The recorder's settings: exported defaults < JSON file < environment < command line, and the bot_record* cvars.
##
## On by default, server-wide only. [code]bot_record 0[/code] (or [code]record: false[/code])
## switches it off; there is no per-player switch because nothing identifying is kept.

const STORES: Array[String] = ["json", "sqlite", "postgres", "mysql", "memory", "off"]

## Master switch; false stops recording and flushes what is queued.
@export var record: bool = true

## Comma list of kinds to record; empty is every kind the game declares.
@export var kinds: String = ""

## Base sample rate in Hz.
@export var rate: float = 16.0

## Rate while a key has few episodes; 0 is the host's tick rate.
@export var rate_max: float = 0.0

## Verified episodes per key at which the rate is back at base.
@export var target: int = 40

## Episodes kept per key.
@export var cap: int = 200

@export var store: String = "json"

## The JSON store's directory, or the SQLite file.
@export var path: String = "user://dot_bot/demos"

## The dot-sql gateway for Postgres and MySQL.
@export var url: String = ""

## Config file only: never read from the environment or the command line.
@export var token: String = ""

## Seconds between writes of the queued episodes.
@export var flush: float = 10.0

var _cvars: Dictionary = {}


func env_prefix() -> String:
	return "DOT_BOT_RECORD_"


func cli_prefix() -> String:
	return "--bot-record-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["token"])


func validate() -> DotResult:
	if rate <= 0.0 or rate > 1000.0:
		return DotResult.fail(DotError.CODE_INVALID, "bot_record_rate is %s; it must be above 0 and at most 1000." % rate)
	if rate_max < 0.0 or (rate_max > 0.0 and rate_max < rate):
		return DotResult.fail(DotError.CODE_INVALID, "bot_record_rate_max is %s; it is 0 (the tick rate) or at least bot_record_rate." % rate_max)
	if target < 1 or cap < 1:
		return DotResult.fail(DotError.CODE_INVALID, "bot_record_target and bot_record_cap must be 1 or more.")
	if not STORES.has(store):
		return DotResult.fail(DotError.CODE_INVALID, "bot_record_store is %s, not '%s'." % [", ".join(STORES), store])
	if flush <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "bot_record_flush must be above 0 seconds.")
	return DotResult.success(self)


## True when [param kind] is one the server records.
func records_kind(kind: String) -> bool:
	if kinds.strip_edges() == "":
		return true
	for part in kinds.split(","):
		if part.strip_edges() == kind:
			return true
	return false


## The effective maximum rate for a host ticking at [param tick_rate].
func effective_rate_max(tick_rate: float) -> float:
	return maxf(rate, tick_rate if rate_max <= 0.0 else rate_max)


## Registers a cvar per setting (never the token) through dot-server's `add_cvar`, by duck typing; returns them.
func bind_cvars(add: Callable, flags: int = 0) -> Array:
	var made: Array = []
	for key in config_keys():
		if sensitive_keys().has(key):
			continue
		var cvar_name := "bot_record" if key == "record" else "bot_record_" + key
		var c: Variant = add.call(cvar_name, _text(get(key)), "Demonstration recorder: %s." % key, flags)
		if not (c is Object) or c == null:
			continue
		var cv := c as Object
		if cv.has_method(&"with_validator"):
			cv.call(&"with_validator", _validator(key))
		if cv.has_signal(&"changed"):
			cv.connect(&"changed", _on_cvar.bind(key))
		_cvars[key] = cv
		made.append(cv)
		# A value a config set before this registered.
		var waiting := cv.call(&"get_string") if cv.has_method(&"get_string") else ""
		if String(waiting) != "" and String(waiting) != _text(get(key)):
			_apply_text(key, String(waiting))
	return made


func describe_lines(redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("recording: %s" % ("ON" if record else "off (bot_record 0)"))
	out.append_array(super.describe_lines(redact_sensitive))
	return out


func _validator(key: String) -> Callable:
	match key:
		"record":
			return DotBotDemoConfig._valid_bool
		"kinds", "store", "path", "url":
			return DotBotDemoConfig._valid_text
	return DotBotDemoConfig._valid_number


static func _valid_bool(value: String) -> DotResult:
	var t := value.strip_edges().to_lower()
	if t in ["1", "true", "on"]:
		return DotResult.success("1")
	if t in ["0", "false", "off"]:
		return DotResult.success("0")
	return DotResult.fail(DotError.CODE_INVALID, "bot_record is 0 or 1.")


static func _valid_number(value: String) -> DotResult:
	if not value.strip_edges().is_valid_float() or value.to_float() < 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a number of 0 or more." % value)
	return DotResult.success(value.strip_edges())


static func _valid_text(value: String) -> DotResult:
	return DotResult.success(value.strip_edges())


static func _text(v: Variant) -> String:
	if v is bool:
		return "1" if v else "0"
	return str(v)


func _on_cvar(_old: String, new_value: String, key: String) -> void:
	_apply_text(key, new_value)


func _apply_text(key: String, text: String) -> void:
	var old: Variant = get(key)
	match typeof(old):
		TYPE_BOOL:
			set(key, text.strip_edges().to_lower() in ["1", "true", "on"])
		TYPE_INT:
			set(key, maxi(1, int(text.to_float())))
		TYPE_FLOAT:
			set(key, text.to_float())
		_:
			set(key, text.strip_edges())
	var valid := validate()
	if not valid.ok:
		set(key, old)
		DotLog.warn(DotBotDemoRecorder.CHANNEL, "Refused %s: %s" % [key, valid.error.message])
