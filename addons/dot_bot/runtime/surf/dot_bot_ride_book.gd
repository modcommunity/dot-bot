class_name DotBotRideBook
extends RefCounted

## The rides known per edge on one map version: verified recordings and offline-searched seeds, ranked by measured success.
##
## An edge's rides are entries [code]{id, source, score, data}[/code]. A recording's [code]data[/code]
## is [code]{actions, action_size, hold}[/code] (its commands, held [code]hold[/code] ticks each); a seed's is whatever the
## host keeps, such as a pilot cache. Below [member DotBotRideConfig.target] verified recordings
## an edge ranks by score and a recording wins a tie; at the target every recording ranks above every seed.
## A new map version drops everything: rides are only good on the geometry they were found on.

const CHANNEL := "bot.ride.book"
const RECORDED := "recorded"
const SEEDED := "seeded"

var config: DotBotRideConfig
var map_id: String = ""
var map_version: String = ""
var invalidated: int = 0

var _edges: Dictionary = {}


func _init(p_config: DotBotRideConfig = null) -> void:
	config = p_config if p_config != null else DotBotRideConfig.new()


## Keys the book to a map version; a different one empties it. True when it did.
func set_map(p_map_id: String, p_version: String) -> bool:
	var changed := p_map_id != map_id or p_version != map_version
	if changed and not _edges.is_empty():
		invalidated += 1
		DotLog.info(CHANNEL, "Map changed; dropped every ride.", {"from": "%s@%s" % [map_id, map_version], "to": "%s@%s" % [p_map_id, p_version]})
		_edges = {}
	map_id = p_map_id
	map_version = p_version
	return changed


func add_seeded(key: String, score: float, data: Variant = null, id: int = 0) -> void:
	_add(key, {"id": id, "source": SEEDED, "score": score, "data": data})


## Replaces an edge's recordings with the verified ones in [param store]; the value is how many.
func load_edge(store: Variant, kind: String, key: String, schema: Variant, tick_rate: float) -> DotResult:
	var loaded: DotResult = await store.load(map_id, map_version, kind, key, config.cap)
	if not loaded.ok:
		return loaded
	var kept: Array = (_edges.get(key, []) as Array).filter(func(r: Dictionary) -> bool: return r["source"] != RECORDED)
	_edges[key] = kept
	var n := 0
	for ep in loaded.value:
		if not ep.verified or ep.map_id != map_id or ep.map_version != map_version:
			continue
		var obs: int = schema.observation_size()
		var actions := PackedFloat32Array()
		for i in ep.sample_count():
			actions.append_array(ep.ticks.slice(i * ep.frame_size + obs, (i + 1) * ep.frame_size))
		var hold := 1 if ep.rate <= 0.0 else maxi(1, roundi(tick_rate / ep.rate))
		kept.append({"id": ep.id, "source": RECORDED, "score": ep.score,
			"data": {"actions": actions, "action_size": schema.action_size(), "hold": hold}})
		n += 1
	return DotResult.success(n)


func edge_keys() -> PackedStringArray:
	return PackedStringArray(_edges.keys())


func recorded_count(key: String) -> int:
	var n := 0
	for r: Dictionary in _edges.get(key, []):
		if r["source"] == RECORDED:
			n += 1
	return n


## An edge's rides, best first.
func ranked(key: String) -> Array:
	var out: Array = (_edges.get(key, []) as Array).duplicate()
	var recorded_first := recorded_count(key) >= config.target
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if recorded_first and a["source"] != b["source"]:
			return a["source"] == RECORDED
		if not is_equal_approx(a["score"], b["score"]):
			return a["score"] > b["score"]
		return a["source"] == RECORDED and b["source"] != RECORDED)
	return out


## An edge's success: its best ride's score, 0 with none.
func success(key: String) -> float:
	var best := 0.0
	for r: Dictionary in _edges.get(key, []):
		best = maxf(best, r["score"])
	return best


## One of an edge's top [member DotBotRideConfig.top] rides, weighted by score from [param rng]; empty with none.
func choose(key: String, rng: DotRandomStream) -> Dictionary:
	var top := ranked(key)
	if top.size() > config.top:
		top.resize(config.top)
	if top.is_empty():
		return {}
	var weights := PackedFloat32Array()
	for r: Dictionary in top:
		weights.append(maxf(0.0, r["score"]) + config.floor_weight)
	var at := rng.next_weighted(weights)
	return top[maxi(at, 0)]


func describe() -> Dictionary:
	var edges := {}
	for key: String in _edges:
		edges[key] = {"recorded": recorded_count(key), "total": (_edges[key] as Array).size(), "success": success(key)}
	return {"map": "%s@%s" % [map_id, map_version], "edges": edges, "invalidated": invalidated}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["ride book %s@%s: %d edges, invalidated %d times" % [map_id, map_version, _edges.size(), invalidated]])
	for key: String in _edges:
		out.append("  %s: %d rides (%d recorded), success %.2f" % [key, (_edges[key] as Array).size(), recorded_count(key), success(key)])
	return out


func _add(key: String, entry: Dictionary) -> void:
	if not _edges.has(key):
		_edges[key] = []
	(_edges[key] as Array).append(entry)
