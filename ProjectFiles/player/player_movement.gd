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
const JUMP_VELOCITY := 12.6  ## 20% bump from 10.5
const WALK_ACCEL: float = 45.0
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
var _jolt_solved_hvel: Vector3 = Vector3.ZERO    # post-solver horizontal velocity (before restore)
var _dynamic_wall_fraction: float = 0.0          # 0 = dynamic body didn't resist, 1 = fully resisted (wall-like)
var _dynamic_floor_fraction: float = 0.0         # 0 = walkable dynamic body got shoved, 1 = fully resisted (static-like)
var _dbg_prev_contact_count: int = 0
var _dbg_pos_drift: Vector3 = Vector3.ZERO       # position drift from Jolt (computed early in on_integrate_forces)
var _dbg_vel_delta: Vector3 = Vector3.ZERO        # velocity change by Jolt
var _dbg_prev_wall_nh: Vector3 = Vector3.ZERO     # previous frame's primary wall normal (horizontal)
var _dbg_is_overlapping: bool = false             # is the capsule overlapping something
var _dbg_is_skidding: bool = false               # is the player in skid mode this frame
var _dbg_prev_set_vel_y: float = 0.0                  # vel.y we set last frame (for ground snap)

# F8 flicker tracker — compact transition log
var _flicker_prev_grounded: bool = false
var _flicker_prev_normal: Vector3 = Vector3.UP
var _flicker_air_streak: int = 0     # How many frames in current state
var _flicker_gnd_streak: int = 0



# ======================================================================
#  Pipeline step 1: on_integrate_forces — sample contacts from Jolt
# ======================================================================

func on_integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	Profiler.begin("movement_integrate")

	# ── Drift diagnostics: measure how Jolt moved position vs our intent ──
	_dbg_pos_drift = state.transform.origin - _dbg_prev_pos - _dbg_prev_set_vel * state.step
	_dbg_vel_delta = state.linear_velocity - _dbg_prev_set_vel

	# F9 floor diagnostic — comprehensive per-frame dump while on a dynamic floor
	if GameManager.debug_floor_diag:
		var fd_post := state.linear_velocity
		var fd_prev := _dbg_prev_set_vel
		print("[FD] ─── on_integrate_forces (frame %d) ───" % _dbg_frame_num)
		print("[FD]   prev_set_vel = (%.4f, %.4f, %.4f)" % [fd_prev.x, fd_prev.y, fd_prev.z])
		print("[FD]   post_solver  = (%.4f, %.4f, %.4f)   (state.linear_velocity)" % [fd_post.x, fd_post.y, fd_post.z])
		print("[FD]   delta        = (%.4f, %.4f, %.4f)   (post-solver - prev_set)" % [
			(fd_post - fd_prev).x, (fd_post - fd_prev).y, (fd_post - fd_prev).z])
		print("[FD]   pos_drift    = (%.4f, %.4f, %.4f)   step=%.4f" % [_dbg_pos_drift.x, _dbg_pos_drift.y, _dbg_pos_drift.z, state.step])
		print("[FD]   contacts: %d" % state.get_contact_count())
		for fdi in state.get_contact_count():
			var fd_n := state.get_contact_local_normal(fdi)
			var fd_imp := state.get_contact_impulse(fdi)
			var fd_col := state.get_contact_collider_object(fdi)
			var fd_walk := fd_n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE
			var fd_kind := "?"
			var fd_body_vel := Vector3.ZERO
			var fd_body_speed := 0.0
			if fd_col is RigidBody3D:
				fd_kind = "DYN(%.0fkg)" % (fd_col as RigidBody3D).mass
				fd_body_vel = (fd_col as RigidBody3D).linear_velocity
				fd_body_speed = fd_body_vel.length()
			elif fd_col is StaticBody3D:
				fd_kind = "STATIC"
			elif fd_col is VoxelLodTerrain:
				fd_kind = "TERRAIN"
			elif fd_col != null:
				fd_kind = fd_col.get_class()
			var fd_t_vel := fd_body_vel - fd_n * fd_body_vel.dot(fd_n)
			print("[FD]     c%d: %s walk=%s n=(%.3f,%.3f,%.3f) ang=%.1f° imp=(%.3f,%.3f,%.3f) body_v=(%.4f,%.4f,%.4f) |v|=%.4f tan_v=%.4f" % [
				fdi, fd_kind, str(fd_walk),
				fd_n.x, fd_n.y, fd_n.z, rad_to_deg(fd_n.angle_to(Vector3.UP)),
				fd_imp.x, fd_imp.y, fd_imp.z,
				fd_body_vel.x, fd_body_vel.y, fd_body_vel.z, fd_body_speed,
				fd_t_vel.length()])

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
	# Save Jolt's post-solver horizontal velocity before the restore overwrites it.
	_jolt_solved_hvel = Vector3(state.linear_velocity.x, 0.0, state.linear_velocity.z)

	# Compute how "wall-like" dynamic body contacts are this frame.
	# For each dynamic wall contact, measure what fraction of the into-wall
	# velocity Jolt absorbed. A fully immovable body absorbs 100% (fraction=1).
	# A light pushable body absorbs little (fraction≈0).
	# Cache previous fraction before resetting — decay/hold modes use it below.
	var prev_dyn_wall_fraction: float = _dynamic_wall_fraction
	var loop_max_wall: float = 0.0
	var had_dyn_wall_contact: bool = false
	_dynamic_floor_fraction = 0.0
	var prev_h := Vector3(_dbg_prev_set_vel.x, 0.0, _dbg_prev_set_vel.z)
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i)
		if not (collider is RigidBody3D):
			continue
		var normal := state.get_contact_local_normal(i)
		if normal.angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
			# Wall-side contact — fold into loop_max_wall.
			var normal_h := Vector3(normal.x, 0.0, normal.z)
			if normal_h.length_squared() < 0.01:
				continue
			normal_h = normal_h.normalized()
			# Mark that a dyn-wall contact exists THIS frame (regardless of
			# whether the deadband below skips the actual measurement). This
			# is what wedge fix #6 (hold) keys on to preserve the fraction.
			had_dyn_wall_contact = true
			var into_set: float = -prev_h.dot(normal_h)
			if into_set < 0.1:
				continue
			var into_solved: float = -_jolt_solved_hvel.dot(normal_h)
			var absorbed: float = (into_set - maxf(into_solved, 0.0)) / into_set
			loop_max_wall = maxf(loop_max_wall, clampf(absorbed, 0.0, 1.0))
		else:
			# Walkable-side contact — same measurement as the wall side, just
			# using the full 3D velocity against the floor normal. This reads
			# the actual fraction of into-floor velocity Jolt absorbed, which
			# comes out to the multi-body mass ratio in steady state: a held
			# box converges to fraction = 1, a free body converges to
			# m_b/(m_p+m_b). No threshold, no deadband — exactly proportional.
			var into_set: float = -_dbg_prev_set_vel.dot(normal)
			if into_set < 0.1:
				continue
			var into_solved: float = -state.linear_velocity.dot(normal)
			var absorbed: float = (into_set - maxf(into_solved, 0.0)) / into_set
			_dynamic_floor_fraction = maxf(_dynamic_floor_fraction, clampf(absorbed, 0.0, 1.0))

	# === Wedge fix lifecycle: decide final _dynamic_wall_fraction value ===
	# Default behavior: reset-to-loop-max each tick. Bug: when the projection
	# kills into-wall velocity below the deadband, no measurement updates the
	# fraction, so it falls to 0, projection turns off, velocity comes back,
	# repeating each tick → visible shake.
	if GameManager.debug_wedge_fraction_hold and had_dyn_wall_contact:
		# Hold previous value when contact still exists. Latest measurement
		# (if any) can still raise it. Drains immediately when contact ends.
		_dynamic_wall_fraction = maxf(loop_max_wall, prev_dyn_wall_fraction)
	elif GameManager.debug_wedge_fraction_decay:
		# Decay previous value, but a fresh measurement can still raise it.
		# Naturally drains over a few frames once contact ends.
		_dynamic_wall_fraction = maxf(loop_max_wall, prev_dyn_wall_fraction * GameManager.debug_wedge_fraction_decay_rate)
	else:
		# Default (buggy): full reset, only this tick's measurements count.
		_dynamic_wall_fraction = loop_max_wall

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
		if GameManager.debug_floor_diag:
			print("[FD]   floor_fraction=%.4f  has_static_wall=%s  has_dynamic_wall=%s  restore_branch=%s" % [
				_dynamic_floor_fraction, str(has_static_wall), str(has_dynamic),
				str((not has_static_wall or GameManager.debug_restore_with_walls) and not GameManager.debug_no_floor_speed_restore)])
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
			#
			# Skip ALL contacts on any body that has a walkable contact
			# with us — that's a body we're standing on, and its other
			# contacts (the side walls of the same box/board) only ever
			# generate frictionless depenetration impulses that don't
			# represent a real "push to preserve". Folding them in
			# produces a slow constant slide at the per-frame impulse
			# rate when the capsule overhangs an edge.
			var floor_bodies: Array = []
			for i in state.get_contact_count():
				var col := state.get_contact_collider_object(i)
				if not (col is RigidBody3D):
					continue
				if state.get_contact_local_normal(i).angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
					continue
				if not col in floor_bodies:
					floor_bodies.append(col)
			var dynamic_delta := Vector3.ZERO
			if not GameManager.debug_no_dynamic_speed_restore:
				for i in state.get_contact_count():
					var collider := state.get_contact_collider_object(i)
					if collider is RigidBody3D:
						var on_floor_body := collider in floor_bodies
						var imp := state.get_contact_impulse(i)
						var imp_h := Vector3(imp.x, 0.0, imp.z) / player.mass
						if GameManager.debug_floor_diag:
							print("[FD]   restore c%d: floor_body=%s imp=(%.4f,%.4f,%.4f) /mass=(%.4f,%.4f,%.4f) %s" % [
								i, str(on_floor_body), imp.x, imp.y, imp.z, imp_h.x, imp_h.y, imp_h.z,
								"SKIPPED (on floor body)" if on_floor_body else "ADDED"])
						if on_floor_body:
							continue
						dynamic_delta += imp_h
			if GameManager.debug_floor_diag:
				print("[FD]   restore: set_h=(%.4f,_,%.4f) dynamic_delta=(%.4f,_,%.4f) -> restore_h=(%.4f,_,%.4f)" % [
					set_h.x, set_h.z, dynamic_delta.x, dynamic_delta.z,
					(set_h + dynamic_delta).x, (set_h + dynamic_delta).z])
			var restore_h := set_h + dynamic_delta
			if GameManager.debug_restore_full_speed:
				restore_h = set_h
			var vel := state.linear_velocity
			var pre_restore := Vector2(vel.x, vel.z)
			vel.x = restore_h.x
			vel.z = restore_h.z
			state.linear_velocity = vel
			if GameManager.debug_floor_diag:
				print("[FD]   state.linear_velocity AFTER restore = (%.4f, %.4f, %.4f)   (was (%.4f, _, %.4f))" % [
					vel.x, vel.y, vel.z, pre_restore.x, pre_restore.y])
			if has_dynamic and GameManager.debug_dynamic_contact_log:
				var post_restore := Vector2(vel.x, vel.z)
				print("[DYN_RESTORE] set_h=(%.2f,%.2f) dyn_delta=(%.2f,%.2f) jolt=(%.2f,%.2f) -> restored=(%.2f,%.2f)  speed: %.2f->%.2f" % [
					set_h.x, set_h.z, dynamic_delta.x, dynamic_delta.z,
					pre_restore.x, pre_restore.y, post_restore.x, post_restore.y,
					pre_restore.length(), post_restore.length()])

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
			"world_pos": state.get_contact_collider_position(i),
		})

	# Box-press diagnostic — fires once per tick when player is touching a
	# dynamic body (typical wedge-shake test scenario). Logs everything we'd
	# need to debug the remaining edge case.
	if GameManager.debug_wedge_log:
		_log_box_press_diagnostic(state)

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
	else:
		# Multi-contact wedge synthesis: no single contact is walkable, but
		# multiple non-walkable contacts together might add up to a walkable
		# "virtual" floor (e.g., wedged in a 60° V — each face is too steep
		# alone but their sum points straight up).
		# Filter: any contact with normal.dot(UP) > 0 (any upward bias). Pure
		# vertical walls (dot=0) and ceilings/overhangs (dot<0) are excluded
		# so they don't skew the sum laterally or cancel it out.
		var sum_normal := Vector3.ZERO
		var support_count := 0
		for c in _contacts:
			if c["normal"].dot(Vector3.UP) > 0.0:
				sum_normal += c["normal"]
				support_count += 1
		if support_count >= 2 and sum_normal.length_squared() > 0.001:
			var avg_normal := sum_normal.normalized()
			if avg_normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
				_has_floor_contact = true
				_best_contact_normal = avg_normal

	# Steep non-walkable slopes (50-85°): Jolt marks these as grounded
	# (jumpable), but we should slide down them, not stand. Only count
	# as grounded if there's an actual walkable contact (or synthesized
	# multi-contact wedge floor, set above).
	if _is_grounded and not _has_floor_contact:
		_is_grounded = false

	# Promote grounding when we have a walkable contact but Jolt's flag
	# didn't fire. The C++ grounding patch in jolt_contact_listener_3d.cpp
	# only sets grounded_by_contact for player-vs-static contacts; for
	# player-on-dynamic-body the flag stays false even though we're
	# clearly standing on something walkable. can_jump() already derives
	# from _has_jumpable_contact (GDScript-side, contact-based) and works
	# correctly on dynamic bodies; this brings _is_grounded into the same
	# truth source so the floor-handling pipeline (slope projection,
	# dynamic_delta filter, floor-fraction gravity scale) actually fires.
	if not _is_grounded and _has_floor_contact:
		_is_grounded = true

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
	if GameManager.debug_floor_diag:
		print("[FD] begin_movement: vel_in=(%.4f,%.4f,%.4f)  _is_grounded=%s  _was_grounded=%s  airborne_hvel=(%.4f,_,%.4f)" % [
			player.velocity.x, player.velocity.y, player.velocity.z,
			str(_is_grounded), str(_was_grounded),
			_airborne_hvel.x, _airborne_hvel.z])
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
	if GameManager.debug_floor_diag:
		print("[FD] process_normal_movement IN: vel=(%.4f,%.4f,%.4f) input_dir=(%.2f,%.2f) direction=(%.3f,%.3f,%.3f)" % [
			player.velocity.x, player.velocity.y, player.velocity.z,
			input_dir.x, input_dir.y, direction.x, direction.y, direction.z])

	# Wall projection: if pressing into a wall, project input along the wall
	# surface. The projected length is the cosine of the approach angle —
	# this scales both max speed and current speed so wall sliding feels
	# like normal movement at a reduced rate.
	# Static walls: project direction + scale speed.
	# Dynamic bodies: only scale speed (Jolt handles the contact).
	var wall_speed_fraction: float = 1.0
	if direction != Vector3.ZERO and _is_grounded and not GameManager.debug_no_wall_proj:
		# Find the wall we're pressing most into (static walls for projection)
		var best_into: float = 0.0
		var best_wall_nh := Vector3.ZERO
		var best_dyn_into: float = 0.0
		var best_dyn_wall_nh := Vector3.ZERO
		for c in _contacts:
			if not c["is_walkable"]:
				var wall_n: Vector3 = c["normal"]
				var wall_nh := Vector3(wall_n.x, 0.0, wall_n.z)
				if wall_nh.length_squared() > 0.01:
					wall_nh = wall_nh.normalized()
					var into_wall := direction.dot(wall_nh)
					if c["body"] is RigidBody3D and not GameManager.debug_wall_proj_dynamic:
						if into_wall < best_dyn_into:
							best_dyn_into = into_wall
							best_dyn_wall_nh = wall_nh
					else:
						if into_wall < best_into:
							best_into = into_wall
							best_wall_nh = wall_nh
		# Project input along static wall
		if best_into < 0.0:
			direction -= best_wall_nh * best_into
			wall_speed_fraction = direction.length()
			if wall_speed_fraction > 0.01:
				direction = direction.normalized()
			else:
				direction = Vector3.ZERO
				wall_speed_fraction = 0.0

		# Dynamic body speed scaling AND direction projection: scale by approach
		# angle, weighted by how much the body actually resisted us. A light
		# pushable block barely resists (fraction≈0, no projection). A massive
		# immovable cube fully resists (fraction≈1, full projection like a
		# static wall).
		if best_dyn_into < 0.0 and wall_speed_fraction == 1.0:
			var projected_dir: Vector3 = direction - best_dyn_wall_nh * best_dyn_into
			var cosine_frac: float = projected_dir.length()
			wall_speed_fraction = lerpf(1.0, cosine_frac, _dynamic_wall_fraction)

			# === Wedge fix #1: lerp direction by fraction (default approach) ===
			# At fraction=1 (wedged), direction fully projected (player slides
			# along box surface like a static wall). At fraction=0 (light box),
			# direction unchanged (push naturally). Smooth blend between.
			if GameManager.debug_wedge_lerp_direction and not GameManager.debug_wedge_hard_kill \
					and _dynamic_wall_fraction > 0.0 and projected_dir.length_squared() > 0.0001:
				var projected_unit: Vector3 = projected_dir.normalized()
				direction = direction.lerp(projected_unit, _dynamic_wall_fraction)
				if direction.length_squared() > 0.0001:
					direction = direction.normalized()

			# === Wedge fix #2: hard kill above threshold (more aggressive) ===
			# Once the body is clearly resisting (fraction past threshold),
			# treat it EXACTLY like a static wall. No partial blend — clean
			# step. Trades smoothness near the threshold for guaranteed
			# stability above it.
			if GameManager.debug_wedge_hard_kill \
					and _dynamic_wall_fraction > GameManager.debug_wedge_hard_kill_threshold \
					and projected_dir.length_squared() > 0.0001:
				direction = projected_dir.normalized()
				wall_speed_fraction = cosine_frac

			# (detailed box-press log fires from on_integrate_forces, where the
			# physics state is fully accessible — see _log_box_press_diagnostic)

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

	# Current horizontal velocity. Wedge fix #4: optionally start from the
	# post-solver velocity (Jolt's converged answer) so the script accumulates
	# input ON TOP of physics-resolved motion, instead of overwriting it.
	# This means killed-by-constraint velocity from prior tick stays killed.
	var hvel: Vector3
	if GameManager.debug_wedge_postsolver_base:
		hvel = Vector3(_jolt_solved_hvel.x, 0.0, _jolt_solved_hvel.z)
	else:
		hvel = Vector3(player.velocity.x, 0.0, player.velocity.z)
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

	if GameManager.debug_dynamic_contact_log:
		var angle := rad_to_deg(atan2(direction.x, direction.z)) if direction != Vector3.ZERO else -999.0
		var vel_angle := rad_to_deg(atan2(hvel.x, hvel.z)) if hvel.length() > 0.1 else -999.0
		var rot_deg := rad_to_deg(player.rotation.y)
		print("[DIR] rot=%.0f dir_angle=%.0f vel_angle=%.0f hspeed=%.1f grounded=%s" % [
			rot_deg, angle, vel_angle, hvel.length(), str(_is_grounded)])

	# Wedge fix #3: skip writing velocity entirely when wedged against a
	# heavily-resisting body. Lets Jolt's solver settle the velocity without
	# the script re-injecting input that has nowhere to go. Player effectively
	# stops at the wall (which is what the solver wants).
	var skip_inject_wedged: bool = (
		GameManager.debug_wedge_skip_inject
		and _dynamic_wall_fraction > GameManager.debug_wedge_hard_kill_threshold
	)
	if not skip_inject_wedged:
		player.velocity.x = hvel.x
		player.velocity.z = hvel.z

	_dbg_cur["move_slope_projected"] = false
	_dbg_cur["move_surface_y"] = 0.0
	_dbg_cur["move_slope_normal"] = Vector3.ZERO

	# Slope projection: set vel.y tangent to surface when grounded
	if GameManager.debug_floor_diag:
		print("[FD] process_normal_movement post-ground-move: hvel=(%.4f,_,%.4f) hspeed=%.4f vel=(%.4f,%.4f,%.4f) is_grounded=%s has_floor=%s floor_normal=(%.3f,%.3f,%.3f)" % [
			hvel.x, hvel.z, hvel.length(),
			player.velocity.x, player.velocity.y, player.velocity.z,
			str(_is_grounded), str(_has_floor_contact),
			_floor_normal.x, _floor_normal.y, _floor_normal.z])
	if _is_grounded and _has_floor_contact and not GameManager.debug_no_slope_projection:
		# Slope projection: keep the player's velocity tangent to the surface
		# at the contact point. The constraint is vel · n = body_surface_vel · n,
		# i.e. match the body's motion along the contact normal. Solving for
		# vel.y given hvel:
		#   surface_y = (body_surface_vel · n - n.x·hvel.x - n.z·hvel.z) / n.y
		#
		# Stationary surface (static contact, or held dynamic body):
		#   body_surface_vel = 0 → reduces to the classic formula.
		# Moving/rotating dynamic surface (seesaw end descending under us):
		#   body_surface_vel.y is non-zero → vel.y follows the contact point's
		#   motion → no losing-and-regaining-contact stutter.
		var n := _floor_normal
		var body_surface_vel := Vector3.ZERO
		for c in _contacts:
			if c["is_walkable"] and c["body"] is RigidBody3D:
				var fb: RigidBody3D = c["body"]
				var contact_world: Vector3 = c["world_pos"]
				var offset: Vector3 = contact_world - fb.global_position
				body_surface_vel = fb.linear_velocity + fb.angular_velocity.cross(offset)
				break
		var surface_y := (body_surface_vel.dot(n) - n.x * hvel.x - n.z * hvel.z) / n.y
		player.velocity.y = surface_y
		_dbg_cur["move_slope_projected"] = true
		_dbg_cur["move_surface_y"] = surface_y
		_dbg_cur["move_slope_normal"] = n
		if GameManager.debug_floor_diag:
			print("[FD]   slope-projected: body_surface_vel=(%.3f,%.3f,%.3f) surface_y=%.4f  vel.y set to %.4f" % [
				body_surface_vel.x, body_surface_vel.y, body_surface_vel.z,
				surface_y, player.velocity.y])
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
	var _dbg_log := (GameManager.debug_grounding_log and not _is_grounded) or (GameManager.debug_snap_log and _was_grounded)

	# F12 diagnostic: what is snap actually hitting? Fires every frame snap runs
	# (which is now every frame) — captures collider name, type, normal, distance.
	if GameManager.debug_wedge_log:
		var hit_str := "MISS"
		if result.size() >= 2 and result[1] < 1.0:
			var dbg_params := PhysicsShapeQueryParameters3D.new()
			dbg_params.shape = params.shape
			dbg_params.transform = params.transform
			dbg_params.transform.origin += params.motion * result[1]
			dbg_params.collision_mask = params.collision_mask
			dbg_params.exclude = params.exclude
			var dbg_rest := space.get_rest_info(dbg_params)
			if dbg_rest:
				var dbg_collider: Object = null
				if "collider_id" in dbg_rest:
					dbg_collider = instance_from_id(dbg_rest.collider_id)
				var name_str: String = "?"
				var class_str: String = "?"
				if dbg_collider:
					class_str = dbg_collider.get_class()
					if dbg_collider is Node:
						name_str = (dbg_collider as Node).name
				var n: Vector3 = dbg_rest.normal
				var angle_to_up: float = rad_to_deg(n.angle_to(Vector3.UP))
				hit_str = "%s(%s) safe=%.3f unsafe=%.3f n=(%.2f,%.2f,%.2f) angle_to_up=%.1f°" % [
					name_str, class_str, result[0], result[1],
					n.x, n.y, n.z, angle_to_up]
		print("[SNAP-CAST f%d] grounded=%s was_grounded=%s snap_dist=%.4f → %s" % [
			_dbg_frame_num, str(_is_grounded), str(_was_grounded), snap_dist, hit_str])
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
			if collider is StaticBody3D or collider is VoxelLodTerrain or collider is VoxelTerrain:
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
				# Snap-success is a landing event — reset air-jump charges.
				# begin_movement already ran this frame with _is_grounded=false,
				# so its "_is_grounded and not _was_grounded" transition check
				# never fired; without this explicit reset, the post_physics_step
				# _was_grounded update masks the transition forever and air jumps
				# don't recharge after any snap-induced landing.
				_air_jumps_used = 0
				return true
			elif collider is RigidBody3D:
				# Snap on a dynamic body always, but transfer the impulse that
				# Jolt's contact solver would have applied so the body still
				# gets its mass-weighted share of the impact. Without this,
				# either we threshold off (and flicker on wavy walking) or we
				# eat all of the player's momentum (and the body never moves).
				# With the impulse, snap behaves like static snap from the
				# player's perspective AND like a real contact from the body's
				# perspective — matching the "infinite-mass walls feel the
				# same as light walls except the light wall actually moves"
				# rule used elsewhere.
				var rb := collider as RigidBody3D
				var n: Vector3 = rest.normal
				var contact_world: Vector3 = rest.get("point", player.global_position)
				var body_offset: Vector3 = contact_world - rb.global_position
				var body_surface_vel: Vector3 = rb.linear_velocity + rb.angular_velocity.cross(body_offset)
				var rel_vel: Vector3 = player.velocity - body_surface_vel
				var into_speed: float = -rel_vel.dot(n)
				if into_speed > 0.0:
					# Mass-weighted impulse. Apply opposite-direction impulse
					# at the contact point on the body — same magnitude Jolt's
					# solver would produce for this collision.
					var m_eff: float = (player.mass * rb.mass) / (player.mass + rb.mass)
					var impulse: float = m_eff * into_speed
					rb.apply_impulse(-impulse * n, body_offset)
				if _dbg_log:
					print("[SNAP] HIT dynamic dist=%.4f normal=(%.2f,%.2f,%.2f) into_speed=%.3f impulse_to_body=%.3f" % [
						snap_dist, n.x, n.y, n.z, into_speed,
						(player.mass * rb.mass) / (player.mass + rb.mass) * maxf(into_speed, 0.0)])
				# Player side: same handling as static snap — kinematic
				# teleport + slope-projected vel.y. Eats whatever falling
				# velocity we had, but the body already received its impulse
				# share above so momentum balance is preserved.
				player.global_position.y += snap_dist * result[0]
				if not GameManager.debug_grounding_no_snap_ground:
					_is_grounded = true
					_floor_normal = n
					_has_floor_contact = true
				player.velocity.x = _airborne_hvel.x
				player.velocity.z = _airborne_hvel.z
				player.velocity.y = -(n.x * player.velocity.x + n.z * player.velocity.z) / n.y
				_air_jumps_used = 0
				return true
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
	if _dbg_is_overlapping and GameManager.debug_dynamic_contact_log:
		var ppos := player.global_position
		var vel_y := player.linear_velocity.y
		for r in overlap_results:
			var col = instance_from_id(r.collider_id)
			var shape_name := "?"
			if col is CollisionObject3D:
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
	_dbg_is_skidding = false
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

	# Skid: above SKID_THRESHOLD or above max_speed (overspeed from landing,
	# boost, etc). Skid steers toward input and decelerates via friction,
	# naturally bringing speed back to max_speed where normal movement takes over.
	if hspeed >= SKID_THRESHOLD or hspeed > max_speed:
		_dbg_is_skidding = true
		return _process_skid(hvel, hspeed, hdir, delta)

	# Dime stop: project input onto any wall contact surface (static or dynamic).
	# If the wall-projected input opposes the current velocity, dime stop.
	# Wall-projected dime stop fires at any speed (below skid) because wall
	# sliding speed isn't capped the same way on dynamic bodies.
	# Non-wall dime stop uses DIME_STOP_SPEED threshold.
	if not GameManager.debug_no_dime_stop:
		var check_dir := hdir
		var wall_projected := false
		for c in _contacts:
			if c["is_walkable"]:
				continue
			var wn: Vector3 = c["normal"]
			var wnh := Vector3(wn.x, 0.0, wn.z)
			if wnh.length_squared() > 0.01:
				wnh = wnh.normalized()
				var into := check_dir.dot(wnh)
				if into < 0.0:
					check_dir = check_dir - wnh * into
					if check_dir.length_squared() > 0.001:
						check_dir = check_dir.normalized()
						wall_projected = true
					break
		var vel_along := hvel.dot(check_dir)
		var just_landed := _is_grounded and not _was_grounded
		if vel_along < 0.0 and (wall_projected or just_landed or hspeed <= DIME_STOP_SPEED):
			hvel -= check_dir * vel_along
			hspeed = hvel.length()

	# Accelerate toward input direction up to max speed
	var vel_toward_target := hvel.dot(hdir)

	if vel_toward_target < max_speed:
		var speed_add := accel * delta
		var new_toward := minf(vel_toward_target + speed_add, max_speed)
		hvel += hdir * (new_toward - vel_toward_target)

	# Clamp to max speed. Always clamp if acceleration ran this frame (new_speed > hspeed).
	# Also clamp if we entered from skid (hspeed was above max but accel brought it close).
	var new_speed := hvel.length()
	if new_speed > max_speed:
		hvel = hvel.normalized() * max_speed

	return hvel


func _process_skid(hvel: Vector3, hspeed: float, input_dir: Vector3, delta: float) -> Vector3:
	## Skid mode: steer + decelerate. Steering uses the same acceleration
	## as normal movement — add accel along input, normalize back to current
	## speed. This makes skid turning feel identical to ground turning.
	# Steer: add acceleration along input, then normalize to preserve speed
	hvel += input_dir * WALK_ACCEL * delta
	hvel = hvel.normalized() * hspeed

	# Friction: decelerate toward max speed
	var new_speed := maxf(hspeed - SKID_FRICTION * delta, 0.0)

	return hvel.normalized() * new_speed


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
		# Don't let movement input increase speed. Cap to whatever we started
		# with or max_speed, whichever is higher. Preserves external boosts.
		var speed_cap := maxf(max_speed, hspeed)
		var new_air_speed := hvel.length()
		if new_air_speed > speed_cap:
			hvel *= speed_cap / new_air_speed

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
		# Unified gravity: decompose against floor normal, scale tangent by
		# (1 - resistance_fraction). Static walkable contacts always fully
		# resist tangent motion (resistance = 1), so the formula naturally
		# generalizes — no separate skip-gravity branch needed.
		#
		#   gravity_n = component along contact normal — continuous weight
		#     transfer through Jolt's solver. The solver iterates this with
		#     any other contacts the body has (floor, neighbors, sandwich
		#     pin) and converges to the right multi-body answer: static
		#     surfaces fully cancel it; a held dynamic body passes weight
		#     to whatever holds it; a free body gets shoved proportional
		#     to mass ratio.
		#   gravity_t = tangent component — frictionless slide. Scaled by
		#     (1 - resistance): static / held body (resistance = 1) adds no
		#     tangent; free body (resistance → 0) adds full tangent, sliding
		#     you proportional to how much the body itself was shoved.
		#
		# Why this matters beyond simplification: applying gravity_n on
		# static floors counteracts upward velocity injections from other
		# contacts (e.g., friction-Y-leak from pushing a spinning box). The
		# previous skip-gravity-on-static branch left those leaks to drift
		# the player upward until Jolt's contact tolerance was exceeded.
		var has_static_walkable := false
		var has_dynamic_walkable := false
		for c in _contacts:
			if c["is_walkable"]:
				if c["body"] is RigidBody3D:
					has_dynamic_walkable = true
				else:
					has_static_walkable = true
		# Effective resistance: any static contact is fully resistant.
		var resistance_fraction: float = 1.0 if has_static_walkable else _dynamic_floor_fraction
		var n := _floor_normal
		var gravity_v := Vector3(0.0, -player.gravity * delta, 0.0)
		var gravity_n := n * gravity_v.dot(n)
		var gravity_t := gravity_v - gravity_n
		var applied := gravity_n + gravity_t * (1.0 - resistance_fraction)
		player.velocity += applied
		if GameManager.debug_floor_diag:
			print("[FD] apply_snap_and_gravity: grounded  static=%s dynamic=%s resistance=%.4f  gravity_n=(%.4f,%.4f,%.4f) gravity_t=(%.4f,%.4f,%.4f) applied=(%.4f,%.4f,%.4f)  vel_out=(%.4f,%.4f,%.4f)" % [
				str(has_static_walkable), str(has_dynamic_walkable), resistance_fraction,
				gravity_n.x, gravity_n.y, gravity_n.z,
				gravity_t.x, gravity_t.y, gravity_t.z,
				applied.x, applied.y, applied.z,
				player.velocity.x, player.velocity.y, player.velocity.z])
		Profiler.end("movement_snap_gravity")
		return
	# Snap was already attempted in try_snap_to_ground before begin_movement.
	# If it had succeeded, _is_grounded would be true and we'd be in the branch
	# above. So at this point we're truly airborne — apply gravity.
	player.velocity.y -= player.gravity * delta
	Profiler.end("movement_snap_gravity")


# ======================================================================
#  Pipeline step 2.5: try_snap_to_ground — runs BEFORE begin_movement
# ======================================================================
#
# When pre_physics_step couldn't ground us via contacts (typical on dynamic
# compound bodies where Jolt drops contact for a frame at tile boundaries),
# attempt a downward capsule cast and promote grounding if a walkable surface
# is within reach. Running this before begin_movement means slope projection,
# walk-acceleration, and the landing transition see correct grounded state on
# brief contact-loss frames, instead of branching airborne for a frame and
# papering over the consequences later in apply_snap_and_gravity.

func try_snap_to_ground(delta: float) -> bool:
	Profiler.begin("movement_try_snap")
	# Snap now runs every frame (was: skipped when _is_grounded). Running while
	# grounded is essentially a no-op when the player is already exactly on the
	# floor (cast hits at distance 0, position correction is 0). When the player
	# has drifted upward (e.g., friction-Y-leak from pushing a spinning box),
	# snap pulls position back to the floor every frame instead of waiting for
	# Jolt's contact tolerance to be exceeded — eliminates the "rises a few cm
	# then snaps back" behavior.
	# Save horizontal vel before snap may modify it.
	_airborne_hvel = Vector3(player.velocity.x, 0.0, player.velocity.z)
	var flicker_frame: bool = GameManager.debug_snap_log and _was_grounded
	if _post_jump_rising:
		if flicker_frame:
			print("[SNAP-FLICKER] SKIPPED: _post_jump_rising=true (timer=%.3f) vel_y=%.4f" % [
				_post_jump_timer, player.velocity.y])
		Profiler.end("movement_try_snap")
		return false
	# Kinematic displacement: where will we be after one frame of gravity?
	#   x = v*t - 0.5*g*t²
	# Negative = downward. If the ground is within this distance, snap to it.
	# Floor: even when going up, always search at least one gravity frame
	# downward (0.5*g*t² from rest) so terrain face changes are caught.
	var kinematic := player.velocity.y * delta - 0.5 * player.gravity * delta * delta
	var recently_jolt_grounded := (Time.get_ticks_msec() / 1000.0 - _last_jolt_grounded_time) < 0.15
	var snap_dist := minf(kinematic, -0.5 * player.gravity * delta * delta)
	# Extend snap budget by 5cm whenever we were grounded last frame (by any
	# mechanism — Jolt contact OR snap promotion). _was_grounded persists
	# through snap-recovered frames so this works on compound dynamic bodies
	# where Jolt's contact listener drops contact frame-to-frame.
	if _was_grounded or recently_jolt_grounded:
		snap_dist -= GameManager.debug_snap_budget
		# Optional: dynamic snap. When launched off a steep slope, one frame
		# of integration carries the capsule vel.y × delta meters upward.
		# Extending snap by that amount lets it find the slope again.
		# Capped at 20cm so genuine airborne motion (jumps, knockback) isn't
		# dragged back down. Off by default — toggle in pause menu.
		if GameManager.debug_dynamic_snap:
			var launch_offset: float = maxf(player.velocity.y * delta, 0.0)
			snap_dist -= minf(launch_offset, 0.20)
	if GameManager.debug_grounding_extend_snap:
		snap_dist = minf(snap_dist, -0.5)
	if flicker_frame:
		var prev_n := _floor_normal
		var prev_angle := rad_to_deg(prev_n.angle_to(Vector3.UP))
		print("[SNAP-FLICKER] vel_y=%.4f kinematic=%.4f snap_dist=%.4f recent_jolt=%s post_jump=%s prev_normal=(%.3f,%.3f,%.3f) prev_angle=%.1f° contacts=%d walkable=%d" % [
			player.velocity.y, kinematic, snap_dist,
			str(recently_jolt_grounded), str(_post_jump_rising),
			prev_n.x, prev_n.y, prev_n.z, prev_angle,
			_contacts.size(), _contacts.filter(func(c): return c["is_walkable"]).size()])
	if _do_snap(snap_dist):
		if flicker_frame:
			print("[SNAP-FLICKER]   → RECOVERED via snap")
		Profiler.end("movement_try_snap")
		return true
	if flicker_frame:
		# Snap missed. Measure where the ground actually is so we can see
		# whether snap_dist was too short, the angle was wrong, or there's
		# truly nothing below.
		var space := player.get_world_3d().direct_space_state
		var col_shape: CollisionShape3D = player.get_node("CollisionShape3D")
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = col_shape.shape
		params.transform = col_shape.global_transform
		params.motion = Vector3(0, -2.0, 0)
		params.collision_mask = player.collision_mask
		params.exclude = [player.get_rid()]
		var result := space.cast_motion(params)
		if result[1] < 1.0:
			var hit_params := PhysicsShapeQueryParameters3D.new()
			hit_params.shape = params.shape
			hit_params.transform = params.transform
			hit_params.transform.origin += params.motion * result[1]
			hit_params.collision_mask = params.collision_mask
			hit_params.exclude = params.exclude
			var rest := space.get_rest_info(hit_params)
			if rest:
				var hit_angle := rad_to_deg(rest.normal.angle_to(Vector3.UP))
				print("[SNAP-FLICKER]   → MISS. ground=%.4fm below (snap was %.4f), normal=(%.2f,%.2f,%.2f) angle=%.1f° walkable=%s" % [
					-2.0 * result[1], snap_dist,
					rest.normal.x, rest.normal.y, rest.normal.z, hit_angle,
					str(hit_angle <= rad_to_deg(FLOOR_MAX_ANGLE))])
			else:
				print("[SNAP-FLICKER]   → MISS. ground=%.4fm below (no rest info)" % [-2.0 * result[1]])
		else:
			print("[SNAP-FLICKER]   → MISS. no ground within 2m")
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
	Profiler.end("movement_try_snap")
	return false


# ======================================================================
#  Pipeline step 6: post_physics_step — debug logging
# ======================================================================

func post_physics_step(_delta: float, _grapple_active: bool) -> void:
	# _airborne_hvel is saved in try_snap_to_ground (which runs before
	# begin_movement). It captures end-of-last-frame vel.x/z, which is the
	# input-applied "intended" hvel that snap or begin_movement's landing
	# transition restore.

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

	if GameManager.debug_floor_diag:
		print("[FD] post_physics_step (end of frame %d): saving prev_set_vel = (%.4f, %.4f, %.4f)  pos=(%.3f,%.3f,%.3f)  is_grounded=%s" % [
			_dbg_frame_num, player.velocity.x, player.velocity.y, player.velocity.z,
			player.global_position.x, player.global_position.y, player.global_position.z,
			str(_is_grounded)])
		print("[FD] ─── end frame %d ───" % _dbg_frame_num)

	# F8 flicker tracker — compact transition log. One line per state change
	# (grounded ↔ airborne) and one line on significant floor-normal jumps.
	if GameManager.debug_floor_flicker:
		if _is_grounded != _flicker_prev_grounded:
			# Transition. Show how long previous state lasted.
			if _is_grounded:
				print("[FLK] f%d  AIR→GND after %d air frames  vel=(%.2f,%.2f,%.2f)  pos.y=%.3f  n=(%.3f,%.3f,%.3f)  contacts=%d" % [
					_dbg_frame_num, _flicker_air_streak,
					player.velocity.x, player.velocity.y, player.velocity.z,
					player.global_position.y,
					_floor_normal.x, _floor_normal.y, _floor_normal.z,
					_contact_count])
				_flicker_gnd_streak = 0
				_flicker_prev_normal = _floor_normal
			else:
				print("[FLK] f%d  GND→AIR after %d gnd frames  vel=(%.2f,%.2f,%.2f)  pos.y=%.3f  contacts=%d  post_jump_rising=%s" % [
					_dbg_frame_num, _flicker_gnd_streak,
					player.velocity.x, player.velocity.y, player.velocity.z,
					player.global_position.y,
					_contact_count, str(_post_jump_rising)])
				_flicker_air_streak = 0
		else:
			if _is_grounded:
				_flicker_gnd_streak += 1
				# Log significant floor-normal change (5° or more) while grounded.
				var ang_jump: float = rad_to_deg(_flicker_prev_normal.angle_to(_floor_normal))
				if ang_jump > 5.0:
					print("[FLK] f%d  NORMAL JUMP +%.1f°  prev=(%.3f,%.3f,%.3f) new=(%.3f,%.3f,%.3f)  vel.y=%.3f" % [
						_dbg_frame_num, ang_jump,
						_flicker_prev_normal.x, _flicker_prev_normal.y, _flicker_prev_normal.z,
						_floor_normal.x, _floor_normal.y, _floor_normal.z,
						player.velocity.y])
					_flicker_prev_normal = _floor_normal
			else:
				_flicker_air_streak += 1
		_flicker_prev_grounded = _is_grounded

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
	return (_has_jumpable_contact or _was_grounded) and not _post_jump_rising


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
#  Box-press diagnostic
# ======================================================================

func _log_box_press_diagnostic(state: PhysicsDirectBodyState3D) -> void:
	## Comprehensive single-line-per-tick log of player + dynamic-body contact
	## state. Fires from on_integrate_forces only when there's at least one
	## dynamic-body contact. Designed to diagnose box-vs-wall shake / phasing.
	##
	## Captures:
	##   - Player: pos, vel (3 layers: script-set, jolt-solved, current state)
	##   - Wedge fix state: dyn_wall_fraction value, which fixes are active
	##   - For each dynamic body contact: body name, mass, vel, pos,
	##     contact normal/point/depth, body's vel at contact point
	##   - "Pressed against" detection: shape-cast the box collision in the
	##     direction the player is pushing; report any blocking hit (the wall
	##     the box is wedged against, or empty space if it can move)
	##   - Phase detection: if player's contact point is INSIDE the box's
	##     shape (penetration depth > some threshold), flag as PHASING

	# Find the first dynamic-body wall-side contact (most relevant for wedge).
	var dyn_idx: int = -1
	for i in state.get_contact_count():
		var col := state.get_contact_collider_object(i)
		if not (col is RigidBody3D):
			continue
		var n := state.get_contact_local_normal(i)
		if n.angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
			dyn_idx = i
			break
	if dyn_idx < 0:
		return  # No dyn-wall contact, nothing to log

	var box: RigidBody3D = state.get_contact_collider_object(dyn_idx)
	var contact_n: Vector3 = state.get_contact_local_normal(dyn_idx)
	var contact_pt: Vector3 = state.get_contact_collider_position(dyn_idx)

	# Player layer
	var player_pos: Vector3 = player.global_position
	var player_vel: Vector3 = state.linear_velocity
	var script_set_vel: Vector3 = _dbg_prev_set_vel
	var solved_h: Vector3 = _jolt_solved_hvel

	# Box state
	var box_vel: Vector3 = box.linear_velocity
	var box_avel: Vector3 = box.angular_velocity
	var box_pos: Vector3 = box.global_position
	var box_mass: float = box.mass

	# Box velocity AT the contact point (linear + angular contribution).
	var offset: Vector3 = contact_pt - box_pos
	var box_vel_at_pt: Vector3 = box_vel + box_avel.cross(offset)

	# "Pressed against": shape-cast the box's collision shape in the direction
	# the player is pushing (= -contact_n). Report any blocking hit within
	# 5cm. That's the static wall (or other body) the box is wedged against.
	var pressed_into_name := "(none)"
	var pressed_into_dist := -1.0
	var pressed_into_normal := Vector3.ZERO
	var space := player.get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	# Use the box's own shape — find its CollisionShape3D child.
	var box_collision: CollisionShape3D = null
	for child in box.get_children():
		if child is CollisionShape3D:
			box_collision = child
			break
	if box_collision and box_collision.shape:
		query.shape = box_collision.shape
		# Use full global transform of the collision shape (handles offsets).
		query.transform = box_collision.global_transform
		query.exclude = [box.get_rid(), player.get_rid()]
		query.collision_mask = 0xFFFFFFFF
		# Probe far enough to catch a wall the box was pushed back from during
		# oscillation (5cm was too short — box bounces away from wall mid-shake).
		var probe_dist := 0.5
		query.motion = -contact_n * probe_dist
		# cast_motion returns [safe_fraction, unsafe_fraction]. If safe < 1, blocked.
		var cast_result: PackedFloat32Array = space.cast_motion(query)
		if cast_result.size() >= 2 and cast_result[0] < 1.0:
			pressed_into_dist = cast_result[0] * probe_dist
			# Move query to the just-before-collision pose for rest_info.
			query.transform = box_collision.global_transform.translated(query.motion * cast_result[0])
			query.motion = Vector3.ZERO
			var rest := space.get_rest_info(query)
			if rest.size() > 0:
				pressed_into_normal = rest.get("normal", Vector3.ZERO)
				var collider = rest.get("collider", null)
				if collider and collider is Node:
					pressed_into_name = (collider as Node).name

		# Fallback: overlap test — what bodies are within ~5cm of the box right
		# now in any direction? Helps when the box isn't aligned-pressed-into-wall
		# but is wedged between multiple things, or the contact normal we're
		# casting from isn't the wall direction.
		if pressed_into_name == "(none)":
			query.transform = box_collision.global_transform
			query.motion = Vector3.ZERO
			var nearby := space.intersect_shape(query, 8)
			if nearby.size() > 0:
				var names: Array[String] = []
				for hit in nearby:
					var c = hit.get("collider", null)
					if c and c is Node:
						names.append((c as Node).name)
				pressed_into_name = "overlap[" + ", ".join(names) + "]"

	# Phase detection: is the player's contact point INSIDE the box?
	# Check the player capsule's distance to the box surface. If the contact
	# point has crossed past the box's surface significantly, we're phasing.
	# (Using contact normal direction as the surface-out direction.)
	var phase_depth := 0.0
	var local_contact: Vector3 = box.global_transform.affine_inverse() * contact_pt
	# For a box shape, check if contact_pt is well inside its extents.
	if box_collision and box_collision.shape is BoxShape3D:
		var box_size: Vector3 = (box_collision.shape as BoxShape3D).size
		var half := box_size * 0.5
		var penetration_x: float = half.x - abs(local_contact.x)
		var penetration_y: float = half.y - abs(local_contact.y)
		var penetration_z: float = half.z - abs(local_contact.z)
		# If all three are positive AND the smallest is significant, it's phasing.
		var min_pen: float = minf(minf(penetration_x, penetration_y), penetration_z)
		if min_pen > 0.02:  # 2cm inside on all axes = phasing
			phase_depth = min_pen

	# Active wedge fix labels
	var fix_labels: Array[String] = []
	if GameManager.debug_wedge_lerp_direction: fix_labels.append("Lerp")
	if GameManager.debug_wedge_hard_kill: fix_labels.append("HardKill")
	if GameManager.debug_wedge_skip_inject: fix_labels.append("Skip")
	if GameManager.debug_wedge_postsolver_base: fix_labels.append("PostSolver")
	if GameManager.debug_wedge_fraction_decay: fix_labels.append("Decay")
	if GameManager.debug_wedge_fraction_hold: fix_labels.append("Hold")
	var fix_str: String = "/".join(fix_labels) if fix_labels.size() > 0 else "(none)"

	print("[BOXLOG f%d] PLR pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) set=(%.2f,_,%.2f) solved=(%.2f,_,%.2f)" % [
		_dbg_frame_num,
		player_pos.x, player_pos.y, player_pos.z,
		player_vel.x, player_vel.y, player_vel.z,
		script_set_vel.x, script_set_vel.z,
		solved_h.x, solved_h.z])
	print("           BOX %s mass=%.1fkg pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) avel=(%.1f,%.1f,%.1f)deg" % [
		box.name,
		box_mass,
		box_pos.x, box_pos.y, box_pos.z,
		box_vel.x, box_vel.y, box_vel.z,
		rad_to_deg(box_avel.x), rad_to_deg(box_avel.y), rad_to_deg(box_avel.z)])
	print("           CONTACT n=(%.2f,%.2f,%.2f) pt=(%.2f,%.2f,%.2f) box_vel_at_pt=(%.2f,%.2f,%.2f)" % [
		contact_n.x, contact_n.y, contact_n.z,
		contact_pt.x, contact_pt.y, contact_pt.z,
		box_vel_at_pt.x, box_vel_at_pt.y, box_vel_at_pt.z])
	print("           PRESSED_INTO=%s dist=%.3fm normal=(%.2f,%.2f,%.2f)  PHASE_DEPTH=%.3fm  dyn_frac=%.3f  fixes=%s" % [
		pressed_into_name, pressed_into_dist,
		pressed_into_normal.x, pressed_into_normal.y, pressed_into_normal.z,
		phase_depth,
		_dynamic_wall_fraction,
		fix_str])


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
