extends "res://examples/selftest/surf_tests.gd"
## The recorded-episode and ride-harvest sections of the bot suite.


func _demo_episode(map_id: String, version: String, kind: String, key: String, score: float = 0.0, verified: bool = false) -> DotBotDemoEpisode:
	var e := DotBotDemoEpisode.new()
	e.map_id = map_id
	e.map_version = version
	e.schema_id = "abc123"
	e.kind = kind
	e.key = key
	e.start = {"pos": [1.5, 2.0, -3.0], "air": true}
	e.rate = 16.0
	e.frame_size = 3
	e.ticks = PackedFloat32Array([0.5, -1.25, 100.0, 0.75, 2.0, -8.5])
	e.outcome = "landed"
	e.day = "2026-10-21"
	e.verified = verified
	e.score = score
	return e


# The simulator and host are toys (a point accelerating along x): dot-player-controller is not linked here, so the harvest runs through its duck-typed interface.

class RideToyState:
	extends RefCounted
	var position := Vector3.ZERO
	var velocity := Vector3.ZERO

	func duplicate_state() -> RideToyState:
		var c := RideToyState.new()
		c.position = position
		c.velocity = velocity
		return c


class RideToySim:
	extends RefCounted
	var delta := 1.0 / 64.0

	func step(state: RideToyState, thrust: float) -> int:
		state.velocity.x += thrust * delta
		state.position.x += state.velocity.x * delta
		return 0


## The platform is x from 10 to 12; past it is a miss.
class RideToyBase:
	extends RefCounted

	func replay_start(ep: DotBotDemoEpisode) -> RideToyState:
		var s := RideToyState.new()
		s.position.x = float(ep.start.get("x", 0.0))
		return s

	func replay_command(_sim: Variant, action: PackedFloat32Array, _state: Variant) -> float:
		return action[0] if action.size() > 0 else 0.0

	func landing(state: RideToyState, _event: int, _ep: DotBotDemoEpisode) -> int:
		if state.position.x > 12.0 or (state.position.x >= 10.0 and state.velocity.x > 30.0):
			return DotBotRideHarvest.FAILED
		return DotBotRideHarvest.LANDED if state.position.x >= 10.0 else DotBotRideHarvest.GOING


class RideToyHost:
	extends RideToyBase

	func perturb(state: RideToyState, rng: DotRandomStream, metres: float, _speed: float) -> RideToyState:
		var c := state.duplicate_state()
		c.position.x -= metres * rng.next_unit()
		return c


class RideToyHostNoPerturb:
	extends RideToyBase


class RideNoLanding:
	extends RefCounted


func _ride_schema() -> DotBotDemoSchema:
	return DotBotDemoSchema.make("ride", 1).add_observation("pos", 3).add_action("thrust", 1)


## An episode of [param samples] samples at 16 Hz, each holding [param thrust] for four ticks.
func _ride_episode(key: String, thrust: float, samples: int = 16, start_x: float = 0.0) -> DotBotDemoEpisode:
	var e := _demo_episode("surf_toy", "v1", "ride", key)
	e.start = {"x": start_x}
	e.rate = 16.0
	e.frame_size = 4
	e.ticks = PackedFloat32Array()
	for i in samples:
		e.ticks.append_array(PackedFloat32Array([0.0, 0.0, 0.0, thrust]))
	return e


func _ride_harvest(cfg: DotBotRideConfig = null, host: Variant = null) -> DotBotRideHarvest:
	return DotBotRideHarvest.new(cfg if cfg != null else DotBotRideConfig.new(), _ride_schema(), RideToySim.new(), host if host != null else RideToyHost.new())


func _test_harvest_verify() -> void:
	_section("ride harvest: replay keeps a ride that lands and rejects one that does not")
	var cfg := DotBotRideConfig.new()
	cfg.settle_ticks = 0
	cfg.perturb_metres = 0.3
	var h := _ride_harvest(cfg)
	_check(h.ready().ok and not _ride_harvest(null, RideNoLanding.new()).ready().ok, "a host without the interface is refused")
	var good := _ride_episode("1>2", 20.0)
	var bad := _ride_episode("1>2", 5.0)
	var over := _ride_episode("1>2", 80.0)
	var v := h.verify([good, bad, over])
	_check(v.size() == 3 and v[0]["ok"] and not v[1]["ok"] and not v[2]["ok"], "the good ride is kept, the short and the overshooting rides are rejected")
	var score := float(v[0]["score"])
	_check(score > 0.0 and score < 1.0 and int(v[0]["starts"]) == cfg.starts, "its score is the share of perturbed starts that land", "%.2f" % score)
	var again := _ride_harvest(cfg).verify([good])
	_check(is_equal_approx(float(again[0]["score"]), score), "the same seed gives the same score")
	var settled := DotBotRideConfig.new()
	var long_run := _ride_harvest(settled).verify([_ride_episode("1>2", 20.0, 16, -4.0)])
	_check(long_run[0]["ok"], "ticks past the recording are allowed to settle")
	var plain := _ride_harvest(null, RideToyHost.new())
	plain.host = RideToyHostNoPerturb.new()
	_check(is_equal_approx(float(plain.verify([_ride_episode("1>2", 20.0)])[0]["score"]), 1.0), "without a perturbation a kept ride scores 1")
	var strict := DotBotRideConfig.new()
	strict.min_score = 1.0
	strict.settle_ticks = 0
	strict.perturb_metres = 6.0
	_check(not _ride_harvest(strict).verify([_ride_episode("1>2", 20.0)])[0]["ok"], "a ride under min_score is rejected")
	var job := h.make_job([_ride_episode("1>2", 20.0), _ride_episode("1>2", 5.0)])
	var steps := 0
	while job.step():
		steps += 1
	_check(job.result != null and job.result.ok and job.verdicts.size() == 2 and job.state == DotJob.State.DONE, "a job reaches its verdicts", str(steps))
	_check(h.describe_lines().size() == 1 and h.describe().has("replays") and not DotBotRideConfig.new().apply_dictionary({"starts": 9, "top": 2}, "file", true).is_empty(), "describes itself and takes config from a dictionary")
	_check(DotBotRideConfig.new().validate().ok, "the defaults are valid")
	var broken := DotBotRideConfig.new()
	broken.top = 0
	_check(not broken.validate().ok, "a top of 0 is refused")
	_done()


func _test_harvest_store() -> void:
	_section("ride harvest: verdicts reach the store, the worst ride is replaced at the cap")
	var store := DotBotDemoStoreMemory.new()
	var cfg := DotBotRideConfig.new()
	cfg.cap = 3
	var h := _ride_harvest(cfg)
	h.host = RideToyHostNoPerturb.new()
	var seeds := [_ride_episode("1>2", 20.0), _ride_episode("1>2", 2.0), _ride_episode("1>2", 22.0)]
	var _a := await store.append(seeds)
	var res: DotResult = await h.harvest(store, "surf_toy", "v1", "ride", "1>2")
	var counts: DotResult = await store.counts("surf_toy", "v1", "ride")
	_check(res.ok and res.value == 2 and counts.value["1>2"] == 2 and store.episodes.size() == 2, "the bad ride is removed and the good ones marked verified", str(store.episodes.size()))
	# Two more good ones: one fits, the next finds the edge at its cap.
	for e: DotBotDemoEpisode in store.episodes:
		e.score = 0.5
	var more := [_ride_episode("1>2", 21.0)]
	var _b := await store.append(more)
	var res2: DotResult = await h.harvest(store, "surf_toy", "v1", "ride", "1>2")
	_check(res2.ok and res2.value == 3 and store.episodes.size() == 3 and h.replaced == 0, "up to the cap nothing is replaced")
	var _c := await store.append([_ride_episode("1>2", 23.0)])
	var res3: DotResult = await h.harvest(store, "surf_toy", "v1", "ride", "1>2")
	var scores: Array = store.episodes.map(func(e: DotBotDemoEpisode) -> float: return e.score)
	scores.sort()
	_check(res3.ok and store.episodes.size() == 3 and h.replaced == 1 and scores == [0.5, 1.0, 1.0], "past the cap a better ride replaces the worst-scored one", str(scores))
	var _d := await store.append([_ride_episode("1>2", 24.0)])
	var res4: DotResult = await h.harvest(store, "surf_toy", "v1", "ride", "1>2")
	_check(res4.ok and store.episodes.size() == 3 and h.turned_away == 0 and h.replaced == 2, "and again, while the worst is below the newcomer")
	var _e := await store.append([_ride_episode("1>2", 25.0)])
	var res5: DotResult = await h.harvest(store, "surf_toy", "v1", "ride", "1>2")
	_check(res5.ok and store.episodes.size() == 3 and h.turned_away == 1, "a newcomer no better than the worst is turned away")
	var keep := DotBotRideConfig.new()
	keep.keep_rejected = true
	var kept_store := DotBotDemoStoreMemory.new()
	var _f := await kept_store.append([_ride_episode("1>2", 2.0)])
	var _g: DotResult = await _ride_harvest(keep).harvest(kept_store, "surf_toy", "v1", "ride", "1>2")
	_check(kept_store.episodes.size() == 1 and kept_store.episodes[0].score == DotBotRideHarvest.REJECTED_SCORE and not kept_store.episodes[0].verified
		and DotBotRideHarvest.unchecked(kept_store.episodes).is_empty(), "keep_rejected marks a rejected ride and it is not replayed again")
	var dir := "user://dot_bot_ride_%d" % randi()
	var json := DotBotDemoStoreJson.new(dir)
	var _o := await json.open()
	var _p := await json.append([_ride_episode("1>2", 20.0), _ride_episode("1>2", 2.0)])
	var res6: DotResult = await _ride_harvest(null, RideToyHostNoPerturb.new()).harvest(json, "surf_toy", "v1", "ride", "1>2")
	var back: DotResult = await DotBotDemoStoreJson.new(dir).load("surf_toy", "v1", "ride", "1>2", 0)
	_check(res6.ok and back.ok and back.value.size() == 1 and back.value[0].verified, "the JSON store takes the verdicts and the removal")
	_done()


func _book(cfg: DotBotRideConfig = null) -> DotBotRideBook:
	var b := DotBotRideBook.new(cfg)
	var _c := b.set_map("surf_toy", "v1")
	return b


func _test_ride_book() -> void:
	_section("ride book: ranking by measured success, recorded above seeded once there are enough")
	var cfg := DotBotRideConfig.new()
	cfg.target = 3
	var b := _book(cfg)
	b.add_seeded("1>2", 0.9, "s1")
	b.add_seeded("1>2", 0.4, "s2")
	b._add("1>2", {"id": 1, "source": DotBotRideBook.RECORDED, "score": 0.6, "data": null})
	var r := b.ranked("1>2")
	_check(r.map(func(x: Dictionary) -> float: return x["score"]) == [0.9, 0.6, 0.4], "under the target, rides rank by score", str(r.size()))
	_check(is_equal_approx(b.success("1>2"), 0.9) and b.success("nowhere") == 0.0, "an edge's success is its best ride's")
	b.add_seeded("2>3", 0.5, "s")
	b._add("2>3", {"id": 2, "source": DotBotRideBook.RECORDED, "score": 0.5, "data": null})
	_check(b.ranked("2>3")[0]["source"] == DotBotRideBook.RECORDED, "a recording wins a tie")
	for i in 2:
		b._add("1>2", {"id": 10 + i, "source": DotBotRideBook.RECORDED, "score": 0.3, "data": null})
	var r2 := b.ranked("1>2")
	_check(b.recorded_count("1>2") == 3 and r2[0]["source"] == DotBotRideBook.RECORDED and r2[2]["source"] == DotBotRideBook.RECORDED and r2[3]["source"] == DotBotRideBook.SEEDED,
		"at the target every recording ranks above every seed", str(r2.map(func(x: Dictionary) -> String: return x["source"])))
	_check(is_equal_approx(b.success("1>2"), 0.9), "but the edge's success still counts the seed")
	_check(b.describe_lines().size() == 3 and b.describe()["edges"].has("1>2"), "the book describes itself")
	_done()


func _test_ride_book_store() -> void:
	_section("ride book: loads verified recordings, forgets them on a new map version")
	var store := DotBotDemoStoreMemory.new()
	var mk := func(version: String, score: float, ok: bool) -> DotBotDemoEpisode:
		var e := _ride_episode("1>2", 20.0, 2)
		e.map_version = version
		e.score = score
		e.verified = ok
		return e
	var _a := await store.append([mk.call("v1", 0.8, true), mk.call("v1", 0.9, false), mk.call("v2", 0.7, true)])
	var b := _book()
	b.add_seeded("1>2", 0.5, "s")
	var n: DotResult = await b.load_edge(store, "ride", "1>2", _ride_schema(), 64.0)
	var ranked := b.ranked("1>2")
	_check(n.ok and n.value == 1 and ranked.size() == 2, "only verified recordings of this map version are loaded, seeds kept", "%s" % [n.value])
	var data: Dictionary = ranked[0]["data"]
	_check(data["hold"] == 4 and data["action_size"] == 1 and (data["actions"] as PackedFloat32Array).size() == 2, "a recording keeps its actions and its hold in ticks")
	_check(not b.set_map("surf_toy", "v1") and b.ranked("1>2").size() == 2, "the same version keeps its rides")
	_check(b.set_map("surf_toy", "v2") and b.ranked("1>2").is_empty() and b.invalidated == 1, "a new map version drops every ride")
	var n2: DotResult = await b.load_edge(store, "ride", "1>2", _ride_schema(), 64.0)
	_check(n2.value == 1 and is_equal_approx(b.success("1>2"), 0.7), "and the new version loads its own")
	var dropped: DotResult = await store.prune("surf_toy", "v2")
	var gone: DotResult = await store.remove([store.episodes[0].id])
	_check(dropped.value == 2 and gone.value == 1 and store.episodes.is_empty(), "the store prunes old versions and removes by id")
	_done()


func _test_ride_pick() -> void:
	_section("ride choice: seeded, weighted, and recordings played back")
	var cfg := DotBotRideConfig.new()
	cfg.target = 2
	cfg.top = 2
	var b := _book(cfg)
	b.add_seeded("1>2", 1.0, "seed")
	for i in 3:
		b._add("1>2", {"id": i + 1, "source": DotBotRideBook.RECORDED, "score": [0.9, 0.5, 0.1][i],
			"data": {"actions": PackedFloat32Array([1.0, 0.0, 1.0]), "action_size": 1, "hold": 2}})
	var counts := {}
	var rng := DotRandomStream.new(5)
	for i in 400:
		var e := DotBotSurfRide.pick(b, "1>2", rng)
		counts[e["id"]] = int(counts.get(e["id"], 0)) + 1
	_check(counts.has(1) and counts.has(2) and not counts.has(3) and not counts.has(0), "a recording is chosen over the seed once there are enough, among the top two only", str(counts))
	_check(int(counts[1]) > int(counts[2]), "the likelier ride is the better one", str(counts))
	var a := DotRandomStream.new(9)
	var c := DotRandomStream.new(9)
	var same := true
	for i in 30:
		same = same and DotBotSurfRide.pick(b, "1>2", a)["id"] == DotBotSurfRide.pick(b, "1>2", c)["id"]
	_check(same and DotBotSurfRide.pick(b, "nowhere", a).is_empty(), "the same seed picks the same rides, and an unknown edge gives none")
	var course := DotBotSurfCourse.new()
	course.goals.append(AABB(Vector3(10.0, -1.0, -5.0), Vector3(2.0, 2.0, 10.0)))
	course.floor_y = -5.0
	var _s := course.settle()
	var seen := PackedInt32Array()
	var decode := func(row: PackedFloat32Array, _state: Variant, intent: DotBotIntent) -> void:
		intent.jump = row[0] > 0.5
	var ride := DotBotSurfRide.new().begin_picked({"id": 4, "source": DotBotRideBook.RECORDED, "score": 1.0,
		"data": {"actions": PackedFloat32Array([1.0, 0.0, 1.0]), "action_size": 1, "hold": 2}}, DotBotSurfPilot.new(), course, null, 0, decode)
	var state := RideToyState.new()
	var intent := DotBotIntent.new()
	for t in 6:
		var st := ride.steer(state, intent, t)
		seen.append(1 if intent.jump else 0)
		if st != DotBotSurfRide.RIDING:
			break
	_check(seen == PackedInt32Array([1, 1, 0, 0, 1, 1]), "a recorded ride is played back a row per hold, the last held on", str(seen))
	state.position.x = 5.0
	var _m := ride.steer(state, intent, 6)
	state.position.x = 10.5
	_check(ride.steer(state, intent, 7) == DotBotSurfRide.LANDED and ride.describe()["source"] == "recorded", "and it ends in the goal")
	_done()
