class_name DotBotDemoStore
extends RefCounted

## Where recorded episodes go. Every method returns a [DotResult] and may be a coroutine, so always await.
##
## The base refuses what it does not implement; a store overrides what it can do.

func open() -> DotResult:
	return DotResult.success(null)


func close() -> DotResult:
	return DotResult.success(null)


## Stores one batch; the value is how many were kept.
func append(_episodes: Array) -> DotResult:
	return _unsupported("append")


## The value is {key: verified count} for a map version and kind.
func counts(_map_id: String, _map_version: String, _kind: String) -> DotResult:
	return _unsupported("counts")


## The value is an Array of episodes, best score first.
func load(_map_id: String, _map_version: String, _kind: String, _key: String, _limit: int) -> DotResult:
	return _unsupported("load")


## Records a consumer's verdict on [param ids].
func mark(_ids: Array, _verified: bool, _score: float) -> DotResult:
	return _unsupported("mark")


## Deletes the episodes with these ids; the value is how many were there.
func remove(_ids: Array) -> DotResult:
	return _unsupported("remove")


## Drops the episodes of every other version of [param map_id]; the value is how many.
func prune(_map_id: String, _keep_version: String) -> DotResult:
	return _unsupported("prune")


func describe_lines() -> PackedStringArray:
	return PackedStringArray()


## The store [param config] names, not yet open; null for "off". A database setting without dot-sql installed is said at ERROR and the JSON store is used.
static func from_config(config: DotBotDemoConfig, host: Node = null) -> DotResult:
	match config.store:
		"off":
			return DotResult.success(null)
		"memory":
			return DotResult.success(DotBotDemoStoreMemory.new())
		"json":
			return DotResult.success(DotBotDemoStoreJson.new(config.path))
	# dot-sql is reached by path: naming DotSql would make a pack fail to parse on a host without it.
	var script_path := "res://addons/dot_sql/core/dot_sql.gd"
	if not ResourceLoader.exists(script_path):
		DotLog.error("bot.demo.store", "bot_record_store is %s but dot-sql is not installed; recording to files" % config.store)
		return DotResult.success(DotBotDemoStoreJson.new(config.path))
	var db := {"driver": "sqlite", "dialect": "sqlite", "path": config.path}
	if config.store == "sqlite":
		if config.path.get_extension() == "":
			db["path"] = config.path.path_join("demos.db")
		var made_dir := DotPaths.ensure_parent_dir(db["path"])
		if not made_dir.ok:
			return made_dir
	else:
		db = {"driver": "gateway", "dialect": config.store, "url": config.url, "token": config.token}
	var sql_script: Script = load(script_path)
	var made: DotResult = sql_script.call("from_config", db, host)
	if not made.ok or made.value == null:
		DotLog.error("bot.demo.store", "the demonstration database settings are not usable; recording to files")
		return DotResult.success(DotBotDemoStoreJson.new(config.path))
	return DotResult.success(DotBotDemoStoreSql.new(made.value))


func _unsupported(what: String) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This store does not support %s." % what)
