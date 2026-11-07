extends SceneTree

## Gates a cloned policy against its baseline on the export's held-out starts (see DotBotEvalGate).
## `godot --headless --path . --script res://tools/demo_eval.gd -- <export dir> <net stem> <host script.gd> [report path] [seeds] [base seed]`
## The host script is the game's simulator adapter (extends RefCounted, the eval_* methods of DotBotEvalGate). The report goes to `<net stem>.eval.json` unless a path is given. Exit 0 when every map passes, 1 when the gate fails, 2 on usage.


func _init() -> void:
	var args := Array(OS.get_cmdline_user_args())
	if args.size() < 3:
		print("usage: demo_eval.gd -- <export dir> <net stem> <host script.gd> [report path] [seeds] [base seed]")
		quit(2)
		return
	var manifest := DotBotDemoExport.load_manifest(args[0])
	if not manifest.ok:
		print(manifest.error.message)
		quit(1)
		return
	var net := DotBotMlp.load_file(args[1])
	if not net.ok:
		print(net.error.message)
		quit(1)
		return
	var script: Variant = load(args[2])
	if not script is GDScript or not (script as GDScript).can_instantiate():
		print("the host script %s does not load" % args[2])
		quit(1)
		return
	var host: Object = (script as GDScript).new()
	var gate := DotBotEvalGate.new()
	if args.size() > 4:
		gate.seeds = int(args[4])
	if args.size() > 5:
		gate.base_seed = int(args[5])
	var verdict := gate.evaluate(net.value, manifest.value, host)
	if not gate.report.is_empty():
		var path: String = args[3] if args.size() > 3 else String(args[1]).get_basename() + ".eval.json"
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			print("cannot write %s" % path)
			quit(1)
			return
		f.store_string(gate.report_text())
		f.close()
		print("report: %s" % path)
	if verdict.ok:
		print("gate passed on %s" % ", ".join(gate.report["policy_on"]))
		quit(0)
	else:
		print(verdict.error.message)
		quit(1)
