class_name DotBotDemoSchema
extends RefCounted

## What one kind of episode records: a name, a version and two ordered field lists, each field a name, a size and a scale.
##
## The host declares it; dot-bot knows nothing of bodies or buttons. The id is a hash of the
## fields, so a game that changes what it records starts a new set instead of mixing two.

## Field row columns.
const COL_NAME := 0
const COL_SIZE := 1
const COL_SCALE := 2
const COL_DISCRETE := 3

var kind: String = ""
var version: int = 1

## Rows of [name, size, scale, discrete].
var observation: Array = []
var action: Array = []

## Outcomes worth keeping; empty keeps every outcome.
var keep_outcomes: PackedStringArray = PackedStringArray()

var _id: String = ""


static func make(p_kind: String, p_version: int = 1) -> DotBotDemoSchema:
	var s := DotBotDemoSchema.new()
	s.kind = p_kind
	s.version = p_version
	return s


## Adds an observation field of [param size] floats, each divided by [param scale] when learned from.
func add_observation(field: String, size: int = 1, scale: float = 1.0) -> DotBotDemoSchema:
	observation.append([field, size, scale, false])
	_id = ""
	return self


## Adds an action field. A [param discrete] field (buttons) keeps the most frequent value over a gap, not the mean.
func add_action(field: String, size: int = 1, scale: float = 1.0, discrete: bool = false) -> DotBotDemoSchema:
	action.append([field, size, scale, discrete])
	_id = ""
	return self


func keeps(outcome: String) -> bool:
	return keep_outcomes.is_empty() or keep_outcomes.has(outcome)


func observation_size() -> int:
	return _total(observation)


func action_size() -> int:
	return _total(action)


## Floats per kept tick.
func frame_size() -> int:
	return observation_size() + action_size()


func has_discrete() -> bool:
	for row: Array in action:
		if bool(row[COL_DISCRETE]):
			return true
	return false


## Fails with CODE_INVALID naming the first problem.
func validate() -> DotResult:
	if kind.strip_edges() == "" or kind.contains(",") or kind.contains("/") or kind.contains("@"):
		return DotResult.fail(DotError.CODE_INVALID, "A schema kind is a plain word, not '%s'." % kind)
	if version < 1:
		return DotResult.fail(DotError.CODE_INVALID, "Schema '%s' has version %d, which must be 1 or more." % [kind, version])
	if observation.is_empty() or action.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Schema '%s' needs at least one observation and one action field." % kind)
	var seen := {}
	for group: Array in [observation, action]:
		for row: Array in group:
			var field := String(row[COL_NAME])
			if field == "" or seen.has(field):
				return DotResult.fail(DotError.CODE_INVALID, "Schema '%s' has an empty or repeated field '%s'." % [kind, field])
			seen[field] = true
			if int(row[COL_SIZE]) < 1:
				return DotResult.fail(DotError.CODE_INVALID, "Field '%s' of '%s' has size %d." % [field, kind, int(row[COL_SIZE])])
			if float(row[COL_SCALE]) <= 0.0:
				return DotResult.fail(DotError.CODE_INVALID, "Field '%s' of '%s' needs a scale above zero." % [field, kind])
	return DotResult.success(self)


## A hash of the kind, version and fields.
func schema_id() -> String:
	if _id == "":
		_id = ("%s|%d|%s|%s" % [kind, version, var_to_str(observation), var_to_str(action)]).sha256_text().substr(0, 16)
	return _id


func describe() -> String:
	return "%s v%d %s (%d observed, %d acted)" % [kind, version, schema_id(), observation_size(), action_size()]


static func _total(rows: Array) -> int:
	var n := 0
	for row: Array in rows:
		n += int(row[COL_SIZE])
	return n
