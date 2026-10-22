class_name DotBotDemoRecorder
extends RefCounted

## Records what players do on the server as episodes in a schema the host declares, for bots to learn from.
##
## [b]The host says what an episode is[/b] ([method begin], [method sample], [method end],
## [method cancel]); the recorder only decides what to keep. [b]Never on a client[/b]:
## without [member is_server] it is a no-op. [b]Never a name or id[/b]: a subject is any
## value the host likes, mapped to an in-memory counter that is not written. The sample rate
## falls as a key's verified count rises ([method rate_for]), and finished episodes leave the
## tick through a queue that [method process] writes within a time budget.

const CHANNEL := "dot.bot.demo"

## The queue's size above which the oldest episode is dropped.
const QUEUE_MAX_BYTES := 4 * 1024 * 1024

## Episodes per store call.
const CHUNK := 8

## The host's tick rate, which sets the stride and the top rate.
var tick_rate: float = 64.0

## Recording happens only where the authoritative motor runs.
var is_server: bool = false

var map_id: String = ""
var map_version: String = ""

## [code]func(subject) -> bool[/code]; false refuses the episode. Set it to refuse bots.
var include_fn: Callable = Callable()

## The most [method process] spends writing in one call.
var write_budget_usec: int = 2000

var config: DotBotDemoConfig
var store: DotBotDemoStore

var recorded: int = 0
var dropped: int = 0
var refused: int = 0
var capped: int = 0
var written: int = 0
var write_errors: int = 0
var bad_samples: int = 0

var _schemas: Dictionary = {}
var _masks: Dictionary = {}
var _active: Dictionary = {}
var _counts: Dictionary = {}
var _kept: Dictionary = {}
var _queue: Array = []
var _queue_bytes: int = 0
var _batch: Array = []
var _busy: bool = false
var _since_flush: float = 0.0
var _was_on: bool = true
var _ordinal: int = 0


## One subject's open episode.
class Active:
	extends RefCounted
	var schema: DotBotDemoSchema
	var key: String = ""
	var start: Dictionary = {}
	var rate: float = 0.0
	var stride: int = 1
	var gap: int = 0
	var last_tick: int = -1
	var last_obs: PackedFloat32Array = PackedFloat32Array()
	var sums: PackedFloat32Array = PackedFloat32Array()
	var modes: Array = []
	var frames: PackedFloat32Array = PackedFloat32Array()


func _init(p_config: DotBotDemoConfig = null, p_store: DotBotDemoStore = null) -> void:
	config = p_config if p_config != null else DotBotDemoConfig.new()
	store = p_store


## Declares a kind of episode; the recorder will refuse to begin one that is not.
func register(schema: DotBotDemoSchema) -> DotResult:
	var valid := schema.validate()
	if not valid.ok:
		return valid.wrap("Cannot record that schema.")
	_schemas[schema.kind] = schema
	var mask := PackedByteArray()
	for row: Array in schema.action:
		for _i in int(row[DotBotDemoSchema.COL_SIZE]):
			mask.append(1 if bool(row[DotBotDemoSchema.COL_DISCRETE]) else 0)
	_masks[schema.kind] = mask
	return DotResult.success(schema)


## A new map (or content version): forgets the tallies. Follow with [method load_counts].
func set_map(p_map_id: String, p_map_version: String) -> void:
	cancel_all()
	map_id = p_map_id
	map_version = p_map_version
	_counts.clear()
	_kept.clear()


## Reads each kind's verified counts from the store, once per map load.
func load_counts() -> DotResult:
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store to read counts from.")
	for kind: String in _schemas:
		var res: DotResult = await store.counts(map_id, map_version, kind)
		if not res.ok:
			return res.wrap("Cannot read the %s counts." % kind)
		_counts[kind] = (res.value as Dictionary).duplicate()
	return DotResult.success(null)


## A consumer verified [param n] more episodes of a key, which lowers its rate.
func note_verified(kind: String, key: String, n: int = 1) -> void:
	var per: Dictionary = _counts.get(kind, {})
	per[key] = int(per.get(key, 0)) + n
	_counts[kind] = per


## True when this would record now.
func is_on() -> bool:
	return is_server and config.record and store != null


## Hz for the next episode of a key: the base rate up to the top rate while it has few verified.
func rate_for(kind: String, key: String) -> float:
	var verified := float(int((_counts.get(kind, {}) as Dictionary).get(key, 0)))
	var top := config.effective_rate_max(tick_rate)
	return config.rate + (top - config.rate) * maxf(0.0, 1.0 - verified / float(maxi(1, config.target)))


## Every this-many ticks a sample is kept at [param hz].
func stride_for(hz: float) -> int:
	return maxi(1, roundi(tick_rate / maxf(hz, 0.001)))


## Starts an episode for [param subject]; fails when recording is off, the kind is unknown or filtered, or the subject refused.
func begin(subject: Variant, kind: String, key: String = "", start: Dictionary = {}) -> DotResult:
	if not is_server:
		return DotResult.fail(DotError.CODE_UNSUPPORTED, "Only the server records.")
	if not config.record:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Recording is off (bot_record 0).")
	if store == null:
		return DotResult.fail(DotError.CODE_STATE, "No store to record into.")
	if not _schemas.has(kind):
		return DotResult.fail(DotError.CODE_INVALID, "Kind '%s' has no registered schema." % kind)
	if not config.records_kind(kind):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Kind '%s' is not in bot_record_kinds." % kind)
	if include_fn.is_valid() and not bool(include_fn.call(subject)):
		refused += 1
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That subject is not recorded.")
	if key != "" and _is_full(kind, key):
		capped += 1
		return DotResult.fail(DotError.CODE_QUOTA, "Key '%s' already has %d episodes." % [key, config.cap])
	var a := Active.new()
	a.schema = _schemas[kind]
	a.key = key
	a.start = start.duplicate(true)
	a.rate = rate_for(kind, key)
	a.stride = stride_for(a.rate)
	a.sums.resize(a.schema.action_size())
	if a.schema.has_discrete():
		for _i in a.schema.action_size():
			a.modes.append({})
	_ordinal += 1
	_active[subject] = a
	return DotResult.success(null)


## Offers one tick; true when it was kept (every [method stride_for]th). The action kept is the one held over the gap.
func sample(subject: Variant, observation: PackedFloat32Array, action: PackedFloat32Array, tick: int = -1) -> bool:
	var a: Active = _active.get(subject)
	if a == null:
		return false
	if observation.size() != a.schema.observation_size() or action.size() != a.sums.size():
		bad_samples += 1
		return false
	if tick >= 0:
		if tick == a.last_tick:
			return false
		a.last_tick = tick
	var mask: PackedByteArray = _masks[a.schema.kind]
	for i in action.size():
		if mask[i] == 1:
			var m: Dictionary = a.modes[i]
			m[action[i]] = int(m.get(action[i], 0)) + 1
		else:
			a.sums[i] += action[i]
	a.gap += 1
	a.last_obs = observation.duplicate()
	if a.gap < a.stride:
		return false
	_emit(a)
	return true


## Finishes the episode and queues it, unless the outcome is not one the kind keeps or its key is full.
func end(subject: Variant, outcome: String, key: String = "") -> DotResult:
	var a: Active = _active.get(subject)
	if a == null:
		return DotResult.fail(DotError.CODE_STATE, "That subject has no episode open.")
	_active.erase(subject)
	if a.gap > 0:
		_emit(a)
	var final_key := key if key != "" else a.key
	if a.frames.is_empty() or not a.schema.keeps(outcome):
		return DotResult.fail(DotError.CODE_CANCELLED, "Outcome '%s' is not kept." % outcome)
	if _is_full(a.schema.kind, final_key):
		capped += 1
		return DotResult.fail(DotError.CODE_QUOTA, "Key '%s' already has %d episodes." % [final_key, config.cap])
	var e := DotBotDemoEpisode.new()
	e.map_id = map_id
	e.map_version = map_version
	e.schema_id = a.schema.schema_id()
	e.kind = a.schema.kind
	e.key = final_key
	e.start = a.start
	e.rate = tick_rate / float(a.stride)
	e.ticks = a.frames
	e.frame_size = a.schema.frame_size()
	e.outcome = outcome
	e.day = Time.get_date_string_from_system(true)
	var per: Dictionary = _kept.get(e.kind, {})
	per[final_key] = int(per.get(final_key, 0)) + 1
	_kept[e.kind] = per
	_enqueue(e)
	recorded += 1
	return DotResult.success(null)


## Drops the subject's open episode (a teleport, a disconnect, a round end).
func cancel(subject: Variant) -> void:
	_active.erase(subject)


func cancel_all() -> void:
	_active.clear()


func is_recording(subject: Variant) -> bool:
	return _active.has(subject)


func queued() -> int:
	return _queue.size() + _batch.size()


func queued_bytes() -> int:
	return _queue_bytes


## Call every frame with the frame time: starts a flush when due and writes within [member write_budget_usec].
func process(delta: float) -> void:
	var on := is_on()
	if _was_on and not on:
		_active.clear()
		_since_flush = config.flush
	_was_on = on
	if store == null:
		return
	_since_flush += delta
	if _since_flush >= config.flush and not _queue.is_empty() and _batch.is_empty():
		_since_flush = 0.0
		_batch = _queue
		_queue = []
		_queue_bytes = 0
	if not _batch.is_empty() and not _busy:
		_write_some(write_budget_usec)


## Writes everything queued now, whatever the budget; for shutdown.
func flush_all() -> DotResult:
	_batch.append_array(_queue)
	_queue = []
	_queue_bytes = 0
	if _busy:
		return DotResult.fail(DotError.CODE_STATE, "A write is already in flight.")
	await _write_some(0x7fffffff)
	return DotResult.success(written)


func describe() -> String:
	return "demo recorder %s, %d open, %d queued, %d written, %d dropped" % [
		"ON" if is_on() else "off", _active.size(), queued(), written, dropped]


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("recording: %s%s" % ["ON" if is_on() else "off", "" if is_server else " (not a server)"])
	out.append("map: %s @ %s" % [map_id, map_version])
	for kind: String in _schemas:
		out.append("kind %s: %s, %d keys counted" % [kind, (_schemas[kind] as DotBotDemoSchema).describe(), (_counts.get(kind, {}) as Dictionary).size()])
		for key: String in (_counts.get(kind, {}) as Dictionary):
			out.append("  %s: %d verified, %.1f Hz" % [key if key != "" else "(none)", int(_counts[kind][key]), rate_for(kind, key)])
	out.append("open %d, queued %d (%d bytes), written %d, recorded %d" % [_active.size(), queued(), _queue_bytes, written, recorded])
	out.append("dropped %d, refused %d, capped %d, write errors %d, bad samples %d" % [dropped, refused, capped, write_errors, bad_samples])
	return out


func _is_full(kind: String, key: String) -> bool:
	var kept := int((_kept.get(kind, {}) as Dictionary).get(key, 0))
	return kept + int((_counts.get(kind, {}) as Dictionary).get(key, 0)) >= config.cap


func _emit(a: Active) -> void:
	var mask: PackedByteArray = _masks[a.schema.kind]
	var window := float(maxi(1, a.gap))
	a.frames.append_array(a.last_obs)
	for i in a.sums.size():
		if mask[i] == 1:
			var best := 0.0
			var best_n := 0
			for v: float in a.modes[i]:
				var n := int((a.modes[i] as Dictionary)[v])
				if n > best_n:
					best = v
					best_n = n
			a.frames.append(best)
			(a.modes[i] as Dictionary).clear()
		else:
			a.frames.append(a.sums[i] / window)
			a.sums[i] = 0.0
	a.gap = 0


func _enqueue(e: DotBotDemoEpisode) -> void:
	_queue.append(e)
	_queue_bytes += e.byte_size()
	while _queue_bytes > QUEUE_MAX_BYTES and _queue.size() > 1:
		var old: DotBotDemoEpisode = _queue.pop_front()
		_queue_bytes -= old.byte_size()
		dropped += 1
		DotLog.warn(CHANNEL, "Queue is over its cap; dropped the oldest episode.", {"dropped": dropped})


func _write_some(budget_usec: int) -> void:
	_busy = true
	var t0 := Time.get_ticks_usec()
	while not _batch.is_empty():
		var chunk: Array = _batch.slice(0, CHUNK)
		var res: DotResult = await store.append(chunk)
		if not res.ok:
			write_errors += 1
			DotLog.warn(CHANNEL, "Could not write %d episodes: %s" % [chunk.size(), res.error.message])
			_queue = _batch + _queue
			_batch = []
			_queue_bytes = 0
			for e: DotBotDemoEpisode in _queue:
				_queue_bytes += e.byte_size()
			break
		_batch = _batch.slice(chunk.size())
		written += chunk.size()
		if Time.get_ticks_usec() - t0 >= budget_usec:
			break
	_busy = false
