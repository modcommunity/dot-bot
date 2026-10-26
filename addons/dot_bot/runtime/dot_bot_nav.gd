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

## Boxes the next bake cuts out of the mesh, so no path ends inside one: a kill volume a bot would
## walk into. A box reaches [member avoid_body] metres below its floor too, since a body is hit by
## what overlaps its column. Kept across [method clear] and a re-bake, like the ride edges.
var avoid: Array[AABB] = []
var avoid_body: float = 1.8

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

## Ride edges: `{"id", "from", "to", "cost", "rid"}`, linked into the map whenever it is baked.
var _rides: Array[Dictionary] = []
## Link RID -> ride id, for [method route].
var _ride_of_link: Dictionary = {}

## Polygon index -> island, from [method islands]; empty until asked.
var _island_of: PackedInt32Array = PackedInt32Array()
var _islands: Array[Dictionary] = []
## Island -> islands one ride edge reaches, for [method joined]; null until asked.
var _ride_graph: Variant = null

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
	for box in avoid:
		var lo := box.position
		var hi := box.end
		source.add_projected_obstruction(PackedVector3Array([
			Vector3(lo.x, 0.0, lo.z), Vector3(hi.x, 0.0, lo.z), Vector3(hi.x, 0.0, hi.z), Vector3(lo.x, 0.0, hi.z)]),
			lo.y - avoid_body, box.size.y + avoid_body, true)
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
	NavigationServer3D.map_set_link_connection_radius(_map, LINK_RADIUS)
	for ride in _rides:
		_link(ride)
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
		for ride in _rides:
			if (ride["rid"] as RID).is_valid():
				NavigationServer3D.free_rid(ride["rid"])
		if _region.is_valid():
			NavigationServer3D.free_rid(_region)
		if _map.is_valid():
			NavigationServer3D.free_rid(_map)


func clear() -> void:
	_unlink_all()
	_island_of = PackedInt32Array()
	_islands.clear()
	_ride_graph = null
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


# --- Ride edges ----------------------------------------------------------------

## How far a ride edge's ends may be from the mesh and still join it, metres.
const LINK_RADIUS := 1.5

## Adds a one-way edge from [param from] to [param to] that is not walked but ridden (a surf ramp
## from one platform to another, a drop), under [param id]. [method route] goes over it when it is
## the cheaper way and says where; the game rides it. [param cost] multiplies its length the way a
## walked metre counts. Kept across a re-bake; [method clear_rides] drops them.
##
## [b]A navigation link, because the mesh cannot hold a ramp.[/b] A face steeper than the slope
## limit is never ground, so the bake leaves every surf ramp out and a combat surf map is islands:
## a walked route to the far side ends at the edge of this one. A link joins two islands in the
## navigation server's own search, so the cheapest way is still one query.
func add_ride(from: Vector3, to: Vector3, id: int, cost: float = 1.0) -> void:
	var ride := {"id": id, "from": from, "to": to, "cost": cost, "rid": RID()}
	_rides.append(ride)
	_ride_graph = null
	if _map.is_valid():
		_link(ride)
		NavigationServer3D.map_force_update(_map)


## The ride edges added, as `{"id", "from", "to", "cost"}`.
func rides() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for ride in _rides:
		out.append({"id": ride["id"], "from": ride["from"], "to": ride["to"], "cost": ride["cost"]})
	return out


func clear_rides() -> void:
	_ride_graph = null
	_unlink_all()
	_rides.clear()
	if _map.is_valid():
		NavigationServer3D.map_force_update(_map)


func _link(ride: Dictionary) -> void:
	var link := NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(link, _map)
	NavigationServer3D.link_set_bidirectional(link, false)
	NavigationServer3D.link_set_start_position(link, ride["from"])
	NavigationServer3D.link_set_end_position(link, ride["to"])
	NavigationServer3D.link_set_travel_cost(link, float(ride["cost"]))
	ride["rid"] = link
	_ride_of_link[link] = int(ride["id"])


func _unlink_all() -> void:
	for ride in _rides:
		var rid: RID = ride["rid"]
		if rid.is_valid():
			NavigationServer3D.free_rid(rid)
		ride["rid"] = RID()
	_ride_of_link.clear()


## A way from [param from] to [param to] that may ride: `{"points": PackedVector3Array, "rides":
## PackedInt32Array}`, where `rides[i]` is the id of the ride edge that starts at `points[i]` (its
## end is `points[i + 1]`), or -1 for a walked corner. Empty points when unreachable.
func route(from: Vector3, to: Vector3) -> Dictionary:
	var out := {"points": PackedVector3Array(), "rides": PackedInt32Array()}
	if not is_ready():
		return out
	var query := NavigationPathQueryParameters3D.new()
	query.map = _map
	query.start_position = from
	query.target_position = to
	query.metadata_flags = NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_TYPES | NavigationPathQueryParameters3D.PATH_METADATA_INCLUDE_RIDS
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(query, result)
	var points := result.path
	var types := result.path_types
	var rids := result.path_rids
	var marks := PackedInt32Array()
	marks.resize(points.size())
	marks.fill(-1)
	for i in range(points.size()):
		if i < types.size() and types[i] == NavigationPathQueryResult3D.PATH_SEGMENT_TYPE_LINK and i < rids.size() and _ride_of_link.has(rids[i]):
			# The link's start is the point flagged as the link; its end is the next one.
			marks[i] = int(_ride_of_link[rids[i]])
	# A link can be reported on both of its points: keep the first of a run.
	for i in range(points.size() - 1, 0, -1):
		if marks[i] >= 0 and marks[i - 1] == marks[i]:
			marks[i] = -1
	out["points"] = points
	out["rides"] = marks
	return out


# --- Islands -------------------------------------------------------------------

## The mesh's islands: polygons joined by shared edges, biggest first, as `{"index", "area",
## "polygons": PackedInt32Array, "bounds": AABB, "centre": Vector3}`. What a walked route cannot
## leave: on a combat surf map each platform group is one, and a ride edge joins two.
func islands() -> Array[Dictionary]:
	if not _islands.is_empty() or mesh == null:
		return _islands
	var vertices := mesh.get_vertices()
	var count := mesh.get_polygon_count()
	var parent := PackedInt32Array()
	parent.resize(count)
	for i in range(count):
		parent[i] = i
	var edge_owner: Dictionary = {}
	for i in range(count):
		var polygon := mesh.get_polygon(i)
		for k in range(polygon.size()):
			var a := _vertex_key(vertices[polygon[k]])
			var b := _vertex_key(vertices[polygon[(k + 1) % polygon.size()]])
			var key := [a, b] if str(a) < str(b) else [b, a]
			if edge_owner.has(key):
				_union(parent, i, int(edge_owner[key]))
			else:
				edge_owner[key] = i
	var groups: Dictionary = {}
	for i in range(count):
		var root := _find(parent, i)
		if not groups.has(root):
			groups[root] = PackedInt32Array()
		groups[root].append(i)
	var out: Array[Dictionary] = []
	for root: int in groups:
		var polygons: PackedInt32Array = groups[root]
		var area := 0.0
		var bounds := AABB()
		var first := true
		var weighted := Vector3.ZERO
		for i in polygons:
			var polygon := mesh.get_polygon(i)
			var a := _polygon_area(polygon, vertices)
			area += a
			var centre := Vector3.ZERO
			for v in polygon:
				centre += vertices[v]
				if first:
					bounds = AABB(vertices[v], Vector3.ZERO)
					first = false
				else:
					bounds = bounds.expand(vertices[v])
			weighted += centre / float(polygon.size()) * a
		out.append({"area": area, "polygons": polygons, "bounds": bounds, "centre": weighted / maxf(area, 0.0001)})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["area"]) > float(y["area"]))
	_island_of = PackedInt32Array()
	_island_of.resize(count)
	for index in range(out.size()):
		out[index]["index"] = index
		for i: int in out[index]["polygons"]:
			_island_of[i] = index
	_islands = out
	return _islands


## The island [param at] stands on (the polygon nearest it, within [param reach] metres), or -1.
func island_at(at: Vector3, reach: float = 1.0) -> int:
	var polygon := polygon_at(at, reach)
	if polygon < 0:
		return -1
	var _all := islands()
	return _island_of[polygon] if polygon < _island_of.size() else -1


## Whether [param at] is over island [param index] (inside one of its triangles seen from
## above, within [param reach] metres up or down). Fast enough to ask every simulated tick: the
## island's triangles are bucketed on a grid of [constant ISLAND_CELL] metres the first time.
## What a ride edge's course asks of its landing.
func on_island(index: int, at: Vector3, reach: float = 0.5) -> bool:
	var all := islands()
	if index < 0 or index >= all.size():
		return false
	var island := all[index]
	if not island.has("grid"):
		island["grid"] = _island_grid(island)
	var grid: Dictionary = island["grid"]
	var cell := Vector2i(floori(at.x / ISLAND_CELL), floori(at.z / ISLAND_CELL))
	var bucket: Variant = grid.get(cell)
	if bucket == null:
		return false
	for tri: Array in bucket:
		var height := _height_in(at, tri[0], tri[1], tri[2])
		if not is_nan(height) and absf(at.y - height) <= reach:
			return true
	return false


## Whether a walk (over ride edges too) from [param from] to [param to] can exist, answered from
## the mesh's islands without a path query: the navigation server prints an error for every query
## between disconnected islands, so a game that filters places by [method path_length] fills its
## log. Both points are snapped to the mesh. True before the mesh is baked, so a caller can
## filter unconditionally. A game with its own idea of "reachable" (a door it can open) passes
## its own Callable to [method DotBotHiding.choose] instead.
func joined(from: Vector3, to: Vector3) -> bool:
	if mesh == null:
		return true
	var a := _island_near(from)
	var b := _island_near(to)
	if a < 0 or b < 0:
		return false
	if a == b:
		return true
	var graph := _rides_between_islands()
	var seen := {a: true}
	var queue: Array[int] = [a]
	while not queue.is_empty():
		var at: int = queue.pop_back()
		for next: int in graph.get(at, []):
			if next == b:
				return true
			if not seen.has(next):
				seen[next] = true
				queue.append(next)
	return false


func _island_near(at: Vector3) -> int:
	var snapped_at := closest(at) if is_ready() else at
	var all := islands()
	for island in all:
		if on_island(int(island["index"]), snapped_at, 0.6):
			return int(island["index"])
	return island_at(snapped_at, 1.0)


func _rides_between_islands() -> Dictionary:
	if _ride_graph != null:
		return _ride_graph
	var graph: Dictionary = {}
	for ride in _rides:
		var a := _island_near(ride["from"])
		var b := _island_near(ride["to"])
		if a >= 0 and b >= 0 and a != b:
			if not graph.has(a):
				graph[a] = []
			graph[a].append(b)
	_ride_graph = graph
	return graph


## Grid cell for [method on_island], metres.
const ISLAND_CELL := 2.0


func _island_grid(island: Dictionary) -> Dictionary:
	var grid: Dictionary = {}
	var vertices := mesh.get_vertices()
	for i: int in island["polygons"]:
		var polygon := mesh.get_polygon(i)
		for k in range(1, polygon.size() - 1):
			var tri := [vertices[polygon[0]], vertices[polygon[k]], vertices[polygon[k + 1]]]
			var lo := Vector2(minf(tri[0].x, minf(tri[1].x, tri[2].x)), minf(tri[0].z, minf(tri[1].z, tri[2].z)))
			var hi := Vector2(maxf(tri[0].x, maxf(tri[1].x, tri[2].x)), maxf(tri[0].z, maxf(tri[1].z, tri[2].z)))
			for cx in range(floori(lo.x / ISLAND_CELL), floori(hi.x / ISLAND_CELL) + 1):
				for cz in range(floori(lo.y / ISLAND_CELL), floori(hi.y / ISLAND_CELL) + 1):
					var key := Vector2i(cx, cz)
					if not grid.has(key):
						grid[key] = []
					grid[key].append(tri)
	return grid


## The index of the polygon under [param at] (within [param reach] metres up or down, and inside
## its outline seen from above), or -1. A linear scan: for tools and for a course's goal test,
## not for every bot every tick.
func polygon_at(at: Vector3, reach: float = 1.0) -> int:
	if mesh == null:
		return -1
	var vertices := mesh.get_vertices()
	var best := -1
	var best_dy := INF
	for i in range(mesh.get_polygon_count()):
		var polygon := mesh.get_polygon(i)
		for k in range(1, polygon.size() - 1):
			var a := vertices[polygon[0]]
			var b := vertices[polygon[k]]
			var c := vertices[polygon[k + 1]]
			var height := _height_in(at, a, b, c)
			if is_nan(height):
				continue
			var dy := absf(at.y - height)
			if dy <= reach and dy < best_dy:
				best_dy = dy
				best = i
	return best


## The height of the triangle (a, b, c) under [param at] seen from above, or NAN outside it.
static func _height_in(at: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var v0 := Vector2(c.x - a.x, c.z - a.z)
	var v1 := Vector2(b.x - a.x, b.z - a.z)
	var v2 := Vector2(at.x - a.x, at.z - a.z)
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 1e-9:
		return NAN
	var u := (d11 * d20 - d01 * d21) / denom
	var v := (d00 * d21 - d01 * d20) / denom
	if u < -0.001 or v < -0.001 or u + v > 1.001:
		return NAN
	return a.y + u * (c.y - a.y) + v * (b.y - a.y)


static func _vertex_key(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 100.0), roundi(v.y * 100.0), roundi(v.z * 100.0))


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[maxi(ra, rb)] = mini(ra, rb)


static func _polygon_area(polygon: PackedInt32Array, vertices: PackedVector3Array) -> float:
	var area := 0.0
	for k in range(1, polygon.size() - 1):
		area += (vertices[polygon[k]] - vertices[polygon[0]]).cross(vertices[polygon[k + 1]] - vertices[polygon[0]]).length() * 0.5
	return area


func describe() -> Dictionary:
	return {
		"ready": is_ready() if is_baked() else false,
		"baking": _baking,
		"polygons": mesh.get_polygon_count() if mesh != null else 0,
		"area": snappedf(_total_area, 0.1),
		"bake_ms": snappedf(bake_ms, 0.1),
		"rides": _rides.size(),
		"avoid": avoid.size(),
	}


func describe_lines() -> PackedStringArray:
	var facts := describe()
	return PackedStringArray(["nav  %s, %d polygons, %.0f m2, baked in %.0f ms" % [
		"ready" if facts["ready"] else ("baking" if facts["baking"] else "not baked"), facts["polygons"], facts["area"], facts["bake_ms"]]])
