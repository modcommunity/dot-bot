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
var _run: DotBotRideHarvest.Run = null
var _stopped: bool = false


func _init(harvest: DotBotRideHarvest, episodes: Array) -> void:
	_harvest = harvest
	_episodes = episodes


func _step() -> bool:
	var cfg := _harvest.config
	var deadline := Time.get_ticks_usec() + int(cfg.budget_msec * 1000.0)
	var used := 0
	while _index < _episodes.size():
		used += _one(_episodes[_index], deadline, cfg.slice_steps - used if cfg.slice_steps > 0 else 0)
		if _stopped or Time.get_ticks_usec() >= deadline or (cfg.slice_steps > 0 and used >= cfg.slice_steps):
			break
	if _index >= _episodes.size():
		_finish(DotResult.success(verdicts))
		return false
	return true


func _progress() -> float:
	return 1.0 if _episodes.is_empty() else float(_index) / _episodes.size()


## Advances the replay of [param ep] (the unperturbed one first, then each perturbed start) until [param deadline] or [param allowance] steps (0 for no limit), and carries on from there next tick. The value is the steps it ran; [member _stopped] says whether a limit stopped it.
func _one(ep: Variant, deadline: int, allowance: int) -> int:
	var cfg := _harvest.config
	var host: Variant = _harvest.host
	_stopped = false
	if _run == null:
		var state: Variant = host.replay_start(ep)
		if state == null:
			_close(ep, false)
			return 0
		if _start < 0:
			_run = _harvest.begin_replay(ep, state)
		else:
			var moved: Variant = host.perturb(state, _rng, cfg.perturb_metres, cfg.perturb_speed)
			if moved == null:
				_after(ep, DotBotRideHarvest.FAILED)
				return 0
			_run = _harvest.begin_replay(ep, moved)
	var before := _run.steps
	var verdict := _run.advance(deadline, allowance)
	var ran := _run.steps - before
	if verdict == DotBotRideHarvest.RUNNING:
		_stopped = true
		return ran
	_run = null
	_after(ep, verdict)
	return ran


func _after(ep: Variant, verdict: int) -> void:
	var cfg := _harvest.config
	var host: Variant = _harvest.host
	if _start < 0:
		_base_ok = verdict == DotBotRideHarvest.LANDED
		_start = 0
		_landed = 0
		_rng = DotRandomStream.new(cfg.seed + ep.id)
		if not _base_ok or cfg.starts == 0 or not host.has_method(&"perturb"):
			_close(ep, _base_ok)
		return
	if verdict == DotBotRideHarvest.LANDED:
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
