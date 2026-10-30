class_name DotBotIntent
extends RefCounted

## What a bot would press this tick: a view, a movement stick and its buttons.
##
## [b]A bot is a player driven by the commands a client sends.[/b] So this is nothing but the
## content of those commands, and [method write_move] and [method write_fire] copy it into the
## game's own (dot-player-controller's [code]DotFpsCommand[/code], dot-weapon's
## [code]DotWeaponCommand[/code]) by duck typing, reading the button bits from the command's
## own script so this addon names neither. A bot can then never do anything a person could
## not: it walks through the same motor, shoots through the same arsenal, and is refused by
## the same checks.

# No log channel: a record.

## Degrees, the command's convention ([member DotBotContact.view_yaw]).
var yaw: float = 0.0
var pitch: float = 0.0

## Local movement: x strafes right, y moves forward. Length at most 1.
var move: Vector2 = Vector2.ZERO

var fire: bool = false
var crouch: bool = false
var jump: bool = false
var walk: bool = false

## Press the game's air-jump (a launch into the air) this tick. Written only where the game
## names the button, see [method write_move].
var air_jump: bool = false

## Throw a grenade (or whatever a game's throwable is) along the view this tick.
var throw: bool = false

## The ride edge the bot's route reached this tick ([method DotBotWorld.route_detail]), or -1. A
## game that rides it hands the movement half of the command to its surf pilot until the ride
## ends, keeping the view and the trigger the brain's, and tells the brain
## ([method DotBotBrain.ride_ended]).
var ride: int = -1

## Whom the bot is fighting, or -1.
var target_id: int = -1

## What the brain is doing, for describe() and a suite: fight, search, listen, roam, retreat, dead.
var state: StringName = &"roam"


## Copies the view, the movement and the movement buttons into [param command].
## [param air_jump_button] is the constant name a game's air-jump uses, when it has one.
func write_move(command: Object, air_jump_button: String = "") -> void:
	if command == null:
		return
	command.set(&"yaw", yaw)
	command.set(&"pitch", pitch)
	command.set(&"move", move.limit_length(1.0))
	_button(command, "BUTTON_CROUCH", crouch)
	_button(command, "BUTTON_JUMP", jump)
	_button(command, "BUTTON_WALK", walk)
	if air_jump_button != "":
		_button(command, air_jump_button, air_jump)


## Copies the view and the trigger into [param command]. [param throw_button] is the
## constant name a game's throw uses, when it has one.
func write_fire(command: Object, throw_button: String = "") -> void:
	if command == null:
		return
	command.set(&"yaw", yaw)
	command.set(&"pitch", pitch)
	_button(command, "BUTTON_ATTACK", fire)
	if throw_button != "":
		_button(command, throw_button, throw)


static func _button(command: Object, constant: String, pressed: bool) -> void:
	var script: Variant = command.get_script()
	if not (script is Script) or not command.has_method(&"set_button"):
		return
	var constants := (script as Script).get_script_constant_map()
	if constants.has(constant):
		command.call(&"set_button", int(constants[constant]), pressed)


## The direction the intent looks along, -Z forward at yaw 0.
func forward() -> Vector3:
	return DotBotIntent.direction(yaw, pitch)


static func direction(p_yaw: float, p_pitch: float) -> Vector3:
	var y := deg_to_rad(p_yaw)
	var p := deg_to_rad(p_pitch)
	return Vector3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p))


func describe() -> Dictionary:
	return {
		"state": state, "target": target_id, "yaw": snappedf(yaw, 0.1), "pitch": snappedf(pitch, 0.1),
		"move": move, "fire": fire, "crouch": crouch, "jump": jump, "throw": throw, "ride": ride,
	}
