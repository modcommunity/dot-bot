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
const LEVEL := 3
const OLDEST := 1
