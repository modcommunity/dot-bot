# Presets

## What each preset is

- **easy**: a new player. Slow to react, slow to turn, misses a lot, barely strafes, never peeks or throws.
- **medium** (the default): an ordinary player. Wins a share of its fights against an ordinary person and loses more. The first play test's complaint was bots that killed him twelve times in ninety seconds; medium is set so that does not happen, and hard is one cvar away.
- **hard**: a good human player. Reacts in about a fifth of a second, opens close and settles fast, strafes almost always, stops to shoot at range, peeks.
- **nightmare**: beyond human, and still not a machine. Its reaction never drops below 0.1 s and its aim never settles to exact, because a bot that reacts on the tick it sees you and never misses is a different game, not a harder one.

The full table with every value is in the [README](../README.md#settings), generated from `DotBotProfile.SPEC`.

## Measured

Two measurements hold the presets, and both run on every change.

**dot-bot's suite** (`examples/bot_selftest.tscn`) measures the brain alone. A stationary target appears 15 m away anywhere in the view cone, forty times per preset:

| Preset | Reaction (setting) | First-shot error | Error after 2.5 s | Fastest turn |
| --- | --- | --- | --- | --- |
| easy | 0.566 s (0.5) | 2.44 deg | 1.14 deg | 199 of 200 deg/s |
| medium | 0.334 s (0.3) | 1.60 deg | 0.43 deg | 448 of 450 deg/s |
| hard | 0.245 s (0.21) | 1.82 deg | 0.25 deg | 598 of 600 deg/s |
| nightmare | 0.186 s (0.12) | 1.60 deg | 0.12 deg | 996 of 1000 deg/s |

Reaction runs a little over the setting because of `bot_notice` and the tick. Hard's first shot is further off than medium's because it fires sooner, while the error is still settling, which is what a fast player does.

Then 100 one-on-one duels per preset against a hand-scripted opponent in a world of rays (an ordinary player: reacts in 0.35 s, opens 4 degrees off and settles to 1.5, fires half-second bursts, strafes at 4 m/s; both bloom with sustained fire, five hits kill, either side may have its back turned at the start): easy 0 (no kills), medium 0.82, hard 5.67, nightmare 100 (no deaths). A duel is decided by small advantages, so the spread is wide.

**game-arena's `headless_bots`** plays each preset for 300 s of one-on-one on dm_box against a reference player whose settings are pinned in the suite (an ordinary player), with arena's real weapons, movement and trace: K/D easy 0.45, medium 1.20, hard 1.72, nightmare 2.75, never a shot without line of sight, never a turn above `bot_turn_rate`. A real map compresses the spread: spawns, corners and who sees whom first decide a lot of fights.

Neither reaches whether a bot *looks* human. game-arena's `tools/render_bots.sh [preset]` photographs one over its shoulder every 0.4 s and logs its state, target, line of sight and trigger.

## Changing a preset

Change the column in `SPEC`; when it is medium's, change the `@export var` default too (the suite checks a new profile equals medium). Then run the suite, game-arena's `headless_bots` and the render, and update the measured numbers here and the band comments in both suites. A band that has to move is a decision, written in the commit.

## Adding a setting

One `SPEC` row (field, min, max, four preset values, help) and an `@export var` of the same name with medium's value. Then make the brain read it: a setting nothing reads is decoration, and the suite only checks that the property exists. The cvar (`bot_<field>`), the solo console variable, the README table and `bot_settings` all come from `SPEC`.
