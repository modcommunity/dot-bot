class_name DotBotNav
extends RefCounted

## Where a bot can walk: a navigation mesh baked from a map's colliders, and paths across it.
##
## [b]Optional.[/b] The brain walks straight at waypoints and hops when stuck, which is enough on
## an arena's open floor. A hiding game is all interiors, stairs, crawl spaces and doors, and a
## bot that walks straight at a cupboard upstairs walks into the wall under it. A game whose maps
## have no graph of their own bakes one here when a map is built and asks it for paths.
##
## [b]Baked from what collides, after the map is built.[/b] The family's maps are built in code
## from documents, so there is nothing to bake in the editor; this parses the static colliders
## (what a body would stand on and walk into) with the engine's own [NavigationServer3D] and
## bakes on the spot. [b]Pass the bodies that never move[/b] (`bodies`), not the whole map: a
## door is a static body too, and a door baked shut is a doorway the mesh does not go through,
## so a bot never walks to it to open it.
##
## [b]Its own navigation map.[/b] Not the world's default one, so a game's own navigation (or a
## second server in the same process) is never disturbed, and [method clear] frees all of it.
##
## [b]Deterministic where it matters.[/b] [method random_point] draws from the caller's
## [DotRandomStream] over the mesh's polygons weighted by area, never the engine's own random
## point, so a seeded game picks the same hiding spots on every run.
##
## [codeblock]
## var nav := DotBotNav.new()
## var baked := nav.bake(map_node, {"radius": 0.35, "height": 0.9, "climb": 0.42})
## var path := nav.path(bot_feet, goal)          # PackedVector3Array, empty when unreachable
## var spot := nav.random_point(stream)
## [/codeblock]

const CHANNEL := "dot.bot.nav"

## Metres a cell of the mesh covers, flat and up. Half a body's radius, so the radius is whole
## cells and a doorway of 0.9 m is a doorway; finer costs bake time on a big map.
const CELL := 0.175
const CELL_HEIGHT := 0.1

## The baked mesh, or null before [method bake].
var mesh: NavigationMesh = null

## How long the last bake took, milliseconds: from the parse to the mesh taken in, so a
## [method bake_in_background] counts the time it spent on its thread.
var bake_ms: float = 0.0

var _started: int = 0
var _baking: bool = false
## Bumped by [method clear]; a background bake started under another number is dropped.
var _generation: int = 0

var _map: RID = RID()
var _synced: bool = false
var _region: RID = RID()

## Polygon index -> cumulative area, for [method random_point].
var _areas: PackedFloat32Array = PackedFloat32Array()
var _total_area: float = 0.0


## Bakes the static colliders under [param root]. [param agent]: `radius`, `height` (the lowest
## a body can go, crouched, so crawl spaces are on the mesh), `climb` (a step), `slope`
## (degrees); [param mask] the collision layers that count as ground and walls (0 for all).
## With [param bodies] (nodes under [param root]), only those and their children are parsed.
func bake(root: Node3D, agent: Dictionary = {}, mask: int = 0, bodies: Array = []) -> DotResult:
	var parsed := _parse(root, agent, mask, bodies)
	if not parsed.ok:
		return parsed
	NavigationServer3D.bake_from_source_geometry_data(mesh, parsed.value)
	return _take_in()


## [method bake], with the bake itself on a worker thread: the colliders are parsed now (that
## has to be the main thread, and is milliseconds), the mesh is built off it, and it is taken in
## on the main thread when it is done, which calls [param done] with [method bake]'s result.
## Until then [method path] answers empty and [method is_baking] is true. Returns a failure
## only when there is nothing to bake; otherwise success, with the result still to come.
##
## [b]For a map too big to bake inside a tick.[/b] game-arena's imported surf maps are twenty
## to fifty thousand collision vertices and took two to three seconds to bake against a map
## change of a tenth of one: on a server that is every player's game stopping at the change.
## The price is [method bake]'s determinism: when the mesh arrives depends on the machine, so a
## game that replays a seeded round from its paths must use [method bake]. Without threads
## ([method DotPlatform.has_threads]) this is [method bake], and [param done] is called before
## it returns.
func bake_in_background(root: Node3D, agent: Dictionary = {}, mask: int = 0, bodies: Array = [], done: Callable = Callable()) -> DotResult:
	var parsed := _parse(root, agent, mask, bodies)
	if not parsed.ok:
		return parsed
	if not DotPlatform.has_threads():
		NavigationServer3D.bake_from_source_geometry_data(mesh, parsed.value)
		var res := _take_in()
		if done.is_valid():
			done.call(res)
		return res
	_baking = true
	# The generation and the mesh are bound so a bake that lands after clear() or a newer bake
	# is dropped instead of taken in over the map that replaced it.
	NavigationServer3D.bake_from_source_geometry_data_async(mesh, parsed.value, _on_baked.bind(_generation, mesh, done))
	return DotResult.success(0)


## Whether a [method bake_in_background] has not landed yet.
func is_baking() -> bool:
	return _baking


func _on_baked(generation: int, baked: NavigationMesh, done: Callable) -> void:
	if generation != _generation or baked != mesh:
		return
	_baking = false
	var res := _take_in()
	if done.is_valid():
		done.call(res)


## Clears, then sets [member mesh] up and parses the colliders into source geometry.
func _parse(root: Node3D, agent: Dictionary, mask: int, bodies: Array) -> DotResult:
	clear()

	if root == null or not root.is_inside_tree():
		return DotResult.fail(DotError.CODE_INVALID, "nothing to bake: the map is not in the tree")

	_started = Time.get_ticks_usec()
	mesh = NavigationMesh.new()
	mesh.cell_size = CELL
	mesh.cell_height = CELL_HEIGHT
	# Whole cells, rounded the safe way (a body wider and taller, a step lower), which the baker
	# does anyway and warns about.
	mesh.agent_radius = ceilf(float(agent.get("radius", 0.35)) / CELL - 0.001) * CELL
	mesh.agent_height = ceilf(float(agent.get("height", 0.9)) / CELL_HEIGHT - 0.001) * CELL_HEIGHT
	mesh.agent_max_climb = floorf(float(agent.get("climb", 0.4)) / CELL_HEIGHT + 0.001) * CELL_HEIGHT
	mesh.agent_max_slope = float(agent.get("slope", 46.0))
	mesh.region_min_size = 2.0
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	var group := StringName("dot_bot_nav_%d" % get_instance_id())
	if not bodies.is_empty():
		mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		mesh.geometry_source_group_name = group
		for body: Node in bodies:
			body.add_to_group(group)
	if mask != 0:
		mesh.geometry_collision_mask = mask

	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(mesh, source, root)
	for body: Node in bodies:
		body.remove_from_group(group)
	return DotResult.success(source)


## Hands the baked [member mesh] to a navigation map of its own.
func _take_in() -> DotResult:
	if mesh.get_polygon_count() == 0:
		bake_ms = (Time.get_ticks_usec() - _started) / 1000.0
		return DotResult.fail(DotError.CODE_INVALID, "the bake found nowhere to walk")

	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(_map, CELL)
	NavigationServer3D.map_set_cell_height(_map, CELL_HEIGHT)
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	# Not on the navigation server's threads: taken in now, on this tick, so a game that asks
	# for a path right after baking gets one, and a seeded round plays the same on every run
	# however its frames fall.
	NavigationServer3D.map_set_use_async_iterations(_map, false)
	NavigationServer3D.region_set_use_async_iterations(_region, false)
	NavigationServer3D.region_set_navigation_mesh(_region, mesh)
	NavigationServer3D.map_force_update(_map)
	_index_areas()

	bake_ms = (Time.get_ticks_usec() - _started) / 1000.0
	DotLog.debug(CHANNEL, "baked", {"polygons": mesh.get_polygon_count(), "ms": snappedf(bake_ms, 0.1)})
	return DotResult.success(mesh.get_polygon_count())


## Baked, and taken in by the navigation server, which happens on a later frame (it syncs its
## maps on the process frame), never during [method bake]: a query before then answers with the
## origin or fails. [method random_point] needs
## only the bake.
func is_ready() -> bool:
	if _synced:
		return true
	if not is_baked() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	# The map's first synchronisation can come before it holds the region (an empty map answers
	# every query with the origin), so ready is the region answering for its own first vertex.
	var probe := mesh.get_vertices()[mesh.get_polygon(0)[0]]
	_synced = NavigationServer3D.map_get_closest_point_owner(_map, probe) == _region
	return _synced


func is_baked() -> bool:
	return _map.is_valid() and mesh != null and _total_area > 0.0


## A walkable path from [param from] to [param to] (both snapped to the mesh), or empty.
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not is_ready():
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(_map, from, to, true)


## The length of [method path], or INF when there is none.
func path_length(from: Vector3, to: Vector3) -> float:
	var points := path(from, to)
	if points.size() < 2:
		return INF
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	# A path that ends far from where it was asked to go did not get there.
	if points[points.size() - 1].distance_to(closest(to)) > 0.6:
		return INF
	return total


## The nearest point on the mesh to [param at].
func closest(at: Vector3) -> Vector3:
	if not is_ready():
		return at
	return NavigationServer3D.map_get_closest_point(_map, at)


## A point on the mesh, drawn from [param stream] weighted by area.
func random_point(stream: DotRandomStream) -> Vector3:
	if not is_baked():
		return Vector3.ZERO
	var pick := stream.next_range_f(0.0, _total_area)
	var lo := 0
	var hi := _areas.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if _areas[mid] < pick:
			lo = mid + 1
		else:
			hi = mid
	var polygon := mesh.get_polygon(lo)
	var vertices := mesh.get_vertices()
	# A triangle of the fan, then a point in it.
	var fan := stream.next_range_i(1, maxi(polygon.size() - 2, 1))
	var a := vertices[polygon[0]]
	var b := vertices[polygon[fan]]
	var c := vertices[polygon[mini(fan + 1, polygon.size() - 1)]]
	var u := stream.next_unit()
	var v := stream.next_unit()
	if u + v > 1.0:
		u = 1.0 - u
		v = 1.0 - v
	return a + (b - a) * u + (c - a) * v


## Frees the navigation map. Call when the map it was baked from goes away.
func _notification(what: int) -> void:
	# The RIDs by hand: a method call on an object being deleted finds it already gone.
	if what == NOTIFICATION_PREDELETE:
		if _region.is_valid():
			NavigationServer3D.free_rid(_region)
		if _map.is_valid():
			NavigationServer3D.free_rid(_map)


func clear() -> void:
	if _region.is_valid():
		NavigationServer3D.free_rid(_region)
	if _map.is_valid():
		NavigationServer3D.free_rid(_map)
	_region = RID()
	_map = RID()
	_synced = false
	_baking = false
	_generation += 1
	mesh = null
	_areas = PackedFloat32Array()
	_total_area = 0.0


func _index_areas() -> void:
	_areas = PackedFloat32Array()
	_total_area = 0.0
	var vertices := mesh.get_vertices()
	for i in range(mesh.get_polygon_count()):
		var polygon := mesh.get_polygon(i)
		var area := 0.0
		for k in range(1, polygon.size() - 1):
			area += (vertices[polygon[k]] - vertices[polygon[0]]).cross(vertices[polygon[k + 1]] - vertices[polygon[0]]).length() * 0.5
		_total_area += area
		_areas.append(_total_area)


func describe() -> Dictionary:
	return {
		"ready": is_ready() if is_baked() else false,
		"baking": _baking,
		"polygons": mesh.get_polygon_count() if mesh != null else 0,
		"area": snappedf(_total_area, 0.1),
		"bake_ms": snappedf(bake_ms, 0.1),
	}


func describe_lines() -> PackedStringArray:
	var facts := describe()
	return PackedStringArray(["nav  %s, %d polygons, %.0f m2, baked in %.0f ms" % [
		"ready" if facts["ready"] else ("baking" if facts["baking"] else "not baked"), facts["polygons"], facts["area"], facts["bake_ms"]]])
