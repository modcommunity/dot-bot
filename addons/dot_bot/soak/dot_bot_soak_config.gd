class_name DotBotSoakConfig
extends DotConfig

## What a soak run lasts and the thresholds that fail it; layered like every config (file, env, argv).

@export_group("Run")
## Simulated minutes the run lasts.
@export_range(0.01, 600.0, 0.01) var minutes: float = 5.0
## Bots the host is asked to field; the soak only reports it.
@export_range(0, 1000, 1) var bots: int = 8
## Seconds between samples.
@export_range(0.1, 600.0, 0.1) var sample_sec: float = 5.0
## Seconds before the leak baseline is taken, so loading is not counted as growth.
@export_range(0.0, 600.0, 0.1) var warmup_sec: float = 10.0
@export var seed_value: int = 1

@export_group("Thresholds")
## Longest a single bot may be stuck, in seconds.
@export_range(0.0, 3600.0, 0.1) var max_stuck_sec: float = 10.0
## Distinct movers that may fall out of the world. -1 skips the check.
@export_range(-1, 100000, 1) var max_fell_out: int = 0
## Distinct movers that may be off the navigation. -1 skips the check.
@export_range(-1, 100000, 1) var max_off_nav: int = -1
## Distinct movers that may be cut off from the players. -1 skips the check.
@export_range(-1, 100000, 1) var max_unreachable: int = -1
## Object count growth after warmup, in percent. 0 or less skips the check.
@export_range(0.0, 10000.0, 0.5) var max_object_growth_pct: float = 25.0
## Static memory growth after warmup, in percent. 0 or less skips the check.
@export_range(0.0, 10000.0, 0.5) var max_memory_growth_pct: float = 50.0
## 95th percentile cost of one tick, in milliseconds. 0 or less skips the check.
@export_range(0.0, 10000.0, 0.1) var max_tick_p95_ms: float = 16.0
## A run at least this long (seconds) with no kills fails; -1 skips the check.
@export_range(-1.0, 100000.0, 1.0) var require_kills_after_sec: float = 120.0


func env_prefix() -> String:
	return "DOT_SOAK_"


func cli_prefix() -> String:
	return "--soak-"
