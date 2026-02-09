extends Node

## Server-side AI brain for bot players.
## Directly writes to the sibling PlayerInput node to simulate input.
## The player.gd _server_process reads PlayerInput the same way for bots
## and real players — no special cases needed in the movement code.

## --- Behaviour tuning ---
const WANDER_INTERVAL_MIN := 3.0     ## Min seconds between picking a new wander target
const WANDER_INTERVAL_MAX := 7.0     ## Max seconds
const WANDER_RADIUS := 40.0          ## How far from current position to pick targets
const EDGE_MARGIN := 20.0            ## Start turning away this far from map edge
const EDGE_HARD_MARGIN := 10.0       ## Emergency turn-around distance
const STUCK_THRESHOLD := 0.3         ## If speed stays below this for STUCK_TIME, re-pick target
const STUCK_TIME := 2.0              ## Seconds of low speed before considered stuck
const LOOK_SMOOTHING := 3.0          ## How fast the bot rotates toward its target yaw
const SHOOT_RANGE := 30.0            ## Max distance to engage a target
const SHOOT_ANGLE := 0.4             ## Radians: must be facing within this angle to fire
const PICKUP_RANGE := 8.0            ## Distance to notice and walk toward items

var _player: CharacterBody3D = null
var _player_input: Node = null
var _map_half_size: float = 112.0
var _rng := RandomNumberGenerator.new()

## Wander state
var _wander_target: Vector3 = Vector3.ZERO
var _wander_timer: float = 0.0
var _target_yaw: float = 0.0

## Stuck detection
var _stuck_timer: float = 0.0

## Combat state
var _combat_target: CharacterBody3D = null
var _combat_scan_timer: float = 0.0
const COMBAT_SCAN_INTERVAL := 1.0

## Jump timer: occasionally jump over obstacles
var _random_jump_timer: float = 0.0


func setup(player: CharacterBody3D) -> void:
	_player = player
	_player_input = player.get_node("PlayerInput")
	_rng.seed = hash(player.name) + Time.get_ticks_msec()
	_target_yaw = _rng.randf_range(-PI, PI)
	_pick_new_wander_target()

	# Try to get map size from the world generator
	var map := player.get_tree().current_scene
	if map:
		var world := map.get_node_or_null("SeedWorld")
		if world and "map_size" in world:
			_map_half_size = world.map_size * 0.5


func _physics_process(delta: float) -> void:
	if _player == null or _player_input == null:
		return
	# Skip bot AI while loading screen is up
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		_clear_inputs()
		return
	if not _player.is_alive:
		_clear_inputs()
		return

	# --- Scan for combat targets ---
	_combat_scan_timer -= delta
	if _combat_scan_timer <= 0.0:
		_combat_scan_timer = COMBAT_SCAN_INTERVAL
		_scan_for_targets()

	# --- Decide behaviour: combat or wander ---
	if _combat_target != null and is_instance_valid(_combat_target) and _combat_target.is_alive:
		_do_combat(delta)
	else:
		_combat_target = null
		_do_wander(delta)

	# --- Edge avoidance: override direction if near map edge ---
	_apply_edge_avoidance(delta)

	# --- Stuck detection: if barely moving, pick a new target + jump ---
	var horiz_speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if horiz_speed < STUCK_THRESHOLD and _player.is_on_floor():
		_stuck_timer += delta
		if _stuck_timer > STUCK_TIME:
			_stuck_timer = 0.0
			_pick_new_wander_target()
			_player_input.action_jump = true
	else:
		_stuck_timer = 0.0

	# --- Smooth yaw toward target ---
	_player_input.look_yaw = lerp_angle(_player_input.look_yaw, _target_yaw, LOOK_SMOOTHING * delta)
	# Keep pitch level (slight downward for terrain visibility)
	_player_input.look_pitch = lerp(_player_input.look_pitch, -0.1, 2.0 * delta)


func _do_wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_pick_new_wander_target()

	# --- Check for nearby items to pick up ---
	var nearby_item := _find_nearest_item()
	var move_target := _wander_target
	if nearby_item != null:
		move_target = nearby_item.global_position

	# Move toward target
	var to_target := move_target - _player.global_position
	to_target.y = 0.0

	if to_target.length() < 2.0:
		# Arrived — pick a new target
		_pick_new_wander_target()
		_player_input.input_direction = Vector2.ZERO
		return

	# Face the target
	_target_yaw = atan2(-to_target.x, -to_target.z)

	# Always walk forward (input_direction is relative to player facing)
	_player_input.input_direction = Vector2(0, -1)  # Forward in Godot's input system

	# Occasional random jump
	_random_jump_timer -= delta
	if _random_jump_timer <= 0.0:
		_random_jump_timer = _rng.randf_range(4.0, 12.0)
		_player_input.action_jump = true
	else:
		_player_input.action_jump = false

	_player_input.action_shoot = false
	_player_input.action_aim = false


func _do_combat(_delta: float) -> void:
	var target_pos := _combat_target.global_position
	var to_target := target_pos - _player.global_position
	var horiz_to := Vector3(to_target.x, 0, to_target.z)
	var dist := horiz_to.length()

	# Face the target
	if horiz_to.length() > 0.5:
		_target_yaw = atan2(-horiz_to.x, -horiz_to.z)

	# Look up/down toward target
	if dist > 1.0:
		var pitch := atan2(-to_target.y, dist)
		_player_input.look_pitch = clampf(pitch, -1.0, 0.5)

	# Approach if too far, back off if too close
	if dist > SHOOT_RANGE * 0.7:
		_player_input.input_direction = Vector2(0, -1)  # Walk forward
	elif dist < 8.0:
		_player_input.input_direction = Vector2(0, 1)  # Back up
	else:
		# Strafe slightly
		_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), 0)

	# Shoot if facing target and in range
	var facing_dir := Vector3(sin(_player_input.look_yaw), 0, cos(_player_input.look_yaw))
	var angle_to_target := facing_dir.angle_to(horiz_to.normalized()) if horiz_to.length() > 0.5 else PI
	_player_input.action_shoot = dist < SHOOT_RANGE and angle_to_target < SHOOT_ANGLE
	_player_input.action_aim = dist > 15.0 and dist < SHOOT_RANGE
	_player_input.action_jump = false


func _scan_for_targets() -> void:
	_combat_target = null
	var players_container := _player.get_parent()
	if players_container == null:
		return

	var best_dist := SHOOT_RANGE
	for child in players_container.get_children():
		if child == _player:
			continue
		if not child is CharacterBody3D:
			continue
		if not child.get("is_alive"):
			continue
		var dist := _player.global_position.distance_to(child.global_position)
		if dist < best_dist:
			best_dist = dist
			_combat_target = child


func _find_nearest_item() -> Node:
	## Find the nearest WorldItem within PICKUP_RANGE.
	var items_container := _player.get_tree().current_scene.get_node_or_null("WorldItems")
	if items_container == null:
		return null

	var best_dist := PICKUP_RANGE
	var best_item: Node = null
	for item in items_container.get_children():
		if not is_instance_valid(item):
			continue
		var dist := _player.global_position.distance_to(item.global_position)
		if dist < best_dist:
			best_dist = dist
			best_item = item
	return best_item


func _pick_new_wander_target() -> void:
	_wander_timer = _rng.randf_range(WANDER_INTERVAL_MIN, WANDER_INTERVAL_MAX)

	# Pick a random point within WANDER_RADIUS, clamped to safe area
	var safe_limit := _map_half_size - EDGE_MARGIN
	var target_x := _player.global_position.x + _rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS)
	var target_z := _player.global_position.z + _rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS)
	target_x = clampf(target_x, -safe_limit, safe_limit)
	target_z = clampf(target_z, -safe_limit, safe_limit)

	# Query terrain height at target position
	var target_y := _player.global_position.y  # Fallback
	var map := _player.get_tree().current_scene
	if map:
		var world := map.get_node_or_null("SeedWorld")
		if world and world.has_method("get_height_at"):
			target_y = world.get_height_at(target_x, target_z) + 1.0

	_wander_target = Vector3(target_x, target_y, target_z)


func _apply_edge_avoidance(_delta: float) -> void:
	## If near the map edge, steer the bot away from the edge.
	var pos := _player.global_position
	var hard := _map_half_size - EDGE_HARD_MARGIN
	var soft := _map_half_size - EDGE_MARGIN

	var nudge := Vector3.ZERO
	# X edges
	if pos.x > soft:
		nudge.x -= (pos.x - soft) / (hard - soft)
	elif pos.x < -soft:
		nudge.x -= (pos.x + soft) / (hard - soft)
	# Z edges
	if pos.z > soft:
		nudge.z -= (pos.z - soft) / (hard - soft)
	elif pos.z < -soft:
		nudge.z -= (pos.z + soft) / (hard - soft)

	if nudge.length() > 0.1:
		# Override wander target to move away from edge
		_wander_target = _player.global_position + nudge.normalized() * 30.0
		_wander_target.x = clampf(_wander_target.x, -soft, soft)
		_wander_target.z = clampf(_wander_target.z, -soft, soft)
		# Face away from edge
		_target_yaw = atan2(-nudge.x, -nudge.z)

	# Emergency: hard clamp position if somehow past the hard edge
	if absf(pos.x) > hard or absf(pos.z) > hard:
		_player_input.input_direction = Vector2(0, -1)
		_target_yaw = atan2(-nudge.x, -nudge.z) if nudge.length() > 0.01 else _target_yaw


func _clear_inputs() -> void:
	_player_input.input_direction = Vector2.ZERO
	_player_input.action_jump = false
	_player_input.action_shoot = false
	_player_input.action_aim = false
	_player_input.action_slide = false
	_player_input.action_extend = false
	_player_input.action_scrap = false
	_player_input.action_slot = 0
