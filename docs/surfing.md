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
- **Two actions are anchored to the ride instead** (`ANCHORED_FROM`): a wish square to the reference yaw, either side. A wish square to the velocity turns the velocity with it, and at speed a wish with any forward part adds nothing (the projection is already over the cap), so the relative set holds a face only by alternating. Down game-arena's surf_10x ramps, whose first metres lean nearly upright, only a held world-fixed wish landed. Appended, so a cache's action numbers keep their meaning.

## The veto, and what it costs

A launch that is going to fall short is decided long before it falls: with a 96-tick horizon 118 of 119 vetoes found no action that survived, so the horizon is 192. Run afresh every 24 ticks that is eight simulated ticks a ridden tick (0.66 ms on game-g2gfast's physics body at 128 Hz).

**`rolling` (the default) keeps the future instead.** The simulator is the motor, so while the bot's real state is the one the forecast predicted for this tick (within a centimetre), everything after it is still exactly what was simulated, and the only new tick is one more at the far end. A ride that goes as foreseen costs one simulated tick a ridden tick; one pushed off the forecast (another player's hull, a booster the simulation did not run, keys turned for the bot's view) recomputes it and counts a `resync`. A veto still tries every action, held for `check_every` ticks, and after one the next waits `check_every` ticks, as before; after one that found no way out the wait doubles, up to eight times (a doomed ride vetoing every 24 ticks was most of a hard edge's cost). A fresh forecast is made at most every `RESYNC_GAP` ticks and never on the ground: a bot whose game turns its keys for its own view walks off the forecast every tick there, and a fresh 192-tick forecast every tick was half a core. `lookahead_ticks` and `veto_ticks` split the cost.

**A fresh forecast is spread over ticks, a veto can be.** `forecast_budget` (default 24 steps, 0 = all at once) caps the simulator steps a tick spends on a forecast; the rest resumes on the next ticks and the veto is judged only when it completes, with the same end event as an unbudgeted forecast (`bot_selftest` compares them). `veto_budget` does the same for a veto (up to eight futures, about 2,000 steps, 0.14 ms each: the 290 ms worst tick in game-arena's surf soak). It defaults to 0 because a veto answered 8 ticks late (256 a tick) made long surf rides in game-arena's `headless_imported` stop landing; a cheaper veto is what the spike needs.

**The lookup is most of a simulated tick, not the motor.** Every forecast tick asks `policy` of its own end state, and `nearest` read every entry in 27 cells: on game-g2gfast's surf_beginner (9,548 entries along one line) that was about 300 of the 390 us a forecast tick cost, the motor about 90. Since 2026-10-13 it reads the bot's own cell first and skips a neighbour whose box is further than the best so far (the position part alone already loses), which gives the same answer (`bot_selftest` compares it with a scan of every entry): the cache alone went from 374 to 93 us a ridden tick, with the forecast from 912 to 339, and a fresh 192-tick forecast from 79 to 36 ms in one tick. A game that puts its bots back at one exact start can leave `horizon` at 0 (game-g2gfast's live bots do).

**A state off every ride was a full scan.** When no entry lay within two cells (5 m) of a state, `nearest` read all of them, about a millisecond a call; a veto's candidate futures drift off the line and ask hundreds of times, which was 4 to 12 ms a riding tick on game-arena's surf_10x_reloaded_fixed. Since 2026-10-19 a cell with no entry within two cells is known up front (`_near`) and goes to a coarse grid (cells 4 times wider, rings outward, boxes pruned: the nearest entry, as before), and a state more than three rings from any entry reads a sample of every 16th entry (it is falling past the ramp; its action is a guess). The scan inlines the distance, one call a cell. Riding cost fell to 1.0 to 1.3 ms a tick, simulated landing rates 60, 80 and 45% as before (a different far lookup is a different chaotic ride: the exact one cost 2.4 ms an edge-0 tick).

## Riding while fighting

`DotBotSurfRide.steer` writes only the legs: the stick that points the pilot's wish for the brain's view (`move_toward`), jump as the action says, and never crouch or walk (either changes the hull or the speed the rides were planned with). In the air the motor reads little of the view but the wish the keys make, so the bot looks at its target and still holds the ramp. **Not on the ground and not on a jump**: a backward key is slower on the ground, and a game with wall moves (game-arena) pushes a jump beside a wall off along the view, so for the run to the ramp and on a jump the view is the ride's own. Wall contact itself is probed partly along the view, which is why a ride made while the bot looks elsewhere still lands less often than one looking along it (game-arena's measurements). The brain says when its route reached a ride edge (`DotBotIntent.ride`, from `DotBotWorld.route_detail`, which `DotBotNav.route` answers once `add_ride` has linked two islands); the game rides it and calls `DotBotBrain.ride_ended`, which asks for the route again from wherever the bot ended.

## A course on an open map

A staged map's pits sit right under its ramps, so a line that leaves the ramp dies at once and the beam forgets it. A combat surf map has a floor teleport under everything, tens of metres down, and two things went wrong there (game-arena's surf_10x_reloaded_fixed): a line falling off the ramp toward the goal kept its energy and gained progress until it hit the floor seconds later, by which time the beam had dropped every rider for it; and a line falling past the landing scored as further along than one on it. `unsupported_fn` (nothing that could hold the state under it or ahead of it, scored `unsupported_penalty` metres down) and `toward_goal` (progress is how much nearer the goal, never past it) are the course's answers; both are off by default, so a staged map's course is unchanged. `DotBotSurfPlanner.trace` is a tool's window into a search that fails.

## Ride edges in the mesh

`DotBotNav` leaves every surf ramp out (a face steeper than the slope limit is never ground), so a combat surf map bakes as islands. `add_ride(from, to, id)` is a one-way navigation link between two islands; `route` returns the corners and, per corner, the ride that starts there; `islands()` and `island_at()` are what a tool builds its edges from. Links are kept across a re-bake.

## Traps

- **`(dict[key] as PackedInt32Array).append(i)` appends to a copy.** The prototype built its lookup grid that way, so the grid was always empty and every lookup scanned every entry. Append through the dictionary (`dict[key].append(i)`) or a typed local.
- **A packed array kept is the caller's array**: the pilot copies the rides it is handed, because the planner keeps appending to its own.
- A cache is only as fresh as the movement and collision it was planned on: replan after either changes.
