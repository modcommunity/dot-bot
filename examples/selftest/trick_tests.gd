extends "res://examples/selftest/duel_tests.gd"

## The movement tricks (slide, wall run, duck, air-jump) per preset, on a toy motor that grants a wall run only after a slide and a jump.


## One bot running at 8 m/s beside a wall for [param seconds]; returns the tricks' counts.
func _trick_run(preset: String, scenario: StringName, seconds: float, ready: bool, health: float, up: float, speed: float = 8.0) -> Dictionary:
	var s := DotBotSettings.new()
	s.set_difficulty(preset)
	var tricks := DotBotTricks.new()
	var rng := DotRandomStream.new(7).stream(&"dot_bot")
	var world := DotBotWorld.new()
	world.wall_fn = func(_from: Vector3, dir: Vector3, reach: float) -> Dictionary:
		return {"normal": Vector3(-dir.x, 0.0, -dir.z), "distance": 1.0} if dir.x > 0.5 and reach > 1.0 else {}
	var me := DotBotContact.new()
	me.velocity = Vector3(0, 0, -speed)
	me.air_jump_ready = ready
	me.health = health
	var air := 0.0
	var slid := 0.0
	var boosted := false
	var t := 0.0
	var presses := 0
	while t < seconds:
		var out := DotBotIntent.new()
		tricks.apply(me, world, s.profile, rng, scenario, up, 0.0, t, TICK, out)
		if out.air_jump:
			presses += 1
		if me.grounded and out.crouch:
			slid = 0.4
		elif slid > 0.0:
			slid -= TICK
			boosted = true
		if me.grounded and out.jump:
			me.grounded = false
			air = 0.7
		elif not me.grounded:
			air -= TICK
			me.wall_running = boosted and air > 0.0 and air < 0.6
			if air <= 0.0:
				me.grounded = true
				me.wall_running = false
				boosted = false
		t += TICK
	var counts := tricks.counts.duplicate()
	counts[&"presses"] = presses
	return counts


func _test_tricks() -> void:
	_section("tricks: slide, wall run, duck and air-jump by preset")

	var easy := _trick_run("easy", &"close", 120.0, false, 1.0, 0.0)
	var hard := _trick_run("nightmare", &"close", 120.0, false, 1.0, 0.0)
	print("       easy %s | nightmare %s" % [easy, hard])
	_check(int(hard[&"slide"]) >= 8, "a nightmare bot slides while closing", str(hard[&"slide"]))
	_check(int(hard[&"wall"]) >= 3, "a nightmare bot takes the wall it runs beside", str(hard[&"wall"]))
	_check(int(easy[&"slide"]) * 5 <= int(hard[&"slide"]) * 4, "an easy bot slides less", "%d vs %d" % [easy[&"slide"], hard[&"slide"]])
	_check(int(easy[&"wall"]) * 2 <= int(hard[&"wall"]), "an easy bot rarely wall runs", "%d vs %d" % [easy[&"wall"], hard[&"wall"]])
	_check(int(hard[&"wall_jump"]) >= 1, "a wall run ends in a wall jump when chained")

	var still := _trick_run("nightmare", &"cover", 120.0, false, 1.0, 0.0, 0.0)
	var calm := _trick_run("easy", &"cover", 120.0, false, 1.0, 0.0, 0.0)
	_check(int(still[&"crouch"]) > int(calm[&"crouch"]), "a nightmare bot ducks in cover more than an easy one", "%d vs %d" % [still[&"crouch"], calm[&"crouch"]])

	var off := _trick_run("nightmare", &"flee", 60.0, false, 0.2, 0.0)
	var on := _trick_run("nightmare", &"flee", 60.0, true, 0.2, 0.0)
	var low := _trick_run("easy", &"flee", 60.0, true, 0.2, 0.0)
	_check(int(off[&"presses"]) == 0, "no air-jump press while the game has it off")
	_check(int(on[&"presses"]) >= 2, "a hurt nightmare bot flees by air-jump when it is on", str(on[&"presses"]))
	_check(int(low[&"presses"]) == 0, "an easy bot never uses the air-jump")

	var a := _trick_run("hard", &"close", 60.0, false, 1.0, 0.0)
	var b := _trick_run("hard", &"close", 60.0, false, 1.0, 0.0)
	_check(a == b, "the same seed plays the same tricks")
	_done()
