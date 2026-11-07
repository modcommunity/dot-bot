extends "res://examples/selftest/eval_tests.gd"
## The policy section of the bot suite: a synthetic net behind the gate, off unless every condition holds.


## A one-input net whose output is its bias: move (0.3, 0.4), look (yaw 100, pitch 0), fire and jump as logits.
func _policy_parts(jump_logit: float = -1.0) -> Array:
	var schema := DotBotDemoSchema.make("policy", 1).add_observation("one", 1, 1.0).add_action("move", 2).add_action("look", 2).add_action("fire", 1, 1.0, true).add_action("jump", 1, 1.0, true)
	var layers := [{"w": PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0]), "b": PackedFloat32Array([0.3, 0.4, 100.0, 0.0, 1.0, jump_logit])}]
	var enc := DotBotMlp.encode("sidP", "roam", PackedInt32Array([1, 6]), PackedStringArray(["linear"]), PackedFloat32Array([1.0]), layers)
	return [DotBotMlp.from_data(enc["header"], enc["weights"]).value, schema]


func _policy_for(jump_logit: float = -1.0) -> DotBotPolicy:
	var parts := _policy_parts(jump_logit)
	var pol := DotBotPolicy.new()
	var r := pol.set_net(parts[0], parts[1])
	_check(r.ok, "a net with a schema of its own output size is accepted")
	pol.observe_fn = func(_me: DotBotContact, _w: DotBotWorld, into: PackedFloat32Array) -> void: into[0] = 1.0
	return pol


func _policy_report(on: Array, pass_: bool = true, schema_id: String = "sidP") -> Dictionary:
	return {"format": DotBotEvalGate.FORMAT, "version": 1, "kind": "roam", "schema_id": schema_id, "maps": {}, "policy_on": on, "pass": pass_}


func _test_policy() -> void:
	_section("bot_policy: a cloned net behind the gate, off unless it passes")

	_check(DotBotProfile.spec_for("policy").size() > 0 and DotBotProfile.new().policy == 0.0, "bot_policy is a setting and 0 by default")
	for preset in DotBotProfile.PRESETS:
		_check(DotBotProfile.preset_value(preset, "policy") == 0.0, "%s leaves the policy off" % preset)
	_check(DotBotProfile.new().set_field("policy", "3").value == 1.0, "bot_policy clamps to 1")

	var parts := _policy_parts()
	var bad := DotBotPolicy.new()
	var short := DotBotDemoSchema.make("policy", 1).add_observation("one").add_action("move", 2)
	_check(not bad.set_net(parts[0], short).ok and bad.net == null, "a schema whose actions are not the net's output size is refused")

	# Baseline: the same scene with no policy.
	var sc := _scene(Vector3(0, 0, -6.0))
	var plain := DotBotBrain.new(1, DotBotSettings.new())
	var base := _run_bot(plain, sc[0], sc[2], 1.0)

	var pol := _policy_for()
	var s := DotBotSettings.new()
	var brain := DotBotBrain.new(1, s)
	brain.policy = pol
	sc = _scene(Vector3(0, 0, -6.0))
	var off := _run_bot(brain, sc[0], sc[2], 1.0)
	var same := true
	for k in base.size():
		var a: DotBotIntent = base[k]
		var b: DotBotIntent = off[k]
		same = same and a.yaw == b.yaw and a.move == b.move and a.fire == b.fire and b.state != &"policy"
	_check(same and pol.thinks == 0, "with bot_policy 0 a net and an allowed map change nothing")

	s.set_value("policy", "1")
	_check(not pol.active(s.profile, 1), "bot_policy 1 alone does nothing: no map is allowed yet")
	pol.map_key = "m@1"
	_check(not pol.active(s.profile, 1), "an unset gate allows no map")
	_check(pol.allow_from_report(_policy_report(["m@1"], false)) == 0 and not pol.active(s.profile, 1), "a failed gate report allows nothing")
	_check(pol.allow_from_report(_policy_report(["m@1"], true, "other")) == 0, "a report for another schema allows nothing")
	_check(pol.allow_from_report("x") == 0 and pol.allow_from_report({}) == 0, "a report that is not a report allows nothing")
	_check(pol.allow_from_report(_policy_report(["n@1"])) == 1 and not pol.active(s.profile, 1), "a passing report for another map allows nothing here")
	_check(pol.allow_from_report(_policy_report(["m@1", "n@1"])) == 2 and pol.active(s.profile, 1), "a passing report listing the map turns the policy on")
	var no_obs := _policy_for()
	no_obs.observe_fn = Callable()
	no_obs.map_key = "m@1"
	no_obs.allowed_maps = PackedStringArray(["m@1"])
	_check(not no_obs.active(s.profile, 1), "no observation function, no policy")

	# On: the net's action is the intent, held to the turn rate, and fire needs a target.
	brain = DotBotBrain.new(1, s)
	brain.policy = pol
	sc = _scene(Vector3(0, 0, -6.0))
	var on := _run_bot(brain, sc[0], sc[2], 1.0)
	var moved := true
	var fastest := 0.0
	var fired := 0
	var jumped := false
	for k in on.size():
		var it: DotBotIntent = on[k]
		moved = moved and it.state == &"policy" and it.move.distance_to(Vector2(0.3, 0.4)) < 1e-5
		jumped = jumped or it.jump
		fired += 1 if it.fire else 0
		if k > 0:
			fastest = maxf(fastest, absf(wrapf(it.yaw - (on[k - 1] as DotBotIntent).yaw, -180.0, 180.0)) / TICK)
	_check(moved and pol.thinks == on.size(), "the net's move is the bot's move on every think")
	_check(not jumped, "a button below zero is not pressed")
	_check(fastest > 0.0 and fastest <= s.profile.turn_rate * 1.01, "the net's look is held to bot_turn_rate", str(fastest))
	_check(fired > 0, "fire is pressed once the brain has a target in sight", str(fired))

	sc = _scene(Vector3(0, 0, -6.0), true)
	brain = DotBotBrain.new(1, s)
	brain.policy = pol
	var blind := _run_bot(brain, sc[0], sc[2], 1.0)
	var any_fire := false
	for it: DotBotIntent in blind:
		any_fire = any_fire or it.fire
	_check(not any_fire, "the net can not fire at what the bot does not see")

	var pj := _policy_for(2.0)
	pj.map_key = "m@1"
	pj.allowed_maps = PackedStringArray(["m@1"])
	brain = DotBotBrain.new(1, s)
	brain.policy = pj
	sc = _scene(Vector3(0, 0, -6.0))
	var jumps := _run_bot(brain, sc[0], sc[2], 0.2)
	_check((jumps[jumps.size() - 1] as DotBotIntent).jump, "a button logit above zero is pressed")

	brain = DotBotBrain.new(1, s)
	brain.policy = pol
	sc = _scene(Vector3(0, 0, -6.0))
	var again := _run_bot(brain, sc[0], sc[2], 1.0)
	var det := true
	for k in on.size():
		det = det and (on[k] as DotBotIntent).describe() == (again[k] as DotBotIntent).describe()
	_check(det, "the same net and scene give the same intents")

	# A share of the bots.
	s.set_value("policy", "0.5")
	var drawn := 0
	for bot_id in 200:
		drawn += 1 if pol.active(s.profile, bot_id) else 0
	_check(drawn > 70 and drawn < 130, "bot_policy 0.5 drives about half the bots", str(drawn))
	_check(pol.active(s.profile, 7) == pol.active(s.profile, 7), "which bots is fixed")
	_done()
