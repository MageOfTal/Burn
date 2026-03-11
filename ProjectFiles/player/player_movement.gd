extends PlayerSubsystem
class_name PlayerMovement

## Player movement subsystem — owns floor detection, slope-projected velocity,
## wall-slide, and acceleration. Jolt handles position integration and collision.
##
## Delegated from player.gd: player retains _integrate_forces() and
## _physics_process() callbacks but calls into movement at specific points.
## Subsystems access movement state via player.movement (e.g.
## player.movement._is_grounded). Public API is player.is_on_floor() and
## player.get_floor_normal() which proxy here.

# ======================================================================
#  Constants
# ======================================================================

const SPEED := 50.0
const JUMP_VELOCITY := 10.5
const WALK_ACCEL: float = 30.33  ## Ground acceleration (m/s²) — 0.3s to top speed
const ACCELERATION := 45.0
const DECELERATION := 30.0
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 0.0

const FLOOR_MAX_ANGLE: float = 0.8727  ## 50 degrees — walkable threshold
const SLOPE_MAX_GROUND_ANGLE: float = 1.4835  ## 85 degrees — grounding ceiling
const SLOPE_SLIDE_MAX_SPEED: float = 20.0  ## Terminal velocity for slope gravity
const CONTROL_SPEED_THRESHOLD: float = 50.0  ## Below this: instant stop, full control. Above: uncontrolled skid.
const INSTANT_STOP_THRESHOLD: float = 13.0  ## Above this: friction decel on release instead of instant stop
const SKID_FRICTION: float = 20.0  ## Deceleration (m/s²) in uncontrolled regime
const SKID_STEER_STRENGTH: float = 3.0  ## How fast skid direction rotates toward input (lerp rate/sec)
const SURFACE_PRESS_DEPTH: float = 0.06  ## Target penetration depth (m) per frame for contact maintenance

# ======================================================================
#  State
# ======================================================================

## Floor detection (contact-based — Jolt contacts from _integrate_forces)
var _is_grounded: bool = false
var _floor_normal: Vector3 = Vector3.UP
var _floor_y: float = -INF
var _was_grounded: bool = false
var _slope_traction: float = 1.0  ## cos(slope_angle): 1.0 = flat, 0.0 = vertical

## Grounded velocity tracking
var _ground_velocity: Vector3 = Vector3.ZERO

## Contact tracking (set in on_integrate_forces each tick)
var _has_floor_contact: bool = false  ## Any walkable contact exists
var _best_contact_normal: Vector3 = Vector3.ZERO  ## Most upward-facing contact normal (any body type)
var _dbg_last_contact_count: int = 0  ## Total contacts last physics tick

## Press undo: tracks the press velocity applied last frame so we can undo it
## if the capsule launched (solver didn't absorb it because there's no contact).
var _last_press_vel: Vector3 = Vector3.ZERO

## Landing correction: position/velocity we sent Jolt last frame, used to undo
## slope deflection on landing (solver converts vertical impact into horizontal).
var _last_sent_pos: Vector3 = Vector3.ZERO

## Non-floor obstacle normals (>FLOOR_MAX_ANGLE) for wall-slide projection
var _obstacle_normals: Array[Vector2] = []

## Air-jump tracking
var _air_jumps_used: int = 0

## Post-jump rising suppression (prevents re-grounding on uphill slopes)
var _post_jump_rising: bool = false
var _left_ground_since_jump: bool = false

## Debug: momentum-based ungrounding flash timer (seconds remaining)
var _momentum_launch_flash: float = 0.0
## Debug: reason string for last momentum ungrounding
var _momentum_launch_reason: String = ""

## Pipeline trace — captures velocity/state at every stage each frame.
## On ground→air transitions, dumps the last grounded + first airborne frame.
var _dbg_set_vel: Vector3 = Vector3.ZERO  ## Velocity we gave Jolt last frame
var _dbg_set_pos_y: float = 0.0  ## Position when we gave Jolt last frame
var _prev_solver_push: float = 0.0  ## Previous frame's solver position push (for raycast tolerance)
var _curr_solver_push: float = 0.0  ## Current frame's solver push (becomes prev next frame)
var _frame_trace: String = ""  ## Current frame's accumulated trace
var _prev_frame_trace: String = ""  ## Previous frame's trace (for transition dump)
var _trace_air_frames: int = 0  ## Consecutive airborne frames
var _trace_normal_ran: bool = false  ## Whether process_normal_movement ran this frame

## Wall-force budget tracking (populated during pipeline, printed in post_physics_step)
var _dbg_h_sent: Vector2 = Vector2.ZERO       ## Horizontal we sent to Jolt last frame
var _dbg_h_jolt: Vector2 = Vector2.ZERO       ## Horizontal Jolt returned
var _dbg_h_after_undo: Vector2 = Vector2.ZERO ## After press undo
var _dbg_h_after_pull: Vector2 = Vector2.ZERO ## After slope pull
var _dbg_h_after_move: Vector2 = Vector2.ZERO ## After move_toward
var _dbg_h_final: Vector2 = Vector2.ZERO      ## Final (after press)


# ======================================================================
#  Delegation entry points (called from player.gd)
# ======================================================================

func on_integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	## Sample contact normals for wall-slide and best floor contact.
	## Called from player._integrate_forces() each physics tick.

	# --- Start frame trace ---
	_dbg_h_sent = Vector2(_dbg_set_vel.x, _dbg_set_vel.z)
	_dbg_h_jolt = Vector2(player.velocity.x, player.velocity.z)
	_frame_trace = "  Jolt->us: vel=(%.3f, %.3f, %.3f) pos_y=%.4f" % [
		player.velocity.x, player.velocity.y, player.velocity.z, player.global_position.y]
	if _dbg_set_vel != Vector3.ZERO:
		var dv_y := player.velocity.y - _dbg_set_vel.y
		var push_y := (player.global_position.y - _dbg_set_pos_y) - _dbg_set_vel.y * state.step
		_prev_solver_push = _curr_solver_push
		_curr_solver_push = absf(push_y)
		_frame_trace += "\n  Solver delta: we_set_y=%.4f jolt_returned_y=%.4f dv_y=%+.4f pos_push=%+.5fm" % [
			_dbg_set_vel.y, player.velocity.y, dv_y, push_y]
	_trace_normal_ran = false

	_has_floor_contact = false
	_best_contact_normal = Vector3.ZERO

	var best_y := -1.0
	var static_count := 0
	var rigid_count := 0

	var obstacles: Array[Vector2] = []
	var contact_str := ""
	var _capture := player.capture_movement
	for i in state.get_contact_count():
		var normal: Vector3 = state.get_contact_local_normal(i)
		var collider := state.get_contact_collider_object(i)
		var is_rigid := collider is RigidBody3D
		# Track walkable floor contacts (any body type)
		if normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			_has_floor_contact = true
		if is_rigid:
			rigid_count += 1
		else:
			static_count += 1
		# Track the most upward-facing contact regardless of body type
		if normal.y > best_y:
			best_y = normal.y
			_best_contact_normal = normal
		var contact_angle := normal.angle_to(Vector3.UP)
		contact_str += " [%s %.1f°]" % ["R" if is_rigid else "S",
			rad_to_deg(contact_angle)]
		if _capture and contact_angle > FLOOR_MAX_ANGLE:
			var cpos: Vector3 = state.get_contact_local_position(i)
			var cname: String = collider.name if collider else "?"
			contact_str += "{n=(%.3f,%.3f,%.3f) p=(%.2f,%.2f,%.2f) %s}" % [
				normal.x, normal.y, normal.z, cpos.x, cpos.y, cpos.z, cname]
		# Obstacle normals: all non-floor static contacts for wall-slide
		if not is_rigid and contact_angle > FLOOR_MAX_ANGLE:
			var n2 := Vector2(normal.x, normal.z).normalized()
			var is_dup := false
			for existing in obstacles:
				if n2.dot(existing) > 0.966:
					is_dup = true
					break
			if not is_dup:
				obstacles.append(n2)
	_obstacle_normals = obstacles
	_dbg_last_contact_count = state.get_contact_count()
	_frame_trace += "\n  Contacts: %d (S:%d R:%d)%s best_y=%.3f" % [
		_dbg_last_contact_count, static_count, rigid_count, contact_str, best_y]


func pre_physics_step(delta: float) -> void:
	## Update floor detection before movement runs.
	## Called at the start of the server block in player._physics_process().
	if _momentum_launch_flash > 0.0:
		_momentum_launch_flash = maxf(_momentum_launch_flash - delta, 0.0)
	_update_ground_state(delta)


	# Proportional press undo: measure how much the solver absorbed the press
	# by projecting the solver's velocity correction onto the press direction.
	# Undo only the unabsorbed remainder — prevents false launches on ramp lips
	# (where wall contacts absorb the press) while still giving clean launches
	# (where zero contacts means zero absorption).
	if _last_press_vel != Vector3.ZERO and _dbg_set_vel != Vector3.ZERO:
		var solver_correction: Vector3 = player.velocity - _dbg_set_vel
		var press_dir: Vector3 = _last_press_vel.normalized()
		var press_mag: float = _last_press_vel.length()
		var absorbed: float = solver_correction.dot(press_dir)
		var unabsorbed: float = maxf(press_mag - absorbed, 0.0)
		var _capture := player.capture_movement
		if _capture and _obstacle_normals.size() > 0:
			_frame_trace += "\n  [PRESS UNDO DEBUG]"
			_frame_trace += "\n    vel_before_undo=(%.4f, %.4f, %.4f)" % [
				player.velocity.x, player.velocity.y, player.velocity.z]
			_frame_trace += "\n    we_set=(%.4f, %.4f, %.4f)" % [
				_dbg_set_vel.x, _dbg_set_vel.y, _dbg_set_vel.z]
			_frame_trace += "\n    solver_correction=(%.4f, %.4f, %.4f) mag=%.4f" % [
				solver_correction.x, solver_correction.y, solver_correction.z,
				solver_correction.length()]
			_frame_trace += "\n    press_vel=(%.4f, %.4f, %.4f) press_dir=(%.4f, %.4f, %.4f) press_mag=%.4f" % [
				_last_press_vel.x, _last_press_vel.y, _last_press_vel.z,
				press_dir.x, press_dir.y, press_dir.z, press_mag]
			_frame_trace += "\n    absorbed=%.4f unabsorbed=%.4f" % [absorbed, unabsorbed]
			# Per-wall breakdown: how much each wall contributes to solver_correction along press_dir
			for wi in _obstacle_normals.size():
				var wn2: Vector2 = _obstacle_normals[wi]
				var wn3 := Vector3(wn2.x, 0.0, wn2.y)
				var wall_response := solver_correction.dot(wn3)
				var wall_press_contam := wn3.dot(press_dir) * wall_response
				_frame_trace += "\n    wall[%d] n2=(%.3f,%.3f) solver_dot_wall=%+.4f wall_contam_on_press=%+.4f" % [
					wi, wn2.x, wn2.y, wall_response, wall_press_contam]
		if unabsorbed > 0.01:
			player.velocity += press_dir * unabsorbed
			_frame_trace += "\n  Press undo: %.3f/%.3f (absorbed=%.3f)" % [
				unabsorbed, press_mag, absorbed]
			if _capture and _obstacle_normals.size() > 0:
				_frame_trace += "\n    vel_after_undo=(%.4f, %.4f, %.4f)" % [
					player.velocity.x, player.velocity.y, player.velocity.z]
		_last_press_vel = Vector3.ZERO

	_dbg_h_after_undo = Vector2(player.velocity.x, player.velocity.z)

	_frame_trace += "\n  Ground: grounded=%s (was=%s) normal=(%.3f,%.3f,%.3f) angle=%.1f° walkable=%s" % [
		_is_grounded, _was_grounded,
		_floor_normal.x, _floor_normal.y, _floor_normal.z,
		rad_to_deg(_floor_normal.angle_to(Vector3.UP)), is_on_walkable_floor()]


func post_physics_step(_delta: float, _grapple_active: bool) -> void:
	## Save grounded velocity for launch detection.
	## Called after _server_process() in player._physics_process().
	if is_on_floor():
		_ground_velocity = player.velocity

	# --- Complete frame trace ---
	if not _trace_normal_ran:
		_frame_trace += "\n  Move: [slide/crouch/grapple — not normal movement]"
	_frame_trace += "\n  Final->Jolt: vel=(%.3f, %.3f, %.3f) pos_y=%.4f h_speed=%.2f" % [
		player.velocity.x, player.velocity.y, player.velocity.z,
		player.global_position.y,
		Vector2(player.velocity.x, player.velocity.z).length()]

	# --- Wall debug: dump full pipeline trace every frame when touching walls ---
	var _capture: bool = player.capture_movement
	if _capture and _obstacle_normals.size() > 0:
		print("[WALL TRACE] obs=%d" % _obstacle_normals.size())
		print(_frame_trace)

		# Wall-force budget: decompose each step's horizontal delta into
		# wall-perpendicular (w⊥, positive=away) and wall-parallel (w∥).
		var wn: Vector2 = _obstacle_normals[0]
		var wp: Vector2 = Vector2(-wn.y, wn.x)  # wall-parallel unit vector
		var d_solver := _dbg_h_jolt - _dbg_h_sent
		var d_undo := _dbg_h_after_undo - _dbg_h_jolt
		var d_pull := _dbg_h_after_pull - _dbg_h_after_undo
		var d_move := _dbg_h_after_move - _dbg_h_after_pull
		var d_press := _dbg_h_final - _dbg_h_after_move
		print("  [WALL BUDGET] wn=(%.3f,%.3f) wp=(%.3f,%.3f)" % [wn.x, wn.y, wp.x, wp.y])
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f  (h: %.3f -> %.3f)" % [
			"jolt_solver:", d_solver.dot(wn), d_solver.dot(wp),
			_dbg_h_sent.length(), _dbg_h_jolt.length()])
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f" % [
			"press_undo:", d_undo.dot(wn), d_undo.dot(wp)])
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f" % [
			"slope_pull:", d_pull.dot(wn), d_pull.dot(wp)])
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f" % [
			"move_toward:", d_move.dot(wn), d_move.dot(wp)])
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f" % [
			"press:", d_press.dot(wn), d_press.dot(wp)])
		var total_perp := _dbg_h_final.dot(wn)
		var total_para := _dbg_h_final.dot(wp)
		print("    %-12s w⊥=%+7.3f  w∥=%+7.3f  |h|=%.3f" % [
			"TOTAL:", total_perp, total_para, _dbg_h_final.length()])
		print("")

	# --- Transition detection ---
	if _was_grounded and not _is_grounded:
		# Ground→Air
		_trace_air_frames = 1
		var space := player.get_world_3d().direct_space_state
		var from := player.global_position + Vector3(0, 0.5, 0)
		var to := player.global_position - Vector3(0, 2.0, 0)
		var query := PhysicsRayQueryParameters3D.create(from, to, CollisionLayers.WORLD)
		query.exclude = [player.get_rid()]
		var ray_result := space.intersect_ray(query)
		var ray_sep := -1.0
		var ray_angle := -1.0
		if ray_result:
			ray_sep = player.global_position.y - ray_result.position.y
			ray_angle = rad_to_deg(ray_result.normal.angle_to(Vector3.UP))
		var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
		var diag_max_sep := _prev_solver_push + 0.01
		print("[G->A] vel=(%.2f,%.2f,%.2f) h=%.2f pos_y=%.4f ray_sep=%.4f ray_ang=%.1f° max_sep=%.4f contacts=%d best_n=(%.3f,%.3f,%.3f) best_ang=%.1f° last_floor_n=(%.3f,%.3f,%.3f)" % [
			player.velocity.x, player.velocity.y, player.velocity.z, h_speed,
			player.global_position.y, ray_sep, ray_angle, diag_max_sep,
			_dbg_last_contact_count,
			_best_contact_normal.x, _best_contact_normal.y, _best_contact_normal.z,
			rad_to_deg(_best_contact_normal.angle_to(Vector3.UP)) if _best_contact_normal != Vector3.ZERO else -1.0,
			_floor_normal.x, _floor_normal.y, _floor_normal.z])
		# Always dump full pipeline trace on G->A for flicker diagnosis
		print("=== GROUND -> AIR ===")
		if _prev_frame_trace != "":
			print("--- LAST GROUNDED FRAME ---")
			print(_prev_frame_trace)
		print("--- FIRST AIRBORNE FRAME ---")
		print(_frame_trace)
		if ray_result:
			print("  Raycast: separation=%.4fm floor_angle=%.1f°" % [ray_sep, ray_angle])
		else:
			print("  Raycast: MISS (no terrain within 2.5m)")
		print("=====================")
	elif not _was_grounded and _is_grounded:
		# Air→Ground
		var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
		print("[A->G] vel=(%.2f,%.2f,%.2f) h=%.2f pos_y=%.4f after=%d_frames best_n=(%.3f,%.3f,%.3f) best_ang=%.1f°" % [
			player.velocity.x, player.velocity.y, player.velocity.z, h_speed,
			player.global_position.y, _trace_air_frames,
			_best_contact_normal.x, _best_contact_normal.y, _best_contact_normal.z,
			rad_to_deg(_best_contact_normal.angle_to(Vector3.UP))])
		# Always dump full pipeline trace on A->G for flicker diagnosis
		print("=== AIR -> GROUND (after %d airborne frames) ===" % _trace_air_frames)
		if _prev_frame_trace != "":
			print("--- LAST AIRBORNE FRAME ---")
			print(_prev_frame_trace)
		print("--- FIRST GROUNDED FRAME ---")
		print(_frame_trace)
		print("=====================")
		_trace_air_frames = 0
	elif not _is_grounded:
		_trace_air_frames += 1
		# Print continued airborne frames (up to 5)
		if _trace_air_frames <= 5:
			var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
			print("  [AIR f=%d] vel=(%.2f,%.2f,%.2f) h=%.2f pos_y=%.4f" % [
				_trace_air_frames, player.velocity.x, player.velocity.y,
				player.velocity.z, h_speed, player.global_position.y])

	_prev_frame_trace = _frame_trace

	# Record what we're giving Jolt (for solver delta and landing correction next frame)
	_dbg_set_vel = player.velocity
	_last_sent_pos = player.global_position
	_dbg_set_pos_y = player.global_position.y


func begin_movement(_delta: float) -> void:
	## Pre-movement setup. Called at the start of movement in
	## player._server_process().
	if is_on_floor():
		_air_jumps_used = 0


func apply_gravity(delta: float) -> void:
	## Apply gravity every frame. Jolt's contact solver balances this at
	## the surface, preventing penetration while maintaining contacts.
	var pre_y := player.velocity.y
	player.velocity.y -= player.gravity * delta
	_frame_trace += "\n  Gravity: vel_y %.4f -> %.4f (%+.4f)" % [
		pre_y, player.velocity.y, -player.gravity * delta]


func process_normal_movement(delta: float) -> void:
	## Two-regime horizontal movement:
	##   Controlled  (≤ CONTROL_SPEED_THRESHOLD on walkable ground):
	##       Full steering, instant stop when input is released.
	##   Uncontrolled (> threshold on walkable ground):
	##       No steering — friction decelerates until control speed is reached.
	##   Air / non-walkable slopes use the original accel/decel model.
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
	var walkable := is_on_walkable_floor()
	var traction := _slope_traction if on_floor else 1.0

	# On landing, the solver deflects vertical impact into horizontal velocity
	# along the slope. Restore pre-solver horizontal velocity and undo the
	# solver's horizontal position push (only when no walls nearby).
	if not _was_grounded and on_floor:
		var pre_solver_h := Vector2(_dbg_set_vel.x, _dbg_set_vel.z)
		if pre_solver_h.length() <= CONTROL_SPEED_THRESHOLD:
			horizontal = pre_solver_h
			if _last_sent_pos != Vector3.ZERO and _obstacle_normals.is_empty():
				# Where we should be: old position + velocity * delta
				var expected_x := _last_sent_pos.x + _dbg_set_vel.x * delta
				var expected_z := _last_sent_pos.z + _dbg_set_vel.z * delta
				player.global_position.x = expected_x
				player.global_position.z = expected_z

	var h_speed := horizontal.length()
	_trace_normal_ran = true
	_frame_trace += "\n  Move start: vel=(%.3f, %.3f, %.3f) h_speed=%.2f on_floor=%s walkable=%s" % [
		player.velocity.x, player.velocity.y, player.velocity.z, h_speed, on_floor, walkable]

	var _wall_dbg := player.capture_movement and _obstacle_normals.size() > 0

	# --- Slope gravity (downhill pull along surface) ---
	# Skipped during controlled walk (input on walkable ground) — walk accel
	# handles direction, tangent snap handles surface following.  Slope pull
	# only applies to uncontrolled speed, no-input stops, and non-walkable slopes.
	var controlled_walk := walkable and direction and h_speed <= CONTROL_SPEED_THRESHOLD
	if on_floor and not controlled_walk:
		var slope_pull := Vector2(_floor_normal.x, _floor_normal.z) * player.gravity
		var gravity_scale := clampf(1.0 - horizontal.length() / SLOPE_SLIDE_MAX_SPEED, 0.0, 1.0)
		var h_before_pull := horizontal
		horizontal += slope_pull * gravity_scale * delta
		if _wall_dbg:
			_frame_trace += "\n  [SLOPE PULL] pull=(%.4f,%.4f) grav_scale=%.3f h_delta=(%.4f,%.4f)" % [
				slope_pull.x, slope_pull.y, gravity_scale,
				horizontal.x - h_before_pull.x, horizontal.y - h_before_pull.y]

	_dbg_h_after_pull = horizontal
	var h_after_slope := horizontal
	var _regime := ""

	# --- Movement regime ---
	if walkable and h_speed > CONTROL_SPEED_THRESHOLD:
		_regime = "UNCONTROLLED"
		# UNCONTROLLED — above threshold on walkable ground.
		# Player can steer (rotate velocity direction) but not accelerate.
		if direction and horizontal.length() > 1.0:
			var input2 := Vector2(direction.x, direction.z).normalized()
			var skid_dir := horizontal.normalized()
			var turn_rate := SKID_STEER_STRENGTH * delta
			horizontal = horizontal.length() * skid_dir.lerp(input2, turn_rate).normalized()
		# Friction decelerates toward zero.
		horizontal = horizontal.move_toward(Vector2.ZERO, SKID_FRICTION * delta)
	elif direction:
		# CONTROLLED WITH INPUT — accelerate toward target velocity.
		# Jolt's contact solver handles wall interactions: we just push toward
		# the desired velocity and the solver's contact response naturally
		# produces wall-sliding without any manual projection.
		var target := Vector2(direction.x, direction.z) * current_speed

		if walkable:
			_regime = "WALK"
			horizontal = horizontal.move_toward(target, WALK_ACCEL * delta)
			if _wall_dbg:
				_frame_trace += "\n  [MOVE] regime=WALK target=(%.3f,%.3f) mag=%.2f accel=%.2f*%.4f=%.4f" % [
					target.x, target.y, target.length(), WALK_ACCEL, delta, WALK_ACCEL * delta]
				_frame_trace += "\n    input_dir=(%.3f,%.3f) direction=(%.3f,%.3f,%.3f)" % [
					input_dir.x, input_dir.y, direction.x, direction.y, direction.z]
				_frame_trace += "\n    h_before=(%.4f,%.4f) h_after=(%.4f,%.4f) h_delta=(%.4f,%.4f)" % [
					h_after_slope.x, h_after_slope.y, horizontal.x, horizontal.y,
					horizontal.x - h_after_slope.x, horizontal.y - h_after_slope.y]
		elif on_floor:
			_regime = "FLOOR_ACCEL"
			horizontal = horizontal.move_toward(target, ACCELERATION * traction * delta)
		else:
			_regime = "AIR_ACCEL"
			var current_mag := horizontal.length()
			var input_dot := horizontal.normalized().dot(target.normalized()) if current_mag > 0.1 else 1.0
			horizontal = horizontal.move_toward(target, AIR_ACCELERATION * delta)
			if horizontal.length() < current_mag and input_dot > 0.0:
				horizontal = horizontal.normalized() * current_mag
	elif walkable:
		_regime = "WALK_STOP"
		# CONTROLLED WITHOUT INPUT — instant stop below threshold, friction above.
		if h_speed > INSTANT_STOP_THRESHOLD:
			horizontal = horizontal.move_toward(Vector2.ZERO, SKID_FRICTION * delta)
		else:
			horizontal = Vector2.ZERO
	else:
		_regime = "AIR_DECEL"
		# AIR / NON-WALKABLE — original deceleration model.
		var decel := (DECELERATION if on_floor else AIR_DECELERATION) * traction
		horizontal = horizontal.move_toward(Vector2.ZERO, decel * delta)

	if _wall_dbg and _regime != "WALK":
		_frame_trace += "\n  [MOVE] regime=%s h_before=(%.4f,%.4f) h_after=(%.4f,%.4f)" % [
			_regime, h_after_slope.x, h_after_slope.y, horizontal.x, horizontal.y]

	_dbg_h_after_move = horizontal
	player.velocity.x = horizontal.x
	player.velocity.z = horizontal.y

	# Velocity dead zone — stopped on walkable ground with no input.
	# Zero everything; gravity + solver maintain contact naturally.
	if walkable and not direction and horizontal.length_squared() < 0.01:
		# On landing, snap XZ back to pre-impact position. Jolt's solver
		# deflects vertical impacts along slopes, shifting the capsule
		# horizontally. Correcting here (at full stop) avoids the stutter
		# that pre_physics_step correction caused with uphill tangent Y.
		if not _was_grounded and _last_sent_pos != Vector3.ZERO:
			player.global_position.x = _last_sent_pos.x
			player.global_position.z = _last_sent_pos.z
		player.velocity = Vector3.ZERO
		_last_press_vel = Vector3.ZERO
		_dbg_h_final = Vector2.ZERO
		_frame_trace += "\n  Move end: vel=(%.3f, %.3f, %.3f) [dead zone]" % [
			player.velocity.x, player.velocity.y, player.velocity.z]
		return

	# Surface following — only modifies vel_y, horizontal is untouched.
	if is_on_floor() and not player._frame_jump:
		var n := _floor_normal
		if is_on_walkable_floor():
			# Forward surface prediction: cast a ray one frame ahead in the
			# travel direction to detect upcoming slope changes. When the
			# ahead surface is steeper (flat → ramp), use its normal for
			# tangent snap so vel_y aligns with the ramp BEFORE contact.
			# This prevents the solver from absorbing the into-surface
			# velocity component at the transition (which costs horizontal
			# speed on sloped surfaces).
			var h_vel := Vector3(player.velocity.x, 0, player.velocity.z)
			var h_spd_sq := h_vel.length_squared()
			if h_spd_sq > 100.0:
				var h_spd := sqrt(h_spd_sq)
				var h_dir := h_vel / h_spd
				var look_dist := h_spd * delta
				var space := player.get_world_3d().direct_space_state
				var ray_from := player.global_position + h_dir * look_dist + Vector3(0, 1.5, 0)
				var ray_to := ray_from - Vector3(0, 2.5, 0)
				var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to, CollisionLayers.WORLD)
				query.exclude = [player.get_rid()]
				var result := space.intersect_ray(query)
				if result and result.normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
					if result.normal.y < n.y:
						_frame_trace += "\n  [AHEAD SNAP] cur_n=(%.3f,%.3f,%.3f) ahead_n=(%.3f,%.3f,%.3f)" % [
							n.x, n.y, n.z, result.normal.x, result.normal.y, result.normal.z]
						n = result.normal
			# Tangent snap with gravity-normal contact bias.
			# slope_y = exact surface tangent (vel · n = 0).
			# Subtracting gravity's normal component leaves a small into-surface
			# velocity — the same force that keeps you on the ground in real
			# physics.  Only vel_y changes; horizontal is completely clean.
			var slope_y := -(n.x * player.velocity.x + n.z * player.velocity.z) / n.y
			var gravity_normal := player.gravity * delta * n.y
			var target_y := slope_y - gravity_normal
			player.velocity.y = target_y
		else:
			# Steep slope: strip velocity going INTO the surface.
			var perp := player.velocity.dot(n)
			if perp < 0.0:
				player.velocity -= n * perp
	_last_press_vel = Vector3.ZERO
	_dbg_h_final = Vector2(player.velocity.x, player.velocity.z)
	_frame_trace += "\n  Move end: vel=(%.3f, %.3f, %.3f) press=%s" % [
		player.velocity.x, player.velocity.y, player.velocity.z,
		_last_press_vel != Vector3.ZERO]


func apply_slope_projection(delta: float, force_tangent: bool = false) -> void:
	## Keep the capsule in actual contact with the surface by:
	## 1. Setting vel.y to the surface tangent (prevents solver bounce AND
	##    prevents gravity accumulation that causes hill sliding).
	## 2. Pushing a fixed depth into the surface each frame so Jolt's solver
	##    always has penetration to resolve (creating real contacts).
	## The press is tracked so it can be undone if the capsule launches
	## (see pre_physics_step) — launch velocity stays clean.
	## force_tangent: always use the tangent + press path (used by slides to
	## ride steep surfaces smoothly instead of fighting the solver).
	var _wall_dbg2 := player.capture_movement and _obstacle_normals.size() > 0
	if not is_on_floor() or player._frame_jump:
		_last_press_vel = Vector3.ZERO
		_dbg_h_final = Vector2(player.velocity.x, player.velocity.z)
		if _wall_dbg2:
			_frame_trace += "\n  [SLOPE PROJ] skipped (on_floor=%s frame_jump=%s)" % [
				is_on_floor(), player._frame_jump]
		return
	var n := _floor_normal
	if is_on_walkable_floor() or force_tangent:
		var vel_before_proj := player.velocity
		# Tangent y-velocity: prevents gravity accumulation (sliding).
		# When downhill (slope_y < 0), always follow the surface.
		# When uphill (slope_y >= 0), only snap upward — preserve excess
		# upward momentum so ramp-to-flat transitions feel natural.
		var slope_y := -(n.x * player.velocity.x + n.z * player.velocity.z) / n.y
		var old_vel_y := player.velocity.y
		var did_snap := slope_y < 0.0 or player.velocity.y <= slope_y
		if did_snap:
			player.velocity.y = slope_y
		# Fixed-depth press into surface along -normal. Press and solver
		# response are exactly opposed along the normal, so they cancel
		# cleanly with zero net horizontal effect on smooth surfaces.
		# When touching a wall, skip: Jolt maintains floor contact via
		# the wall+floor constraint network.
		if _obstacle_normals.size() == 0 and not GameManager.debug_disable_surface_press:
			var press_speed := SURFACE_PRESS_DEPTH / delta
			_last_press_vel = press_speed * n
			player.velocity -= _last_press_vel
		else:
			_last_press_vel = Vector3.ZERO
		_dbg_h_final = Vector2(player.velocity.x, player.velocity.z)
		if _wall_dbg2:
			_frame_trace += "\n  [SLOPE PROJ] walkable n=(%.4f,%.4f,%.4f) angle=%.1f°" % [
				n.x, n.y, n.z, rad_to_deg(n.angle_to(Vector3.UP))]
			_frame_trace += "\n    slope_y=%.4f old_vel_y=%.4f snapped=%s" % [
				slope_y, old_vel_y, did_snap]
			_frame_trace += "\n    vel_after_tangent=(%.4f, %.4f, %.4f)" % [
				vel_before_proj.x, player.velocity.y + _last_press_vel.y, vel_before_proj.z]
			_frame_trace += "\n    press_vel=(%.4f, %.4f, %.4f) walls=%d" % [
				_last_press_vel.x, _last_press_vel.y, _last_press_vel.z,
				_obstacle_normals.size()]
			_frame_trace += "\n    vel_final=(%.4f, %.4f, %.4f)" % [
				player.velocity.x, player.velocity.y, player.velocity.z]
			_frame_trace += "\n    vel_change=(%.4f, %.4f, %.4f)" % [
				player.velocity.x - vel_before_proj.x,
				player.velocity.y - vel_before_proj.y,
				player.velocity.z - vel_before_proj.z]
	else:
		# Steep slope: only strip velocity going INTO the surface.
		# Preserve the away-from-surface component so the player can
		# crest ramp lips without being pulled back.
		var perp := player.velocity.dot(n)
		if perp < 0.0:
			player.velocity -= n * perp
		_last_press_vel = Vector3.ZERO
		_dbg_h_final = Vector2(player.velocity.x, player.velocity.z)
		if _wall_dbg2:
			_frame_trace += "\n  [SLOPE PROJ] steep n=(%.4f,%.4f,%.4f) perp=%.4f" % [
				n.x, n.y, n.z, perp]


func slope_compensated_jump_y() -> float:
	## Returns a fixed JUMP_VELOCITY regardless of slope.
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


func _update_ground_state(delta: float) -> void:
	## Contact-based floor detection with raycast persistence.
	## Grounded when Jolt contacts include a walkable surface, OR when we were
	## grounded last frame and a raycast confirms the surface is still within
	## one frame's travel distance (velocity * delta). The raycast bridges
	## brief contact gaps at block edges without modifying velocity at all.
	_was_grounded = _is_grounded

	# Post-jump rising: once the player is falling, the flag has served its
	# purpose (preventing re-ground on the launch surface while still rising).
	# Clear it so contacts can ground the player normally.  Without this, a
	# player who jumps into a ramp edge and never loses contacts gets stuck
	# airborne forever (_left_ground_since_jump is never set).
	if _post_jump_rising and player.velocity.y <= 0.0:
		_post_jump_rising = false
		_left_ground_since_jump = false

	var has_floor_contact := _best_contact_normal != Vector3.ZERO \
			and _best_contact_normal.angle_to(Vector3.UP) <= SLOPE_MAX_GROUND_ANGLE

	# --- Grounded: update floor normal from contacts ---
	if has_floor_contact:
		_floor_normal = _best_contact_normal
		_slope_traction = _best_contact_normal.y
		_floor_y = player.global_position.y
		_is_grounded = true

		# Post-jump rising suppression
		if _post_jump_rising:
			if _left_ground_since_jump:
				_post_jump_rising = false
				_left_ground_since_jump = false
			else:
				_is_grounded = false
		return

	# --- No contacts: raycast persistence ---
	# Bridges single-frame contact gaps from solver depenetration overshoot.
	# max_sep = previous frame's solver push (the physical cause of the gap)
	# plus a small float-precision margin.
	if _was_grounded and not _post_jump_rising:
		var departing := player.velocity.dot(_floor_normal) > 0.0
		if not departing:
			var max_sep := _prev_solver_push + 0.01
			var space := player.get_world_3d().direct_space_state
			var from := player.global_position + Vector3(0, 0.5, 0)
			var to := from + Vector3(0, -(0.5 + max_sep), 0)
			var query := PhysicsRayQueryParameters3D.create(from, to, CollisionLayers.WORLD)
			query.exclude = [player.get_rid()]
			var result := space.intersect_ray(query)
			if result and result.normal.angle_to(Vector3.UP) <= SLOPE_MAX_GROUND_ANGLE:
				var sep: float = player.global_position.y - result.position.y
				if sep <= max_sep:
					_floor_normal = result.normal
					_slope_traction = result.normal.y
					_floor_y = result.position.y
					_is_grounded = true
					_frame_trace += "\n  [RAY PERSIST] sep=%.4f max=%.4f n=(%.3f,%.3f,%.3f)" % [
						sep, max_sep, result.normal.x, result.normal.y, result.normal.z]
					return
				else:
					_frame_trace += "\n  [RAY REJECT sep] sep=%.4f > max=%.4f" % [sep, max_sep]
			elif result:
				_frame_trace += "\n  [RAY REJECT angle] ang=%.1f° n=(%.3f,%.3f,%.3f)" % [
					rad_to_deg(result.normal.angle_to(Vector3.UP)), result.normal.x, result.normal.y, result.normal.z]
			else:
				_frame_trace += "\n  [RAY MISS] from_y=%.4f to_y=%.4f max_sep=%.4f" % [from.y, to.y, max_sep]
		else:
			_frame_trace += "\n  [RAY SKIP departing] dot=%.4f floor_n=(%.3f,%.3f,%.3f)" % [
				player.velocity.dot(_floor_normal), _floor_normal.x, _floor_normal.y, _floor_normal.z]

	# --- Airborne ---
	if _post_jump_rising:
		_left_ground_since_jump = true
	_is_grounded = false
	_floor_normal = Vector3.UP
	_floor_y = -INF
	_slope_traction = 0.0


# ======================================================================
#  Force airborne
# ======================================================================

func force_airborne() -> void:
	## Force player to airborne state (used by slide-jump, grapple release, etc.)
	_is_grounded = false
	_post_jump_rising = true


# ======================================================================
#  Reset
# ======================================================================


func reset_movement() -> void:
	## Reset movement state on respawn.
	_air_jumps_used = 0
	_obstacle_normals = []
	_ground_velocity = Vector3.ZERO
	_post_jump_rising = false
	_left_ground_since_jump = false
	_is_grounded = false
	_floor_normal = Vector3.UP
	_floor_y = -INF
	_slope_traction = 1.0
	_last_press_vel = Vector3.ZERO
	_last_sent_pos = Vector3.ZERO
