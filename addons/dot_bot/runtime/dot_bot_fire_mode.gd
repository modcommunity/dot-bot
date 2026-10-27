class_name DotBotFireMode
extends RefCounted

## Which fire mode a bot should be in at a given range: auto up close, burst in the middle, semi far.

## Closer than this (metres) a bot sprays on full auto.
const CLOSE := 12.0
## Farther than this a bot takes single aimed shots; between the two it fires bursts.
const FAR := 30.0

## Replace to change the rule for a profile or game: `func(distance, modes) -> String`.
var rule: Callable = Callable()


## The mode from [param modes] (strings "auto", "semi", "burst") for [param distance], or "" when the gun
## offers a single mode. A mode the gun lacks falls to the nearest one it has.
func pick(distance: float, modes: PackedStringArray) -> String:
	if modes.size() < 2:
		return ""

	if rule.is_valid():
		var chosen := str(rule.call(distance, modes))
		return chosen if modes.has(chosen) else ""

	var order: Array = ["auto", "burst", "semi"]
	if distance >= FAR:
		order = ["semi", "burst", "auto"]
	elif distance >= CLOSE:
		order = ["burst", "semi", "auto"]
	for want in order:
		if modes.has(want):
			return want

	return ""
