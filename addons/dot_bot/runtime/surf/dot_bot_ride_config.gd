class_name DotBotRideConfig
extends DotConfig

## The ride harvest's numbers: exported defaults < JSON file < environment < command line.

## Perturbed starts a verified ride is scored from.
@export var starts: int = 6

## How far the host is asked to move a start, metres.
@export var perturb_metres: float = 0.4

## How far the host is asked to change a start's speed, metres a second.
@export var perturb_speed: float = 0.5

## Ticks a replay may run past the recorded ride before it counts as not landing.
@export var settle_ticks: int = 96

## Longest a harvest job step may run, milliseconds.
@export var budget_msec: float = 2.0

## A verified ride scoring under this is rejected.
@export var min_score: float = 0.0

## Rejected episodes are marked and kept instead of removed.
@export var keep_rejected: bool = false

## Verified rides an edge keeps; past it a better ride replaces the worst.
@export var cap: int = 200

## Verified recordings at which they rank above searched rides.
@export var target: int = 40

## An edge's best this many rides are the ones a bot picks among.
@export var top: int = 3

## Added to every score when weighting a pick, so a 0% ride is rare, not impossible.
@export var floor_weight: float = 0.05

## Seeds the perturbation, so a harvest repeats.
@export var seed: int = 1


func env_prefix() -> String:
	return "DOT_BOT_HARVEST_"


func cli_prefix() -> String:
	return "--bot-harvest-"


func validate() -> DotResult:
	if starts < 0 or settle_ticks < 0 or top < 1 or cap < 1 or target < 1:
		return DotResult.fail(DotError.CODE_INVALID, "harvest starts and settle_ticks are 0 or more; top, cap and target are 1 or more.")
	if budget_msec <= 0.0 or perturb_metres < 0.0 or perturb_speed < 0.0 or floor_weight < 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "harvest budget_msec must be above 0; perturbation and floor_weight 0 or more.")
	if min_score < 0.0 or min_score > 1.0:
		return DotResult.fail(DotError.CODE_INVALID, "harvest min_score is 0 to 1.")
	return DotResult.success(self)
