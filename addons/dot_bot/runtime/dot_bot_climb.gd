class_name DotBotClimb
extends RefCounted

## One ladder ride, shared by the brain and any game that steers its own stand-ins: face the ladder, push forward so the controller's ladder mode climbs, hop off at the top onto the landing (walking away while on it would descend).
##
## [method step] each tick with the feet position; apply the result to the command, and drop the climb when [code]done[/code].

## Longest a ladder is climbed before it is given up, seconds, and the longest spent stepping off the top.
const TIMEOUT := 20.0
const EXIT := 1.5

var box := AABB()
var to := Vector3.ZERO
var since := 0.0
var exit_since := NAN


## [param ladder] is a [method DotBotLinks.ladder_of] answer.
static func begin(ladder: Dictionary, now: float) -> DotBotClimb:
	var c := DotBotClimb.new()
	c.box = ladder["box"]
	c.to = ladder["to"]
	c.since = now
	return c


## `{"yaw": degrees, "move": Vector2, "jump": bool, "done": bool}`; with done set the rest is to be ignored.
func step(pos: Vector3, now: float) -> Dictionary:
	if now - since > TIMEOUT:
		return {"done": true}
	var target := to
	var hop := false
	if pos.y >= minf(to.y - 0.1, box.end.y + 0.02) and is_nan(exit_since):
		exit_since = now
		hop = true
	if is_nan(exit_since):
		target = Vector3(clampf(pos.x, box.position.x, box.end.x), 0.0, clampf(pos.z, box.position.z, box.end.z))
	elif Vector2(to.x - pos.x, to.z - pos.z).length() < 0.5 or now - exit_since > EXIT:
		return {"done": true}
	var flat := Vector2(target.x - pos.x, target.z - pos.z)
	var yaw := rad_to_deg(atan2(-flat.x, -flat.y)) if flat.length() > 0.01 else NAN
	return {"yaw": yaw, "move": Vector2(0.0, 1.0), "jump": hop, "done": false}
