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


## Drops the episodes of every other version of [param map_id]; the value is how many.
func prune(_map_id: String, _keep_version: String) -> DotResult:
	return _unsupported("prune")


func describe_lines() -> PackedStringArray:
	return PackedStringArray()


func _unsupported(what: String) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This store does not support %s." % what)
