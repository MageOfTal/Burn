extends PlayerSubsystem
class_name PlayerMovement

## Player movement subsystem — owns floor detection, grounded position control,
## wall-slide, acceleration, and the Jolt integration undo pipeline.
##
## Delegated from player.gd: player retains _integrate_forces() and
## _physics_process() callbacks but calls into movement at specific points.
## Subsystems access movement state via player.movement (e.g.
## player.movement._is_grounded). Public API is player.is_on_floor() and
## player.get_floor_normal() which proxy here.

# ======================================================================
#  Constants
# ======================================================================

const SPEED := 9.1
const JUMP_VELOCITY := 10.5
const ACCELERATION := 45.0
const DECELERATION := 30.0
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 0.0

const FLOOR_MAX_ANGLE: float = 0.8727  ## 50 degrees — walkable threshold
const SLOPE_MAX_GROUND_ANGLE: float = 1.4835  ## 85 degrees — grounding ceiling
const SLOPE_SLIDE_MAX_SPEED: float = 20.0  ## Terminal velocity for slope gravity
const FLOOR_SNAP_MARGIN: float = 0.3
const CAPSULE_RADIUS: float = 0.4
const FLOOR_CONTACT_TOLERANCE: float = 0.1
const LAUNCH_DOT_THRESHOLD: float = 2.0  ## Quake-style: dot(velocity, normal) above this = launch

# ======================================================================
#  State
# ======================================================================

## Floor detection (raycast-based)
var _is_grounded: bool = false
var _floor_normal: Vector3 = Vector3.UP
var _floor_y: float = -INF
var _was_grounded: bool = false
var _slope_traction: float = 1.0  ## cos(slope_angle): 1.0 = flat, 0.0 = vertical

## Grounded velocity tracking
var _ground_velocity: Vector3 = Vector3.ZERO
var _pre_solver_velocity: Vector3 = Vector3.ZERO
var _undo_jolt_integration: bool = false

## Dynamic body contact tracking (set in on_integrate_forces each tick)
var _touching_dynamic_body: bool = false
var _on_dynamic_body: bool = false
var _dynamic_body_ref: RigidBody3D = null

## Wall-slide normals (individual 2D normals from Jolt contacts)
var _wall_normals: Array[Vector2] = []

## Air-jump tracking
var _air_jumps_used: int = 0

## Post-jump rising suppression (prevents re-grounding on uphill slopes)
var _post_jump_rising: bool = false


# ======================================================================
#  Delegation entry points (called from player.gd)
# ======================================================================

func on_integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	## Sample contact normals for wall-slide and dynamic body tracking.
	## Called from player._integrate_forces() each physics tick.
	_touching_dynamic_body = false
	_on_dynamic_body = false
	_dynamic_body_ref = null

	var wall_angle_threshold := FLOOR_MAX_ANGLE if (_is_grounded or _post_jump_rising) else deg_to_rad(30.0)

	var normals: Array[Vector2] = []
	for i in state.get_contact_count():
		var normal: Vector3 = state.get_contact_local_normal(i)
		var collider := state.get_contact_collider_object(i)
		if collider is RigidBody3D:
			_touching_dynamic_body = true
			_dynamic_body_ref = collider
			if normal.y > 0.7:
				_on_dynamic_body = true
		if normal.angle_to(Vector3.UP) > wall_angle_threshold:
			if collider is RigidBody3D:
				continue
			if _is_grounded and normal.dot(_floor_normal) > 0.9:
				continue
			var n2 := Vector2(normal.x, normal.z).normalized()
			var is_dup := false
			for existing in normals:
				if n2.dot(existing) > 0.966:
					is_dup = true
					break
			if not is_dup:
				normals.append(n2)
	_wall_normals = normals


func pre_physics_step(delta: float) -> void:
	## Undo Jolt position integration and update floor detection.
	## Called at the start of the server block in player._physics_process().
	_was_grounded = _is_grounded

	if _undo_jolt_integration:
		player.global_position -= _pre_solver_velocity * delta
		_undo_jolt_integration = false

	_update_ground_state()


func post_physics_step(delta: float, grapple_active: bool) -> void:
	## Grounded position control and pre-solver velocity save.
	## Called after _server_process() in player._physics_process().
	var on_top_of_lightweight := _on_dynamic_body and _dynamic_body_ref != null \
			and is_instance_valid(_dynamic_body_ref) and _dynamic_body_ref.mass < 20.0
	if is_on_walkable_floor() and _was_grounded and not on_top_of_lightweight \
			and not grapple_active:
		var dx := player.velocity.x * delta
		var dz := player.velocity.z * delta
		player.global_position.x += dx
		player.global_position.z += dz
		if _floor_y > -INF and _floor_normal.y > 0.001:
			var hemi_offset := CAPSULE_RADIUS * (1.0 - _floor_normal.y) / _floor_normal.y
			var estimated_floor_y := _floor_y - (_floor_normal.x * dx + _floor_normal.z * dz) / _floor_normal.y
			player.global_position.y = estimated_floor_y + hemi_offset
		_ground_velocity = player.velocity
		_undo_jolt_integration = true
	elif on_top_of_lightweight and is_on_floor():
		_ground_velocity = player.velocity
	elif is_on_floor() and _was_grounded:
		_ground_velocity = player.velocity

	_pre_solver_velocity = player.velocity


func begin_movement(_delta: float) -> void:
	## Grounded velocity management — restore tracked velocity on floor,
	## hand off to Jolt on air transition. Called at the start of movement
	## in player._server_process().
	# Reset air-jump counter on landing
	if is_on_floor():
		_air_jumps_used = 0

	var _on_dynamic_lightweight := _on_dynamic_body and _dynamic_body_ref != null \
			and is_instance_valid(_dynamic_body_ref) and _dynamic_body_ref.mass < 20.0
	if is_on_walkable_floor() and not _on_dynamic_lightweight:
		if not _was_grounded:
			_ground_velocity = Vector3(_pre_solver_velocity.x, 0.0, _pre_solver_velocity.z)
		player.velocity = _ground_velocity
	elif is_on_floor() and _on_dynamic_lightweight:
		if player.velocity.y < 0.0:
			player.velocity.y = 0.0
	elif _was_grounded:
		player.velocity = _ground_velocity
		_ground_velocity = Vector3.ZERO


func apply_gravity(delta: float) -> void:
	## Apply manual gravity (skip when grounded or sliding).
	if not is_on_floor() and not player.slide_crouch.is_sliding:
		player.velocity.y -= player.gravity * delta


func process_normal_movement(delta: float) -> void:
	## Acceleration-based horizontal movement with wall-slide projection.
	var shoe_bonus: float = player.inventory.get_shoe_speed_bonus() if player.inventory else 0.0
	var bonus_speed: float = 0.0
	if 5 in player.active_bonuses:
		bonus_speed += 0.10
	if player._second_wind_timer > 0.0:
		bonus_speed += 0.50
	var current_speed := SPEED * (player.heat_system.get_speed_multiplier() + shoe_bonus + bonus_speed)
	var input_dir: Vector2 = player.player_input.input_direction
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var horizontal := Vector2(player.velocity.x, player.velocity.z)
	var on_floor := is_on_floor()
	var traction := _slope_traction if on_floor else 1.0

	# --- Slope gravity (downhill pull along surface) ---
	# floor_normal XZ = downhill direction with magnitude sin(angle).
	# Diminish contribution at high speed to create natural terminal velocity.
	if on_floor and _floor_normal.y < 0.999:
		var slope_pull := Vector2(_floor_normal.x, _floor_normal.z) * player.gravity
		var gravity_scale := clampf(1.0 - horizontal.length() / SLOPE_SLIDE_MAX_SPEED, 0.0, 1.0)
		horizontal += slope_pull * gravity_scale * delta

	# --- Wall-slide projection ---
	if direction:
		var target := Vector2(direction.x, direction.z) * current_speed

		var best_normal := Vector2.ZERO
		var best_dot := 0.0
		for wn in _wall_normals:
			var d := target.dot(wn)
			if d < best_dot:
				best_dot = d
				best_normal = wn

		if best_normal != Vector2.ZERO:
			target -= best_normal * target.dot(best_normal)

			var wall_tang := Vector2(-best_normal.y, best_normal.x)
			var perp_speed := horizontal.dot(best_normal)
			var para_speed := horizontal.dot(wall_tang)
			var target_para := target.dot(wall_tang)

			var accel := (ACCELERATION if on_floor else AIR_ACCELERATION) * traction
			para_speed = move_toward(para_speed, target_para, accel * delta)

			var perp_out := maxf(perp_speed, 0.0)

			horizontal = wall_tang * para_speed + best_normal * perp_out

			for wn in _wall_normals:
				var d := horizontal.dot(wn)
				if d < 0.0:
					horizontal -= wn * d
		else:
			if on_floor:
				horizontal = horizontal.move_toward(target, ACCELERATION * traction * delta)
			else:
				var current_mag := horizontal.length()
				var input_dot := horizontal.normalized().dot(target.normalized()) if current_mag > 0.1 else 1.0
				horizontal = horizontal.move_toward(target, AIR_ACCELERATION * delta)
				if horizontal.length() < current_mag and input_dot > 0.0:
					horizontal = horizontal.normalized() * current_mag
	else:
		var decel := (DECELERATION if on_floor else AIR_DECELERATION) * traction
		horizontal = horizontal.move_toward(Vector2.ZERO, decel * delta)

	player.velocity.x = horizontal.x
	player.velocity.z = horizontal.y

	# Velocity dead zone — only on gentle slopes where friction can hold
	if on_floor and not direction and horizontal.length_squared() < 0.01 and _floor_normal.y > 0.85:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		player.velocity.y = 0.0
		return

	# Slope alignment — project velocity onto slope surface
	var on_slope := _floor_normal.dot(Vector3.UP) <= 0.999
	if on_floor and on_slope and not player._frame_jump:
		if _floor_normal.y > 0.3:
			# Walkable slopes: algebraic Y projection
			player.velocity.y = -(_floor_normal.x * player.velocity.x + _floor_normal.z * player.velocity.z) / _floor_normal.y
		else:
			# Steep slopes: vector projection (numerically stable)
			var into_surface := player.velocity.dot(_floor_normal)
			if into_surface < 0.0:
				player.velocity -= _floor_normal * into_surface


func slope_compensated_jump_y() -> float:
	## Returns JUMP_VELOCITY compensated for slope rise at the current horizontal
	## speed, ensuring consistent jump height relative to the ground surface.
	## On flat ground this equals JUMP_VELOCITY. On a slope it adds the slope's
	## Y-rate so the player clears the same height above the surface.
	if _floor_normal.y > 0.3 and _floor_normal.dot(Vector3.UP) < 0.999:
		var slope_y := maxf(-(_floor_normal.x * player.velocity.x + _floor_normal.z * player.velocity.z) / _floor_normal.y, 0.0)
		return slope_y + JUMP_VELOCITY
	return JUMP_VELOCITY


func do_jump() -> void:
	## Ground jump — sets velocity and flags.
	player.velocity.y = slope_compensated_jump_y()
	_is_grounded = false
	_post_jump_rising = true
	player.slide_crouch.clear_slide_on_land()


func do_air_jump() -> bool:
	## Air jump (trinket-granted). Returns true if jump was performed.
	var extra_jumps: int = player.inventory.get_shoe_extra_jumps() if player.inventory else 0
	if _air_jumps_used < extra_jumps:
		player.velocity.y = JUMP_VELOCITY * 1.5
		_air_jumps_used += 1
		_post_jump_rising = true
		return true
	return false


# ======================================================================
#  Floor detection
# ======================================================================

func is_on_floor() -> bool:
	return _is_grounded


func get_floor_normal() -> Vector3:
	return _floor_normal


func is_on_walkable_floor() -> bool:
	return _is_grounded and _floor_normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE


func _update_ground_state() -> void:
	## Downward raycast for floor detection. Must run in _physics_process().
	var space := player.get_world_3d().direct_space_state
	if space == null:
		_is_grounded = false
		_floor_y = -INF
		return

	var origin := player.global_position + Vector3(0, 0.9, 0)
	var end := origin + Vector3(0, -(0.9 + FLOOR_SNAP_MARGIN), 0)
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.TOAD_WALLS | CollisionLayers.TOAD_RAIN | CollisionLayers.WALL_SMOOTH
	query.exclude = [player.get_rid()]

	var result := space.intersect_ray(query)
	if result.is_empty():
		_is_grounded = false
		_floor_normal = Vector3.UP
		_floor_y = -INF
		return

	var normal: Vector3 = result["normal"]
	if normal.angle_to(Vector3.UP) > SLOPE_MAX_GROUND_ANGLE:
		_is_grounded = false
		_floor_normal = Vector3.UP
		_floor_y = -INF
		_slope_traction = 0.0
		return

	# Quake-style launch: if grounded velocity is diverging from the surface,
	# go airborne. On steady slopes dot ≈ 0 (tangent). At convex transitions
	# (crests) the surface flattens but velocity still points uphill → dot > 0.
	if _was_grounded and _ground_velocity.y > 0.5:
		var launch_dot := _ground_velocity.dot(normal)
		if launch_dot > LAUNCH_DOT_THRESHOLD:
			_is_grounded = false
			_floor_normal = Vector3.UP
			_floor_y = -INF
			_slope_traction = 0.0
			return

	_slope_traction = normal.y  # cos(angle) — traction degrades with steepness
	_floor_normal = normal
	_floor_y = result["position"].y

	# Clamp hemi_offset — the hemisphere formula breaks down on steep slopes
	# where the capsule cylinder contacts the surface, not the bottom hemisphere.
	var hemi_offset := minf(CAPSULE_RADIUS * (1.0 - normal.y) / maxf(normal.y, 0.01),
			CAPSULE_RADIUS * 2.0)
	var feet_gap := player.global_position.y - (_floor_y + hemi_offset)
	if _is_grounded:
		_is_grounded = feet_gap <= FLOOR_SNAP_MARGIN
	else:
		_is_grounded = feet_gap <= FLOOR_CONTACT_TOLERANCE

	# Post-jump rising suppression
	if _post_jump_rising:
		if player.velocity.y > 0.0:
			_is_grounded = false
		else:
			_post_jump_rising = false

	# On-top-of-dynamic-body override
	if _on_dynamic_body and _dynamic_body_ref != null \
			and is_instance_valid(_dynamic_body_ref) \
			and _dynamic_body_ref.mass < 20.0 \
			and player.velocity.y <= 0.0:
		_is_grounded = true


# ======================================================================
#  Reset
# ======================================================================

func reset_movement() -> void:
	## Reset movement state on respawn.
	_air_jumps_used = 0
	_wall_normals = []
	_ground_velocity = Vector3.ZERO
	_pre_solver_velocity = Vector3.ZERO
	_undo_jolt_integration = false
	_post_jump_rising = false
	_is_grounded = false
	_floor_normal = Vector3.UP
	_floor_y = -INF
	_slope_traction = 1.0
