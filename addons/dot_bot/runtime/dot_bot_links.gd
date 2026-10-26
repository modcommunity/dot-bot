class_name DotBotLinks
extends RefCounted

## What a converted map's own entities add to [DotBotNav]: teleports the mesh can use, kill volumes it
## must keep clear of, and touch doors a body opens by walking into them.
##
## [b]Read from the map, never written in a game.[/b] [method read] takes a built map world by duck
## typing (dot-map's `DotMapWorld`: `volumes.nodes` and `io.entities`, `io.destinations`), so this
## names no other addon and a game with imported maps gets all three from one call. The facts are
## plain data afterwards (the arrays below), which is also what the suite feeds it.
##
## [codeblock]
## var links := DotBotLinks.read(map_world)
## links.carve(nav)                          # before the bake: kill volumes are cut out
## nav.bake_in_background(root, agent, 0, statics)
## # once nav.is_ready():
## links.join(nav)                           # teleports become one-way edges
## for index in links.doors_touched(feet, 0.35, 1.8):  # each step: doors a body is walking into
##     map_world.io.touch(index, body)
## [/codeblock]
##
## [b]A teleport is an edge, not a ride.[/b] It is added with [method DotBotNav.add_ride] so a path
## crosses it, but its id is at or above [constant TELEPORT_ID]: nothing is ridden, the bot stands in the
## box and the map moves it. [b]Only what a runner can fire now.[/b] A volume that is disabled, filtered
## or not for clients is left out (and counted), because a path through it would end at a box that does
## nothing; one a button enables later is not known here, so the path stops short of it.

const CHANNEL := "dot.bot.links"

## Ride ids from here up are teleports, so a game's own ride ids (surf edges) are never confused with them.
const TELEPORT_ID := 1000000
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
## Volumes left out and why: `{"disabled", "filtered", "flags", "no_destination"}` counts.
var skipped: Dictionary = {}
## What [method join] found: `{"joined", "off_mesh", "stranded"}`.
var joined: Dictionary = {}

## Damage at or above which a hurt volume counts as a kill, and the metres a kill box is grown by.
var lethal: float = 100.0
var margin: float = 0.4


## Reads [param world]'s teleports, kill volumes and touch doors. [param options]: `lethal`, `margin`.
static func read(world: Object, options: Dictionary = {}) -> DotBotLinks:
	var links := DotBotLinks.new()
	links.lethal = float(options.get("lethal", links.lethal))
	links.margin = float(options.get("margin", links.margin))
	if world == null:
		return links

	var io: Object = world.get("io")
	var destinations: Dictionary = io.get("destinations") if io != null else {}
	var volumes: Object = world.get("volumes")
	if volumes != null:
		for node: Object in volumes.get("nodes"):
			links._read_volume(node, destinations)
	if io != null:
		for e: Object in io.get("entities"):
			links._read_door(e)
	return links


## Cuts the kill volumes out of the next bake of [param nav], so a path ends short of one.
func carve(nav: DotBotNav) -> void:
	nav.avoid.clear()
	for box in kills:
		nav.avoid.append(box)


## Joins each teleport to [param nav] (which must be ready) as an edge from the mesh point inside its
## box to its destination, ids [constant TELEPORT_ID] up in the order read. Returns [member joined].
func join(nav: DotBotNav) -> Dictionary:
	var stats := {"joined": 0, "off_mesh": 0, "stranded": 0}
	for i in teleports.size():
		var t := teleports[i]
		var from := _entry(nav, t["box"])
		if from == Vector3.INF:
			stats["off_mesh"] += 1
			continue
		var to: Vector3 = t["to"]
		if nav.closest(to).distance_to(to) > DESTINATION_REACH:
			stats["stranded"] += 1
			continue
		nav.add_ride(from, to, TELEPORT_ID + i, TELEPORT_COST)
		stats["joined"] += 1
	joined = stats
	return stats


## The entity indices of the touch doors a body at [param feet] (radius, height) is overlapping.
func doors_touched(feet: Vector3, radius: float, height: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var body := AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, height, radius * 2.0))
	for door in doors:
		if (door["box"] as AABB).grow(0.1).intersects(body):
			out.append(int(door["index"]))
	return out


func describe() -> Dictionary:
	return {"teleports": teleports.size(), "kills": kills.size(), "doors": doors.size(),
		"skipped": skipped.duplicate(), "joined": joined.duplicate()}


func _read_volume(node: Object, destinations: Dictionary) -> void:
	var volume: Object = node.get("volume")
	if volume == null:
		return
	var kind := str(volume.get("kind"))
	if kind != "teleport" and kind != "hurt":
		return
	if node.has_method("active") and not node.call("active"):
		_skip("disabled")
		return
	var flags := int(volume.get("spawnflags")) & 15
	if flags != 0 and flags & FLAG_CLIENTS == 0:
		_skip("flags")
		return

	if kind == "hurt":
		var damage := float((volume.get("record") as Dictionary).get("damage", 0.0))
		if damage >= lethal:
			for box in _boxes(volume):
				kills.append(_grown(box))
		return

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
static func _entry(nav: DotBotNav, box: AABB) -> Vector3:
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
			if p.x < box.position.x or p.x > box.end.x or p.z < box.position.z or p.z > box.end.z \
					or p.y > box.end.y or p.y + 0.2 < box.position.y:
				continue
			var d := p.distance_to(middle)
			if d < best_d:
				best = p
				best_d = d
	return best
