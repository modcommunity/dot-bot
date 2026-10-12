This is the **bot** asset for TMC's **Dot** collection. It adds player bots: a brain that plays like a person, difficulty presets, names and a roster.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## What it does
A bot here is a player. Each tick the brain decides what a person would press (where to look, how to move, whether to shoot, crouch, jump or throw) and your game turns that into the same movement and weapon commands a client sends. The bot walks through your movement code and shoots through your weapons, so it can never do something a player could not.

The brain sees only what is inside its view cone and in line of sight, and hears gunshots within its hearing range. It reacts after a delay, its first shots miss by a few degrees and get better as the fight goes on, and its view turns at a limited speed. It keeps a preferred range, strafes, fires in bursts at range, can stop or crouch for a long burst, backs out when badly hurt, pre-aims and re-peeks the corner a target went behind, throws a grenade at somebody who just took cover, and roams toward where it last knew of an enemy.

How well it does all that is a profile of about thirty numbers. Four presets (`easy`, `medium`, `hard`, `nightmare`) fill them in, and every number is its own cvar, so a server owner can pick a preset and then change any single setting.

It also has a pool of bot names, so a scoreboard never shows "Bot 2", and a roster that adds or removes bots to reach a count (dot-server's `DotBotQuota` says what the count is).

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The easiest way to get this addon and the ones it needs is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons into each one.

To add it to your own project by hand, copy `addons/dot_bot/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into it and enable dot-bot in **Project → Project Settings → Plugins**. dot-core is the only dependency.

## Using it

```gdscript
# The world: what a bot may know. Set the callables, or extend DotBotWorld.
var world := DotBotWorld.new()
world.contacts_fn = func() -> Array: return my_players_as_contacts()   # Array of DotBotContact
world.line_of_sight_fn = func(a: Vector3, b: Vector3) -> bool: return trace.line_of_sight(a, b)
world.waypoints_fn = func() -> PackedVector3Array: return spawn_points
# Optional: a walkable way between two places (a navigation graph's corners), so a bot does not
# walk into the wall between it and a waypoint; and how fast the held weapon's shot flies, so a
# rocket is led. Without them a bot walks straight and aims every weapon as hitscan.
world.route_fn = func(from: Vector3, to: Vector3) -> PackedVector3Array: return nav.path(from, to)
world.projectile_speed_fn = func(shooter: DotBotContact) -> float: return held_weapon_speed(shooter)

# Every gunshot, so bots can hear it.
world.emit_sound(shooter_position, 1.0, shooter_id, now)

# One brain per bot, sharing the game's settings.
var brain := DotBotBrain.new(bot_id, DotBotSettings.of(game))

# Each tick: what it would press, written into your own commands.
var intent := brain.think(me_as_contact, world, now)
intent.write_move(move_command)     # yaw, pitch, move, crouch, jump
intent.write_fire(fire_command)     # yaw, pitch, attack

# When it is hit.
brain.hurt(attacker_eye_position, now)
```

`write_move` and `write_fire` read the button bits from your command's own constants (`BUTTON_ATTACK`, `BUTTON_CROUCH`, `BUTTON_JUMP`), so dot-player-controller's `DotFpsCommand` and dot-weapon's `DotWeaponCommand` work as they are.

A game that already decides what its bots do can use just the aiming part, so its bots still turn, miss and react like the presets say:

```gdscript
var aim := DotBotAim.new(bot_id, DotBotSettings.of(game))
aim.view_from(body_yaw, body_pitch)                 # each tick, the view going into it
aim.engage(target_id, eye, target_chest, now)        # each tick it can see its target
var view := aim.track(eye, target_chest, target_velocity, now, delta)
command.yaw = view.x
command.pitch = view.y
fire = aim.trigger(now, eye.distance_to(target_chest))
```

On a server, register the cvars on your module. In a solo game, add them to the player's console:

```gdscript
DotBotSettings.of(game).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)   # dot-server module
DotBotSettings.of(game).bind_console(local_console)                                 # dot-console's DotConsoleLocal
```

Names and the bot count:

```gdscript
var roster := DotBotRoster.new()
roster.keep(quota.wanted(humans, max_players), bot_ids,
    func(name: String) -> int: return add_bot(name),
    func(id: int) -> void: remove_bot(id),
    names_in_use)
```

### Hiding, searching and walking a map
For games where bots hide and seek rather than fight, three helpers sit beside the brain. `DotBotNav` bakes a navigation mesh from your map's colliders when the map is built (pass the bodies that never move, so a door baked shut is not a wall) and gives paths and seeded random points. `DotBotHiding` scores places by how many of the map's sight lines reach them, picks one apart from the other hiders, and finds somewhere out of a seeker's sight to run to. `DotBotSearch` is a seeker's memory: the likely places first, crossed off once looked at, and the places near a sound put back on the list.

```gdscript
var nav := DotBotNav.new()
nav.bake(map, {"radius": 0.35, "height": 0.95, "climb": 0.4}, 0, [walls_body, furniture_body])
var spots := DotBotHiding.survey(candidates, watchers, line_of_sight)    # once per map
var spot := DotBotHiding.choose(spots, me, seeker_starts, taken, stream, settings.profile.map_knowledge)
var search := DotBotSearch.new()
search.setup(spots, settings.profile.map_knowledge)
var next := search.next(my_feet, now, other_seekers_targets, stream)
```

game-hide-n-seek's `game/hs_bots.gd` is the worked example.

## Settings
`bot_difficulty` picks a preset (default `medium`). Every other setting below follows the preset unless you set it yourself; a setting you set stays when the preset changes, and `bot_settings_reset` puts the preset's values back. `bot_settings` lists every value and marks the ones you set.

| Cvar | Easy | Medium (default) | Hard | Nightmare | Range | What it does |
| --- | --- | --- | --- | --- | --- | --- |
| `bot_reaction` | 0.5 | 0.3 | 0.21 | 0.12 | 0.05 to 3 | Seconds between first seeing somebody and pulling the trigger on them. |
| `bot_notice` | 0.35 | 0.15 | 0.12 | 0.06 | 0 to 2 | Extra seconds to react to somebody 90 degrees off the view, scaled by how far off they are. |
| `bot_fov` | 90 | 110 | 120 | 160 | 30 to 360 | View cone in degrees: nobody outside it is seen, only heard. |
| `bot_sight` | 35 | 55 | 75 | 100 | 5 to 500 | Farthest the bot sees anybody, metres. |
| `bot_hearing` | 12 | 22 | 32 | 45 | 0 to 200 | How far a gunshot is heard, metres; quieter sounds scale it down. |
| `bot_through_walls` | 0 | 0 | 0 | 0 | 0 to 1 | 1 lets the bot see through walls. Off in every preset; for testing only. |
| `bot_memory` | 2 | 4 | 6 | 10 | 0 to 60 | Seconds a target lost from sight is still hunted and pre-aimed. |
| `bot_aim_error` | 7 | 4 | 2.5 | 1.2 | 0 to 30 | Degrees off the target at the start of an engagement. |
| `bot_aim_settle` | 1 | 0.5 | 0.4 | 0.25 | 0.05 to 10 | Seconds for the aim error to halve while the fight goes on. |
| `bot_aim_floor` | 2 | 1 | 0.6 | 0.3 | 0 to 15 | Degrees the aim error settles to: it swings between about half and all of this. |
| `bot_flinch` | 4 | 3 | 1.5 | 0.6 | 0 to 30 | Degrees of aim error added each time the bot is hit. |
| `bot_turn_rate` | 200 | 450 | 600 | 1000 | 30 to 3600 | Fastest the view turns, degrees per second. |
| `bot_turn_smooth` | 0.3 | 0.55 | 0.65 | 0.85 | 0.05 to 1 | How quickly the view closes on where it wants to look (1 is fastest). |
| `bot_prediction` | 0.25 | 0.6 | 0.75 | 0.95 | 0 to 1 | How much of a moving target's motion is tracked rather than trailed. |
| `bot_fire_cone` | 7 | 5 | 3 | 2 | 0.5 to 45 | Degrees the view may still be off its aim when the bot fires. |
| `bot_range` | 8 | 10 | 12 | 12 | 1 to 100 | Distance the bot likes to fight at, metres. |
| `bot_max_range` | 25 | 35 | 50 | 70 | 1 to 500 | Farthest the bot opens fire from, metres. |
| `bot_burst` | 0.6 | 0.35 | 0.3 | 0.25 | 0.05 to 5 | Seconds of trigger held per burst beyond burst_range. |
| `bot_burst_pause` | 0.6 | 0.3 | 0.22 | 0.12 | 0 to 5 | Seconds between bursts beyond burst_range. |
| `bot_burst_range` | 12 | 16 | 18 | 24 | 0 to 500 | Beyond this the bot fires in bursts; inside it, it holds the trigger. |
| `bot_aggression` | 0.3 | 0.5 | 0.6 | 0.8 | 0 to 1 | How readily it chases a lost target or a sound instead of holding. |
| `bot_cover` | 0.1 | 0.3 | 0.6 | 0.7 | 0 to 1 | Chance of backing out of a fight when badly hurt. |
| `bot_grenades` | 0 | 0.2 | 0.5 | 0.7 | 0 to 1 | Chance of throwing at a target that just went behind cover. |
| `bot_strafe` | 0.15 | 0.55 | 0.85 | 1 | 0 to 1 | Chance of strafing while fighting, per change of direction. |
| `bot_strafe_time` | 1.5 | 0.9 | 0.6 | 0.45 | 0.1 to 5 | Average seconds between changes of strafe direction. |
| `bot_stop_to_shoot` | 0 | 0.35 | 0.6 | 0.8 | 0 to 1 | Chance per engagement of standing still for long-range bursts. |
| `bot_peek` | 0 | 0.3 | 0.7 | 0.9 | 0 to 1 | Chance of pre-aiming and re-peeking where a target was lost. |
| `bot_crouch` | 0 | 0.1 | 0.25 | 0.3 | 0 to 1 | Chance per engagement of crouching for long-range fire. |
| `bot_jump` | 0 | 0.05 | 0.15 | 0.2 | 0 to 2 | Jumps per second while fighting up close. |
| `bot_map_knowledge` | 0.1 | 0.4 | 0.7 | 1 | 0 to 1 | Chance a roaming bot heads where it last knew of an enemy instead of anywhere. |

Hard is meant to play like a good human player. Nightmare is better than a human, but its reaction never drops to zero and its aim is never exact.

## Testing
```bash
godot --headless --path . --import
timeout 180 godot --headless --path . res://examples/bot_selftest.tscn
```

The suite checks the presets and cvars, and measures each preset's reaction time, first-shot aim error, settled aim, turn speed and kill/death ratio against one scripted opponent. game-arena's `headless_bots` measures the same in a real match.

## License
[MIT](LICENSE)
