extends "res://examples/selftest/harness.gd"
## The surf sections of the bot suite.


## A body shaped like dot-player-controller's state, with a toy motor (a point accelerating along the wish), so the planner and pilot are tested without that addon; the real motor is in the games' suites.
class ToyState:
	extends RefCounted
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO
	func duplicate_state() -> ToyState:
		var s := ToyState.new()
		s.position = position
		s.velocity = velocity
		return s
	func is_grounded() -> bool:
		return false


class ToyCommand:
	extends RefCounted
	var yaw := 0.0
	var move := Vector2.ZERO
	var jump := false


class ToySim:
	extends RefCounted
	var delta := 1.0 / 64.0
	var course: DotBotSurfCourse = null
	var steps := 0
	func command(yaw: float, move: Vector2, jump: bool) -> ToyCommand:
		var c := ToyCommand.new()
		c.yaw = yaw
		c.move = move
		c.jump = jump
		return c
	func step(s: ToyState, c: ToyCommand) -> int:
		steps += 1
		var y := deg_to_rad(c.yaw)
		var wish := Vector3(cos(y), 0.0, -sin(y)) * c.move.x + Vector3(-sin(y), 0.0, -cos(y)) * c.move.y
		s.velocity = (s.velocity + wish * 6.0 * delta).limit_length(6.0)
		s.position += s.velocity * delta
		return course.event_at(s) if course != null else 0


## A corridor along -z that turns right at its end: straight on is a pit, the goal is round the
## corner.
func _toy_course() -> DotBotSurfCourse:
	var course := DotBotSurfCourse.new()
	course.start = Vector3.ZERO
	course.goals.append(AABB(Vector3(4.0, -1.0, -24.0), Vector3(6.0, 2.0, 6.0)))
	course.pits.append(AABB(Vector3(-50.0, -1.0, -50.0), Vector3(48.0, 2.0, 100.0)))  # x < -2
	course.pits.append(AABB(Vector3(12.0, -1.0, -50.0), Vector3(40.0, 2.0, 100.0)))   # x > 12
	course.pits.append(AABB(Vector3(-2.0, -1.0, -50.0), Vector3(14.0, 2.0, 26.0)))    # z < -24
	course.pits.append(AABB(Vector3(2.0, -1.0, -12.0), Vector3(10.0, 2.0, 12.0)))     # the wall beside the corridor
	course.floor_y = -5.0
	return course.settle()


func _toy_starts(count: int, seed_value: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in range(count):
		var s := ToyState.new()
		s.position = Vector3(rng.randf_range(-0.8, 0.8), 0.0, rng.randf_range(-0.5, 0.5))
		var a := rng.randf_range(-0.6, 0.6)
		s.velocity = Vector3(sin(a), 0.0, -cos(a)) * rng.randf_range(0.0, 3.0)
		out.append(s)
	return out


func _test_surf() -> void:
	_section("surfing: a ride searched on a simulator, a cache from it, a pilot riding it")
	var course := _toy_course()
	var sim := ToySim.new()
	sim.course = course
	var planner := DotBotSurfPlanner.new()
	planner.seconds = 12.0
	var start: ToyState = _toy_starts(1, 1)[0]
	var found := planner.search(start, course, sim)
	_check(bool(found["found"]), "the beam finds a way round the corner", str(found["why"]))
	var ride := DotBotSurfPlanner.trajectory(start, found.get("actions", PackedByteArray()), planner.hold, course, sim)
	_check(int(ride["event"]) == DotBotSurfCourse.EVENT_GOAL and int(ride["ticks"]) == int(found["ticks"]),
		"and its actions replayed arrive on the same tick (the simulator is deterministic)", "%d and %d ticks" % [ride["ticks"], found["ticks"]])

	var lines: Array[String] = []
	var built := planner.build(_toy_starts(4, 2), _toy_starts(16, 3), 3, course, sim, sim,
		func(line: String) -> void: lines.append(line))
	_check(int(built["found"]) >= 3 and (built["lengths"] as PackedInt32Array).size() == int(built["found"]),
		"a cache is built from several starts and repair rounds", "%d rides, failures per round %s" % [built["found"], str(built["rounds"])])

	# Saved and read back as a game's file keeps it, in units of 2 cm.
	var rows := DotBotSurfPilot.entries_to_rows(built["rides"], 0.02)
	var pilot := DotBotSurfPilot.new()
	pilot.load_stage({"entries": rows, "lengths": Array(built["lengths"]), "reference_yaw": course.reference_yaw()}, 0.02)
	_check(pilot.size() == (built["rides"] as PackedFloat32Array).size() / DotBotSurfPilot.STRIDE,
		"the cache reads back from its rows", "%d entries" % pilot.size())
	pilot.sim = sim
	pilot.score = course.score

	_surf_lookup(pilot)
	_surf_far(pilot)
	var tries := _toy_starts(20, 4)
	_surf_ride_modes(pilot, sim, tries)
	_surf_forecast(pilot, sim, tries)

	# Riding while aiming elsewhere: the keys are turned for the view, and the wish is the same.
	var heading_view := DotBotSurfPilot.move_toward(30.0, 30.0)
	var turned := DotBotSurfPilot.move_toward(30.0, 120.0)
	var wish_a := _wish(30.0, heading_view)
	var wish_b := _wish(120.0, turned)
	_check(heading_view.is_equal_approx(Vector2(0.0, 1.0)) and wish_a.is_equal_approx(wish_b),
		"a wish is held from any view (the keys turn, the direction does not)", "%s and %s" % [str(wish_a), str(wish_b)])
	_done()

func _surf_lookup(pilot: DotBotSurfPilot) -> void:
	# The lookup skips a neighbour cell no entry of which can be nearer than the best so far.
	# Armed by skipping on `>= 0.0` (every neighbour is skipped and some answers move).
	var agree := 0
	var asked := 0
	for s: ToyState in _toy_starts(40, 5):
		for t in range(0, 200, 25):
			var probe := s.duplicate_state()
			probe.position += Vector3(0.37 * float(t % 7) - 1.1, 0.0, 0.29 * float(t % 5) - 0.6)
			asked += 1
			var best := -1
			var best_d := INF
			for i in range(pilot.size()):
				var d := pilot._distance(i, probe.position, probe.velocity)
				if d < best_d:
					best_d = d
					best = i
			var got := pilot.nearest(probe)
			if got == best or is_equal_approx(pilot._distance(got, probe.position, probe.velocity), best_d):
				agree += 1
	_check(agree == asked, "the cache's lookup finds the entry a scan of every entry finds", "%d of %d" % [agree, asked])


func _surf_far(pilot: DotBotSurfPilot) -> void:
	# A state off every ride (a veto's candidate gone wrong) reads the coarse grid: the nearest
	# entry too, ring by ring. Much further out it reads a sparse sample: an entry near the
	# nearest (within 20 m, here), which is all a falling state's action needs.
	var far_ok := 0
	var far_asked := 0
	for offset: Vector3 in [Vector3(14.0, 9.0, -11.0), Vector3(40.0, 25.0, -30.0)]:
		for s: ToyState in _toy_starts(10, 6):
			var probe := s.duplicate_state()
			probe.position += offset
			if pilot._near.has(pilot._cell(probe.position)):
				continue
			far_asked += 1
			var best_d := INF
			for i in range(pilot.size()):
				best_d = minf(best_d, pilot._distance(i, probe.position, probe.velocity))
			var got := pilot.nearest(probe)
			var slack := 0.0 if offset.length() < 20.0 else 20.0
			if got >= 0 and sqrt(pilot._distance(got, probe.position, probe.velocity)) <= sqrt(best_d) + slack + 0.001:
				far_ok += 1
	_check(far_ok == far_asked, "a state off every ride finds the nearest entry from the coarse grid, a near one from the sparse sample", "%d of %d" % [far_ok, far_asked])
	_check(far_asked >= 5, "and enough of the probes were far", "%d" % far_asked)


func _surf_ride_modes(pilot: DotBotSurfPilot, sim: ToySim, tries: Array) -> void:
	var arrived := [0, 0]
	var cost := [0, 0]
	var ridden := [0, 0]
	for mode in [0, 1]:
		pilot.rolling = mode == 1
		pilot.lookahead_ticks = 0
		for s: ToyState in tries:
			var r := pilot.ride(s, sim, 64 * 12)
			arrived[mode] += 1 if int(r["event"]) == DotBotSurfCourse.EVENT_GOAL else 0
			ridden[mode] += int(r["ticks"])
		cost[mode] = pilot.lookahead_ticks
	var plain_cost := float(cost[0]) / maxf(1.0, ridden[0])
	var rolling_cost := float(cost[1]) / maxf(1.0, ridden[1])
	_check(arrived[0] >= 16 and arrived[1] >= 16, "the pilot arrives from most perturbed starts, either veto",
		"%d and %d of 20" % [arrived[0], arrived[1]])
	_check(pilot.resyncs == 0, "on an exact simulator a kept forecast never stops matching", "%d resyncs" % pilot.resyncs)
	_check(rolling_cost < plain_cost * 0.5, "and keeping the forecast costs under half the lookahead of running it afresh",
		"%.2f against %.2f simulated ticks a ridden tick; %s" % [rolling_cost, plain_cost, str(pilot.describe())])


func _surf_forecast(pilot: DotBotSurfPilot, sim: ToySim, tries: Array) -> void:
	# A forecast spread over ticks ends where, and with the verdict, an all-at-once one does.
	var same := 0
	var steps_ok := true
	pilot.sim = sim
	pilot.rolling = true
	for s: ToyState in tries:
		pilot.forecast_budget = 0
		pilot._forecast(s, -1, 0)
		var whole_event: int = pilot._end_event
		var whole_n: int = pilot._pred_p.size()
		var whole_end: Vector3 = pilot._end.position
		pilot.forecast_budget = 7
		pilot._forecast(s, -1, 0)
		var calls := 1
		while pilot._fc_pending:
			pilot._run_forecast()
			calls += 1
		same += 1 if pilot._end_event == whole_event and pilot._pred_p.size() == whole_n and pilot._end.position.is_equal_approx(whole_end) else 0
		steps_ok = steps_ok and calls == ceili(float(whole_n) / 7.0)
	var veto_same := 0
	for s: ToyState in tries:
		pilot.veto_budget = 5
		pilot._override = -2
		pilot._override_left = 0
		var ahead: ToyState = s.duplicate_state()
		pilot._advance_for_latency(ahead)
		pilot.veto_budget = 0
		pilot._hopeless_streak = 0
		pilot._veto(ahead)
		var whole_action: int = pilot._override
		var whole_wait: int = pilot._cooldown
		pilot.veto_budget = 5
		pilot._hopeless_streak = 0
		pilot._override = -2
		pilot._override_left = 0
		pilot._veto(s)
		var veto_calls := 1
		while pilot._vt_pending:
			pilot._veto_run()
			veto_calls += 1
		veto_same += 1 if pilot._override == whole_action and pilot._cooldown == whole_wait and veto_calls > 1 else 0
	pilot.veto_budget = 0
	pilot.forecast_budget = 24
	pilot._drop_forecast()
	_check(same == tries.size(), "a forecast spread over ticks ends where an all-at-once one does, with the same event", "%d of %d" % [same, tries.size()])
	_check(steps_ok, "and takes no more steps a tick than its budget")
	_check(veto_same == tries.size(), "and a veto spread over ticks picks the action and the wait an all-at-once one from the state it is late by does", "%d of %d" % [veto_same, tries.size()])


static func _wish(view_yaw: float, move: Vector2) -> Vector3:
	var y := deg_to_rad(view_yaw)
	return Vector3(cos(y), 0.0, -sin(y)) * move.x + Vector3(-sin(y), 0.0, -cos(y)) * move.y


## A route over a ride edge: the mesh holds two floors with a gap no walk crosses, a ride edge
## joins them, the route goes over it and says where, and the brain says when it gets there.
func _test_ride_edges() -> void:
	_section("riding: a ride edge joins two islands, a route crosses it, the brain hands it over")
	var root := Node3D.new()
	add_child(root)
	var still := StaticBody3D.new()
	root.add_child(still)
	for centre: Vector3 in [Vector3(0.0, -0.1, 0.0), Vector3(20.0, -0.1, 0.0)]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(10.0, 0.2, 10.0)
		shape.shape = box
		shape.position = centre
		still.add_child(shape)
	await get_tree().physics_frame
	var nav := DotBotNav.new()
	var baked := nav.bake(root, {"radius": 0.35, "height": 1.0, "climb": 0.4}, 0, [still])
	var islands := nav.islands()
	_check(baked.ok and islands.size() == 2 and nav.island_at(Vector3(0.0, 0.0, 0.0)) != nav.island_at(Vector3(20.0, 0.0, 0.0)),
		"two floors with a gap are two islands", "%d islands, at %d and %d, %s" % [islands.size(), nav.island_at(Vector3(0.0, 0.0, 0.0)), nav.island_at(Vector3(20.0, 0.0, 0.0)), str(islands.map(func(i: Dictionary) -> String: return str(i["bounds"])))])
	var far := nav.island_at(Vector3(20.0, 0.0, 0.0))
	_check(nav.on_island(far, Vector3(21.0, 0.1, 1.0)) and not nav.on_island(far, Vector3(1.0, 0.1, 1.0))
		and not nav.on_island(far, Vector3(21.0, 3.0, 1.0)), "a point is on the far island only over it and near its floor")
	var walked := nav.route(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0))
	var walked_points: PackedVector3Array = walked["points"]
	_check(walked_points.is_empty() or walked_points[walked_points.size() - 1].x < 6.0,
		"with no ride edge a route cannot reach the far floor", "%d points" % walked_points.size())
	_check(nav.joined(Vector3(-2.0, 0.0, 0.0), Vector3(1.0, 0.0, 1.0)) and not nav.joined(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0)),
		"joined: the same floor yes, the far floor no, with no path query")
	nav.add_ride(Vector3(4.0, 0.0, 0.0), Vector3(16.0, 0.0, 0.0), 7)
	var way := nav.route(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0))
	_check(nav.joined(Vector3(-2.0, 0.0, 0.0), Vector3(22.0, 0.0, 0.0)) and not nav.joined(Vector3(22.0, 0.0, 0.0), Vector3(-2.0, 0.0, 0.0)),
		"joined: a ride edge joins the far floor one way only")
	var points: PackedVector3Array = way["points"]
	var rides: PackedInt32Array = way["rides"]
	var at := rides.find(7)
	_check(points.size() >= 3 and points[points.size() - 1].distance_to(Vector3(22.0, 0.0, 0.0)) < 0.6
		and at >= 0 and at + 1 < points.size() and points[at].distance_to(Vector3(4.0, 0.0, 0.0)) < 0.6
		and points[at + 1].distance_to(Vector3(16.0, 0.0, 0.0)) < 0.6,
		"with one the route reaches it and marks where the ride starts and ends", "%s %s" % [str(points), str(rides)])

	# The brain walks the route and says when it is at the ride's start.
	var world := DotBotWorld.new()
	world.waypoints_fn = func() -> PackedVector3Array: return PackedVector3Array([Vector3(22.0, 0.0, 0.0)])
	world.route_detail_fn = nav.route
	var me := DotBotContact.make(1, Vector3(-2.0, 0.0, 0.0))
	world.contacts_fn = func() -> Array: return [me]
	var brain := DotBotBrain.new(5)
	var said := -1
	var where := Vector3.ZERO
	var t := 0.0
	while t < 4.0 and said < 0:
		var intent := brain.think(me, world, t)
		if intent.ride >= 0:
			said = intent.ride
			where = me.position
		me.view_yaw = intent.yaw
		var y := deg_to_rad(intent.yaw)
		me.position += (Vector3(cos(y), 0.0, -sin(y)) * intent.move.x + Vector3(-sin(y), 0.0, -cos(y)) * intent.move.y) * 4.0 * TICK
		t += TICK
	_check(said == 7 and where.distance_to(Vector3(4.0, 0.0, 0.0)) < 1.2, "the brain says ride 7 at its start",
		"ride %d at %s" % [said, str(where)])

	var landed := _ride_steer_checks()
	brain.ride_ended(true)
	me.position = landed
	var after := brain.think(me, world, t)
	_check(after.ride == -1 and brain._route.size() >= 1 and brain._route[brain._route.size() - 1].x > 15.0,
		"and after it the brain asks for its route again, from the far floor", "%d corners" % brain._route.size())
	nav.clear()
	root.queue_free()
	_done()


func _ride_steer_checks() -> Vector3:
	# A ride: the pilot's legs into the brain's intent, the view left alone, and the landing told.
	var course := DotBotSurfCourse.new()
	course.start = Vector3(4.0, 0.0, 0.0)
	course.goals.append(AABB(Vector3(15.0, -1.0, -5.0), Vector3(10.0, 2.0, 10.0)))
	course.floor_y = -5.0
	var _settled := course.settle()
	var sim := ToySim.new()
	var cache := DotBotSurfPilot.new()
	cache.load_entries(PackedFloat32Array([4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 4.0]), PackedInt32Array([1]), course.reference_yaw())
	var ride := DotBotSurfRide.new().begin(cache, course, null, 0)
	var s := ToyState.new()
	s.position = Vector3(4.0, 0.0, 0.0)
	var status := DotBotSurfRide.RIDING
	var tick := 0
	var view_kept := true
	while status == DotBotSurfRide.RIDING and tick < 64 * 10:
		var intent := DotBotIntent.new()
		intent.yaw = 180.0  # looking back the way it came, at somebody
		status = ride.steer(s, intent, tick)
		if status != DotBotSurfRide.RIDING:
			break
		view_kept = view_kept and intent.yaw == 180.0
		var _e := sim.step(s, sim.command(intent.yaw, intent.move, intent.jump))
		tick += 1
	_check(status == DotBotSurfRide.LANDED and view_kept, "a ride steers to the far floor while looking the other way",
		"status %d after %d ticks at %s" % [status, tick, str(s.position)])
	var stalled := DotBotSurfRide.new().begin(cache, course, null, 0)
	var pinned := ToyState.new()
	pinned.position = Vector3(4.0, 0.0, 0.0)
	var pin_status := DotBotSurfRide.RIDING
	var pin_tick := 0
	while pin_status == DotBotSurfRide.RIDING and pin_tick < 64 * 10:
		pin_status = stalled.steer(pinned, DotBotIntent.new(), pin_tick)
		pin_tick += 1
	_check(pin_status == DotBotSurfRide.TIMED_OUT and pin_tick < 64 * 12, "a ride that goes nowhere for 8 s ends instead of running its 30",
		"status %d after %d ticks" % [pin_status, pin_tick])
	return s.position
