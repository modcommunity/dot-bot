@tool
class_name DotBotProfile
extends Resource

## How a bot plays, as numbers: how fast it reacts, how badly it aims at first and how fast
## that settles, how it moves while it fights.
##
## [b]A preset is a bundle of these, never a number of its own.[/b] "Hard" means nothing a
## server owner can reason about; "reacts in 0.21 s, opens 2.8 degrees off and settles to 0.7"
## does. So `easy`, `medium`, `hard` and `nightmare` are four columns of [constant SPEC], and
## every row is a cvar (`bot_<field>`) that stays individually overridable after a preset
## is chosen ([DotBotSettings]).
##
## [b]What the presets aim at.[/b] Medium is the default: an ordinary player who wins some
## fights. Hard is a good human: reaction about a fifth of a second, a first shot that is
## close but not on, strafing and peeking. Nightmare is beyond human, and still not a
## machine: its reaction stays above a tenth of a second and its aim never lands exactly,
## because a bot that reacts on the tick it sees you and never misses is not a harder
## opponent, it is a different game.
##
## [b]Every field is read by the brain[/b] ([DotBotBrain]); the suite checks that every row
## of [constant SPEC] names a property here, so a setting can not be decoration.

# No log channel: numbers, presets and their parsing. DotBotSettings logs the changes.

## The presets, in the order a menu lists them.
const PRESETS := ["easy", "medium", "hard", "nightmare"]

## The preset a bot uses when nobody chose one.
const DEFAULT_PRESET := "medium"

## Every setting: [code][field, min, max, easy, medium, hard, nightmare, help][/code].
##
## One table rather than four constructors, so adding a setting is one line and a preset
## can not forget it. The cvar is `bot_` + field.
const SPEC := [
	# Perception
	["reaction", 0.05, 3.0, 0.5, 0.3, 0.21, 0.12, "Seconds between first seeing somebody and pulling the trigger on them."],
	["notice", 0.0, 2.0, 0.35, 0.15, 0.12, 0.06, "Extra seconds to react to somebody 90 degrees off the view, scaled by how far off they are."],
	["fov", 30.0, 360.0, 90.0, 110.0, 120.0, 160.0, "View cone in degrees: nobody outside it is seen, only heard."],
	["sight", 5.0, 500.0, 35.0, 55.0, 75.0, 100.0, "Farthest the bot sees anybody, metres."],
	["hearing", 0.0, 200.0, 12.0, 22.0, 32.0, 45.0, "How far a gunshot is heard, metres; quieter sounds scale it down."],
	["through_walls", 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, "1 lets the bot see through walls. Off in every preset; for testing only."],
	["memory", 0.0, 60.0, 2.0, 4.0, 6.0, 10.0, "Seconds a target lost from sight is still hunted and pre-aimed."],
	# Aim
	["aim_error", 0.0, 30.0, 7.0, 4.0, 2.5, 1.2, "Degrees off the target at the start of an engagement."],
	["aim_settle", 0.05, 10.0, 1.0, 0.5, 0.4, 0.25, "Seconds for the aim error to halve while the fight goes on."],
	["aim_floor", 0.0, 15.0, 2.0, 1.0, 0.6, 0.3, "Degrees the aim error settles to: it swings between about half and all of this."],
	["flinch", 0.0, 30.0, 4.0, 3.0, 1.5, 0.6, "Degrees of aim error added each time the bot is hit."],
	["turn_rate", 30.0, 3600.0, 200.0, 450.0, 600.0, 1000.0, "Fastest the view turns, degrees per second."],
	["turn_smooth", 0.05, 1.0, 0.3, 0.55, 0.65, 0.85, "How quickly the view closes on where it wants to look (1 is fastest)."],
	["prediction", 0.0, 1.0, 0.25, 0.6, 0.75, 0.95, "How much of a moving target's motion is tracked rather than trailed."],
	["fire_cone", 0.5, 45.0, 7.0, 5.0, 3.0, 2.0, "Degrees the view may still be off its aim when the bot fires."],
	# Fighting
	["range", 1.0, 100.0, 8.0, 10.0, 12.0, 12.0, "Distance the bot likes to fight at, metres."],
	["max_range", 1.0, 500.0, 25.0, 35.0, 50.0, 70.0, "Farthest the bot opens fire from, metres."],
	["burst", 0.05, 5.0, 0.6, 0.35, 0.3, 0.35, "Seconds of trigger held per burst beyond burst_range."],
	["burst_pause", 0.0, 5.0, 0.6, 0.3, 0.22, 0.4, "Seconds between bursts beyond burst_range."],
	["burst_range", 0.0, 500.0, 12.0, 16.0, 18.0, 4.0, "Beyond this the bot fires in bursts; inside it, it holds the trigger."],
	["aggression", 0.0, 1.0, 0.3, 0.5, 0.6, 0.8, "How readily it chases a lost target or a sound instead of holding."],
	["cover", 0.0, 1.0, 0.1, 0.3, 0.6, 0.7, "Chance of backing out of a fight when badly hurt."],
	["grenades", 0.0, 1.0, 0.0, 0.2, 0.5, 0.7, "Chance of throwing at a target that just went behind cover."],
	# Movement
	["strafe", 0.0, 1.0, 0.15, 0.55, 0.85, 1.0, "Chance of strafing while fighting, per change of direction."],
	["strafe_time", 0.1, 5.0, 1.5, 0.9, 0.6, 0.45, "Average seconds between changes of strafe direction."],
	["stop_to_shoot", 0.0, 1.0, 0.0, 0.35, 0.6, 0.8, "Chance per engagement of standing still for long-range bursts."],
	["peek", 0.0, 1.0, 0.0, 0.3, 0.7, 0.9, "Chance of pre-aiming and re-peeking where a target was lost."],
	["crouch", 0.0, 1.0, 0.15, 0.3, 0.4, 0.3, "Chance per engagement of crouching for long-range fire."],
	["jump", 0.0, 2.0, 0.0, 0.05, 0.15, 0.2, "Jumps per second while fighting up close."],
	["slide", 0.0, 1.0, 0.12, 0.3, 0.5, 0.75, "Chance per chance of sliding at a run: closing on a fight, chasing, breaking away."],
	["wall_run", 0.0, 1.0, 0.05, 0.2, 0.4, 0.7, "Chance of taking a wall it runs beside: a slide, a jump, and a run along it."],
	["air_jump", 0.0, 1.0, 0.0, 0.1, 0.35, 0.6, "Chance of using the air-jump to flee when hurt, or to reach a target above (only where the game has it on)."],
	["trick_chain", 0.0, 1.0, 0.05, 0.25, 0.55, 0.85, "Chance one trick leads straight into the next (slide, jump, wall run, wall jump)."],
	["trick_delay", 0.0, 2.0, 0.6, 0.35, 0.2, 0.1, "Seconds between seeing the chance for a trick and starting it."],
	["cover_crouch", 0.0, 1.0, 0.25, 0.45, 0.55, 0.6, "Chance of ducking in cover when pulling back or waiting out a lost target."],
	["map_knowledge", 0.0, 1.0, 0.1, 0.4, 0.7, 1.0, "Chance a roaming bot heads where it last knew of an enemy instead of anywhere."],
	# Humanisation: every one is 0 for the old, exact behaviour.
	["react_jitter", 0.0, 2.0, 0.5, 0.3, 0.3, 0.25, "How unevenly the reaction time varies between sightings (0 is the plain 15 percent either way)."],
	["overshoot", 0.0, 1.0, 0.6, 0.4, 0.4, 0.3, "How far a fast turn onto a target swings past it before coming back (0 is none)."],
	["track_lag", 0.0, 0.5, 0.12, 0.05, 0.04, 0.03, "Seconds the bot takes to notice a target changed direction (it aims with the old velocity meanwhile)."],
	["strafe_jitter", 0.0, 1.0, 0.6, 0.6, 0.5, 0.4, "How irregular strafing is: uneven lengths, pauses, easing into a change of direction (0 is a metronome)."],
	["glance", 0.0, 1.0, 0.8, 0.6, 0.5, 0.4, "How often a roaming bot turns its head to look aside and holds the look (0 never)."],
	["hesitate", 0.0, 2.0, 0.35, 0.2, 0.12, 0.06, "Seconds a bot may stand still when it first sights somebody before it starts moving."],
	["hurt_delay", 0.0, 1.0, 0.25, 0.15, 0.1, 0.06, "Seconds before a bot that was hit turns toward the shooter (0 is instant)."],
]

## SPEC's columns.
const COL_FIELD := 0
const COL_MIN := 1
const COL_MAX := 2
const COL_FIRST_PRESET := 3
const COL_HELP := 7

@export var preset_name: String = DEFAULT_PRESET

@export_group("Perception")
@export var reaction: float = 0.3
@export var notice: float = 0.15
@export var fov: float = 110.0
@export var sight: float = 55.0
@export var hearing: float = 22.0
@export var through_walls: float = 0.0
@export var memory: float = 4.0

@export_group("Aim")
@export var aim_error: float = 4.0
@export var aim_settle: float = 0.5
@export var aim_floor: float = 1.0
@export var flinch: float = 3.0
@export var turn_rate: float = 450.0
@export var turn_smooth: float = 0.55
@export var prediction: float = 0.6
@export var fire_cone: float = 5.0

@export_group("Fighting")
@export var range: float = 10.0
@export var max_range: float = 35.0
@export var burst: float = 0.35
@export var burst_pause: float = 0.3
@export var burst_range: float = 16.0
@export var aggression: float = 0.5
@export var cover: float = 0.3
@export var grenades: float = 0.2

@export_group("Movement")
@export var strafe: float = 0.55
@export var strafe_time: float = 0.9
@export var stop_to_shoot: float = 0.35
@export var peek: float = 0.3
@export var crouch: float = 0.3
@export var jump: float = 0.05
@export var slide: float = 0.3
@export var wall_run: float = 0.2
@export var air_jump: float = 0.1
@export var trick_chain: float = 0.25
@export var trick_delay: float = 0.35
@export var cover_crouch: float = 0.45
@export var map_knowledge: float = 0.4

@export_group("Humanisation")
@export var react_jitter: float = 0.3
@export var overshoot: float = 0.4
@export var track_lag: float = 0.05
@export var strafe_jitter: float = 0.6
@export var glance: float = 0.6
@export var hesitate: float = 0.2
@export var hurt_delay: float = 0.15


## A profile set to [param name]'s column, or null for a name that is not a preset.
static func preset(name: String) -> DotBotProfile:
	var column := preset_column(name)
	if column < 0:
		return null
	var out := DotBotProfile.new()
	out.apply_preset(name)
	return out


## The SPEC column for a preset name, or -1.
static func preset_column(name: String) -> int:
	var index := PRESETS.find(name.strip_edges().to_lower())
	return COL_FIRST_PRESET + index if index >= 0 else -1


## Every field name, in SPEC order.
static func fields() -> PackedStringArray:
	var out := PackedStringArray()
	for row: Array in SPEC:
		out.append(String(row[COL_FIELD]))
	return out


## The SPEC row for [param field], or an empty array.
static func spec_for(field: String) -> Array:
	for row: Array in SPEC:
		if row[COL_FIELD] == field:
			return row
	return []


## What preset [param name] gives [param field], or NAN.
static func preset_value(name: String, field: String) -> float:
	var column := preset_column(name)
	var row := spec_for(field)
	if column < 0 or row.is_empty():
		return NAN
	return float(row[column])


## Every field to [param name]'s column. A name that is not a preset is refused and nothing
## changes, so a typo leaves the bots as they were rather than half-changed.
func apply_preset(name: String) -> DotResult:
	var column := preset_column(name)
	if column < 0:
		return DotResult.fail(DotError.CODE_INVALID, "bot_difficulty is %s, not '%s'." % [", ".join(PRESETS), name])
	for row: Array in SPEC:
		set(StringName(row[COL_FIELD]), float(row[column]))
	preset_name = name.strip_edges().to_lower()
	return DotResult.success(preset_name)


## Sets one field from text, clamped to its range. Refuses an unknown field or a non-number.
func set_field(field: String, text: String) -> DotResult:
	var row := spec_for(field)
	if row.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "no bot setting '%s'" % field)
	var clean := text.strip_edges()
	if not clean.is_valid_float():
		return DotResult.fail(DotError.CODE_INVALID, "bot_%s takes a number, not '%s'" % [field, text])
	var value := clampf(clean.to_float(), float(row[COL_MIN]), float(row[COL_MAX]))
	set(StringName(field), value)
	return DotResult.success(value)


func get_field(field: String) -> float:
	return float(get(StringName(field)))


## A copy that shares nothing with this one.
func copy() -> DotBotProfile:
	var out := DotBotProfile.new()
	out.preset_name = preset_name
	for field in fields():
		out.set(StringName(field), get_field(field))
	return out


func to_dictionary() -> Dictionary:
	var out := {"preset": preset_name}
	for field in fields():
		out[field] = get_field(field)
	return out


func describe() -> Dictionary:
	return to_dictionary()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["preset %s" % preset_name])
	for field in fields():
		out.append("  bot_%-14s %s" % [field, _fmt(get_field(field))])
	return out


static func _fmt(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(roundf(value)))
	return str(snappedf(value, 0.001))
