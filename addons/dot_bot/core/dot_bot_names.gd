class_name DotBotNames
extends RefCounted

## Names for bots that read like the names people pick, and never "Bot 2" or "Stand-in 3".
##
## [b]Why a pool, and why in the addon.[/b] Every game named its bots its own way: one counted
## them ("Stand-in 2"), one used a list of twelve, one prefixed "Bot". A scoreboard of numbered
## stand-ins tells a player they are alone; a scoreboard of names is a match. The scoreboard
## still marks a bot as a bot where a game wants it to (that is the game's row, not the name).
##
## [b]Deterministic and never doubled.[/b] [method pick] takes the names already in use and a
## salt (the bot's id), and walks the pool from a hashed start, so the same server gives the
## same bot the same name and two bots never share one. Past the end of the pool it appends a
## number, which only a server with more bots than [constant POOL] names ever sees.

# No log channel: a list and a pick.

const POOL := [
	"Ash", "Basil", "Birch", "Blaze", "Bramble", "Cinder", "Clover", "Comet", "Copper", "Cricket",
	"Dune", "Ember", "Fable", "Fern", "Flint", "Frost", "Gale", "Garnet", "Glimmer", "Gravel",
	"Hazel", "Hollow", "Indigo", "Ivy", "Jasper", "Juniper", "Kestrel", "Lark", "Loam", "Maple",
	"Marlin", "Moss", "Nettle", "Nova", "Onyx", "Orbit", "Pebble", "Pike", "Quartz", "Quill",
	"Raven", "Reed", "Ripple", "Rook", "Rowan", "Rust", "Saffron", "Sable", "Sage", "Slate",
	"Sorrel", "Spark", "Sprocket", "Tansy", "Thistle", "Tinder", "Topaz", "Vale", "Vesper", "Wren",
	"Yarrow", "Zephyr",
]


## A name not in [param taken], chosen from [param salt]. [param pool] replaces [constant POOL]
## for a game with its own theme; [param prefix] goes in front ("[BOT] " for a game that wants it).
static func pick(taken: Array, salt: int, pool: Array = [], prefix: String = "") -> String:
	var names: Array = pool if not pool.is_empty() else POOL
	var used := {}
	for t in taken:
		used[String(t)] = true
	var start := int(DotRandomStream.new(salt).stream(&"dot_bot_names").unit_at(0) * float(names.size()))
	for round_ in range(1, 100):
		for i in range(names.size()):
			var base := String(names[(start + i) % names.size()])
			var candidate := prefix + (base if round_ == 1 else "%s %d" % [base, round_])
			if not used.has(candidate):
				return candidate
	return prefix + "%s %d" % [String(names[0]), salt]
