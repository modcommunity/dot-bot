# dot-bot

**Player bots.** A brain that decides what a bot would press each tick (view, movement, trigger, crouch, jump, throw) as the content of the commands a client sends; difficulty presets that are bundles of about thirty individual settings, each a cvar; a name pool; and a roster that adds or removes bots to reach a count.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to bots. The reasoning is in [docs/](docs/README.md).

**Depends on dot-core alone.** It names no other addon: dot-server's cvars, dot-console's console, dot-player-controller's and dot-weapon's commands are all reached by duck typing, so a game with none of them can still use it. Keep it that way.

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | why a separate addon, what the brain may know, the fight, the view, determinism |
| [docs/surfing.md](docs/surfing.md) | anything in `runtime/surf/`, ride edges, `DotBotIntent.ride` |
| [docs/demonstration-recorder.md](docs/demonstration-recorder.md) | recording players for bots to learn from; the recorder itself is the addon [dot-bot-record](../dot-bot-record/CLAUDE.md), the ride harvest here is built, statistics are not |
| [docs/presets.md](docs/presets.md) | changing a preset's number or adding a setting; what each preset is meant to be, and the measured numbers |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_bot/core/dot_bot_profile.gd` | `DotBotProfile`: every setting, `SPEC` (one row per setting: range, four presets, help) |
| `addons/dot_bot/core/dot_bot_settings.gd` | `DotBotSettings`: the live values of one game, `bot_difficulty`, overrides, `bind_cvars` (server), `bind_console` (solo) |
| `addons/dot_bot/core/dot_bot_contact.gd`, `dot_bot_intent.gd` | what the brain reads (a body) and returns (what it would press) |
| `addons/dot_bot/core/dot_bot_names.gd` | `DotBotNames`: the name pool |
| `addons/dot_bot/core/dot_bot_persona.gd`, `runtime/dot_bot_persona_pool.gd` | `DotBotPersona` (profile kind `bot`: a hunt/loot/hold/support/scout mix, a pool weight, a difficulty and skill override; `pick` never returns idle) and `DotBotPersonaPool` (the weighted draw per bot, a per-server `id:weight` override, built from a dot-profile set by duck typing) |
| `addons/dot_bot/runtime/dot_bot_world.gd` | `DotBotWorld`: all a brain may know (bodies, line of sight, waypoints, sounds) |
| `addons/dot_bot/runtime/dot_bot_aim.gd` | `DotBotAim`: the view, the aim error, the reaction and the trigger; the brain's, and a game with its own decisions uses it alone |
| `addons/dot_bot/runtime/dot_bot_brain.gd` | `DotBotBrain`: perceive, then fight, search, listen or roam |
| `addons/dot_bot/runtime/dot_bot_roster.gd` | `DotBotRoster`: from the bots there are to the number wanted, named |
| `addons/dot_bot/runtime/dot_bot_nav.gd`, `dot_bot_hiding.gd`, `dot_bot_search.gd` | for hiding games: a navigation mesh baked from a map's colliders; places scored by sight lines and picked apart; a seeker's memory of the places |
| `addons/dot_bot/runtime/dot_bot_links.gd` | `DotBotLinks`: a converted map's teleports (one-way nav edges), lethal hurt volumes (carved out of the bake through `DotBotNav.avoid`) touch doors and the buttons/triggers that enable a disabled teleport (`gadgets`, `next_gadget`), read by duck typing from the map world |
| `addons/dot_bot/runtime/surf/` | surf bots: `DotBotSurfCourse` (one ride), `DotBotSurfPlanner` (the search on the motor, the cache's repair rounds), `DotBotSurfPilot` (the run-time policy and veto), `DotBotSurfRide` (one bot riding one edge while it aims) |
| (dot-bot-record) | the demonstration recorder, schema and stores were here until API level 6 and are now their own addon, `DotBotDemo*` names unchanged. dot-bot reaches a store, schema or episode untyped (`Variant`), never by class name, so it compiles without it; the suite links `addons/dot_bot_record` |
| `addons/dot_bot/soak/` | `DotBotSoak` (headless soak runner, JSON report, pass/fail reasons) and `DotBotSoakConfig` (thresholds); [docs/soak.md](docs/soak.md); suite `examples/soak_selftest.tscn` |
| `examples/bot_selftest.tscn` | the suite: presets, cvars, names, roster, senses, turn rate, reaction and aim measured, duels, hiding, searching, a baked path, a surf ride on a toy simulator, a ride edge, the demonstration recorder |

## Running and testing

- Link `addons/dot_core` from its repo once ([development setup](../../docs/development-setup.md)), then the family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)) and `timeout 180 godot --headless --path . res://examples/bot_selftest.tscn`.
- **A change to the brain or a preset is not done until game-arena's `headless_bots` passes**: it plays every preset in the real game and holds each to a K/D band, no blind shot and no turn above `bot_turn_rate`. Then the other games that use it (game-zombie-zone, mg-prop-hunt). [presets](docs/presets.md#measured)
- **Look at it.** No suite reaches whether a bot looks human: game-arena's `tools/render_bots.sh [preset]` photographs one from over its shoulder and logs what it was doing. [presets](docs/presets.md#measured)

## Rules that bite

- The brain is pure: it reads a `DotBotContact` and a `DotBotWorld` and returns a `DotBotIntent`. It moves nothing and holds no node. [design](docs/design.md#the-brain-is-pure)
- It knows of a body only through sight (view cone, sight range, the world's line of sight, unless `bot_through_walls`) or a sound. Never hand it a position it could not have seen. [design](docs/design.md#what-a-bot-may-know)
- `through_walls` is 0 in every preset and exists for tests only.
- A setting is a row of `DotBotProfile.SPEC` AND an `@export var` of the same name, with medium's value as its default; the suite checks every row names a property and a new profile equals medium. [presets](docs/presets.md#adding-a-setting)
- Every field must be read by the brain; a setting nothing reads is decoration. [presets](docs/presets.md#adding-a-setting)
- An override outlives a preset change; the cvars always hold the value in use. Waiting config values are all read before the preset is applied. [design](docs/design.md#presets-and-overrides)
- Settings live on the game as metadata (`DotBotSettings.of(node)`), never in `DotRegistry`: two servers in one process. [design](docs/design.md#presets-and-overrides)
- A cvar validator is a static method, never a lambda: a lambda's script can be gone before the console at teardown (dot-server's `DotBotQuota` found it).
- Sounds are heard by sequence number, never by time. [history](docs/history.md)
- A target killed in view is forgotten, not searched for; a sound or a lost target the bot is not going after holds it for `GLANCE` (1.2 s), not its whole memory. [design](docs/design.md#the-fight)
- A caller of `DotBotAim` engages every tick it sees its target; a gap over 0.25 s is a lost target (a re-sight within 1.5 s reacts in half the time), over that a new engagement. [design](docs/design.md#the-fight)
- Randomness is the bot's own `DotRandomStream` (seeded from its id), never `randf`; the clock is the caller's `now`. [design](docs/design.md#determinism)
- Nightmare's reaction stays above 0.1 s and its aim floor above 0. [presets](docs/presets.md#what-each-preset-is)
- `DotBotNav.bake` gets the bodies that never move (a door baked shut is a wall on the mesh) and runs synchronous iterations, so it answers on the tick it baked and a seeded round replays the same. [design](docs/design.md#hiding-and-searching)
- `DotBotNav.bake_in_background` is for a map too big to bake in a tick (seconds); it gives up that determinism, and is `bake` without threads. [design](docs/design.md#hiding-and-searching)
- `DotBotSearch` crosses a place off only when the seeker has had it in view; nothing tells it where a hider is. [design](docs/design.md#hiding-and-searching)
- The surf simulator is duck typed (dot-player-controller's `DotFpsSimulator`); `runtime/surf/` names no other addon. A cache is planned by a tool, never at map load, and replanned after a movement or collision change. [surfing](docs/surfing.md)
- A riding bot's legs are the pilot's, its view and trigger the brain's: `DotBotSurfRide.steer` writes the move for the intent's own yaw and never crouches or walks. [surfing](docs/surfing.md#riding-while-fighting)
- Never `(dict[k] as PackedInt32Array).append(x)`: the cast is a copy and the append is lost. [surfing](docs/surfing.md#traps)

## Where a game plugs in

| To change | Where |
| --- | --- |
| What a bot may know | `DotBotWorld`: subclass, or set `contacts_fn`, `line_of_sight_fn`, `waypoints_fn`, `projectile_speed_fn` |
| What it hears | `DotBotWorld.emit_sound(position, loudness, source, now)` from the game's shots and steps |
| That it was hit | `DotBotBrain.hurt(from, now)` |
| How it plays | `bot_difficulty` and the `bot_*` settings, or a `DotBotSettings` of a game's own per bot |
| How a bot with a game's own decisions aims and shoots | `DotBotAim`: `view_from`, `engage` every tick it sees the target, `track` or `look_at_point`, `trigger`, `hurt` |
| Its commands | `DotBotIntent.write_move` / `write_fire` (a game's throw button by constant name) |
| Its name | `DotBotNames.pick`, or `DotBotRoster.pool` / `prefix` |
| Hiding and seeking | `DotBotNav` (paths), `DotBotHiding.survey` / `choose` / `flee_spot`, `DotBotSearch` |
| Surfing | `DotBotSurfCourse` (a game's course: goals, pits, or override `event_at`), `DotBotSurfPlanner.build` in a tool, `DotBotNav.add_ride` + `DotBotWorld.route_detail_fn`, `DotBotSurfRide` per bot |
| How many | dot-server's `DotBotQuota` for the number, `DotBotRoster.keep` to reach it; `solo_wanted` for one person |

Deliberately not here: pathfinding inside the brain (it walks straight at waypoints and hops when stuck; a game with a graph hands it nearer waypoints, and a hiding game paths with `DotBotNav` itself), weapon choice, game-specific roles (hide, seek, race, survive; each game's own brain builds on this one), chat.
