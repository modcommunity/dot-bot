class_name DotBotPolicy
extends RefCounted

## The cloned policy's place in the brain: a [DotBotMlp] read every think, its action written over the brain's [DotBotIntent].
##
## [b]Off unless it passes.[/b] A policy drives a bot only when all of these hold: [member DotBotProfile.policy] (`bot_policy`, 0 in every preset) is above 0; this object has a net and an observation function; the evaluation gate's report ([DotBotEvalGate]) lists the current map in `policy_on` ([method allow_from_report]); and the bot falls inside the share `bot_policy` asks for (a fixed draw per bot id, so 0.5 is half the bots, always the same half). A report that failed, a map not in it, or no report at all leaves the rules' brain in full control.
##
## [b]What the net may do.[/b] Its action fields are read by name from the host's schema: `move` (2: strafe, forward), `look` (2: yaw and pitch change in degrees, held to `bot_turn_rate` times the think's step, so the policy can not turn faster than the preset allows), and the buttons `fire`, `crouch`, `jump`, `walk`, `use`, `throw` (discrete: a logit above 0 is pressed, the trainer's sigmoid at one half). A field with another name is ignored, and a field the net lacks keeps the brain's own value. `fire` is pressed only while the brain has a target in sight, so a policy can never shoot at what the bot does not see.
## The policy is a fixed function of the observation: the same net and observation give the same intent.

const CHANNEL := "bot.policy"

## Buttons the net may press, by action field name.
const BUTTONS := ["fire", "crouch", "jump", "walk", "use", "throw"]

## The net, or null for no policy.
var net: DotBotMlp = null
## [code]func(me: DotBotContact, world: DotBotWorld, into: PackedFloat32Array) -> void[/code]: fills [param into] (the net's input size) with the raw observation; the host's schema decides what it holds.
var observe_fn: Callable = Callable()
## `map_id@map_version` keys the gate passed ([code]report["policy_on"][/code]).
var allowed_maps: PackedStringArray = PackedStringArray()
## The current map's key, set by the host at map load.
var map_key: String = ""
## Times the net drove a think, for a suite and for a host that logs how often the policy ran.
var thinks: int = 0

# Per action field, in order: [name, offset, size, discrete].
var _layout: Array = []
var _obs: PackedFloat32Array = PackedFloat32Array()
var _has_look: bool = false


## Sets the net and reads the action layout from [param schema] (a DotBotDemoSchema, duck typed: its `action` rows are [name, size, scale, discrete]). Fails, leaving the policy empty, when the schema's action size is not the net's output size.
func set_net(p_net: DotBotMlp, schema: Variant) -> DotResult:
	net = null
	_layout = []
	_has_look = false
	if p_net == null or schema == null:
		return DotResult.fail(DotError.CODE_INVALID, "A policy needs a net and the schema its actions follow.")
	var offset := 0
	var layout: Array = []
	for row: Array in schema.action:
		layout.append([String(row[0]), offset, int(row[1]), bool(row[3])])
		offset += int(row[1])
	if offset != p_net.output_size():
		return DotResult.fail(DotError.CODE_INVALID, "The schema's actions are %d floats, the net's output is %d." % [offset, p_net.output_size()])
	net = p_net
	_layout = layout
	for f: Array in layout:
		if f[0] == "look" and f[2] == 2:
			_has_look = true
	_obs.resize(p_net.input_size())
	return DotResult.success()


## Allows the maps a gate report lists in `policy_on`; a report that is not a passing one for this net's schema and kind allows none. Returns how many maps are allowed.
func allow_from_report(report: Variant) -> int:
	allowed_maps = PackedStringArray()
	if net == null or not report is Dictionary:
		return 0
	var r: Dictionary = report
	if r.get("format") != DotBotEvalGate.FORMAT or r.get("schema_id") != net.schema_id or r.get("kind") != net.kind or r.get("pass") != true:
		return 0
	var on: Variant = r.get("policy_on")
	if not on is Array:
		return 0
	for k: Variant in on:
		if k is String:
			allowed_maps.append(k)
	return allowed_maps.size()


## Whether bot [param bot_id] is driven by the net under [param p]. False by default, and whenever any condition of the class comment fails.
func active(p: DotBotProfile, bot_id: int) -> bool:
	if net == null or p == null or p.policy <= 0.0 or not observe_fn.is_valid():
		return false
	if map_key == "" or not allowed_maps.has(map_key):
		return false
	return _draw(bot_id) < p.policy


## A fixed number in [0, 1) per bot, so a share always picks the same bots.
static func _draw(bot_id: int) -> float:
	return float(hash(["dotbot-policy", bot_id]) & 0xFFFF) / 65536.0


## Runs the net for [param me] and writes its action into [param out]. [param dt] is the think's step in seconds.
func apply(me: DotBotContact, world: DotBotWorld, p: DotBotProfile, dt: float, out: DotBotIntent) -> void:
	if net == null:
		return
	observe_fn.call(me, world, _obs)
	var act := net.forward(_obs)
	if me != null and _has_look and is_finite(me.view_yaw) and is_finite(me.view_pitch):
		# The net's look is a change to the view the bot has now.
		out.yaw = me.view_yaw
		out.pitch = me.view_pitch
	thinks += 1
	write(act, p, dt, out)


## Writes a raw action row over [param out] (see the class comment for what it may touch).
func write(act: PackedFloat32Array, p: DotBotProfile, dt: float, out: DotBotIntent) -> void:
	if net == null or act.size() != net.output_size():
		return
	for f: Array in _layout:
		var name: String = f[0]
		var o: int = f[1]
		var n: int = f[2]
		if name == "move" and n == 2:
			out.move = Vector2(act[o], act[o + 1]).limit_length(1.0)
		elif name == "look" and n == 2:
			var d := Vector2(act[o], act[o + 1])
			var limit := p.turn_rate * maxf(dt, 0.0)
			if d.length() > limit:
				d = d.normalized() * limit
			out.yaw = wrapf(out.yaw + d.x, -180.0, 180.0)
			out.pitch = clampf(out.pitch + d.y, -85.0, 85.0)
		elif n == 1 and bool(f[3]) and BUTTONS.has(name):
			var pressed := act[o] > 0.0
			match name:
				"fire": out.fire = pressed and out.target_id >= 0
				"crouch": out.crouch = pressed
				"jump": out.jump = pressed
				"walk": out.walk = pressed
				"use": out.use = pressed
				"throw": out.throw = pressed
	out.state = &"policy"
