class_name DotBotDemoStoreSql
extends DotBotDemoStore

## Episodes in a database through a dot-sql driver, held untyped so dot-bot does not need dot-sql.
##
## The driver is anything with query, execute, batch, migrate and is_open (dot-sql's SQLite
## driver, or its HTTP gateway for PostgreSQL and MySQL). The column is [code]edge_key[/code]
## because [code]key[/code] is reserved in one dialect.

const CHANNEL := "bot.demo.store"
const COMPONENT := "dot-bot:demos"
const TABLE := "dot_bot_demos"
const COLUMNS := "id, map_id, map_version, schema_id, kind, edge_key, day, rate, frame_size, outcome, verified, score, start, ticks"

## The dot-sql driver, not yet open.
var driver = null

var _last_id: int = 0


func _init(p_driver: Variant = null) -> void:
	driver = p_driver


## The migration steps; append a step, never edit one.
static func migration_steps() -> Array:
	return [[{
		"name": TABLE,
		"columns": [
			{"name": "id", "type": "bigint", "null": false},
			{"name": "map_id", "type": "key", "null": false},
			{"name": "map_version", "type": "key", "null": false},
			{"name": "schema_id", "type": "key", "null": false},
			{"name": "kind", "type": "key", "null": false},
			{"name": "edge_key", "type": "key", "null": false},
			{"name": "day", "type": "key", "null": false},
			{"name": "rate", "type": "real", "null": false, "default": 0},
			{"name": "frame_size", "type": "int", "null": false, "default": 0},
			{"name": "outcome", "type": "key", "null": false},
			{"name": "verified", "type": "int", "null": false, "default": 0},
			{"name": "score", "type": "real", "null": false, "default": 0},
			{"name": "start", "type": "json"},
			{"name": "ticks", "type": "text"},
		],
		"primary_key": ["id"],
		"indexes": [{"name": "dot_bot_demos_by_edge", "columns": ["map_id", "map_version", "kind", "edge_key", "score"]}],
	}]]


func open() -> DotResult:
	if driver == null:
		return DotResult.fail(DotError.CODE_STATE, "No SQL driver.")
	var available: DotResult = driver.is_available()
	if not available.ok:
		return available
	var opened: DotResult = await driver.open()
	if not opened.ok:
		return opened
	var migrated: DotResult = await driver.migrate(COMPONENT, migration_steps())
	if not migrated.ok:
		return migrated.wrap("Could not prepare the demonstration table.")
	return DotResult.success(true)


func close() -> DotResult:
	if driver != null:
		driver.close()
	return DotResult.success(null)


func append(batch: Array) -> DotResult:
	var statements: Array = []
	var sql := "INSERT INTO %s (%s) VALUES (%s)" % [TABLE, COLUMNS, ", ".join(_marks(14))]
	for item: Variant in batch:
		var e := item as DotBotDemoEpisode
		if e == null:
			return DotResult.fail(DotError.CODE_INVALID, "A store holds DotBotDemoEpisode, not %s." % type_string(typeof(item)))
		e.id = _new_id()
		statements.append([sql, [
			e.id, e.map_id, e.map_version, e.schema_id, e.kind, e.key, e.day, e.rate, e.frame_size,
			e.outcome, 1 if e.verified else 0, e.score, JSON.stringify(e.start),
			Marshalls.raw_to_base64(e.ticks.to_byte_array()),
		]])
	var res: DotResult = await driver.batch(statements)
	if not res.ok:
		return res.wrap("Could not store %d episodes." % batch.size())
	return DotResult.success(batch.size())


func counts(map_id: String, map_version: String, kind: String) -> DotResult:
	var res: DotResult = await driver.query(
		"SELECT edge_key, verified, COUNT(*) AS n FROM %s WHERE map_id = ? AND map_version = ? AND kind = ? GROUP BY edge_key, verified" % TABLE,
		[map_id, map_version, kind])
	if not res.ok:
		return res
	var out := {}
	for row: Dictionary in res.value:
		var key := str(row["edge_key"])
		out[key] = int(out.get(key, 0)) + (int(row["n"]) if int(row["verified"]) != 0 else 0)
	return DotResult.success(out)


func load(map_id: String, map_version: String, kind: String, key: String, limit: int) -> DotResult:
	var sql := "SELECT %s FROM %s WHERE map_id = ? AND map_version = ? AND kind = ? AND edge_key = ? ORDER BY score DESC, id" % [COLUMNS, TABLE]
	var params: Array = [map_id, map_version, kind, key]
	if limit > 0:
		sql += " LIMIT ?"
		params.append(limit)
	var res: DotResult = await driver.query(sql, params)
	if not res.ok:
		return res
	var out: Array = []
	for row: Dictionary in res.value:
		out.append(DotBotDemoStoreSql._episode(row))
	return DotResult.success(out)


func mark(ids: Array, verified: bool, score: float) -> DotResult:
	var changed := 0
	for i in range(0, ids.size(), 50):
		var part: Array = ids.slice(i, i + 50)
		var params: Array = [1 if verified else 0, score]
		params.append_array(part)
		var res: DotResult = await driver.execute(
			"UPDATE %s SET verified = ?, score = ? WHERE id IN (%s)" % [TABLE, ", ".join(_marks(part.size()))], params)
		if not res.ok:
			return res
		changed += part.size()
	return DotResult.success(changed)


func remove(ids: Array) -> DotResult:
	var gone := 0
	for i in range(0, ids.size(), 50):
		var part: Array = ids.slice(i, i + 50)
		var res: DotResult = await driver.execute(
			"DELETE FROM %s WHERE id IN (%s)" % [TABLE, ", ".join(_marks(part.size()))], part)
		if not res.ok:
			return res
		gone += part.size()
	return DotResult.success(gone)


func prune(map_id: String, keep_version: String) -> DotResult:
	var seen: DotResult = await driver.query_value(
		"SELECT COUNT(*) FROM %s WHERE map_id = ? AND map_version <> ?" % TABLE, [map_id, keep_version], 0)
	if not seen.ok:
		return seen
	var res: DotResult = await driver.execute(
		"DELETE FROM %s WHERE map_id = ? AND map_version <> ?" % TABLE, [map_id, keep_version])
	if not res.ok:
		return res
	return DotResult.success(int(seen.value))


func describe_lines() -> PackedStringArray:
	var name := str(driver.driver_name()) if driver != null else "none"
	return PackedStringArray(["store sql: driver %s, table %s" % [name, TABLE]])


## Unique across restarts and servers sharing a database, without a round trip.
func _new_id() -> int:
	_last_id = maxi(_last_id + 1, int(Time.get_unix_time_from_system() * 1000.0))
	return _last_id


static func _marks(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append("?")
	return out


static func _episode(row: Dictionary) -> DotBotDemoEpisode:
	var e := DotBotDemoEpisode.new()
	e.id = int(row["id"])
	e.map_id = str(row["map_id"])
	e.map_version = str(row["map_version"])
	e.schema_id = str(row["schema_id"])
	e.kind = str(row["kind"])
	e.key = str(row["edge_key"])
	e.day = str(row["day"])
	e.rate = float(row["rate"])
	e.frame_size = int(row["frame_size"])
	e.outcome = str(row["outcome"])
	e.verified = int(row["verified"]) != 0
	e.score = float(row["score"])
	var parsed: Variant = JSON.parse_string(str(row.get("start", "")))
	e.start = parsed if parsed is Dictionary else {}
	e.ticks = Marshalls.base64_to_raw(str(row.get("ticks", ""))).to_float32_array()
	return e
