extends Node
class_name SlideCrouchSystem

## Slide and crouch physics subsystem.
## Owns all slide/crouch constants, state, and physics logic.
## Attached as a child of Player in player.tscn.

## --- Slide constants ---
const SLIDE_INITIAL_SPEED := 12.0    ## Only used as fallback if somehow speed is 0
const SLIDE_FRICTION_COEFF := 0.25   ## Ground friction (lowered for longer, smoother slides)
const SLIDE_MIN_SPEED := 0.5        ## Low threshold — let slides die naturally via physics
const SLIDE_MIN_ENTRY_SPEED := 3.5
const SLIDE_COOLDOWN := 0.4
const SLIDE_CAPSULE_HEIGHT := 1.0
const SLIDE_CAMERA_OFFSET := -0.5
const SLIDE_AIRBORNE_GRACE := 0.2
const SLIDE_SNAP_DOWN := 4.0
const SLIDE_TO_CROUCH_DELAY := 0.3   ## Seconds coasting at low speed before crouch transition
const SLIDE_MAX_SPEED := 20.0        ## Hard cap — raised for fast downhill/momentum slides
const SLIDE_LATERAL_FRICTION := 6.0   ## Reduced so player steering actually works
const SLIDE_STEER_STRENGTH := 8.0    ## How aggressively WASD redirects the slide

## --- Crouch constants ---
const CROUCH_CAPSULE_HEIGHT := 1.0
const CROUCH_CAMERA_OFFSET := -0.5
const CROUCH_SPEED_MULT := 0.5
const CROUCH_MESH_SCALE_Y := 0.55  # Visual squish

## --- Synced state (replicated via ServerSync) ---
var is_sliding: bool = false
var is_crouching: bool = false

## --- Internal state ---
var _slide_velocity: Vector3 = Vector3.ZERO
var _slide_cooldown_timer: float = 0.0
var _slide_airborne_timer: float = 0.0
var _slide_low_speed_timer: float = 0.0
var _slide_smoothed_normal: Vector3 = Vector3.UP  ## Smoothed floor normal to avoid jitter
var _slide_forward_dir: Vector3 = Vector3.ZERO    ## Original slide direction for lateral friction
var _wants_slide_on_land: bool = false             ## Queue slide when landing from a jump
var _slide_on_land_grace: float = 0.0              ## Grace window after landing to trigger slide
var _was_on_floor: bool = true                     ## Track floor state for landing detection
var _pre_land_velocity_y: float = 0.0              ## Vertical speed right before landing

## --- Stored geometry defaults ---
var _original_capsule_height: float = 1.8
var _original_camera_y: float = 1.5
var _original_mesh_y: float = 0.9
var _original_mesh_scale_y: float = 1.0

## Player reference (set during setup)
var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p
	_original_capsule_height = p._original_capsule_height
	_original_camera_y = p._original_camera_y
	_original_mesh_y = p._original_mesh_y
	_original_mesh_scale_y = p._original_mesh_scale_y


## ---- Slide mechanics (server-only) ----

func tick_cooldown(delta: float) -> void:
	## Called each frame from _server_process to decrement slide cooldown.
	if _slide_cooldown_timer > 0.0:
		_slide_cooldown_timer -= delta


func can_start_slide() -> bool:
	if not player.is_on_floor():
		return false
	if _slide_cooldown_timer > 0.0:
		return false
	var horiz_speed := Vector2(player.velocity.x, player.velocity.z).length()
	if horiz_speed < SLIDE_MIN_ENTRY_SPEED:
		return false
	# Block slide initiation only on steep uphill (>~20°) — anything gentler is fine
	var floor_normal := player.get_floor_normal()
	var slope_steepness := sqrt(1.0 - floor_normal.y * floor_normal.y)
	if slope_steepness > 0.35:  # ~20°
		var downhill_3d := (Vector3.DOWN - floor_normal * Vector3.DOWN.dot(floor_normal))
		var downhill_horiz := Vector3(downhill_3d.x, 0.0, downhill_3d.z)
		if downhill_horiz.length() > 0.001:
			var move_dir := Vector3(player.velocity.x, 0.0, player.velocity.z).normalized()
			var alignment := move_dir.dot(downhill_horiz.normalized())
			if alignment < -0.3:
				return false
	return true


func start_slide() -> void:
	is_sliding = true
	is_crouching = false
	_slide_airborne_timer = 0.0
	_slide_low_speed_timer = 0.0
	_slide_smoothed_normal = player.get_floor_normal() if player.is_on_floor() else Vector3.UP
	# Lock slide direction to current movement direction — NO speed boost.
	var horiz := Vector2(player.velocity.x, player.velocity.z)
	var horiz_speed := horiz.length()
	if horiz_speed > 0.01:
		var dir_2d := horiz.normalized()
		_slide_velocity = Vector3(dir_2d.x * horiz_speed, 0.0, dir_2d.y * horiz_speed)
		_slide_forward_dir = _slide_velocity.normalized()
	else:
		# Fallback: slide forward at entry threshold speed
		var forward := -player.transform.basis.z
		_slide_velocity = forward * SLIDE_MIN_ENTRY_SPEED
		_slide_forward_dir = Vector3(forward.x, 0.0, forward.z).normalized()

	apply_lowered_pose(SLIDE_CAPSULE_HEIGHT, SLIDE_CAMERA_OFFSET)


func process_slide(delta: float) -> void:
	## Server-only: physics-based slide.
	## Uses real inclined-plane physics: a = g * (sin(angle)*alignment - friction*cos(angle))

	# --- Jump out of slide: keep all horizontal momentum ---
	if player.player_input.action_jump and player.is_on_floor():
		var saved_hx: float = _slide_velocity.x
		var saved_hz: float = _slide_velocity.z
		# End slide state (may try to transition to crouch, which we override)
		is_sliding = false
		_slide_cooldown_timer = SLIDE_COOLDOWN
		_slide_low_speed_timer = 0.0
		_slide_velocity = Vector3.ZERO
		_slide_forward_dir = Vector3.ZERO
		is_crouching = false
		apply_standing_pose()
		# Set velocity AFTER end_slide so nothing overwrites it
		player.velocity.x = saved_hx
		player.velocity.z = saved_hz
		player.velocity.y = player.JUMP_VELOCITY
		return

	var on_floor := player.is_on_floor()
	var gravity: float = player.gravity

	# --- Airborne grace ---
	if on_floor:
		_slide_airborne_timer = 0.0
	else:
		_slide_airborne_timer += delta

	# --- Smooth the floor normal to prevent jitter on procedural terrain ---
	var raw_normal := player.get_floor_normal() if on_floor else _slide_smoothed_normal
	var smooth_rate := 6.0 * delta
	_slide_smoothed_normal = _slide_smoothed_normal.lerp(raw_normal, clampf(smooth_rate, 0.0, 1.0)).normalized()

	var slope_steepness := sqrt(1.0 - _slide_smoothed_normal.y * _slide_smoothed_normal.y)

	# Downhill direction from smoothed normal (horizontal only)
	var downhill_3d := (Vector3.DOWN - _slide_smoothed_normal * Vector3.DOWN.dot(_slide_smoothed_normal))
	var downhill_horiz := Vector3(downhill_3d.x, 0.0, downhill_3d.z)
	if downhill_horiz.length() > 0.001:
		downhill_horiz = downhill_horiz.normalized()
	else:
		downhill_horiz = Vector3.ZERO

	var slide_dir := _slide_velocity.normalized() if _slide_velocity.length() > 0.01 else Vector3.ZERO
	var alignment := slide_dir.dot(downhill_horiz) if downhill_horiz.length() > 0.001 else 0.0

	# --- On downhill slopes, gently redirect slide toward downhill ---
	if on_floor and slope_steepness > 0.1 and alignment > 0.0:
		var redirect_strength := slope_steepness * 2.5 * delta
		redirect_strength = minf(redirect_strength, 0.5)
		var redirect_spd := _slide_velocity.length()
		var redirected_dir := slide_dir.lerp(downhill_horiz, redirect_strength).normalized()
		_slide_velocity = redirected_dir * redirect_spd
		# Recalculate after redirect
		slide_dir = _slide_velocity.normalized() if _slide_velocity.length() > 0.01 else Vector3.ZERO
		alignment = slide_dir.dot(downhill_horiz) if downhill_horiz.length() > 0.001 else 0.0

	# --- Player steering during slide (camera-relative A/D) ---
	var steer_input: Vector2 = player.player_input.input_direction
	if steer_input.length() > 0.1 and _slide_velocity.length() > 1.0:
		var cam_right: Vector3 = player.camera.global_transform.basis.x
		cam_right.y = 0.0
		if cam_right.length() > 0.001:
			cam_right = cam_right.normalized()
		# Steer laterally based on A/D input (x component)
		var steer_dir: Vector3 = cam_right * steer_input.x * SLIDE_STEER_STRENGTH * delta
		_slide_velocity += steer_dir
		# Update forward dir to track the new velocity direction
		if _slide_velocity.length() > 0.5:
			_slide_forward_dir = _slide_velocity.normalized()
		# Recalculate slide_dir after steering
		slide_dir = _slide_velocity.normalized() if _slide_velocity.length() > 0.01 else Vector3.ZERO
		alignment = slide_dir.dot(downhill_horiz) if downhill_horiz.length() > 0.001 else 0.0

	# --- Unified physics-based slope force ---
	var slope_force: float = 0.0
	if on_floor and slope_steepness > 0.01:
		var sin_angle := slope_steepness
		var cos_angle := _slide_smoothed_normal.y
		slope_force = gravity * (sin_angle * alignment - SLIDE_FRICTION_COEFF * cos_angle)
	else:
		slope_force = -gravity * SLIDE_FRICTION_COEFF

	# Apply force as speed change
	var spd := _slide_velocity.length()
	spd = maxf(spd + slope_force * delta, 0.0)
	spd = minf(spd, SLIDE_MAX_SPEED)
	if spd > 0.01 and slide_dir.length() > 0.001:
		_slide_velocity = slide_dir * spd
	else:
		_slide_velocity = Vector3.ZERO

	# --- Kill lateral drift ---
	if _slide_velocity.length() > 0.01 and _slide_forward_dir.length() > 0.001:
		var forward_speed := _slide_velocity.dot(_slide_forward_dir)
		var forward_component := _slide_forward_dir * forward_speed
		var lateral_component := _slide_velocity - forward_component
		lateral_component = lateral_component.move_toward(Vector3.ZERO, SLIDE_LATERAL_FRICTION * delta)
		_slide_velocity = forward_component + lateral_component
		_slide_forward_dir = _slide_forward_dir.lerp(_slide_velocity.normalized(), 1.5 * delta).normalized()

	# --- Apply velocity ---
	player.velocity.x = _slide_velocity.x
	player.velocity.z = _slide_velocity.z

	if on_floor:
		var speed_factor := _slide_velocity.length() / SLIDE_INITIAL_SPEED
		var snap_force := SLIDE_SNAP_DOWN + gravity * slope_steepness * speed_factor
		player.velocity.y = -snap_force * maxf(slope_steepness, 0.08)
	else:
		player.velocity.y -= gravity * delta

	# --- End conditions ---
	if _slide_velocity.length() < SLIDE_MIN_SPEED:
		_slide_low_speed_timer += delta
	else:
		_slide_low_speed_timer = 0.0

	var should_end := false
	if not player.player_input.action_slide:
		should_end = true
	if not on_floor and _slide_airborne_timer > SLIDE_AIRBORNE_GRACE:
		should_end = true
	if _slide_low_speed_timer > SLIDE_TO_CROUCH_DELAY:
		should_end = true

	if should_end:
		end_slide()


func end_slide() -> void:
	is_sliding = false
	_slide_cooldown_timer = SLIDE_COOLDOWN
	_slide_low_speed_timer = 0.0
	_slide_velocity = Vector3.ZERO
	_slide_forward_dir = Vector3.ZERO

	# Transition to crouch if still holding Ctrl, or if there's no headroom
	if player.player_input.action_slide or not has_headroom():
		var input_dir: Vector2 = player.player_input.input_direction
		if input_dir.length() > 0.1:
			var shoe_bonus: float = player.inventory.get_shoe_speed_bonus() if player.inventory else 0.0
			var crouch_speed: float = player.SPEED * (player.heat_system.get_speed_multiplier() + shoe_bonus) * CROUCH_SPEED_MULT
			var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
			player.velocity.x = direction.x * crouch_speed
			player.velocity.z = direction.z * crouch_speed
		else:
			player.velocity.x = 0.0
			player.velocity.z = 0.0
		start_crouch()
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		apply_standing_pose()


## ---- Crouch mechanics (server-only) ----

func start_crouch() -> void:
	is_crouching = true
	is_sliding = false
	apply_lowered_pose(CROUCH_CAPSULE_HEIGHT, CROUCH_CAMERA_OFFSET)


func process_crouch(delta: float) -> void:
	## Server-only: crouched movement with reduced speed.
	if not player.player_input.action_slide and has_headroom():
		end_crouch()
		return

	# Allow jumping out of crouch
	if player.player_input.action_jump and player.is_on_floor() and has_headroom():
		end_crouch()
		player.velocity.y = player.JUMP_VELOCITY
		return

	# Crouched movement — slower, same acceleration feel
	var shoe_bonus: float = player.inventory.get_shoe_speed_bonus() if player.inventory else 0.0
	var current_speed: float = player.SPEED * (player.heat_system.get_speed_multiplier() + shoe_bonus) * CROUCH_SPEED_MULT
	var input_dir: Vector2 = player.player_input.input_direction
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var horizontal := Vector2(player.velocity.x, player.velocity.z)
	if direction:
		var target: Vector2 = Vector2(direction.x, direction.z) * current_speed
		horizontal = horizontal.move_toward(target, player.ACCELERATION * delta)
	else:
		horizontal = horizontal.move_toward(Vector2.ZERO, player.DECELERATION * delta)

	player.velocity.x = horizontal.x
	player.velocity.z = horizontal.y


func end_crouch() -> void:
	is_crouching = false
	apply_standing_pose()


## ---- Slide-on-land system ----

func clear_slide_on_land() -> void:
	## Clear the queued slide-on-land request (e.g. on new jump).
	_wants_slide_on_land = false


func queue_slide_on_land() -> void:
	## Queue a slide to be triggered when the player next lands.
	_wants_slide_on_land = true


func track_pre_land_velocity() -> void:
	## Call each frame while airborne to capture vertical speed before landing.
	if not _was_on_floor:
		_pre_land_velocity_y = player.velocity.y


func process_landing(delta: float) -> void:
	## Process slide-on-land after move_and_slide. Call from player._server_process.
	var was_airborne := not _was_on_floor
	_was_on_floor = player.is_on_floor()

	if was_airborne and player.is_on_floor() and _wants_slide_on_land:
		# Convert downward velocity into horizontal speed on landing
		var land_speed_bonus := maxf(-_pre_land_velocity_y, 0.0) * 0.5
		if land_speed_bonus > 0.1:
			var horiz_dir := Vector3(player.velocity.x, 0.0, player.velocity.z)
			if horiz_dir.length() < 0.1:
				horiz_dir = -player.transform.basis.z
			horiz_dir = horiz_dir.normalized()
			player.velocity.x += horiz_dir.x * land_speed_bonus
			player.velocity.z += horiz_dir.z * land_speed_bonus
		# Start grace window
		_slide_on_land_grace = 0.15

	# Process grace window
	if _slide_on_land_grace > 0.0 and not is_sliding and not is_crouching:
		_slide_on_land_grace -= delta
		if player.is_on_floor() and can_start_slide():
			_wants_slide_on_land = false
			_slide_on_land_grace = 0.0
			start_slide()
		elif _slide_on_land_grace <= 0.0:
			_wants_slide_on_land = false
			if player.player_input.action_slide:
				start_crouch()


## ---- Shared pose helpers ----

func apply_lowered_pose(capsule_height: float, camera_offset: float) -> void:
	## Shrink capsule, mesh, and lower camera for slide/crouch.
	var col_shape := player.get_node("CollisionShape3D")
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = capsule_height
		col_shape.position.y = capsule_height * 0.5

	var height_ratio := capsule_height / _original_capsule_height
	player.body_mesh.scale.y = _original_mesh_scale_y * height_ratio
	player.body_mesh.position.y = _original_mesh_y * height_ratio

	player.camera_pivot.position.y = _original_camera_y + camera_offset


func apply_standing_pose() -> void:
	## Restore capsule, mesh, and camera to full standing height.
	var col_shape := player.get_node("CollisionShape3D")
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = _original_capsule_height
		col_shape.position.y = _original_capsule_height * 0.5

	player.body_mesh.scale.y = _original_mesh_scale_y
	player.body_mesh.position.y = _original_mesh_y
	player.camera_pivot.position.y = _original_camera_y


func has_headroom() -> bool:
	## Check if there's enough space above to stand up from crouch/slide.
	var space_state := player.get_world_3d().direct_space_state
	var head_pos := player.global_position + Vector3(0, CROUCH_CAPSULE_HEIGHT, 0)
	var stand_pos := player.global_position + Vector3(0, _original_capsule_height + 0.1, 0)
	var query := PhysicsRayQueryParameters3D.create(head_pos, stand_pos)
	query.exclude = [player.get_rid()]
	var result := space_state.intersect_ray(query)
	return result.is_empty()
