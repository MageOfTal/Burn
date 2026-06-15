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
const AIR_ACCELERATION := 15.0

const FLOOR_MAX_ANGLE: float = 0.8727  ## 50° — walkable
const JUMP_MAX_ANGLE: float = 1.4835   ## 85° — jumpable

## Stair/curb auto-step-up height (m). The CharacterVirtual's WalkStairs casts
## up by this much, forward, then down — so a block step at or below this is
## walked over, anything taller is a wall. (Capsule radius is ~0.4.)
const STEP_UP_HEIGHT: float = 0.45
## Extra downward StickToFloor distance beyond STEP_UP_HEIGHT (m) — keeps the
## capsule glued when cresting a downhill ridge faster than it can follow.
const STEP_DOWN_EXTRA: float = 0.0

## Epsilon for central-difference terrain normal calculation (meters).
const SDF_NORMAL_EPS: float = 0.5

const SKID_STEER_STRENGTH: float = 3.0


# ──────────────────────────────────────────────────────────────────────
# Surface friction system
#
# A surface's friction (m/s² of deceleration when sliding on it) is the
# single property that drives all of the ground-locomotion knobs: walk
# acceleration, skid threshold, dime-stop speed, and skid deceleration.
# Each scales linearly with friction, matching the physics relationship
# (max acceleration ∝ μ·g; control window scales with available decel).
#
# A body's friction is read via metadata "surface_friction" on the contact
# collider, defaulting to DEFAULT_FRICTION when unset. Existing terrain,
# walls, and debris use the default. Slippery surfaces (ice, oil, polished
# metal) set a lower value; sticky surfaces (rubber, velcro) a higher one.
# ──────────────────────────────────────────────────────────────────────

const DEFAULT_FRICTION: float = 20.0       ## Baseline deceleration on typical ground (m/s²).
const ACCEL_FRICTION_RATIO: float = 2.25   ## walk_accel = friction × this (default: 45.0)
const SKID_THRESHOLD_RATIO: float = 2.75   ## skid_threshold = friction × this (default: 55.0)
const DIME_STOP_RATIO: float = 0.3         ## dime_stop_speed = friction × this (default: 6.0)

## Default-derived constants kept for external reference (slide_crouch_system,
## game_manager, etc). Internal ground-movement code computes per-frame from
## the actual contact friction and ignores these.
const WALK_ACCEL: float = DEFAULT_FRICTION * ACCEL_FRICTION_RATIO    ## 45.0
const SKID_THRESHOLD: float = DEFAULT_FRICTION * SKID_THRESHOLD_RATIO ## 55.0
const SKID_FRICTION: float = DEFAULT_FRICTION                         ## 20.0
const DIME_STOP_SPEED: float = DEFAULT_FRICTION * DIME_STOP_RATIO     ## 6.0


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

# Sweep-based wall-contact oracle (JoltCharacterVirtual3D). CharacterVirtual's
# contact set is derived from a shape sweep, so it sees both faces of a corner
# in a single cast and reports the TRUE per-triangle face normal (not the
# averaged GJK penetration axis the RigidBody manifold gives). The wall-proj
# input-scaling reads this stable set instead of `_contacts`, so the walk-accel
# target doesn't flicker as the player slides into a seam. Refreshed once per
# pre_physics_step at the player's physics position.
var _wall_oracle: JoltCharacterVirtual3D = null
var _oracle_contacts: Array = []       ## raw get_contacts() — includes the sweep's lookahead hits
var _oracle_touch: Array = []          ## subset the capsule is actually touching (Contact.mDistance <= eps)
## Distance cutoff for "actually touching". A wall the capsule is resting against
## reports mDistance jiggling around 0 (±~1 mm) frame to frame; a hard 0 cutoff
## then flips it in and out of _oracle_touch, which flickers wall_planes, which
## flickers _project_off_walls — the inside-corner wiggle. A small positive eps
## (well under predictive_contact_distance, so it still won't pick up genuine
## look-ahead-only hits a few cm away) keeps a resting contact stably "touching".
const _ORACLE_TOUCH_EPS := 0.02
var _oracle_shape_offset := Vector3.ZERO  ## CollisionShape3D local offset (the player body origin is at the feet, capsule is offset up)
var _oracle_capsule_radius := 0.4      ## cached from the player's CollisionShape3D in setup()
var _oracle_capsule_height := 1.8
var _oracle_wall_min_y := -1e9         ## contact-point Y below this is on the capsule's rounded bottom (a step it rolls over, not a wall); refreshed each pre_physics_step
var _cv_dbg_frames := 0                 ## TEMP: counts apply_cv_move calls for peer 1 so we can dump the first ~240 frames after spawn

## Leg odometer (active during the F8/F9 combined capture): one [LEG] line per
## movement leg — frames held, displacement, heading — so input asymmetry
## (hold-time / heading differences between directions) is directly visible in
## the log and can't be confused with engine drift.
var _leg_dir := Vector3.ZERO
var _leg_start_pos := Vector3.ZERO
var _leg_frames := 0

## External horizontal momentum (explosion knockback, body shoves). Tracked
## separately from walk velocity so the grounded instant-grip clamp only
## applies to the player's own input contribution: knockback is frictioned
## away independently (floor friction per grounded frame, none airborne) and
## killed against walls. Add through add_knockback(); never write directly.
var knockback_hvel := Vector3.ZERO


## Apply external knockback to the player. The vertical component goes through
## the normal vy path (it naturally makes the player airborne if strong);
## the horizontal component enters the independent knockback channel.
func add_knockback(vel_delta: Vector3) -> void:
	player.velocity.y += vel_delta.y
	knockback_hvel += Vector3(vel_delta.x, 0.0, vel_delta.z)

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
var _dbg_prev_floor_normal: Vector3 = Vector3.UP       # previous frame's floor normal (for angle-change tracking)
var _dbg_prev_post_pos: Vector3 = Vector3.ZERO         # previous frame's post-physics position (compare to predicted_pos_y)
var _dbg_prev_floor_source_body: String = "none"       # previous frame's body whose normal was selected as _floor_normal

# F8 wedge-stutter: tracked across frames to detect contacts that disappeared
# between frames so we can shape-test the lost body and check whether the
# capsule still overlaps it (reveals Jolt-side reporting bugs vs real drift).
var _ws_prev_nonwalk_bodies: Array = []

# F8 wedge-stutter: previous-frame wall-proj outputs, for Δ tracking. Tells us
# whether wall-proj's *output* is flickering between frames (the actual signal
# the user perceives — wall_speed_fraction toggling makes max_speed and the
# walk-accel target oscillate, which drives hvel/vel.y/pos oscillation).
var _ws_prev_wall_speed_fraction: float = 1.0
var _ws_prev_wall_proj_dir: Vector3 = Vector3.ZERO
var _ws_prev_wall_planes: Array = []   # array of {body_name, normal}


# F8 flicker tracker — compact transition log
var _flicker_prev_grounded: bool = false
var _flicker_prev_normal: Vector3 = Vector3.UP
var _flicker_air_streak: int = 0     # How many frames in current state
var _flicker_gnd_streak: int = 0



func setup(p: Player) -> void:
	super.setup(p)
	_create_wall_oracle()


func _create_wall_oracle() -> void:
	# The JoltCharacterVirtual3D that DRIVES the player's walking movement:
	# pre_physics_step refreshes its contacts at the player's position; the
	# movement branch sets player.velocity; apply_cv_move() then hands that
	# velocity to extended_update() (swept collide-and-slide + StickToFloor +
	# WalkStairs) and copies the resolved position/velocity back onto the
	# (frozen-kinematic) player body. The body stays a physics presence (other
	# bodies bump it, raycasts hit it) but is never solved against, so the CV
	# is the single collision authority.
	if not ClassDB.class_exists("JoltCharacterVirtual3D"):
		push_warning("JoltCharacterVirtual3D not available (non-Jolt build?); player movement will not work.")
		return
	_wall_oracle = JoltCharacterVirtual3D.new()
	_wall_oracle.name = "WallContactOracle"
	var col := player.get_node_or_null("CollisionShape3D")
	if col != null:
		_oracle_shape_offset = col.position
		if col.shape is CapsuleShape3D:
			var cap: CapsuleShape3D = col.shape
			_oracle_capsule_radius = cap.radius
			_oracle_capsule_height = cap.height
	_wall_oracle.capsule_radius = _oracle_capsule_radius
	_wall_oracle.capsule_height = _oracle_capsule_height
	# The CV is a phantom — inner_body = false, so it never creates a physics
	# body of its own. Its collision_layer would only matter for the "does
	# anything mask against me" half of the layer-pair test; we don't need that
	# (the frozen-kinematic player RigidBody3D is the physics presence), and
	# leaving it on PLAYER_LAYER would make the player's own body — which sits
	# 1:1 inside the CV capsule — get reported as a wall to slide against. So:
	# no layer. The mask is the player's normal physical mask MINUS the player
	# layers (PLAYERS_HIT / PLAYERS_PUSH) so the CV ignores its own body (and,
	# for now, other players — see note in player_movement re: re-adding p-v-p).
	_wall_oracle.collision_layer = 0
	_wall_oracle.collision_mask = CollisionLayers.PLAYER_MASK & ~(CollisionLayers.PLAYERS_HIT | CollisionLayers.PLAYERS_PUSH)
	_wall_oracle.up_direction = Vector3.UP
	# The frozen-kinematic player RigidBody is already the physics presence
	# (others collide with it, raycasts hit it) — so no inner body needed.
	_wall_oracle.inner_body = false
	# Anything steeper than this is "steep ground" → the CV won't support the
	# player there, so they slide down it (matches FLOOR_MAX_ANGLE = walkable).
	_wall_oracle.max_slope_angle_deg = rad_to_deg(FLOOR_MAX_ANGLE)
	# Predictive scan distance: how far ahead/below the CV looks for contacts.
	# Kept small: a generous value makes the collide-and-slide "see" walls/steps
	# from further away, so at running speed the player can get clipped by a
	# surface that's still several cm ahead — feels like an invisible wall. The
	# grounding flicker the bigger value was meant to soothe is handled instead
	# by the contact-scan + down-cast snap in pre_physics_step.
	# Predictive scan distance (m): how far outside the capsule the CV searches for
	# contacts each tick. This must cover the player's per-frame displacement so the
	# constraint solver sees every body it might pass through during one Update
	# (otherwise the body wouldn't enter the contact set and the player would punch
	# straight through). With SPEED 9 m/s + slide/bonus headroom up to ~12 m/s and
	# dt 1/60, max displacement per frame is ~0.2 m; 0.2 covers it comfortably.
	# Predictive contacts whose mTOI exceeds the remaining frame time are ignored
	# by SolveConstraints (line 832) so this doesn't cause "ghost collisions" — a
	# wall 18 cm away you're not approaching has no effect on your velocity.
	_wall_oracle.predictive_contact_distance = 0.2
	# Max push force (N) the character can impart to dynamic bodies per contact.
	# Jolt clamps the per-frame impulse to max_strength * dt, so this directly
	# caps how fast the character can accelerate a body it's pushing:
	#   Δv_per_frame = (max_strength * dt) / body_mass
	# Default 100 N means a 4 kg toad only gains 0.42 m/s per frame, so for the
	# first ~350 ms of contact the toad's velocity paces the player — feels like
	# pushing a brick wall. 1000 N is "strong character" — a 4 kg toad reaches
	# walk speed in ~3 frames (essentially instant), while a 100 kg crate still
	# accelerates slowly, so heavier-is-harder remains a natural gradient.
	_wall_oracle.max_strength = 1000.0
	# Route the CV's collision detection through Jolt's internal-edge removal:
	# contacts at mesh triangle seams / voxel block boundaries whose normal
	# disagrees with the real face get voided, instead of entering the solver
	# as phantom constraint planes. Those phantom planes were one of the two
	# ingredients of the random "invisible wall" stalls (the other was the
	# listener re-amplifying on every solver iteration — fixed C++-side).
	# Rigid bodies already run with the equivalent setting on by default.
	_wall_oracle.enhanced_internal_edge_removal = true
	player.add_child(_wall_oracle)


## Resize the CharacterVirtual capsule (and update the cached shape offset) to
## match the player's CollisionShape3D after a slide/crouch pose change. Called
## by SlideCrouchSystem.apply_lowered_pose / apply_standing_pose.
func set_capsule_height(new_height: float) -> void:
	_oracle_capsule_height = new_height
	# The CollisionShape3D sits with its origin at the capsule centre, i.e. at
	# (0, new_height/2, 0) relative to the feet — mirror that for the CV node.
	_oracle_shape_offset = Vector3(_oracle_shape_offset.x, new_height * 0.5, _oracle_shape_offset.z)
	if _wall_oracle != null and _wall_oracle.has_method("set_capsule_height"):
		_wall_oracle.set_capsule_height(new_height)


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

	# Diagnostic: aggregate Jolt depen impulse per contact category
	# (walkable floor vs non-walkable wall). Reveals when an angled wall
	# is contributing an upward Y impulse against gravity — the "depen-up
	# vs gravity-down" oscillation hypothesis for the slightly-angled-wall
	# flicker.
	if GameManager.debug_wedge_stutter:
		var wall_imp_total: Vector3 = Vector3.ZERO
		var floor_imp_total: Vector3 = Vector3.ZERO
		var contact_imp_summary: Array = []
		for i in state.get_contact_count():
			var ci_n: Vector3 = state.get_contact_local_normal(i)
			var ci_imp: Vector3 = state.get_contact_impulse(i)
			var ci_walkable: bool = ci_n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE
			var ci_collider: Object = state.get_contact_collider_object(i)
			var ci_name: String = ((ci_collider as Node).name) if ci_collider is Node else "?"
			if ci_walkable:
				floor_imp_total += ci_imp
			else:
				wall_imp_total += ci_imp
			contact_imp_summary.append({
				"name": ci_name,
				"normal": ci_n,
				"walkable": ci_walkable,
				"impulse": ci_imp,
			})
		_dbg_cur["ws_jolt_wall_imp_total"] = wall_imp_total
		_dbg_cur["ws_jolt_floor_imp_total"] = floor_imp_total
		_dbg_cur["ws_jolt_contact_impulses"] = contact_imp_summary

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

	# Start this frame's debug-trace dict here (on_integrate_forces — the old
	# place — no longer runs now that the player body is frozen-kinematic).
	_dbg_cur = {}
	_dbg_cur["frame"] = _dbg_frame_num
	_dbg_cur["int_pos"] = player.global_position
	_dbg_cur["int_vel"] = player.velocity
	_snap_vel_y = 0.0
	_jolt_solved_hvel = Vector3.ZERO

	# Refresh the sweep-based wall-contact oracle at the player's current
	# physics position. Runs here (from _physics_process, between physics
	# steps) where the Jolt worker is idle, so the synchronous narrowphase
	# query inside refresh_contacts() is safe. _oracle_contacts then carries
	# stable, true-face-normal contacts used below to (a) correct _floor_normal
	# (Jolt averages it wrong at terrain triangle boundaries) and (b) drive the
	# wall-proj input-scaling without flicker.
	_oracle_contacts = []
	_oracle_touch = []
	# Contact-point Y below this is on the capsule's rounded bottom — a step/bump
	# the capsule rolls over (RigidBody handles that), not a wall. The wall-proj
	# clips below ignore those so a small terrain riser doesn't read as a wall
	# and redirect the player. (Centered-capsule convention: feet at origin.y - h/2.)
	if _wall_oracle != null and _wall_oracle.is_inside_tree() and _wall_oracle.has_method("refresh_contacts"):
		var oracle_pos: Vector3 = player.to_global(_oracle_shape_offset)
		_wall_oracle.global_position = oracle_pos
		# capsule center at oracle_pos.y; feet at center - h/2; rounded bottom ends at feet + radius
		_oracle_wall_min_y = oracle_pos.y - _oracle_capsule_height * 0.5 + _oracle_capsule_radius
		_wall_oracle.refresh_contacts()
		_oracle_contacts = _wall_oracle.get_contacts()
		for c in _oracle_contacts:
			if bool(c.get("is_sensor", false)):
				continue   # sensor/Area (pickups, trigger zones) — non-solid; never a wall
			if c.get("collider") == player:
				continue   # the CharacterVirtual sweep also hits the player's own RigidBody (shares the PLAYERS_* layers) — ignore self
			if float(c.get("distance", 1.0)) <= _ORACLE_TOUCH_EPS:
				_oracle_touch.append(c)

	# Oracle contact dump for the wedge-stutter trace — so we can see exactly
	# what the JoltCharacterVirtual3D sweep reports (true face normal, contact
	# point, distance), which of those pass the touch/curb filters, and what
	# the wall-proj therefore clips against.
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_oracle_min_y"] = _oracle_wall_min_y
		var _od: Array = []
		for c in _oracle_contacts:
			var _col = c.get("collider")
			_od.append({
				"pos": c.get("position", Vector3.ZERO),
				"sn": c.get("surface_normal", Vector3.ZERO),
				"cn": c.get("contact_normal", Vector3.ZERO),
				"dist": float(c.get("distance", 999.0)),
				"name": ((_col as Node).name if _col is Node else "?"),
				"is_rb": _col is RigidBody3D,
				"is_sensor": bool(c.get("is_sensor", false)),
			})
		_dbg_cur["ws_oracle"] = _od

	# ── Mirror the CharacterVirtual's contact set into the old _contacts dict
	# shape ─────────────────────────────────────────────────────────────────
	# (on_integrate_forces no longer runs — the kinematic player body has no
	# rigid-body manifold. RefreshContacts above gave us the swept, true-face-
	# normal set; the few remaining consumers — the dime-stop, the debug dumps
	# — still read `_contacts`, so keep it populated.)
	_contacts.clear()
	for c in _oracle_contacts:
		if bool(c.get("is_sensor", false)):
			continue
		if c.get("collider") == player:
			continue
		var cn: Vector3 = c.get("surface_normal", Vector3.ZERO)
		if cn == Vector3.ZERO:
			continue
		var c_ang := cn.angle_to(Vector3.UP)
		var c_body = c.get("collider")
		var c_bname := "?"
		var c_bclass := "?"
		if c_body is Node:
			c_bname = (c_body as Node).name
			c_bclass = (c_body as Object).get_class()
		_contacts.append({
			"normal": cn,
			"body": c_body,
			"world_pos": c.get("position", Vector3.ZERO),
			"is_walkable": c_ang <= FLOOR_MAX_ANGLE,
			"is_jumpable": c_ang <= JUMP_MAX_ANGLE,
			"is_dynamic": c_body is RigidBody3D,
			"body_class": c_bclass,
			"body_name": c_bname,
		})
	_contact_count = _contacts.size()
	_dbg_contact_body_class = _contacts[0]["body_class"] if _contacts.size() > 0 else ""

	# ── Grounding from the CharacterVirtual's ground state ──────────────────
	# 0 = OnGround (supported on a walkable surface) → grounded.
	# 1 = OnSteepGround → touching a too-steep surface, not supported → treat
	#     as airborne so the player slides down it (the CV won't support them
	#     there either; the air path applies gravity, the CV's slide keeps it
	#     tangent to the steep face).
	# 2 = NotSupported / 3 = InAir → airborne.
	var _gs := 3
	var _gn := Vector3.UP
	if _wall_oracle != null and _wall_oracle.has_method("get_ground_state"):
		_gs = int(_wall_oracle.get_ground_state())
		_gn = _wall_oracle.get_ground_normal()

	# ── Stay-grounded (only if we were grounded last frame) ─────────────────
	# The CV reports a single "best supporting contact"; at a corner where a
	# steep wall meets a walkable slope it can blink between them, flickering gs
	# (and the ground normal) every frame — the corner wiggle. So if the CV says
	# "not supported" but we WERE grounded and the contact set still has a
	# touching walkable face below the capsule centre, stay grounded on it (no
	# extra query). Only if there's no such contact do we fall back to a downward
	# shape-cast snap (StayOnGround) to re-find walkable ground just below. Both
	# fire ONLY when we were grounded last frame and aren't mid-jump — and both
	# only ever ground us on a walkable face, so neither can catch a wall and
	# ride us up (and gravity runs every frame on the airborne branch anyway).
	_dbg_cur["pre_snapped_down"] = 0.0
	_dbg_cur["pre_grounded_via"] = "cv"
	if _gs != 0 and _was_grounded and not _post_jump_rising and _wall_oracle != null and _wall_oracle.is_inside_tree():
		var scan_n := Vector3.ZERO
		for c in _oracle_contacts:
			if bool(c.get("is_sensor", false)) or c.get("collider") == player:
				continue
			if float(c.get("distance", 1.0)) > 0.06:
				continue   # not actually touching
			var cn: Vector3 = c.get("surface_normal", Vector3.ZERO)
			if cn == Vector3.ZERO or cn.y <= 0.0 or cn.angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
				continue   # zero / sideways / too-steep — not a floor
			if float(c.get("position", Vector3.ZERO).y) >= _wall_oracle.global_position.y:
				continue   # contact is on the upper body — a wall hit, not the floor
			if cn.y > scan_n.y:
				scan_n = cn
		if scan_n != Vector3.ZERO:
			_gs = 0
			_gn = scan_n
			_dbg_cur["pre_grounded_via"] = "contact_scan"
		elif _wall_oracle.has_method("cast_shape"):
			var from_xform := Transform3D(Basis(), _wall_oracle.global_position)
			var hit: Dictionary = _wall_oracle.cast_shape(from_xform, Vector3.DOWN * STEP_UP_HEIGHT, _wall_oracle.collision_mask)
			if not hit.is_empty():
				var sn: Vector3 = hit.get("surface_normal", Vector3.ZERO)
				if sn != Vector3.ZERO and sn.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
					var snap_down: float = float(hit.get("fraction", 1.0)) * STEP_UP_HEIGHT
					if snap_down > 0.001:
						player.global_position.y -= snap_down
						_wall_oracle.global_position = player.to_global(_oracle_shape_offset)
						_wall_oracle.refresh_contacts()
						_oracle_contacts = _wall_oracle.get_contacts()
						_gs = int(_wall_oracle.get_ground_state())
						_gn = _wall_oracle.get_ground_normal()
						_dbg_cur["pre_snapped_down"] = snap_down
						_dbg_cur["pre_grounded_via"] = "snap_cast"

	_has_floor_contact = (_gs == 0)
	_has_jumpable_contact = (_gs == 0 or _gs == 1)
	_is_grounded = (_gs == 0)
	_best_contact_normal = Vector3.ZERO
	if (_gs == 0 or _gs == 1) and _gn != Vector3.ZERO and _gn.angle_to(Vector3.UP) < 1.553:   # < ~89°
		_floor_normal = _gn
		_best_contact_normal = _gn
	if _best_contact_normal == Vector3.ZERO:
		_best_contact_normal = _floor_normal

	# While rising from a jump, hold "airborne" — the capsule may still graze
	# the floor for a frame or two and the CV would otherwise re-ground us.
	if _post_jump_rising:
		_post_jump_timer -= delta
		if _post_jump_timer <= 0.0 or player.velocity.y <= 0.0:
			_post_jump_rising = false
		else:
			_is_grounded = false

	var floor_source_body := "cv"
	var floor_source_branch: String = ["on_ground", "on_steep_ground", "not_supported", "in_air"][clampi(_gs, 0, 3)]
	var walkable_summary: Array = []
	var _dbg_grounding_reason := "cv"

	# ── DBG: pre_physics_step capture ──
	_dbg_cur["pre_was_grounded"] = _was_grounded
	_dbg_cur["pre_has_floor_contact"] = _has_floor_contact
	_dbg_cur["pre_has_jumpable"] = _has_jumpable_contact
	_dbg_cur["pre_best_normal"] = _best_contact_normal
	_dbg_cur["pre_post_jump_rising"] = _post_jump_rising
	_dbg_cur["pre_grounding_reason"] = _dbg_grounding_reason
	_dbg_cur["pre_is_grounded"] = _is_grounded
	_dbg_cur["pre_floor_normal"] = _floor_normal
	# Floor-normal selection diagnostics (for esoteric "near-threshold walkable
	# contact" flicker — the floor source body changing frame-to-frame is the
	# direct signal).
	_dbg_cur["ws_floor_source_body"] = floor_source_body
	_dbg_cur["ws_floor_source_branch"] = floor_source_branch
	_dbg_cur["ws_floor_source_changed"] = (floor_source_body != _dbg_prev_floor_source_body)
	_dbg_cur["ws_walkable_contacts"] = walkable_summary
	_dbg_prev_floor_source_body = floor_source_body

	# ── DBG: wedge-stutter — capture entry state and the full contact set ──
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_pre_pos"] = player.global_position
		_dbg_cur["ws_pre_vel"] = player.velocity
		# Jolt's vel.y at start of frame minus what we set last frame:
		# isolates Jolt's solver impulse on Y (e.g. depen pushing the
		# capsule up after penetrating a triangle).
		_dbg_cur["ws_vy_jolt_delta"] = player.velocity.y - _dbg_prev_set_vel.y
		# Full Vector3 Jolt delta — isolates depen impulses on x/z too.
		# In a corner with a slightly-upward wall, depen impulse will have
		# upward Y component AND outward X/Z components.
		_dbg_cur["ws_vel_jolt_delta"] = player.velocity - _dbg_prev_set_vel
		_dbg_cur["ws_prev_floor_normal"] = _dbg_prev_floor_normal
		# Angle change (deg) between this frame's floor normal and last frame's.
		# A sudden ~5° jump on an otherwise-continuous surface = triangle-edge
		# crossing. The slope_proj from one triangle's normal vs the next is
		# what produces the ws_predicted_pos_y vs ws_sdf_y_now divergence.
		_dbg_cur["ws_floor_normal_angle_change_deg"] = rad_to_deg(_floor_normal.angle_to(_dbg_prev_floor_normal))
		_dbg_cur["ws_prev_post_pos"] = _dbg_prev_post_pos
		# SDF gradient normal — smoothed reference, immune to mesh edges.
		# If contact normals disagree with this, the discretization is causing
		# fake normals (internal-edge artifacts on top of a smooth surface).
		var sdf_n: Vector3 = _get_sdf_surface_normal()
		_dbg_cur["ws_sdf_normal"] = sdf_n
		_dbg_cur["ws_floor_vs_sdf_deg"] = rad_to_deg(_floor_normal.angle_to(sdf_n))
		var contact_summary: Array = []
		var current_nonwalk_bodies: Array = []   # for next-frame's contact-loss detection
		for c in _contacts:
			var body_obj = c.get("body")
			var body_class := "null"
			var body_name := "null"
			if body_obj != null:
				body_class = body_obj.get_class()
				if body_obj is Node:
					body_name = (body_obj as Node).name
			var cn: Vector3 = c["normal"]
			# Internal-edge probe: raycast from just OUTSIDE the contact (along
			# the contact normal) THROUGH the contact point. The hit surface's
			# face normal should match the reported contact normal IF the
			# contact is on a real face. If the face normal differs, the
			# contact is on an EDGE — Jolt is reporting the edge's
			# perpendicular instead of the face normal of either adjacent
			# face. For this to be meaningful we must restrict the ray to
			# the contact's OWN body — otherwise the probe can hit a
			# different nearby body and produce a meaningless comparison.
			var probe_face_n: Vector3 = Vector3.ZERO
			var probe_face_match: float = -1.0
			var probe_did_hit: bool = false
			var contact_wp: Vector3 = c.get("world_pos", Vector3.ZERO)
			if contact_wp != Vector3.ZERO and body_obj != null:
				var probe_space := player.get_world_3d().direct_space_state
				var probe_ray := PhysicsRayQueryParameters3D.new()
				probe_ray.from = contact_wp + cn * 0.05
				probe_ray.to = contact_wp - cn * 0.05
				probe_ray.collision_mask = player.collision_mask
				# Exclude every other body in the world. The simplest way
				# in Godot 4: exclude the player and any non-target body.
				# Since we don't have a clean "include only" API, we collect
				# nearby bodies from _contacts and exclude all but this one.
				var excludes: Array = [player.get_rid()]
				for cc in _contacts:
					var ccb = cc["body"]
					if ccb != null and ccb != body_obj and ccb is CollisionObject3D:
						var rid: RID = (ccb as CollisionObject3D).get_rid()
						if not excludes.has(rid):
							excludes.append(rid)
				probe_ray.exclude = excludes
				var probe_hit: Dictionary = probe_space.intersect_ray(probe_ray)
				if not probe_hit.is_empty():
					# Verify the hit is on the target body. If somehow we hit
					# a body we didn't have in _contacts (shouldn't happen),
					# discard so we don't get misleading data.
					var hit_collider = probe_hit.get("collider", null)
					if hit_collider == body_obj:
						probe_did_hit = true
						probe_face_n = probe_hit.get("normal", Vector3.ZERO)
						if probe_face_n != Vector3.ZERO:
							probe_face_match = rad_to_deg(probe_face_n.angle_to(cn))
			contact_summary.append({
				"normal": cn,
				"is_walkable": c["is_walkable"],
				"is_jumpable": c["is_jumpable"],
				"body_class": body_class,
				"body_name": body_name,
				"is_dynamic": body_obj is RigidBody3D,
				"world_pos": contact_wp,
				"vel_dot_n": player.velocity.dot(cn),     # how much vel is along this contact normal
				"probe_face_n": probe_face_n,
				"probe_face_match_deg": probe_face_match,
				"probe_did_hit": probe_did_hit,
			})
			if not c["is_walkable"] and body_obj != null:
				current_nonwalk_bodies.append(body_obj)
		_dbg_cur["ws_contacts"] = contact_summary

		# Contact-loss probe: for each non-walkable body that was in contact LAST
		# frame but isn't this frame, shape-test against it. If overlap exists,
		# Jolt's contact reporting is dropping a real overlap (geometry-driven —
		# triangle migration, broadphase glitch, etc.). If no overlap, the
		# capsule actually separated (drift past tolerance).
		var lost_contact_probes: Array = []
		for prev_body in _ws_prev_nonwalk_bodies:
			if prev_body == null or not is_instance_valid(prev_body):
				continue
			if prev_body in current_nonwalk_bodies:
				continue
			# Was non-walkable in contact last frame, gone this frame. Probe it.
			var space := player.get_world_3d().direct_space_state
			var col_shape: CollisionShape3D = player.get_node("CollisionShape3D")
			var probe_params := PhysicsShapeQueryParameters3D.new()
			probe_params.shape = col_shape.shape
			probe_params.transform = col_shape.global_transform
			probe_params.collision_mask = player.collision_mask
			probe_params.exclude = [player.get_rid()]
			# Restrict to the body we're probing.
			if prev_body is CollisionObject3D:
				probe_params.collide_with_areas = false
				probe_params.collide_with_bodies = true
			var rest: Dictionary = space.get_rest_info(probe_params)
			var overlapping: bool = not rest.is_empty()
			var probe_name: String = "?"
			if prev_body is Node:
				probe_name = String((prev_body as Node).name)
			var probe_class: String = "?"
			if prev_body is Object:
				probe_class = (prev_body as Object).get_class()
			var rest_normal: Vector3 = Vector3.ZERO
			if overlapping:
				rest_normal = rest.get("normal", Vector3.ZERO)
			lost_contact_probes.append({
				"body_name": probe_name,
				"body_class": probe_class,
				"overlap_at_capsule_pos": overlapping,
				"rest_normal": rest_normal,
			})
		_dbg_cur["ws_lost_contact_probes"] = lost_contact_probes

		# Save the bodies present this frame for next frame's loss detection.
		_ws_prev_nonwalk_bodies = current_nonwalk_bodies.duplicate()
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
		# Landed: reset the air-jump counter. Do NOT restore _airborne_hvel here
		# any more — that save/restore existed because the old RigidBody solver
		# would zero the player's velocity on a hard contact, so we had to stash
		# and re-apply the horizontal component. The CharacterVirtual's collide-
		# and-slide preserves tangent momentum through a land-and-slide on its
		# own, and _airborne_hvel is no longer being updated (its writer,
		# try_snap_to_ground, is gone) — restoring it just teleported the
		# horizontal velocity to a stale value, which on bumpy block-terrain
		# (where ground state flickers for a frame as you go over a step)
		# produced the stop/start stutter.
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
	# Raw input direction (world-frame). Wall-proj no longer mutates `direction`
	# — both `direction` and `raw_input_dir` stay equal here. The variable is
	# kept for the stick-to-walls fix below, which uses it to check player
	# intent (input pressing INTO a non-walkable contact).
	var raw_input_dir: Vector3 = direction
	if GameManager.debug_floor_diag:
		print("[FD] process_normal_movement IN: vel=(%.4f,%.4f,%.4f) input_dir=(%.2f,%.2f) direction=(%.3f,%.3f,%.3f)" % [
			player.velocity.x, player.velocity.y, player.velocity.z,
			input_dir.x, input_dir.y, direction.x, direction.y, direction.z])

	# Compute max_speed first — needed as the sweep cast distance below.
	var shoe_bonus: float = player.inventory.get_shoe_speed_bonus() if player.inventory else 0.0
	var heat_mult: float = player.heat_system.get_speed_multiplier()
	var speed_mult: float = heat_mult + shoe_bonus
	if 5 in player.active_bonuses:
		speed_mult += 0.1
	if player._second_wind_timer > 0.0:
		speed_mult += 0.3
	var max_speed: float = SPEED * speed_mult
	if GameManager.debug_speed_50:
		max_speed = 50.0

	# ── Collide-and-slide: contact set ───────────────────────────────────────
	# Non-walkable surfaces the capsule is touching, from the oracle (true
	# per-triangle face normals, stable frame-to-frame — sensors and the
	# player's own body already filtered out of _oracle_touch). These are what
	# both the walk-accel push and the final velocity get projected off of.
	# Filtered here only by what the projection genuinely doesn't apply to:
	#   • walkable surfaces (angle ≤ 50°) — that's a floor, slope-proj owns it
	#   • a light dynamic body that barely resisted last frame — not wall-like
	# No "curb / step rolled over" filter: a curb-edge contact and a tall wall-
	# face contact at the base are geometrically *indistinguishable* from a
	# single contact (same low position, same normal), so any height-based
	# carve-out misclassifies one of them. Without one, sub-radius rollable
	# curbs slow the player on approach but don't launch them; tall walls and
	# steep ramps are clipped correctly. (Block-mesh terrain doesn't have real
	# sub-radius curbs anyway.)
	# Inclusion horizon: a wall the player can REACH this frame must shape the
	# target, not just walls already touched. With the touching-only set, a
	# capsule wedged in a two-wall corner oscillates a few mm per frame and
	# each frame only ONE wall passes the touch filter — the target aims along
	# that wall, the engine clips into the other, mirrored next frame: a
	# standing limit-cycle ("velocity carries over like one continuous
	# surface"). Reach = this frame's horizontal travel + touch epsilon, so
	# both corner planes stay in the set continuously and the target collapses
	# onto their crease (vertical for walls → dime stop). Derived from speed
	# and dt — not a tuned constant.
	var _wp_reach: float = maxf(_ORACLE_TOUCH_EPS, Vector2(player.velocity.x, player.velocity.z).length() * delta)
	# Each plane carries a resistance fraction f: 1.0 for static geometry, and
	# mass/(mass + character_mass) for dynamic bodies — the same law the
	# solver's velocity clip uses. The input target is projected off each
	# plane by f, so an infinite-mass dynamic wall shapes input exactly like
	# a static wall and a light crate barely shapes it at all (you push it
	# instead). This replaces the old binary `_dynamic_wall_fraction < 0.5`
	# skip — a step function where the doctrine wants continuity.
	var _wp_char_mass: float = _wall_oracle.character_mass if _wall_oracle != null else 70.0
	var wall_planes: Array = []
	for c in _oracle_contacts:
		if bool(c.get("is_sensor", false)):
			continue
		if c.get("collider") == player:
			continue
		if float(c.get("distance", 1.0)) > _wp_reach:
			continue
		var cn: Vector3 = c["surface_normal"]
		if cn == Vector3.ZERO:
			continue
		if cn.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			continue
		var f := 1.0
		if c["collider"] is RigidBody3D and not GameManager.debug_wall_proj_dynamic:
			var rb_mass: float = (c["collider"] as RigidBody3D).mass
			f = rb_mass / (rb_mass + _wp_char_mass)
		wall_planes.append({"n": cn, "f": f})

	# ── Walk-accel target ────────────────────────────────────────────────────
	# Walk-accel is a ground push — it only ever produces *horizontal* velocity,
	# so it can never climb a non-walkable surface. The chase target is the
	# input direction projected so it doesn't point into any wall in `wall_planes`
	# (and at a corner of two, onto their crease line — which for vertical walls
	# is vertical, so the horizontal target collapses to zero and the player
	# just stops). The target's magnitude scales with how much of the input
	# survived the projection: pressing into a wall at an angle contributes less
	# acceleration. Momentum already moving *along* a wall is untouched (the
	# projection only removes the into-wall component) — the cap is on what the
	# player contributes, not a hard speed clamp.
	# The chase target is the input direction clipped off the wall planes
	# (crease line at a two-wall corner), magnitude scaled by what survives the
	# projection: pressing into a wall at angle φ from its plane contributes
	# max_speed·cos(φ) along the wall — the trig speed cap — and because
	# walk-accel chases THIS target, the acceleration is shaped by the same
	# function (it drives along the wall instead of wasting itself into it).
	# This is input-TARGET shaping, not a second collision authority: Jolt
	# still solves every contact; this only changes what the player asks for.
	# (An older comment here claimed re-enabling this caused inside-corner
	# wiggle — that was the RigidBody era, when the script also projected the
	# final VELOCITY against a flickering manifold contact set. The target
	# projection alone can't disagree with the solver, and wall_planes now
	# come from the CV oracle's stable true-face-normal sweep. With it
	# disabled, walk-accel aimed the full 9 m/s INTO walls, so the along-wall
	# target was just the residual tangential component — sliding required
	# turning nearly parallel; see the 2026-06-10 wall-slide log.)
	var walk_target_velocity: Vector3 = direction * max_speed
	if direction != Vector3.ZERO and _is_grounded and not GameManager.debug_no_wall_proj and not wall_planes.is_empty():
		var d: Vector3 = _project_off_walls(direction, wall_planes, 4)
		walk_target_velocity = Vector3(d.x, 0.0, d.z) * max_speed
		if GameManager.debug_no_wall_speed_scale:
			walk_target_velocity = direction * max_speed

	# walk_target_speed is the scalar magnitude of walk_target_velocity —
	# the "how fast walk-accel chases" used by the air path, the overspeed
	# friction-decel, and other branches that work in scalar form.
	# max_speed remains the true running cap (skid trigger / hard ceiling),
	# independent of wall-proj.
	var walk_target_speed: float = walk_target_velocity.length()

	# Wall-proj output capture for wedge-stutter diagnosis. Records what
	# wall-proj produced this frame so the dump can compare frame-to-frame.
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_wp_fraction"] = walk_target_speed / max_speed if max_speed > 0.0 else 0.0
		_dbg_cur["ws_wp_direction"] = direction
		_dbg_cur["ws_wp_planes"] = []   # clip-based wall-proj has no plane set
		_dbg_cur["ws_wp_dyn_fraction"] = _dynamic_wall_fraction
		_dbg_cur["ws_wp_prev_fraction"] = _ws_prev_wall_speed_fraction
		_dbg_cur["ws_wp_prev_direction"] = _ws_prev_wall_proj_dir
		_dbg_cur["ws_wp_prev_planes"] = _ws_prev_wall_planes
		_dbg_cur["ws_wp_disabled"] = GameManager.debug_no_wall_proj
		# Update tracker for next frame.
		_ws_prev_wall_speed_fraction = walk_target_speed / max_speed if max_speed > 0.0 else 0.0
		_ws_prev_wall_proj_dir = direction
		_ws_prev_wall_planes = []

	var accel: float = current_floor_friction() * ACCEL_FRICTION_RATIO if _is_grounded else AIR_ACCELERATION
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

	# ── Support-relative frame ───────────────────────────────────────────────
	# The whole grounded walk pipeline (targets, friction bleed, instant stop,
	# grip clamp, skid threshold, dime stop) operates RELATIVE to the surface
	# being stood on: an infinite-mass moving platform is walked on exactly
	# like ground — standing still means moving WITH it, walk speed is speed
	# across ITS surface, friction grips relative slip. The carry is added
	# back when the result is written. On static ground the carry is zero, so
	# nothing changes there. (Airborne frames take the air path with zero
	# carry — world frame is correct in the air.)
	var ground_carry := Vector3.ZERO
	if _is_grounded and _wall_oracle != null and _wall_oracle.has_method("get_ground_velocity"):
		var gv: Vector3 = _wall_oracle.get_ground_velocity()
		ground_carry = Vector3(gv.x, 0.0, gv.z)
		hvel -= ground_carry
		hspeed = hvel.length()

	# (No hard clamp on hvel here. The wall-proj cap is on player INPUT
	# acceleration only — it must not silently drop speed that came from an
	# external force. Friction-decel above max_speed is handled inside
	# _process_ground_movement.)

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

	# Walk-accel target capture for wedge-stutter. The target = walk_target_velocity
	# (wall-clipped × max_speed) is what walk-accel chases.
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_walk_max_speed"] = walk_target_velocity.length()
		_dbg_cur["ws_walk_target_hvel"] = walk_target_velocity
		_dbg_cur["ws_walk_accel"] = accel

	# ── Knockback channel ────────────────────────────────────────────────────
	# External momentum (explosions, body shoves) lives in `knockback_hvel`,
	# separate from walk velocity, so the grounded grip clamp can't eat it.
	# It is removed from the carried velocity before the walk pipeline runs,
	# frictioned away independently (grounded only — air keeps momentum), has
	# its into-wall components killed by the same wall planes that shape the
	# walk target, and is re-added after. The walk pipeline therefore shapes
	# only the player's own contribution, per the input-contribution doctrine.
	if knockback_hvel != Vector3.ZERO:
		for w in wall_planes:
			var wn: Vector3 = w["n"]
			var wnh := Vector3(wn.x, 0.0, wn.z)
			if wnh.length_squared() > 0.01:
				wnh = wnh.normalized()
				var into := knockback_hvel.dot(wnh)
				if into < 0.0:
					# Walls absorb knockback proportional to their resistance.
					knockback_hvel -= wnh * into * float(w["f"])
		if _is_grounded:
			knockback_hvel = knockback_hvel.move_toward(Vector3.ZERO, current_floor_friction() * delta)
		if knockback_hvel.length_squared() < 0.01:
			knockback_hvel = Vector3.ZERO

	var walk_hvel := hvel - knockback_hvel
	var walk_hspeed := walk_hvel.length()

	var use_ground := _is_grounded or GameManager.debug_always_ground_move
	if GameManager.debug_no_walk_accel:
		# Test toggle: skip walk-acceleration entirely. hvel unchanged.
		pass
	elif hspeed >= current_floor_friction() * SKID_THRESHOLD_RATIO and use_ground:
		# Extreme overspeed: skid operates on the TOTAL velocity — fold the
		# knockback channel back in and let skid own all of it.
		knockback_hvel = Vector3.ZERO
		hvel = _process_ground_movement(hvel, hspeed, direction, walk_target_velocity, max_speed, accel, delta)
	elif use_ground:
		hvel = _process_ground_movement(walk_hvel, walk_hspeed, direction, walk_target_velocity, max_speed, accel, delta) + knockback_hvel
		if _dbg_wall_nh != Vector3.ZERO:
			_dbg_cur["wall_perp_s1"] = hvel.dot(_dbg_wall_nh)
		if _dbg_wall_nh != Vector3.ZERO:
			_dbg_cur["wall_perp_s2"] = hvel.dot(_dbg_wall_nh)
	else:
		hvel = _process_air_movement(walk_hvel, walk_hspeed, direction, walk_target_speed, accel, delta) + knockback_hvel

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
		player.velocity.x = hvel.x + ground_carry.x
		player.velocity.z = hvel.z + ground_carry.z

	# Friction-coupled vy decay. When grounded on a slope and walk-accel reduces
	# the horizontal speed (player releases input → decel), scale vy by the same
	# factor so the vy/hvel ratio (= tan(slope_angle)) is preserved without ever
	# referencing a floor normal. When hvel → 0, the scale → 0 and vy → 0, which
	# kills the post-stop hop. When hvel is constant (sustained walking), scale =
	# 1.0 so vy is unchanged. When hvel ACCELERATES (input applied from rest), vy
	# would scale up by hspeed_new/hspeed_old, but at rest hspeed_old ≈ 0 — gate
	# on hspeed_old > epsilon to avoid divide-by-zero / runaway boost. The
	# acceleration case is handled by Jolt's projection (it'll lift vy to the
	# new slope-tangent when the velocity hits the slope contact).
	# This sidesteps the GDScript-vs-Jolt multi-contact disagreement entirely
	# because no floor normal is referenced — we just preserve the existing
	# vy/hvel relationship across frames as it evolves.
	# Crest-launch behavior preserved: when the slope flattens, vy/hvel ratio
	# (from previous steeper slope) exceeds the new slope's tangent → velocity
	# has a positive dot with the new contact normal (separating) → Jolt's
	# projection inactive → player goes naturally airborne with the carried vy.
	if _is_grounded:
		var hspeed_new := hvel.length()
		if hspeed > 1.0e-4:
			# DECAY-ONLY: clamp the ratio to ≤ 1. Growth was always delegated
			# to Jolt's tangent handling, and an unclamped ratio is a positive
			# feedback amplifier: wedged in a wall corner, the walls clip h
			# down and walk-accel re-grows it every frame, so vy multiplied by
			# ~2 per frame and rocketed the player (logged 12 → 24 → 45 m/s).
			player.velocity.y *= minf(hspeed_new / hspeed, 1.0)

	# Leg odometer: while the combined capture (F8/F9) is on, print one [LEG]
	# line whenever the input direction changes (start, stop, or turn): how many
	# frames the previous leg was held, the net world displacement it covered,
	# and its heading. Lets a "back and forth slides me downhill" log show
	# directly whether the legs were symmetric (input) or the ground track
	# disagrees with the input (engine).
	if GameManager.debug_combined_capture_active:
		var same_leg := (direction == Vector3.ZERO and _leg_dir == Vector3.ZERO) \
				or (direction != Vector3.ZERO and _leg_dir != Vector3.ZERO and direction.dot(_leg_dir) > 0.996)
		if same_leg:
			_leg_frames += 1
		else:
			if _leg_frames > 0:
				var net := player.global_position - _leg_start_pos
				var net_h := Vector2(net.x, net.z)
				var kind := "idle" if _leg_dir == Vector3.ZERO else "move"
				var head := rad_to_deg(atan2(_leg_dir.x, _leg_dir.z)) if _leg_dir != Vector3.ZERO else 0.0
				print("[LEG] %s %d frames  heading=%.1f°  net=(%.3f,%.3f,%.3f)  |h|=%.3f m  avg=%.2f m/s" % [
					kind, _leg_frames, head, net.x, net.y, net.z, net_h.length(),
					net_h.length() / (maxf(1.0, float(_leg_frames)) / 60.0)])
			_leg_dir = direction
			_leg_start_pos = player.global_position
			_leg_frames = 1
	else:
		_leg_frames = 0
		_leg_dir = Vector3.ZERO

	# Vel.y attribution chain: capture vel.y after walk-accel writes hvel
	# but BEFORE slope-proj sets vel.y. This is the "vel.y that survived
	# from last frame's end (modulo gravity)" — useful for attributing
	# the discrete vel.y jumps to slope-proj specifically.
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_vy_post_walkaccel"] = player.velocity.y

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
	# Slope handling lives in the C++ listener (OnContactSolve in
	# jolt_character_virtual_3d.cpp): on each walkable contact it preserves the
	# incoming horizontal velocity verbatim and recomputes vy for tangency to
	# THAT contact (the same cn Jolt's solver uses — no GDScript-vs-Jolt normal
	# mismatch), blended by the solver's mass-ratio law for dynamic floors, at
	# most once per contact per frame. The once-per-frame gate is what makes
	# this convergent — the ungated variant stuck-looped the solver when it was
	# first tried. The post-stop hop is handled by the friction-coupled vy decay
	# above — no floor normal needed.
	# The legacy GDScript block is kept disabled for A/B testing.
	if false and _is_grounded and _has_floor_contact and not GameManager.debug_no_slope_projection:
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
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_slope_proj_y"] = surface_y
			_dbg_cur["ws_post_move_vel"] = player.velocity
			# Compute vel·n for each non-walkable contact AFTER walk-accel+slope-proj
			# so we can compare to the pre-pipeline value. If this is positive
			# (outward) that's the "drift" we suspect causes contact loss.
			var post_dots: Array = []
			for cc in _contacts:
				if not cc["is_walkable"]:
					post_dots.append({
						"name": ((cc["body"] as Node).name if cc["body"] is Node else "?"),
						"normal": cc["normal"],
						"vel_dot_n": player.velocity.dot(cc["normal"]),
					})
			_dbg_cur["ws_post_pipeline_wall_dots"] = post_dots

			# Y-trajectory: predict where vel.y * delta puts the player and
			# compare to the SDF terrain height at the player's (x, z). If
			# predicted_pos_y is higher than sdf_y_now, the slope projection's
			# prediction puts the capsule ABOVE the actual surface — that's
			# the discretization error driving snap to yank the player down.
			var ws_pos_now_xz: Vector3 = player.global_position
			_dbg_cur["ws_pos_now"] = ws_pos_now_xz
			_dbg_cur["ws_predicted_pos_y"] = ws_pos_now_xz.y + player.velocity.y * delta
			_dbg_cur["ws_sdf_y_now"] = _get_terrain_height(ws_pos_now_xz.x, ws_pos_now_xz.z)
			_dbg_cur["ws_floor_normal_at_proj"] = n
		if GameManager.debug_floor_diag:
			print("[FD]   slope-projected: body_surface_vel=(%.3f,%.3f,%.3f) surface_y=%.4f  vel.y set to %.4f" % [
				body_surface_vel.x, body_surface_vel.y, body_surface_vel.z,
				surface_y, player.velocity.y])
		# Surface press: add a small downward bias to maintain floor contact
		if GameManager.debug_grounding_surface_press:
			player.velocity.y -= GameManager.debug_grounding_press_strength

		# Collide-and-slide: project the full velocity (the vel.y slope-proj
		# just set, plus hvel) off every non-walkable contact, while keeping it
		# tangent to the floor. Removes only the into-surface component — momentum
		# along a wall (lateral, knockback) is untouched — so walking into a wall
		# slides you along its base, never up it; vel.y from the floor that
		# happens to point into a steep slope is cancelled in the floor plane (no
		# ride-up from Jolt's depen either); and a corner of vertical walls leaves
		# zero horizontal motion → the player stops, no twitch.
		if not GameManager.debug_no_wall_proj and not wall_planes.is_empty():
			player.velocity = _project_vel_keep_floor(player.velocity, wall_planes, n, body_surface_vel.dot(n))
			if GameManager.debug_wedge_stutter:
				_dbg_cur["ws_post_move_vel"] = player.velocity

		# Stick-to-walls (compound contact wedge fix). The slope projection above
		# enforces tangency to the floor (vel · n_floor = 0) but doesn't account
		# for any non-walkable contact (ramp, wall, ceiling). The result is
		# velocity that's tangent to the floor but has a small outward component
		# along the non-walkable contact normal — the capsule slowly drifts away
		# from the second surface, contact is lost after a few frames, and the
		# resulting wall_speed_fraction snap produces visible stutter.
		#
		# Fix: when the player is actively pressing into a non-walkable contact,
		# zero the outward velocity component along that contact's normal. This
		# is the missing second contact constraint, applied only when player
		# intent says they want to be glued to the wall (input has into-wall
		# component). When the player presses away from the wall, no projection
		# fires — they back out naturally.
		if GameManager.debug_wedge_stick_to_walls:
			var wall_n: Vector3 = Vector3.ZERO
			var most_into: float = 0.0
			for c in _contacts:
				if c["is_walkable"]:
					continue
				var cn: Vector3 = c["normal"]
				var input_into := raw_input_dir.dot(cn)
				# Player is pressing into this contact if input · n is negative
				# (input opposes the surface normal).
				if input_into < most_into:
					most_into = input_into
					wall_n = cn
			if wall_n != Vector3.ZERO:
				var vel_outward := player.velocity.dot(wall_n)
				if vel_outward > 0.0:
					player.velocity -= wall_n * vel_outward

		# Compound contact constraint (full-3D wall projection). Wall-proj above
		# uses only the horizontal component of contact normals, so a sloped
		# ceiling or angled-wall contact has its Y component silently ignored.
		# slope-proj enforces tangency to the floor only. Result: under a ramp
		# while walking down a slope, vel has a nonzero component along the
		# ramp's full 3D normal — the capsule slowly drains out of the ceiling
		# contact in Y, contact dies, wall-proj's horizontal clamp releases,
		# forward speed jumps, slope-proj recomputes a bigger vel.y, capsule
		# slams the ramp again. Visible stutter.
		#
		# Fix: after slope-proj has set vel.y, project velocity against the
		# FULL 3D normal of every active non-walkable contact. Removes the
		# orthogonal Y leak no other projection covers. Unconditional — runs
		# whether or not the player is "intentionally pressing in", since the
		# leak happens regardless of input intent (it comes from slope-proj).
		if GameManager.debug_wall_proj_full_normal:
			var fix8_fired: int = 0
			var fix8_total_correction: float = 0.0
			for c in _contacts:
				if c["is_walkable"]:
					continue
				var cn: Vector3 = c["normal"]
				var vel_outward2: float = player.velocity.dot(cn)
				if vel_outward2 > 0.0:
					player.velocity -= cn * vel_outward2
					fix8_fired += 1
					fix8_total_correction += vel_outward2
			if GameManager.debug_wedge_stutter:
				_dbg_cur["ws_fix8_active"] = true
				_dbg_cur["ws_fix8_fired_count"] = fix8_fired
				_dbg_cur["ws_fix8_total_correction"] = fix8_total_correction
				_dbg_cur["ws_post_fix8_vel"] = player.velocity
		elif GameManager.debug_wedge_stutter:
			_dbg_cur["ws_fix8_active"] = false

		# Joint compound-contact projection (wedge axis). Sequential single-
		# plane projections (slope-proj for floor, Fix 8 for ceiling) violate
		# each other — Fix 8 cancels vel·n_ceiling but breaks vel·n_floor=0,
		# so the capsule rises off the floor; snap then yanks it back down
		# every frame, draining it out of the ceiling contact.
		#
		# Geometrically correct: when two contact normals are simultaneously
		# active, velocity must lie in the intersection of both tangent
		# planes — the line `n_floor × n_other`. Projecting velocity onto
		# this wedge axis enforces both constraints jointly.
		#
		# Effect: in a true wedge (e.g. floor + ramp ceiling), the capsule
		# slides exactly along the wedge corner — no separation from either
		# surface, no snap fight, no slam. Pressing perpendicular to the
		# wedge axis collapses motion to zero, which is the geometrically
		# correct outcome (a rigid capsule can't move perpendicular to a
		# wedge it's jammed into). For vertical walls (n.y ≈ 0), wedge axis
		# is vertical, perpendicular pressure = stop, parallel pressure =
		# full speed — same as today's wall-proj.
		if GameManager.debug_wedge_joint_proj:
			var fix9_walk_vy_pre: float = player.velocity.y
			var fix9_walk_max_n: Vector3 = Vector3.ZERO
			var fix9_walk_max_vy: float = player.velocity.y

			# Pass 1: secondary WALKABLE contacts (ridge crossings).
			# When the capsule touches two floor triangles at a ridge, slope-
			# proj only enforces tangency to the primary floor normal, leaving
			# vel·n_other ≠ 0 on the second triangle. If vel·n_other < 0
			# (capsule moving INTO the second surface) Jolt's depen kicks the
			# capsule up next physics step → felt bump.
			#
			# Geometrically correct + non-restrictive fix: ensure vel.y is at
			# least the slope-proj value for every walkable normal — i.e.
			# vel.y = max(vel.y_i across walkable contacts). The capsule stays
			# tangent to the steepest of the relevant triangles and separates
			# slightly (vel·n > 0) from any flatter triangles. No penetration
			# → no depen impulse → no bump. No horizontal restriction.
			for c in _contacts:
				var cn: Vector3 = c["normal"]
				if cn.angle_to(n) < deg_to_rad(1.0):
					continue          # primary floor — slope-proj already did this
				if not c["is_walkable"]:
					continue          # non-walkable — handled in pass 2
				if cn.y > 0.001:
					var sec_vy: float = -(cn.x * player.velocity.x + cn.z * player.velocity.z) / cn.y
					if sec_vy > player.velocity.y:
						player.velocity.y = sec_vy
						if sec_vy > fix9_walk_max_vy:
							fix9_walk_max_vy = sec_vy
							fix9_walk_max_n = cn

			# Pass 2: secondary NON-WALKABLE contact (wedge / ceiling case).
			# ONE-SIDED compound-contact constraint:
			#   vel·n_floor = 0   (slope-proj already enforces — preserve)
			#   vel·n_other ≥ 0   (don't penetrate the secondary surface)
			#
			# When vel·n_other < 0 (moving into the secondary), apply the
			# minimal correction that:
			#   1. Cancels vel·n_other (makes it 0 — tangent to secondary)
			#   2. Lies in the floor plane (preserves vel·n_floor = 0)
			#
			# The correction direction is n_other projected onto the floor
			# plane: n_other_in_floor = n_other - n_floor * (n_other · n_floor).
			# Adding α * n_other_in_floor with α = -vel·n_other / |n_other_in_floor|²
			# yields the unique vector that satisfies both constraints.
			#
			# When vel·n_other ≥ 0 (moving away from or tangent to secondary),
			# no correction fires. Pulling backward out of a wedge, sliding
			# along the wedge axis, or any motion that doesn't penetrate the
			# secondary surface is unrestricted.
			var n_other: Vector3 = Vector3.ZERO
			var most_into: float = 0.0
			for c in _contacts:
				if c["is_walkable"]:
					continue
				var cn: Vector3 = c["normal"]
				var into: float = -player.velocity.dot(cn)   # >0 when penetrating
				if into > most_into:
					most_into = into
					n_other = cn
			if n_other != Vector3.ZERO and most_into > 0.0:
				var n_dot: float = n_other.dot(n)
				var n_other_in_floor: Vector3 = n_other - n * n_dot
				var n_other_in_floor_sq: float = n_other_in_floor.length_squared()
				if n_other_in_floor_sq > 0.0001:
					var pre_joint_vel: Vector3 = player.velocity
					var alpha: float = most_into / n_other_in_floor_sq
					player.velocity += n_other_in_floor * alpha
					if GameManager.debug_wedge_stutter:
						_dbg_cur["ws_fix9_active"] = true
						_dbg_cur["ws_fix9_n_other"] = n_other
						_dbg_cur["ws_fix9_into_amount"] = most_into
						_dbg_cur["ws_fix9_correction_dir"] = n_other_in_floor.normalized()
						_dbg_cur["ws_fix9_pre_vel"] = pre_joint_vel
						_dbg_cur["ws_fix9_post_vel"] = player.velocity
				elif GameManager.debug_wedge_stutter:
					_dbg_cur["ws_fix9_active"] = true
					_dbg_cur["ws_fix9_degenerate"] = true
			elif GameManager.debug_wedge_stutter:
				_dbg_cur["ws_fix9_active"] = true
				if n_other == Vector3.ZERO:
					_dbg_cur["ws_fix9_no_other"] = true
				else:
					_dbg_cur["ws_fix9_already_separating"] = true
				_dbg_cur["ws_fix9_post_vel"] = player.velocity

			# Diagnostic capture for walkable pass.
			if GameManager.debug_wedge_stutter:
				_dbg_cur["ws_fix9_walk_vy_pre"] = fix9_walk_vy_pre
				_dbg_cur["ws_fix9_walk_vy_post_walkpass"] = fix9_walk_max_vy
				_dbg_cur["ws_fix9_walk_max_n"] = fix9_walk_max_n
		elif GameManager.debug_wedge_stutter:
			_dbg_cur["ws_fix9_active"] = false

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
	if GameManager.debug_wedge_stutter:
		# Pipeline checkpoint: end of process_normal_movement.
		# Pos is the same as start (only Jolt moves position via physics step,
		# not script — except snap), so any non-zero Δ vs pre_snap pos must
		# come from snap. Vel is the final script-set vel for this frame.
		_dbg_cur["ws_chk_post_norm_move_pos"] = player.global_position
		_dbg_cur["ws_chk_post_norm_move_vel"] = player.velocity
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
				if GameManager.debug_wedge_stutter:
					var snap_pt: Vector3 = rest.get("point", player.global_position)
					_dbg_cur["ws_snap_target_name"] = (collider as Node).name if collider is Node else "?"
					_dbg_cur["ws_snap_target_class"] = (collider as Object).get_class()
					_dbg_cur["ws_snap_hit_point"] = snap_pt
					_dbg_cur["ws_snap_actual_dy"] = snap_dist * result[0]
					_dbg_cur["ws_snap_hit_normal"] = rest.normal
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
				if GameManager.debug_wedge_stutter:
					_dbg_cur["ws_snap_target_name"] = (rb as Node).name
					_dbg_cur["ws_snap_target_class"] = (rb as Object).get_class()
					_dbg_cur["ws_snap_hit_point"] = contact_world
					_dbg_cur["ws_snap_actual_dy"] = snap_dist * result[0]
					_dbg_cur["ws_snap_hit_normal"] = n
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


# ──────────────────────────────────────────────────────────────────────
#  Collide-and-slide helpers
# ──────────────────────────────────────────────────────────────────────

## Project `v` off the wall planes. `walls` is an array of {n: Vector3,
## f: float} where f is the plane's resistance fraction (1.0 = rigid).
## Rigid planes (f ≈ 1) are hard constraints: iteratively clip so v·n ≥ 0,
## sliding onto the crease line at a two-wall corner, zero when boxed in by
## three. Yielding planes (light dynamic bodies) remove only f of the
## into-plane component per pass — pushing a light object costs the input
## proportionally little, and as f → 1 the behavior converges to the rigid
## path (the doctrine's infinite-mass limit).
func _project_off_walls(v: Vector3, walls: Array, passes: int) -> Vector3:
	var rigid: Array = []
	var yielding: Array = []
	for w in walls:
		if float(w["f"]) >= 0.999:
			rigid.append(w["n"])
		else:
			yielding.append(w)

	for _pass in range(passes):
		var worst_d: float = -1.0e-4
		var worst_n: Vector3 = Vector3.ZERO
		for n in rigid:
			var dd: float = v.dot(n)
			if dd < worst_d:
				worst_d = dd
				worst_n = n
		if worst_n == Vector3.ZERO:
			break   # nothing violated
		var v1: Vector3 = v - worst_n * v.dot(worst_n)
		var second_d: float = -1.0e-4
		var second_n: Vector3 = Vector3.ZERO
		for n in rigid:
			if n == worst_n:
				continue
			var dd: float = v1.dot(n)
			if dd < second_d:
				second_d = dd
				second_n = n
		if second_n == Vector3.ZERO:
			v = v1
			continue
		var crease: Vector3 = worst_n.cross(second_n)
		if crease.length_squared() < 1.0e-8:
			v = v1   # (anti)parallel planes — clipping onto one is enough
			continue
		crease = crease.normalized()
		v = crease * v.dot(crease)
		for n in rigid:
			if v.dot(n) < -1.0e-4:
				return Vector3.ZERO   # boxed in by ≥3 planes — no valid direction

	# Yielding planes: partial clips, repeated — each pass removes f of the
	# remaining into-component, so this converges geometrically and cannot
	# ping-pong.
	for _pass in range(passes):
		var any_clip := false
		for w in yielding:
			var n: Vector3 = w["n"]
			var dd: float = v.dot(n)
			if dd < -1.0e-4:
				v -= n * (dd * float(w["f"]))
				any_clip = true
		if not any_clip:
			break
	return v


## Project `v` off the wall normals while keeping v·floor_n == floor_dot —
## i.e. stay tangent to the walkable floor. Each wall correction is added
## along the wall normal projected into the floor plane: the minimal change
## that cancels v·n_wall without disturbing v·floor_n. So walking into a wall
## on a slope slides you along its base instead of riding up it. Boxed in →
## keep the floor-tangent vertical, kill horizontal motion (player stops).
func _project_vel_keep_floor(v: Vector3, walls: Array, floor_n: Vector3, floor_dot: float) -> Vector3:
	if absf(floor_n.y) < 0.001:
		return v   # near-vertical "floor" — shouldn't happen (it's walkable)
	for _pass in range(5):
		var changed: bool = false
		var ny: float = (floor_dot - floor_n.x * v.x - floor_n.z * v.z) / floor_n.y
		if absf(ny - v.y) > 1.0e-5:
			v.y = ny
			changed = true
		for w in walls:
			var n: Vector3 = w["n"]
			var into: float = v.dot(n) * float(w["f"])
			if into >= -1.0e-5:
				continue
			var m: Vector3 = n - floor_n * n.dot(floor_n)
			var m_sq: float = m.length_squared()
			if m_sq > 1.0e-6:
				v += m * (-into / m_sq)
			else:
				v -= n * into   # n ⟂ floor plane — plain clip; floor re-enforce next pass
			changed = true
		if not changed:
			break
	for w in walls:
		if float(w["f"]) >= 0.999 and v.dot(w["n"]) < -1.0e-3:
			v = Vector3(0.0, floor_dot / floor_n.y, 0.0)   # vel·floor_n == floor_dot with vx = vz = 0
			break
	return v


func _process_ground_movement(hvel: Vector3, hspeed: float, direction: Vector3, walk_target_velocity: Vector3, max_speed: float, accel: float, delta: float) -> Vector3:
	# walk_target_velocity = clip(direction, wall_normals) × max_speed. The
	# walk-accel chase target is this VECTOR (not just a magnitude). Its
	# direction is the wall-tangent component of input (so walk-accel push
	# never has into-wall components), and its magnitude scales with how
	# much of input is tangent. max_speed is the true cap (no wall-proj)
	# — the skid trigger and the friction-decel floor.
	var walk_target_speed: float = walk_target_velocity.length()
	_dbg_is_skidding = false
	var floor_friction := current_floor_friction()
	var skid_threshold := floor_friction * SKID_THRESHOLD_RATIO
	var skid_friction := floor_friction
	var dime_stop_speed := floor_friction * DIME_STOP_RATIO
	if direction == Vector3.ZERO:
		# No input: instant stop (below skid threshold)
		if hspeed <= skid_threshold:
			return Vector3.ZERO
		else:
			# In skid with no input: friction slows us down
			return hvel.move_toward(Vector3.ZERO, skid_friction * delta)

	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	# Skid: ONLY above the friction-derived "extreme overspeed" threshold.
	# Below it, grounded friction is in the instant-grip regime (the "instant
	# stop/start within a friction-determined threshold" rule), so landing
	# from a jump with slope-projected speed below skid_threshold grips
	# immediately instead of sliding down the hill. (This branch previously
	# also skidded on hspeed > max_speed, which put every landing redirect
	# into a gradual decel — the "landing slides me down the hill" bug.)
	if hspeed >= skid_threshold:
		_dbg_is_skidding = true
		return _process_skid(hvel, hspeed, hdir, delta)

	# (Overspeed below the skid threshold is clamped AFTER the steering block
	# at the end of this function. An early-return snap here skipped friction,
	# dime stop and steering — and since Quake-style accel legitimately
	# overshoots magnitude on the chord mid-turn, the snap fired every other
	# frame and froze the heading on those frames: measured 0.00°-turn frames
	# at exactly walk_target_speed in the 2026-06-11 turn-lag log.)

	# Source/Quake-style always-on ground friction. Bleeds hvel uniformly by
	# floor_friction (m/s²) every grounded frame, regardless of input. Walk-
	# accel below adds back along input up to walk_target_speed; equilibrium
	# at full forward input = walk_target_speed.
	#
	# Why: gravity is always applied (even when grounded), so slope-tangent
	# slide accumulates whenever input is blocked — e.g., pushing into a wall
	# on a slope. The previous input-gated friction only fired with zero
	# input, so this slide grew unchecked. PM_Friction in HL/Quake runs every
	# grounded frame; net forward accel becomes (accel - floor_friction)
	# instead of (accel), so the controller feels slightly less snappy on
	# straight-line accel — tune ACCEL_FRICTION_RATIO if needed.
	if hspeed > 0.001:
		var drop := floor_friction * delta
		var new_speed := maxf(0.0, hspeed - drop)
		hvel *= new_speed / hspeed
		hspeed = new_speed

	# Dime stop: project input onto any wall contact surface (static or dynamic).
	# If the wall-projected input opposes the current velocity, dime stop.
	# Wall-projected dime stop fires at any speed (below skid) because wall
	# sliding speed isn't capped the same way on dynamic bodies.
	# Non-wall dime stop uses dime_stop_speed threshold.
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
					# Yielding bodies dime-stop proportionally to their
					# resistance — a light crate isn't a wall, an
					# infinitely heavy one is exactly a wall.
					var wf := 1.0
					if c["body"] is RigidBody3D:
						var wm: float = (c["body"] as RigidBody3D).mass
						wf = wm / (wm + 70.0)
					check_dir = check_dir - wnh * into * wf
					if wf >= 0.999 and check_dir.length_squared() > 0.001:
						check_dir = check_dir.normalized()
						wall_projected = true
					break
		var vel_along := hvel.dot(check_dir)
		var just_landed := _is_grounded and not _was_grounded
		if vel_along < 0.0 and (wall_projected or just_landed or hspeed <= dime_stop_speed):
			hvel -= check_dir * vel_along
			hspeed = hvel.length()

	# Accelerate toward the WALL-TANGENT target velocity. The push direction
	# is the clipped direction (wall-tangent), not raw input — so the
	# velocity we write has no into-wall component and Jolt's solver has
	# nothing to clip. This is the canonical collide-and-slide pattern:
	# script-side clip BEFORE the solver, not solver-side depen after.
	# Adds along the target direction up to walk_target_speed; perpendicular
	# velocity (lateral momentum, knockback) is preserved. When target is
	# zero (player wedged with no valid sliding direction), normalized()
	# returns zero, the dot product is zero, and the < check fails — no
	# acceleration is added. No special case needed.
	var target_dir := walk_target_velocity.normalized()
	var vel_toward_target := hvel.dot(target_dir)
	if vel_toward_target < walk_target_speed:
		var speed_add := accel * delta
		var new_toward := minf(vel_toward_target + speed_add, walk_target_speed)
		hvel += target_dir * (new_toward - vel_toward_target)

	# Landing-grip / overspeed clamp — POST-steer, so turning never skips an
	# input frame. Below the skid threshold, grounded friction is in the
	# instant-grip regime: any speed beyond the (wall-projected) walk target
	# snaps down to it in the same frame. This is what makes a landing
	# redirect grip instead of sliding down the hill; genuine overspeed
	# (≥ skid_threshold) took the skid branch above and never reaches here.
	# Mid-turn chord overshoot from the walk-accel block gets re-capped each
	# frame, so the trig wall cap and the running cap both hold exactly.
	var final_speed := hvel.length()
	if final_speed > walk_target_speed:
		hvel *= walk_target_speed / final_speed
	return hvel


func _process_skid(hvel: Vector3, hspeed: float, input_dir: Vector3, delta: float) -> Vector3:
	## Skid mode: steer + decelerate. Steering uses the same acceleration
	## as normal movement — add accel along input, normalize back to current
	## speed. This makes skid turning feel identical to ground turning.
	var floor_friction := current_floor_friction()
	# Steer: add acceleration along input, then normalize to preserve speed
	hvel += input_dir * (floor_friction * ACCEL_FRICTION_RATIO) * delta
	hvel = hvel.normalized() * hspeed

	# Friction: decelerate toward max speed
	var new_speed := maxf(hspeed - floor_friction * delta, 0.0)

	return hvel.normalized() * new_speed


func _process_air_movement(hvel: Vector3, hspeed: float, direction: Vector3, walk_target_speed: float, accel: float, delta: float) -> Vector3:
	if direction == Vector3.ZERO:
		return hvel  # No air friction — maintain momentum

	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	# Air acceleration: accelerate in the desired direction at reduced rate
	var vel_toward_target := hvel.dot(hdir)

	if vel_toward_target < walk_target_speed:
		var speed_add := accel * delta
		var new_toward := minf(vel_toward_target + speed_add, walk_target_speed)
		hvel += hdir * (new_toward - vel_toward_target)
		# Don't let movement input increase speed. Cap to whatever we started
		# with or walk_target_speed, whichever is higher. Preserves external boosts.
		var speed_cap := maxf(walk_target_speed, hspeed)
		var new_air_speed := hvel.length()
		if new_air_speed > speed_cap:
			hvel *= speed_cap / new_air_speed

	return hvel


# ======================================================================
#  Pipeline step 5b: apply_cv_move — hand the desired velocity to the
#  CharacterVirtual, which does the swept collide-and-slide + ground snap +
#  stair-step, then copy the resolved position/velocity back onto the player.
#  This is the SINGLE collision authority. Called after the movement branch
#  has set player.velocity (normal/slide/crouch). Grapple calls it with
#  add_gravity=false (it applies its own swing gravity); kamikaze and the
#  demon-catch animation bypass it entirely (they own their position).
# ======================================================================

func apply_cv_move(delta: float, add_gravity: bool = true) -> void:
	# Gravity is folded in EVERY frame — the CharacterVirtual is the single
	# collision authority and its custom OnContactSolve (C++) handles the rest:
	# on a walkable contact it re-seats the velocity onto the slope (so the
	# gravity term doesn't creep you downhill and you keep horizontal speed up/
	# down slopes); on a non-walkable contact JPH's own solver already cancels
	# velocity towards the slope (so walk-accel can't climb it) and gravity here
	# drags you down it. So there's no script-side gravity-skipping / slope-proj
	# / wall-proj any more — nothing here can disagree with the CV.
	var has_cv := _wall_oracle != null and _wall_oracle.is_inside_tree() and _wall_oracle.has_method("extended_update")
	var desired: Vector3 = player.velocity
	if add_gravity:
		desired.y -= player.gravity * delta

	_dbg_cur["move_cv_desired"] = desired

	var _cvdbg := (player.peer_id == 1 and _cv_dbg_frames < 900)
	if _cvdbg:
		_cv_dbg_frames += 1
	var _gn_dbg: Vector3 = _wall_oracle.get_ground_normal() if has_cv else Vector3.UP
	var _idir_dbg: Vector2 = player.player_input.input_direction if player.player_input != null else Vector2.ZERO

	if not has_cv:
		# No CharacterVirtual available — integrate manually so the player at
		# least moves (no collision; should not happen in a Jolt build).
		if _cvdbg:
			print("[CVMOVE %3d] FALLBACK (no CV) desired=%v ppos=%v" % [_cv_dbg_frames, desired, player.global_position])
		player.global_position += desired * delta
		player.velocity = desired
		return

	# The CV's capsule is centered on its node; the player body's origin is at
	# the feet, so the CV node sits at the player's position plus the capsule-
	# center offset (the CollisionShape3D's local offset, ~(0, h/2, 0)).
	var center_offset: Vector3 = player.to_global(_oracle_shape_offset) - player.global_position
	var ppos_in: Vector3 = player.global_position
	_wall_oracle.global_position = player.global_position + center_offset
	# WalkStairs (Jolt's step-over heuristic) is disabled for now: in tight
	# ramp-against-wall corners it climbs the ramp you're already standing on a
	# little each frame ("rides up the wall"). step_up=0 skips WalkStairs
	# entirely; passing STEP_UP_HEIGHT as the step-down arg keeps StickToFloor's
	# downward reach at the same 0.45 m, so ground-snap on small ridges is
	# unchanged. (Trade-off: the capsule now snags on block steps until WalkStairs
	# is re-enabled with a tighter stair-vs-wall check.)
	# While the unified capture toggle (F3/F8/F9) is active, request one frame of
	# C++ [CV-CAP] logging each physics tick. Pressing the key again flips the
	# toggle off and the C++ side stops on its next move() call.
	if GameManager.debug_combined_capture_active and _wall_oracle.has_method("start_debug_capture"):
		_wall_oracle.start_debug_capture(1)
	_wall_oracle.extended_update(desired, delta, Vector3(0.0, -player.gravity, 0.0), 0.0, STEP_UP_HEIGHT)
	player.global_position = _wall_oracle.get_character_position() - center_offset

	# Carry the *resolved* velocity forward = the actual displacement / dt.
	# JPH::CharacterVirtual::Update only clips the displacement, never writes the
	# clipped velocity back, so the position delta IS the resolved velocity (and
	# it's self-limiting — bounded by geometry — so the gravity term can't run
	# away while grounded). StickToFloor / WalkStairs nudges show up here too;
	# that's fine, they're real position changes.
	player.velocity = (player.global_position - ppos_in) / delta

	if _cvdbg:
		var _hin := Vector2(desired.x, desired.z).length()
		var _hout := Vector2(player.velocity.x, player.velocity.z).length()
		print("[CVMOVE %3d] gnd=%s via=%s pjr=%s snap=%.3f gn=%v idir=%v desired=%v hin=%.2f gs_out=%d contacts=%d ppos_out=%v vel_out=%v hout=%.2f" % [
			_cv_dbg_frames, str(_is_grounded), str(_dbg_cur.get("pre_grounded_via", "?")), str(_post_jump_rising),
			float(_dbg_cur.get("pre_snapped_down", 0.0)), _gn_dbg, _idir_dbg, desired, _hin,
			int(_wall_oracle.get_ground_state()), _wall_oracle.get_contacts().size(), player.global_position, player.velocity, _hout])
		# A "stop" — running fast (hin > 2) but the CV barely moved us (hout
		# collapsed to < 30% of hin). Dump every contact so we can see what we
		# hit (a real wall vs. a curb WalkStairs should've cleared vs. a sensor).
		if _hin > 2.0 and _hout < _hin * 0.3:
			var _cs: Array = _wall_oracle.get_contacts()
			var _cstr := ""
			for _c in _cs:
				var _sn: Vector3 = _c.get("surface_normal", Vector3.ZERO)
				var _cn: Vector3 = _c.get("contact_normal", Vector3.ZERO)
				var _col = _c.get("collider")
				_cstr += "  [%s sn=%v θ=%.0f° cn=%v d=%.3f sensor=%s]" % [
					((_col as Node).name if _col is Node else "?"), _sn, rad_to_deg(_sn.angle_to(Vector3.UP)),
					_cn, float(_c.get("distance", 9.0)), str(_c.get("is_sensor", false))]
			print("[CVSTOP %3d] hin=%.2f→hout=%.2f desired=%v vel_out=%v gn=%v contacts(%d):%s" % [
				_cv_dbg_frames, _hin, _hout, desired, player.velocity, _gn_dbg, _cs.size(), _cstr])

	_dbg_cur["move_cv_pos"] = player.global_position
	_dbg_cur["move_cv_vel"] = player.velocity
	_dbg_cur["move_cv_ground_state"] = int(_wall_oracle.get_ground_state())


# ======================================================================
#  Pipeline step 5c (LEGACY — unused now that apply_cv_move owns the move):
#  apply_snap_and_gravity. Kept so the old toggles/tests don't break.
# ======================================================================

func apply_snap_and_gravity(delta: float) -> void:
	Profiler.begin("movement_snap_gravity")
	## Snap to ground when briefly airborne, otherwise apply gravity.
	## Called AFTER all movement branches (slide/crouch/normal) so it
	## runs unconditionally every frame.
	if GameManager.debug_gravity_always:
		# Test toggle: apply world-Y gravity unconditionally every frame.
		# Bypasses the grounded conditional (which normally skips gravity
		# on static contacts and applies normal-aligned bias on dynamic).
		player.velocity.y -= player.gravity * delta
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_grav_branch"] = "always_on"
			_dbg_cur["ws_post_grav_vel"] = player.velocity
		Profiler.end("movement_snap_gravity")
		return
	if _is_grounded:
		# Grounded on a walkable floor: the velocity is already tangent to the
		# floor (slope_proj sets vel.y; the collide-and-slide pass below keeps
		# it tangent while clipping walls). Applying world-Y gravity on top
		# would break that tangency — the capsule sinks, Jolt depen pops it
		# back, stutter — and on a sloped floor it accumulates as downhill
		# drift (nothing cancels the tangent component of a vertical pull).
		# Snap + slope-proj hold elevation; an overhang above the head is
		# handled by the wall projection, not by gravity. So: no gravity.
		if GameManager.debug_floor_diag:
			print("[FD] apply_snap_and_gravity: grounded vel_out=(%.4f,%.4f,%.4f)" % [
				player.velocity.x, player.velocity.y, player.velocity.z])
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_grav_branch"] = "grounded_skip"
			_dbg_cur["ws_post_grav_vel"] = player.velocity
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
	# Test toggle: bypass snap entirely. For wedge-cause isolation — does the
	# stutter persist with snap fully off?
	if GameManager.debug_no_snap:
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_snap_result"] = "disabled"
		Profiler.end("movement_try_snap")
		return false
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
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_pre_snap_pos"] = player.global_position
		_dbg_cur["ws_pre_snap_vel"] = player.velocity
		_dbg_cur["ws_chk_pre_snap_pos"] = player.global_position
		_dbg_cur["ws_chk_pre_snap_vel"] = player.velocity
	if _post_jump_rising:
		if flicker_frame:
			print("[SNAP-FLICKER] SKIPPED: _post_jump_rising=true (timer=%.3f) vel_y=%.4f" % [
				_post_jump_timer, player.velocity.y])
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_snap_result"] = "skipped_post_jump_rising"
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
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_snap_dist"] = snap_dist
	if _do_snap(snap_dist):
		if flicker_frame:
			print("[SNAP-FLICKER]   → RECOVERED via snap")
		if GameManager.debug_wedge_stutter:
			_dbg_cur["ws_snap_result"] = "snapped"
			_dbg_cur["ws_post_snap_pos"] = player.global_position
			_dbg_cur["ws_post_snap_vel"] = player.velocity
		Profiler.end("movement_try_snap")
		return true
	if GameManager.debug_wedge_stutter:
		_dbg_cur["ws_snap_result"] = "miss"
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

	# Ground-truth downcast: independent of Jolt's contact list. Casts a
	# capsule downward 50cm from the player's current position and reports
	# what surface it actually finds. Useful to spot phantom contacts
	# (Jolt reports a contact that isn't really there), missing contacts
	# (Jolt drops a real one), or capsule penetration into terrain (cast
	# returns fraction 0 = already overlapping).
	if GameManager.debug_wedge_stutter:
		var dc_space := player.get_world_3d().direct_space_state
		var dc_shape: CollisionShape3D = player.get_node("CollisionShape3D")
		var dc_params := PhysicsShapeQueryParameters3D.new()
		dc_params.shape = dc_shape.shape
		dc_params.transform = dc_shape.global_transform
		dc_params.motion = Vector3(0, -0.5, 0)
		dc_params.collision_mask = player.collision_mask
		dc_params.exclude = [player.get_rid()]
		var dc_res := dc_space.cast_motion(dc_params)
		if dc_res[1] < 1.0:
			# Hit. Get rest info at the contact for normal + body name.
			var dc_rest_params := PhysicsShapeQueryParameters3D.new()
			dc_rest_params.shape = dc_params.shape
			dc_rest_params.transform = dc_params.transform
			dc_rest_params.transform.origin += dc_params.motion * dc_res[1]
			dc_rest_params.collision_mask = dc_params.collision_mask
			dc_rest_params.exclude = dc_params.exclude
			var dc_rest := dc_space.get_rest_info(dc_rest_params)
			_dbg_cur["ws_downcast_hit"] = true
			_dbg_cur["ws_downcast_safe_frac"] = dc_res[0]
			_dbg_cur["ws_downcast_unsafe_frac"] = dc_res[1]
			_dbg_cur["ws_downcast_dy_safe"] = -0.5 * dc_res[0]
			_dbg_cur["ws_downcast_dy_unsafe"] = -0.5 * dc_res[1]
			if dc_rest:
				_dbg_cur["ws_downcast_normal"] = dc_rest.normal as Vector3
				var dc_collider: Object = null
				if "collider_id" in dc_rest:
					dc_collider = instance_from_id(dc_rest.collider_id)
				if dc_collider is Node:
					_dbg_cur["ws_downcast_body"] = (dc_collider as Node).name
					_dbg_cur["ws_downcast_class"] = (dc_collider as Object).get_class()
				_dbg_cur["ws_downcast_point"] = (dc_rest.point as Vector3) if "point" in dc_rest else Vector3.ZERO
		else:
			_dbg_cur["ws_downcast_hit"] = false

	_dbg_ring.append(_dbg_cur)
	if _dbg_ring.size() > DBG_RING_SIZE:
		_dbg_ring.pop_front()

	# F8 wedge-stutter dump: per-frame multi-line trace of pos/vel deltas, full
	# contact set, and pipeline transitions. Designed for "walking into a wedge
	# with capsule-top against a downward ramp" stutter diagnosis.
	if GameManager.debug_wedge_stutter:
		_dbg_dump_wedge_stutter()

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
	_dbg_prev_floor_normal = _floor_normal
	_dbg_prev_post_pos = player.global_position
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

## Returns the friction value for a contact body in m/s² of deceleration.
## Reads from metadata "surface_friction" if present, otherwise DEFAULT_FRICTION.
## Bodies that want to be ice/oil/etc. set surface_friction to a lower number;
## sticky surfaces set it higher. null bodies (e.g., voxel terrain reported
## without a Node) get the default.
static func get_surface_friction(body: Object) -> float:
	if body == null:
		return DEFAULT_FRICTION
	if body.has_meta("surface_friction"):
		return body.get_meta("surface_friction")
	return DEFAULT_FRICTION


## Friction of the floor we're currently standing on. Walks the contact list
## for the first walkable contact and reads its surface_friction. Drives
## walk_accel, skid_threshold, dime_stop_speed, and skid deceleration.
func current_floor_friction() -> float:
	for c in _contacts:
		if c["is_walkable"]:
			return get_surface_friction(c["body"])
	return DEFAULT_FRICTION


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


# ======================================================================
#  Debug: F8 wedge-stutter per-frame dump
# ======================================================================
#
# Targets the "walking into a wedge with capsule-top against a downward ramp"
# stutter scenario. Prints per-frame:
#   - Δpos and Δvel since previous frame (the stutter signal — alternating
#     vertical motion or velocity flips here are the smoking gun)
#   - grounded state and floor normal (look for flicker frame-to-frame)
#   - full contact list (look for normals that flip between two values, or
#     for contact count toggling between 1 and 2)
#   - pipeline trace: pre-snap → snap result → process_normal_movement
#     slope projection y → apply_snap_and_gravity branch
#
# How to read the output for stutter diagnosis:
#   * Δpy oscillating sign frame-to-frame ⇒ you ARE stuttering positionally
#   * floor_normal flipping between two values ⇒ contact-listener picking
#     different walkable contacts (multi-contact wedge ambiguity)
#   * grounded toggling ⇒ briefly going airborne in the wedge
#   * contact count flickering ⇒ ramp contact lost and regained
#   * snap_result alternating "snapped"/"miss" ⇒ snap fighting with the ramp
#   * post_grav_vel.y has flipping sign ⇒ gravity branch applying then ramp
#     pushing back
func _dbg_dump_wedge_stutter() -> void:
	var pos: Vector3 = player.global_position
	var vel: Vector3 = player.velocity
	var dpos := pos - _dbg_prev_pos
	var dvel := vel - _dbg_prev_set_vel
	var fn: Vector3 = _floor_normal
	var fn_angle := rad_to_deg(fn.angle_to(Vector3.UP))

	var ground_tag := "GND" if _is_grounded else "AIR"
	var was_tag := "g" if _was_grounded else "a"
	var trans_tag := ""
	if _is_grounded != _was_grounded:
		trans_tag = " ←→TRANSITION"
	print("[WS f%d] %s(was=%s)%s  hfc=%s  n=(%.3f,%.3f,%.3f) θ=%.1f°" % [
		_dbg_frame_num, ground_tag, was_tag, trans_tag,
		str(_has_floor_contact),
		fn.x, fn.y, fn.z, fn_angle])
	print("       pos=(%.4f,%.4f,%.4f)  Δpos=(%.4f,%.4f,%.4f)" % [
		pos.x, pos.y, pos.z, dpos.x, dpos.y, dpos.z])
	print("       vel=(%.4f,%.4f,%.4f)  Δvel=(%.4f,%.4f,%.4f)" % [
		vel.x, vel.y, vel.z, dvel.x, dvel.y, dvel.z])

	# Floor-normal frame-to-frame change. >2° on a continuous surface = triangle edge.
	var prev_n: Vector3 = _dbg_cur.get("ws_prev_floor_normal", Vector3.UP)
	var n_change: float = _dbg_cur.get("ws_floor_normal_angle_change_deg", 0.0)
	var n_tag := ""
	if n_change > 2.0:
		n_tag = "  *** EDGE-CROSS ***"
	print("       prev_n=(%.3f,%.3f,%.3f) Δθ=%.2f°%s" % [prev_n.x, prev_n.y, prev_n.z, n_change, n_tag])

	# ── Pipeline checkpoint trace: position and velocity at each stage ──
	# Position is only modified by snap (in script) and Jolt (during the
	# physics step). Velocity is modified at every stage. The deltas localize
	# where any jitter originates: a non-zero Δsnap_pos = snap teleport;
	# Δjolt_pos = physics step (depen + integration).
	if _dbg_cur.has("ws_chk_pre_snap_pos"):
		var p_pre_snap: Vector3 = _dbg_cur["ws_chk_pre_snap_pos"]
		var p_post_snap: Vector3 = _dbg_cur.get("ws_chk_post_snap_pos", p_pre_snap)
		var p_post_norm: Vector3 = _dbg_cur.get("ws_chk_post_norm_move_pos", p_post_snap)
		var p_end: Vector3 = _dbg_cur.get("post_pos", p_post_norm)
		var d_snap: Vector3 = p_post_snap - p_pre_snap
		var d_script: Vector3 = p_post_norm - p_post_snap
		var d_jolt: Vector3 = p_end - p_post_norm
		print("       pos chain: pre_snap=(%.4f,%.4f,%.4f) post_snap=(%.4f,%.4f,%.4f) post_norm=(%.4f,%.4f,%.4f) end=(%.4f,%.4f,%.4f)" % [
			p_pre_snap.x, p_pre_snap.y, p_pre_snap.z,
			p_post_snap.x, p_post_snap.y, p_post_snap.z,
			p_post_norm.x, p_post_norm.y, p_post_norm.z,
			p_end.x, p_end.y, p_end.z])
		print("              Δsnap=(%+.5f,%+.5f,%+.5f)  Δscript=(%+.5f,%+.5f,%+.5f)  Δjolt=(%+.5f,%+.5f,%+.5f)" % [
			d_snap.x, d_snap.y, d_snap.z,
			d_script.x, d_script.y, d_script.z,
			d_jolt.x, d_jolt.y, d_jolt.z])
		# Velocity chain (full Vector3, all stages)
		var v_pre_snap: Vector3 = _dbg_cur.get("ws_chk_pre_snap_vel", Vector3.ZERO)
		var v_post_snap: Vector3 = _dbg_cur.get("ws_chk_post_snap_vel", v_pre_snap)
		var v_post_begin: Vector3 = _dbg_cur.get("ws_chk_post_begin_vel", v_post_snap)
		var v_post_norm: Vector3 = _dbg_cur.get("ws_chk_post_norm_move_vel", v_post_begin)
		var v_post_grav: Vector3 = _dbg_cur.get("ws_post_grav_vel", v_post_norm)
		var v_end: Vector3 = _dbg_cur.get("post_vel", v_post_grav)
		print("       vel chain: pre_snap=(%.3f,%.3f,%.3f) post_snap=(%.3f,%.3f,%.3f) post_begin=(%.3f,%.3f,%.3f)" % [
			v_pre_snap.x, v_pre_snap.y, v_pre_snap.z,
			v_post_snap.x, v_post_snap.y, v_post_snap.z,
			v_post_begin.x, v_post_begin.y, v_post_begin.z])
		print("                  post_norm=(%.3f,%.3f,%.3f) post_grav=(%.3f,%.3f,%.3f) end=(%.3f,%.3f,%.3f)" % [
			v_post_norm.x, v_post_norm.y, v_post_norm.z,
			v_post_grav.x, v_post_grav.y, v_post_grav.z,
			v_end.x, v_end.y, v_end.z])

	# Jolt depen impulse breakdown — separates floor vs wall contributions
	# so we can spot when a slightly-upward wall is producing a recurring
	# upward Y impulse against gravity (oscillation source).
	if _dbg_cur.has("ws_jolt_wall_imp_total"):
		var wi: Vector3 = _dbg_cur["ws_jolt_wall_imp_total"]
		var fi: Vector3 = _dbg_cur["ws_jolt_floor_imp_total"]
		var jdv: Vector3 = _dbg_cur.get("ws_vel_jolt_delta", Vector3.ZERO)
		var jdv_tag: String = ""
		if absf(jdv.x) > 0.05 or absf(jdv.y) > 0.05 or absf(jdv.z) > 0.05:
			jdv_tag = "  *** Jolt-Δvel non-trivial ***"
		print("       jolt impulses: floor=(%.3f,%.3f,%.3f) wall=(%.3f,%.3f,%.3f)  Δvel_jolt=(%+.4f,%+.4f,%+.4f)%s" % [
			fi.x, fi.y, fi.z, wi.x, wi.y, wi.z, jdv.x, jdv.y, jdv.z, jdv_tag])
		# Per-contact impulse details (only show non-zero ones)
		var ci_summary: Array = _dbg_cur.get("ws_jolt_contact_impulses", [])
		for ci in ci_summary:
			var ci_imp: Vector3 = ci["impulse"]
			if ci_imp.length_squared() > 0.0001:
				var ci_n: Vector3 = ci["normal"]
				print("              c %s [%s] n=(%.2f,%.2f,%.2f) imp=(%.3f,%.3f,%.3f)" % [
					ci["name"], "W" if ci["walkable"] else ".",
					ci_n.x, ci_n.y, ci_n.z,
					ci_imp.x, ci_imp.y, ci_imp.z])

	# Floor-normal selection trace: which contact's normal got chosen as
	# _floor_normal, and via which branch. If the source body or branch
	# changes frame-to-frame, that's a direct flicker signal.
	if _dbg_cur.has("ws_floor_source_body"):
		var fs_body: String = _dbg_cur["ws_floor_source_body"]
		var fs_branch: String = _dbg_cur["ws_floor_source_branch"]
		var fs_changed: bool = _dbg_cur.get("ws_floor_source_changed", false)
		var fs_tag: String = ""
		if fs_changed:
			fs_tag = "  *** FLOOR-SOURCE-CHANGED ***"
		print("       floor source: body=%s branch=%s%s" % [fs_body, fs_branch, fs_tag])
		var walkable_list: Array = _dbg_cur.get("ws_walkable_contacts", [])
		if walkable_list.size() > 1:
			# Multiple walkable contacts → near-threshold flicker risk
			var parts: Array = []
			for w in walkable_list:
				parts.append("%s θ=%.1f°" % [w["body"], w["angle_deg"]])
			print("       walkable contacts (%d): %s" % [walkable_list.size(), " | ".join(parts)])

	# SDF reference normal — smoothed surface normal from noise gradient,
	# unaffected by mesh discretization. If a contact normal disagrees with
	# this by >5° on terrain, the contact is from an INTERNAL EDGE, not a face.
	if _dbg_cur.has("ws_sdf_normal"):
		var sdf_n: Vector3 = _dbg_cur["ws_sdf_normal"]
		var floor_vs_sdf: float = _dbg_cur.get("ws_floor_vs_sdf_deg", 0.0)
		var sdf_tag := ""
		if floor_vs_sdf > 5.0:
			sdf_tag = "  *** floor_n diverges from SDF by %.1f° ***" % floor_vs_sdf
		print("       sdf_n=(%.3f,%.3f,%.3f) θ=%.1f° (smooth ground-truth normal)%s" % [
			sdf_n.x, sdf_n.y, sdf_n.z, rad_to_deg(sdf_n.angle_to(Vector3.UP)), sdf_tag])

	# Vel.y attribution chain: how vel.y was modified across the frame.
	# If the bump comes from slope-proj (discrete normal change), the big
	# delta will be at "post_walkaccel → post_slope_proj". If from Jolt
	# depen, it'll be at "ws_vy_jolt_delta". If from gravity/snap, those
	# stages will show.
	var vy_pre: float = (_dbg_cur.get("ws_pre_vel", Vector3.ZERO) as Vector3).y
	var vy_jolt_dy: float = _dbg_cur.get("ws_vy_jolt_delta", 0.0)
	var vy_post_walk: float = _dbg_cur.get("ws_vy_post_walkaccel", vy_pre)
	var vy_post_slope: float = (_dbg_cur.get("ws_post_move_vel", Vector3.ZERO) as Vector3).y
	var vy_post_fix9: float = (_dbg_cur.get("ws_fix9_post_vel", Vector3.ZERO) as Vector3).y if _dbg_cur.has("ws_fix9_post_vel") else vy_post_slope
	var vy_post_grav: float = (_dbg_cur.get("ws_post_grav_vel", Vector3.ZERO) as Vector3).y
	var vy_end: float = vel.y
	print("       vel.y chain: jolt_input=%+.4f (Δjolt=%+.4f) → post_walk=%+.4f → post_slope=%+.4f → post_fix9=%+.4f → post_grav=%+.4f → end=%+.4f" % [
		vy_pre, vy_jolt_dy, vy_post_walk, vy_post_slope, vy_post_fix9, vy_post_grav, vy_end])
	# Per-stage deltas — the biggest is the one driving the bump.
	print("              Δslope=%+.4f  Δfix9=%+.4f  Δgrav=%+.4f  Δsnap=%+.4f" % [
		vy_post_slope - vy_post_walk,
		vy_post_fix9 - vy_post_slope,
		vy_post_grav - vy_post_fix9,
		vy_end - vy_post_grav])

	# Ground-truth downcast: where is the floor really, independent of contacts.
	if _dbg_cur.get("ws_downcast_hit", false):
		var dc_safe: float = _dbg_cur.get("ws_downcast_safe_frac", 1.0)
		var dc_unsafe: float = _dbg_cur.get("ws_downcast_unsafe_frac", 1.0)
		var dc_dy: float = _dbg_cur.get("ws_downcast_dy_unsafe", 0.0)
		var dc_n: Vector3 = _dbg_cur.get("ws_downcast_normal", Vector3.UP)
		var dc_n_ang: float = rad_to_deg(dc_n.angle_to(Vector3.UP))
		var dc_body: String = _dbg_cur.get("ws_downcast_body", "?")
		var dc_class: String = _dbg_cur.get("ws_downcast_class", "?")
		var dc_pt: Vector3 = _dbg_cur.get("ws_downcast_point", Vector3.ZERO)
		# Compare to Jolt's reported floor normal — if they disagree, Jolt
		# is reporting a different contact than the one directly below us.
		var jolt_vs_dc_ang: float = rad_to_deg(fn.angle_to(dc_n))
		var dc_tag := ""
		if dc_unsafe < 0.001:
			dc_tag = "  *** ALREADY-PENETRATING ***"
		elif jolt_vs_dc_ang > 1.0:
			dc_tag = "  *** JOLT≠DOWNCAST n=%.1f° ***" % jolt_vs_dc_ang
		print("       downcast: %s:%s safe=%.4f unsafe=%.4f Δy=%.4f n=(%.3f,%.3f,%.3f) θ=%.1f° pt.y=%.4f%s" % [
			dc_class, dc_body, dc_safe, dc_unsafe, dc_dy, dc_n.x, dc_n.y, dc_n.z, dc_n_ang, dc_pt.y, dc_tag])
	elif _dbg_cur.has("ws_downcast_hit"):
		print("       downcast: NO HIT within 0.5m ← capsule is airborne or floor very far below")

	# Snap pipeline trace
	var snap_result: String = _dbg_cur.get("ws_snap_result", "n/a")
	var snap_dist: float = _dbg_cur.get("ws_snap_dist", 0.0)
	if _dbg_cur.has("ws_post_snap_pos"):
		var post_snap_pos: Vector3 = _dbg_cur["ws_post_snap_pos"]
		var snap_dy := post_snap_pos.y - (_dbg_cur.get("ws_pre_snap_pos", post_snap_pos) as Vector3).y
		print("       snap: result=%s dist=%.4f Δy=%.4f" % [snap_result, snap_dist, snap_dy])
		if _dbg_cur.has("ws_snap_target_name"):
			var tn: String = _dbg_cur["ws_snap_target_name"]
			var tc: String = _dbg_cur["ws_snap_target_class"]
			var hp: Vector3 = _dbg_cur["ws_snap_hit_point"]
			var hn: Vector3 = _dbg_cur["ws_snap_hit_normal"]
			var actual_dy: float = _dbg_cur["ws_snap_actual_dy"]
			print("         target=%s:%s hit_point=(%.4f,%.4f,%.4f) actual_Δy=%.5f hit_n=(%.3f,%.3f,%.3f)" % [
				tc, tn, hp.x, hp.y, hp.z, actual_dy, hn.x, hn.y, hn.z])
	else:
		print("       snap: result=%s dist=%.4f" % [snap_result, snap_dist])

	# ── Wall-proj output trace + frame-to-frame Δ ──
	# This is the actual output that drives walk-accel, max_speed, and (via
	# hvel) slope-proj. If `Δfraction` or `plane Δ` is non-zero on a steady-
	# state frame, wall-proj's output is flickering — that flicker IS the
	# corner-jiggle source. Plane list = what got fed into the projection
	# (post-stiffness-filter); compare across frames to see what's coming
	# and going.
	if _dbg_cur.has("ws_wp_fraction"):
		var wp_disabled: bool = _dbg_cur.get("ws_wp_disabled", false)
		if wp_disabled:
			print("       wall-proj: DISABLED (debug_no_wall_proj=true) → fraction=1.0, direction unchanged")
		else:
			var wp_frac: float = _dbg_cur["ws_wp_fraction"]
			var wp_prev_frac: float = _dbg_cur.get("ws_wp_prev_fraction", 1.0)
			var wp_dir: Vector3 = _dbg_cur["ws_wp_direction"]
			var wp_prev_dir: Vector3 = _dbg_cur.get("ws_wp_prev_direction", Vector3.ZERO)
			var wp_planes: Array = _dbg_cur.get("ws_wp_planes", [])
			var wp_prev_planes: Array = _dbg_cur.get("ws_wp_prev_planes", [])
			var wp_dyn: float = _dbg_cur.get("ws_wp_dyn_fraction", 0.0)
			var dfrac: float = wp_frac - wp_prev_frac
			var ddir_deg: float = 0.0
			if wp_dir != Vector3.ZERO and wp_prev_dir != Vector3.ZERO:
				var dir_dot: float = clampf(wp_dir.dot(wp_prev_dir), -1.0, 1.0)
				ddir_deg = rad_to_deg(acos(dir_dot))
			# Plane-set diff: which bodies entered, which left.
			var prev_names: Array = []
			for pp in wp_prev_planes:
				prev_names.append(pp.get("body_name", "?"))
			var cur_names: Array = []
			for pp in wp_planes:
				cur_names.append(pp.get("body_name", "?"))
			var entered: Array = []
			for nm in cur_names:
				if not (nm in prev_names):
					entered.append(nm)
			var left: Array = []
			for nm in prev_names:
				if not (nm in cur_names):
					left.append(nm)
			var flick_tag: String = ""
			if absf(dfrac) > 0.05 or ddir_deg > 1.0 or entered.size() > 0 or left.size() > 0:
				flick_tag = "  *** WP-FLICKER ***"
			print("       wall-proj: fraction=%.3f (Δ=%+.3f) dir=(%.3f,%.3f,%.3f) Δdir=%.1f° dyn_frac=%.2f planes=%d%s" % [
				wp_frac, dfrac, wp_dir.x, wp_dir.y, wp_dir.z, ddir_deg, wp_dyn, wp_planes.size(), flick_tag])
			if entered.size() > 0 or left.size() > 0:
				print("                  plane Δ: entered=%s left=%s" % [str(entered), str(left)])
			for i in wp_planes.size():
				var pp: Dictionary = wp_planes[i]
				var nn: Vector3 = pp["normal"]
				var ang: float = rad_to_deg(nn.angle_to(Vector3.UP))
				print("                  [%d] %s n=(%.3f,%.3f,%.3f) θ=%.1f°" % [
					i, pp["body_name"], nn.x, nn.y, nn.z, ang])
	# Walk-accel target & effect: what speed/direction was walk-accel chasing,
	# and what did it produce? hvel oscillating means target is oscillating.
	if _dbg_cur.has("ws_walk_target_hvel"):
		var t_hvel: Vector3 = _dbg_cur["ws_walk_target_hvel"]
		var t_speed: float = _dbg_cur.get("ws_walk_max_speed", 0.0)
		var hvel_b: Vector3 = _dbg_cur.get("move_hvel_before", Vector3.ZERO)
		var hvel_a: Vector3 = _dbg_cur.get("move_hvel_after", Vector3.ZERO)
		var dh: Vector3 = hvel_a - hvel_b
		var t_h_mag: float = Vector3(t_hvel.x, 0.0, t_hvel.z).length()
		print("       walk-accel: max_speed=%.2f target_hvel=(%.3f,_,%.3f) |t_h|=%.3f" % [
			t_speed, t_hvel.x, t_hvel.z, t_h_mag])
		print("                   hvel before=(%.3f,_,%.3f) → after=(%.3f,_,%.3f)  Δhvel=(%+.3f,_,%+.3f)" % [
			hvel_b.x, hvel_b.z, hvel_a.x, hvel_a.z, dh.x, dh.z])

	# Slope-projection trace
	if _dbg_cur.get("move_slope_projected", false):
		var sn: Vector3 = _dbg_cur.get("move_slope_normal", Vector3.ZERO)
		var sy: float = _dbg_cur.get("move_surface_y", 0.0)
		print("       slope_proj: surface_y=%.4f n=(%.3f,%.3f,%.3f)" % [sy, sn.x, sn.y, sn.z])
		# Y-trajectory: predicted (post slope_proj kinematic) vs SDF (true) vs actual post.
		# - predicted_y > sdf_y → slope_proj over-predicted upward; snap MUST pull down.
		# - sdf_y > predicted_y → slope_proj under-predicted; capsule will float into the hill.
		# - actual_post_y vs both shows which mechanism (snap, Jolt depen, gravity) won.
		if _dbg_cur.has("ws_predicted_pos_y"):
			var pos_now: Vector3 = _dbg_cur["ws_pos_now"]
			var pred_y: float = _dbg_cur["ws_predicted_pos_y"]
			var sdf_y: float = _dbg_cur["ws_sdf_y_now"]
			var post_pos: Vector3 = _dbg_cur.get("post_pos", pos_now)
			var pred_vs_sdf := pred_y - sdf_y
			var actual_vs_pred := post_pos.y - pred_y
			var actual_vs_sdf := post_pos.y - sdf_y
			print("       y-traj: pos_now.y=%.5f pred.y=%.5f sdf.y=%.5f post.y=%.5f" % [
				pos_now.y, pred_y, sdf_y, post_pos.y])
			print("              pred-sdf=%+.5f  post-pred=%+.5f  post-sdf=%+.5f" % [
				pred_vs_sdf, actual_vs_pred, actual_vs_sdf])
	else:
		var move_type: String = _dbg_cur.get("move_type", "?")
		print("       slope_proj: SKIPPED (move_type=%s, _has_floor_contact=%s)" % [
			move_type, str(_has_floor_contact)])

	# Gravity branch trace
	var grav_branch: String = _dbg_cur.get("ws_grav_branch", "airborne_or_skipped")
	if _dbg_cur.has("ws_post_grav_vel"):
		var post_grav: Vector3 = _dbg_cur["ws_post_grav_vel"]
		print("       grav: branch=%s post_vel.y=%.4f" % [grav_branch, post_grav.y])
	else:
		print("       grav: branch=%s" % grav_branch)

	# Full contact set, with vel·n entry value and contact world position
	var contacts: Array = _dbg_cur.get("ws_contacts", [])
	if contacts.is_empty():
		print("       contacts: (none)")
	else:
		print("       contacts: %d" % contacts.size())
		for i in contacts.size():
			var c: Dictionary = contacts[i]
			var n: Vector3 = c["normal"]
			var nang := rad_to_deg(n.angle_to(Vector3.UP))
			var flags := ""
			if c["is_walkable"]:
				flags += "W"
			else:
				flags += "·"
			if c["is_jumpable"]:
				flags += "J"
			else:
				flags += "·"
			if c["is_dynamic"]:
				flags += "D"
			else:
				flags += "·"
			var wp: Vector3 = c.get("world_pos", Vector3.ZERO)
			var vdn: float = c.get("vel_dot_n", 0.0)
			print("         [%d] %s [%s:%s] n=(%.3f,%.3f,%.3f) θ=%.1f° wp=(%.3f,%.3f,%.3f) vel·n_pre=%+.4f" % [
				i, flags, c["body_class"], c["body_name"],
				n.x, n.y, n.z, nang,
				wp.x, wp.y, wp.z, vdn])
			# Internal-edge probe result: face normal at the contact point
			# vs the reported contact normal. Match < 5° = real face.
			# Match > 5° = contact normal is from an EDGE, not a face.
			var pf_did_hit: bool = c.get("probe_did_hit", false)
			var pf_match: float = c.get("probe_face_match_deg", -1.0)
			var pf_n: Vector3 = c.get("probe_face_n", Vector3.ZERO)
			if pf_did_hit:
				var edge_tag := ""
				if pf_match > 5.0:
					edge_tag = "  *** INTERNAL-EDGE (face_n disagrees by %.1f°) ***" % pf_match
				print("              probe: face_n=(%.3f,%.3f,%.3f) match=%.1f°%s" % [
					pf_n.x, pf_n.y, pf_n.z, pf_match, edge_tag])
			else:
				print("              probe: ray missed (contact wp may be off the surface)")

	# Oracle (JoltCharacterVirtual3D sweep) contact set — the source the
	# wall-proj actually clips against. Flags: T = in _oracle_touch (dist <= 0
	# AND not a sensor), S = sensor/Area (pickup, trigger — filtered out),
	# W = walkable surface (angle to UP <= 50°, so wall-proj ignores it),
	# C = below curb threshold (pos.y < min_y → treated as a step rolled over,
	# wall-proj ignores it), R = dynamic body. A contact the wall-proj clips
	# against is one that is T and not W and not C.
	var ora: Array = _dbg_cur.get("ws_oracle", [])
	var omin_y: float = _dbg_cur.get("ws_oracle_min_y", -1e9)
	if ora.is_empty():
		print("       oracle: 0 contacts (min_y=%.3f)" % omin_y)
	else:
		print("       oracle: %d contacts (touch-cutoff dist<=%.3f, curb min_y=%.3f)" % [ora.size(), _ORACLE_TOUCH_EPS, omin_y])
		for oc in ora:
			var osn: Vector3 = oc["sn"]
			var ocn: Vector3 = oc["cn"]
			var odist: float = oc["dist"]
			var opos: Vector3 = oc["pos"]
			var is_sensor: bool = oc.get("is_sensor", false)
			var osn_ang := rad_to_deg(osn.angle_to(Vector3.UP)) if osn != Vector3.ZERO else -1.0
			var is_touch := odist <= _ORACLE_TOUCH_EPS and not is_sensor
			var is_walk := osn != Vector3.ZERO and osn.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE
			var is_curb := opos.y < omin_y
			var oflags := ""
			oflags += "T" if is_touch else "·"
			oflags += "S" if is_sensor else "·"
			oflags += "W" if is_walk else "·"
			oflags += "C" if is_curb else "·"
			oflags += "R" if oc.get("is_rb", false) else "·"
			var clip_tag := "  <<< CLIPPED BY WALL-PROJ" if (is_touch and not is_walk) else ""
			var sn_cn_tag := ""
			if osn != Vector3.ZERO and ocn != Vector3.ZERO:
				var disagree := rad_to_deg(osn.angle_to(ocn))
				if disagree > 5.0:
					sn_cn_tag = "  (avg-vs-face disagree %.1f°)" % disagree
			print("         %s [%s] surf_n=(%.3f,%.3f,%.3f) θ=%.1f° cont_n=(%.3f,%.3f,%.3f) dist=%+.4f pos=(%.3f,%.3f,%.3f)%s%s" % [
				oflags, oc["name"],
				osn.x, osn.y, osn.z, osn_ang,
				ocn.x, ocn.y, ocn.z, odist,
				opos.x, opos.y, opos.z, clip_tag, sn_cn_tag])

	# Post-pipeline vel·n for each non-walkable contact (after walk-accel +
	# slope-proj). Compare to the pre value above: if pre was small + and
	# post is larger +, slope projection is amplifying drift. If post is
	# zero, the cancellation is happening in GDScript and the issue is
	# elsewhere (Jolt reporting). If post is large +, drift is going into
	# the physics step → next frame's contact loss is drift-driven.
	var post_dots: Array = _dbg_cur.get("ws_post_pipeline_wall_dots", [])
	if not post_dots.is_empty():
		var parts: Array = []
		for d in post_dots:
			parts.append("%s vel·n_post=%+.4f" % [d["name"], d["vel_dot_n"]])
		print("       post-pipeline wall dots: %s" % " | ".join(parts))

	# Fix 8 (full-3D wall-proj) state. If active, prints whether it fired,
	# total correction magnitude, and the post-fix vel·n for each non-walk
	# contact (should be ~0). If not active, prints "OFF" so we can tell
	# at a glance whether the toggle was on during capture.
	if _dbg_cur.get("ws_fix8_active", false):
		var f8_count: int = _dbg_cur.get("ws_fix8_fired_count", 0)
		var f8_corr: float = _dbg_cur.get("ws_fix8_total_correction", 0.0)
		var f8_vel: Vector3 = _dbg_cur.get("ws_post_fix8_vel", Vector3.ZERO)
		var post_fix_dots: Array = []
		for c in _contacts:
			if c["is_walkable"]:
				continue
			var cn: Vector3 = c["normal"]
			var nm: String = ((c["body"] as Node).name if c["body"] is Node else "?")
			post_fix_dots.append("%s vel·n_postfix=%+.5f" % [nm, f8_vel.dot(cn)])
		print("       fix8: fired=%d total_corr=%+.5f post_fix_vel=(%.4f,%.4f,%.4f) | %s" % [
			f8_count, f8_corr, f8_vel.x, f8_vel.y, f8_vel.z, " | ".join(post_fix_dots)])
	elif _dbg_cur.has("ws_fix8_active"):
		print("       fix8: OFF (toggle not enabled)")

	# Fix 9 (joint compound-contact projection) state
	if _dbg_cur.get("ws_fix9_active", false):
		# Walkable pass: max-slope-proj across walkable secondary contacts
		var walk_pre: float = _dbg_cur.get("ws_fix9_walk_vy_pre", 0.0)
		var walk_post: float = _dbg_cur.get("ws_fix9_walk_vy_post_walkpass", walk_pre)
		var walk_max_n: Vector3 = _dbg_cur.get("ws_fix9_walk_max_n", Vector3.ZERO)
		if walk_max_n != Vector3.ZERO:
			print("       fix9 walk-pass: vy %+.4f → %+.4f (Δ=%+.4f)  driver_n=(%.3f,%.3f,%.3f)" % [
				walk_pre, walk_post, walk_post - walk_pre, walk_max_n.x, walk_max_n.y, walk_max_n.z])
		# Wedge-pass (non-walkable secondary, one-sided correction)
		if _dbg_cur.has("ws_fix9_correction_dir"):
			var corr_dir: Vector3 = _dbg_cur["ws_fix9_correction_dir"]
			var into_amt: float = _dbg_cur["ws_fix9_into_amount"]
			var n_other: Vector3 = _dbg_cur["ws_fix9_n_other"]
			var pre_v: Vector3 = _dbg_cur["ws_fix9_pre_vel"]
			var post_v: Vector3 = _dbg_cur["ws_fix9_post_vel"]
			var n_floor_check: float = post_v.dot(_floor_normal)
			var n_other_check: float = post_v.dot(n_other)
			print("       fix9 wedge-pass (one-sided): into=%+.4f  corr_dir=(%.3f,%.3f,%.3f)  vel·n_floor=%+.5f vel·n_other=%+.5f" % [
				into_amt, corr_dir.x, corr_dir.y, corr_dir.z, n_floor_check, n_other_check])
			print("            pre=(%.4f,%.4f,%.4f) post=(%.4f,%.4f,%.4f) Δ=(%.4f,%.4f,%.4f)" % [
				pre_v.x, pre_v.y, pre_v.z,
				post_v.x, post_v.y, post_v.z,
				post_v.x - pre_v.x, post_v.y - pre_v.y, post_v.z - pre_v.z])
		elif _dbg_cur.get("ws_fix9_degenerate", false):
			print("       fix9 wedge-pass: degenerate (n_other parallel to n_floor)")
		elif _dbg_cur.get("ws_fix9_already_separating", false):
			print("       fix9 wedge-pass: secondary present but vel·n ≥ 0 (separating, no correction)")
		elif _dbg_cur.get("ws_fix9_no_other", false) and walk_max_n == Vector3.ZERO:
			print("       fix9: no secondary contact — slope-proj alone applies")
	elif _dbg_cur.has("ws_fix9_active"):
		print("       fix9: OFF (toggle not enabled)")

	# Lost-contact probes (bodies that were in contact last frame but aren't
	# this frame). Probe asks: does the capsule STILL overlap that body at
	# the current position?
	var probes: Array = _dbg_cur.get("ws_lost_contact_probes", [])
	if not probes.is_empty():
		for p in probes:
			var verdict := "STILL_OVERLAP — Jolt dropped a real contact" if p["overlap_at_capsule_pos"] else "no_overlap — capsule actually separated (drift)"
			print("       LOST CONTACT: %s:%s → %s" % [p["body_class"], p["body_name"], verdict])
			if p["overlap_at_capsule_pos"]:
				var rn: Vector3 = p["rest_normal"]
				print("         rest_normal=(%.3f,%.3f,%.3f)" % [rn.x, rn.y, rn.z])


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
