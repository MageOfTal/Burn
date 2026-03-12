extends PlayerSubsystem
class_name PlayerMovement

## Player movement subsystem.
##
## Uses RigidBody3D with custom_integrator=true. Jolt handles position
## integration and collision response. This script sets velocity each frame;
## Jolt integrates it next frame.
##
## Ground detection is contact-based. A post-move downward capsule sweep
## ("ground snap") prevents liftoff on convex terrain by clamping vel.y
## so the player tracks the surface. The snap uses real velocity (not
## teleportation), so dynamic bodies underneath still receive contact forces.

# ======================================================================
#  Constants (referenced by slide_crouch_system.gd)
# ======================================================================

const SPEED := 9.0
const JUMP_VELOCITY := 10.5
const WALK_ACCEL: float = 30.33
const AIR_ACCELERATION := 15.0

const FLOOR_MAX_ANGLE: float = 0.8727  ## 50° — walkable
const JUMP_MAX_ANGLE: float = 1.4835   ## 85° — jumpable

## Ground snap: prevents liftoff on convex terrain curvature changes.
## Probes one frame ahead to find the actual ground surface position,
## then clamps vel.y so the capsule tracks the surface instead of
## overshooting above it. Uses real velocity → dynamic bodies get forces.
const GROUND_SNAP_PROBE_UP: float = 0.5    ## start probe this far above
const GROUND_SNAP_PROBE_DOWN: float = 0.3  ## search this far below current pos
const GROUND_SNAP_MIN_HSPEED: float = 0.5  ## don't snap when nearly still

## Below this horizontal speed, direction reversal causes an instant stop.
const DIME_STOP_SPEED: float = 6.0

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

var _has_floor_contact: bool = false
var _has_jumpable_contact: bool = false
var _best_contact_normal: Vector3 = Vector3.ZERO

var _obstacle_normals: Array[Vector2] = []  ## Debug only (read by player.gd)

var _ground_velocity: Vector3 = Vector3.ZERO
var _air_jumps_used: int = 0
var _post_jump_rising: bool = false

## Horizontal velocity saved at end of each airborne frame (before Jolt integrates).
## Restored on landing to undo Jolt's slope deflection of falling velocity.
var _airborne_hvel: Vector3 = Vector3.ZERO

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

# ======================================================================
#  Pipeline step 1: on_integrate_forces — sample contacts from Jolt
# ======================================================================

func on_integrate_forces(state: PhysicsDirectBodyState3D) -> void:
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


# ======================================================================
#  Pipeline step 2: pre_physics_step — update ground state from contacts
# ======================================================================

func pre_physics_step(delta: float) -> void:
	_was_grounded = _is_grounded

	# Determine ground state purely from contacts.
	_has_floor_contact = false
	_has_jumpable_contact = false
	_best_contact_normal = Vector3.ZERO

	var best_dot: float = -1.0

	for c in _contacts:
		var normal: Vector3 = c["normal"]
		var dot := normal.dot(Vector3.UP)

		if c["is_jumpable"]:
			_has_jumpable_contact = true

		if c["is_walkable"]:
			_has_floor_contact = true
			if dot > best_dot:
				best_dot = dot
				_best_contact_normal = normal

	# While rising from a jump, the capsule may still overlap the floor for a
	# frame or two. Stay airborne until we actually stop rising.
	if _post_jump_rising:
		if player.velocity.y <= 0.0:
			_post_jump_rising = false

	# Ground the player if there's a walkable contact and we're not
	# still rising from a jump.
	var _dbg_grounding_reason := "none"
	if _has_floor_contact and not _post_jump_rising:
		_is_grounded = true
		_floor_normal = _best_contact_normal
		_dbg_grounding_reason = "contact"
	else:
		_is_grounded = false
		if _post_jump_rising:
			_dbg_grounding_reason = "post_jump_rising"
		else:
			_dbg_grounding_reason = "no_walkable_contact"

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


# ======================================================================
#  Pipeline step 3: begin_movement — reset air jumps on landing
# ======================================================================

func begin_movement(delta: float) -> void:
	_dbg_cur["begin_vel_before"] = player.velocity
	var _dbg_landing := false
	if _is_grounded and not _was_grounded:
		# Just landed — restore horizontal velocity from the last airborne frame.
		# Jolt's solver deflects falling velocity onto the slope surface, converting
		# downward momentum into downhill horizontal motion. Undo that by restoring
		# the horizontal velocity we set before Jolt integrated the landing collision.
		_dbg_landing = true
		player.velocity.x = _airborne_hvel.x
		player.velocity.z = _airborne_hvel.z
		_air_jumps_used = 0
	_dbg_cur["begin_landing_fired"] = _dbg_landing
	_dbg_cur["begin_airborne_hvel"] = _airborne_hvel
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
	var input_dir: Vector2 = player.player_input.input_direction
	var direction := (player.transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized() \
		if input_dir.length() > 0.1 else Vector3.ZERO

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
	var max_speed: float = SPEED * speed_mult
	# Debug override
	if GameManager.debug_speed_50:
		max_speed = 50.0

	var accel: float = WALK_ACCEL if _is_grounded else AIR_ACCELERATION

	# Current horizontal velocity
	var hvel := Vector3(player.velocity.x, 0.0, player.velocity.z)
	var hspeed := hvel.length()

	_dbg_cur["move_type"] = "normal"
	_dbg_cur["move_input"] = input_dir
	_dbg_cur["move_hvel_before"] = hvel
	_dbg_cur["move_hspeed_before"] = hspeed
	_dbg_cur["move_vel_before"] = player.velocity

	if _is_grounded:
		hvel = _process_ground_movement(hvel, hspeed, direction, max_speed, accel, delta)
	else:
		hvel = _process_air_movement(hvel, hspeed, direction, max_speed, accel, delta)

	_dbg_cur["move_hvel_after"] = hvel

	player.velocity.x = hvel.x
	player.velocity.z = hvel.z

	_dbg_cur["move_slope_projected"] = false
	_dbg_cur["move_surface_y"] = 0.0
	_dbg_cur["move_slope_normal"] = Vector3.ZERO

	if _is_grounded and _has_floor_contact:
		# Slope projection: set vel.y so velocity is tangent to the surface.
		# This keeps horizontal speed constant on slopes and prevents sliding
		# when standing still.
		var n := _floor_normal
		if n.y > 0.01:
			var surface_y := -(n.x * hvel.x + n.z * hvel.z) / n.y
			var vel := player.velocity
			vel.y = surface_y
			player.velocity = vel
			_dbg_cur["move_slope_projected"] = true
			_dbg_cur["move_surface_y"] = surface_y
			_dbg_cur["move_slope_verify"] = player.velocity.y
			_dbg_cur["move_slope_normal"] = n

		# Ground snap: cast the capsule one frame ahead to find the actual
		# ground surface. If slope projection would overshoot (convex
		# curvature, uphill or downhill), clamp vel.y to track the surface.
		# Uses real velocity so dynamic bodies underneath still get pushed.
		var hspd := Vector2(hvel.x, hvel.z).length()
		if hspd > GROUND_SNAP_MIN_HSPEED:
			_apply_ground_snap(delta)

	_dbg_cur["move_vel_final"] = player.velocity
	_dbg_cur["move_pos_final"] = player.global_position


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

	# Check if we're in skid territory
	if hspeed >= SKID_THRESHOLD:
		# SKID: can only steer and decelerate
		return _process_skid(hvel, hspeed, hdir, delta)

	# Dime stop: below DIME_STOP_SPEED, strip any velocity component opposing
	# the new input direction. Moving NE and pressing W kills the east component
	# but keeps north. Moving E and pressing W zeroes everything.
	if hspeed > 0.01 and hspeed <= DIME_STOP_SPEED:
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
#  Ground snap — prevent liftoff on convex terrain
# ======================================================================

func _apply_ground_snap(delta: float) -> void:
	## Project the capsule one frame ahead (horizontal only), raise it,
	## then cast downward to find the actual ground surface position.
	## If the ground is lower than what slope projection predicts (convex
	## curvature), clamp vel.y to track the real surface.
	##
	## Because we adjust velocity (not position), Jolt still integrates
	## normally — dynamic bodies underneath receive real contact forces.
	var space_state := player.get_world_3d().direct_space_state
	if space_state == null:
		return

	var col_node: CollisionShape3D = player.get_node_or_null("CollisionShape3D")
	if col_node == null or col_node.shape == null:
		return

	var hvel := Vector3(player.velocity.x, 0, player.velocity.z)
	var future_h_offset := hvel * delta

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = col_node.shape
	# Start at future horizontal position, raised by PROBE_UP
	var probe_xform := player.global_transform * col_node.transform
	probe_xform.origin += future_h_offset + Vector3(0, GROUND_SNAP_PROBE_UP, 0)
	params.transform = probe_xform
	var total_cast := GROUND_SNAP_PROBE_UP + GROUND_SNAP_PROBE_DOWN
	params.motion = Vector3(0, -total_cast, 0)
	params.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.TOAD_RAIN | CollisionLayers.WALL_SMOOTH
	params.exclude = [player.get_rid()]

	var results := space_state.cast_motion(params)
	if results.size() < 2 or results[1] >= 1.0:
		return  # no ground within probe range
	if results[0] <= 0.0:
		return  # probe starts inside geometry (ground is above us)

	# Ground surface height relative to current player Y.
	# Capsule bottom at probe start = current_y + PROBE_UP.
	# At safe_fraction it has descended by safe_fraction * total_cast.
	# Ground_rel_y = PROBE_UP - safe_fraction * total_cast
	#   positive → ground is above us (uphill)
	#   negative → ground is below us (would separate)
	var ground_rel_y: float = GROUND_SNAP_PROBE_UP - results[0] * total_cast
	var desired_vel_y: float = ground_rel_y / delta

	# Only snap downward: if the actual ground ahead is lower than
	# slope projection predicts, reduce vel.y to track the real surface.
	if desired_vel_y < player.velocity.y:
		player.velocity.y = desired_vel_y
		_dbg_cur["snap_applied"] = true
		_dbg_cur["snap_ground_rel_y"] = ground_rel_y
		_dbg_cur["snap_vel_y"] = desired_vel_y


# ======================================================================
#  Pipeline step 6: post_physics_step — debug logging
# ======================================================================

func post_physics_step(_delta: float, _grapple_active: bool) -> void:
	# Save horizontal velocity while airborne. This captures our intended velocity
	# AFTER movement code runs but BEFORE Jolt integrates next frame. On landing,
	# begin_movement() restores this to undo Jolt's slope deflection.
	if not _is_grounded:
		_airborne_hvel = Vector3(player.velocity.x, 0.0, player.velocity.z)

	# ── DBG: finalize frame and push to ring buffer ──
	_dbg_cur["post_vel"] = player.velocity
	_dbg_cur["post_pos"] = player.global_position
	_dbg_cur["post_is_grounded"] = _is_grounded
	_dbg_cur["post_was_grounded"] = _was_grounded

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

	# Save for next frame's delta comparison
	_dbg_prev_set_vel = player.velocity
	_dbg_prev_pos = player.global_position
	_dbg_frame_num += 1


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
	player.velocity.y = JUMP_VELOCITY
	_is_grounded = false
	_post_jump_rising = true
	player.slide_crouch.clear_slide_on_land()


func do_air_jump() -> bool:
	var extra_jumps: int = player.inventory.get_shoe_extra_jumps() if player.inventory else 0
	if _air_jumps_used < extra_jumps:
		player.velocity.y = JUMP_VELOCITY * 1.5
		_air_jumps_used += 1
		_post_jump_rising = true
		return true
	return false


func force_airborne() -> void:
	_is_grounded = false
	_post_jump_rising = true


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
			var verify_y = f.get("move_slope_verify", "N/A")
			print("%s             slope: n=(%.4f,%.4f,%.4f) angle=%.1f°  surface_y=%.4f  verify_y=%s" % [
				tag, sn.x, sn.y, sn.z, rad_to_deg(sn.angle_to(Vector3.UP)),
				f.get("move_surface_y", 0.0), str(verify_y)])
		if f.get("snap_applied", false):
			print("%s             SNAP: ground_rel_y=%.4f  vel_y=%.4f" % [
				tag, f.get("snap_ground_rel_y", 0.0), f.get("snap_vel_y", 0.0)])
	else:
		print("%s       move: type=%s" % [tag, mt])

	# ── final ──
	var fv: Vector3 = f.get("move_vel_final", f.get("post_vel", Vector3.ZERO))
	var fp: Vector3 = f.get("move_pos_final", f.get("post_pos", Vector3.ZERO))
	print("%s       FINAL: vel=(%.3f,%.3f,%.3f) |h|=%.3f  pos=(%.3f,%.3f,%.3f)  grounded=%s" % [
		tag, fv.x, fv.y, fv.z, Vector2(fv.x, fv.z).length(),
		fp.x, fp.y, fp.z, str(f.get("post_is_grounded", false))])
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
