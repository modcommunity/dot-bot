class_name DotBotObjective
extends RefCounted

## What every bot may know about the flags (or a hill to hold), and which job each bot has: the
## shared half of a team mode's bot plan. [DotBotGoal] is the per-bot half that reads it.
##
## [b]Written by the game, read by brains.[/b] The game calls [method set_flag] for each team's
## flag once per tick on the main thread and [method assign] when a bot joins or changes team;
## brains (possibly on worker threads) only read. Flags are public knowledge in a flag mode (the
## HUD shows them), so this is no cheat in the sense of [DotBotWorld].
##
## [codeblock]
## var objective := DotBotObjective.new()
## world.objective = objective
## objective.set_flag(team, flag.home, flag.position, carrier_id, DotBotObjective.CARRIED, capture_point)
## var role := objective.assign(bot_id, team, settings.profile, persona.role_bias())
## [/codeblock]

# No log channel: holds state; the brain and the game log.

const DEFEND := &"defend"
const ATTACK := &"attack"
const SUPPORT := &"support"
## No team job: the bot roams as in a free-for-all.
const ROAM := &"roam"

const HOME := 0
const CARRIED := 1
const DROPPED := 2

## Weight of a persona's preference against the team's share when [method assign] picks a role.
const BIAS_WEIGHT := 0.75

## False until the game reports a flag; a brain with an inactive objective plays as before.
var active: bool = false

# Indexed by team number; _known marks the teams that have a flag.
var _known := PackedByteArray()
var _home := PackedVector3Array()
var _flag := PackedVector3Array()
var _capture := PackedVector3Array()
var _state := PackedInt32Array()
var _carrier := PackedInt64Array()

var _roles: Dictionary = {}
var _teams: Dictionary = {}

## A point a team holds to score (a hill), INF for none; its radius and the team holding it (0 none).
var point: Vector3 = Vector3.INF
var point_radius: float = 0.0
var point_owner: int = 0


## Team [param team]'s flag: its [param home], where it is now ([param at]), who carries it
## (-1 for nobody), its [param state] ([constant HOME], [constant CARRIED], [constant DROPPED]),
## and [param capture]: where a carrier of team [param team] scores an enemy flag.
func set_flag(team: int, home: Vector3, at: Vector3, carrier: int, state: int, capture: Vector3) -> void:
	if team < 0:
		return
	if team >= _known.size():
		var n := team + 1
		_known.resize(n)
		_home.resize(n)
		_flag.resize(n)
		_capture.resize(n)
		_state.resize(n)
		_carrier.resize(n)
	_known[team] = 1
	_home[team] = home
	_flag[team] = at
	_capture[team] = capture
	_state[team] = state
	_carrier[team] = carrier
	active = true


## A hill at [param at] within [param radius], held by [param p_owner] (0 for nobody). Once per
## tick on the main thread, like [method set_flag]; a mode has flags or a hill, not both.
func set_point(at: Vector3, radius: float, p_owner: int) -> void:
	point = at
	point_radius = maxf(radius, 1.0)
	point_owner = p_owner
	active = true


func has_point() -> bool:
	return point != Vector3.INF


## Forgets every flag and the hill (a map change or a mode without either); roles stay.
func clear_flags() -> void:
	_known.fill(0)
	point = Vector3.INF
	active = false


func has_flag(team: int) -> bool:
	return team >= 0 and team < _known.size() and _known[team] == 1


func home_of(team: int) -> Vector3:
	return _home[team] if has_flag(team) else Vector3.INF


func flag_at(team: int) -> Vector3:
	return _flag[team] if has_flag(team) else Vector3.INF


func state_of(team: int) -> int:
	return _state[team] if has_flag(team) else HOME


func carrier_of(team: int) -> int:
	return _carrier[team] if has_flag(team) else -1


## Where a carrier of [param team] takes a flag; its own home when the game gave none.
func capture_for(team: int) -> Vector3:
	if not has_flag(team):
		return Vector3.INF
	return _capture[team] if _capture[team] != Vector3.INF else _home[team]


## The team whose flag [param id] carries, or -1.
func carrying(id: int) -> int:
	for team in _known.size():
		if _known[team] == 1 and _state[team] == CARRIED and _carrier[team] == id:
			return team
	return -1


## The flag a bot of [param team] goes for: the nearest other team's to [param from].
func enemy_of(team: int, from: Vector3 = Vector3.ZERO) -> int:
	var best := -1
	var best_d := INF
	for t in _known.size():
		if t == team or _known[t] != 1:
			continue
		var d := from.distance_squared_to(_flag[t])
		if d < best_d:
			best_d = d
			best = t
	return best


## Picks [param id]'s job in [param team]: the role furthest under its share in [param profile]
## (role_defend, role_attack, role_support), leaning toward [param bias] (defend, attack,
## support preference, each 0 to 1). The same id keeps its role until released or moved team.
func assign(id: int, team: int, profile: DotBotProfile, bias: Vector3 = Vector3.ZERO) -> StringName:
	if _roles.has(id) and int(_teams.get(id, -1)) == team:
		return _roles[id]
	_roles.erase(id)
	var shares := Vector3(profile.role_defend, profile.role_attack, profile.role_support).max(Vector3.ZERO)
	var total := shares.x + shares.y + shares.z
	var role := ROAM
	if total > 0.0:
		shares /= total
		var count := Vector3.ZERO
		for other in _roles:
			if int(_teams.get(other, -1)) != team:
				continue
			match _roles[other]:
				DEFEND: count.x += 1.0
				ATTACK: count.y += 1.0
				SUPPORT: count.z += 1.0
		var n := count.x + count.y + count.z + 1.0
		var need := shares * n - count + bias.clamp(Vector3.ZERO, Vector3.ONE) * BIAS_WEIGHT
		# A role with no share stays empty whatever the persona prefers.
		for axis in 3:
			if shares[axis] <= 0.0:
				need[axis] = -INF
		role = DEFEND
		if need.y > need.x and need.y >= need.z:
			role = ATTACK
		elif need.z > need.x and need.z > need.y:
			role = SUPPORT
	_roles[id] = role
	_teams[id] = team
	return role


func role_of(id: int) -> StringName:
	return _roles.get(id, ROAM)


## Counts of each role in [param team], as {role: n}.
func roles_in(team: int) -> Dictionary:
	var out := {DEFEND: 0, ATTACK: 0, SUPPORT: 0, ROAM: 0}
	for id in _roles:
		if int(_teams.get(id, -1)) == team:
			out[_roles[id]] += 1
	return out


func release(id: int) -> void:
	_roles.erase(id)
	_teams.erase(id)
