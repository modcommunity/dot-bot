extends "res://examples/selftest/harvest_tests.gd"
## The duels, the aim solver and the humanisation sections of the bot suite.

## K/D against the scripted opponent ([method _duel]), per preset: [low, high].
## Medium sits a little under an ordinary player, hard wins most fights, nightmare nearly all.
## Medium's floor dropped with its slower, human turning: it loses more first shots now.
const KD_BANDS := {
	"easy": [0.0, 0.35],
	"medium": [0.25, 1.5],
	"hard": [2.0, 30.0],
	"nightmare": [8.0, 1000.0],
}

## Rounds per preset in the duel.
const DUELS := 100

## The scripted opponent of [method _duel]: reaction, opening aim error, its floor, and the
## seconds the error takes to halve.
var OPP_REACTION := 0.35
var OPP_ERROR := 4.0
var OPP_FLOOR := 1.5
var OPP_SETTLE := 0.7

## The last duel's engagement, for a probe.
var last_engagement := {}

func _scene(enemy_at: Vector3, wall: bool = false) -> Array:
	var me := DotBotContact.make(1, Vector3.ZERO)
	var enemy := DotBotContact.make(2, enemy_at)
	var world := DotBotWorld.new()
	world.contacts_fn = func() -> Array: return [me, enemy]
	world.line_of_sight_fn = func(_a: Vector3, _b: Vector3) -> bool: return not wall
	return [me, enemy, world]


func _run_bot(brain: DotBotBrain, me: DotBotContact, world: DotBotWorld, seconds: float, start: float = 0.0) -> Array:
	var out: Array = []
	var t := start
	while t < start + seconds:
		var intent := brain.think(me, world, t)
		out.append(intent)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch
		t += TICK
	return out


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var total := 0.0
	for v in values:
		total += v
	return total / float(values.size())


## Kill/death ratio per preset against one fixed scripted opponent in a world of rays: both fire 10 rounds a second, five hits kill, a hit is a ray within 0.3 m of the chest.
## The opponent reacts in 0.35 s, aims 4 degrees off (settling to 1.5), fires half-second bursts and strafes at 4 m/s every 0.7 s, so the number moves only with the bot.
func _test_duels() -> void:
	_section("kill/death against a scripted opponent")

	var previous := -1.0
	for preset in DotBotProfile.PRESETS:
		var s := DotBotSettings.new()
		s.set_difficulty(preset)
		var kills := 0
		var deaths := 0
		for round_ in range(DUELS):
			var outcome := _duel(s, round_)
			if outcome > 0:
				kills += 1
			elif outcome < 0:
				deaths += 1
		var kd := float(kills) / float(maxi(deaths, 1))
		var band: Array = KD_BANDS[preset]
		print("       %-9s %2d kills, %2d deaths, K/D %.2f (band %.1f..%.1f)" % [preset, kills, deaths, kd, band[0], band[1]])
		_check(kd >= float(band[0]) and kd <= float(band[1]), "%s K/D inside its band" % preset, "%.2f" % kd)
		_check(kd > previous, "%s beats the preset before it" % preset)
		previous = kd
	_done()


## One round: +1 the bot won, -1 it lost, 0 nobody died in ten seconds.
func _duel(s: DotBotSettings, round_: int) -> int:
	var rng := DotRandomStream.new(round_).stream(&"duel")
	# Who has the drop varies, as it does in a match: the bot may face the opponent or have
	# its back to them (and then only hears the first shots), and the opponent's own reaction
	# varies from round to round around OPP_REACTION.
	var distance := rng.next_range_f(6.0, 35.0)
	var off := deg_to_rad(rng.next_range_f(-150.0, 150.0))
	# The opponent faces somewhere too: up to 150 degrees off the bot, which costs it a turn
	# (a person flicks round at about 600 degrees a second) before its reaction counts.
	var their_off := absf(rng.next_range_f(-150.0, 150.0))
	var their_reaction := OPP_REACTION * rng.next_range_f(0.7, 1.5) + their_off / 600.0
	var me := DotBotContact.make(1, Vector3.ZERO)
	var them := DotBotContact.make(2, Vector3(-sin(off), 0.0, -cos(off)) * distance)
	var world := DotBotWorld.new()
	world.contacts_fn = func() -> Array: return [me, them]
	var brain := DotBotBrain.new(round_ * 7 + 3, s)

	var my_hp := 5
	var their_hp := 5
	var my_cooldown := 0.0
	var their_cooldown := 0.0
	var my_bloom := 0.0
	var their_bloom := 0.0
	var their_seen_at := 0.0
	var strafe_dir := 1.0
	var t := 0.0
	while t < 10.0:
		var intent := brain.think(me, world, t)
		me.view_yaw = intent.yaw
		me.view_pitch = intent.pitch

		# The bot's move, at 5 m/s.
		var yr := deg_to_rad(intent.yaw)
		var fwd := Vector3(-sin(yr), 0.0, -cos(yr))
		var right := Vector3(cos(yr), 0.0, -sin(yr))
		me.velocity = (right * intent.move.x + fwd * intent.move.y) * 5.0 * (0.5 if intent.crouch else 1.0)
		me.position += me.velocity * TICK

		# The opponent strafes across the bot.
		if fmod(t, 0.7) < TICK:
			strafe_dir = -strafe_dir
		_strafe_across(me, them, strafe_dir)

		# Both shoot. Sustained fire blooms half a degree a round up to four, and recovers at
		# eight a second, so a burst is worth something here as it is in a real weapon.
		my_cooldown -= TICK
		their_cooldown -= TICK
		my_bloom = maxf(my_bloom - 8.0 * TICK, 0.0)
		their_bloom = maxf(their_bloom - 8.0 * TICK, 0.0)
		if intent.fire and my_cooldown <= 0.0:
			my_cooldown = 0.1
			var spread := (0.6 if me.velocity.length() > 1.0 else 0.0) + my_bloom
			my_bloom = minf(my_bloom + 0.5, 4.0)
			if _hits(me.eye(), _wobble(intent.forward(), spread, rng), them.aim_point()):
				their_hp -= 1
		var age := t - their_seen_at - their_reaction + OPP_REACTION
		# The opponent fires half-second bursts with a third of a second between.
		var bursting := fmod(age - OPP_REACTION, 0.8) < 0.5
		if age >= OPP_REACTION and bursting and their_cooldown <= 0.0:
			their_cooldown = 0.1
			var err := OPP_FLOOR + (OPP_ERROR - OPP_FLOOR) * pow(0.5, age / OPP_SETTLE)
			var dir := (me.aim_point() - them.eye()).normalized()
			var aim := _offset(dir, err * (0.55 + 0.45 * sin(t * 2.1)), t * 1.3 + float(round_))
			world.emit_sound(them.eye(), 1.0, them.id, t)
			if _hits(them.eye(), _wobble(aim, 0.6 + their_bloom, rng), me.aim_point()):
				my_hp -= 1
			their_bloom = minf(their_bloom + 0.5, 4.0)
		if their_hp <= 0 or my_hp <= 0:
			last_engagement = brain.engagement()
			last_engagement["t"] = t
			last_engagement["dist"] = snappedf(distance, 0.1)
			last_engagement["off"] = snappedf(rad_to_deg(off), 1)
			last_engagement["hp"] = [my_hp, their_hp]
			return 1 if their_hp <= 0 else -1
		t += TICK
	return 0


## Moves [param them] across [param me] at 4 m/s, one tick, in direction [param strafe_dir].
func _strafe_across(me: DotBotContact, them: DotBotContact, strafe_dir: float) -> void:
	var to_me := me.position - them.position
	var across := Vector3(-to_me.z, 0.0, to_me.x).normalized()
	them.velocity = across * 4.0 * strafe_dir
	them.position += them.velocity * TICK


## [param dir] turned [param degrees] off itself, toward [param angle] around it: an aim
## that is off by a steady, drifting amount, the way a person's is.
func _offset(dir: Vector3, degrees: float, angle: float) -> Vector3:
	var right := dir.cross(Vector3.UP).normalized()
	var up := right.cross(dir).normalized()
	var axis := (right * cos(angle) + up * sin(angle)).normalized()
	return dir.rotated(axis, deg_to_rad(degrees))


func _wobble(dir: Vector3, degrees: float, rng: DotRandomStream) -> Vector3:
	if degrees <= 0.0:
		return dir
	return rng.next_cone(dir, degrees)


func _hits(from: Vector3, dir: Vector3, chest: Vector3) -> bool:
	var to := chest - from
	var along := to.dot(dir)
	if along <= 0.0:
		return false
	return (to - dir * along).length() <= 0.3


func _test_aim_solver() -> void:
	_section("aim solver: drop and lead for simulated bullets, plain aim without tuning")
	var tuning := {"muzzle_velocity": 400.0, "bullet_gravity": 1.0, "drag": 0.0005}
	var eye := Vector3(0.0, 1.6, 0.0)
	var far := Vector3(0.0, 1.6, -150.0)
	var p := DotBotAimSolver.solve(eye, far, Vector3.ZERO, tuning)
	_check(p.y > far.y + 0.3 and absf(p.x) < 0.001 and absf(p.z - far.z) < 0.001, "a still target at range is aimed above, for drop", str(p))
	var mv := DotBotAimSolver.solve(eye, far, Vector3(10.0, 0.0, 0.0), tuning)
	_check(mv.x > 1.0 and mv.y > far.y, "a target crossing right is led to the right", str(mv))
	var ml := DotBotAimSolver.solve(eye, far, Vector3(-10.0, 0.0, 0.0), tuning)
	_check(ml.x < -1.0 and absf(ml.x + mv.x) < 0.5, "and to the left when crossing left, by the same amount", str(ml))
	_check(DotBotAimSolver.solve(eye, far, Vector3(10.0, 0.0, 0.0), null) == far, "no tuning gives the plain aim point")
	_check(DotBotAimSolver.solve(eye, far, Vector3.ZERO, {"muzzle_velocity": 0.0}) == far, "a hitscan weapon (no muzzle velocity) gives the plain aim point")
	var out := Vector3(0.0, 1.6, -5000.0)
	_check(DotBotAimSolver.solve(eye, out, Vector3.ZERO, tuning) == out, "no solution (out of reach) falls back to the plain aim point")
	var aim := DotBotAim.new(1, DotBotSettings.new())
	_check(not aim.aim_solver.is_valid(), "off by default: no solver is assigned")
	var plain := DotBotAim.new(2, DotBotSettings.new())
	var solved := DotBotAim.new(2, DotBotSettings.new())
	solved.aim_solver = func(e: Vector3, pt: Vector3, v: Vector3) -> Vector3: return DotBotAimSolver.solve(e, pt, v, tuning)
	var _a := plain.engage(7, eye, far, 0.0)
	var _b := solved.engage(7, eye, far, 0.0)
	var va := plain.track(eye, far, Vector3.ZERO, 5.0, 0.1)
	var vb := solved.track(eye, far, Vector3.ZERO, 5.0, 0.1)
	_check(vb.y != va.y or vb.x != va.x, "an assigned solver changes where track aims")
	_done()


const HUMAN := ["react_jitter", "overshoot", "track_lag", "strafe_jitter", "glance", "hesitate", "hurt_delay"]


## Medium with the aim error out of the way, and the humanisation on or all the way off.
func _human_settings(on: bool, overrides: Dictionary = {}) -> DotBotSettings:
	var s := DotBotSettings.new()
	s.set_difficulty("medium")
	var p := s.profile
	p.aim_error = 0.0
	p.aim_floor = 0.0
	p.flinch = 0.0
	if not on:
		for f in HUMAN:
			p.set(StringName(f), 0.0)
	for key in overrides:
		p.set(StringName(key), overrides[key])
	return s


func _stdev(values: Array[float]) -> float:
	var m := _mean(values)
	var acc := 0.0
	for v in values:
		acc += (v - m) * (v - m)
	return sqrt(acc / maxf(float(values.size()), 1.0))


func _test_humanisation() -> void:
	_section("humanisation: each cvar changes the behaviour and 0 restores the plain one")

	var fields := DotBotProfile.fields()
	for f in HUMAN:
		_check(fields.has(f) and DotBotProfile.preset_value("medium", f) > 0.0, "bot_%s is a setting, on in medium" % f)
	var cs := DotBotSettings.new()
	_check(cs.set_value("glance", "0").ok and cs.profile.glance == 0.0 and cs.is_overridden("glance"), "bot_glance 0 is an override that turns it off")

	_human_reaction()
	_human_overshoot()
	_human_track_lag()
	_human_strafe()
	_human_glance()
	_human_hesitate()
	_human_hurt_delay()
	_stale_standoff()
	_done()


func _stale_standoff() -> void:
	# A fight at the bot's own range holds its ground at first, then walks in once it has stood there too long.
	var sc := _scene(Vector3(0.0, 0.0, -10.0))
	var s := _human_settings(false, {"strafe": 0.0, "stop_to_shoot": 0.0, "crouch": 0.0, "cover": 0.0})
	var brain := DotBotBrain.new(5100, s)
	var intents := _run_bot(brain, sc[0], sc[2], 12.0)
	var early := 0.0
	var late := INF
	for i in intents.size():
		var t := float(i) * TICK
		var y := (intents[i] as DotBotIntent).move.y
		if t > 2.0 and t < DotBotBrain.STALE_FIGHT - 1.0:
			early = maxf(early, absf(y))
		elif t > DotBotBrain.STALE_FIGHT + 1.0:
			late = minf(late, y)
	print("       standoff at 10 m: forward early %.2f, late %.2f" % [early, late])
	_check(early < 0.2 and late > 0.8, "a standoff at range holds, then pushes in after STALE_FIGHT", "early %.2f late %.2f" % [early, late])


func _human_reaction() -> void:
	# Reaction: spread of the time to first shot.
	var spread := {}
	var minimum := {}
	for on in [false, true]:
		var times: Array[float] = []
		for trial in range(60):
			var sc := _scene(Vector3(0.0, 0.0, -15.0))
			var brain := DotBotBrain.new(2000 + trial, _human_settings(on))
			_run_bot(brain, sc[0], sc[2], 3.0)
			var e := brain.engagement()
			times.append(float(e["first_shot_at"]) - float(e["seen_at"]))
		spread[on] = _stdev(times)
		minimum[on] = times.min()
		print("       reaction jitter %s: stdev %.3f s, fastest %.3f s" % ["on" if on else "off", spread[on], minimum[on]])
	_check(spread[true] > spread[false] * 1.5, "reaction time varies more with bot_react_jitter on", "%.3f vs %.3f" % [spread[true], spread[false]])
	_check(minimum[true] >= 0.3 * 0.85 - 0.02 and minimum[false] >= 0.3 * 0.85 - 0.02, "jitter never makes it faster than the plain reaction")


func _human_overshoot() -> void:
	# Overshoot: a flick onto a target 70 degrees off swings past it only with the setting.
	var swing := {}
	for on in [false, true]:
		var worst := 0.0
		for trial in range(8):
			var sc := _scene(Vector3(-sin(deg_to_rad(70.0)), 0.0, -cos(deg_to_rad(70.0))) * 12.0)
			var s := _human_settings(on)
			s.profile.turn_rate = 900.0
			s.profile.turn_smooth = 0.9
			s.profile.reaction = 0.05
			var brain := DotBotBrain.new(3000 + trial, s)
			var target_yaw := DotBotAim.angles_to((sc[0] as DotBotContact).eye(), (sc[1] as DotBotContact).aim_point()).x
			for intent: DotBotIntent in _run_bot(brain, sc[0], sc[2], 1.5):
				worst = maxf(worst, intent.yaw - target_yaw if target_yaw > 0.0 else target_yaw - intent.yaw)
		swing[on] = worst
		print("       overshoot %s: view passes the target by %.2f deg" % ["on" if on else "off", worst])
	_check(swing[false] < 0.5, "no overshoot with bot_overshoot 0", "%.2f" % swing[false])
	_check(swing[true] > 0.8, "the view swings past the target with bot_overshoot on", "%.2f" % swing[true])


func _human_track_lag() -> void:
	# Tracking lag: a target that reverses is followed late, a steady one is not.
	var trail := {}
	for lag in [0.0, 0.15]:
		var sc := _scene(Vector3(-6.0, 0.0, -15.0))
		var enemy: DotBotContact = sc[1]
		var s := _human_settings(false, {"track_lag": lag, "prediction": 1.0, "turn_smooth": 1.0, "turn_rate": 1500.0})
		var brain := DotBotBrain.new(4000, s)
		var worst := 0.0
		var x := -6.0
		var t := 0.0
		while t < 1.6:
			enemy.velocity = Vector3(8.0 if t < 0.8 else -8.0, 0.0, 0.0)
			x += enemy.velocity.x * TICK
			enemy.position.x = x
			var intent := brain.think(sc[0], sc[2], t)
			(sc[0] as DotBotContact).view_yaw = intent.yaw
			(sc[0] as DotBotContact).view_pitch = intent.pitch
			if t > 0.8 and t < 1.3:
				worst = maxf(worst, rad_to_deg(intent.forward().angle_to(enemy.aim_point() - (sc[0] as DotBotContact).eye())))
			t += TICK
		trail[lag] = worst
	print("       error after a reversal: lag 0 %.2f deg, lag 0.15 %.2f deg" % [trail[0.0], trail[0.15]])
	_check(trail[0.15] > trail[0.0] + 1.0, "the view is late on a reversal with bot_track_lag", "%.2f vs %.2f" % [trail[0.15], trail[0.0]])


func _human_strafe() -> void:
	# Strafing: lengths vary more, and a change of direction eases through zero.
	var cv := {}
	var eased := {}
	for on in [false, true]:
		var sc := _scene(Vector3(0.0, 0.0, -10.0))
		var s := _human_settings(on, {"strafe": 1.0, "hesitate": 0.0, "stop_to_shoot": 0.0, "crouch": 0.0})
		var brain := DotBotBrain.new(5000, s)
		var lengths: Array[float] = []
		var run_sign := 0
		var run_start := 0.0
		var mid := 0
		var t := 0.0
		while t < 90.0:
			var intent := brain.think(sc[0], sc[2], t)
			(sc[0] as DotBotContact).view_yaw = intent.yaw
			(sc[0] as DotBotContact).view_pitch = intent.pitch
			if t > 2.0:
				# Once the standoff has gone stale the bot walks in at full forward and the diagonal is shortened to length 1; undo that to get the strafe back.
				var x := intent.move.x / intent.move.y if intent.move.y > 0.5 else intent.move.x
				if absf(x) > 0.1 and absf(x) < 0.9:
					mid += 1
				var sg := 0 if absf(x) < 0.3 else (1 if x > 0.0 else -1)
				if sg != run_sign:
					if run_sign != 0 or t - run_start > 0.0:
						lengths.append(t - run_start)
					run_sign = sg
					run_start = t
			t += TICK
		cv[on] = _stdev(lengths) / maxf(_mean(lengths), 0.001)
		eased[on] = mid
		print("       strafe %s: %d segments, length variation %.2f, %d eased ticks" % ["on" if on else "off", lengths.size(), cv[on], mid])
	_check(cv[true] > cv[false] * 1.25, "strafe segment lengths vary more with bot_strafe_jitter", "%.2f vs %.2f" % [cv[true], cv[false]])
	_check(eased[false] < 20 and eased[true] > 100, "strafe direction eases only with the setting", "%d vs %d" % [eased[false], eased[true]])


func _human_glance() -> void:
	# Glance: a roaming bot looks well off its heading, and holds it.
	var turned := {}
	for on in [false, true]:
		var sc := _scene(Vector3(0.0, 0.0, -10.0))
		(sc[1] as DotBotContact).alive = false
		(sc[2] as DotBotWorld).waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([Vector3(0.0, 0.0, -200.0)])
		var brain := DotBotBrain.new(6000, _human_settings(on))
		var widest := 0.0
		var held := 0
		for intent: DotBotIntent in _run_bot(brain, sc[0], sc[2], 30.0):
			widest = maxf(widest, absf(intent.yaw))
			if absf(intent.yaw) > 45.0:
				held += 1
		turned[on] = widest
		print("       glance %s: widest look %.1f deg, %d ticks past 45 deg" % ["on" if on else "off", widest, held])
	_check(turned[false] < 35.0, "a roaming bot only sways 25 degrees with bot_glance 0", "%.1f" % turned[false])
	_check(turned[true] > 50.0, "a roaming bot turns its head well aside with bot_glance on", "%.1f" % turned[true])


func _human_hesitate() -> void:
	# Hesitation: the time from sighting to the first step.
	var wait := {}
	for on in [false, true]:
		var delays: Array[float] = []
		for trial in range(20):
			var sc := _scene(Vector3(0.0, 0.0, -25.0))
			var brain := DotBotBrain.new(7000 + trial, _human_settings(on))
			var t := 0.0
			var started := -1.0
			while t < 2.0 and started < 0.0:
				var intent := brain.think(sc[0], sc[2], t)
				if intent.move.length() > 0.1:
					started = t
				t += TICK
			delays.append(started)
		wait[on] = _mean(delays)
		print("       hesitation %s: first step %.3f s after the sighting" % ["on" if on else "off", wait[on]])
	_check(wait[false] < 0.05, "it moves at once with bot_hesitate 0", "%.3f" % wait[false])
	_check(wait[true] > 0.05 and wait[true] <= 0.25, "it stands a moment first with bot_hesitate on", "%.3f" % wait[true])


func _human_hurt_delay() -> void:
	# Hurt delay: the turn toward a shooter.
	var lag_turn := {}
	for on in [false, true]:
		var delays: Array[float] = []
		for trial in range(20):
			var sc := _scene(Vector3(0.0, 0.0, -10.0))
			(sc[1] as DotBotContact).alive = false
			var brain := DotBotBrain.new(8000 + trial, _human_settings(on))
			brain.think(sc[0], sc[2], 0.0)
			brain.hurt(Vector3(0.0, 0.0, 8.0), 0.1)
			var t := 0.1
			var found := -1.0
			while t < 1.5 and found < 0.0:
				if brain.think(sc[0], sc[2], t).state == &"listen":
					found = t - 0.1
				t += TICK
			delays.append(found)
		lag_turn[on] = _mean(delays)
		print("       hurt delay %s: turns %.3f s after the hit" % ["on" if on else "off", lag_turn[on]])
	_check(lag_turn[false] < 0.03, "it turns at once with bot_hurt_delay 0", "%.3f" % lag_turn[false])
	_check(lag_turn[true] > 0.07 and lag_turn[true] < 0.35, "it turns after a beat with bot_hurt_delay on", "%.3f" % lag_turn[true])



func _test_utility_grenades() -> void:
	_section("utility grenades: a flashed bot is blind, smoke blocks sight")

	var s := DotBotSettings.new()
	s.set_difficulty("nightmare")

	var sc := _scene(Vector3(0, 0, -15))
	var brain := DotBotBrain.new(1, s)
	var seen := _run_bot(brain, sc[0], sc[2], 1.5)
	_check(seen.any(func(i: DotBotIntent) -> bool: return i.target_id == 2), "unflashed, the bot sees a target in the open")
	_check(seen.any(func(i: DotBotIntent) -> bool: return i.fire), "unflashed, it fires at it")

	sc = _scene(Vector3(0, 0, -15))
	brain = DotBotBrain.new(1, s)
	brain.blind_for(0.0, 2.0)
	_check(brain.is_blind(1.0) and not brain.is_blind(2.5), "blind_for lasts its seconds")
	var blind := _run_bot(brain, sc[0], sc[2], 1.9)
	_check(blind.all(func(i: DotBotIntent) -> bool: return not i.fire and i.target_id == -1), "a flashed bot neither targets nor fires during its blind time")
	var after := _run_bot(brain, sc[0], sc[2], 1.5, 2.0)
	_check(after.any(func(i: DotBotIntent) -> bool: return i.target_id == 2), "and sees the target again once it ends")

	sc = _scene(Vector3(0, 0, -15))
	brain = DotBotBrain.new(1, s)
	var pre := _run_bot(brain, sc[0], sc[2], 1.0)
	_check(pre.any(func(i: DotBotIntent) -> bool: return i.target_id == 2), "a flash lands on a bot already fighting")
	brain.blind_for(1.0, 1.0)
	var mid := _run_bot(brain, sc[0], sc[2], 0.9, 1.0)
	_check(mid.all(func(i: DotBotIntent) -> bool: return not i.fire and i.target_id == -1), "it drops the target and stops firing")

	sc = _scene(Vector3(0, 0, -15))
	var world: DotBotWorld = sc[2]
	brain = DotBotBrain.new(1, s)
	pre = _run_bot(brain, sc[0], world, 1.0)
	_check(pre.any(func(i: DotBotIntent) -> bool: return i.target_id == 2), "before the smoke the bot sees the target")
	var id := world.add_sight_blocker(Vector3(0, 1, -7), 3.0, 3.0)
	var smoked := _run_bot(brain, sc[0], world, 1.0, 1.0)
	_check(smoked.all(func(i: DotBotIntent) -> bool: return i.target_id == -1 and not i.fire), "a target behind smoke is not seen")
	_check(not world.line_of_sight(Vector3.ZERO, Vector3(0, 0, -15)) and world.line_of_sight(Vector3.ZERO, Vector3(15, 0, 0)), "only a segment through the cloud is blocked")
	world.remove_sight_blocker(id)
	_check(_run_bot(brain, sc[0], world, 1.5, 2.0).any(func(i: DotBotIntent) -> bool: return i.target_id == 2), "and is seen again when the smoke goes")
	var timed := world.add_sight_blocker(Vector3(0, 1, -7), 3.0, 2.5)
	var _t := _run_bot(brain, sc[0], world, 1.0, 2.0)
	_check(not world.sight_blockers.has(timed), "smoke ends by its own time")
	_done()


func _pickup_scene(drop_at: Vector3, drop_value: float, held: Dictionary, with_enemy: bool = false) -> Array:
	var sc := _scene(Vector3(0, 0, -15))
	var me: DotBotContact = sc[0]
	var world: DotBotWorld = sc[2]
	me.loadout = held
	if not with_enemy:
		world.contacts_fn = func() -> Array: return [me]
	var drop := {"id": 7, "position": drop_at, "slot": 1, "value": drop_value, "ammo": 1.0}
	world.drops_fn = func() -> Array: return [drop]
	return sc


func _pickup_settings(on: float = 1.0) -> DotBotSettings:
	var s := DotBotSettings.new()
	s.set_difficulty("nightmare")
	s.profile.pickup_weapons = on
	return s


func _test_pickup() -> void:
	_section("pickup: a quiet bot fetches a better weapon, never in a fight, never when off")

	var held := {1: {"value": 0.3, "ammo": 1.0}}
	var sc := _pickup_scene(Vector3(5, 0, 0), 0.8, held)
	var far := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 2.0)
	_check(far.any(func(i: DotBotIntent) -> bool: return i.state == &"pickup" and i.move.length() > 0.1), "a better weapon in view: the bot walks to it")
	_check(far.all(func(i: DotBotIntent) -> bool: return not i.use), "and does not press use from five metres")

	sc = _pickup_scene(Vector3(0.5, 0, 0), 0.8, held)
	var near := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 3.0)
	_check(near.any(func(i: DotBotIntent) -> bool: return i.use), "beside it, the bot presses use")
	_check(near.any(func(i: DotBotIntent) -> bool: return i.use and i.move.length() < 0.01), "standing still while it does")

	sc = _pickup_scene(Vector3(5, 0, 0), 0.8, {})
	var empty := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 2.0)
	_check(empty.any(func(i: DotBotIntent) -> bool: return i.state == &"pickup"), "an empty slot is worth a walk")

	sc = _pickup_scene(Vector3(5, 0, 0), 0.8, {1: {"value": 0.8, "ammo": 0.1}})
	var low := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 2.0)
	_check(low.any(func(i: DotBotIntent) -> bool: return i.state == &"pickup"), "low ammunition makes the same weapon worth a walk")

	sc = _pickup_scene(Vector3(0.5, 0, 0), 0.2, held)
	var worse := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 3.0)
	_check(worse.all(func(i: DotBotIntent) -> bool: return i.state != &"pickup" and not i.use), "a worse weapon is left lying")

	sc = _pickup_scene(Vector3(1.5, 0, 0), 0.8, held, true)
	var brawl := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 3.0)
	var fighting := brawl.filter(func(i: DotBotIntent) -> bool: return i.target_id == 2)
	_check(not fighting.is_empty() and fighting.all(func(i: DotBotIntent) -> bool: return i.state != &"pickup" and not i.use), "with an enemy in view it fights and does not fetch")

	sc = _pickup_scene(Vector3(0.5, 0, 0), 0.8, held)
	var off := _run_bot(DotBotBrain.new(1, _pickup_settings(0.0)), sc[0], sc[2], 3.0)
	_check(off.all(func(i: DotBotIntent) -> bool: return i.state != &"pickup" and not i.use), "bot_pickup_weapons 0: it never goes for one")

	sc = _pickup_scene(Vector3(60, 0, 0), 0.8, held)
	var distant := _run_bot(DotBotBrain.new(1, _pickup_settings()), sc[0], sc[2], 2.0)
	_check(distant.all(func(i: DotBotIntent) -> bool: return i.state != &"pickup"), "past pickup_range it is not noticed")

	sc = _pickup_scene(Vector3(0.5, 0, 0), 0.8, held)
	var gaveup := DotBotBrain.new(1, _pickup_settings())
	var tries := _run_bot(gaveup, sc[0], sc[2], 6.0)
	var presses := tries.filter(func(i: DotBotIntent) -> bool: return i.use)
	_check(presses.size() * TICK < 2.0 and tries.slice(-50).all(func(i: DotBotIntent) -> bool: return not i.use), "a weapon that stays put after a try is given up on, not pressed forever")
	_done()


class FakeTuning extends RefCounted:
	var damage := 20.0
	var pellets := 1.0


class FakeDef extends RefCounted:
	var tuning: Object = FakeTuning.new()
	var use_interval_ticks := 10
	var infinite_reserve := false
	var magazine := 10
	var slot := 2
	var ammo_type := &"bullet"

	func reserve_cap() -> int:
		return 30


class FakeHeld extends RefCounted:
	var def: Object = null
	var magazine := 5


class FakeAmmo extends RefCounted:
	func count(_t: StringName) -> int:
		return 15


class FakeCatalogue extends RefCounted:
	var defs := {}

	func get_def(id: StringName) -> Object:
		return defs.get(id)


class FakeArsenal extends RefCounted:
	var catalogue: Object = FakeCatalogue.new()
	var held := {}

	func slot_at(slot: int) -> Object:
		return held.get(slot)

	func ammo() -> Object:
		return FakeAmmo.new()


class FakeDrops extends RefCounted:
	var list: Array[Dictionary] = []

	func snapshot() -> Array[Dictionary]:
		return list


func _test_arms() -> void:
	_section("arms: weapon rating, loadout and drops from a duck-typed arsenal")
	var def := FakeDef.new()
	_check(is_equal_approx(DotBotArms.rate(def), 20.0 * 2.0 / DotBotArms.FULL_DPS), "rating is damage per second over the full-rating figure")
	var fast := FakeDef.new()
	fast.use_interval_ticks = 2
	_check(DotBotArms.rate(fast) > DotBotArms.rate(def), "a faster weapon rates higher")
	fast.tuning = null
	_check(DotBotArms.rate(fast) > 0.0 and DotBotArms.rate(null) == 0.0, "no tuning rates by the default damage; no definition rates 0")
	_check(is_equal_approx(DotBotArms.ammo_fraction(def, 5, 15), 0.5), "ammunition is a fraction of magazine plus reserve cap")
	def.infinite_reserve = true
	_check(DotBotArms.ammo_fraction(def, 0, 0) == 1.0, "infinite reserve is always full")
	def.infinite_reserve = false

	var arsenal := FakeArsenal.new()
	var h := FakeHeld.new()
	h.def = def
	arsenal.held[2] = h
	var load := DotBotArms.loadout_of(arsenal)
	_check(load.size() == 1 and load.has(2) and is_equal_approx(float(load[2]["ammo"]), 0.5), "loadout holds one entry per carried slot with its ammunition")
	_check(DotBotArms.loadout_of(null).is_empty(), "no arsenal, empty loadout")
	var rated := DotBotArms.loadout_of(arsenal, func(_d: Object) -> float: return 0.77)
	_check(is_equal_approx(float(rated[2]["value"]), 0.77), "a game's own rater replaces the default")

	arsenal.catalogue.defs[&"smg"] = def
	var drops := FakeDrops.new()
	drops.list.append({"id": 4, "state": {"id": "smg", "magazine": 10, "reserve": 30}, "at": Transform3D(Basis.IDENTITY, Vector3(1, 2, 3))})
	drops.list.append({"id": 5, "state": {"id": "unknown"}, "at": Transform3D.IDENTITY})
	var lying := DotBotArms.drops_of(drops, arsenal)
	_check(lying.size() == 1 and lying[0]["position"] == Vector3(1, 2, 3) and lying[0]["slot"] == 2 and is_equal_approx(float(lying[0]["ammo"]), 1.0), "a drop becomes {id, position, slot, value, ammo}; an unknown weapon is skipped")
	_check(DotBotArms.drops_of(null, arsenal).is_empty() and DotBotArms.drops_of(drops, null).is_empty(), "no drop set or no arsenal, nothing lying")
	var world := DotBotWorld.new()
	DotBotArms.wire(world, func() -> Object: return drops, func() -> Object: return arsenal)
	_check(world.drops().size() == 1, "wire sets the world's drops_fn")
	_done()
