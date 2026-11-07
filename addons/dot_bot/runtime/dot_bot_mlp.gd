class_name DotBotMlp
extends RefCounted

## A small multilayer perceptron run in GDScript: the behaviour-cloning policy's forward pass.
##
## Weights are `<name>.dotmlp` (a JSON header) and a sibling `<name>.f32` (little-endian float32: per layer the weights row-major, [out][in], then the biases). Both are untrusted: sizes, the hash, every float and every shape are checked before use.
## [method forward] allocates nothing (the buffers are made at load) and gives the same result for the same input, every call.

const CHANNEL := "bot.mlp"
const FORMAT := "dotbot-mlp"
const VERSION := 1
const HEADER_EXT := "dotmlp"
const WEIGHTS_EXT := "f32"

const MAX_HEADER_BYTES := 64 * 1024
const MAX_WEIGHT_BYTES := 4 * 1024 * 1024
const MAX_LAYERS := 4
const MAX_WIDTH := 1024
const MAX_PARAMS := MAX_WEIGHT_BYTES / 4
const MAX_NAME := 64
## A smaller input scale could blow a finite input up past float range.
const MIN_SCALE := 1e-6

const ACT_LINEAR := 0
const ACT_TANH := 1
const ACT_RELU := 2
const _ACTIVATIONS := {"linear": ACT_LINEAR, "tanh": ACT_TANH, "relu": ACT_RELU}

var schema_id: String = ""
var kind: String = ""
## Layer widths, input first: a 16-64-64-6 net is [16, 64, 64, 6].
var sizes: PackedInt32Array = PackedInt32Array()
## The training run's numbers, as the header carried them.
var metrics: Dictionary = {}

var _activations: PackedInt32Array = PackedInt32Array()
var _scales: PackedFloat32Array = PackedFloat32Array()
var _weights: PackedFloat32Array = PackedFloat32Array()
# Per layer: where its weights start in _weights; its biases follow them.
var _offsets: PackedInt32Array = PackedInt32Array()
# Two work rows end to end (a layer reads one and writes the other), each as wide as the widest layer.
var _work: PackedFloat32Array = PackedFloat32Array()
var _width: int = 0
var _out: PackedFloat32Array = PackedFloat32Array()


func input_size() -> int:
	return sizes[0] if sizes.size() > 0 else 0


func output_size() -> int:
	return sizes[sizes.size() - 1] if sizes.size() > 0 else 0


## Multiply-adds of one forward pass.
func multiply_adds() -> int:
	var n := 0
	for i in range(1, sizes.size()):
		n += sizes[i - 1] * sizes[i]
	return n


## Loads `<stem>.dotmlp` and its sibling `.f32` (pass the stem or either file). With a [param schema] (a DotBotDemoSchema, duck typed) the header's schema id and the input and output sizes must match it, or the file is refused.
static func load_file(path: String, schema: Variant = null) -> DotResult:
	var stem := path
	if path.get_extension() == HEADER_EXT or path.get_extension() == WEIGHTS_EXT:
		stem = path.get_basename()
	var header_path := stem + "." + HEADER_EXT
	var weights_path := stem + "." + WEIGHTS_EXT
	var hsize := DotPaths.file_size(header_path)
	if hsize < 0:
		return DotResult.fail(DotError.CODE_IO, "No %s." % header_path.get_file())
	if hsize > MAX_HEADER_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "The header is %d bytes; the limit is %d." % [hsize, MAX_HEADER_BYTES])
	var wsize := DotPaths.file_size(weights_path)
	if wsize < 0:
		return DotResult.fail(DotError.CODE_IO, "No %s." % weights_path.get_file())
	if wsize > MAX_WEIGHT_BYTES:
		return DotResult.fail(DotError.CODE_INVALID, "The weights are %d bytes; the limit is %d." % [wsize, MAX_WEIGHT_BYTES])
	var parsed := DotPaths.read_json(header_path)
	if not parsed.ok:
		return parsed
	var bytes := DotPaths.read_bytes(weights_path)
	if not bytes.ok:
		return bytes
	return from_data(parsed.value, bytes.value, schema)


## Builds a net from a parsed header and the weights' bytes, with every check [method load_file] makes.
static func from_data(header: Variant, weight_bytes: PackedByteArray, schema: Variant = null) -> DotResult:
	if not header is Dictionary:
		return _bad("the header is not an object.")
	var h: Dictionary = header
	if not h.get("format") is String or String(h["format"]) != FORMAT:
		return _bad("the format is not '%s'." % FORMAT)
	if not _is_int(h.get("version")) or int(h["version"]) != VERSION:
		return _bad("version %s is not supported (only %d)." % [str(h.get("version")).left(MAX_NAME), VERSION])
	var m := DotBotMlp.new()
	for key in ["schema_id", "kind"]:
		if not h.get(key) is String or String(h[key]) == "" or String(h[key]).length() > MAX_NAME:
			return _bad("'%s' is missing or too long." % key)
	m.schema_id = String(h["schema_id"])
	m.kind = String(h["kind"])

	var sz: Variant = h.get("sizes")
	if not sz is Array or (sz as Array).size() < 2 or (sz as Array).size() > MAX_LAYERS + 1:
		return _bad("'sizes' is a list of 2 to %d widths." % (MAX_LAYERS + 1))
	for v: Variant in sz:
		if not _is_int(v) or int(v) < 1 or int(v) > MAX_WIDTH:
			return _bad("a width is outside 1 to %d." % MAX_WIDTH)
		m.sizes.append(int(v))
	var layers := m.sizes.size() - 1
	var params := 0
	for i in layers:
		m._offsets.append(params)
		params += m.sizes[i] * m.sizes[i + 1] + m.sizes[i + 1]
		if params > MAX_PARAMS:
			return _bad("more than %d weights." % MAX_PARAMS)

	var acts: Variant = h.get("activations")
	if not acts is Array or (acts as Array).size() != layers:
		return _bad("'activations' needs one entry per layer (%d)." % layers)
	for a: Variant in acts:
		if not a is String or not _ACTIVATIONS.has(a):
			return _bad("an activation is not one of linear, tanh, relu.")
		m._activations.append(_ACTIVATIONS[a])

	var sc: Variant = h.get("input_scales")
	if not sc is Array or (sc as Array).size() != m.sizes[0]:
		return _bad("'input_scales' needs one scale per input (%d)." % m.sizes[0])
	for v: Variant in sc:
		if not (v is float or v is int) or not is_finite(float(v)) or absf(float(v)) < MIN_SCALE or absf(float(v)) > 1.0 / MIN_SCALE:
			return _bad("an input scale is not a usable finite number.")
		m._scales.append(float(v))

	if h.has("metrics"):
		if not h["metrics"] is Dictionary:
			return _bad("'metrics' is not an object.")
		m.metrics = (h["metrics"] as Dictionary).duplicate(true)

	if schema != null:
		if schema.schema_id() != m.schema_id:
			return DotResult.fail(DotError.CODE_INVALID, "The weights are for schema '%s', the game's is '%s'." % [m.schema_id, schema.schema_id()])
		if schema.observation_size() != m.input_size() or schema.action_size() != m.output_size():
			return DotResult.fail(DotError.CODE_INVALID, "The net is %d in, %d out; the schema is %d in, %d out." % [m.input_size(), m.output_size(), schema.observation_size(), schema.action_size()])

	if weight_bytes.size() != params * 4:
		return DotResult.fail(DotError.CODE_INTEGRITY, "The weights are %d bytes, expected %d." % [weight_bytes.size(), params * 4])
	if not h.get("sha256") is String or String(h["sha256"]) == "":
		return _bad("'sha256' of the weights is missing.")
	if _sha256(weight_bytes) != String(h["sha256"]).to_lower():
		return DotResult.fail(DotError.CODE_INTEGRITY, "The weights do not match the header's hash.")
	m._weights = weight_bytes.to_float32_array()
	for v in m._weights:
		if not is_finite(v):
			return DotResult.fail(DotError.CODE_INTEGRITY, "The weights hold a value that is not finite.")

	for w in m.sizes:
		m._width = maxi(m._width, w)
	m._work.resize(m._width * 2)
	m._out.resize(m.output_size())
	return DotResult.success(m)


## A header and the weights' bytes for a net, for a trainer's output and for tests: [param layers] is one {w: PackedFloat32Array ([out][in] row-major), b: PackedFloat32Array} per layer.
static func encode(p_schema_id: String, p_kind: String, p_sizes: PackedInt32Array, p_activations: PackedStringArray, p_scales: PackedFloat32Array, layers: Array, p_metrics: Dictionary = {}) -> Dictionary:
	var floats := PackedFloat32Array()
	for l: Dictionary in layers:
		floats.append_array(l["w"])
		floats.append_array(l["b"])
	var bytes := floats.to_byte_array()
	var scales: Array = []
	for s in p_scales:
		scales.append(s)
	return {
		"header": {
			"format": FORMAT, "version": VERSION, "schema_id": p_schema_id, "kind": p_kind,
			"sizes": Array(p_sizes), "activations": Array(p_activations), "input_scales": scales,
			"sha256": _sha256(bytes), "metrics": p_metrics,
		},
		"weights": bytes,
	}


## Runs the net over [param obs] (raw observation; each element is divided by its input scale). The result is this net's own buffer, valid until the next call; copy it to keep it. Allocates nothing. An input of the wrong size gives zeros.
func forward(obs: PackedFloat32Array) -> PackedFloat32Array:
	if sizes.is_empty() or obs.size() != sizes[0]:
		_out.fill(0.0)
		return _out
	var layers := sizes.size() - 1
	var src := 0
	var dst := _width
	for i in sizes[0]:
		_work[src + i] = obs[i] / _scales[i]
	for l in layers:
		var n_in := sizes[l]
		var n_out := sizes[l + 1]
		var w := _offsets[l]
		var bias := w + n_in * n_out
		var act := _activations[l]
		for o in n_out:
			var sum := _weights[bias + o]
			var row := w + o * n_in
			for i in n_in:
				sum += _weights[row + i] * _work[src + i]
			if act == ACT_TANH:
				sum = tanh(sum)
			elif act == ACT_RELU and sum < 0.0:
				sum = 0.0
			_work[dst + o] = sum
		var t := src
		src = dst
		dst = t
	for o in _out.size():
		_out[o] = _work[src + o]
	return _out


func describe() -> String:
	return "DotBotMlp(%s, schema %s, %s, %d multiply-adds)" % [kind, schema_id, "-".join(Array(sizes).map(str)), multiply_adds()]


static func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _is_int(v: Variant) -> bool:
	return (v is int) or (v is float and is_finite(v) and v == floorf(v) and absf(v) < 1e9)


static func _bad(why: String) -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, "Not a usable net: %s" % why)
