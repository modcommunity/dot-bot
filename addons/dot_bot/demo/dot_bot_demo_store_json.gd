class_name DotBotDemoStoreJson
extends DotBotDemoStore

## Episodes in JSON files, one per map version and kind: [code]<path>/<map_id>@<version>/<kind>.json[/code].
##
## Each file is held whole in memory and rewritten whole, atomically, only when an append or a
## mark changed it. A file that will not parse is moved aside to [code].corrupt[/code] and
## started again, so a torn disk never stops the recorder. The offline tools write the same files.

const CHANNEL := "bot.demo.store"
const FORMAT := 1

## The directory the files live under.
var path: String = "user://dot_bot/demos"

## Files moved aside because they would not parse.
var recovered: int = 0

## Files written.
var writes: int = 0

var _files: Dictionary = {}
var _last_id: int = 0


func _init(p_path: String = "user://dot_bot/demos") -> void:
	path = p_path


func open() -> DotResult:
	return DotPaths.ensure_dir(path)


func append(batch: Array) -> DotResult:
	var touched := {}
	for item: Variant in batch:
		var e := item as DotBotDemoEpisode
		if e == null:
			return DotResult.fail(DotError.CODE_INVALID, "A store holds DotBotDemoEpisode, not %s." % type_string(typeof(item)))
		var file_path := file_for(e.map_id, e.map_version, e.kind)
		var loaded := _file(file_path)
		if not loaded.ok:
			return loaded
		e.id = _new_id()
		(loaded.value as Array).append(e)
		touched[file_path] = true
	for file_path: String in touched:
		var saved := _save(file_path)
		if not saved.ok:
			return saved
	return DotResult.success(batch.size())


func counts(map_id: String, map_version: String, kind: String) -> DotResult:
	var loaded := _file(file_for(map_id, map_version, kind))
	if not loaded.ok:
		return loaded
	var out := {}
	for e: DotBotDemoEpisode in loaded.value:
		if e.map_id == map_id and e.map_version == map_version:
			out[e.key] = int(out.get(e.key, 0)) + (1 if e.verified else 0)
	return DotResult.success(out)


func load(map_id: String, map_version: String, kind: String, key: String, limit: int) -> DotResult:
	var loaded := _file(file_for(map_id, map_version, kind))
	if not loaded.ok:
		return loaded
	var found: Array = []
	for e: DotBotDemoEpisode in loaded.value:
		if e.map_id == map_id and e.map_version == map_version and e.key == key:
			found.append(e)
	found.sort_custom(DotBotDemoStoreJson._better)
	if limit > 0 and found.size() > limit:
		found.resize(limit)
	return DotResult.success(found)


func mark(ids: Array, verified: bool, score: float) -> DotResult:
	var changed := 0
	for file_path in _all_paths():
		var loaded := _file(file_path)
		if not loaded.ok:
			continue
		var hit := false
		for e: DotBotDemoEpisode in loaded.value:
			if ids.has(e.id):
				e.verified = verified
				e.score = score
				changed += 1
				hit = true
		if hit:
			var saved := _save(file_path)
			if not saved.ok:
				return saved
	return DotResult.success(changed)


func remove(ids: Array) -> DotResult:
	var gone := 0
	for file_path in _all_paths():
		var loaded := _file(file_path)
		if not loaded.ok:
			continue
		var list: Array = loaded.value
		var before := list.size()
		for i in range(list.size() - 1, -1, -1):
			if ids.has((list[i] as DotBotDemoEpisode).id):
				list.remove_at(i)
		if list.size() != before:
			gone += before - list.size()
			var saved := _save(file_path)
			if not saved.ok:
				return saved
	return DotResult.success(gone)


func prune(map_id: String, keep_version: String) -> DotResult:
	var keep := _dir_for(map_id, keep_version)
	var prefix := DotPaths.slugify(map_id) + "@"
	var dropped := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return DotResult.success(0)
	var stale: Array[String] = []
	for name in dir.get_directories():
		var full := path.path_join(name)
		if name.begins_with(prefix) and full != keep:
			stale.append(full)
	for full in stale:
		for name in DirAccess.get_files_at(full):
			if name.ends_with(".json"):
				var file_path := full.path_join(name)
				dropped += (_files[file_path] as Array).size() if _files.has(file_path) else _count_in(file_path)
		for file_path: String in _files.keys():
			if file_path.begins_with(full + "/"):
				_files.erase(file_path)
		var removed := DotPaths.remove_tree(full)
		if not removed.ok:
			return removed
	return DotResult.success(dropped)


func describe_lines() -> PackedStringArray:
	var held := 0
	for list: Array in _files.values():
		held += list.size()
	return PackedStringArray(["store json: %s, %d files and %d episodes held, %d written, %d recovered" % [path, _files.size(), held, writes, recovered]])


## The file one map version's kind lives in.
func file_for(map_id: String, map_version: String, kind: String) -> String:
	return _dir_for(map_id, map_version).path_join(DotPaths.slugify(kind) + ".json")


func _dir_for(map_id: String, map_version: String) -> String:
	return path.path_join("%s@%s" % [DotPaths.slugify(map_id), DotPaths.slugify(map_version)])


## Unique across restarts and servers sharing a directory, without reading every file.
func _new_id() -> int:
	_last_id = maxi(_last_id + 1, int(Time.get_unix_time_from_system() * 1000.0))
	return _last_id


func _all_paths() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(path)
	if dir != null:
		for sub in dir.get_directories():
			for name in DirAccess.get_files_at(path.path_join(sub)):
				if name.ends_with(".json"):
					out.append(path.path_join(sub).path_join(name))
	for held: String in _files.keys():
		if not out.has(held):
			out.append(held)
	return out


## The episodes of one file, read once; the value is the live Array.
func _file(file_path: String) -> DotResult:
	if _files.has(file_path):
		return DotResult.success(_files[file_path])
	var list: Array = []
	if FileAccess.file_exists(file_path):
		var read := DotPaths.read_json(file_path)
		var data: Variant = read.value if read.ok else null
		if data is Dictionary and int((data as Dictionary).get("format", 0)) > FORMAT:
			return DotResult.fail(DotError.CODE_VERSION, "%s was written by a newer build." % file_path)
		if data is Dictionary and (data as Dictionary).get("episodes") is Array:
			for d: Variant in (data as Dictionary)["episodes"]:
				if d is Dictionary:
					list.append(DotBotDemoEpisode.from_dictionary(d))
		else:
			_set_aside(file_path)
	_files[file_path] = list
	return DotResult.success(list)


func _set_aside(file_path: String) -> void:
	recovered += 1
	DirAccess.rename_absolute(file_path, file_path + ".corrupt")
	DotLog.warn(CHANNEL, "A demonstration file would not parse; moved aside and started again.", {"file": file_path})


func _save(file_path: String) -> DotResult:
	var rows: Array = []
	for e: DotBotDemoEpisode in _files[file_path]:
		rows.append(e.to_dictionary())
	var res := DotPaths.write_json(file_path, {"format": FORMAT, "episodes": rows}, false)
	if res.ok:
		writes += 1
	return res


func _count_in(file_path: String) -> int:
	var read := DotPaths.read_json(file_path)
	if read.ok and read.value is Dictionary and (read.value as Dictionary).get("episodes") is Array:
		return ((read.value as Dictionary)["episodes"] as Array).size()
	return 0


static func _better(a: DotBotDemoEpisode, b: DotBotDemoEpisode) -> bool:
	return a.score > b.score
