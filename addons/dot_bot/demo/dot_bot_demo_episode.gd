class_name DotBotDemoEpisode
extends RefCounted

## One recorded stretch: what it is about, where a replay starts and the kept samples.
##
## Holds no name, account, peer number, address, team or chat, and the day is the finest time.

var id: int = 0
var map_id: String = ""
var map_version: String = ""
var schema_id: String = ""
var kind: String = ""
var key: String = ""

## The state a replay begins from, plain values only.
var start: Dictionary = {}

## The kept rate in Hz.
var rate: float = 0.0

## Observation then action per kept tick, one flat array.
var ticks: PackedFloat32Array = PackedFloat32Array()
var frame_size: int = 0
var outcome: String = ""

## UTC date, nothing finer.
var day: String = ""

## Filled by a consumer.
var verified: bool = false
var score: float = 0.0


func sample_count() -> int:
	return 0 if frame_size <= 0 else ticks.size() / frame_size


## About how many bytes this holds, for the recorder's queue cap.
func byte_size() -> int:
	return ticks.size() * 4 + 256


## Plain values only: floats as base64 of the float32 bytes, so it is JSON-safe.
func to_dictionary() -> Dictionary:
	return {
		"id": id, "map_id": map_id, "map_version": map_version, "schema_id": schema_id,
		"kind": kind, "key": key, "start": start, "rate": rate, "frame_size": frame_size,
		"ticks": Marshalls.raw_to_base64(ticks.to_byte_array()), "outcome": outcome, "day": day,
		"verified": verified, "score": score,
	}


static func from_dictionary(d: Dictionary) -> DotBotDemoEpisode:
	var e := DotBotDemoEpisode.new()
	e.id = int(d.get("id", 0))
	e.map_id = String(d.get("map_id", ""))
	e.map_version = String(d.get("map_version", ""))
	e.schema_id = String(d.get("schema_id", ""))
	e.kind = String(d.get("kind", ""))
	e.key = String(d.get("key", ""))
	e.start = (d.get("start", {}) as Dictionary).duplicate(true)
	e.rate = float(d.get("rate", 0.0))
	e.frame_size = int(d.get("frame_size", 0))
	e.ticks = Marshalls.base64_to_raw(String(d.get("ticks", ""))).to_float32_array()
	e.outcome = String(d.get("outcome", ""))
	e.day = String(d.get("day", ""))
	e.verified = bool(d.get("verified", false))
	e.score = float(d.get("score", 0.0))
	return e
