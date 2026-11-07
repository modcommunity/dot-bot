extends "res://examples/selftest/mlp_tests.gd"
## The evaluation gate section of the bot suite, on a one-dimensional synthetic simulator and synthetic policies.


## A bot that moves `x` by its action for 20 thinks; the score is where it ends. The seed perturbs the gain, deterministically; `bb` in a start state is a bonus the baseline gets (so a map can favour it).
class EvalHost extends RefCounted:
	var starts := 0

	func eval_start(start: Dictionary, seed: int) -> Variant:
		starts += 1
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		return {"x": 0.0, "n": 0, "gain": 1.0 + rng.randf_range(-0.2, 0.2), "bb": float(start.get("bb", 0.0))}

	func eval_observe(state: Variant) -> PackedFloat32Array:
		return PackedFloat32Array([state["x"]])

	func eval_baseline(state: Variant) -> PackedFloat32Array:
		return PackedFloat32Array([0.05 + state["bb"]])

	func eval_step(state: Variant, action: PackedFloat32Array) -> void:
		state["x"] += action[0] * state["gain"]
		state["n"] += 1

	func eval_done(state: Variant) -> bool:
		return state["n"] >= 20

	func eval_score(state: Variant) -> float:
		return state["x"]


## A net of sizes [1, 1] that ignores its input and always outputs [param level].
func _const_net(level: float) -> DotBotMlp:
	var layers := [{"w": PackedFloat32Array([0.0]), "b": PackedFloat32Array([level])}]
	var enc := DotBotMlp.encode("sidE", "ride", PackedInt32Array([1, 1]), PackedStringArray(["linear"]), PackedFloat32Array([1.0]), layers)
	return DotBotMlp.from_data(enc["header"], enc["weights"]).value


func _eval_manifest(bb_b: float = 0.0) -> Dictionary:
	var held: Array = []
	for i in 4:
		held.append({"id": 10 + i, "map_id": "a" if i < 2 else "b", "map_version": "1", "key": "k", "start": {"bb": 0.0 if i < 2 else bb_b}})
	return {"kind": "ride", "schema_id": "sidE", "held_out": held}


func _test_eval_gate() -> void:
	_section("eval gate: paired seeded replays, per-map verdict, deterministic")
	var gate := DotBotEvalGate.new()
	var host := EvalHost.new()
	var man := _eval_manifest()

	var good := gate.evaluate(_const_net(0.1), man, host)
	_check(good.ok and gate.report["pass"] and gate.report["policy_on"] == ["a@1", "b@1"], "a policy twice the baseline passes on both maps", good.error.message if not good.ok else "")
	var a: Dictionary = gate.report["maps"]["a@1"]
	_check(a["episodes"] == 2 and a["runs"] == 10 and a["wins"] == 10 and a["gain"] > 0.9 and a["policy_mean"] > a["baseline_mean"], "metrics are reported per map", str(a))
	_check(host.starts == 2 * 4 * gate.seeds, "each held-out start is replayed once per seed for each side", str(host.starts))

	var first := gate.report_text()
	gate.evaluate(_const_net(0.1), man, EvalHost.new())
	_check(gate.report_text() == first, "the same inputs give the same report, byte for byte")
	gate.base_seed = 2
	gate.evaluate(_const_net(0.1), man, EvalHost.new())
	_check(gate.report_text() != first and gate.seed_for(10, 0) != DotBotEvalGate.new().seed_for(10, 0), "another base seed perturbs differently")
	gate.base_seed = 1

	var same := gate.evaluate(_const_net(0.05), man, host)
	_check(not same.ok and not gate.report["pass"] and gate.report["policy_on"] == [], "a policy equal to the baseline fails on every map")
	var worse := gate.evaluate(_const_net(0.02), man, host)
	_check(not worse.ok and gate.report["maps"]["a@1"]["gain"] < 0.0 and worse.error.message.contains("a@1"), "a worse policy fails and the message names the maps")

	var mixed := gate.evaluate(_const_net(0.1), _eval_manifest(0.2), host)
	_check(not mixed.ok and gate.report["policy_on"] == ["a@1"] and gate.report["maps"]["b@1"]["pass"] == false, "a policy that loses on one map is on only where it wins")

	gate.min_margin = 5.0
	_check(not gate.evaluate(_const_net(0.1), man, host).ok, "a gain under the margin fails")
	gate.min_margin = 0.02
	gate.min_policy_score = 100.0
	_check(not gate.evaluate(_const_net(0.1), man, host).ok, "a policy under the score floor fails")
	gate.min_policy_score = 0.0
	gate.min_episodes = 3
	_check(not gate.evaluate(_const_net(0.1), man, host).ok, "a map with too few held-out episodes fails")
	gate.min_episodes = 1
	gate.spread_k = 1000.0
	_check(not gate.evaluate(_const_net(0.1), man, host).ok, "a gain inside the seed spread fails")
	gate.spread_k = 2.0

	var wrong := _eval_manifest()
	wrong["schema_id"] = "other"
	_check(gate.evaluate(_const_net(0.1), wrong, host).code() == DotError.CODE_INVALID, "a net for another schema is refused")
	_check(gate.evaluate(_const_net(0.1), {"kind": "ride", "schema_id": "sidE", "held_out": []}, host).code() == DotError.CODE_INVALID, "no held-out episodes is a failure, not a pass")
	_check(gate.evaluate(_const_net(0.1), man, RefCounted.new()).code() == DotError.CODE_INVALID, "a host without the eval methods is refused")
	gate.seeds = 1
	_check(gate.evaluate(_const_net(0.1), man, host).code() == DotError.CODE_INVALID, "one seed has no spread and is refused")
	_done()
