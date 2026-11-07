extends "res://examples/selftest/config_tests.gd"
## The behaviour-cloning net section of the bot suite.

# Expected outputs come from an independent float64 reference (plain Python, the same formulas) so the check is against another implementation, not the one under test.
const MLP_EXPECTED := [
	[-0.5261578326074077, -0.8049995408469253, -0.755679955452816],
	[-0.6264765333220468, -1.0106269517398168, -1.028283819356434],
	[-0.034841627065329894, -0.98080835542923, -1.5658401756752391],
]
const MLP_SIZES := [6, 8, 8, 3]


func _mlp_net() -> Dictionary:
	var sizes := PackedInt32Array(MLP_SIZES)
	var layers: Array = []
	var k := 0
	for l in 3:
		var w := PackedFloat32Array()
		var b := PackedFloat32Array()
		for i in sizes[l] * sizes[l + 1]:
			w.append(0.6 * sin(0.731 * k + 0.1))
			k += 1
		for i in sizes[l + 1]:
			b.append(0.6 * sin(0.731 * k + 0.1))
			k += 1
		layers.append({"w": w, "b": b})
	return DotBotMlp.encode("sid1", "ride", sizes, PackedStringArray(["tanh", "tanh", "linear"]), PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 0.5, 10.0]), layers, {"held_out_loss": 0.25})


func _mlp_obs(s: int) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for i in 6:
		o.append(3.0 * sin(1.3 * i + 0.7 * s))
	return o


func _mlp_refused(header: Variant, bytes: PackedByteArray, schema: Variant = null) -> bool:
	var r: DotResult = DotBotMlp.from_data(header, bytes, schema)
	return not r.ok


func _test_mlp() -> void:
	_section("bc net: loads a checked file, matches the reference, deterministic, refuses bad files")
	var net := _mlp_net()
	var header: Dictionary = (net["header"] as Dictionary).duplicate(true)
	var bytes: PackedByteArray = net["weights"]
	var res: DotResult = DotBotMlp.from_data(header, bytes)
	_check(res.ok, "a well-formed net loads", res.error.message if not res.ok else "")
	if not res.ok:
		_done()
		return
	var m: DotBotMlp = res.value
	_check(m.input_size() == 6 and m.output_size() == 3 and m.multiply_adds() == 6 * 8 + 64 + 24 and m.metrics.get("held_out_loss") == 0.25, "sizes, cost and metrics are read", m.describe())

	var worst := 0.0
	for s in 3:
		var out := m.forward(_mlp_obs(s))
		for j in 3:
			worst = maxf(worst, absf(out[j] - float(MLP_EXPECTED[s][j])))
	_check(worst < 1e-5, "forward matches the reference to 1e-5", "worst " + str(worst))

	var first := m.forward(_mlp_obs(1)).duplicate()
	m.forward(_mlp_obs(2))
	_check(m.forward(_mlp_obs(1)) == first, "the same input gives the same output, whatever ran between")
	_check(m.forward(PackedFloat32Array([1.0])) == PackedFloat32Array([0.0, 0.0, 0.0]), "a wrong-sized input gives zeros")
	var obs := _mlp_obs(0)
	m.forward(obs)
	var t0 := Time.get_ticks_usec()
	for i in 200:
		m.forward(obs)
	var per_call := float(Time.get_ticks_usec() - t0) / 200.0
	print("        (6-8-8-3 forward: %.1f us; %d multiply-adds)" % [per_call, m.multiply_adds()])
	_check(per_call < 2000.0, "a forward pass of the small net is well under 2 ms", "%.1f us" % per_call)

	# The 16-64-64-6 net of the design: cost reported, and bounded loosely so a slow box does not fail it.
	var big_sizes := PackedInt32Array([16, 64, 64, 6])
	var layers: Array = []
	for l in 3:
		var w := PackedFloat32Array()
		w.resize(big_sizes[l] * big_sizes[l + 1])
		for i in w.size():
			w[i] = 0.1 * sin(0.37 * i)
		var b := PackedFloat32Array()
		b.resize(big_sizes[l + 1])
		layers.append({"w": w, "b": b})
	var scales := PackedFloat32Array()
	scales.resize(16)
	scales.fill(1.0)
	var big_net := DotBotMlp.encode("sid1", "ride", big_sizes, PackedStringArray(["tanh", "tanh", "linear"]), scales, layers)
	var big: DotResult = DotBotMlp.from_data(big_net["header"], big_net["weights"])
	_check(big.ok, "a 16-64-64-6 net loads")
	if big.ok:
		var bm: DotBotMlp = big.value
		var bobs := PackedFloat32Array()
		bobs.resize(16)
		bobs.fill(0.5)
		bm.forward(bobs)
		var b0 := Time.get_ticks_usec()
		for i in 200:
			bm.forward(bobs)
		var big_us := float(Time.get_ticks_usec() - b0) / 200.0
		print("        (16-64-64-6 forward: %.1f us; %d multiply-adds)" % [big_us, bm.multiply_adds()])
		_check(big_us < 5000.0, "a forward pass of the 16-64-64-6 net is under 5 ms", "%.1f us" % big_us)

	var schema := DotBotDemoSchema.make("ride", 2).add_observation("a", 6, 1.0).add_action("b", 3, 1.0)
	header["schema_id"] = schema.schema_id()
	var matched: DotResult = DotBotMlp.from_data(header, bytes, schema)
	_check(matched.ok, "weights for the game's schema load", matched.error.message if not matched.ok else "")
	_check(_mlp_refused(net["header"], bytes, schema), "weights for another schema id are refused")
	var narrow := DotBotDemoSchema.make("ride", 2).add_observation("a", 5, 1.0).add_action("b", 3, 1.0)
	var h2: Dictionary = header.duplicate(true)
	h2["schema_id"] = narrow.schema_id()
	_check(_mlp_refused(h2, bytes, narrow), "a net whose input size is not the schema's is refused")

	# Untrusted input: every mutation of a good header or body is refused.
	var bad := bytes.duplicate()
	bad[10] ^= 0x01
	_check(_mlp_refused(header, bad), "a flipped weight byte fails the hash")
	_check(_mlp_refused(header, bytes.slice(0, bytes.size() - 4)), "short weights are refused")
	var nan_floats := bytes.to_float32_array()
	nan_floats[3] = NAN
	var nan_bytes := nan_floats.to_byte_array()
	var h3: Dictionary = header.duplicate(true)
	h3["sha256"] = DotBotMlp._sha256(nan_bytes)
	_check(_mlp_refused(h3, nan_bytes), "a NaN weight is refused even with a matching hash")
	nan_floats[3] = INF
	nan_bytes = nan_floats.to_byte_array()
	h3["sha256"] = DotBotMlp._sha256(nan_bytes)
	_check(_mlp_refused(h3, nan_bytes), "an infinite weight is refused")
	var mutations := {
		"format": "other", "version": 2, "kind": "", "schema_id": 5, "sizes": [6, 0, 3], "activations": ["tanh"],
		"input_scales": [1, 1, 1, 1, 1, 0], "metrics": 3, "sha256": "",
	}
	var refused := 0
	for key: String in mutations:
		var h: Dictionary = header.duplicate(true)
		h[key] = mutations[key]
		if _mlp_refused(h, bytes):
			refused += 1
	_check(refused == mutations.size(), "a wrong format, version, kind, schema id, widths, activations, scales, metrics or hash is refused", "%d of %d" % [refused, mutations.size()])
	var huge: Dictionary = header.duplicate(true)
	huge["sizes"] = [1024, 1024, 1024, 1024]
	_check(_mlp_refused(huge, bytes), "a net over the weight limit is refused before its weights are read")
	var deep: Dictionary = header.duplicate(true)
	deep["sizes"] = [6, 2, 2, 2, 2, 2, 3]
	_check(_mlp_refused(deep, bytes), "too many layers are refused")
	var nan_scale: Dictionary = header.duplicate(true)
	nan_scale["input_scales"] = [1, 1, 1, 1, 1, 1e-12]
	_check(_mlp_refused(nan_scale, bytes), "a vanishing input scale is refused")
	_check(_mlp_refused([1, 2], bytes) and _mlp_refused(null, bytes), "a header that is not an object is refused")

	# Through files: header and weights are siblings; a missing or oversized sibling is refused.
	var dir := "user://dot_bot_mlp_%d" % randi()
	DirAccess.make_dir_recursive_absolute(dir)
	var stem := dir.path_join("ride")
	var hf := FileAccess.open(stem + ".dotmlp", FileAccess.WRITE)
	hf.store_string(JSON.stringify(net["header"]))
	hf.close()
	_check(not DotBotMlp.load_file(stem).ok, "a header with no weights file is refused")
	var wf := FileAccess.open(stem + ".f32", FileAccess.WRITE)
	wf.store_buffer(bytes)
	wf.close()
	var from_file: DotResult = DotBotMlp.load_file(stem + ".dotmlp")
	_check(from_file.ok, "a header and weights on disk load", from_file.error.message if not from_file.ok else "")
	if from_file.ok:
		_check(((from_file.value as DotBotMlp).forward(_mlp_obs(2)) as PackedFloat32Array).size() == 3 and absf(from_file.value.forward(_mlp_obs(2))[2] - float(MLP_EXPECTED[2][2])) < 1e-5, "the loaded file gives the reference output")
	wf = FileAccess.open(stem + ".f32", FileAccess.WRITE)
	var chunk := PackedByteArray()
	chunk.resize(1024 * 1024)
	for i in 5:
		wf.store_buffer(chunk)
	wf.close()
	_check(not DotBotMlp.load_file(stem).ok, "weights over the size limit are refused")
	DirAccess.remove_absolute(stem + ".dotmlp")
	DirAccess.remove_absolute(stem + ".f32")
	DirAccess.remove_absolute(dir)
	_done()
