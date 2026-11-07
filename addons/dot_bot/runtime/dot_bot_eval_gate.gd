class_name DotBotEvalGate
extends RefCounted

## The evaluation gate of a cloned policy: replays the held-out episodes' start states on a host's simulator, once with a [DotBotMlp] and once with the fixed baseline it would replace, under seeded perturbations, and says per map whether the policy beats the baseline by more than the spread between seeds.
##
## The host is duck typed (the gate names no game) and must be deterministic for a given start and seed:
## [codeblock]
## eval_start(start: Dictionary, seed: int) -> Variant   # a fresh state; the seed drives the host's perturbation
## eval_observe(state) -> PackedFloat32Array              # the net's input, raw
## eval_baseline(state) -> PackedFloat32Array             # what the baseline would do now, in the net's output layout
## eval_step(state, action: PackedFloat32Array) -> void   # one think
## eval_done(state) -> bool
## eval_score(state) -> float                             # the kind's own metric, higher is better (1 for landed; seconds alive)
## [/codeblock]
## Pure and repeatable: the same net, manifest, host and config give the same report, byte for byte. [method evaluate] returns a success when every map passes and a failure otherwise; the report (the metrics in both cases) is in [member report].

const CHANNEL := "bot.eval"
const FORMAT := "dotbot-eval"
const VERSION := 1
const MAX_SEEDS := 256
const MAX_STEPS := 1 << 20

## Seeds each episode is replayed under; the spread is measured across them, so 2 is the least.
var seeds: int = 5
## Base of every derived seed.
var base_seed: int = 1
## Thinks an episode may last before it is scored as it stands.
var max_steps: int = 2000
## A map passes only when the mean paired gain (policy minus baseline, per seed) is at least this.
var min_margin: float = 0.02
## ...and at least this many standard deviations of the per-seed gain.
var spread_k: float = 2.0
## ...and the policy's own mean score is at least this.
var min_policy_score: float = 0.0
## Held-out episodes a map needs before it can pass.
var min_episodes: int = 1

## The last report; empty before a run.
var report: Dictionary = {}


## The seed for [param episode_id] under seed number [param index]: a fixed mixing of the three, the same on every machine.
func seed_for(episode_id: int, index: int) -> int:
	var x: int = (base_seed * 1000003 + episode_id * 7919 + index * 104729 + 12345) & 0x7FFFFFFF
	for i in 3:
		x = ((x ^ (x >> 15)) * 2246822519) & 0x7FFFFFFF
		x = (x ^ (x >> 13)) & 0x7FFFFFFF
	return x


## Runs [param net] and the host's baseline over the manifest's held-out entries (from [method DotBotDemoExport.load_manifest]). Failure for bad inputs or a gate that does not pass; see [member report].
func evaluate(net: DotBotMlp, manifest: Dictionary, host: Object) -> DotResult:
	report = {}
	var bad := _check_inputs(net, manifest, host)
	if bad != "":
		return DotResult.fail(DotError.CODE_INVALID, bad)
	var held: Array = manifest.get("held_out", [])
	var order: Array = []
	for e: Variant in held:
		order.append(e)
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["id"]) < int(b["id"]))

	var by_map := {}
	var map_order: Array = []
	for e: Dictionary in order:
		var key := "%s@%s" % [e["map_id"], e["map_version"]]
		if not by_map.has(key):
			by_map[key] = []
			map_order.append(key)
		(by_map[key] as Array).append(e)
	map_order.sort()

	var maps := {}
	var failed: PackedStringArray = PackedStringArray()
	var passing: Array = []
	for key: String in map_order:
		var verdict := _map_verdict(net, by_map[key], host)
		maps[key] = verdict
		if verdict["pass"]:
			passing.append(key)
		else:
			failed.append("%s (%s)" % [key, verdict["reason"]])
	var ok := not map_order.is_empty() and failed.is_empty()
	report = {
		"format": FORMAT, "version": VERSION, "kind": net.kind, "schema_id": net.schema_id,
		"config": {"seeds": seeds, "base_seed": base_seed, "max_steps": max_steps, "min_margin": min_margin, "spread_k": spread_k, "min_policy_score": min_policy_score, "min_episodes": min_episodes},
		"maps": maps, "policy_on": passing, "pass": ok,
	}
	if map_order.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "The manifest holds no held-out episodes.", JSON.stringify(report))
	if not ok:
		return DotResult.fail(DotError.CODE_INVALID, "The policy does not beat the baseline on: %s." % ", ".join(failed), JSON.stringify(report))
	return DotResult.success(report)


## The report as stable text (sorted keys), for committing beside the weights.
func report_text() -> String:
	return JSON.stringify(report, "\t", true) + "\n"


func _check_inputs(net: DotBotMlp, manifest: Dictionary, host: Object) -> String:
	if net == null or net.sizes.is_empty():
		return "There is no net."
	if host == null:
		return "There is no host."
	for m in ["eval_start", "eval_observe", "eval_baseline", "eval_step", "eval_done", "eval_score"]:
		if not host.has_method(m):
			return "The host has no %s." % m
	if seeds < 2 or seeds > MAX_SEEDS or max_steps < 1 or max_steps > MAX_STEPS or min_episodes < 1:
		return "seeds is 2 to %d, max_steps 1 to %d and min_episodes 1 or more." % [MAX_SEEDS, MAX_STEPS]
	if not is_finite(min_margin) or not is_finite(spread_k) or spread_k < 0.0 or not is_finite(min_policy_score):
		return "min_margin, spread_k and min_policy_score are finite and spread_k is not negative."
	if not manifest.get("held_out") is Array:
		return "The manifest has no held-out list."
	if String(manifest.get("schema_id", "")) != net.schema_id or String(manifest.get("kind", "")) != net.kind:
		return "The net (%s, schema %s) was not trained on this manifest (%s, schema %s)." % [net.kind, net.schema_id, manifest.get("kind", ""), manifest.get("schema_id", "")]
	return ""


func _map_verdict(net: DotBotMlp, eps: Array, host: Object) -> Dictionary:
	var diffs := PackedFloat64Array()
	var sum_p := 0.0
	var sum_b := 0.0
	var wins := 0
	var runs := 0
	var n := float(eps.size())
	for s in seeds:
		var p_sum := 0.0
		var b_sum := 0.0
		for e: Dictionary in eps:
			var sd := seed_for(int(e["id"]), s)
			var ps := _play(host, e["start"], sd, net)
			var bs := _play(host, e["start"], sd, null)
			p_sum += ps
			b_sum += bs
			runs += 1
			if ps > bs:
				wins += 1
		diffs.append(p_sum / n - b_sum / n)
		sum_p += p_sum / n
		sum_b += b_sum / n
	var mean_d := 0.0
	for d in diffs:
		mean_d += d
	mean_d /= seeds
	var var_sum := 0.0
	for d in diffs:
		var_sum += (d - mean_d) * (d - mean_d)
	var spread := sqrt(var_sum / (seeds - 1))
	var policy_mean := sum_p / seeds
	var needed := maxf(min_margin, spread_k * spread)
	var reason := ""
	if eps.size() < min_episodes:
		reason = "%d held-out episodes, %d needed" % [eps.size(), min_episodes]
	elif policy_mean < min_policy_score:
		reason = "policy score %.4f under the floor %.4f" % [policy_mean, min_policy_score]
	elif mean_d < needed or mean_d <= 0.0:
		reason = "gain %.4f under the %.4f needed" % [mean_d, needed]
	return {
		"episodes": eps.size(), "runs": runs, "policy_mean": policy_mean, "baseline_mean": sum_b / seeds,
		"gain": mean_d, "spread": spread, "needed": needed, "wins": wins, "per_seed_gain": Array(diffs),
		"pass": reason == "", "reason": reason,
	}


## One replay of one start under one seed; [param net] null plays the baseline.
func _play(host: Object, start: Dictionary, sd: int, net: DotBotMlp) -> float:
	var state: Variant = host.eval_start(start, sd)
	var steps := 0
	while steps < max_steps and not host.eval_done(state):
		var action: PackedFloat32Array
		if net == null:
			action = host.eval_baseline(state)
		else:
			action = net.forward(host.eval_observe(state))
		host.eval_step(state, action)
		steps += 1
	return float(host.eval_score(state))
