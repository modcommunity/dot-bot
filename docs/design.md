# Design

## Why a separate addon

A bot here is a **player**: it has a session id, a loadout, a score, a body that moves through the game's own movement code and a gun that fires through the game's own arsenal. Each tick it decides what a person would press, and the game turns that into the same commands a client sends. That is a different thing from an NPC, which dot-npc places, paths and budgets and dot-npc-ai's behaviour trees decide for.

dot-npc-ai was the alternative, and it already has the shape to borrow (a character table, a turn-rate limit, aim error, reaction time, `npc_skill`). It was not used because it depends on dot-npc, and a game whose bots are players (every game in the family that has bots) would then have to install the NPC runtime to get them; and because the two difficulty knobs answer different questions. `npc_skill` moves a horde of monsters toward easier or harder; `bot_difficulty` is how good the players you are matched against are, setting by setting, which a server owner wants to tune one number at a time. They stay separate cvars on purpose.

So dot-bot depends on dot-core alone and names no other addon: dot-server's cvars (`bind_cvars` takes `DotModule.add_cvar`), dot-console's console (`bind_console` takes anything with `add_var`), and the command classes (`DotBotIntent.write_move` reads the button bits from the command's own constants) are all reached by duck typing.

## The brain is pure

`DotBotBrain.think(me, world, now)` reads a `DotBotContact` for itself and a `DotBotWorld`, and returns a `DotBotIntent`. It holds no node and moves nothing. The game builds the contacts once a tick (`ArenaBots.World.refresh` in game-arena), and every bot reads the same list. The clock is the caller's `now` (game-arena passes the tick over the tick rate), never the engine's.

## What a bot may know

Everything is in `DotBotWorld`: the bodies, a line-of-sight answer, places to walk to and the way there, how fast the held weapon's shot flies, and the sounds made. A bot knows of another body only when:

- it is inside the view cone (`bot_fov`) and within `bot_sight`, and the world says the line from the bot's eye to that body's chest or eye is clear; or it is within 2 m, which a person feels whatever way they face; or the bot is already fighting it and it is within 90 degrees (the bot is turning after it);
- or it made a sound the bot heard: within `bot_hearing` times the sound's loudness (1 for a gunshot, about 0.3 for a swing or a step). A sound gives a rough position (the further, the vaguer), never a target;
- or it hit the bot (`hurt(from, now)`), which gives the shooter's position and turns the bot toward it.

`bot_through_walls` exists for tests and is 0 in every preset. "No shooting through walls" is then structural: the brain cannot fire at what it has not seen, and game-arena's `headless_bots` counts every trigger pull without line of sight (zero, over thousands of shots per preset).


### Flashes and smoke (API level 8)

`DotBotBrain.blind_for(now, seconds, from)` makes a bot see nothing for its seconds: it loses a visible target, while hearing and pain still work, and `from` (where the flash went off, or `Vector3.INF`) is where it turns afterwards. `is_blind(now)` asks. `DotBotWorld.add_sight_blocker(center, radius, until)` makes `line_of_sight` refuse any segment through that sphere until game time `until` (smoke) and returns an id for `remove_sight_blocker(id)`; the brain prunes ended ones each think through `prune_sight_blockers(now)`. A game's grenade code calls these; the addon names no grenade. A consumer that must still load against an older dot-bot guards with `DotAddonApi.build_level("dot_bot") >= 8`.

## The states

Each tick the brain perceives first, then does one of:

- **fight**: a target is in sight. Aim, fire when the view is on the aim and the reaction time has passed, keep `bot_range`, strafe, burst at range, maybe stand still or crouch for a long burst, maybe jump up close, back out when badly hurt (`bot_cover`).
- **search**: the target went out of sight within `bot_memory`. Pre-aim where it went and shuffle in and out of the corner (`bot_peek`), or walk after it (`bot_aggression`), or hold and look; maybe throw at it (`bot_grenades`).
- **listen**: a sound or a hit within memory. Turn to it; walk to it if the bot rolled to go after it.
- **roam**: walk between the world's waypoints, glancing from side to side, toward where it last knew of an enemy when `bot_map_knowledge` says so; hop and pick another waypoint when it has not moved in 1.5 s. Where the world has a route (`DotBotWorld.route`, a game's navigation graph), the bot walks it corner by corner, asked once per goal; with none, straight at the waypoint, which is enough on an open floor and walks into the wall on a map with corners. Going after a sound walks the same way.

## The fight

The view, the aim error, the reaction and the trigger are `DotBotAim`, which the brain holds and a game with decisions of its own (a co-op stand-in, a hunter sweeping a room) uses by itself: it calls `view_from` with the body's view going into the tick, `engage` every tick it sees its target, `track` toward the target (or `look_at_point` toward anything else), and `trigger` for the button. Asked again within 0.25 s, an engagement simply continues, so a game ticking twenty times a second does not restart the reaction every tick.

**The view is turned, never set.** The brain closes on where it wants to look smoothly (`bot_turn_smooth`), carrying half of a moving target's motion plus `bot_prediction` of the rest, and the whole step is clamped to `bot_turn_rate`. A target outside the view takes visible time to turn onto.

**The aim starts off and settles.** An engagement opens `bot_aim_error` degrees off (scaled 0.75 to 1.25 per engagement), in a direction that drifts, halves every `bot_aim_settle` seconds down to `bot_aim_floor`, and swings between about half and all of that. A hit adds `bot_flinch`. A target re-acquired within 1.5 s continues the same engagement (the error keeps settling) and reacts in half the time, which is what a held angle is.

**The trigger has gates**: reaction passed (`bot_reaction`, plus `bot_notice` scaled by how far off the view the target was), the view within `bot_fire_cone` of where it means to aim, and within `bot_max_range`. Beyond `bot_burst_range` it fires `bot_burst` seconds on, `bot_burst_pause` off.

**A target killed in view is forgotten.** A person moves on after a kill; a bot that searched for it stood pre-aiming the body for its whole memory (seen in the first render). A sound or a lost target the bot is not going after holds it for a glance (1.2 s), not its whole memory, for the same reason: a bot staring at a wall for four seconds reads as stuck.

### Simulated bullets

With the server's `sv_ballistics` on, a bullet drops and takes time to arrive, and a hitscan aim misses. `DotBotAim.aim_solver` is an optional callable `func(eye, point, velocity) -> Vector3` that `track` uses in place of the plain lead; unset (the default) changes nothing. `DotBotAimSolver.solve(muzzle, target, velocity, tuning)` is a ready one: it iterates flight time and bore pitch a few times, reads `muzzle_velocity`, `bullet_gravity` and `drag` off the tuning by duck typing (a dot-weapon `DotWeaponBallistics`, or a dictionary), and returns the plain point when there is no tuning or no solution. dot-bot does not depend on dot-weapon.

## Presets and overrides

`DotBotProfile.SPEC` is the one table: per setting its range, its value in each of the four presets, and its help line. `DotBotSettings` holds one game's live profile and its overrides:

- `bot_difficulty <preset>` writes every setting not overridden;
- any `bot_<setting>` written by hand is an override and survives the next preset;
- `bot_settings` lists every value (overrides marked `*`), `bot_settings_reset` drops the overrides.

A preset change keeping overrides is what makes a server config order-free: `bot_reaction 0.4` above `bot_difficulty hard` in a file means both. When the cvars are bound late, values a config left waiting are all read before the preset is applied, because applying it rewrites every cvar. One case it cannot see: a waiting value equal to medium's default is indistinguishable from the default and is not taken as an override.

The settings are per game, kept on a node as metadata (`DotBotSettings.of(game)`), never in `DotRegistry`, because the family runs two servers in one process in its suites.

## Determinism

Each brain draws from its own `DotRandomStream` seeded from its id, and its clock is the caller's. Two runs with the same inputs play the same bot, which is what lets `headless_bots` hold every preset to a band without flaking. A game must not seed a bot from an object's instance id (it moves between runs).

## Hiding and searching

Not every game's bots fight. A hiding game's bots need to know where people hide and where people look, and those are questions about the map, not about a target. Three helpers answer them, pure like the brain (everything comes in as arguments) and usable by any hiding game:

- **`DotBotNav`**: a navigation mesh baked with the engine's `NavigationServer3D` from the colliders under a node, on its own navigation map, after the map is built in code. A game passes the bodies that never move, because a door is a static body too and a door baked shut is a doorway the mesh does not cross. Its iterations are synchronous (`map_set_use_async_iterations` off, then `map_force_update`), so it answers on the tick it was baked: with asynchronous iterations a path asked for straight after the bake came back empty, and the tick it became ready depended on how the frames fell, so a seeded round played differently on every run. Random points are drawn over the polygons by area from the caller's `DotRandomStream`, never the engine's own. `bake_in_background` parses on the main thread (it must, and it is milliseconds), bakes on a worker with `bake_from_source_geometry_data_async`, and takes the mesh in on the main thread when it lands, calling back with `bake`'s result; `path` answers empty and `is_baking` is true until then, and a bake that lands after `clear` or a newer bake is dropped. It exists for game-arena's imported surf maps, 20 to 50 thousand collision vertices that took 2 to 3 s to bake against a map change of a tenth of a second. The mesh arriving when the machine finishes it is the determinism `bake` keeps, so a game that replays a seeded round from its paths uses `bake`. Without threads it is `bake`.
- **`DotBotHiding`**: a place is good when few of the map's sight lines reach it. `survey` asks the game's line of sight from a sample of watchers (points across the floor at a standing eye) to each candidate place (at a crouched head) once per map, and keeps the share that see it. `choose` scores down places near ones other hiders took (a hider caught becomes a seeker where it stands, next to anybody hidden near it) and near where seekers start, and looks further down the list the less the bot knows the map (`bot_map_knowledge`). `flee_spot` is somewhere out of a given seeker's sight, never past it.
- **`DotBotSearch`**: a seeker's memory of the places. A place is crossed off only when the seeker has had it in view; a sound puts the places near it back first; another seeker's target is scored down so two seekers split a house. It never learns where anybody is from anything but its own eyes and ears.

game-hide-n-seek's `examples/headless_bots` holds the result to bands over whole rounds; its numbers are in that game's `docs/design.md`.

## Links from a map's own entities

`DotBotLinks.read(world)` takes a built map world (dot-map's, by duck typing) and returns plain data: the teleports a runner can fire now, the hurt volumes that kill, and the movers that open by touch. `carve(nav)` puts the kill boxes into `DotBotNav.avoid` before a bake, so a path ends short of them instead of through them. `join(nav)` adds each teleport as an edge with an id at or above `TELEPORT_ID`, so a path crosses it and nothing is ridden. A volume that is disabled, filtered or not for clients is counted in `skipped` and left out; a teleport a button or trigger enables later is kept in `later`, and the buttons and triggers that lead to it (found by walking the output links backwards) in `gadgets`. `next_gadget` / `next_teleport` name the next errand, `refresh` joins a teleport once its entity is live, and a teleport box that lies off the mesh is joined through the floor above or below it (`off_mesh`). Walking to a gadget, holding there and firing it is the runner's job (mg-wipeout's `WoIoBot`). `doors_touched` names the touch doors a body overlaps so the caller can fire them.

## DotBotLinks usage

```gdscript
var links := DotBotLinks.read(map_world)
links.carve(nav)                          # before the bake: kill volumes are cut out
nav.bake_in_background(root, agent, 0, statics)
# once nav.is_ready():
links.join(nav)                           # teleports become one-way edges
# every so often: links.refresh(nav)      # teleports a button has enabled since
var g := links.next_gadget(nav, feet, done)  # a button or trigger to go and press first
for index in links.doors_touched(feet, 0.35, 1.8):  # each step: doors a body is walking into
    map_world.io.touch(index, body)
```

A teleport is added with `DotBotNav.add_ride` so a path crosses it, but nothing is ridden: the bot stands in the box and the map moves it. A volume that is disabled, filtered or not for clients is left out (and counted); one a button enables later is not known, so the path stops short of it.

## DotBotNav usage

```gdscript
var nav := DotBotNav.new()
var baked := nav.bake(map_node, {"radius": 0.35, "height": 0.9, "climb": 0.42})
var path := nav.path(bot_feet, goal)          # PackedVector3Array, empty when unreachable
var spot := nav.random_point(stream)
```

The family's maps are built in code, so the mesh is baked from the static colliders with the engine's `NavigationServer3D` on the spot, on a map of its own so a game's navigation is never disturbed. `random_point` weights the mesh's polygons by area so a seeded game picks the same hiding spots every run.
