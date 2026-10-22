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
const LEVEL := 5
const OLDEST := 1
