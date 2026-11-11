class_name DotBotGoal
extends RefCounted

## One bot's current job in a flag or hill mode: where to go and how much else may distract it,
## re-planned every [constant REPLAN] seconds from the [DotBotObjective] the world holds.
##
## [codeblock]
## carrying a flag      capture: run home, no pickups, fights on the move (urgent)
## own flag dropped     return: defenders and supporters, and anybody close
## own flag carried     intercept: chase the carrier (defenders, supporters, anybody close)
## attack               grab the enemy flag, or escort a teammate who has it
## support              escort a carrier, else hold the ground between the bases
## defend               patrol within bot_defend_radius of home, hold and watch the way in;
##                      does not chase a sound or a lost target beyond twice that
## a hill instead       defend holds on it, attack takes it when another team has it (else
##                      hunts), support holds a ring around it facing in
## [/codeblock]
##
## bot_objective_focus is how often the bot keeps to its job; the rest of the time it roams a
## few seconds as in a free-for-all.

# No log channel: plans; the brain logs.

const REPLAN := 0.75
## A new destination this close to the old one keeps the old, so the route is not asked for again.
const KEEP := 3.0
## Within this of a destination the bot has arrived.
const ARRIVED := 2.0
## Anybody this close to their own loose flag goes for it, whatever their role.
const NEAR_FLAG := 22.0

var role: StringName = DotBotObjective.ROAM
## &"" when the bot has no job this moment (free roam or no objective).
var kind: StringName = &""
var dest: Vector3 = Vector3.INF
## Carrying a flag: nothing but enemies in its face distracts it.
var urgent: bool = false
## Where [member leash] is measured from; INF for no leash.
var anchor: Vector3 = Vector3.INF
var leash: float = INF
## Where an arrived bot looks while it holds; INF to look about.
var face: Vector3 = Vector3.INF

var _next: float = -INF
var _free_until: float = -INF
var _hold_until: float = -INF
var _offset: float = 0.0


func _init(p_id: int = 0) -> void:
	# Spread brains over the interval so a full server does not re-plan on one tick.
	_offset = fmod(float(absi(p_id)) * 0.137, REPLAN)


func due(now: float) -> bool:
	return now >= _next


## Forgets the job (a respawn); the next think plans again.
func reset() -> void:
	kind = &""
	dest = Vector3.INF
	urgent = false
	anchor = Vector3.INF
	leash = INF
	face = Vector3.INF
	_next = -INF
	_free_until = -INF
	_hold_until = -INF


## Whether [param at] is beyond the leash: the bot should go back to its post, not chase.
func strays(at: Vector3) -> bool:
	return anchor != Vector3.INF and at.distance_to(anchor) > leash


## Whether the bot is at [member dest] and should hold there.
func arrived(at: Vector3) -> bool:
	return dest != Vector3.INF and Vector2(at.x - dest.x, at.z - dest.z).length() < ARRIVED


func plan(me: DotBotContact, objective: DotBotObjective, world: DotBotWorld, p: DotBotProfile, rng: DotRandomStream, now: float) -> void:
	_next = now + (_offset if _next == -INF else REPLAN)
	if objective == null or not objective.active:
		_clear()
		return
	role = objective.role_of(me.id)
	var team := me.team
	if objective.has_point():
		_plan_point(me, objective, world, p, rng, now)
		return
	var enemy := objective.enemy_of(team, me.position)
	if objective.carrying(me.id) >= 0:
		_aim_at(&"capture", objective.capture_for(team), true)
		return
	urgent = false
	var own_state := objective.state_of(team) if objective.has_flag(team) else DotBotObjective.HOME
	var own_at := objective.flag_at(team)
	var near_own := own_at != Vector3.INF and me.position.distance_to(own_at) < NEAR_FLAG
	if own_state != DotBotObjective.HOME and (role != DotBotObjective.ATTACK or near_own) and role != DotBotObjective.ROAM:
		_aim_at(&"return" if own_state == DotBotObjective.DROPPED else &"intercept", own_at, false)
		return
	if now < _free_until or role == DotBotObjective.ROAM:
		_clear()
		return
	if rng.next_unit() < (1.0 - p.objective_focus) * 0.15:
		# A spell off the job: a person on defence wanders, an attacker detours for a fight.
		_free_until = now + 4.0 + 4.0 * rng.next_unit()
		_clear()
		return
	var escort := _teammate_carrier(objective, team, enemy, me.id)
	match role:
		DotBotObjective.ATTACK:
			if escort != Vector3.INF:
				_aim_at(&"escort", escort, false)
			elif enemy >= 0:
				_aim_at(&"grab", objective.flag_at(enemy), false)
			else:
				_clear()
		DotBotObjective.SUPPORT:
			if escort != Vector3.INF:
				_aim_at(&"escort", escort, false)
			elif enemy >= 0 and objective.has_flag(team):
				if kind != &"hold" or (arrived(me.position) and now >= _hold_until):
					var mid := objective.home_of(team).lerp(objective.home_of(enemy), 0.6)
					var spot := _spot_near(world, mid, p.defend_radius, rng)
					_aim_at(&"hold", spot, false)
					_hold_until = now + 3.0 + 4.0 * rng.next_unit()
				face = objective.home_of(enemy)
			else:
				_clear()
		DotBotObjective.DEFEND:
			var home := objective.home_of(team)
			if home == Vector3.INF:
				_clear()
				return
			if kind != &"defend" or (arrived(me.position) and now >= _hold_until):
				_aim_at(&"defend", _spot_near(world, home, p.defend_radius, rng), false)
				_hold_until = now + 2.0 + 4.0 * rng.next_unit()
			anchor = home
			leash = 2.0 * p.defend_radius
			face = objective.home_of(enemy) if enemy >= 0 else Vector3.INF


## The hill: everybody near it, each role at its own distance.
func _plan_point(me: DotBotContact, objective: DotBotObjective, world: DotBotWorld, p: DotBotProfile, rng: DotRandomStream, now: float) -> void:
	urgent = false
	if now < _free_until or role == DotBotObjective.ROAM:
		_clear()
		return
	if rng.next_unit() < (1.0 - p.objective_focus) * 0.15:
		_free_until = now + 4.0 + 4.0 * rng.next_unit()
		_clear()
		return
	var hill := objective.point
	var radius := objective.point_radius
	match role:
		DotBotObjective.DEFEND:
			if kind != &"defend" or (arrived(me.position) and now >= _hold_until):
				_aim_at(&"defend", _spot_near(world, hill, radius * 0.7, rng), false)
				_hold_until = now + 2.0 + 4.0 * rng.next_unit()
			anchor = hill
			leash = maxf(2.0 * radius, p.defend_radius)
		DotBotObjective.ATTACK:
			if objective.point_owner == me.team:
				# Ours: the attackers go out and meet the next push instead of standing on it.
				_clear()
			elif kind != &"grab" or (arrived(me.position) and now >= _hold_until):
				_aim_at(&"grab", _spot_near(world, hill, radius * 0.5, rng), false)
				_hold_until = now + 2.0 + 2.0 * rng.next_unit()
		DotBotObjective.SUPPORT:
			if kind != &"hold" or (arrived(me.position) and now >= _hold_until):
				_aim_at(&"hold", _spot_near(world, hill, radius * 1.6, rng), false)
				_hold_until = now + 3.0 + 4.0 * rng.next_unit()
			face = hill


func describe() -> Dictionary:
	return {"role": role, "goal": kind, "urgent": urgent}


func _aim_at(p_kind: StringName, at: Vector3, p_urgent: bool) -> void:
	if p_kind != kind or dest == Vector3.INF or at == Vector3.INF or at.distance_to(dest) > KEEP:
		dest = at
	kind = p_kind
	urgent = p_urgent
	anchor = Vector3.INF
	leash = INF
	face = Vector3.INF


func _clear() -> void:
	kind = &""
	dest = Vector3.INF
	urgent = false
	anchor = Vector3.INF
	leash = INF
	face = Vector3.INF


## Where a teammate carrying [param enemy]'s flag is, or INF.
func _teammate_carrier(objective: DotBotObjective, team: int, enemy: int, me_id: int) -> Vector3:
	if enemy < 0 or objective.state_of(enemy) != DotBotObjective.CARRIED or objective.carrier_of(enemy) == me_id:
		return Vector3.INF
	# The carrier is on this team by construction: only a team's rival carries its flag.
	return objective.flag_at(enemy)


## A waypoint within [param radius] of [param centre] (one in five tries), else a point on a ring
## around it, put on the walkable surface when the world knows one.
func _spot_near(world: DotBotWorld, centre: Vector3, radius: float, rng: DotRandomStream) -> Vector3:
	if world != null:
		var points := world.waypoints()
		if not points.is_empty():
			for i in 5:
				var point := points[rng.next_range_i(0, points.size() - 1)]
				if point.distance_to(centre) <= radius:
					return point
	var angle := rng.next_unit() * TAU
	var at := centre + Vector3(cos(angle), 0.0, sin(angle)) * radius * (0.3 + 0.5 * rng.next_unit())
	if world != null:
		var walk := world.walkable_near(at)
		if walk != Vector3.INF:
			return walk
	return at
