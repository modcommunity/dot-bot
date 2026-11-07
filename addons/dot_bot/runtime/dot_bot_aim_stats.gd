class_name DotBotAimStats
extends RefCounted

## How quickly and how well people aim on one map version, folded from recorded `engage` episodes into percentile sketches. No episode is kept once folded.
##
## An episode starts when a player first has an enemy in view and ends at their first hit or when the enemy leaves view. Nothing that identifies a person is kept.

const KIND := "engage"

## The measures, each with the range its sketch covers (a value past it counts in the end bin).
const METRICS := {
	"reaction": 3.0,
	"aim_error": 30.0,
	"tracking": 30.0,
	"time_to_kill": 10.0,
}

## Which measure sets which SPEC row; every one is lower-is-better.
const SPEC_FIELDS := {"reaction": "reaction", "aim_error": "aim_error", "aim_floor": "tracking"}

## Percentile of people (by skill) each preset takes; nightmare keeps its own numbers.
const PRESET_PERCENTILES := {"easy": 20.0, "medium": 50.0, "hard": 80.0}

const BINS := 300

## Floats into a frame (observation first): the view's error off the target in degrees, and the fired flag (above 0.5).
var error_index: int = 0
var fire_index: int = 1

## Tracking error in degrees while the target moves; a negative value means it did not, and -1 for no such field.
var track_index: int = -1

## The outcome that means the player killed the target; the episode's length is then the time to kill.
var kill_outcome: String = "kill"

## Faster than any person: a reaction under this many seconds, or a first-second error under [member min_error] degrees, is a cheat and dropped.
var min_reaction: float = 0.1
var min_error: float = 0.05

## Fewest episodes a label needs before a percentile of it is given.
var min_count: int = 30

## A host's exclusion of an episode (a moderation flag): called with the episode, true keeps it.
var include_fn: Callable = Callable()

var map_id: String = ""
var map_version: String = ""

## Episodes dropped as cheats or by [member include_fn].
var dropped: int = 0

# label -> {metric: PackedInt32Array(BINS)}
var _sketches: Dictionary = {}
var _episodes: Dictionary = {}
var _total: int = 0


## Folds one episode; another kind, map or version, a frame too small, or no first shot is refused (false), a cheat or excluded one is dropped (false, counted).
func fold(ep: DotBotDemoEpisode) -> bool:
	if ep.kind != KIND or ep.sample_count() == 0 or ep.rate <= 0.0 or ep.frame_size <= maxi(error_index, maxi(fire_index, track_index)):
		return false
	if _total > 0 and (ep.map_id != map_id or ep.map_version != map_version):
		return false
	var reaction := -1.0
	var err_sum := 0.0
	var err_n := 0
	var track_sum := 0.0
	var track_n := 0
	for i in ep.sample_count():
		var base := i * ep.frame_size
		var t := i / ep.rate
		if reaction < 0.0 and ep.ticks[base + fire_index] > 0.5:
			reaction = t
		if t < 1.0:
			err_sum += ep.ticks[base + error_index]
			err_n += 1
		if track_index >= 0 and ep.ticks[base + track_index] >= 0.0:
			track_sum += ep.ticks[base + track_index]
			track_n += 1
	if reaction < 0.0:
		return false
	var first_error := err_sum / err_n
	if reaction < min_reaction or first_error < min_error or (include_fn.is_valid() and not include_fn.call(ep)):
		dropped += 1
		return false
	map_id = ep.map_id
	map_version = ep.map_version
	var sketch: Dictionary = _sketches.get(ep.key, {})
	_add(sketch, "reaction", reaction)
	_add(sketch, "aim_error", first_error)
	if track_n > 0:
		_add(sketch, "tracking", track_sum / track_n)
	if ep.outcome == kill_outcome:
		_add(sketch, "time_to_kill", ep.sample_count() / ep.rate)
	_sketches[ep.key] = sketch
	_episodes[ep.key] = int(_episodes.get(ep.key, 0)) + 1
	_total += 1
	return true


## Folds the `engage` episodes of a store for the labels named (a label is an episode key such as a game); the value is how many were folded.
func fold_store(store: DotBotDemoStore, p_map_id: String, p_version: String, labels: Array, limit: int = 500) -> DotResult:
	var folded := 0
	for label: String in labels:
		var res: DotResult = await store.load(p_map_id, p_version, KIND, label, limit)
		if not res.ok:
			return res
		for ep: DotBotDemoEpisode in res.value:
			if fold(ep):
				folded += 1
	return DotResult.success(folded)


## Episodes folded for [param label] ("" adds every label).
func episode_count(label: String = "") -> int:
	return _total if label == "" else int(_episodes.get(label, 0))


## The [param pct]th percentile (0 to 100) of [param metric] over the people, or NAN when the label has fewer than [member min_count] episodes or measured it too seldom.
func percentile(metric: String, pct: float, label: String = "") -> float:
	if not METRICS.has(metric) or episode_count(label) < min_count:
		return NAN
	var bins := PackedInt32Array()
	bins.resize(BINS)
	var n := 0
	for key: String in _sketches:
		if label != "" and key != label:
			continue
		var theirs: PackedInt32Array = (_sketches[key] as Dictionary).get(metric, PackedInt32Array())
		for i in theirs.size():
			bins[i] += theirs[i]
			n += theirs[i]
	if n < min_count:
		return NAN
	var want := clampf(pct, 0.0, 100.0) / 100.0 * n
	var seen := 0.0
	var width: float = float(METRICS[metric]) / BINS
	for i in BINS:
		if bins[i] > 0 and seen + bins[i] >= want:
			return (i + (want - seen) / bins[i]) * width
		seen += bins[i]
	return float(METRICS[metric])


## Every measure at the 20th, 50th and 80th percentile, for a consumer that wants numbers rather than presets (dot-npc-ai's `from_percentiles`, duck typed).
func percentiles(label: String = "") -> Dictionary:
	var out := {}
	for metric: String in METRICS:
		var row := {}
		for pct in [20, 50, 80]:
			row["p%d" % pct] = percentile(metric, pct, label)
		out[metric] = row
	return out


## A suggested value for every SPEC row this measures, per preset: [code]{preset: {field: value}}[/code]. Easy takes the 20th percentile of people by skill (the slow end), medium the 50th, hard the 80th, each inside the row's range and never harder than nightmare, whose numbers stay as they are. Empty when there is too little data; a row whose measure was never recorded (no tracking field) is left out.
func suggest(spec: Array = DotBotProfile.SPEC, label: String = "") -> Dictionary:
	var out := {}
	if episode_count(label) < min_count:
		return out
	for preset: String in PRESET_PERCENTILES:
		out[preset] = {}
	for row: Array in spec:
		var field: String = row[DotBotProfile.COL_FIELD]
		if not SPEC_FIELDS.has(field):
			continue
		var metric: String = SPEC_FIELDS[field]
		var nightmare := float(row[DotBotProfile.COL_FIRST_PRESET + DotBotProfile.PRESETS.find("nightmare")])
		for preset: String in PRESET_PERCENTILES:
			var value := percentile(metric, 100.0 - float(PRESET_PERCENTILES[preset]), label)
			if is_nan(value):
				continue
			out[preset][field] = clampf(value, maxf(float(row[DotBotProfile.COL_MIN]), nightmare), float(row[DotBotProfile.COL_MAX]))
	return out


## The suggestion beside the current numbers, for a person to review.
func suggest_lines(spec: Array = DotBotProfile.SPEC, label: String = "") -> PackedStringArray:
	var lines := PackedStringArray()
	var table := suggest(spec, label)
	if table.is_empty():
		lines.append("not enough episodes for %s@%s (%d, need %d)" % [map_id, map_version, episode_count(label), min_count])
		return lines
	lines.append("%-12s %-8s %8s %8s" % ["field", "preset", "now", "suggest"])
	for field: String in SPEC_FIELDS:
		for preset: String in PRESET_PERCENTILES:
			if not table[preset].has(field):
				continue
			lines.append("%-12s %-8s %8.3f %8.3f" % [field, preset, DotBotProfile.preset_value(preset, field), table[preset][field]])
	return lines


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["aim stats %s@%s: %d episodes, %d dropped, %d labels" % [map_id, map_version, _total, dropped, _sketches.size()]])


func _add(sketch: Dictionary, metric: String, value: float) -> void:
	var bins: PackedInt32Array = sketch.get(metric, PackedInt32Array())
	if bins.is_empty():
		bins.resize(BINS)
	bins[clampi(int(value / float(METRICS[metric]) * BINS), 0, BINS - 1)] += 1
	sketch[metric] = bins
