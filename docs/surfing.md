# Surfing

A bot that rides surf ramps learns each ramp from the map alone: a search on the real motor, offline, finds rides; the rides are saved as a cache; at run time the bot does what the nearest cached state did and checks its next second and a half on the same motor. The study that chose this over recorded demonstrations and reinforcement learning, and its measurements, is `game-dev/docs/surf-bots-study.md` (not in a repository).

## The pieces

| Class | What |
| --- | --- |
| `DotBotSurfCourse` | One ride: a start and its view, goals and pits (boxes, or callables for a goal that is not a box), a floor, and the score the search ranks by (progress along the start-to-goal line, or a `guide` polyline, plus half the energy, height plus v²/2g) |
| `DotBotSurfPlanner` | A beam search over held actions (width 32, held 8 ticks, one survivor per 0.9 m cell and 1.9 m/s speed bucket), the replay of a found ride, and `build`: rides from perturbed starts, then repair rounds from wherever the pilot fails |
| `DotBotSurfPilot` | The run-time policy: the action of the nearest cached entry (position plus a quarter-second of velocity, on a 2.4 m grid), a veto (the policy's own future, 192 ticks; when it falls, the action whose future survives), optional tracking for a sparse cache. `ACTIONS`, `command_for`, `move_toward` |
| `DotBotSurfRide` | One bot on one ride edge: the pilot's legs written into the brain's intent for the brain's own view, until the course says it landed or fell |

dot-bot names no other addon, so the simulator is duck typed: dot-player-controller's `DotFpsSimulator` (`step(state, command) -> int`, `command(yaw, move, jump)`, `delta`) and its states (`position`, `velocity`, `duplicate_state()`, `is_grounded()`). The event numbers (`EVENT_NONE`, `GOAL`, `PIT`, `BELOW`) are the same on both. `bot_selftest`'s surf sections ride a toy simulator; the real motor is game-g2gfast's `headless_imported` and game-arena's `headless_imported`.

## Why a search and a cache

- **The motor is deterministic and query-only**, so a second copy of it is a perfect simulator: a found sequence of actions is a proof that the ramp can be ridden, not an estimate. A model of the motor would drift, and a ride planned on it falls off the real ramp.
- **A rule does not know which face, how high on it, or how fast to leave.** A rule-based surfer on an A-frame ramp landed on the ridge and strafed between its faces for forty seconds.
- **The repair rounds are the learning.** A round rides the pilot from perturbed starts and searches again from a second before each failure, so the cache grows where the pilot's own mistakes take it, which no search from the start visits. That is imitation learning's dataset aggregation with the planner as the teacher, with no training loop.
- **Copy, once the cache is dense.** Tracking (simulate every action eight ticks and steer at where the remembered ride went next) wins while the cache is sparse (50% against 15% of perturbed starts) and loses once repair rounds have filled it (72% against 92%), at twice the cost.
- **Actions are relative to the velocity**, so one recorded action is reused from a nearby state at another speed; below 1.1 m/s they are relative to the course's reference yaw, because a standstill has no heading.

## The veto, and what it costs

A launch that is going to fall short is decided long before it falls: with a 96-tick horizon 118 of 119 vetoes found no action that survived, so the horizon is 192. Run afresh every 24 ticks that is eight simulated ticks a ridden tick (0.66 ms on game-g2gfast's physics body at 128 Hz).

**`rolling` (the default) keeps the future instead.** The simulator is the motor, so while the bot's real state is the one the forecast predicted for this tick (within a centimetre), everything after it is still exactly what was simulated, and the only new tick is one more at the far end. A ride that goes as foreseen costs one simulated tick a ridden tick; one pushed off the forecast (another player's hull, a booster the simulation did not run, keys turned for the bot's view) recomputes it and counts a `resync`. A veto still tries every action, held for `check_every` ticks, and after one the next waits `check_every` ticks, as before. `lookahead_ticks` and `veto_ticks` split the cost.

## Riding while fighting

`DotBotSurfRide.steer` writes only the legs: the stick that points the pilot's wish for the brain's view (`move_toward`), jump as the action says, and never crouch or walk (either changes the hull or the speed the rides were planned with). In the air the motor reads nothing of the view but the wish the keys make, so the bot looks at its target and still holds the ramp. The brain says when its route reached a ride edge (`DotBotIntent.ride`, from `DotBotWorld.route_detail`, which `DotBotNav.route` answers once `add_ride` has linked two islands); the game rides it and calls `DotBotBrain.ride_ended`, which asks for the route again from wherever the bot ended.

## Ride edges in the mesh

`DotBotNav` leaves every surf ramp out (a face steeper than the slope limit is never ground), so a combat surf map bakes as islands. `add_ride(from, to, id)` is a one-way navigation link between two islands; `route` returns the corners and, per corner, the ride that starts there; `islands()` and `island_at()` are what a tool builds its edges from. Links are kept across a re-bake.

## Traps

- **`(dict[key] as PackedInt32Array).append(i)` appends to a copy.** The prototype built its lookup grid that way, so the grid was always empty and every lookup scanned every entry. Append through the dictionary (`dict[key].append(i)`) or a typed local.
- **A packed array kept is the caller's array**: the pilot copies the rides it is handed, because the planner keeps appending to its own.
- A cache is only as fresh as the movement and collision it was planned on: replan after either changes.
