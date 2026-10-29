extends RefCounted

## dot-bot's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 1: DotBotProfile (presets as bundles of settings), DotBotSettings (bot_difficulty and the
#    bot_* cvars, server and solo), DotBotBrain, DotBotAim, DotBotWorld, DotBotContact, DotBotIntent,
#    DotBotNames, DotBotRoster.
# 2: DotBotNav (a navigation mesh baked from colliders), DotBotHiding (spots scored by sight
#    lines, picked apart), DotBotSearch (a seeker's memory of the places).
# 3: DotBotNav.bake_in_background, is_baking (a mesh baked on a worker thread).
# 4: surfing. DotBotSurfCourse, DotBotSurfPlanner, DotBotSurfPilot, DotBotSurfRide; ride edges:
#    DotBotNav.add_ride, rides, clear_rides, route (points and rides), islands, island_at,
#    polygon_at, on_island; DotBotWorld.route_detail_fn and route_detail; DotBotIntent.ride;
#    DotBotBrain.ride_ended; DotBotSurfCourse.unsupported_fn, toward_goal; DotBotSurfPlanner.trace.
# 5: the demonstration recorder. DotBotDemoSchema, DotBotDemoEpisode, DotBotDemoRecorder,
#    DotBotDemoConfig (bind_cvars), DotBotDemoStore, DotBotDemoStoreMemory.
# 6: the recorder (the level-5 DotBotDemo* classes) moved to the addon dot-bot-record with the same
#    names. Level 5 was never delivered to a game, so OLDEST stays 1: nothing built at 1 to 4 names
#    a recorder class. A game that records links dot-bot-record (its own requires entry).
# 7: DotBotNav.joined (whether a walk between two points can exist, from the islands and rides,
#    without a path query that errors between islands).
# 8: DotBotBrain.blind_for, is_blind (a flashed bot sees nothing for its seconds); DotBotWorld.add_sight_blocker,
#    remove_sight_blocker, prune_sight_blockers (smoke: line of sight through a sphere is refused).
const LEVEL := 8
const OLDEST := 1
