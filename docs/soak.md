# Bot soak harness

`DotBotSoak` drives a game's bots headless for N simulated minutes and answers one question: did anything go wrong that a short test would not show. It samples every `sample_sec`: stuck, fell-out, off-nav and unreachable movers, kills, deaths and damage, tick cost, and object and static-memory growth. At the end it judges the run against thresholds and returns a report with `ok` and a list of `reasons`.

It depends on dot-core only. Stuck, fell-out, off-nav and unreachable detection come from dot-spawn's `DotSpawnWatch`, reached by duck typing: assign any object with `report(id, position, kind, has_goal)`, `advance(delta)` returning verdicts (`id`, `category`, `seconds`) and optionally `set_players` and `describe_lines`. Without a watch those checks are skipped and the report says `"watch": false`. A game that wants them enables the watch's rules (`rules.enabled = true`) and sets its `nav_distance_fn` and `reachable_fn`.

## Host integration

A game owns `tools/soak.tscn`, which builds its normal headless world with bots and runs:

```gdscript
var soak := DotBotSoak.new(cfg)   # cfg = DotBotSoakConfig.new(), cfg.apply_cli()
soak.movers_fn = func() -> Array: return world.bots_as_movers()     # {id, position, kind, has_goal}
soak.stats_fn = world.combat_totals                                 # {kills, deaths, damage}, running totals
var report := await soak.run(get_tree())                            # or call soak.advance(delta) yourself
```

Then print `DotBotSoak.summary(report)` and `DotBotSoak.report_line(report)` (one `SOAK {...}` line for CI to grep), optionally `soak.write_report(report, path)`, and quit with `0 if report["ok"] else 1`. `run` awaits physics frames; a host that steps its own world sets `step_fn` and calls `advance(tick)` in a loop, and the cost of `step_fn` is the tick cost. Otherwise the cost is the engine's process plus physics time of the last frame, or `tick_cost_fn`.

Optional hooks: `players_fn` (living players, for far and unreachable), `object_count_fn`, and `describers`, a name to callable map whose output (for example an AI scheduler's or avoidance's `describe_lines`) is copied into the report.

## Thresholds

`DotBotSoakConfig` is a `DotConfig`: defaults, JSON file, environment `DOT_SOAK_*`, command line `--soak-*`. `minutes`, `bots`, `sample_sec`, `warmup_sec`, `seed_value`, and `max_stuck_sec` (10), `max_fell_out` (0), `max_off_nav` and `max_unreachable` (-1, off), `max_object_growth_pct` (25), `max_memory_growth_pct` (50), `max_tick_p95_ms` (16), `require_kills_after_sec` (120; a run that long with no kills fails; unchecked without `stats_fn`). Growth is measured from the first sample after `warmup_sec`.

## Report

`schema` 1; `ok`; `reasons` (strings starting `stuck:`, `fell_out:`, `off_nav:`, `unreachable:`, `leak:`, `tick cost:`, `combat:`); `duration_sec`, `ticks`, `bots`, `movers_seen`, `watch`; `totals`; `tick_ms` (mean, p95, max); `memory`; `samples` (one row per interval); `describe`; `config`.

`examples/soak_selftest.tscn` proves every detector and the schema against a trivial arena of fake movers.
