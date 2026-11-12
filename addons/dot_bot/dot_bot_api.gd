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
# 9: ladders: DotBotLinks.ladders / ladder_of, DotBotWorld.ladder_fn (a game assigns links.ladder_of).
# 10: DotBotLinks.link_ladders (boxes and a nav in, links out; assign its ladder_of to ladder_fn).
# 11: DotBotClimb (one ladder ride as a step function; the brain uses it, a game steering its own stand-ins can too).
# 12: DotBotUnstick (no-progress detection and escalation, in the brain for every state); DotBotWorld.walkable_fn and walkable_near.
# 13: DotBotNav.spread_points and DotBotWorld.extra_waypoints (waypoints from the mesh); roaming bots hunt toward the nearest enemy.
# 14: DotBotThinkTier (think-rate tiers: which bots think every tick and which every few, for a crowd).
# 15: DotBotWorld.contacts_version, native_enabled, native_available, senses (the sight scan in dot-sim when loaded).
# 16: DotBotThinkTier.engaged_far_every, engaged_range, load_scale (fighting bots out of sight thin out; the tiers stretch under load).
# 17: DotBotBrain.target_first (a bot that sees its target tests it before scanning every body; same choice, a switch for comparing).
# 18: DotBotWorld.contact_of (the contact for an id out of this tick's list; a world that indexes its contacts overrides it, the brain asks it instead of walking the list).
# 19: DotBotObjective, DotBotGoal, DotBotWorld.objective, DotBotBrain.goal, DotBotPersona.role_bias; profile rows role_defend, role_attack, role_support, objective_focus, defend_radius (team jobs in a flag mode); DotBotObjective.set_point (the same jobs around a hill).
# 20: DotBotPersona.scale, spread, derive_into, shapes_skill; DotBotSettings.derived, sync; DotBotPersonaPool.deal, given; DotBotProfile.set_number, copy_from (each bot its own persona).
# 21: DotBotThinkTier.idle_view_every and period(..., idle) (an idle bot a person only sees thins out; idle defaults false, so callers that do not pass it are unchanged).
# 22: DotBotThinkTier.body_near_every, body_far_every, body_period, body_counts (body tiers: the game may tick an unseen near or far bot's motor every few ticks; off by default).
# 23: DotBotNav.bake / bake_in_background agent keys `cell` and `cell_height` (per-bake cell size, in the cache digest and the map's cell size; defaults CELL, CELL_HEIGHT unchanged).
# 24: DotBotThinkTier.body_above; body tiers on by default (body_near_every 2, body_far_every 4) above 24 players.
# 25: DotBotWorld.sight_far, sight_far_reuse (sight LOD: a far body not seen keeps that answer longer; off by default).
# 26: DotBotLinks.join_step, DotBotNav.held, begin_edges, step_edges (a map's drop, hop and stitch search over several frames, the nav held unready until done; join unchanged).
const LEVEL := 26
const OLDEST := 1
