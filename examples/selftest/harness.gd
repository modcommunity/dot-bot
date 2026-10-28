extends Node
## The counters and check helpers every part of the bot suite shares.


const TICK := 1.0 / 64.0

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _sql_ran := false
var _entered := 0
var _completed := 0


func _section(title: String) -> void:
	_entered += 1
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		var line := what if detail == "" else "%s (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
