class_name DotBotRideHarvest
extends RefCounted

## Turns recorded ride episodes into verified ones: replays each on the host's simulator from its start and keeps it only if it lands where the player did.
##
## [b]The host is duck typed[/b] (nothing here names a game or the motor): [code]replay_start(episode) -> state[/code]
## or null, [code]replay_command(sim, action: PackedFloat32Array, state) -> command[/code], and
## [code]landing(state, event: int, episode) -> int[/code] ([constant LANDED], [constant FAILED] or [constant GOING]).
## [code]perturb(state, rng, metres, speed) -> state[/code] is optional; without it a kept ride scores 1.
## The simulator has [code]step(state, command) -> int[/code] (non-zero ends the ride) and [code]delta[/code].
##
## A ride is kept when the unperturbed replay lands and its score, the share of
## [member DotBotRideConfig.starts] perturbed starts that land, reaches [member DotBotRideConfig.min_score].

const CHANNEL := "bot.ride.harvest"

const GOING := 0
const LANDED := 1
const FAILED := -1

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


## One replay of [param ep] from [param state]: [constant LANDED], [constant FAILED] or [constant GOING] if it ran out of ticks.
func replay(ep: Variant, state: Variant) -> int:
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
	return {"verified": verified, "rejected": rejected, "replaced": replaced, "turned_away": turned_away, "replays": replays}


func describe_lines() -> PackedStringArray:
	return PackedStringArray(["ride harvest: %d verified, %d rejected, %d replaced at the cap, %d turned away, %d replays" % [verified, rejected, replaced, turned_away, replays]])
