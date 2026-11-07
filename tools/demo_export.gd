extends SceneTree

## Exports a store's verified episodes of one schema as a behaviour-cloning dataset (see DotBotDemoExport).
## `godot --headless --path . --script res://tools/demo_export.gd -- <store dir> <schema.json> <out dir> <map id> <map version> [held-out fraction] [--overwrite]`
## The schema file is {"kind", "version", "observation": [[name, size, scale]], "action": [[name, size, scale, discrete]]}.


func _init() -> void:
	var args := Array(OS.get_cmdline_user_args())
	var overwrite := args.has("--overwrite")
	args.erase("--overwrite")
	if args.size() < 5:
		print("usage: demo_export.gd -- <store dir> <schema.json> <out dir> <map id> <map version> [held-out fraction] [--overwrite]")
		quit(2)
		return
	var described := DotPaths.read_json(args[1])
	if not described.ok or not described.value is Dictionary:
		print("the schema file is not a JSON object: %s" % described.error.message)
		quit(1)
		return
	var schema := DotBotDemoExport.schema_from_dictionary(described.value)
	if not schema.ok:
		print(schema.error.message)
		quit(1)
		return
	var store := DotBotDemoStoreJson.new(args[0])
	var counts: DotResult = store.counts(args[3], args[4], (schema.value as DotBotDemoSchema).kind)
	if not counts.ok:
		print(counts.error.message)
		quit(1)
		return
	var export := DotBotDemoExport.new(schema.value)
	if args.size() > 5:
		export.held_out_fraction = float(args[5])
	var added: DotResult = await export.collect(store, args[3], args[4], (counts.value as Dictionary).keys())
	if not added.ok:
		print(added.error.message)
		quit(1)
		return
	var wrote := export.write(args[2], overwrite)
	if not wrote.ok:
		print(wrote.error.message)
		quit(1)
		return
	var totals: Dictionary = wrote.value["totals"]
	print("%d train and %d held-out episodes (%d and %d rows) in %d shards; %d refused" % [totals["train_episodes"], totals["held_out_episodes"], totals["train_rows"], totals["held_out_rows"], (wrote.value["shards"] as Array).size(), export.rejected])
	quit(0)
