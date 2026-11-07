class_name DotBotDemoExport
extends RefCounted

## Verified episodes of one schema as a behaviour-cloning dataset: `manifest.json` and `shard_N.f32` files, split into train and held-out by episode.
##
## A shard is little-endian float32 rows, observation then action, raw (the manifest holds each field's scale), one split and one map version each, an episode never across two shards. Plain bytes, so the trainer needs no Godot.
## Nothing that identifies a person is written: the episode ids are the store's counters.
## [method load_manifest] and [method read_shard] treat the directory as untrusted: every size, name, count and float is checked before it is believed.

const CHANNEL := "bot.demo.export"
const FORMAT := "dotbot-bc"
const VERSION := 1
const MANIFEST := "manifest.json"
const SPLIT_TRAIN := "train"
const SPLIT_HELD_OUT := "held_out"
const SHARD_PATTERN := "^shard_[0-9]{1,6}\\.f32$"

## Limits a loader holds a directory to.
const MAX_MANIFEST_BYTES := 8 * 1024 * 1024
const MAX_SHARD_BYTES := 256 * 1024 * 1024
const MAX_SHARDS := 4096
const MAX_HELD_OUT := 1 << 20
const MAX_FIELDS := 256
const MAX_FIELD_SIZE := 4096
const MAX_FRAME_SIZE := 65536
const MAX_NAME := 64

## Rows a shard holds before the next one starts (an episode longer than this gets one to itself).
var max_shard_rows: int = 50000

## Share of each map version's episodes held out, by episode; at least one when the map has two or more, never all.
var held_out_fraction: float = 0.2

## Mixed into the split, so another seed holds out other episodes.
var split_seed: String = "bc1"

## Episodes [method add] refused: not verified, another schema, a bad frame, a non-finite value or a repeated id.
var rejected: int = 0

var _schema: DotBotDemoSchema
# "map_id@version" -> {map_id, map_version, episodes: Array}
var _groups: Dictionary = {}
var _seen: Dictionary = {}


func _init(p_schema: DotBotDemoSchema = null) -> void:
	_schema = p_schema


## A schema from the plain description a tool reads from JSON: {kind, version, observation: [[name, size, scale]], action: [[name, size, scale, discrete]]}.
static func schema_from_dictionary(d: Dictionary) -> DotResult:
	var s := DotBotDemoSchema.make(String(d.get("kind", "")), int(d.get("version", 1)))
	var obs: Variant = d.get("observation", [])
	var act: Variant = d.get("action", [])
	if not obs is Array or not act is Array:
		return DotResult.fail(DotError.CODE_INVALID, "A schema's observation and action are lists of rows.")
	for row: Variant in obs:
		if not row is Array or (row as Array).size() < 2:
			return DotResult.fail(DotError.CODE_INVALID, "An observation row is [name, size, scale].")
		var r := row as Array
		s.add_observation(String(r[0]), int(r[1]), float(r[2]) if r.size() > 2 else 1.0)
	for row: Variant in act:
		if not row is Array or (row as Array).size() < 2:
			return DotResult.fail(DotError.CODE_INVALID, "An action row is [name, size, scale, discrete].")
		var r := row as Array
		s.add_action(String(r[0]), int(r[1]), float(r[2]) if r.size() > 2 else 1.0, bool(r[3]) if r.size() > 3 else false)
	return s.validate()


## Adds one episode; false (and counted in [member rejected]) when it cannot be learned from.
func add(ep: DotBotDemoEpisode) -> bool:
	if _schema == null or not _schema.validate().ok or not ep.verified or ep.kind != _schema.kind or ep.schema_id != _schema.schema_id():
		rejected += 1
		return false
	var frame := _schema.frame_size()
	if ep.frame_size != frame or ep.ticks.is_empty() or ep.ticks.size() % frame != 0 or ep.map_id == "":
		rejected += 1
		return false
	for v in ep.ticks:
		if not is_finite(v):
			rejected += 1
			return false
	var group_key := "%s@%s" % [ep.map_id, ep.map_version]
	var seen_key := "%s#%d" % [group_key, ep.id]
	if _seen.has(seen_key):
		rejected += 1
		return false
	_seen[seen_key] = true
	if not _groups.has(group_key):
		_groups[group_key] = {"map_id": ep.map_id, "map_version": ep.map_version, "episodes": []}
	(_groups[group_key]["episodes"] as Array).append(ep)
	return true


## Adds the schema's episodes of [param labels] on one map version from a store; the value is how many were added.
func collect(store: DotBotDemoStore, map_id: String, map_version: String, labels: Array, limit: int = 0) -> DotResult:
	var added := 0
	for label: String in labels:
		var res: DotResult = await store.load(map_id, map_version, _schema.kind, label, limit)
		if not res.ok:
			return res
		for ep: DotBotDemoEpisode in res.value:
			if add(ep):
				added += 1
	return DotResult.success(added)


func episode_count() -> int:
	var n := 0
	for g: Dictionary in _groups.values():
		n += (g["episodes"] as Array).size()
	return n


## Writes the shards and then the manifest into [param dir]; the manifest's presence means the export is whole. A directory that already holds one is refused unless [param overwrite]. The value is the manifest dictionary.
func write(dir: String, overwrite: bool = false) -> DotResult:
	if _schema == null or not _schema.validate().ok:
		return DotResult.fail(DotError.CODE_INVALID, "An export needs a valid schema.")
	if episode_count() == 0:
		return DotResult.fail(DotError.CODE_INVALID, "No verified episodes of '%s' to export." % _schema.kind)
	if max_shard_rows < 1 or held_out_fraction < 0.0 or held_out_fraction >= 1.0:
		return DotResult.fail(DotError.CODE_INVALID, "max_shard_rows is 1 or more and held_out_fraction is in [0, 1).")
	var made := DotPaths.ensure_dir(dir)
	if not made.ok:
		return made
	if FileAccess.file_exists(dir.path_join(MANIFEST)):
		if not overwrite:
			return DotResult.fail(DotError.CODE_CONFLICT, "'%s' already holds an export." % dir)
		DirAccess.remove_absolute(dir.path_join(MANIFEST))
	_remove_shards(dir)

	var frame := _schema.frame_size()
	var shards: Array = []
	var held_out: Array = []
	var maps: Array = []
	var totals := {"train_episodes": 0, "held_out_episodes": 0, "train_rows": 0, "held_out_rows": 0}
	var keys := _groups.keys()
	keys.sort()
	for group_key: String in keys:
		var group: Dictionary = _groups[group_key]
		var split := _split(group["episodes"])
		var counts := {SPLIT_TRAIN: 0, SPLIT_HELD_OUT: 0}
		for part: String in [SPLIT_TRAIN, SPLIT_HELD_OUT]:
			var pending: Array = split[part]
			var run: Array = []
			var run_rows := 0
			for i in pending.size() + 1:
				var ep: DotBotDemoEpisode = pending[i] if i < pending.size() else null
				var rows: int = 0 if ep == null else ep.sample_count()
				if not run.is_empty() and (ep == null or run_rows + rows > max_shard_rows):
					var wrote := _write_shard(dir, shards.size(), part, group, run, frame)
					if not wrote.ok:
						return wrote
					shards.append(wrote.value)
					run = []
					run_rows = 0
				if ep == null:
					break
				run.append(ep)
				run_rows += rows
				counts[part] += 1
				totals[part + "_episodes"] += 1
				totals[part + "_rows"] += rows
				if part == SPLIT_HELD_OUT:
					held_out.append({
						"id": ep.id, "map_id": ep.map_id, "map_version": ep.map_version, "key": ep.key,
						"rate": ep.rate, "outcome": ep.outcome, "rows": rows, "start": ep.start,
					})
		maps.append({"id": group["map_id"], "version": group["map_version"], "train": counts[SPLIT_TRAIN], "held_out": counts[SPLIT_HELD_OUT]})

	var manifest := {
		"format": FORMAT, "version": VERSION,
		"kind": _schema.kind, "schema_version": _schema.version, "schema_id": _schema.schema_id(),
		"frame_size": frame, "observation_size": _schema.observation_size(), "action_size": _schema.action_size(),
		"observation": _field_dicts(_schema.observation), "action": _field_dicts(_schema.action),
		"split": {"seed": split_seed, "held_out_fraction": held_out_fraction},
		"maps": maps, "shards": shards, "held_out": held_out, "totals": totals, "rejected": rejected,
	}
	var saved := DotPaths.write_json(dir.path_join(MANIFEST), manifest)
	if not saved.ok:
		return saved
	DotLog.info(CHANNEL, "exported %d train and %d held-out episodes of '%s' to %s" % [totals["train_episodes"], totals["held_out_episodes"], _schema.kind, dir])
	return DotResult.success(manifest)


## The manifest of [param dir], checked in full; the value holds only what was checked, every count an int. Fails CODE_IO, CODE_PARSE, CODE_VERSION or CODE_INVALID.
static func load_manifest(dir: String) -> DotResult:
	var path := dir.path_join(MANIFEST)
	if not FileAccess.file_exists(path):
		return DotResult.fail(DotError.CODE_IO, "No %s in '%s'." % [MANIFEST, dir])
	var size := DotPaths.file_size(path)
	if size > MAX_MANIFEST_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "The manifest is %d bytes; the limit is %d." % [size, MAX_MANIFEST_BYTES])
	var parsed := DotPaths.read_json(path)
	if not parsed.ok:
		return parsed
	if not parsed.value is Dictionary:
		return _bad("it is not an object.")
	var m: Dictionary = parsed.value
	if not m.get("format") is String or String(m["format"]) != FORMAT:
		return _bad("it is not a %s export." % FORMAT)
	if _count(m.get("version"), 1, 1 << 30) != VERSION:
		return DotResult.fail(DotError.CODE_VERSION, "Export version %s; this reads version %d." % [str(m.get("version")).left(MAX_NAME), VERSION])
	var out := {"format": FORMAT, "version": VERSION}
	for key in ["kind", "schema_id"]:
		var s := _name(m.get(key))
		if s == "":
			return _bad("'%s' is missing or not a short plain string." % key)
		out[key] = s
	var schema_version := _count(m.get("schema_version"), 1, 1 << 30)
	var frame := _count(m.get("frame_size"), 1, MAX_FRAME_SIZE)
	if schema_version < 0 or frame < 0:
		return _bad("schema_version or frame_size is out of range.")
	out["schema_version"] = schema_version
	out["frame_size"] = frame
	var fields := {}
	var sizes := {}
	for group in ["observation", "action"]:
		var rows: Variant = m.get(group)
		if not rows is Array or (rows as Array).is_empty() or (rows as Array).size() > MAX_FIELDS:
			return _bad("'%s' must list 1 to %d fields." % [group, MAX_FIELDS])
		var clean: Array = []
		var total := 0
		for row: Variant in rows:
			if not row is Dictionary:
				return _bad("A field of '%s' is not an object." % group)
			var r: Dictionary = row
			var field_name := _name(r.get("name"))
			var field_size := _count(r.get("size"), 1, MAX_FIELD_SIZE)
			var scale: Variant = r.get("scale")
			if field_name == "" or fields.has(field_name) or field_size < 0 or not (scale is float or scale is int) or not is_finite(float(scale)) or float(scale) <= 0.0:
				return _bad("A field of '%s' has a bad or repeated name, size or scale." % group)
			fields[field_name] = true
			total += field_size
			clean.append({"name": field_name, "size": field_size, "scale": float(scale), "discrete": r.get("discrete", false) == true})
		out[group] = clean
		sizes[group] = total
	if sizes["observation"] + sizes["action"] != frame:
		return _bad("the fields add up to %d floats, not frame_size %d." % [sizes["observation"] + sizes["action"], frame])
	out["observation_size"] = sizes["observation"]
	out["action_size"] = sizes["action"]

	var shards_in: Variant = m.get("shards")
	if not shards_in is Array or (shards_in as Array).size() > MAX_SHARDS:
		return _bad("'shards' must list at most %d shards." % MAX_SHARDS)
	var name_check := RegEx.create_from_string(SHARD_PATTERN)
	var files := {}
	var shards: Array = []
	var totals := {SPLIT_TRAIN: 0, SPLIT_HELD_OUT: 0}
	for item: Variant in shards_in:
		if not item is Dictionary:
			return _bad("a shard entry is not an object.")
		var e: Dictionary = item
		var file: String = e["file"] if e.get("file") is String else ""
		var split: String = e["split"] if e.get("split") is String else ""
		var rows_n := _count(e.get("rows"), 1, MAX_SHARD_BYTES / 4 / frame)
		var hash_hex: String = e["sha256"] if e.get("sha256") is String else ""
		if name_check.search(file) == null or files.has(file):
			return _bad("shard file '%s' is not shard_N.f32 or is listed twice." % file.left(MAX_NAME))
		if not totals.has(split) or rows_n < 0 or hash_hex.length() != 64 or not hash_hex.is_valid_hex_number(false):
			return _bad("shard '%s' has a bad split, row count or hash." % file)
		var eps_in: Variant = e.get("episodes")
		if not eps_in is Array or (eps_in as Array).is_empty() or (eps_in as Array).size() > rows_n:
			return _bad("shard '%s' lists no episodes or more than it has rows." % file)
		var eps: Array = []
		var sum := 0
		for pair: Variant in eps_in:
			if not pair is Array or (pair as Array).size() != 2:
				return _bad("shard '%s' has an episode entry that is not [id, rows]." % file)
			var ep_id := _count(pair[0], 0, 1 << 52)
			var ep_rows := _count(pair[1], 1, rows_n)
			if ep_rows < 0 or ep_id < 0:
				return _bad("shard '%s' has an episode with a bad id or row count." % file)
			sum += ep_rows
			eps.append([ep_id, ep_rows])
		if sum != rows_n:
			return _bad("shard '%s' says %d rows but its episodes add up to %d." % [file, rows_n, sum])
		var map_id := _name(e.get("map_id"))
		if map_id == "" or not e.get("map_version") is String or _name(e["map_version"], true) != e["map_version"]:
			return _bad("shard '%s' has no usable map id and version." % file)
		files[file] = true
		totals[split] += rows_n
		shards.append({"file": file, "split": split, "rows": rows_n, "sha256": hash_hex.to_lower(), "episodes": eps, "map_id": map_id, "map_version": e["map_version"]})
	out["shards"] = shards

	var held_in: Variant = m.get("held_out", [])
	if not held_in is Array or (held_in as Array).size() > MAX_HELD_OUT:
		return _bad("'held_out' is not a list of at most %d." % MAX_HELD_OUT)
	var held: Array = []
	for item: Variant in held_in:
		if not item is Dictionary:
			return _bad("a held-out entry is not an object.")
		var h: Dictionary = item
		var h_rows := _count(h.get("rows"), 1, 1 << 30)
		var h_id := _count(h.get("id"), 0, 1 << 52)
		var h_start: Variant = h.get("start", {})
		var h_rate: Variant = h.get("rate")
		if h_rows < 0 or h_id < 0 or not h_start is Dictionary or not (h_rate is float or h_rate is int) or not is_finite(float(h_rate)):
			return _bad("a held-out entry has a bad id, rows, rate or start.")
		held.append({
			"id": h_id, "map_id": _name(h.get("map_id")), "map_version": _name(h.get("map_version"), true), "key": _name(h.get("key"), true),
			"rate": float(h_rate), "outcome": _name(h.get("outcome"), true), "rows": h_rows, "start": h_start,
		})
	out["held_out"] = held
	out["totals"] = totals
	return DotResult.success(out)


## The rows of shard [param index] of a manifest [method load_manifest] returned, as one flat array of frame_size floats per row. The file's size, hash and every value are checked first.
static func read_shard(dir: String, manifest: Dictionary, index: int) -> DotResult:
	var shards: Array = manifest.get("shards", [])
	if index < 0 or index >= shards.size():
		return DotResult.fail(DotError.CODE_INVALID, "No shard %d." % index)
	var shard: Dictionary = shards[index]
	var file := String(shard["file"])
	# load_manifest matched the name already; a manifest built by hand is held to it too.
	if RegEx.create_from_string(SHARD_PATTERN).search(file) == null:
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a shard file name." % file.left(MAX_NAME))
	var path := dir.path_join(file)
	var want: int = int(shard["rows"]) * int(manifest["frame_size"]) * 4
	var have := DotPaths.file_size(path)
	if have != want or want > MAX_SHARD_BYTES:
		return DotResult.fail(DotError.CODE_INTEGRITY, "Shard '%s' is %d bytes, expected %d." % [file, have, want])
	if FileAccess.get_sha256(path) != String(shard["sha256"]):
		return DotResult.fail(DotError.CODE_INTEGRITY, "Shard '%s' does not match its hash." % file)
	var bytes := DotPaths.read_bytes(path)
	if not bytes.ok:
		return bytes
	var floats := (bytes.value as PackedByteArray).to_float32_array()
	for v in floats:
		if not is_finite(v):
			return DotResult.fail(DotError.CODE_INTEGRITY, "Shard '%s' holds a value that is not finite." % file)
	return DotResult.success(floats)


func _split(episodes: Array) -> Dictionary:
	var keyed: Array = []
	for ep: DotBotDemoEpisode in episodes:
		keyed.append([("%s|%s|%s|%d" % [split_seed, ep.map_id, ep.map_version, ep.id]).sha256_text(), ep])
	keyed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var n := keyed.size()
	var held_n := 0 if n < 2 else clampi(roundi(n * held_out_fraction), 1 if held_out_fraction > 0.0 else 0, n - 1)
	var out := {SPLIT_TRAIN: [], SPLIT_HELD_OUT: []}
	for i in n:
		(out[SPLIT_HELD_OUT if i < held_n else SPLIT_TRAIN] as Array).append(keyed[i][1])
	for list: Array in out.values():
		list.sort_custom(func(a: DotBotDemoEpisode, b: DotBotDemoEpisode) -> bool: return a.id < b.id)
	return out


func _write_shard(dir: String, number: int, part: String, group: Dictionary, run: Array, frame: int) -> DotResult:
	var rows := PackedFloat32Array()
	var eps: Array = []
	for ep: DotBotDemoEpisode in run:
		rows.append_array(ep.ticks)
		eps.append([ep.id, ep.sample_count()])
	var file := "shard_%d.f32" % number
	var saved := DotPaths.write_bytes(dir.path_join(file), rows.to_byte_array())
	if not saved.ok:
		return saved
	return DotResult.success({
		"file": file, "split": part, "map_id": group["map_id"], "map_version": group["map_version"],
		"rows": rows.size() / frame, "sha256": FileAccess.get_sha256(dir.path_join(file)), "episodes": eps,
	})


static func _field_dicts(rows: Array) -> Array:
	var out: Array = []
	for row: Array in rows:
		out.append({
			"name": row[DotBotDemoSchema.COL_NAME], "size": row[DotBotDemoSchema.COL_SIZE],
			"scale": row[DotBotDemoSchema.COL_SCALE], "discrete": row[DotBotDemoSchema.COL_DISCRETE],
		})
	return out


static func _remove_shards(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.begins_with("shard_") and f.ends_with(".f32"):
			d.remove(f)


## A whole number within [lo, hi] from a JSON number, or -1.
static func _count(v: Variant, lo: int, hi: int) -> int:
	if not (v is float or v is int) or not is_finite(float(v)) or float(v) != floorf(float(v)):
		return -1
	if float(v) < lo or float(v) > hi:
		return -1
	return int(v)


## A short string with no control characters or path separators, or "".
static func _name(v: Variant, allow_empty: bool = false) -> String:
	if not v is String:
		return ""
	var s: String = v
	if s.length() > MAX_NAME or (s == "" and not allow_empty):
		return ""
	for c in s:
		if c.unicode_at(0) < 32 or c == "/" or c == "\\":
			return ""
	return s


static func _bad(why: String) -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, "Export manifest: " + why)
