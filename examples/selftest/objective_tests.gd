extends "res://examples/selftest/trick_tests.gd"

## Team jobs in a flag mode: role split, each role's goal, and a brain walking its job.

const RED_HOME := Vector3(0.0, 0.0, 0.0)
const BLUE_HOME := Vector3(60.0, 0.0, 0.0)


func _flags(blue_state: int = DotBotObjective.HOME, blue_at: Vector3 = BLUE_HOME, carrier: int = -1, red_state: int = DotBotObjective.HOME, red_at: Vector3 = RED_HOME) -> DotBotObjective:
	var o := DotBotObjective.new()
	o.set_flag(1, RED_HOME, red_at, -1, red_state, RED_HOME)
	o.set_flag(2, BLUE_HOME, blue_at, carrier, blue_state, BLUE_HOME)
	return o


func _red(id: int, at: Vector3) -> DotBotContact:
	var c := DotBotContact.make(id, at)
	c.team = 1
	return c


func _planned(o: DotBotObjective, me: DotBotContact, p: DotBotProfile, now: float = 0.0) -> DotBotGoal:
	var g := DotBotGoal.new(me.id)
	g.plan(me, o, null, p, DotRandomStream.new(me.id).stream(&"dot_bot"), now)
	return g


func _test_objective() -> void:
	_section("objective: roles by share and persona, goals by role, a brain walking its job")
	var p := DotBotProfile.new()

	var o := DotBotObjective.new()
	for id in 10:
		var _r := o.assign(100 + id, 1, p)
	var split := o.roles_in(1)
	print("       medium split of 10: %s" % split)
	_check(split[DotBotObjective.DEFEND] == 3 and split[DotBotObjective.ATTACK] == 4 and split[DotBotObjective.SUPPORT] == 3, "ten bots split 3/4/3 by the default shares", str(split))
	_check(o.assign(100, 1, p) == o.role_of(100), "a bot keeps its role on a second assign")
	o.release(100)
	_check(o.role_of(100) == DotBotObjective.ROAM, "a released bot has no role")

	var even := p.copy()
	even.role_defend = 1.0
	even.role_attack = 1.0
	even.role_support = 0.0
	var leaning := DotBotObjective.new()
	_check(leaning.assign(1, 1, even, Vector3(1.0, 0.0, 0.0)) == DotBotObjective.DEFEND, "a holder persona takes defence first")
	for id in 8:
		var _r := leaning.assign(2 + id, 1, even, Vector3(0.0, 0.0, 1.0))
	_check(leaning.roles_in(1)[DotBotObjective.SUPPORT] == 0, "a role with no share stays empty whatever the persona leans to")

	var holder := DotBotPersona.from_values("holder", {"hold": 4.0, "hunt": 1.0, "loot": 0.0, "support": 0.0, "scout": 0.0})
	var bias := holder.role_bias()
	_check(bias.x > bias.y and bias.z == 0.0, "a holding mix leans to defence", str(bias))

	var none := p.copy()
	none.role_defend = 0.0
	none.role_attack = 0.0
	none.role_support = 0.0
	_check(DotBotObjective.new().assign(1, 1, none) == DotBotObjective.ROAM, "all shares 0 leaves the bot roaming as before")

	# Goals.
	var flags := _flags()
	var _a := flags.assign(1, 1, even, Vector3(0.0, 1.0, 0.0))
	var _d := flags.assign(2, 1, even, Vector3(1.0, 0.0, 0.0))
	var focused := p.copy()
	focused.objective_focus = 1.0
	var grab := _planned(flags, _red(1, Vector3(10.0, 0.0, 0.0)), focused)
	_check(grab.kind == &"grab" and grab.dest == BLUE_HOME, "an attacker goes for the enemy flag", "%s %s" % [grab.kind, grab.dest])
	var guard := _planned(flags, _red(2, Vector3(5.0, 0.0, 0.0)), focused)
	_check(guard.kind == &"defend" and guard.dest.distance_to(RED_HOME) <= focused.defend_radius + 0.01, "a defender posts within bot_defend_radius of home", "%s %s" % [guard.kind, guard.dest])
	_check(guard.strays(Vector3(45.0, 0.0, 0.0)) and not guard.strays(Vector3(10.0, 0.0, 0.0)), "a defender is leashed to twice the radius")

	var carried := _flags(DotBotObjective.CARRIED, Vector3(50.0, 0.0, 0.0), 1)
	var _a2 := carried.assign(1, 1, even, Vector3(0.0, 1.0, 0.0))
	var attackers := p.copy()
	attackers.role_defend = 0.0
	attackers.role_support = 0.0
	var _a3 := carried.assign(3, 1, attackers)
	var run := _planned(carried, _red(1, Vector3(50.0, 0.0, 0.0)), focused)
	_check(run.kind == &"capture" and run.urgent and run.dest == RED_HOME, "the carrier runs home, urgent", "%s %s" % [run.kind, run.dest])
	var escort := _planned(carried, _red(3, Vector3(30.0, 0.0, 0.0)), focused)
	_check(escort.kind == &"escort" and escort.dest == Vector3(50.0, 0.0, 0.0), "a teammate escorts the carrier", "%s %s" % [escort.kind, escort.dest])

	var dropped := _flags(DotBotObjective.HOME, BLUE_HOME, -1, DotBotObjective.DROPPED, Vector3(20.0, 0.0, 0.0))
	var _d2 := dropped.assign(2, 1, even, Vector3(1.0, 0.0, 0.0))
	var back := _planned(dropped, _red(2, Vector3(5.0, 0.0, 0.0)), focused)
	_check(back.kind == &"return" and back.dest == Vector3(20.0, 0.0, 0.0), "a defender returns its dropped flag", "%s %s" % [back.kind, back.dest])

	var spells := {}
	var focuses: Array[float] = [0.0, 1.0]
	for focus in focuses:
		var loose := p.copy()
		loose.objective_focus = focus
		var g := DotBotGoal.new(1)
		var rng := DotRandomStream.new(5).stream(&"dot_bot")
		var free := 0
		var t := 0.0
		while t < 120.0:
			g.plan(_red(1, Vector3(10.0, 0.0, 0.0)), flags, null, loose, rng, t)
			if g.kind == &"":
				free += 1
			t += DotBotGoal.REPLAN
		spells[focus] = free
	_check(int(spells[1.0]) == 0 and int(spells[0.0]) > 20, "bot_objective_focus 1 never strays off the job; 0 often does", str(spells))

	# A brain walking its job: the carrier runs home on a flat floor.
	var me := _red(1, Vector3(50.0, 0.0, 0.0))
	var world := DotBotWorld.new()
	world.contacts_fn = func() -> Array: return [me]
	world.objective = carried
	var brain := DotBotBrain.new(1, DotBotSettings.new())
	var t := 0.0
	var states := {}
	while t < 12.0:
		var intent := brain.think(me, world, t)
		states[intent.state] = true
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		var y := deg_to_rad(intent.yaw)
		var dir := Vector2(cos(y), -sin(y)) * intent.move.x + Vector2(-sin(y), -cos(y)) * intent.move.y
		me.position += Vector3(dir.x, 0.0, dir.y) * 6.0 * TICK
		carried.set_flag(2, BLUE_HOME, me.position, 1, DotBotObjective.CARRIED, BLUE_HOME)
		t += TICK
	print("       carrier ended at %s, states %s" % [me.position, states.keys()])
	_check(me.position.distance_to(RED_HOME) < 12.0, "a carrier brain walks the flag home", str(me.position))
	_check(states.has(&"capture"), "its state names the job")
	_check(brain.describe()["role"] == DotBotObjective.ATTACK, "describe reports the role")
	_done()
