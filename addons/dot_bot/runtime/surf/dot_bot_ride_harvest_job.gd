class_name DotBotRideHarvestJob
extends DotJob

## Replays episodes for [DotBotRideHarvest] a few at a time inside [member DotBotRideConfig.budget_msec], so a server never stalls a frame on it.
##
## The result's value is [member verdicts]: per episode [code]{episode, ok, score, landed, starts}[/code].

var verdicts: Array = []

var _harvest: DotBotRideHarvest
var _episodes: Array
var _index: int = 0
## -1 is the unperturbed replay, 0 and up the perturbed starts.
var _start: int = -1
var _landed: int = 0
var _base_ok: bool = false
var _rng: DotRandomStream = null


func _init(harvest: DotBotRideHarvest, episodes: Array) -> void:
	_harvest = harvest
	_episodes = episodes


func _step() -> bool:
	var began := Time.get_ticks_usec()
	var limit := _harvest.config.budget_msec * 1000.0
	while _index < _episodes.size():
		_one(_episodes[_index])
		if Time.get_ticks_usec() - began >= limit:
			break
	if _index >= _episodes.size():
		_finish(DotResult.success(verdicts))
		return false
	return true


func _progress() -> float:
	return 1.0 if _episodes.is_empty() else float(_index) / _episodes.size()


## One replay of [param ep]: the unperturbed one first, then each perturbed start.
func _one(ep: Variant) -> void:
	var cfg := _harvest.config
	var host: Variant = _harvest.host
	var state: Variant = host.replay_start(ep)
	if state == null:
		_close(ep, false)
		return
	if _start < 0:
		_base_ok = _harvest.replay(ep, state) == DotBotRideHarvest.LANDED
		_start = 0
		_landed = 0
		_rng = DotRandomStream.new(cfg.seed + ep.id)
		if not _base_ok or cfg.starts == 0 or not host.has_method(&"perturb"):
			_close(ep, _base_ok)
		return
	var moved: Variant = host.perturb(state, _rng, cfg.perturb_metres, cfg.perturb_speed)
	if moved != null and _harvest.replay(ep, moved) == DotBotRideHarvest.LANDED:
		_landed += 1
	_start += 1
	if _start >= cfg.starts:
		_close(ep, true)


func _close(ep: Variant, base_ok: bool) -> void:
	var cfg := _harvest.config
	var measured := cfg.starts > 0 and _start > 0
	var score := float(_landed) / cfg.starts if measured else (1.0 if base_ok else 0.0)
	var ok := base_ok and score >= cfg.min_score
	verdicts.append({"episode": ep, "ok": ok, "score": score if ok else 0.0, "landed": base_ok, "starts": _start})
	_index += 1
	_start = -1
