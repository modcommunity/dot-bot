class_name DotBotDemoHeatmap
extends RefCounted

## Where people stand on one map version, folded from recorded `place` episodes into a 2 m grid.
##
## The host says which floats of a frame are the position and the fight flag. Nothing that identifies a person is kept: a cell holds a decayed weight and counts.

const KIND := "place"

## Grid cell edge in metres.
var cell_size: float = 2.0

## Samples a second kept from an episode, whatever rate it was recorded at.
var sample_hz: float = 1.0

## Days after which a sample counts half; a changed meta fades out.
var half_life_days: float = 14.0

## A cell is only used with this many samples from at least [member min_episodes] episodes, so one player's habit never shows.
var min_count: int = 20
var min_episodes: int = 3

## Floats into a frame (observation first) of the ground-plane position and the in-a-fight flag (above 0.5 is a fight); -1 for no flag.
var x_index: int = 0
var z_index: int = 2
var fight_index: int = -1

var map_id: String = ""
var map_version: String = ""

# label -> {Vector2i: [weight, samples, fight weight, episodes]}
var _cells: Dictionary = {}
var _max_weight: Dictionary = {}
var _episodes: int = 0
var _samples: int = 0


## Folds one episode; a different kind, map or version is refused (false). [param today] is `YYYY-MM-DD` UTC, empty for now.
func fold(ep: DotBotDemoEpisode, today: String = "") -> bool:
	if ep.kind != KIND or ep.sample_count() == 0 or ep.frame_size <= maxi(x_index, maxi(z_index, fight_index)):
		return false
	if _episodes > 0 and (ep.map_id != map_id or ep.map_version != map_version):
		return false
	map_id = ep.map_id
	map_version = ep.map_version
	var weight := _decay(ep.day, today)
	var stride := maxi(1, roundi(ep.rate / sample_hz)) if ep.rate > 0.0 else 1
	var grid: Dictionary = _cells.get(ep.key, {})
	var seen := {}
	for i in range(0, ep.sample_count(), stride):
		var base := i * ep.frame_size
		var cell := Vector2i(floori(ep.ticks[base + x_index] / cell_size), floori(ep.ticks[base + z_index] / cell_size))
		var row: Array = grid.get(cell, [0.0, 0, 0.0, 0])
		row[0] += weight
		row[1] += 1
		if fight_index >= 0 and ep.ticks[base + fight_index] > 0.5:
			row[2] += weight
		if not seen.has(cell):
			seen[cell] = true
			row[3] += 1
		grid[cell] = row
		_samples += 1
	_cells[ep.key] = grid
	_max_weight.clear()
	_episodes += 1
	return true


## Folds the `place` episodes of a store for the labels named (a label is an episode key such as a team); the value is how many were folded.
func fold_store(store: DotBotDemoStore, p_map_id: String, p_version: String, labels: Array, limit: int = 500, today: String = "") -> DotResult:
	var folded := 0
	for label: String in labels:
		var res: DotResult = await store.load(p_map_id, p_version, KIND, label, limit)
		if not res.ok:
			return res
		for ep: DotBotDemoEpisode in res.value:
			if fold(ep, today):
				folded += 1
	return DotResult.success(folded)


## The decayed weight of the cell holding [param pos] for [param label] ("" adds every label); 0 when the cell has too few samples or episodes.
func weight_at(pos: Vector3, label: String = "") -> float:
	var row := _row(_cell_of(pos), label)
	return row[0] if not row.is_empty() else 0.0


## The share of that cell's weight spent in a fight; 0 when the cell is unused.
func fight_share_at(pos: Vector3, label: String = "") -> float:
	var row := _row(_cell_of(pos), label)
	return row[2] / row[0] if not row.is_empty() and row[0] > 0.0 else 0.0


## [param points] with each repeated one to [param max_copies] times by how often people stand in its cell, so a uniform pick among them is weighted. A point in an unused cell appears once.
func weighted(points: PackedVector3Array, label: String = "", max_copies: int = 4) -> PackedVector3Array:
	var top := _top(label)
	var out := PackedVector3Array()
	for point in points:
		var copies := 1
		if top > 0.0 and max_copies > 1:
			copies += roundi((max_copies - 1) * weight_at(point, label) / top)
		for _i in copies:
			out.append(point)
	return out


## A `DotBotWorld.waypoints_fn` returning [param points] weighted by this map.
func waypoints_fn(points: PackedVector3Array, label: String = "", max_copies: int = 4) -> Callable:
	return weighted.bind(points, label, max_copies)


func episode_count() -> int:
	return _episodes


func describe_lines() -> PackedStringArray:
	var cells := 0
	for grid: Dictionary in _cells.values():
		cells += grid.size()
	return PackedStringArray(["heatmap %s@%s: %d episodes, %d samples, %d cells, %d labels" % [map_id, map_version, _episodes, _samples, cells, _cells.size()]])


func _cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / cell_size), floori(pos.z / cell_size))


func _row(cell: Vector2i, label: String) -> Array:
	var sum := []
	for key: String in _cells:
		if label != "" and key != label:
			continue
		var row: Array = (_cells[key] as Dictionary).get(cell, [])
		if row.is_empty():
			continue
		if sum.is_empty():
			sum = [0.0, 0, 0.0, 0]
		for i in 4:
			sum[i] += row[i]
	if sum.is_empty() or sum[1] < min_count or sum[3] < min_episodes:
		return []
	return sum


func _top(label: String) -> float:
	if _max_weight.has(label):
		return _max_weight[label]
	var best := 0.0
	var seen := {}
	for key: String in _cells:
		for cell: Vector2i in _cells[key]:
			if not seen.has(cell):
				seen[cell] = true
				var row := _row(cell, label)
				if not row.is_empty():
					best = maxf(best, row[0])
	_max_weight[label] = best
	return best


## 1 for today, halving every half-life; an unreadable day counts as today.
func _decay(day: String, today: String) -> float:
	var then := Time.get_unix_time_from_datetime_string(day + "T00:00:00") if day != "" else 0.0
	var now := Time.get_unix_time_from_datetime_string(today + "T00:00:00") if today != "" else Time.get_unix_time_from_system()
	if then <= 0.0 or half_life_days <= 0.0:
		return 1.0
	return pow(0.5, maxf(0.0, now - then) / 86400.0 / half_life_days)
