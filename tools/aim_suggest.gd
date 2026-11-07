extends SceneTree

## Prints the preset numbers people's recorded fights suggest, for a person to review; it changes nothing.
## `godot --headless --path . --script res://tools/aim_suggest.gd -- <store dir> <map id> <map version> [min episodes]`


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		print("usage: aim_suggest.gd -- <store dir> <map id> <map version> [min episodes]")
		quit(2)
		return
	var store := DotBotDemoStoreJson.new(args[0])
	var counts: DotResult = store.counts(args[1], args[2], DotBotAimStats.KIND)
	if not counts.ok:
		print(counts.message)
		quit(1)
		return
	var stats := DotBotAimStats.new()
	if args.size() > 3:
		stats.min_count = int(args[3])
	var folded: DotResult = await stats.fold_store(store, args[1], args[2], (counts.value as Dictionary).keys())
	if not folded.ok:
		print(folded.message)
		quit(1)
		return
	for line in stats.describe_lines() + stats.suggest_lines():
		print(line)
	quit(0)
