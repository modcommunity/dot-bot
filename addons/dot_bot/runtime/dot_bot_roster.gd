class_name DotBotRoster
extends RefCounted

## Puts the number of bots right: adds named ones while there are too few, removes the newest
## while there are too many.
##
## [b]The count is the game's or dot-server's, never this.[/b] dot-server's [code]DotBotQuota[/code]
## says how many bots a server wants for the people on it (`bot_quota`, `bot_quota_mode`); a
## solo game asks the same rule with one person ([method solo_wanted]). This only gets from
## the number there are to the number wanted, which every game wrote by hand with its own
## naming, and the naming is the part that went wrong ("Stand-in 2").
##
## [codeblock]
## var roster := DotBotRoster.new()
## roster.keep(quota.wanted(humans, slots), bridge.bot_ids(),
##     func(name: String) -> int: return bridge.add_bot(name),
##     func(id: int) -> void: bridge.remove_bot(id),
##     names_in_use)
## [/codeblock]
##
## [b]Newest out first[/b], so a person joining takes the place of the bot that came last and
## the longest-standing bots keep their scores.

const CHANNEL := "dot.bot"

## Names a game uses instead of [constant DotBotNames.POOL]; empty for the pool.
var pool: Array = []

## Put in front of every name ("[BOT] "); empty by default.
var prefix: String = ""

## How many names this has handed out, the salt for the next.
var _given: int = 0


## Adds or removes until [param current] has [param wanted] ids. [param add] is
## [code](name: String) -> id[/code], where 0, null or "" means the game refused (and adding
## stops); [param remove] is [code](id) -> void[/code]. [param taken] is every name in use,
## people included, so a bot never shares a person's name. Returns the ids after.
func keep(wanted: int, current: Array, add: Callable, remove: Callable, taken: Array = []) -> Array:
	var ids := current.duplicate()
	var names := taken.duplicate()
	wanted = maxi(wanted, 0)

	while ids.size() < wanted:
		var name := next_name(names)
		var made: Variant = add.call(name)
		if made == null or (made is int and made == 0) or (made is String and made == "") or (made is StringName and made == &""):
			DotLog.debug(CHANNEL, "the game refused a bot", {"name": name, "have": ids.size(), "wanted": wanted})
			break
		ids.append(made)
		names.append(name)

	while ids.size() > wanted:
		remove.call(ids.pop_back())

	return ids


## The next name, not in [param taken].
func next_name(taken: Array) -> String:
	_given += 1
	return DotBotNames.pick(taken, _given, pool, prefix)


## How many bots a solo game wants: the server's fill rule with one person, so solo and a
## server agree about what `bot_quota 4` means (four players, three of them bots).
static func solo_wanted(quota: int, fill: bool = true) -> int:
	return maxi(quota - 1, 0) if fill else maxi(quota, 0)
