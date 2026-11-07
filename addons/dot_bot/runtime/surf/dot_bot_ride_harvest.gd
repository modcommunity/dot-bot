class_name DotBotRideHarvest
extends RefCounted

## Turns recorded ride episodes into verified ones: replays each on the host's simulator from its start and keeps it only if it lands where the player did.
##
## The host is duck typed: [code]replay_start[/code], [code]replay_command[/code], [code]landing[/code] and optionally [code]perturb[/code]; the simulator has [code]step[/code] and [code]delta[/code]. A ride is kept when the replay lands and enough perturbed starts ([member DotBotRideConfig.min_score]) do too.
##
## [b]Piloted replay[/b] (host method [code]pilot_setup(pilot, episode)[/code], [member DotBotRideConfig.piloted]): the commands are quantised to pilot actions ([DotBotRideQuantiser]) and a [DotBotSurfPilot] with the ride as its only cache, tracking and vetoing, rides the simulator. That is what a bot does with the ride, so a line the pilot cannot follow is rejected however well the player flew it. The simulator must return [DotBotSurfCourse] events for the veto. Without [code]pilot_setup[/code] the recorded commands are replayed open loop.

const CHANNEL := "bot.ride.harvest"

const GOING := 0
const LANDED := 1
const FAILED := -1
## Only a [class Run] in progress.
const RUNNING := 2

## Marks a rejected episode when [member DotBotRideConfig.keep_rejected] keeps it.
const REJECTED_SCORE := -1.0

var config: DotBotRideConfig
var schema: Variant
var sim: Variant = null
var host: Variant = null

var verified: int = 0
var rejected: int = 0
var replaced: int = 0
var turned_away: int = 0
var replays: int = 0
var piloted_replays: int = 0

var _pilot_ep: Variant = null
var _pilot: DotBotSurfPilot = null


func _init(p_config: DotBotRideConfig, p_schema: Variant, p_sim: Variant, p_host: Variant) -> void:
	config = p_config
	schema = p_schema
	sim = p_sim
	host = p_host


## True when the host has what a replay needs; otherwise the reason.
func ready() -> DotResult:
	for m in [&"replay_start", &"replay_command", &"landing"]:
		if host == null or not host.has_method(m):
			return DotResult.fail(DotError.CODE_STATE, "The ride host has no %s." % m)
	if sim == null or not sim.has_method(&"step"):
		return DotResult.fail(DotError.CODE_STATE, "The ride simulator has no step.")
	return DotResult.success(true)


## Whether replays go through the pilot: the config says so and the host can set one up.
func is_piloted() -> bool:
	return config.piloted and host != null and host.has_method(&"pilot_setup")


## One replay of [param ep] from [param state]: [constant LANDED], [constant FAILED] or [constant GOING] if it ran out of ticks.
func replay(ep: Variant, state: Variant) -> int:
	return begin_replay(ep, state).advance(0, 0)


## A replay of [param ep] that [method Run.advance] steps a slice at a time. An open loop replay is not sliced: its run is already finished.
func begin_replay(ep: Variant, state: Variant) -> Run:
	if not is_piloted():
		var open := Run.new()
		open.verdict = replay_open(ep, state)
		return open
	return _begin_piloted(ep, state)


## [method replay] with the pilot riding the quantised ride, tracking and vetoing, one command a simulator tick.
func replay_piloted(ep: Variant, state: Variant) -> int:
	return _begin_piloted(ep, state).advance(0, 0)


func _begin_piloted(ep: Variant, state: Variant) -> Run:
	replays += 1
	piloted_replays += 1
	var delta: float = float(sim.get("delta")) if sim.get("delta") != null else 0.0
	var hold := 1 if delta <= 0.0 or ep.rate <= 0.0 else maxi(1, roundi(1.0 / (delta * ep.rate)))
	if _pilot_ep != ep or _pilot == null:
		_pilot_ep = ep
		_pilot = DotBotRideQuantiser.pilot_for(ep, schema, sim, Callable(host, &"pilot_setup"), config.pilot_tracking, config.pilot_horizon, hold)
	var run := Run.new()
	run.harvest = self
	run.ep = ep
	if _pilot.size() == 0:
		run.verdict = FAILED
		return run
	_pilot.reset()
	run.pilot = _pilot
	run.state = state.duplicate_state()
	run.left = ep.sample_count() * hold + config.settle_ticks
	return run


## One piloted replay in progress. [method advance] runs it a few simulator steps at a time; the verdict is the same however it is sliced.
class Run:
	extends RefCounted

	## The verdict once finished, [constant RUNNING] before.
	var verdict: int = RUNNING
	var steps: int = 0
	var harvest: DotBotRideHarvest
	var ep: Variant
	var pilot: DotBotSurfPilot
	var state: Variant
	var left: int = 0

	## Steps until [param deadline_usec] (0 for no time limit) or [param max_steps] (0 for no step limit): [constant RUNNING] if either stopped it, else the verdict. At least one step runs.
	func advance(deadline_usec: int, max_steps: int) -> int:
		var done := 0
		while verdict == RUNNING:
			if left <= 0:
				verdict = GOING
				break
			left -= 1
			steps += 1
			done += 1
			var event: int = harvest.sim.step(state, pilot.command(state))
			var landed: int = harvest.host.landing(state, event, ep)
			if landed != GOING:
				verdict = landed
			elif event != 0:
				verdict = FAILED
			if verdict == RUNNING and ((max_steps > 0 and done >= max_steps) or (deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec)):
				return RUNNING
		return verdict


## [method replay] on the recorded commands themselves.
func replay_open(ep: Variant, state: Variant) -> int:
	replays += 1
	var fs: int = ep.frame_size
	var obs: int = schema.observation_size()
	var delta: float = float(sim.get("delta")) if sim.get("delta") != null else 0.0
	var hold := 1 if delta <= 0.0 or ep.rate <= 0.0 else maxi(1, roundi(1.0 / (delta * ep.rate)))
	var action := PackedFloat32Array()
	var count: int = ep.sample_count()
	for i in count + ceili(float(config.settle_ticks) / hold):
		if i < count:
			action = ep.ticks.slice(i * fs + obs, (i + 1) * fs)
		for _h in hold:
			var event: int = sim.step(state, host.replay_command(sim, action, state))
			var verdict: int = host.landing(state, event, ep)
			if verdict != GOING:
				return verdict
			if event != 0:
				return FAILED
	return GOING


## A job that replays [param episodes] a slice at a time; its result is the Array of verdicts.
func make_job(episodes: Array) -> DotBotRideHarvestJob:
	return DotBotRideHarvestJob.new(self, episodes)


## Replays [param episodes] to the end now, for tools and tests; the verdicts, see [DotBotRideHarvestJob].
func verify(episodes: Array) -> Array:
	var job := make_job(episodes)
	var _r := job.run_to_completion()
	return job.verdicts


## Episodes of an edge nobody has replayed yet.
static func unchecked(episodes: Array) -> Array:
	return episodes.filter(func(e: Variant) -> bool: return not e.verified and e.score == 0.0)


## Replays an edge's unchecked episodes in [param store] and stores the verdicts; the value is the edge's verified count.
func harvest(store: Variant, map_id: String, map_version: String, kind: String, key: String) -> DotResult:
	var loaded: DotResult = await store.load(map_id, map_version, kind, key, 0)
	if not loaded.ok:
		return loaded
	var verdicts := verify(unchecked(loaded.value))
	return await commit(store, loaded.value, verdicts)


## Writes [param verdicts] to [param store] against the edge's [param existing] episodes, replacing the worst-scored verified ride past the cap.
func commit(store: Variant, existing: Array, verdicts: Array) -> DotResult:
	var kept: Array = existing.filter(func(e: Variant) -> bool: return e.verified)
	var drop: Array = []
	for v: Dictionary in verdicts:
		var ep: Variant = v["episode"]
		if not v["ok"]:
			rejected += 1
			if config.keep_rejected:
				var marked: DotResult = await store.mark([ep.id], false, REJECTED_SCORE)
				if not marked.ok:
					return marked
			else:
				drop.append(ep.id)
			continue
		if kept.size() >= config.cap:
			var worst: Variant = kept[0]
			for k in kept:
				if k.score < worst.score:
					worst = k
			if float(v["score"]) <= worst.score:
				turned_away += 1
				drop.append(ep.id)
				continue
			kept.erase(worst)
			drop.append(worst.id)
			replaced += 1
		ep.verified = true
		ep.score = float(v["score"])
		kept.append(ep)
		verified += 1
		var res: DotResult = await store.mark([ep.id], true, ep.score)
		if not res.ok:
			return res
	if not drop.is_empty():
		var removed: DotResult = await store.remove(drop)
		if not removed.ok:
			return removed
	DotLog.debug(CHANNEL, "Harvest done.", {"kept": kept.size(), "dropped": drop.size()})
	return DotResult.success(kept.size())


func describe() -> Dictionary:
	return {"verified": verified, "rejected": rejected, "replaced": replaced, "turned_away": turned_away, "replays": replays, "piloted_replays": piloted_replays}


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["ride harvest: %d verified, %d rejected, %d replaced at the cap, %d turned away, %d replays" % [verified, rejected, replaced, turned_away, replays]])
