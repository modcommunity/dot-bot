class_name DotBotLinks
extends RefCounted

## What a converted map's own entities add to [DotBotNav]: teleports the mesh can use, kill volumes it must keep clear of, and touch doors a body opens by walking into them.
##
## [method read] takes a built map world by duck typing (dot-map's `DotMapWorld`), so no other addon is named. A teleport is an edge (id at or above [constant TELEPORT_ID]), not a ride; only what a runner can fire now is used. Usage: docs/design.md.

const CHANNEL := "dot.bot.links"

## Ride ids from here up are teleports, so a game's own ride ids (surf edges) are never confused with them.
const TELEPORT_ID := 1000000
## Ride ids from here up are drops off the mesh's rims ([method DotBotNav.find_drops]).
const DROP_ID := 2000000
## Ride ids from here up are the legs of a platform ride (a train carrying a body between two stops).
const PLATFORM_ID := 3000000
## Shortest drop that gets an edge: below a step's climb the mesh walks it, and a drop a little over one (a pool floor
## 1.2 m down) is a floor the bake does not join either.
const DROP_MIN := 0.6
## Ride ids from here up are jumps across a gap ([method DotBotNav.find_hops]).
const HOP_ID := 4000000
## Ride ids from here up are ladders, climbed by the brain itself ([method ladder_of]), not handed to a game's rider.
const LADDER_ID := 5000000
## A ladder's travel cost per metre: slower than walking, so a stair or ramp beside it wins.
const LADDER_COST := 1.5
## Metres out from a ladder's face tried for its foot and top, and how far a mesh point may be from the try.
const LADDER_FOOT_OFFSETS := [0.5, 0.9]
const LADDER_TOP_OFFSETS := [0.4, 0.8, 1.2, 1.6]
const LADDER_SNAP := 0.5
## Metres a ladder must rise to get an edge.
const LADDER_MIN_RISE := 1.0
## Metres a platform's centre may be from a stop and count as standing there.
const STOP_REACH := 0.8
## A teleport's travel cost per metre: the trip is instant, but not free, so a short walk still wins.
const TELEPORT_COST := 0.01
## Metres a mesh point may be from a destination and still join it (the nav map's link radius).
const DESTINATION_REACH := 1.5
## Source's trigger spawnflag for "clients".
const FLAG_CLIENTS := 1

## `{"box": AABB, "to": Vector3, "entity": int, "name": String}` per teleport a runner can fire.
var teleports: Array[Dictionary] = []
## Boxes that kill whoever stands in them (a body's column overlapping), grown by [member margin].
var kills: Array[AABB] = []
## `{"index": int, "box": AABB}` per mover that opens by touch, at rest, in world space.
var doors: Array[Dictionary] = []
## Teleport volumes that are disabled now: `{"node": volume node, "entity": int}`.
var later: Array[Dictionary] = []
## Every button and trigger volume a runner can fire: `{"index": int, "kind": "walk"|"use", "box": AABB, "feeds":
## PackedInt32Array (the disabled teleports its output chain reaches, often none), "node": Object}`.
var gadgets: Array[Dictionary] = []
## Teleports [method join] could not attach: `{"entity", "box", "gap"}` (metres from the box to the nearest mesh point).
var off_mesh: Array[Dictionary] = []
## Volumes left out and why: `{"disabled", "filtered", "flags", "no_destination"}` counts.
var skipped: Dictionary = {}
## What [method join] found: `{"joined", "off_mesh", "stranded"}`.
var joined: Dictionary = {}
## `{"node": Node3D, "mover": Object}` per door or slide that swings or slides from a closed pose, for [method pose_open].
var swings: Array[Dictionary] = []
## `{"ent": Object, "node": Node3D, "stops": Array[Vector3] (the platform's centre at each corner), "top": float, "half": Vector3}`
## per train that is a raft or lift rather than a wall: thin and wide enough to stand on.
var platforms: Array[Dictionary] = []
## `{"from": Vector3, "to": Vector3, "platform": int, "stop_from": int, "stop_to": int, "id": int}` per leg a train carries a body.
var platform_links: Array[Dictionary] = []
var _platforms_joined := false
## `{"box": AABB, "from": Vector3, "to": Vector3}` per ladder brush; from and to are set once [method join] attached it.
var ladders: Array[Dictionary] = []
var _attached := {}
## Whether [method join] adds drop edges down from the mesh's rims, and how many it added.
var drops: bool = true
var dropped: int = 0
var hopped: int = 0
var _dropped_once := false
## Metres a button may be used from, and how far from the mesh a teleport box may lie and still be entered by a step.
const USE_REACH := 1.6
const ENTRY_SLACK := 1.0
## The mesh floats this far above the floor a body stands on, so a flat volume laid in the floor lies just below it.
const MESH_FLOAT := 0.35

## Metres a shot button may be shot from: a bot with no weapon in hand is the map's own damage on it, so the reach is a
## stand-in for a sight line, not a ranged attack.
const SHOOT_REACH := 3.0

## Damage at or above which a hurt volume counts as a kill, and the metres a kill box is grown by.
var lethal: float = 100.0
var margin: float = 0.4


## Opt-in unlock hints from the map's own logic ([method apply_export]); empty until a game applies one.
var unlock_doors: Array[Dictionary] = []


## Reads [param world]'s teleports, kill volumes and touch doors. [param options]: `lethal`, `margin`, and `nav_export`
## (dot-map's `DotMapNavLinks.read(world)`, which [method apply_export] takes; a game that passes none is unchanged).
static func read(world: Object, options: Dictionary = {}) -> DotBotLinks:
	var links := DotBotLinks.new()
	links.lethal = float(options.get("lethal", links.lethal))
	links.margin = float(options.get("margin", links.margin))
	if world == null:
		DotLog.debug(CHANNEL, "no world to read; bots get no teleports, kills or doors")
		return links

	if world.has_method("ladder_boxes"):
		for box: AABB in world.call("ladder_boxes"):
			links.ladders.append({"box": box})
	var io: Object = world.get("io")
	var destinations: Dictionary = io.get("destinations") if io != null else {}
	var volumes: Object = world.get("volumes")
	if volumes != null:
		for node: Object in volumes.get("nodes"):
			links._read_volume(node, destinations)
	if io != null:
		for e: Object in io.get("entities"):
			links._read_door(e)
			links._read_swing(e)
			links._read_platform(e)
		links._read_gadgets(world, io)
	var export: Variant = options.get("nav_export")
	if export is Dictionary:
		links.apply_export(export)
	return links


## Takes dot-map's door and teleport export (`DotMapNavLinks.read`): every opener of a closed door or disabled teleport becomes a gadget (a shot button is kind `"shoot"`) with the entities it reaches in `feeds`.
## [member unlock_doors] keeps `{"entity", "box", "opened_by"}` per openable door. Plain data in.
func apply_export(export: Dictionary) -> void:
	var by_index := {}
	for g in gadgets:
		by_index[int(g["index"])] = g
	var feeds := {}
	var targets: Array = []
	targets.append_array(export.get("doors", []))
	targets.append_array(export.get("teleports", []))
	unlock_doors.clear()
	for t: Dictionary in targets:
		var by: Array = t.get("opened_by", [])
		if by.is_empty():
			continue
		if t.has("opens"):
			unlock_doors.append({"entity": int(t["entity"]), "box": t["box"], "opened_by": by})
		for o: Dictionary in by:
			var list: Array = feeds.get(int(o["index"]), [])
			if not list.has(int(t["entity"])):
				list.append(int(t["entity"]))
			feeds[int(o["index"])] = list
	var openers: Dictionary = export.get("openers", {})
	for index: int in feeds:
		var feed := PackedInt32Array(feeds[index])
		if by_index.has(index):
			var g: Dictionary = by_index[index]
			var merged := PackedInt32Array(g["feeds"])
			for f in feed:
				if not merged.has(f):
					merged.append(f)
			g["feeds"] = merged
		elif openers.has(index) and str((openers[index] as Dictionary)["kind"]) == "shoot":
			gadgets.append({"index": index, "kind": "shoot", "box": (openers[index] as Dictionary)["box"], "feeds": feed, "node": null})


## Cuts the kill volumes out of the next bake of [param nav], so a path ends short of one.
func carve(nav: DotBotNav) -> void:
	nav.avoid.clear()
	for box in kills:
		nav.avoid.append(box)


## Joins each teleport not yet joined to [param nav] (which must be ready) as an edge from the mesh point inside its
## box to its destination, ids [constant TELEPORT_ID] up in the order read. Returns [member joined].
func join(nav: DotBotNav) -> Dictionary:
	var stats := {"joined": 0, "off_mesh": 0, "stranded": 0}
	off_mesh.clear()
	for i in teleports.size():
		var t := teleports[i]
		if _attached.has(i):
			continue
		var from := _entry(nav, t["box"], ENTRY_SLACK)
		if from == Vector3.INF:
			stats["off_mesh"] += 1
			var box: AABB = t["box"]
			off_mesh.append({"entity": t["entity"], "box": box, "gap": nav.closest(box.get_center()).distance_to(box.get_center())})
			continue
		var to: Vector3 = t["to"]
		if nav.closest(to).distance_to(to) > DESTINATION_REACH:
			stats["stranded"] += 1
			continue
		nav.add_ride(from, to, TELEPORT_ID + i, TELEPORT_COST)
		_attached[i] = true
		t["from"] = from
		stats["joined"] += 1
	if not ladders.is_empty():
		stats["ladders"] = _join_ladders(nav)
	if not _platforms_joined:
		_platforms_joined = true
		stats["platforms"] = _join_platforms(nav)
	if drops and not _dropped_once:
		_dropped_once = true
		dropped = nav.find_drops(DROP_ID, DROP_MIN)
		stats["drops"] = dropped
		hopped = nav.find_hops(HOP_ID) if drops else 0
		stats["hops"] = hopped
	joined = stats
	return stats


## The ladder behind ride [param ride_id] as `{"box", "from", "to"}`, or an empty dictionary: what [member DotBotWorld.ladder_fn] answers.
func ladder_of(ride_id: int) -> Dictionary:
	var i := ride_id - LADDER_ID
	if i < 0 or i >= ladders.size() or not ladders[i].has("from"):
		return {}
	return ladders[i]


## One-way up edges from each ladder's foot to its top, both on the mesh; returns how many were added.
func _join_ladders(nav: DotBotNav) -> int:
	var added := 0
	for i in ladders.size():
		var l := ladders[i]
		if l.has("from"):
			continue
		var box: AABB = l["box"]
		var from := _ladder_end(nav, box, box.position.y, LADDER_FOOT_OFFSETS)
		var to := _ladder_end(nav, box, box.end.y, LADDER_TOP_OFFSETS)
		if from == Vector3.INF or to == Vector3.INF or to.y - from.y < LADDER_MIN_RISE:
			continue
		l["from"] = from
		l["to"] = to
		nav.add_ride(from, to, LADDER_ID + i, LADDER_COST)
		added += 1
	return added


## The mesh point nearest to where a body would stand at [param y] out from either face of the ladder.
func _ladder_end(nav: DotBotNav, box: AABB, y: float, offsets: Array) -> Vector3:
	var along_x := box.size.x < box.size.z
	var centre := box.get_center()
	var best := Vector3.INF
	var best_d := LADDER_SNAP
	for side in [-1.0, 1.0]:
		for out: float in offsets:
			var reach: float = (box.size.x if along_x else box.size.z) * 0.5 + out
			var at := Vector3(centre.x + side * reach, y, centre.z) if along_x else Vector3(centre.x, y, centre.z + side * reach)
			var near := nav.closest(at)
			var d := Vector2(near.x - at.x, near.z - at.z).length()
			if d < best_d and absf(near.y - y) < 0.8:
				best = near
				best_d = d
	return best


## Takes in the teleports a button has enabled since [method read] and joins them. Returns how many are new.
func refresh(nav: DotBotNav, destinations: Dictionary) -> int:
	var fresh := 0
	for l in later.duplicate():
		var node: Object = l["node"]
		if node.has_method("active") and node.call("active"):
			later.erase(l)
			var before := teleports.size()
			_add_teleport(node, destinations)
			fresh += teleports.size() - before
	if fresh > 0:
		var _stats := join(nav)
	return fresh


## The nearest gadget not in [param done] whose teleport is still disabled ([param any]: every gadget), within [param within] metres of walking from [param feet];
## it gains `"at"` (the mesh point) and `"metres"`, or an empty dictionary.
func next_gadget(nav: DotBotNav, feet: Vector3, done: Dictionary, any: bool = false, within: float = 60.0) -> Dictionary:
	var best := {}
	var best_metres := within
	for g in gadgets:
		if done.has(g["index"]) or not (any or _wanted(g)) or not _available(g):
			continue
		var at := _stand(nav, g)
		if at == Vector3.INF:
			continue
		var path := nav.path(feet, at)
		if path.size() < 2 and feet.distance_to(at) > 1.0:
			continue
		if not path.is_empty() and path[path.size() - 1].distance_to(at) > 1.0:
			continue
		var metres := 0.0
		for i in range(1, path.size()):
			metres += path[i - 1].distance_to(path[i])
		if metres < best_metres:
			best_metres = metres
			best = g.duplicate()
			best["at"] = at
			best["metres"] = metres
	return best


## The nearest joined teleport not in [param taken] (teleport index to anything) that a bot at [param feet] can walk to:
## `{"index", "kind": "teleport", "box", "at", "metres"}` shaped like a gadget, or an empty dictionary.
func next_teleport(nav: DotBotNav, feet: Vector3, taken: Dictionary) -> Dictionary:
	var best := {}
	var best_metres := INF
	for i in teleports.size():
		var t := teleports[i]
		if taken.has(TELEPORT_ID + i) or not _attached.has(i):
			continue
		var at: Vector3 = t["from"]
		var path := nav.path(feet, at)
		if path.is_empty() or path[path.size() - 1].distance_to(at) > 1.0:
			continue
		var metres := 0.0
		for j in range(1, path.size()):
			metres += path[j - 1].distance_to(path[j])
		if metres < best_metres:
			best_metres = metres
			best = {"index": TELEPORT_ID + i, "kind": "teleport", "box": t["box"], "at": at, "metres": metres}
	return best


## Whether a body at [param feet] (radius, height) is where [param gadget] fires: inside a trigger's volume, or
## within reach of a button.
func at_gadget(gadget: Dictionary, feet: Vector3, radius: float = 0.35, height: float = 1.8) -> bool:
	var box: AABB = gadget["box"]
	if gadget["kind"] == "shoot":
		return box.grow(SHOOT_REACH).has_point(feet + Vector3(0.0, 0.9, 0.0))
	if gadget["kind"] == "use":
		return box.grow(USE_REACH).has_point(feet + Vector3(0.0, 0.9, 0.0))
	return box.grow(0.1).intersects(AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0)))


## The entity indices of the touch doors a body at [param feet] (radius, height) is overlapping.
func doors_touched(feet: Vector3, radius: float, height: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var body := AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0))
	for door in doors:
		if (door["box"] as AABB).grow(0.1).intersects(body):
			out.append(int(door["index"]))
	return out


## Poses every door and slide open, returning what [method restore] needs; call just before a bake and restore right after (the bake parses on the calling tick). A door baked shut is a wall.
func pose_open() -> Array[Dictionary]:
	var undo: Array[Dictionary] = []
	for swing in swings:
		var node: Node3D = swing["node"]
		var mover: Object = swing["mover"]
		if node == null or not is_instance_valid(node):
			continue
		undo.append({"node": node, "was": node.transform})
		var t: Transform3D = mover.call("transform_at", 1.0, 1.0)
		node.transform = Transform3D(t.basis * node.transform.basis, node.transform.origin + t.origin)
	return undo


## Puts the nodes [method pose_open] moved back.
func restore(undo: Array[Dictionary]) -> void:
	for entry in undo:
		(entry["node"] as Node3D).transform = entry["was"]


## The collision bodies of the doors and slides, which a bake given only static bodies leaves out.
func swing_bodies() -> Array:
	var out: Array = []
	for swing in swings:
		var node: Node = swing["node"]
		if node != null and is_instance_valid(node):
			for body in node.find_children("*", "CollisionObject3D", true, false):
				out.append(body)
	return out


## Static copies of every platform's collision at each of its stops, under [param root], so a bake sees a floor
## wherever a raft can lie. [b]Copies, not the body moved[/b]: one body cannot stand at two stops. Free them with
## [method free_stop_bodies] right after the bake (it parses on the calling tick).
func stop_bodies(root: Node3D, io: Object) -> Array:
	var out: Array = []
	var inverse := root.global_transform.affine_inverse()
	for index in platforms.size():
		var platform := platforms[index]
		var node: Node3D = platform["node"]
		if node == null or not is_instance_valid(node):
			continue
		var stops: Array = platform["stops"]
		var now_at := platform_centre(index, io)
		for k in stops.size():
			var shift: Vector3 = stops[k] - now_at
			var body := StaticBody3D.new()
			root.add_child(body)
			body.transform = Transform3D(Basis.IDENTITY, shift)
			for shape_node in node.find_children("*", "CollisionShape3D", true, false):
				var cs := shape_node as CollisionShape3D
				var copy := CollisionShape3D.new()
				copy.shape = cs.shape
				body.add_child(copy)
				copy.transform = inverse * cs.global_transform
			out.append(body)
	return out


func free_stop_bodies(bodies: Array) -> void:
	for body: Node in bodies:
		if is_instance_valid(body):
			body.get_parent().remove_child(body)
			body.free()


## Where the platform's centre is now, from the train's own clock.
func platform_centre(index: int, io: Object) -> Vector3:
	var p: Dictionary = platforms[index]
	var ent: Object = p["ent"]
	var corners: Array = ent.get("_corners")
	var s: float = ent.call("path_at", int(io.get("now")), int(io.get("rate")))
	return (ent.get("hit_frame") as Transform3D).origin + (ent.call("path_point", s) as Vector3) - (corners[0] as Vector3)


## Whether the platform is within [constant STOP_REACH] (flat) of its stop [param stop].
func platform_at_stop(index: int, stop: int, io: Object) -> bool:
	var c := platform_centre(index, io)
	var target: Vector3 = platforms[index]["stops"][stop]
	return Vector2(c.x - target.x, c.z - target.z).length() < STOP_REACH


## The platform leg whose start is within [param reach] metres (flat, and a step in height) of [param at], or {}.
func platform_link_near(at: Vector3, reach: float) -> Dictionary:
	for leg in platform_links:
		var from: Vector3 = leg["from"]
		if Vector2(from.x - at.x, from.z - at.z).length() < reach and absf(from.y - at.y) < 1.0:
			return leg
	return {}


func _join_platforms(nav: DotBotNav) -> int:
	var count := 0
	for i in platforms.size():
		var stops: Array = platforms[i]["stops"]
		var top: float = platforms[i]["top"]
		var points: Array = []
		for stop: Vector3 in stops:
			var near := nav.closest(Vector3(stop.x, top, stop.z))
			var ok := Vector2(near.x - stop.x, near.z - stop.z).length() < 0.9 and absf(near.y - top) < 0.8
			points.append(near if ok else Vector3.INF)
		for k in stops.size() - 1:
			if points[k] == Vector3.INF or points[k + 1] == Vector3.INF:
				continue
			for dir in 2:
				var a := k if dir == 0 else k + 1
				var b := k + 1 if dir == 0 else k
				var id := PLATFORM_ID + platform_links.size()
				nav.add_ride(points[a], points[b], id, TELEPORT_COST)
				platform_links.append({"from": points[a], "to": points[b], "platform": i, "stop_from": a, "stop_to": b, "id": id})
				count += 1
	return count


func describe() -> Dictionary:
	return {"teleports": teleports.size(), "kills": kills.size(), "doors": doors.size(), "later": later.size(),
		"gadgets": gadgets.size(), "swings": swings.size(), "platforms": platforms.size(), "legs": platform_links.size(), "skipped": skipped.duplicate(), "joined": joined.duplicate()}


func _read_volume(node: Object, destinations: Dictionary) -> void:
	var volume: Object = node.get("volume")
	if volume == null:
		return
	var kind := str(volume.get("kind"))
	if kind != "teleport" and kind != "hurt":
		return
	if node.has_method("active") and not node.call("active"):
		_skip("disabled")
		if kind == "teleport":
			later.append({"node": node, "entity": int(volume.get("entity"))})
		return
	var flags := int(volume.get("spawnflags")) & 15
	if flags != 0 and flags & FLAG_CLIENTS == 0:
		_skip("flags")
		return

	if kind == "hurt":
		var damage := float((volume.get("record") as Dictionary).get("damage", 0.0))
		if damage >= lethal and not _scores(volume):
			for box in _boxes(volume):
				kills.append(_grown(box))
		return

	_add_teleport(node, destinations)


## Whether a hurt volume is the map's finish line: it scores whoever touches it, however it kills.
func _scores(volume: Object) -> bool:
	for output: Dictionary in volume.get("outputs") if volume.get("outputs") != null else []:
		if str(output.get("input", "")).to_lower() == "applyscore":
			return true
	return false


func _add_teleport(node: Object, destinations: Dictionary) -> void:
	var volume: Object = node.get("volume")
	if str(volume.get("filter")) != "":
		_skip("filtered")
		return
	var name := str(volume.get("target"))
	var entity: Object = node.get("entity")
	if name == "" and entity != null and entity.has_method("key"):
		name = str(entity.call("key", "target"))
	var dest: Variant = destinations.get(name)
	if not dest is Dictionary or not (dest as Dictionary).get("at") is Array:
		_skip("no_destination")
		return
	var at: Array = (dest as Dictionary)["at"]
	teleports.append({"box": volume.call("bounds"), "to": Vector3(at[0], at[1], at[2]), "name": name,
		"entity": int(volume.get("entity"))})


func _read_door(e: Object) -> void:
	var mover: Object = e.get("mover")
	if mover == null or not bool(mover.get("touch")):
		return
	var half: Vector3 = e.get("hit_half")
	if half == Vector3.ZERO:
		return
	var frame: Transform3D = e.get("hit_frame")
	var box := AABB(frame.origin, Vector3.ZERO)
	for corner in 8:
		box = box.expand(frame * Vector3(
			half.x if corner & 1 else -half.x, half.y if corner & 2 else -half.y, half.z if corner & 4 else -half.z))
	doors.append({"index": int(e.get("index")), "box": box})


func _read_platform(e: Object) -> void:
	var mover: Object = e.get("mover")
	var node: Object = e.get("node")
	if mover == null or not node is Node3D or str(mover.get("kind")) != "path" or not bool(mover.get("solid")):
		return
	var half: Vector3 = e.get("hit_half")
	var corners: Array = e.get("_corners")
	if half.y > 0.6 or half.x < 0.5 or half.z < 0.5 or corners.size() < 2:
		return
	var frame: Transform3D = e.get("hit_frame")
	var stops: Array = []
	for c: Vector3 in corners:
		stops.append(frame.origin + c - (corners[0] as Vector3))
	platforms.append({"ent": e, "node": node, "stops": stops, "top": frame.origin.y + half.y, "half": half})


func _read_swing(e: Object) -> void:
	var mover: Object = e.get("mover")
	var node: Object = e.get("node")
	if mover == null or not node is Node3D or bool(mover.get("start_open")) or not bool(mover.get("solid")):
		return
	if str(mover.get("kind")) in ["slide", "rotate", "rotate_button"] and bool(mover.call("is_animatable")):
		swings.append({"node": node, "mover": mover})


## The buttons and trigger volumes whose output chains reach a disabled teleport, found backwards from each teleport
## through every output that names the entity so far (an Enable, a relay, a counter, another trigger).
func _read_gadgets(world: Object, io: Object) -> void:
	var feeders := {}
	for e: Object in io.get("entities"):
		for link: Dictionary in e.get("links") if e.get("links") != null else []:
			var inp := str(link["input"]).to_lower()
			if inp in ["disable", "turnoff", "kill", "killhierarchy"]:
				continue
			for target: Object in io.call("resolve", str(link["target"]), e, null):
				var list: Array = feeders.get(int(target.get("index")), [])
				list.append(int(e.get("index")))
				feeders[int(target.get("index"))] = list
	var roots := {}
	var volumes: Object = world.get("volumes")
	for node: Object in volumes.get("nodes"):
		var volume: Object = node.get("volume")
		var kind := str(volume.get("kind"))
		var flags := int(volume.get("spawnflags")) & 15
		if (kind != "multiple" and kind != "once") or (flags != 0 and flags & FLAG_CLIENTS == 0) or str(volume.get("filter")) != "":
			continue
		var bounds: AABB = volume.call("bounds")
		roots[int(volume.get("entity"))] = {"index": int(volume.get("entity")), "kind": "walk", "box": bounds, "node": node}
	for e: Object in io.get("entities"):
		var mover: Object = e.get("mover")
		if mover == null or mover.get("use") != true or str(mover.get("kind")) in ["spin", "path"]:
			continue
		var half: Vector3 = e.get("hit_half")
		if half == Vector3.ZERO:
			continue
		var frame: Transform3D = e.get("hit_frame")
		var box := AABB(frame.origin, Vector3.ZERO)
		for corner in 8:
			box = box.expand(frame * Vector3(
				half.x if corner & 1 else -half.x, half.y if corner & 2 else -half.y, half.z if corner & 4 else -half.z))
		roots[int(e.get("index"))] = {"index": int(e.get("index")), "kind": "use", "box": box, "node": e}

	var feeds := {}
	for l in later:
		var seen := {int(l["entity"]): true}
		var frontier: Array = [int(l["entity"])]
		for depth in 10:
			var next: Array = []
			for at: int in frontier:
				for from: int in feeders.get(at, []):
					if seen.has(from):
						continue
					seen[from] = true
					next.append(from)
					if roots.has(from):
						var list: Array = feeds.get(from, [])
						list.append(int(l["entity"]))
						feeds[from] = list
			frontier = next
			if frontier.is_empty():
				break
	for index: int in roots:
		var g: Dictionary = roots[index]
		g["feeds"] = PackedInt32Array(feeds.get(index, []))
		gadgets.append(g)


## Whether a teleport the gadget feeds is still disabled.
func _wanted(gadget: Dictionary) -> bool:
	for l in later:
		if (gadget["feeds"] as PackedInt32Array).has(int(l["entity"])):
			return true
	return false


## Whether the gadget can fire now: a trigger volume that is enabled.
func _available(gadget: Dictionary) -> bool:
	var node: Object = gadget["node"]
	if node == null:
		return true
	if gadget["kind"] == "walk":
		return node.has_method("active") and bool(node.call("active"))
	return not bool(node.get("locked")) and bool(node.get("alive"))


## The mesh point a bot stands on to fire [param gadget], INF when the mesh never gets there.
func _stand(nav: DotBotNav, gadget: Dictionary) -> Vector3:
	var box: AABB = gadget["box"]
	if gadget["kind"] == "walk":
		return _entry(nav, box, 0.0)
	var near := nav.closest(box.get_center())
	return near if at_gadget(gadget, near) else Vector3.INF


func _skip(why: String) -> void:
	skipped[why] = int(skipped.get(why, 0)) + 1


## One box per brush when the volume has them (a union would span the gaps), else its bounds.
static func _boxes(volume: Object) -> Array[AABB]:
	var out: Array[AABB] = []
	if volume.has_method("brush_boxes"):
		out.assign(volume.call("brush_boxes"))
	if out.is_empty():
		out.append(volume.call("bounds"))
	return out


func _grown(box: AABB) -> AABB:
	return AABB(box.position - Vector3(margin, 0.0, margin), box.size + Vector3(margin * 2.0, 0.0, margin * 2.0))


## A mesh point inside [param box], nearest its middle, or INF when the floor never enters it.
static func _entry(nav: DotBotNav, box: AABB, slack: float = 0.0) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	var middle := box.get_center()
	var steps_x := clampi(int(ceil(box.size.x / 0.5)), 1, 8)
	var steps_z := clampi(int(ceil(box.size.z / 0.5)), 1, 8)
	for ix in steps_x + 1:
		for iz in steps_z + 1:
			var sample := Vector3(
				box.position.x + box.size.x * float(ix) / float(steps_x), box.position.y + 0.3,
				box.position.z + box.size.z * float(iz) / float(steps_z))
			var p := nav.closest(sample)
			# a body's feet stand a little above the mesh; its column must meet the box
			if p.x < box.position.x - slack or p.x > box.end.x + slack or p.z < box.position.z - slack \
					or p.z > box.end.z + slack or p.y > box.end.y + MESH_FLOAT or p.y + 1.7 < box.position.y:
				continue
			var d := p.distance_to(middle)
			if d < best_d:
				best = p
				best_d = d
	return best
