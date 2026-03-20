extends PlayerSubsystem
class_name PlayerMovement

## Player movement subsystem.
##
## Uses RigidBody3D with custom_integrator=true. Jolt handles position
## integration and collision response. This script sets velocity each frame;
## Jolt integrates it next frame.
##
## Ground detection is contact-based. Slope projection keeps velocity
## tangent to the surface. Jolt handles contact pressure and penetration
## recovery directly — no velocity override or artificial bias needed.

# ======================================================================
#  Constants (referenced by slide_crouch_system.gd)
# ======================================================================

const SPEED := 9.0
const JUMP_VELOCITY := 10.5
const WALK_ACCEL: float = 30.33
const AIR_ACCELERATION := 15.0

const FLOOR_MAX_ANGLE: float = 0.8727  ## 50° — walkable
const JUMP_MAX_ANGLE: float = 1.4835   ## 85° — jumpable

## Below this horizontal speed, direction reversal causes an instant stop.
const DIME_STOP_SPEED: float = 6.0

## Epsilon for central-difference terrain normal calculation (meters).
const SDF_NORMAL_EPS: float = 0.5

## Above this horizontal speed, the player enters "skid" mode — they can
## only steer and decelerate, not accelerate toward their movement direction.
const SKID_THRESHOLD: float = 55.0
const SKID_FRICTION: float = 20.0
const SKID_STEER_STRENGTH: float = 3.0


# ======================================================================
#  State (read by player.gd, slide_crouch_system.gd, player_hud.gd)
# ======================================================================

var _is_grounded: bool = false
var _floor_normal: Vector3 = Vector3.UP
var _was_grounded: bool = false
var _last_grounded_time: float = 0.0
var _last_jolt_grounded_time: float = 0.0

var _has_floor_contact: bool = false
var _has_jumpable_contact: bool = false
var _best_contact_normal: Vector3 = Vector3.ZERO

var _obstacle_normals: Array[Vector2] = []  ## Debug only (read by player.gd)

var _ground_velocity: Vector3 = Vector3.ZERO
var _air_jumps_used: int = 0
var _post_jump_rising: bool = false
var _post_jump_timer: float = 0.0
const POST_JUMP_DURATION: float = 0.25


## Horizontal velocity saved at end of each airborne frame (before Jolt integrates).
## Restored on landing to undo Jolt's slope deflection of falling velocity.
var _airborne_hvel: Vector3 = Vector3.ZERO

## Pre-impulse vel.y from Jolt contact listener. The velocity that would have
## penetrated past the walkable surface. Used as snap distance budget.
var _snap_vel_y: float = 0.0

## Cached SeedWorld reference for noise-based terrain height queries.
var _cached_seed_world: Node = null

## Contact state sampled from on_integrate_forces
var _contact_count: int = 0
var _contacts: Array[Dictionary] = []  ## [{normal, body, is_walkable, is_jumpable}]

## Debug (read by player_hud.gd)
var _momentum_launch_flash: float = 0.0
var _momentum_launch_reason: String = ""
var _dbg_contact_body_class: String = ""

# ── Ground-transition debug ring buffer ──────────────────────────────
const DBG_RING_SIZE := 10
var _dbg_ring: Array[Dictionary] = []
var _dbg_frame_num: int = 0
var _dbg_cur: Dictionary = {}           # current frame being built
var _dbg_after_count: int = -1          # frames still to capture after transition
const DBG_AFTER_FRAMES := 3

# ── Debug: previous-frame tracking for deltas ──
var _dbg_prev_set_vel: Vector3 = Vector3.ZERO   # velocity we SET last frame
var _dbg_prev_pos: Vector3 = Vector3.ZERO        # position last frame
var _dbg_prev_contact_count: int = 0
var _dbg_pos_drift: Vector3 = Vector3.ZERO       # position drift from Jolt (computed early in on_integrate_forces)
var _dbg_vel_delta: Vector3 = Vector3.ZERO        # velocity change by Jolt
var _dbg_prev_wall_nh: Vector3 = Vector3.ZERO     # previous frame's primary wall normal (horizontal)
var _dbg_is_overlapping: bool = false             # is the capsule overlapping something
var _dbg_prev_set_vel_y: float = 0.0                  # vel.y we set last frame (for ground snap)



# ======================================================================
#  Pipeline step 1: on_integrate_forces — sample contacts from Jolt
# ======================================================================

func on_integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	Profiler.begin("movement_integrate")

	# ── Drift diagnostics: measure how Jolt moved position vs our intent ──
	_dbg_pos_drift = state.transform.origin - _dbg_prev_pos - _dbg_prev_set_vel * state.step
	_dbg_vel_delta = state.linear_velocity - _dbg_prev_set_vel

	# Log when Jolt significantly changed our horizontal velocity direction
	if GameManager.debug_grounding_log:
		var set_h := Vector3(_dbg_prev_set_vel.x, 0.0, _dbg_prev_set_vel.z)
		var jolt_h := Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z)
		var diff_h := jolt_h - set_h
		if set_h.length() > 1.0 and diff_h.length() > 0.5:
			print("[DEFLECT] we_set=(%.2f,%.2f) jolt=(%.2f,%.2f) diff=(%.2f,%.2f) len=%.2f grounded=%s cc=%d" % [
				set_h.x, set_h.z, jolt_h.x, jolt_h.z, diff_h.x, diff_h.z,
				diff_h.length(), state.is_grounded_by_contact(), state.get_contact_count()])

	# Grounding set entirely by Jolt's contact listener during the solve.
	# Walkable (≤50°) contacts zero vel.y and ground.
	# Jumpable (≤85°) contacts ground without zeroing vel.y.
	# No contacts = airborne.
	_is_grounded = state.is_grounded_by_contact()
	state.clear_grounded_by_contact()
	if _is_grounded:
		_last_jolt_grounded_time = Time.get_ticks_msec() / 1000.0

	# Maintain horizontal velocity on walkable contacts (like Unreal's
	# MaintainHorizontalGroundVelocity). The solver deflects horizontal
	# direction when resolving slope contacts — correct for rigid bodies,
	# wrong for characters. Restore our horizontal velocity when the only
	# contacts are walkable floors. If there are wall contacts, the solver's
	# horizontal changes are wanted (wall sliding), so keep them.
	if _is_grounded:
		var has_static_wall := false
		var has_dynamic := false
		for i in state.get_contact_count():
			var collider := state.get_contact_collider_object(i)
			if state.get_contact_local_normal(i).angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
				if collider is RigidBody3D:
					has_dynamic = true
				else:
					has_static_wall = true
					break
		if (not has_static_wall or GameManager.debug_restore_with_walls) and not GameManager.debug_no_floor_speed_restore:
			var set_h := Vector3(_dbg_prev_set_vel.x, 0.0, _dbg_prev_set_vel.z)
			var jolt_speed := Vector2(state.linear_velocity.x, state.linear_velocity.z).length()
			var set_speed := Vector2(set_h.x, set_h.z).length()

			# Per-contact breakdown: show every contact's contribution
			if GameManager.debug_grounding_log and (has_dynamic or set_speed - jolt_speed > 0.3):
				var total_h_impulse := 0.0
				for i in state.get_contact_count():
					var collider := state.get_contact_collider_object(i)
					var impulse := state.get_contact_impulse(i)
					var normal := state.get_contact_local_normal(i)
					var h_impulse := Vector2(impulse.x, impulse.z).length()
					total_h_impulse += h_impulse
					var body_type := "static"
					var body_mass := 0.0
					if collider is RigidBody3D:
						body_type = "dynamic(%.0fkg)" % (collider as RigidBody3D).mass
						body_mass = (collider as RigidBody3D).mass
					elif collider is VoxelLodTerrain:
						body_type = "terrain"
					print("[CONTACT %d/%d] %s n=(%.2f,%.2f,%.2f) imp=(%.1f,%.1f,%.1f) h_imp=%.2f dv=%.3f" % [
						i, state.get_contact_count(), body_type,
						normal.x, normal.y, normal.z,
						impulse.x, impulse.y, impulse.z,
						h_impulse, h_impulse / player.mass])
				var explained := total_h_impulse / player.mass
				print("[SOLVER] set=%.2f jolt=%.2f loss=%.2f explained=%.2f unexplained=%.2f restore_to=%.2f" % [
					set_speed, jolt_speed, set_speed - jolt_speed, explained,
					(set_speed - jolt_speed) - explained,
					maxf(set_speed - (total_h_impulse / player.mass if not GameManager.debug_no_dynamic_speed_restore else 0.0), 0.0)])

			# Restore intended velocity + dynamic body impulses.
			# Start from what we intended (undoes floor deflection),
			# then add back the dynamic body impulse vector (preserves
			# explosion pushes, grapple pulls, toad bumps).
			var dynamic_delta := Vector3.ZERO
			if not GameManager.debug_no_dynamic_speed_restore:
				for i in state.get_contact_count():
					var collider := state.get_contact_collider_object(i)
					if collider is RigidBody3D:
						var imp := state.get_contact_impulse(i)
						dynamic_delta += Vector3(imp.x, 0.0, imp.z) / player.mass
			var restore_h := set_h + dynamic_delta
			if GameManager.debug_restore_full_speed:
				restore_h = set_h
			var vel := state.linear_velocity
			vel.x = restore_h.x
			vel.z = restore_h.z
			state.linear_velocity = vel

	# Read pre-impulse vel.y from Jolt contact listener (the velocity that
	# would have penetrated past the walkable surface). Used as snap budget.
	_snap_vel_y = state.get_zeroed_vel_y()
	state.clear_zeroed_vel_y()

	_contact_count = state.get_contact_count()
	_contacts.clear()

	for i in _contact_count:
		var normal := state.get_contact_local_normal(i)
		var body := state.get_contact_collider_object(i)
		var angle_to_up := normal.angle_to(Vector3.UP)

		_contacts.append({
			"normal": normal,
			"body": body,
			"is_walkable": angle_to_up <= FLOOR_MAX_ANGLE,
			"is_jumpable": angle_to_up <= JUMP_MAX_ANGLE,
		})

	# Debug: record class of first contact body
	if _contacts.size() > 0 and _contacts[0]["body"] != null:
		_dbg_contact_body_class = _contacts[0]["body"].get_class()
	else:
		_dbg_contact_body_class = ""

	# ── DBG: start new frame capture ──
	_dbg_cur = {}
	_dbg_cur["frame"] = _dbg_frame_num
	_dbg_cur["int_pos"] = player.global_position
	_dbg_cur["int_vel"] = player.linear_velocity
	_dbg_cur["int_contact_count"] = _contact_count
	_dbg_cur["int_step"] = state.step
	_dbg_cur["int_pos_drift"] = _dbg_pos_drift
	_dbg_cur["int_vel_delta"] = _dbg_vel_delta
	var dbg_contacts: Array[Dictionary] = []
	var dbg_body_ids: Array[int] = []
	for i in _contact_count:
		var n: Vector3 = state.get_contact_local_normal(i)
		var pos: Vector3 = state.get_contact_local_position(i)
		var col_pos: Vector3 = state.get_contact_collider_position(i)
		var body = state.get_contact_collider_object(i)
		var cls: String = body.get_class() if body != null else "null"
		var bname := ""
		if body is Node:
			bname = body.name
			if body.get_parent():
				bname = body.get_parent().name + "/" + bname
		var bid: int = body.get_instance_id() if body != null else 0
		dbg_body_ids.append(bid)
		var angle := rad_to_deg(n.angle_to(Vector3.UP))
		dbg_contacts.append({
			"normal": n, "angle": angle, "local_pos": pos,
			"collider_pos": col_pos, "body_class": cls,
			"body_name": bname, "body_id": bid,
			"walkable": angle <= rad_to_deg(FLOOR_MAX_ANGLE),
			"impulse": state.get_contact_impulse(i),
		})
	var unique_bodies := {}
	for bid in dbg_body_ids:
		unique_bodies[bid] = true
	_dbg_cur["int_multi_body"] = unique_bodies.size() > 1
	_dbg_cur["int_unique_body_count"] = unique_bodies.size()
	_dbg_cur["int_contacts"] = dbg_contacts

	# ── DBG: velocity/position deltas (what we set vs what Jolt reports) ──
	_dbg_cur["int_vel_we_set"] = _dbg_prev_set_vel
	_dbg_cur["int_vel_jolt_reports"] = player.linear_velocity
	_dbg_cur["int_vel_delta"] = player.linear_velocity - _dbg_prev_set_vel
	var pos_delta := player.global_position - _dbg_prev_pos
	_dbg_cur["int_pos_delta"] = pos_delta
	_dbg_cur["int_prev_contact_count"] = _dbg_prev_contact_count

	_dbg_prev_contact_count = _contact_count
	Profiler.end("movement_integrate")


# ======================================================================
#  Pipeline step 2: pre_physics_step — update ground state from contacts
# ======================================================================

func pre_physics_step(delta: float) -> void:
	Profiler.begin("movement_pre_step")
	# NOTE: _was_grounded is saved at end of frame in post_physics_step,
	# NOT here. on_integrate_forces already updated _is_grounded before
	# this runs, so copying here would make both values identical and
	# landing detection (_is_grounded and not _was_grounded) would never fire.

	# Determine ground state purely from contacts.
	_has_floor_contact = false
	_has_jumpable_contact = false
	_best_contact_normal = Vector3.ZERO

	var best_cont_dot: float = -2.0
	var best_up_dot: float = -1.0
	var cont_normal: Vector3 = Vector3.ZERO
	var up_normal: Vector3 = Vector3.ZERO

	for c in _contacts:
		var normal: Vector3 = c["normal"]
		var dot_up := normal.dot(Vector3.UP)

		if c["is_jumpable"]:
			_has_jumpable_contact = true

		if c["is_walkable"]:
			_has_floor_contact = true
			# Continuity: prefer normal closest to previous floor normal
			var d := normal.dot(_floor_normal)
			if d > best_cont_dot:
				best_cont_dot = d
				cont_normal = normal
			# Fallback: most upright
			if dot_up > best_up_dot:
				best_up_dot = dot_up
				up_normal = normal

	if _has_floor_contact:
		# When already grounded, prefer continuity to avoid anomalous
		# contacts at mesh triangle boundaries causing slope jumps.
		if _was_grounded and best_cont_dot > 0.85:
			_best_contact_normal = cont_normal
		else:
			_best_contact_normal = up_normal

	# Steep non-walkable slopes (50-85°): Jolt marks these as grounded
	# (jumpable), but we should slide down them, not stand. Only count
	# as grounded if there's an actual walkable contact.
	if _is_grounded and not _has_floor_contact:
		_is_grounded = false

	# While rising from a jump, override Jolt's grounding — the capsule
	# may still overlap the floor for a frame or two.
	if _post_jump_rising:
		_post_jump_timer -= delta
		if _post_jump_timer <= 0.0 or player.velocity.y <= 0.0:
			_post_jump_rising = false
		else:
			_is_grounded = false

	# Grounding is set entirely by Jolt (in on_integrate_forces).
	# Just update the floor normal from contacts.
	var _dbg_grounding_reason := "jolt"
	if _has_floor_contact:
		_floor_normal = _best_contact_normal

	# ── DBG: pre_physics_step capture ──
	_dbg_cur["pre_was_grounded"] = _was_grounded
	_dbg_cur["pre_has_floor_contact"] = _has_floor_contact
	_dbg_cur["pre_has_jumpable"] = _has_jumpable_contact
	_dbg_cur["pre_best_normal"] = _best_contact_normal
	_dbg_cur["pre_post_jump_rising"] = _post_jump_rising
	_dbg_cur["pre_grounding_reason"] = _dbg_grounding_reason
	_dbg_cur["pre_is_grounded"] = _is_grounded
	_dbg_cur["pre_floor_normal"] = _floor_normal
	_dbg_cur["pre_vel"] = player.velocity

	# Decay momentum launch flash
	if _momentum_launch_flash > 0.0:
		_momentum_launch_flash -= delta
		if _momentum_launch_flash < 0.0:
			_momentum_launch_flash = 0.0

	# Debug: all non-primary-floor contacts (read by player.gd for logging)
	_obstacle_normals.clear()
	for c in _contacts:
		var n: Vector3 = c["normal"]
		if _is_grounded and n.distance_to(_best_contact_normal) < 0.01:
			continue
		_obstacle_normals.append(Vector2(n.x, n.z))
	Profiler.end("movement_pre_step")


# ======================================================================
#  Pipeline step 3: begin_movement — reset air jumps on landing
# ======================================================================

func begin_movement(delta: float) -> void:
	_dbg_cur["begin_vel_before"] = player.velocity
	var _dbg_landing := false
	if _is_grounded and not _was_grounded:
		_dbg_landing = true
		if not GameManager.debug_no_landing_restore:
			player.velocity.x = _airborne_hvel.x
			player.velocity.z = _airborne_hvel.z
			player.velocity.y = 0.0
		_air_jumps_used = 0
	_dbg_cur["begin_landing_fired"] = _dbg_landing
	_dbg_cur["begin_vel_after"] = player.velocity


# ======================================================================
#  Pipeline step 4: apply_gravity
# ======================================================================

func apply_gravity(delta: float) -> void:
	_dbg_cur["grav_vel_before"] = player.velocity
	player.velocity.y -= player.gravity * delta
	_dbg_cur["grav_vel_after"] = player.velocity
	_dbg_cur["grav_amount"] = player.gravity * delta


# ======================================================================
#  Pipeline step 5: process_normal_movement — walk/stop/skid/air
# ======================================================================

func process_normal_movement(delta: float) -> void:
	Profiler.begin("movement_normal")
	var input_dir: Vector2 = player.player_input.input_direction
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized() \
		if input_dir.length() > 0.1 else Vector3.ZERO

	# Wall projection: if pressing into a wall, project input along the wall
	# surface. The projected length is the cosine of the approach angle —
	# this scales both max speed and current speed so wall sliding feels
	# like normal movement at a reduced rate.
	var wall_speed_fraction: float = 1.0
	if direction != Vector3.ZERO and _is_grounded and not GameManager.debug_no_wall_proj:
		# Find the wall we're pressing most into
		var best_into: float = 0.0
		var best_wall_nh := Vector3.ZERO
		for c in _contacts:
			if not c["is_walkable"]:
				# Dynamic bodies aren't walls — the solver handles the collision
				if c["body"] is RigidBody3D and not GameManager.debug_wall_proj_dynamic:
					continue
				var wall_n: Vector3 = c["normal"]
				var wall_nh := Vector3(wall_n.x, 0.0, wall_n.z)
				if wall_nh.length_squared() > 0.01:
					wall_nh = wall_nh.normalized()
					var into_wall := direction.dot(wall_nh)
					if into_wall < best_into:
						best_into = into_wall
						best_wall_nh = wall_nh
		# Project input along that wall
		if best_into < 0.0:
			direction -= best_wall_nh * best_into
			wall_speed_fraction = direction.length()
			if wall_speed_fraction > 0.01:
				direction = direction.normalized()
			else:
				direction = Vector3.ZERO
				wall_speed_fraction = 0.0

		if GameManager.debug_no_wall_speed_scale:
			wall_speed_fraction = 1.0

	# Calculate effective max speed with all bonuses
	var shoe_bonus: float = player.inventory.get_shoe_speed_bonus() if player.inventory else 0.0
	var heat_mult: float = player.heat_system.get_speed_multiplier()
	var speed_mult: float = heat_mult + shoe_bonus
	# Bonus 5: Adrenaline Rush (+10% speed)
	if 5 in player.active_bonuses:
		speed_mult += 0.1
	# Bonus 12: Second Wind (5s speed boost on respawn)
	if player._second_wind_timer > 0.0:
		speed_mult += 0.3
	var max_speed: float = SPEED * speed_mult * wall_speed_fraction
	# Debug override
	if GameManager.debug_speed_50:
		max_speed = 50.0 * wall_speed_fraction

	var accel: float = WALK_ACCEL if _is_grounded else AIR_ACCELERATION
	if GameManager.debug_instant_accel:
		accel = 9999.0

	# Current horizontal velocity
	var hvel := Vector3(player.velocity.x, 0.0, player.velocity.z)
	var hspeed := hvel.length()
	# Cap current speed to wall-adjusted max so hitting a wall at an angle
	# immediately reduces speed to the trigonometric fraction
	if wall_speed_fraction < 1.0 and hspeed > max_speed:
		hvel = hvel.normalized() * max_speed
		hspeed = max_speed

	# Wall-perp debugging: identify primary wall normal for tracing
	var _dbg_wall_nh := Vector3.ZERO
	if _is_grounded:
		for c in _contacts:
			if not c["is_walkable"]:
				var n: Vector3 = c["normal"]
				var nh := Vector3(n.x, 0.0, n.z)
				if nh.length_squared() > 0.001:
					_dbg_wall_nh = nh.normalized()
					break
	if _dbg_wall_nh != Vector3.ZERO:
		_dbg_cur["wall_nh"] = _dbg_wall_nh
		_dbg_cur["wall_nh_stable"] = _dbg_wall_nh.distance_to(_dbg_prev_wall_nh) < 0.05
		_dbg_cur["wall_perp_set_prev"] = Vector3(_dbg_prev_set_vel.x, 0.0, _dbg_prev_set_vel.z).dot(_dbg_wall_nh)
		_dbg_cur["wall_perp_jolt_d"] = Vector3(_dbg_vel_delta.x, 0.0, _dbg_vel_delta.z).dot(_dbg_wall_nh)
		_dbg_cur["wall_perp_s0"] = hvel.dot(_dbg_wall_nh)

	_dbg_cur["move_type"] = "normal"
	_dbg_cur["move_input"] = input_dir
	_dbg_cur["move_hvel_before"] = hvel
	_dbg_cur["move_hspeed_before"] = hspeed
	_dbg_cur["move_vel_before"] = player.velocity

	var use_ground := _is_grounded or GameManager.debug_always_ground_move
	if use_ground:
		hvel = _process_ground_movement(hvel, hspeed, direction, max_speed, accel, delta)
		if _dbg_wall_nh != Vector3.ZERO:
			_dbg_cur["wall_perp_s1"] = hvel.dot(_dbg_wall_nh)
		if _dbg_wall_nh != Vector3.ZERO:
			_dbg_cur["wall_perp_s2"] = hvel.dot(_dbg_wall_nh)
	else:
		hvel = _process_air_movement(hvel, hspeed, direction, max_speed, accel, delta)

	_dbg_cur["move_hvel_after"] = hvel

	player.velocity.x = hvel.x
	player.velocity.z = hvel.z

	_dbg_cur["move_slope_projected"] = false
	_dbg_cur["move_surface_y"] = 0.0
	_dbg_cur["move_slope_normal"] = Vector3.ZERO

	# Slope projection: set vel.y tangent to surface when grounded
	if _is_grounded and _has_floor_contact and not GameManager.debug_no_slope_projection:
		var n := _floor_normal
		var surface_y := -(n.x * hvel.x + n.z * hvel.z) / n.y
		player.velocity.y = surface_y
		_dbg_cur["move_slope_projected"] = true
		_dbg_cur["move_surface_y"] = surface_y
		_dbg_cur["move_slope_normal"] = n
		# Surface press: add a small downward bias to maintain floor contact
		if GameManager.debug_grounding_surface_press:
			player.velocity.y -= GameManager.debug_grounding_press_strength

	# Snap + gravity are applied in apply_snap_and_gravity(), called from
	# player._server_process after all movement branches (slide/crouch/normal)
	# so they run every frame regardless of movement state.
	var _dbg_applied_gravity := false
	var _dbg_snap_hit := false
	if player.capture_movement:
		var gnd_tag := "GND" if _is_grounded else "AIR"
		var gnd_src: String = _dbg_cur.get("pre_grounding_reason", "?")
		print("  [GRAV] %s src=%s gravity=%s snap=%s vel.y=%.3f pos.y=%.3f cc=%d" % [
			gnd_tag, gnd_src,
			str(_dbg_applied_gravity),
			"n/a",
			player.velocity.y,
			player.global_position.y,
			_contact_count])

	_dbg_cur["move_vel_final"] = player.velocity
	_dbg_cur["move_pos_final"] = player.global_position
	if _dbg_wall_nh != Vector3.ZERO:
		_dbg_cur["wall_perp_s3"] = Vector3(player.velocity.x, 0.0, player.velocity.z).dot(_dbg_wall_nh)
		_dbg_prev_wall_nh = _dbg_wall_nh
	else:
		_dbg_prev_wall_nh = Vector3.ZERO
	Profiler.end("movement_normal")




func _do_snap(snap_dist: float) -> bool:
	## Cast capsule downward by snap_dist. If walkable static ground is hit,
	## snap position to it. Returns true if snapped.
	var space := player.get_world_3d().direct_space_state
	var col_shape: CollisionShape3D = player.get_node("CollisionShape3D")
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = col_shape.shape
	params.transform = col_shape.global_transform
	params.motion = Vector3(0, snap_dist, 0)
	params.collision_mask = player.collision_mask
	params.exclude = [player.get_rid()]
	var result := space.cast_motion(params)
	var _dbg_log := GameManager.debug_grounding_log and not _is_grounded
	if result[1] < 1.0:
		# Move query to collision point so get_rest_info finds the contact
		var collision_params := PhysicsShapeQueryParameters3D.new()
		collision_params.shape = params.shape
		collision_params.transform = params.transform
		collision_params.transform.origin += params.motion * result[1]
		collision_params.collision_mask = params.collision_mask
		collision_params.exclude = params.exclude
		var rest := space.get_rest_info(collision_params)
		if rest and rest.normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			var collider := instance_from_id(rest.collider_id)
			if collider is StaticBody3D or collider is VoxelLodTerrain:
				if _dbg_log:
					print("[SNAP] HIT static dist=%.4f safe=%.4f unsafe=%.4f normal=(%.2f,%.2f,%.2f)" % [
						snap_dist, result[0], result[1], rest.normal.x, rest.normal.y, rest.normal.z])
				# Use safe fraction (just above surface) not unsafe (at/inside surface).
				# Unsafe causes penetration → Jolt depenetrates by pushing the capsule
				# out along the normal → launches us off the surface → grounding flicker.
				player.global_position.y += snap_dist * result[0]
				if not GameManager.debug_grounding_no_snap_ground:
					_is_grounded = true
					_floor_normal = rest.normal
					_has_floor_contact = true
				# Landing: restore airborne hvel + slope-project vel.y
				player.velocity.x = _airborne_hvel.x
				player.velocity.z = _airborne_hvel.z
				var n: Vector3 = rest.normal
				player.velocity.y = -(n.x * player.velocity.x + n.z * player.velocity.z) / n.y
				return true
			elif collider is RigidBody3D:
				if _dbg_log:
					print("[SNAP] HIT dynamic — skipped")
				return false
			else:
				if _dbg_log:
					print("[SNAP] HIT unknown body: %s" % collider.get_class())
				return false
		else:
			if _dbg_log:
				var angle := rad_to_deg(rest.normal.angle_to(Vector3.UP)) if rest else -1.0
				print("[SNAP] HIT but not walkable angle=%.1f° dist=%.4f" % [angle, snap_dist])
	else:
		if _dbg_log:
			print("[SNAP] MISS dist=%.4f pos.y=%.3f vel.y=%.2f" % [snap_dist, player.global_position.y, player.velocity.y])
	return false


func _update_overlap_debug() -> void:
	## Debug-only: check if the capsule overlaps anything (for HUD indicator).
	var overlap_space := player.get_world_3d().direct_space_state
	var overlap_params := PhysicsShapeQueryParameters3D.new()
	overlap_params.shape = player.get_node("CollisionShape3D").shape
	overlap_params.transform = player.get_node("CollisionShape3D").global_transform
	overlap_params.collision_mask = player.collision_mask
	overlap_params.exclude = [player.get_rid()]
	var overlap_results := overlap_space.intersect_shape(overlap_params, 8)
	_dbg_is_overlapping = not overlap_results.is_empty()
	if _dbg_is_overlapping:
		var ppos := player.global_position
		var vel_y := player.linear_velocity.y
		for r in overlap_results:
			var col = instance_from_id(r.collider_id)
			var shape_name := "?"
			if col is CollisionObject3D:
				# Guard against shapes mid-registration (terrain threading)
				var owner_id: int = -1
				var shape_node: Node = null
				if col.get_shape_owners().size() > 0:
					owner_id = col.shape_find_owner(r.shape) if r.shape >= 0 else -1
				if owner_id >= 0:
					shape_node = col.shape_owner_get_owner(owner_id)
				if shape_node:
					shape_name = shape_node.name
					var spos: Vector3 = shape_node.global_position if shape_node is Node3D else Vector3.ZERO
					print("  [OVERLAP] player=(%.1f,%.1f,%.1f) vel_y=%.2f shape=%d name=%s shape_pos=(%.1f,%.1f,%.1f)" % [
						ppos.x, ppos.y, ppos.z, vel_y, r.shape, shape_name, spos.x, spos.y, spos.z])
				else:
					print("  [OVERLAP] player=(%.1f,%.1f,%.1f) vel_y=%.2f shape=%d owner_id=%d collider=%s" % [
						ppos.x, ppos.y, ppos.z, vel_y, r.shape, owner_id, col])


func _process_ground_movement(hvel: Vector3, hspeed: float, direction: Vector3, max_speed: float, accel: float, delta: float) -> Vector3:
	if direction == Vector3.ZERO:
		# No input: instant stop (below skid threshold)
		if hspeed <= SKID_THRESHOLD:
			return Vector3.ZERO
		else:
			# In skid with no input: friction slows us down
			return hvel.move_toward(Vector3.ZERO, SKID_FRICTION * delta)

	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	# No hdir wall projection — Jolt handles wall contacts via the
	# contact solver. We just accelerate toward the input direction.

	# Check if we're in skid territory
	if hspeed >= SKID_THRESHOLD:
		# SKID: can only steer and decelerate
		return _process_skid(hvel, hspeed, hdir, delta)

	# Dime stop: below DIME_STOP_SPEED, strip any velocity component opposing
	# the new input direction. Moving NE and pressing W kills the east component
	# but keeps north. Moving E and pressing W zeroes everything.
	if hspeed > 0.01 and hspeed <= DIME_STOP_SPEED and not GameManager.debug_no_dime_stop:
		var vel_along_input := hvel.dot(hdir)
		if vel_along_input < 0.0:
			hvel -= hdir * vel_along_input
			hspeed = hvel.length()

	# Accelerate toward input direction up to max speed
	var vel_toward_target := hvel.dot(hdir)

	if vel_toward_target < max_speed:
		var speed_add := accel * delta
		var new_toward := minf(vel_toward_target + speed_add, max_speed)
		hvel += hdir * (new_toward - vel_toward_target)

	# Clamp to max speed (only if we're accelerating, not if external forces pushed us)
	var new_speed := hvel.length()
	if new_speed > max_speed and new_speed > hspeed:
		hvel = hvel.normalized() * max_speed

	return hvel


func _process_skid(hvel: Vector3, hspeed: float, input_dir: Vector3, delta: float) -> Vector3:
	## Skid mode: player can only steer their current velocity direction
	## and decelerate. Cannot accelerate toward movement direction.
	var current_dir := hvel.normalized()

	# Steer: rotate velocity direction toward input
	var steer_amount := SKID_STEER_STRENGTH * delta
	var new_dir := current_dir.lerp(input_dir, clampf(steer_amount, 0.0, 1.0)).normalized()

	# Friction: strong ground friction decelerates
	var new_speed := maxf(hspeed - SKID_FRICTION * delta, 0.0)

	return new_dir * new_speed


func _process_air_movement(hvel: Vector3, hspeed: float, direction: Vector3, max_speed: float, accel: float, delta: float) -> Vector3:
	if direction == Vector3.ZERO:
		return hvel  # No air friction — maintain momentum

	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	# Air acceleration: accelerate in the desired direction at reduced rate
	var vel_toward_target := hvel.dot(hdir)

	if vel_toward_target < max_speed:
		var speed_add := accel * delta
		var new_toward := minf(vel_toward_target + speed_add, max_speed)
		hvel += hdir * (new_toward - vel_toward_target)

	return hvel


# ======================================================================
#  Pipeline step 5b: apply_snap_and_gravity — runs every frame
# ======================================================================

func apply_snap_and_gravity(delta: float) -> void:
	Profiler.begin("movement_snap_gravity")
	## Snap to ground when briefly airborne, otherwise apply gravity.
	## Called AFTER all movement branches (slide/crouch/normal) so it
	## runs unconditionally every frame.
	if _is_grounded:
		Profiler.end("movement_snap_gravity")
		return
	# Save airborne hvel NOW, before the snap might ground us.
	# This is fresh — the movement code just set the horizontal velocity.
	_airborne_hvel = Vector3(player.velocity.x, 0.0, player.velocity.z)
	# Snap: only when not actively jumping (rising from a jump should be free)
	if not _post_jump_rising:
		# Kinematic displacement: where will we be after one frame of gravity?
		#   x = v*t - 0.5*g*t²
		# Negative = downward. If the ground is within this distance, snap to it.
		# Floor: even when going up, always search at least one gravity frame
		# downward (0.5*g*t² from rest) so terrain face changes are caught.
		# First sweep: kinematic — where gravity would put us in one frame.
		# First sweep: kinematic — where gravity would put us in one frame.
		var kinematic := player.velocity.y * delta - 0.5 * player.gravity * delta * delta
		var recently_jolt_grounded := (Time.get_ticks_msec() / 1000.0 - _last_jolt_grounded_time) < 0.25
		var snap_dist := minf(kinematic, -0.5 * player.gravity * delta * delta)
		if recently_jolt_grounded:
			snap_dist -= 0.05
		if GameManager.debug_grounding_extend_snap:
			snap_dist = minf(snap_dist, -0.5)
		if _do_snap(snap_dist):
			Profiler.end("movement_snap_gravity")
			return
		# Debug: measure actual distance to ground when both sweeps miss.
		if GameManager.debug_grounding_log and _was_grounded:
			var space := player.get_world_3d().direct_space_state
			var col_shape: CollisionShape3D = player.get_node("CollisionShape3D")
			var params := PhysicsShapeQueryParameters3D.new()
			params.shape = col_shape.shape
			params.transform = col_shape.global_transform
			params.motion = Vector3(0, -1.0, 0)
			params.collision_mask = player.collision_mask
			params.exclude = [player.get_rid()]
			var result := space.cast_motion(params)
			if result[1] < 1.0:
				print("[SNAP] ground_dist=%.4f snap_tried=%.4f vel.y=%.2f" % [
					-1.0 * result[1], snap_dist, player.velocity.y])
			else:
				print("[SNAP] no ground within 1m snap_tried=%.4f vel.y=%.2f" % [
					snap_dist, player.velocity.y])
	# Gravity: always applies when airborne (whether jumping or falling)
	player.velocity.y -= player.gravity * delta
	Profiler.end("movement_snap_gravity")


# ======================================================================
#  Pipeline step 6: post_physics_step — debug logging
# ======================================================================

func post_physics_step(_delta: float, _grapple_active: bool) -> void:
	# _airborne_hvel is saved in apply_snap_and_gravity (before the snap),
	# so it's always fresh when either the snap or begin_movement restores it.

	# Grounding flicker log
	if GameManager.debug_grounding_log and _is_grounded != _was_grounded:
		var tag := "GND→AIR" if _was_grounded else "AIR→GND"
		print("[GFLICKER] %s vel=(%.2f,%.2f,%.2f) pos.y=%.3f fn=(%.2f,%.2f,%.2f) cc=%d snap_y=%.3f" % [
			tag, player.velocity.x, player.velocity.y, player.velocity.z,
			player.global_position.y, _floor_normal.x, _floor_normal.y, _floor_normal.z,
			_contact_count, _snap_vel_y])

	# Save grounded state for next frame's landing/launch detection.
	# Must be here (end of frame), NOT in pre_physics_step, because
	# on_integrate_forces already set _is_grounded before pre_physics_step runs.
	_was_grounded = _is_grounded
	if _is_grounded:
		_last_grounded_time = Time.get_ticks_msec() / 1000.0

	# Update overlap debug indicator (for HUD blue/red dot)
	_update_overlap_debug()

	# ── DBG: finalize frame and push to ring buffer ──
	_dbg_cur["post_vel"] = player.velocity
	_dbg_cur["post_pos"] = player.global_position
	_dbg_cur["post_is_grounded"] = _is_grounded
	_dbg_cur["post_was_grounded"] = _was_grounded

	# Terrain gap: how far above/below the noise surface is the capsule bottom?
	var _dbg_pos := player.global_position
	var _dbg_terrain_y := _get_terrain_height(_dbg_pos.x, _dbg_pos.z)
	_dbg_cur["post_terrain_y"] = _dbg_terrain_y
	_dbg_cur["post_terrain_gap"] = _dbg_pos.y - _dbg_terrain_y  # positive = above

	# Record if process_normal_movement was NOT called (slide/crouch/grapple)
	if not _dbg_cur.has("move_type"):
		_dbg_cur["move_type"] = "skipped"

	_dbg_ring.append(_dbg_cur)
	if _dbg_ring.size() > DBG_RING_SIZE:
		_dbg_ring.pop_front()

	# Trigger: went airborne this frame, was NOT a jump
	if _was_grounded and not _is_grounded and not _post_jump_rising:
		_dbg_after_count = DBG_AFTER_FRAMES
		_dbg_dump_transition()
	elif _dbg_after_count > 0:
		_dbg_after_count -= 1
		_dbg_print_frame(_dbg_cur, "AFTER ")
		if _dbg_after_count == 0:
			print("═══════════════════ END GROUND→AIR DUMP ═══════════════════\n")

	# ── F10 verbose movement debug (per-frame compact line + detail on transitions) ──
	if player.capture_movement:
		var gnd_tag := "GND" if _is_grounded else "AIR"
		var trans := ""
		if _was_grounded and not _is_grounded:
			trans = " >>>AIR"
		elif not _was_grounded and _is_grounded:
			trans = " >>>GND"
		var fn := _floor_normal
		var vel := player.velocity
		var hspd := Vector2(vel.x, vel.z).length()
		var gap: float = _dbg_cur.get("post_terrain_gap", 0.0)
		var line := "[F%d] %s%s cc=%d fn=(%.3f,%.3f,%.3f) vel=(%.2f,%.2f,%.2f) h=%.2f gap=%.1fmm" % [
			_dbg_frame_num, gnd_tag, trans, _contact_count,
			fn.x, fn.y, fn.z, vel.x, vel.y, vel.z, hspd, gap * 1000.0]
		var wf: float = _dbg_cur.get("move_wall_factor", 1.0)
		if wf < 0.999:
			line += " wf=%.2f" % wf
		var wclip: Vector3 = _dbg_cur.get("move_wall_clip_delta", Vector3.ZERO)
		if wclip.length_squared() > 0.0001:
			line += " WCLIP=(%.3f,%.3f)" % [wclip.x, wclip.z]
		if _dbg_cur.get("move_slope_projected", false):
			line += " sy=%.3f" % _dbg_cur.get("move_surface_y", 0.0)
		# Position drift: how much Jolt moved position beyond our velocity * dt
		var drift: Vector3 = _dbg_cur.get("int_pos_drift", Vector3.ZERO)
		var drift_h := Vector3(drift.x, 0.0, drift.z)
		if drift_h.length_squared() > 0.0000001:  # > 0.001mm
			line += " DRIFT_H=%.4fmm" % (drift_h.length() * 1000.0)
			# Project drift onto each wall normal to identify wall-perpendicular component
			for c in _contacts:
				if not c["is_walkable"]:
					var wn: Vector3 = c["normal"]
					var wd := drift.dot(wn)
					line += " wd=%.4fmm" % (wd * 1000.0)
					break  # first wall normal is enough
		var vd: Vector3 = _dbg_cur.get("int_vel_delta", Vector3.ZERO)
		var vd_h := Vector3(vd.x, 0.0, vd.z)
		if vd_h.length_squared() > 0.0001:
			line += " VEL_D=(%.4f,%.4f)" % [vd.x, vd.z]
		var pcorr: Vector3 = _dbg_cur.get("int_pos_correction", Vector3.ZERO)
		if pcorr.length_squared() > 0.0000001:
			line += " PCORR=%.4fmm" % (pcorr.length() * 1000.0)
		print(line)
		# Wall perpendicular trace: decompose velocity at each pipeline stage
		if _dbg_cur.has("wall_nh"):
			var wnh: Vector3 = _dbg_cur["wall_nh"]
			var stable: bool = _dbg_cur.get("wall_nh_stable", false)
			var wp_prev: float = _dbg_cur.get("wall_perp_set_prev", 0.0)
			var wp_jd: float = _dbg_cur.get("wall_perp_jolt_d", 0.0)
			var wp0: float = _dbg_cur.get("wall_perp_s0", 0.0)
			var wp1: float = _dbg_cur.get("wall_perp_s1", 0.0)
			var wp2: float = _dbg_cur.get("wall_perp_s2", 0.0)
			var wp3: float = _dbg_cur.get("wall_perp_s3", 0.0)
			print("  [WALL] nh=(%.3f,%.3f) stable=%s | prev_set=%.4f jolt_d=%.4f | start=%.4f accel=%.4f clip=%.4f final=%.4f" % [
				wnh.x, wnh.z, str(stable), wp_prev, wp_jd, wp0, wp1, wp2, wp3])
		if trans != "":
			for i in _contacts.size():
				var c := _contacts[i]
				var n: Vector3 = c["normal"]
				var imp: Vector3 = _dbg_cur.get("int_contacts", [{}])[i].get("impulse", Vector3.ZERO) if i < _dbg_cur.get("int_contacts", []).size() else Vector3.ZERO
				print("  c%d: n=(%.4f,%.4f,%.4f) ang=%.1f° walk=%s imp=(%.2f,%.2f,%.2f)" % [
					i, n.x, n.y, n.z,
					rad_to_deg(n.angle_to(Vector3.UP)),
					str(c["is_walkable"]),
					imp.x, imp.y, imp.z])

	# Save for next frame's delta comparison
	_dbg_prev_set_vel = player.velocity
	_dbg_prev_pos = player.global_position
	_dbg_prev_set_vel_y = player.velocity.y
	_dbg_frame_num += 1


# ======================================================================
#  Terrain SDF queries (noise-based, no physics)
# ======================================================================

func _get_terrain_height(wx: float, wz: float) -> float:
	## Terrain surface height from noise. Instant, no raycasts.
	## Returns 0.0 if SeedWorld is unavailable.
	if _cached_seed_world == null:
		var cs: Node = player.get_tree().current_scene
		if cs:
			_cached_seed_world = cs.get_node_or_null("SeedWorld")
			if _cached_seed_world == null:
				_cached_seed_world = cs.get_node_or_null("BlockoutMap/SeedWorld")
	if _cached_seed_world and _cached_seed_world.has_method("get_height_from_noise"):
		return _cached_seed_world.get_height_from_noise(wx, wz)
	return 0.0


func _get_sdf_surface_normal() -> Vector3:
	## Compute the terrain surface normal at the player's XZ position
	## using central-difference on noise height queries.
	## Smoother than mesh triangle normals and has no one-frame lag
	## from triangle boundary crossings.
	var px: float = player.global_position.x
	var pz: float = player.global_position.z
	var h: float = _get_terrain_height(px, pz)
	var hx: float = _get_terrain_height(px + SDF_NORMAL_EPS, pz)
	var hz: float = _get_terrain_height(px, pz + SDF_NORMAL_EPS)
	var dx: float = (hx - h) / SDF_NORMAL_EPS
	var dz: float = (hz - h) / SDF_NORMAL_EPS
	return Vector3(-dx, 1.0, -dz).normalized()


# ======================================================================
#  Floor detection
# ======================================================================

func is_on_floor() -> bool:
	return _is_grounded


func get_floor_normal() -> Vector3:
	return _floor_normal


func is_on_walkable_floor() -> bool:
	return _is_grounded and _floor_normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE


func can_jump() -> bool:
	return _has_jumpable_contact and not _post_jump_rising


# ======================================================================
#  Jump
# ======================================================================

func slope_compensated_jump_y() -> float:
	return JUMP_VELOCITY


func do_jump() -> void:
	if player.velocity.y > JUMP_VELOCITY:
		return
	player.velocity.y = JUMP_VELOCITY

	if not GameManager.debug_no_jump_unground:
		_is_grounded = false
	_post_jump_rising = true
	_post_jump_timer = POST_JUMP_DURATION
	player.slide_crouch.clear_slide_on_land()


func do_air_jump() -> bool:
	var extra_jumps: int = player.inventory.get_shoe_extra_jumps() if player.inventory else 0
	if _air_jumps_used < extra_jumps:
		player.velocity.y = JUMP_VELOCITY * 1.5
		_air_jumps_used += 1
		_post_jump_rising = true
		_post_jump_timer = POST_JUMP_DURATION
		return true
	return false


func force_airborne() -> void:
	if not GameManager.debug_no_force_airborne:
		_is_grounded = false
		_post_jump_rising = true
		_post_jump_timer = POST_JUMP_DURATION


# ======================================================================
#  Debug: ground→airborne transition dump
# ======================================================================

func _dbg_dump_transition() -> void:
	print("\n═══════════════════ GROUND→AIR TRANSITION (frame %d) ═══════════════════" % _dbg_frame_num)
	for i in _dbg_ring.size():
		var f: Dictionary = _dbg_ring[i]
		var is_trigger := (i == _dbg_ring.size() - 1)
		var tag := ">>> " if is_trigger else "    "
		_dbg_print_frame(f, tag)
	print("─────────────────── (capturing %d after-frames) ───────────────────" % DBG_AFTER_FRAMES)


func _dbg_print_frame(f: Dictionary, tag: String) -> void:
	var fr: int = f.get("frame", -1)

	# ── integrate_forces ──
	var int_pos: Vector3 = f.get("int_pos", Vector3.ZERO)
	var int_vel: Vector3 = f.get("int_vel", Vector3.ZERO)
	var cc: int = f.get("int_contact_count", 0)
	var multi: bool = f.get("int_multi_body", false)
	var ubc: int = f.get("int_unique_body_count", 0)
	var multi_tag := "  *** MULTI_BODY(%d) ***" % ubc if multi else ""
	var cx: float = abs(fmod(int_pos.x, 16.0))
	cx = min(cx, 16.0 - cx)
	var cy: float = abs(fmod(int_pos.y, 16.0))
	cy = min(cy, 16.0 - cy)
	var cz: float = abs(fmod(int_pos.z, 16.0))
	cz = min(cz, 16.0 - cz)
	var seam_tag := "  seam_dist=(%.1f,%.1f,%.1f)" % [cx, cy, cz]
	print("%s[F%d] ── integrate_forces ── contacts=%d  pos=(%.3f,%.3f,%.3f)  vel=(%.3f,%.3f,%.3f)%s%s" % [
		tag, fr, cc, int_pos.x, int_pos.y, int_pos.z, int_vel.x, int_vel.y, int_vel.z, multi_tag, seam_tag])
	var contacts: Array = f.get("int_contacts", [])
	for ci in contacts.size():
		var c: Dictionary = contacts[ci]
		var n: Vector3 = c.get("normal", Vector3.ZERO)
		var lp: Vector3 = c.get("local_pos", Vector3.ZERO)
		var cp: Vector3 = c.get("collider_pos", Vector3.ZERO)
		var imp: Vector3 = c.get("impulse", Vector3.ZERO)
		print("%s       c%d: n=(%.4f,%.4f,%.4f) ang=%.1f° walk=%s  lpos=(%.3f,%.3f,%.3f)  cpos=(%.3f,%.3f,%.3f)  imp=(%.2f,%.2f,%.2f)  body=%s  node=%s" % [
			tag, ci, n.x, n.y, n.z, c.get("angle", 0.0), str(c.get("walkable", false)),
			lp.x, lp.y, lp.z, cp.x, cp.y, cp.z, imp.x, imp.y, imp.z, c.get("body_class", "?"), c.get("body_name", "?")])

	# ── velocity/position deltas ──
	var vel_we_set: Vector3 = f.get("int_vel_we_set", Vector3.ZERO)
	var vel_jolt: Vector3 = f.get("int_vel_jolt_reports", Vector3.ZERO)
	var vel_delta: Vector3 = f.get("int_vel_delta", Vector3.ZERO)
	var pos_delta: Vector3 = f.get("int_pos_delta", Vector3.ZERO)
	var prev_cc: int = f.get("int_prev_contact_count", 0)
	print("%s       Δvel: set=(%.3f,%.3f,%.3f) jolt=(%.3f,%.3f,%.3f) diff=(%.4f,%.4f,%.4f)  Δpos=(%.4f,%.4f,%.4f)  prev_cc=%d" % [
		tag, vel_we_set.x, vel_we_set.y, vel_we_set.z,
		vel_jolt.x, vel_jolt.y, vel_jolt.z,
		vel_delta.x, vel_delta.y, vel_delta.z,
		pos_delta.x, pos_delta.y, pos_delta.z, prev_cc])

	# ── pre_physics_step ──
	var reason: String = f.get("pre_grounding_reason", "?")
	var gnd: bool = f.get("pre_is_grounded", false)
	var was: bool = f.get("pre_was_grounded", false)
	var fn: Vector3 = f.get("pre_floor_normal", Vector3.ZERO)
	var bn: Vector3 = f.get("pre_best_normal", Vector3.ZERO)
	var pv: Vector3 = f.get("pre_vel", Vector3.ZERO)
	print("%s       pre: was=%s → is=%s  reason=%s  floor_n=(%.4f,%.4f,%.4f)  best_n=(%.4f,%.4f,%.4f)" % [
		tag, str(was), str(gnd), reason, fn.x, fn.y, fn.z, bn.x, bn.y, bn.z])
	print("%s            has_floor=%s  post_jump=%s  vel=(%.3f,%.3f,%.3f)" % [
		tag, str(f.get("pre_has_floor_contact", false)),
		str(f.get("pre_post_jump_rising", false)), pv.x, pv.y, pv.z])

	# ── begin_movement ──
	var bv_b: Vector3 = f.get("begin_vel_before", Vector3.ZERO)
	var bv_a: Vector3 = f.get("begin_vel_after", Vector3.ZERO)
	var landed: bool = f.get("begin_landing_fired", false)
	if landed:
		var ah: Vector3 = f.get("begin_airborne_hvel", Vector3.ZERO)
		print("%s       begin: LANDING  airborne_hvel=(%.3f,%.3f,%.3f)  vel: (%.3f,%.3f,%.3f)→(%.3f,%.3f,%.3f)" % [
			tag, ah.x, ah.y, ah.z, bv_b.x, bv_b.y, bv_b.z, bv_a.x, bv_a.y, bv_a.z])
	else:
		print("%s       begin: no landing  vel=(%.3f,%.3f,%.3f)" % [tag, bv_a.x, bv_a.y, bv_a.z])

	# ── apply_gravity ──
	var gv_b: Vector3 = f.get("grav_vel_before", Vector3.ZERO)
	var gv_a: Vector3 = f.get("grav_vel_after", Vector3.ZERO)
	print("%s       gravity: vel.y %.3f → %.3f  (−%.3f)" % [tag, gv_b.y, gv_a.y, f.get("grav_amount", 0.0)])

	# ── movement ──
	var mt: String = f.get("move_type", "skipped")
	if mt == "normal":
		var hb: Vector3 = f.get("move_hvel_before", Vector3.ZERO)
		var ha: Vector3 = f.get("move_hvel_after", Vector3.ZERO)
		var sp: bool = f.get("move_slope_projected", false)
		var inp: Vector2 = f.get("move_input", Vector2.ZERO)
		print("%s       move: type=%s  input=(%.2f,%.2f)  hvel: (%.3f,0,%.3f)→(%.3f,0,%.3f)  hspd: %.3f→%.3f" % [
			tag, mt, inp.x, inp.y, hb.x, hb.z, ha.x, ha.z, f.get("move_hspeed_before", 0.0), ha.length()])
		if sp:
			var sn: Vector3 = f.get("move_slope_normal", Vector3.ZERO)
			var sy: float = f.get("move_surface_y", 0.0)
			print("%s             slope: n=(%.4f,%.4f,%.4f) angle=%.1f°  surface_y=%.4f" % [
				tag, sn.x, sn.y, sn.z, rad_to_deg(sn.angle_to(Vector3.UP)), sy])
	else:
		print("%s       move: type=%s" % [tag, mt])

	# ── final ──
	var fv: Vector3 = f.get("move_vel_final", f.get("post_vel", Vector3.ZERO))
	var fp: Vector3 = f.get("move_pos_final", f.get("post_pos", Vector3.ZERO))
	var t_gap: float = f.get("post_terrain_gap", 0.0)
	var t_y: float = f.get("post_terrain_y", 0.0)
	print("%s       FINAL: vel=(%.3f,%.3f,%.3f) |h|=%.3f  pos=(%.3f,%.3f,%.3f)  grounded=%s  gap=%.1fmm (terrain_y=%.3f)" % [
		tag, fv.x, fv.y, fv.z, Vector2(fv.x, fv.z).length(),
		fp.x, fp.y, fp.z, str(f.get("post_is_grounded", false)),
		t_gap * 1000.0, t_y])
	print("")


# ======================================================================
#  Reset
# ======================================================================

func reset_movement() -> void:
	_air_jumps_used = 0
	_obstacle_normals = []
	_ground_velocity = Vector3.ZERO
	_post_jump_rising = false
	_is_grounded = false
	_floor_normal = Vector3.UP
	_contacts.clear()
	_contact_count = 0
	_has_floor_contact = false
	_has_jumpable_contact = false
	_momentum_launch_flash = 0.0
	_airborne_hvel = Vector3.ZERO
