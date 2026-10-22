class_name DotBotDemoStoreMemory
extends DotBotDemoStore

## Episodes held in memory, for suites and for hosts that only want a tally.

## Every episode held, oldest first.
var episodes: Array = []

var _next_id: int = 1


func append(batch: Array) -> DotResult:
	for item: Variant in batch:
		var e := item as DotBotDemoEpisode
		if e == null:
			return DotResult.fail(DotError.CODE_INVALID, "A store holds DotBotDemoEpisode, not %s." % type_string(typeof(item)))
		e.id = _next_id
		_next_id += 1
		episodes.append(e)
	return DotResult.success(batch.size())


func counts(map_id: String, map_version: String, kind: String) -> DotResult:
	var out := {}
	for e: DotBotDemoEpisode in episodes:
		if e.map_id == map_id and e.map_version == map_version and e.kind == kind:
			out[e.key] = int(out.get(e.key, 0)) + (1 if e.verified else 0)
	return DotResult.success(out)


func load(map_id: String, map_version: String, kind: String, key: String, limit: int) -> DotResult:
	var found: Array = []
	for e: DotBotDemoEpisode in episodes:
		if e.map_id == map_id and e.map_version == map_version and e.kind == kind and e.key == key:
			found.append(e)
	found.sort_custom(DotBotDemoStoreMemory._better)
	if limit > 0 and found.size() > limit:
		found.resize(limit)
	return DotResult.success(found)


func mark(ids: Array, verified: bool, score: float) -> DotResult:
	var changed := 0
	for e: DotBotDemoEpisode in episodes:
		if ids.has(e.id):
			e.verified = verified
			e.score = score
			changed += 1
	return DotResult.success(changed)


func prune(map_id: String, keep_version: String) -> DotResult:
	var kept: Array = []
	for e: DotBotDemoEpisode in episodes:
		if e.map_id != map_id or e.map_version == keep_version:
			kept.append(e)
	var dropped := episodes.size() - kept.size()
	episodes = kept
	return DotResult.success(dropped)


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["store memory: %d episodes" % episodes.size()])


static func _better(a: DotBotDemoEpisode, b: DotBotDemoEpisode) -> bool:
	return a.score > b.score
