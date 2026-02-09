extends Node

## Shrinking circle zone system.
## Server-authoritative: server shrinks the zone and damages players outside it.
## Clients read zone state for HUD and visual ring.

# ======================================================================
#  Zone phase definitions
# ======================================================================

const ZONE_DAMAGE_PER_SECOND := 5.0        ## Base HP/s outside zone
const ZONE_DAMAGE_SCALE_PER_PHASE := 2.0   ## Damage multiplier added per phase

const ZONE_PHASES: Array[Dictionary] = [
	{ "wait": 60.0,  "target_pct": 0.70, "shrink_time": 30.0 },
	{ "wait": 45.0,  "target_pct": 0.45, "shrink_time": 25.0 },
	{ "wait": 30.0,  "target_pct": 0.25, "shrink_time": 20.0 },
	{ "wait": 25.0,  "target_pct": 0.10, "shrink_time": 15.0 },
	{ "wait": 20.0,  "target_pct": 0.02, "shrink_time": 10.0 },
]

# ======================================================================
#  State (readable by clients for HUD/visuals)
# ======================================================================

var zone_center: Vector2 = Vector2.ZERO    ## XZ center of safe zone
var zone_radius: float = 200.0            ## Current safe zone radius
var target_radius: float = 200.0          ## Radius we're shrinking toward
var shrink_speed: float = 0.0             ## Units/sec while actively shrinking
var zone_phase: int = -1                  ## -1 = not started, 0+ = active phase
var next_shrink_time: float = 0.0         ## Seconds until next shrink starts (wait phase)
var is_shrinking: bool = false            ## True when zone is actively shrinking
var _initial_radius: float = 200.0       ## Starting radius (set once)
var _active: bool = false                 ## Zone system running


func reset() -> void:
	## Reset zone to idle state (called when returning to main menu).
	_active = false
	zone_radius = 200.0
	target_radius = 200.0
	zone_center = Vector2.ZERO
	zone_phase = 0
	is_shrinking = false
	shrink_speed = 0.0
	next_shrink_time = 0.0


func start_zone(initial_radius: float, center: Vector2) -> void:
	## Called by blockout_map after terrain settles.
	_initial_radius = initial_radius
	zone_radius = initial_radius
	target_radius = initial_radius
	zone_center = center
	zone_phase = 0
	is_shrinking = false
	shrink_speed = 0.0
	_active = true

	# Start first phase wait timer
	if ZONE_PHASES.size() > 0:
		next_shrink_time = ZONE_PHASES[0]["wait"]
	print("[ZoneManager] Zone started: radius=%.0f, center=%s, first shrink in %.0fs" % [
		initial_radius, str(center), next_shrink_time])


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if multiplayer.multiplayer_peer == null:
		return
	if not multiplayer.is_server():
		return
	if zone_phase < 0 or zone_phase >= ZONE_PHASES.size():
		# All phases complete — zone stays at final size, keep damaging
		_damage_outside_players(delta)
		return

	# --- Wait phase: countdown to next shrink ---
	if not is_shrinking:
		next_shrink_time -= delta
		if next_shrink_time <= 0.0:
			# Start shrinking
			var phase: Dictionary = ZONE_PHASES[zone_phase]
			target_radius = _initial_radius * phase["target_pct"]
			var shrink_time: float = phase["shrink_time"]
			shrink_speed = (zone_radius - target_radius) / maxf(shrink_time, 0.1)
			is_shrinking = true
			print("[ZoneManager] Phase %d: shrinking %.0f → %.0f over %.0fs" % [
				zone_phase, zone_radius, target_radius, shrink_time])

	# --- Shrink phase: reduce radius ---
	if is_shrinking:
		zone_radius -= shrink_speed * delta
		if zone_radius <= target_radius:
			zone_radius = target_radius
			is_shrinking = false
			shrink_speed = 0.0
			zone_phase += 1
			# Start next phase wait timer
			if zone_phase < ZONE_PHASES.size():
				next_shrink_time = ZONE_PHASES[zone_phase]["wait"]
				print("[ZoneManager] Phase %d complete. Next shrink in %.0fs" % [
					zone_phase - 1, next_shrink_time])
			else:
				print("[ZoneManager] All phases complete. Zone at final radius: %.0f" % zone_radius)

	# --- Damage players outside the zone ---
	_damage_outside_players(delta)


func _damage_outside_players(delta: float) -> void:
	var players_container := get_tree().current_scene.get_node_or_null("Players")
	if players_container == null:
		return

	var effective_phase := maxi(zone_phase, 0)
	var dmg_per_sec: float = ZONE_DAMAGE_PER_SECOND * (1.0 + effective_phase * ZONE_DAMAGE_SCALE_PER_PHASE)

	for player_node in players_container.get_children():
		if not player_node is CharacterBody3D:
			continue
		if not player_node.get("is_alive"):
			continue
		var player_xz := Vector2(player_node.global_position.x, player_node.global_position.z)
		var dist := player_xz.distance_to(zone_center)
		if dist > zone_radius:
			var damage: float = dmg_per_sec * delta
			if player_node.has_method("take_damage"):
				player_node.take_damage(damage, -1)  # -1 = zone damage


func is_outside_zone(world_pos: Vector3) -> bool:
	## Check if a world position is outside the safe zone.
	var pos_xz := Vector2(world_pos.x, world_pos.z)
	return pos_xz.distance_to(zone_center) > zone_radius


func get_distance_to_edge(world_pos: Vector3) -> float:
	## Returns how far inside (negative) or outside (positive) the zone edge.
	var pos_xz := Vector2(world_pos.x, world_pos.z)
	return pos_xz.distance_to(zone_center) - zone_radius
