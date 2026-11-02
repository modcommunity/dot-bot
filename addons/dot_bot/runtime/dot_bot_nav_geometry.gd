class_name DotBotNavGeometry
extends RefCounted

## Pure mesh geometry for [DotBotNav]: islands, their lookup grid, triangle heights, edge keys.

## Grid cell for [method grid], metres.
const ISLAND_CELL := 2.0


## The mesh's islands (polygons joined by shared edges), biggest first, each with its "index".
static func islands(mesh: NavigationMesh) -> Array[Dictionary]:
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
			var a := vertex_key(vertices[polygon[k]])
			var b := vertex_key(vertices[polygon[(k + 1) % polygon.size()]])
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
		out.append(_summarise(mesh, vertices, groups[root]))
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["area"]) > float(y["area"]))
	for index in range(out.size()):
		out[index]["index"] = index
	return out


static func _summarise(mesh: NavigationMesh, vertices: PackedVector3Array, polygons: PackedInt32Array) -> Dictionary:
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
	return {"area": area, "polygons": polygons, "bounds": bounds, "centre": weighted / maxf(area, 0.0001)}


## The island's triangles bucketed by [constant ISLAND_CELL] cell, for [method DotBotNav.on_island].
static func grid(mesh: NavigationMesh, island: Dictionary) -> Dictionary:
	var cells: Dictionary = {}
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
					if not cells.has(key):
						cells[key] = []
					cells[key].append(tri)
	return cells


## The height of the triangle (a, b, c) under [param at] seen from above, or NAN outside it.
static func height_in(at: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
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


static func edge_key(a: Vector3i, b: Vector3i) -> String:
	var forward := a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z)))
	return "%s|%s" % [a, b] if forward else "%s|%s" % [b, a]


static func vertex_key(v: Vector3) -> Vector3i:
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

