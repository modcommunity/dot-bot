> The recorder (schema, episode, recorder, config, stores) moved to the addon dot-bot-record; this file keeps the whole design, and the harvest, heatmap, statistics and cloning below stay in dot-bot.

# Demonstration recorder

Stage 1's core is built (`dot-bot-record`: schema, episode, recorder, config, store base, memory store); the JSON and SQL stores are built (`dot_bot_demo_store_json.gd`, `dot_bot_demo_store_sql.gd`, `DotBotDemoStore.from_config`); the ride harvest (`DotBotRideHarvest`, `DotBotRideBook`, `DotBotRideConfig` in `runtime/surf/`) is built, with the pilot replay (quantised actions, tracking, veto) below; aim statistics (`DotBotAimStats`, `runtime/dot_bot_aim_stats.gd`, printed by `tools/aim_suggest.gd`) are built; the positioning heatmap (`DotBotDemoHeatmap`, `runtime/dot_bot_demo_heatmap.gd`) is built, fed from a store or episodes and read through `waypoints_fn(points, label, max_copies)`. A dedicated server records what real players do, as observations and actions in a schema each game declares, and bots learn from it: first as ride routes (surf rides, verified on the motor), then as plain statistics (where people stand, how fast they react), and last as a small policy network cloned from the recordings. Everything game-specific is declared by the host; dot-bot keeps naming no other addon.

## Why

The offline search (`DotBotSurfPlanner`, a game's `tools/surf_rides.tscn`) proves a ride exists, but on about one map in three it needed hand-steering and landing rates run 22 to 100%. Real players find the lines the search misses, and they find them on every map a server runs, not only the ones somebody planned. The same recordings answer questions the bot settings now guess at: where a person waits on this map, how long a person takes to react.

## Stage 1: the recorder

### What a host declares

A game hands the recorder a `DotBotDemoSchema` per kind of episode: a name (`"ride"`), a version, and two ordered field lists, observation and action, each field a name, a size and a scale (the number a value is divided by so most of it lands in -1..1). The schema's id is a hash of its fields, so a game that changes what it records starts a new set instead of mixing two. dot-bot hardcodes nothing about bodies, weapons or buttons; a surf ride's observation is position and velocity and its action is the command the server applied (yaw, pitch, the stick, the buttons), and another game's observation can be a hiding spot's sight lines.

The host also tells the recorder when an episode starts and ends, because only the game knows what a "ride" or an "engagement" is:

| Call | When |
| --- | --- |
| `begin(subject, kind, key, start)` | the game saw a stretch worth keeping start (a player left platform 17 in the air); `key` names what it is about (`"17>9"` once known, or `""`), `start` the full state a replay needs |
| `sample(subject, observation, action, tick)` | every server tick for that subject; the recorder decides whether to keep it |
| `end(subject, outcome, key)` | it finished (`landed` on 9, `fell`, `died`); the episode is queued, or dropped when the outcome is not one the kind keeps |
| `cancel(subject)` | a teleport, a disconnect, a round end |

`subject` is any value the host uses for a player this session (its peer number); the recorder maps it to a counter that lives only in memory and never writes it. Bots are never subjects: a host that passes a bot gets the episode refused (`include_fn`, default: refuse when the host says it is a bot), because bots learning from bots is a loop that converges on the bots.

### Server-side, on by default

The recorder runs where the authoritative motor runs: a dedicated server or a listen server's host. A web build is a client only, so it never records; the recorder refuses to start without the host saying it is the server, and stays a no-op. It records what the server applied after `DotFpsCommand.sanitise`, never what a client claims, so a recording is only ever what the server itself simulated.

| Setting (cvar and config key) | Default | What |
| --- | --- | --- |
| `bot_record` | `1` | master switch; `0` stops recording and flushes what is queued |
| `bot_record_kinds` | `""` (all the game declares) | a comma list to record only some kinds |
| `bot_record_rate` | `16` Hz | the base sample rate |
| `bot_record_rate_max` | the tick rate | the rate while a key has few episodes |
| `bot_record_target` | `40` | verified episodes per key at which the rate is back at base |
| `bot_record_cap` | `200` | episodes kept per key; past it a new one replaces the worst-scored |
| `bot_record_store` | `json` | `json`, `sqlite`, `postgres`, `mysql`, `off` |
| `bot_record_path` | `user://dot_bot/demos` | the JSON store's directory, or the SQLite file |
| `bot_record_url`, `bot_record_token` | `""` | the dot-sql gateway for Postgres and MySQL; the token is a sensitive key (config file only) |
| `bot_record_flush` | `10` s | how often queued episodes are written |

`DotBotDemoConfig` is a `DotConfig` (defaults < JSON file < environment < command line; `sensitive_keys` refuses the token from environment and argv), bound to cvars by `bind_cvars(add)` the way `DotBotSettings` is, and `describe_lines()` says what is on, the rate per key, what is queued and what was written.

### Adaptive sample rate

A small server with few players should keep every tick of the few rides it sees; a busy one already has plenty and should spend less. Per key: `rate = base + (max - base) * max(0, 1 - verified / target)`, so the first rides on an edge are kept at the full tick rate and the fortieth at the base rate. A kept sample is every `round(tick_rate / rate)`th tick, and the action kept is the one held over the gap (the most frequent command in it, the mean for an analogue field), so a lower rate is a coarser ride, not a missing one. Past `cap`, an episode is only recorded when the key's worst-scored episode might be beaten, and is dropped on the server without being written otherwise. The counts come from the store once per map load and then from the recorder's own tally, never from a store read on the tick.

### Batched writes off the tick

`sample` appends to a per-subject `PackedFloat32Array` and does nothing else. `end` moves the finished episode to a queue. Every `bot_record_flush` seconds the queue goes to the store as one batch: a thread from `DotPlatform.has_threads()` (`WorkerThreadPool`), or without threads a coroutine that writes one episode a frame. A queue that outgrows 4 MiB drops its oldest episode and counts a `dropped`, so a store that is down never grows the server. Every write under `user://` ends with `DotWeb.sync_filesystem()`.

### An episode

| Field | What |
| --- | --- |
| `map_id`, `map_version` | the map's id and the content version it was played on (a delivered pack's version, or the local import's hash); a different version is a different set |
| `schema_id`, `kind`, `key` | what it is and what it is about |
| `start` | the state a replay begins from (a `Dictionary` of plain values) |
| `rate`, `ticks` | the kept rate, and the samples as one flat float array (observation then action, per kept tick) |
| `outcome` | the host's word for how it ended |
| `day` | the UTC date it was recorded, nothing finer |
| `verified`, `score` | filled by a consumer: did it replay, and how well |

Nothing else: no player name, account, peer number, address, team or chat. See [Privacy](#privacy).

## Storage

One interface, `DotBotDemoStore` (`RefCounted`, every method returns `DotResult` and may be a coroutine, always `await`), with the shape dot-stats' and dot-timer's stores already have:

| Method | What |
| --- | --- |
| `open()`, `close()` | |
| `append(episodes: Array)` | one batch |
| `counts(map_id, map_version, kind) -> {key: verified}` | what the adaptive rate reads at map load |
| `load(map_id, map_version, kind, key, limit)` | episodes, best score first |
| `mark(ids, verified, score)` | a consumer's verdict |
| `prune(map_id, keep_version)` | drop episodes of every other version of a map |
| `describe_lines()` | |

- `DotBotDemoStoreJson`, the default: one file per map version and kind, `<path>/<map_id>@<version>/<kind>.json`, written whole from the store's in-memory copy (a ride file is kilobytes to a few megabytes). The offline tools write the same files, so a seeded map and a recorded one are read the same way. A game's planned cache (`maps/surf/<id>.surf.json`) stays where it is and is the seed; the recorded file sits beside it in `user://`.
- `DotBotDemoStoreSql`: an untyped driver (`query`, `execute`, `batch`, `migrate`), migration component `dot-bot:demos`, one table `dot_bot_demos` (id, map_id, map_version, schema_id, kind, edge_key, day, rate, outcome, verified, score, start as JSON text, ticks as base64 of the float bytes). `key` is a reserved word in one of the three dialects, so the column is `edge_key`. `DotBotDemoStore.from_config(config, host)` loads `res://addons/dot_sql/core/dot_sql.gd` by path, the way game-g2gfast's records store does, so dot-bot never names a `DotSql*` class; without dot-sql installed a database setting is said at ERROR and the JSON store is used.
- `DotBotDemoStoreMemory` for suites.

## The first consumer: surf rides

### Recording a ride

The game (game-arena's `arena_surf.gd`) declares the `ride` schema: observation `position` (3), `velocity` (3); action `yaw`, `move` (2), `jump`. A ride begins when a player who stood on an island (`DotBotNav.island_at`) is in the air above no island, with the full motor state as `start`; it ends `landed` when they stand on another island (the key becomes `"from>to"`), and is cancelled by a teleport, a death or a fall onto a teleport floor. A ride back onto its own island is not kept.

### Verifying it

`DotBotRideHarvest` (dot-bot, `runtime/surf/`) turns episodes into cache rides:

1. **Quantise.** Each kept tick's command becomes the nearest `DotBotSurfPilot.ACTIONS` entry for that tick's velocity (actions are relative to the velocity, `ANCHORED_FROM` included), held for the gap the rate left.
2. **Replay.** From `start`, the pilot rides the simulator (duck typed: a game hands its `DotFpsSimulator` per edge, as it already does for the planner) with this ride alone as its cache, tracking on, veto on. That is what a bot will actually do with it, so a ride the pilot cannot follow is not worth keeping however good the player was.
3. **Keep or reject.** Kept when the course (`DotBotSurfCourse` for that landing) says it landed on the recorded island; the episode is marked `verified` and its `score` is its landing rate from six perturbed starts (the planner's own perturbation). Otherwise marked unverified and never loaded again.

Verification costs a ride's length in simulated ticks a start, so it never runs on the tick: on a server it is a `DotJob` on dot-core's `DotScheduler` (threads where `has_threads()`, a frame budget otherwise, capped at 2 ms a frame), and the offline tool runs it in bulk.

### As built

`DotBotRideHarvest` replays the recorded commands themselves (open loop, each held for the gap the rate left) on the host's simulator through three host methods (`replay_start`, `replay_command`, `landing`, optional `perturb`), as a `DotBotRideHarvestJob` inside `budget_msec` a step. Quantising to pilot actions with tracking and veto is built (below). A full edge past `cap` replaces its worst-scored ride with a better newcomer through `DotBotDemoStore.remove`. `DotBotRideBook` keeps verified recordings and searched seeds per edge for one map id and version (a new version empties it), and `DotBotSurfRide.pick` and `begin_picked` choose and play one. All numbers are `DotBotRideConfig`.

### Piloted replay (built)

When the host also has `pilot_setup(pilot, episode)` (and `DotBotRideConfig.piloted` is on, the default), `DotBotRideHarvest.replay` is the three steps above:

- `DotBotRideQuantiser.entries` turns each sample into a cache row. The `ride` schema's fields are found by name (`position`, `velocity`, `yaw`, `move`, `jump`, in any order, other fields allowed). The command becomes the nearest `DotBotSurfPilot.ACTIONS` entry for that sample's velocity: no stick is 0 (coast), a held jump is 8, otherwise the stick's angle off the view plus the view yaw is compared with each action's wish yaw (heading from the recorded velocity, `reference_yaw` for the anchored two and for a velocity too small to have a heading). A gap of `hold` ticks becomes `hold` rows, position and velocity interpolated and the action held, because the pilot's tracking looks `track_every` rows ahead and means ticks. Without that a 16 Hz recording tracked 0.5 s ahead and the toy ride overshot the platform.
- The pilot has this ride as its only cache, `pilot_tracking` (off by default: tracking cannot follow a ride a planner flew on a synthetic simulator; the ride book stores the mode a recording was verified with and `begin_picked` rides with it, so the two never differ), veto horizon `pilot_horizon` (the simulator has to return `DotBotSurfCourse` events, as the planner's already does). `pilot_setup` is where the host sets what only it knows: `pilot.reference_yaw` and `pilot.score` from the edge's course.
- `host.landing` judges every tick as before, and the same perturbed starts score it.

On the suite's toy, from starts perturbed by up to 2.2 m/s the pilot lands the recorded line 100% and the raw commands 62%. A host without `pilot_setup`, or `piloted = false`, still replays the commands open loop, so game-arena's e8ce78c keeps working unchanged. `DotBotRideBook.load_edge(..., reference_yaw)` then also stores the quantised cache with the recording, and `DotBotSurfRide.begin_picked` rides it on a pilot of its own (tracking when a simulator is given) instead of playing the raw rows back.

Limit: a job step checks its 2 ms budget between replays, and a piloted replay with the veto costs more than an open one (not measured on a real map), so on a server give the job `budget_msec` accordingly or run it between rounds.

### Host wiring for game-arena (design note, not built: the repo was held)

Four additions to `arena_surf_rides.gd`, all optional, none changing the existing `replay_*` methods:

1. `pilot_setup(pilot, ep)`: `var c := course_for_key(ep.key)`; `pilot.reference_yaw` as the bot pilot gets it for that edge (not checked against arena_surf.gd; `c.start_yaw` is the likely source); `pilot.score = c.score`. Whatever `ArenaSurf` gives a bot's pilot for this edge (the same course object, `sim` is already the edge's simulator with its `oracle` returning course events) is what the harvest must see, so reuse that builder rather than a second copy.
2. `_sim` must be the edge's `DotFpsSimulator` with the course oracle set before the job starts (the existing `_replay_course.current` trick does this for `landing`; the veto needs the oracle too, because it reads `step`'s event).
3. `harvest_edge` calls `book.load_edge(store, KIND, key, schema, tick_rate, <the same reference yaw>)` so the bot gets the cache; the `decode` callable stays as the fallback for books loaded without a yaw.
4. `tools/surf_rides.tscn --harvest` prints `harvest.describe()["piloted_replays"]` and writes the merged cache from `book.ranked(key)` entries' `data["cache"]` (rows already in metres; `DotBotSurfPilot.entries_to_rows`), which also closes the "writes no merged cache file" gap in arena-ride-recording.

Cost to watch in headless_imported: the veto makes a piloted replay roughly as dear as a bot riding the edge, times `1 + starts`.

### Ranking and choosing

An edge's rides are the planner's (source `searched`) plus the verified recordings (source `recorded`). Each has a measured success; an edge's success is the best of its rides', so a recorded line that lands more often than any searched one makes the edge usable, and the bot's route cost for an edge can weigh in a low success. Once an edge has `target` verified recordings, recorded rides rank above searched ones at equal success (they are what people do, so they also look like people). `DotBotSurfRide` picks one ride per attempt among an edge's top few, weighted by success, from the bot's own `DotRandomStream`, so a seeded round replays the same and bots do not all take one line. The pilot is handed the chosen ride first and the rest of the edge's cache behind it, so a correction can still use a neighbour.

### The offline tool stays

A game's `tools/surf_rides.tscn` keeps `--explore`, `--plan` and `--measure`, and gains `--harvest` (verify every stored episode of a map, rank, and write the merged edge cache) and `--demos` (list what the store holds per edge). A map nobody has played has only its searched rides; one people play converges on theirs.

### Where the code lives

| dot-bot (nothing surf- or game-specific beyond `runtime/surf/`) | game-arena |
| --- | --- |
| `DotBotDemoSchema`, `DotBotDemoEpisode`, `DotBotDemoRecorder`, `DotBotDemoConfig`, the three stores, `DotBotRideHarvest`, ride choice in `DotBotSurfRide`, the suite sections on a toy simulator | the `ride` schema, `begin`/`sample`/`end` from the island tests it already has, the map id and version from its session, the store from its config, the arena's surf tuning in the simulator it hands over, `tools/surf_rides.tscn --harvest`, `headless_imported` riding a recorded edge |

Another game with ramps or trick movement uses the same pieces with its own schema and segmenting.

## Stage 2: statistics, no learning

Two consumers of the same recordings that change bot settings, not bot code.

- **Positioning heatmaps** (`DotBotDemoHeatmap`, built): kind `place`, one sample a second per living player (position, a host label such as a team or role, whether they were in a fight), binned per map version on a 2 m grid with a decay so a changed meta fades out. A brain reads it through `DotBotWorld.waypoints_fn`: roaming bots weight waypoints by how often people stand there, hiders' `DotBotHiding.survey` can prefer or avoid the places seekers look first. A cell is only used past a minimum count, so one player's habit never shows.
- **Aim and reaction statistics** (`DotBotAimStats`, built; the host says which floats of a frame are the view's error, the fired flag and the tracking error, and `suggest` leaves out a row whose measure was never recorded): kind `engage`, begun when the host says a player first had an enemy in view and ended at their first hit or when it left view: reaction (sight to first shot), the view's error over the first second, tracking error while it moves, time to kill. Folded per map version and game into percentile sketches (no episode kept once folded). `DotBotAimStats.suggest(profile_spec)` maps percentiles onto `DotBotProfile.SPEC` rows within their ranges: easy at the 20th percentile of people, medium at the 50th, hard at the 80th, nightmare clamped by the existing floors (reaction above 0.1 s, aim floor above 0). The suggestion is printed by a tool and reviewed by a person; presets are not rewritten by a server on its own. Samples faster than any person (reaction under 0.1 s, error under the floor) are dropped as cheats, and a host can exclude a session by `include_fn` (a moderation flag).
- **dot-npc-ai** takes the same percentile dictionary in `DotNpcAiCharacter.from_percentiles(dict)`, duck typed, so an NPC's character can come from people too without either addon naming the other.

## Stage 3: behaviour cloning

A small network copies what people do in a state, for the parts no search or rule covers well. Never an LLM in the control loop: the policy is a fixed function of the observation, run every think.

- **Dataset export** (`tools/demo_export.gd` in dot-bot): a store's verified episodes of one kind to a directory of shards, `manifest.json` (schema fields with sizes and scales, map ids and versions, counts, a train/held-out split by episode, never by tick, so a held-out ride is truly unseen) and `shard_N.f32` (little-endian float32 rows, observation then action). Plain bytes, so the trainer needs no Godot. Built as `DotBotDemoExport` (format `dotbot-bc`, `version` 1; a loader refuses any other version): the manifest also holds the schema id and version, per-shard row counts with `[episode id, rows]` per episode, a SHA-256 per shard, and the held-out episodes' ids, keys and start states for the evaluation gate. Rows are raw; the trainer divides each field by its manifest scale. The split hashes the episode id with a seed, so it is repeatable, holds out at least one episode per map version that has two, and a lone episode trains. `load_manifest` and `read_shard` treat the directory as untrusted: a manifest over 8 MiB, an unknown version, a shard name other than `shard_N.f32`, a size or hash that does not match, a count out of range or a non-finite float is refused with a reason. The tool takes the schema as a JSON file.
- **Training** (`tools/bc/train.py` in dot-bot): PyTorch, run on the GPU boxes with `~/godot/gpu.sh py -- python3 tools/bc/train.py <export dir>` (staging02's RTX 2070, the laptop when it is off). A multilayer perceptron, at most two hidden layers of 64, tanh, continuous action fields regressed and button fields as logits; trained with dataset aggregation where a simulator exists (the planner's repair rounds already do this for rides).
- **Weights** (`.dotmlp`): a JSON header (schema id, layer sizes, activations, the input scales, the training run's metrics) and the float32 weights in a sibling `.f32`, both under the map or game's data, versioned with the schema id. A file whose schema id does not match the game's is refused at load.
- **Weights header** (`DotBotMlp`, format `dotbot-mlp`, `version` 1): `schema_id`, `kind`, `sizes` (input first, at most 4 layers of at most 1024), `activations` (`linear`, `tanh`, `relu`, one per layer), `input_scales` (one per input, the manifest's scale repeated per element), `sha256` of the `.f32`, optional `metrics`. The `.f32` is per layer the weights row-major `[out][in]`, then the biases; at most 4 MiB.
- **Inference** (`DotBotMlp`, dot-bot): a forward pass over `PackedFloat32Array`, no allocation per call. A 16-64-64-6 net is about 5,500 multiply-adds, roughly 0.2 to 0.4 ms in GDScript; at the dot-npc-ai scheduler's tiers (every tick for a bot near a player, every Nth otherwise; `DotNpcAiScheduler.admit`) and a 16 Hz think, that is under 1% of a core per bot. The action is held between thinks, as the pilot already holds its actions.
- **Evaluation gate** (`tools/demo_eval.gd`): replay the held-out episodes' start states on the game's simulator, once with the policy and once with the fixed baseline it would replace (the pilot for rides, the scripted brain for roaming), with seeded perturbations. The policy is only switched on by default (`bot_policy` cvar, default `0`) for a kind when it beats the baseline on that kind's own metric (landing rate, reaching the next waypoint, time alive) by a margin over the seeds' spread, on every map in the held-out set, and the gate's report is committed beside the weights. A policy that loses on one map is off on that map. Built as `DotBotEvalGate` (`tools/demo_eval.gd` is its command line): the host is duck typed (`eval_start(start, seed)`, `eval_observe`, `eval_baseline`, `eval_step`, `eval_done`, `eval_score`), each held-out start is replayed under every seed for both sides with the same seed, and a map passes when the mean per-seed gain is at least `max(min_margin, spread_k` times the standard deviation of the gain across seeds`)`, the policy's own score clears `min_policy_score` and the map has `min_episodes` held-out episodes. The report is deterministic (no times, sorted keys) and lists `policy_on`.

## Arena host for the gate and the policy (design)

Built here: `DotBotPolicy` (the intent writer) and `bot_policy`. Not built, because game-arena was held by the demo-stats slice: the host script. game-arena adds `tools/bc_eval_host.gd` (a script the `tools/demo_eval.gd` command takes) and three lines in its bot wiring.

- **Kind and schema.** The first kind is `engage` (the aim and strafe of a fight), the one `arena-demo-stats` records; the schema is the recorder's own, so `DotBotPolicy.set_net(net, schema)` reads the action layout from it. Action fields the policy may use by name: `move`, `look`, `fire`, `crouch`, `jump`; anything else in the schema is recorded but ignored.
- **`eval_start(start, seed)`**: build a headless Arena world (the `headless_bots` rig) on the start's map, place the subject and the recorded opponent at the start state's positions and views, seed the opponent's aim error and the world's `DotRandomStream` from `seed`, and return the state (the rig plus a tick counter).
- **`eval_observe(state)`**: the schema's observation for the subject, built by the same function the recorder samples with (one function, so training and replay can not drift apart); returns a `PackedFloat32Array`.
- **`eval_baseline(state)`**: the action row the scripted `DotBotBrain` would give this tick for the same observation, packed in the schema's order (`DotBotPolicy.write` is the inverse of this packing).
- **`eval_step(state, action)`**: write the row into the subject's `DotFpsCommand`/`DotWeaponCommand` through `DotBotIntent.write_move`/`write_fire` and step the world one think (1/16 s).
- **`eval_done(state)`**: the opponent or the subject is dead, or `max_steps` thinks.
- **`eval_score(state)`**: the engagement metric: 1 for a kill plus the share of health left, 0 for a death (higher is better, so a policy that wins fights faster scores more).
- **Wiring.** At map load: `policy.map_key = "%s@%s" % [map_id, map_version]`, `policy.allow_from_report(JSON.parse(committed report))`, `brain.policy = policy`, `policy.observe_fn = <the same observation function>`. A missing report file allows nothing. The cvar `bot_policy` stays 0 until a server owner raises it; the gate decides where raising it does anything.
- **Order of work.** `arena-demo-stats` lands and a server records for a while, `demo_export.gd` and `tools/bc/train.py` make the net, the host runs the gate, and the report is committed beside the weights. Until real held-out episodes exist none of this runs; the suite proves only the plumbing with a synthetic net.

## Privacy

Movement is not sensitive, and nothing that identifies a person is kept. What is stored: the map, a schema, the ticks of a stretch of movement or an engagement, its outcome, and the date. What is never stored: a name, an account id, a peer number, an address, a team roster, chat, voice, or a time finer than a day. The subject counter exists only in memory for one episode. Statistics are folded into counts and percentiles; a heatmap cell or a statistic needs a minimum count before it is used. Recording is server-side, so nothing is sent from a client that it would not send anyway.

The text for a game's README and a server's rules (`cfg` comment and server info):

> This server records anonymous movement (where players move and how they ride ramps, and how quickly they react in a fight) to teach its bots. No names, account ids, addresses or chat are recorded, and recordings are stored by map and date only. The server owner can turn this off with `bot_record 0`.

## Task breakdown

Each piece is one repository, sized S (an hour or two of a builder, under 300 lines), M (half a day) or L (a day). Arrows are dependencies.

| Key | Repo | What | Size | After |
| --- | --- | --- | --- | --- |
| `demo-rec-core` | dot-bot | `DotBotDemoSchema`, `DotBotDemoEpisode`, `DotBotDemoRecorder` (begin/sample/end/cancel, include_fn, adaptive rate, queue, flush), `DotBotDemoConfig` + `bind_cvars`, `DotBotDemoStore` base and the memory store; suite sections: a fake host records, a bot is refused, the rate falls as the count rises, a full queue drops oldest | L | - |
| `demo-rec-stores` | dot-bot | `DotBotDemoStoreJson`, `DotBotDemoStoreSql` (migration, batch insert, counts, prune), `from_config` loading dot-sql by path; offline suite on the JSON and recording driver, a live suite run by dot-sql's `tools/test_live.sh` on SQLite (Postgres and MariaDB where available, never `tmc_dev`) | M | `demo-rec-core` |
| `demo-ride-harvest` | dot-bot | `DotBotRideHarvest` (quantise, pilot replay, keep or reject, score), `DotJob` scheduling with a frame budget, rides merged with source and success; ride choice among an edge's top rides in `DotBotSurfRide`; suite: a good toy ride kept, a bad one rejected, choice is seeded | M | `demo-rec-core` |
| `arena-ride-recording` | game-arena | the `ride` schema and segmenting in `arena_surf.gd`, recorder and store from the game's config, recorded rides loaded with the planned cache, `tools/surf_rides.tscn --harvest` and `--demos`; `headless_imported` records simulated players' rides, harvests them and has a bot ride a recorded edge | L | `demo-rec-stores`, `demo-ride-harvest` |
| `deploy-demo-cfg` | dot-server-deploy | `cfg/bot_record.yml` documenting every key and the rules text, read into the game's `DotBotDemoConfig` by the host the way `replay.yml` is | S | `demo-rec-core` |
| `demo-heatmap` | dot-bot | `DotBotDemoHeatmap` (kind `place`, grid, decay, minimum count) and a `waypoints_fn` weighting helper; suite | M | `demo-rec-stores` |
| `demo-aim-stats` | dot-bot | `DotBotAimStats` (kind `engage`, percentile sketches, cheat floor, `suggest` onto `SPEC`) and a tool that prints a suggested preset table; suite | M | `demo-rec-stores` |
| `arena-demo-stats` | game-arena | `place` and `engage` episodes from the arena's sight and hit events; roaming weighted by the heatmap; `headless_bots` still passes | M | `demo-heatmap`, `demo-aim-stats` |
| `npc-character-from-stats` | dot-npc-ai | `DotNpcAiCharacter.from_percentiles(dict)`, duck typed; suite | S | `demo-aim-stats` |
| `bc-export` | dot-bot | `tools/demo_export.gd`: manifest and float32 shards, split by episode; suite reads a shard back | S | `demo-rec-stores` |
| `bc-train` | dot-bot | `tools/bc/train.py` (PyTorch, MLP, DAgger hook), `.dotmlp` writer, run once on staging02 through `gpu.sh py` on a toy export | M | `bc-export` |
| `bc-mlp-runtime` | dot-bot | `DotBotMlp` (load, schema check, allocation-free forward), a policy intent writer, the `bot_policy` cvar default off; suite: matches the trainer's output on fixed inputs to 1e-5, cost measured | M | `bc-train` |
| `bc-eval-gate` | dot-bot | `tools/demo_eval.gd`: held-out starts, policy against baseline on a host's simulator, seeded, per-map verdict and report | M | `bc-mlp-runtime` |
| `arena-bc-trial` | game-arena | the first cloned policy (rides or roaming), trained on recorded arena episodes, gated by `bc-eval-gate`; stays off unless the gate passes | L | `bc-eval-gate`, `arena-ride-recording` |

Stage 1 is the first five, and is `bot-recorded-rides-1`'s "done when". Stages 2 and 3 can start once `demo-rec-stores` lands and do not block it.

The job replays a piloted ride a slice at a time (`DotBotRideHarvest.Run.advance`, bounded by `budget_msec` and `slice_steps`) with the verdicts of an unsliced replay; the least a tick can cost is one simulator step plus the pilot's command, and with tracking on the pilot's own command can spike (rolling repair) far above the budget.
