extends Node
class_name GrappleSystem

## Grappling Hook — position-based constraint pendulum.
##
## Based on Jamie Fristrom's Spider-Man 2 technique: the rope is an invisible
## spherical wall.  Each frame we predict where the player will be, snap that
## position onto the sphere surface if it overshoots, and derive the new
## velocity from the corrected position.  The outward radial velocity is
## automatically eliminated; what remains is tangential (the swing).
##
## On the ground, move_and_slide() blocks the downward component of the
## derived velocity, so the constraint correction becomes horizontal — the
## player glides forward.  In the air, the full 3D correction applies.
## There is no ground/air branching — the transition is seamless.
##
## Server-authoritative: server runs all physics, clients draw the rope.

# ======================================================================
#  Constants
# ======================================================================

const MAX_GRAPPLE_RANGE := 60.0       ## Raycast distance for finding anchor
const SWING_GRAVITY := 17.5           ## Same as player gravity
## Release boost — tilts velocity upward and adds speed on release.
const RELEASE_PITCH_UP := deg_to_rad(25.0)   ## Tilt velocity 25° upward on release
const RELEASE_PITCH_MAX := deg_to_rad(30.0)  ## Never tilt above 30° upward
const RELEASE_BOOST_MIN_SPEED := 2.0         ## No boost below this speed (m/s)
const RELEASE_BOOST_MAX_SPEED := 50.0        ## Full boost at this speed (m/s)
const RELEASE_BOOST_MIN := 1.0               ## Boost at min speed (m/s)
const RELEASE_BOOST_MAX := 10.0              ## Boost at max speed (m/s)
const MIN_ROPE_LENGTH := 3.0          ## Stop reeling at this distance
const ROPE_REEL_SPEED := 3.0          ## Rope shortens this many m/s (creates pull)

## Steering — A/D rotates velocity direction, W pumps swing arc, S brakes.
const STEER_RATE := 1.8               ## A/D rotation rate (rad/s at full input)
const SWING_PUMP_STRENGTH := 8.0      ## W pumps along swing velocity (air only)

## Launch nudge — small upward kick on fire to unstick from the floor.
const LAUNCH_NUDGE_SPEED := 4.0       ## Max upward speed added on fire (m/s)
const LAUNCH_MAX_ANGLE := 60.0        ## No nudge above this angle (too vertical)

## Low-momentum inward pull — lets you scale buildings when nearly stationary.
const CLIMB_PULL_SPEED := 6.0         ## Inward pull speed when climbing (m/s)
const CLIMB_ANGULAR_THRESHOLD := 0.0873 ## Below this angular rate (rad/s ≈ 5°/s) = "stationary"
const CLIMB_DELAY := 0.5              ## Seconds of low momentum before pull activates

## Speed caps — safety nets.
const MAX_TANGENTIAL_SPEED := 50.0    ## Cap on tangential orbit speed (m/s)
const MAX_ANGULAR_RATE := 1.75        ## Max rotation rate around anchor (rad/s)
const MAX_SPEED_CAP := 35.0           ## Hard cap on total horizontal speed (m/s)
const SPEED_CAP_DRAG := 10.0          ## Drag per m/s over the cap

## Proximity dampening — reduces forces near anchor to prevent jitter.
const PROXIMITY_DAMPEN_RANGE := 8.0
const PROXIMITY_MIN_FACTOR := 0.1

## Short-rope clearance — outward push when very close to anchor.
const SHORT_ROPE_CLEARANCE := 4.0
const CLEARANCE_FORCE := 12.0

## Charge system — two grapples before cooldown.
const MAX_CHARGES := 2
const CHARGE_RECHARGE_TIME := 1.0   ## Seconds to regain one charge

## Rope line-of-sight — cut if geometry obstructs the line.
const ROPE_LOS_MARGIN := 3.0
const ROPE_LOS_INTERVAL := 1

## Pill obstruction shape — one capsule centered on the rope, split into
## two ConvexPolygonShape3D halves (left/right of the swing plane).
## Each half is a half-capsule: flat face on the split plane, hemisphere outward.
## If blocked, shrink radius and retry.
const PILL_RADIUS := 0.35             ## Capsule radius for the go-around check
const ARC_CONTACT_RADIUS := 3.0       ## Different-object contacts beyond this from center contact are ignored
const HALF_CAPSULE_SEGS := 6          ## Circumference segments for half-capsule vertices
const HALF_CAPSULE_HEMI_STEPS := 3    ## Latitude steps for the hemisphere cap
## Center sweep — a flat triangle (prev_chest, current_chest, anchor) covering
## the area the rope swept through between LOS checks.  Uses ConvexPolygonShape3D
## with 3 coplanar vertices — the physics engine treats this as a triangle.


# ======================================================================
#  Synced state (replicated via ServerSync)
# ======================================================================

var is_grappling: bool = false
var anchor_point: Vector3 = Vector3.ZERO

# ======================================================================
#  Internal state (server only)
# ======================================================================

var _rope_length: float = 0.0
var _shoot_was_held: bool = false
var _los_frame_counter: int = 0
var _was_on_floor: bool = false
var _anchor_collider_rid: RID = RID()
var _low_momentum_timer: float = 0.0  ## Tracks how long angular rate has been below threshold
var _last_los_chest: Vector3 = Vector3.ZERO  ## Player chest pos at last LOS check (for fan sweep)
var _fresh_grapple: bool = false      ## True until player first exceeds angular threshold

## Charge system
var _charges: int = MAX_CHARGES
var _recharge_timer: float = 0.0      ## Time until next charge is restored

## Boost cooldown — prevents spamming grapple for repeated boosts.
var _last_boost_time: float = -1.0    ## Engine time of last release boost (-1 = never)


## Debug timing — spike detection
var _debug_last_print_time: float = 0.0          ## Throttle prints to 1/sec
const DEBUG_SPIKE_THRESHOLD_US := 500.0           ## Print if any section takes > 500µs

# ======================================================================
#  Client VFX state
# ======================================================================

var _rope_mesh_instance: MeshInstance3D = null
var _anchor_light: OmniLight3D = null
var _rope_material: StandardMaterial3D = null
var _pill_mesh_instance: MeshInstance3D = null
var _contact_mesh_instance: MeshInstance3D = null

## Pre-cached debug materials (created once in setup, reused every frame)
var _pill_clear_left_mat: StandardMaterial3D = null      # Green (left half clear)
var _pill_clear_right_mat: StandardMaterial3D = null      # Yellow (right half clear)
var _pill_blocked_mat: StandardMaterial3D = null           # Red (half blocked)
var _pill_subdiv_clear_left_mat: StandardMaterial3D = null # Green 40% (subdivision clear)
var _pill_subdiv_clear_right_mat: StandardMaterial3D = null # Yellow 40% (subdivision clear)
var _pill_subdiv_blocked_mat: StandardMaterial3D = null    # Red 40% (subdivision blocked)
var _sweep_wire_mat: StandardMaterial3D = null             # Blue wireframe (center sweep triangle)
var _contact_center_mat: StandardMaterial3D = null         # Bright cyan (center contact)
var _contact_cloud_mat: StandardMaterial3D = null          # Dim cyan (cloud points)
var _contact_arc_mat: StandardMaterial3D = null            # Green-blue (arc contacts)
var _contact_sphere_mat: StandardMaterial3D = null         # White semi-transparent (radius sphere)

## Pill debug state — set by server obstruction check, read by client visuals.
## 0 = clear, 1 = blocked.  Index 0 = left half (swing direction), 1 = right half.
var _pill_half_blocked: Array[int] = [0, 0]
## The swing-perpendicular direction used to orient the pill halves.
var _pill_swing_normal: Vector3 = Vector3.ZERO
## Previous LOS chest position — stored for swept pill visualization.
var _prev_los_chest: Vector3 = Vector3.ZERO

## Half-capsule shapes — one ConvexPolygonShape3D per half (left/right).
## Pre-created in setup() to avoid Jolt race condition.  Vertices rebuilt
## each check to match current rope length and radius.
var _left_half_shape: ConvexPolygonShape3D = null
var _left_half_query: PhysicsShapeQueryParameters3D = null
var _right_half_shape: ConvexPolygonShape3D = null
var _right_half_query: PhysicsShapeQueryParameters3D = null

## Center sweep shape — flat triangle (ConvexPolygonShape3D, 3 coplanar verts)
## covering the area the rope swept through between LOS checks.  Rebuilt each check.
var _center_sweep_shape: ConvexPolygonShape3D = null
var _center_sweep_query: PhysicsShapeQueryParameters3D = null

## Debug: center-ray contact point (where the rope hits geometry).
var _center_contact_point: Vector3 = Vector3.ZERO
var _has_center_contact: bool = false
## Debug: contact cloud — multiple hit points on the center obstacle mapped by fan rays.
var _center_contact_cloud: Array[Vector3] = []
## Debug: RID of the center obstacle (used for same-object detection).
var _center_contact_rid: RID = RID()
## Debug: arc contact points that caused a half to be blocked (per half).
## Index 0 = left half contacts, 1 = right half contacts.
var _arc_contacts: Array[Array] = [[], []]

## Debug: on-screen label showing bend angle, wrap count, rope state.
var _debug_label: Label = null

# ======================================================================
#  Player reference
# ======================================================================

var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p
	_rope_material = StandardMaterial3D.new()
	_rope_material.albedo_color = Color(0.3, 0.6, 1.0, 1.0)
	_rope_material.emission_enabled = true
	_rope_material.emission = Color(0.2, 0.5, 1.0)
	_rope_material.emission_energy_multiplier = 2.0
	_rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Pre-cache pill half-capsule debug materials (avoids 8-13 allocations per frame)
	_pill_clear_left_mat = _make_pill_mat(Color(0.1, 1.0, 0.2, 0.15))
	_pill_clear_right_mat = _make_pill_mat(Color(1.0, 1.0, 0.1, 0.15))
	_pill_blocked_mat = _make_pill_mat(Color(1.0, 0.15, 0.1, 0.25))
	_pill_subdiv_clear_left_mat = _make_pill_mat(Color(0.1, 1.0, 0.2, 0.06))
	_pill_subdiv_clear_right_mat = _make_pill_mat(Color(1.0, 1.0, 0.1, 0.06))
	_pill_subdiv_blocked_mat = _make_pill_mat(Color(1.0, 0.15, 0.1, 0.1))

	# Pre-cache center sweep wireframe material
	_sweep_wire_mat = StandardMaterial3D.new()
	_sweep_wire_mat.albedo_color = Color(0.4, 0.75, 1.0, 0.4)
	_sweep_wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sweep_wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Pre-cache contact debug materials
	_contact_center_mat = _make_contact_mat(Color(0.2, 0.9, 1.0, 0.9))
	_contact_cloud_mat = _make_contact_mat(Color(0.15, 0.7, 0.85, 0.7))
	_contact_arc_mat = _make_contact_mat(Color(0.1, 0.8, 0.6, 0.9))
	_contact_sphere_mat = StandardMaterial3D.new()
	_contact_sphere_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.3)
	_contact_sphere_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_contact_sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_contact_sphere_mat.no_depth_test = true

	# Pre-create half-capsule shapes for pill obstruction checks
	_left_half_shape = ConvexPolygonShape3D.new()
	_left_half_query = PhysicsShapeQueryParameters3D.new()
	_left_half_query.shape = _left_half_shape
	_left_half_query.collision_mask = 1
	_left_half_query.collide_with_bodies = true
	_left_half_query.collide_with_areas = false

	_right_half_shape = ConvexPolygonShape3D.new()
	_right_half_query = PhysicsShapeQueryParameters3D.new()
	_right_half_query.shape = _right_half_shape
	_right_half_query.collision_mask = 1
	_right_half_query.collide_with_bodies = true
	_right_half_query.collide_with_areas = false

	# Pre-create center sweep shape (flat triangle, verts set each check)
	_center_sweep_shape = ConvexPolygonShape3D.new()
	_center_sweep_query = PhysicsShapeQueryParameters3D.new()
	_center_sweep_query.shape = _center_sweep_shape
	_center_sweep_query.collision_mask = 1
	_center_sweep_query.collide_with_bodies = true
	_center_sweep_query.collide_with_areas = false

	# Debug HUD label — shows bend angle, wrap count, rope state on screen
	_debug_label = Label.new()
	_debug_label.add_theme_font_size_override("font_size", 20)
	_debug_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
	_debug_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_debug_label.add_theme_constant_override("shadow_offset_x", 2)
	_debug_label.add_theme_constant_override("shadow_offset_y", 2)
	_debug_label.position = Vector2(20, 200)
	_debug_label.visible = false
	var hud_layer := player.get_node_or_null("HUDLayer")
	if hud_layer:
		hud_layer.add_child(_debug_label)


func _make_pill_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _make_contact_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	return m


func is_active() -> bool:
	return is_grappling


func _get_proximity_factor() -> float:
	var dist: float = player.global_position.distance_to(anchor_point)
	if dist >= PROXIMITY_DAMPEN_RANGE:
		return 1.0
	var t: float = dist / PROXIMITY_DAMPEN_RANGE
	var smooth: float = t * t * (3.0 - 2.0 * t)
	return lerpf(PROXIMITY_MIN_FACTOR, 1.0, smooth)


func tick_charges(delta: float) -> void:
	## Recharge grapple charges over time. Call every frame (even when not grappling).
	if _charges < MAX_CHARGES:
		_recharge_timer -= delta
		if _recharge_timer <= 0.0:
			_charges += 1
			if _charges < MAX_CHARGES:
				_recharge_timer = CHARGE_RECHARGE_TIME  # Start recharging next charge
			else:
				_recharge_timer = 0.0


func handle_shoot_input(shoot_held: bool) -> void:
	var just_pressed: bool = shoot_held and not _shoot_was_held
	_shoot_was_held = shoot_held
	if just_pressed:
		if is_grappling:
			# Boost on release unless player is holding Ctrl
			var boost: bool = not player.player_input.action_ctrl
			_do_release(boost)
		else:
			try_fire()


# ======================================================================
#  Server: fire grapple
# ======================================================================

func try_fire() -> void:
	if is_grappling:
		return

	# Check charges
	if _charges <= 0:
		return

	var space_state := player.get_world_3d().direct_space_state
	var hand_origin: Vector3 = player.global_position + Vector3(0, 1.2, 0)

	# Two-step aim: first find where the camera crosshair hits the world,
	# then fire from the hand toward that point.  This makes the grapple
	# land where the white dot shows unless terrain blocks the hand's path.
	var cam_origin: Vector3 = player.camera.global_position
	var cam_forward: Vector3 = -player.camera.global_transform.basis.z
	var aim_target: Vector3 = _get_grapple_aim_target(space_state, cam_origin, cam_forward, hand_origin)

	var to_target: Vector3 = aim_target - hand_origin
	var aim_dist: float = to_target.length()
	if aim_dist < 0.1:
		return
	var aim_dir: Vector3 = to_target / aim_dist

	# Single long ray (500m) — matches crosshair preview exactly.
	# Check hit distance afterwards instead of clamping the ray length,
	# so narrow geometry at the edge of range doesn't get missed.
	var far_point := hand_origin + aim_dir * 500.0

	var query := PhysicsRayQueryParameters3D.create(hand_origin, far_point)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return

	# Reject hits beyond grapple range
	if hand_origin.distance_to(result.position) > MAX_GRAPPLE_RANGE:
		return

	anchor_point = result.position
	_rope_length = player.global_position.distance_to(anchor_point)
	_anchor_collider_rid = result.get("rid", RID())
	_low_momentum_timer = 0.0
	_fresh_grapple = true
	is_grappling = true
	_shoot_was_held = true
	_last_los_chest = hand_origin

	# Consume a charge and start recharging
	_charges -= 1
	if _recharge_timer <= 0.0:
		_recharge_timer = CHARGE_RECHARGE_TIME

	# End crouch if active
	var slide_crouch: SlideCrouchSystem = player.slide_crouch
	if slide_crouch.is_crouching:
		slide_crouch.end_crouch()

	# Launch nudge — small upward kick scaled by rope angle
	var to_anchor_dir: Vector3 = (anchor_point - player.global_position).normalized()
	var anchor_up: float = clampf(to_anchor_dir.y, 0.0, 1.0)
	var anchor_angle_deg: float = rad_to_deg(asin(clampf(to_anchor_dir.y, -1.0, 1.0)))
	if anchor_up > 0.05 and anchor_angle_deg < LAUNCH_MAX_ANGLE:
		player.velocity.y += LAUNCH_NUDGE_SPEED * anchor_up

	var hand_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	_show_grapple_fire.rpc(hand_pos, anchor_point)
	print("Player %d fired grapple (anchor: %s, rope: %.1fm)" % [
		player.peer_id, str(anchor_point), _rope_length])


func _get_grapple_aim_target(space_state: PhysicsDirectSpaceState3D,
		cam_origin: Vector3, cam_forward: Vector3, hand_origin: Vector3) -> Vector3:
	## Find the world point the camera crosshair is looking at, then return it
	## as the aim target for the hand.  If the camera ray misses, fall back to
	## a far point along cam_forward from the hand (directional aim).
	var cam_far := cam_origin + cam_forward * 1000.0
	var cam_query := PhysicsRayQueryParameters3D.create(cam_origin, cam_far)
	cam_query.exclude = [player.get_rid()]
	cam_query.collision_mask = 1
	var cam_result := space_state.intersect_ray(cam_query)
	if not cam_result.is_empty():
		return cam_result.position
	# Camera didn't hit anything — aim along cam_forward from hand (sky shot)
	return hand_origin + cam_forward * MAX_GRAPPLE_RANGE


# ======================================================================
#  Server: swing physics — Fristrom position-based constraint
# ======================================================================

func process(delta: float) -> void:
	## Each frame:
	## 1. Apply gravity to velocity
	## 2. Apply steering to velocity
	## 3. Reel rope shorter (creates pull via constraint)
	## 4. Predict test_pos = position + velocity * delta
	## 5. If test_pos overshoots rope length, snap onto sphere surface
	## 6. Derive velocity = (snapped_pos - position) / delta
	## 7. move_and_slide() — floor/wall collisions
	##
	## On the ground, move_and_slide() blocks the downward velocity from
	## the derived result, so the player glides horizontally.  Going over
	## a cliff, the floor stops blocking — but the velocity was derived
	## from the SAME constraint correction, so there's no speed change.
	if not is_grappling:
		return

	var _t0 := Time.get_ticks_usec()

	# --- Camera look ---
	player.rotation.y = player.player_input.look_yaw
	player.camera_pivot.rotation.x = player.player_input.look_pitch

	var on_floor: bool = player.is_on_floor()
	var pos: Vector3 = player.global_position

	# --- Rope geometry ---
	var rope_dist: float = pos.distance_to(anchor_point)

	# =================================================================
	# 1. GRAVITY
	# =================================================================
	player.velocity.y -= SWING_GRAVITY * delta

	# =================================================================
	# 2. STEERING — direction only, no speed added
	# =================================================================
	var input_dir: Vector2 = player.player_input.input_direction

	# A/D: rotate horizontal velocity direction
	if absf(input_dir.x) > 0.1:
		var horiz_speed := Vector2(player.velocity.x, player.velocity.z).length()
		if horiz_speed > 0.5:
			var cam_right: Vector3 = player.camera.global_transform.basis.x
			cam_right.y = 0.0
			if cam_right.length() > 0.001:
				cam_right = cam_right.normalized()
			var turn_angle: float = STEER_RATE * input_dir.x * delta
			var vel_horiz := Vector3(player.velocity.x, 0.0, player.velocity.z)
			var vel_perp := Vector3(-vel_horiz.z, 0.0, vel_horiz.x).normalized()
			var cam_side: float = cam_right.dot(vel_perp)
			turn_angle *= signf(cam_side) if absf(cam_side) > 0.01 else 1.0
			var cos_a := cos(turn_angle)
			var sin_a := sin(turn_angle)
			var new_vx: float = player.velocity.x * cos_a - player.velocity.z * sin_a
			var new_vz: float = player.velocity.x * sin_a + player.velocity.z * cos_a
			player.velocity.x = new_vx
			player.velocity.z = new_vz

	# W: pump along swing direction
	if input_dir.y < -0.1 and player.velocity.length() > 0.5:
		var swing_dir: Vector3 = player.velocity.normalized()
		player.velocity += swing_dir * SWING_PUMP_STRENGTH * absf(input_dir.y) * delta

	# S: gentle brake
	if input_dir.y > 0.1:
		var brake: float = clampf(1.0 - 2.0 * input_dir.y * delta, 0.9, 1.0)
		player.velocity.x *= brake
		player.velocity.z *= brake

	# =================================================================
	# 2b. ADDED PULL — inward pull toward anchor when nearly stationary.
	#     Fresh grapple: pull activates immediately if below threshold.
	#     Already swinging: 0.5s timer must elapse first.
	#     Once the player exceeds the threshold, fresh status clears
	#     and the timer governs from then on.
	# =================================================================
	if rope_dist > 0.5:
		var to_anchor: Vector3 = anchor_point - pos
		var radial_dir_3d: Vector3 = to_anchor.normalized()
		var radial_speed: float = player.velocity.dot(radial_dir_3d)
		var tangential_vel: Vector3 = player.velocity - radial_dir_3d * radial_speed
		var tangential_speed: float = tangential_vel.length()
		var angular_rate: float = tangential_speed / rope_dist  # rad/s

		var below_threshold: bool = angular_rate < CLIMB_ANGULAR_THRESHOLD

		if below_threshold:
			_low_momentum_timer += delta
		else:
			_low_momentum_timer = 0.0
			_fresh_grapple = false  # Exceeded threshold — no longer fresh

		# Fresh grapple: pull immediately if below threshold
		# Already swinging: need 0.5s of low momentum first
		var should_pull: bool = below_threshold and (_fresh_grapple or _low_momentum_timer > CLIMB_DELAY)

		if should_pull:
			var pull_t: float
			if _fresh_grapple:
				# Ramp in over 0.3s from grapple start
				pull_t = clampf(_low_momentum_timer / 0.3, 0.0, 1.0)
			else:
				# Ramp in over 0.5s after delay expires
				pull_t = clampf((_low_momentum_timer - CLIMB_DELAY) / 0.5, 0.0, 1.0)
			var pull_strength: float = CLIMB_PULL_SPEED * pull_t
			player.velocity += radial_dir_3d * pull_strength * delta
	else:
		_low_momentum_timer = 0.0

	# =================================================================
	# 3. REEL ROPE — shortens over time.  On the ground, clamp to
	#    actual distance so no deficit builds up.  Ratchet: if player
	#    moved closer, shorten rope to match (keeps it taut).
	# =================================================================
	var prox: float = _get_proximity_factor()
	var reel_mult := clampf(_rope_length / SHORT_ROPE_CLEARANCE, 0.15, 1.0)
	var reel_speed: float = GameManager.debug_grapple_reel_speed
	_rope_length = maxf(_rope_length - reel_speed * reel_mult * prox * delta, MIN_ROPE_LENGTH)
	if on_floor:
		_rope_length = maxf(_rope_length, rope_dist)
	# Ratchet: rope never longer than actual distance (stays taut)
	_rope_length = minf(_rope_length, rope_dist)

	# =================================================================
	# 4-6. POSITION-BASED CONSTRAINT (Fristrom technique)
	#
	#    Predict where the player will be.  If beyond rope length, snap
	#    that position onto the sphere surface.  Derive new velocity from
	#    the corrected position.  This automatically strips the outward
	#    radial velocity and preserves tangential — no explicit force
	#    calculation needed.
	# =================================================================
	var test_pos: Vector3 = pos + player.velocity * delta
	var offset: Vector3 = test_pos - anchor_point
	var test_dist: float = offset.length()

	if test_dist > _rope_length and test_dist > 0.001:
		# Snap predicted position onto the sphere surface
		var corrected_pos: Vector3 = anchor_point + (offset / test_dist) * _rope_length
		# Derive velocity from the correction
		player.velocity = (corrected_pos - pos) / maxf(delta, 0.001)

	# --- Short-rope clearance push ---
	if _rope_length < SHORT_ROPE_CLEARANCE:
		var cur_offset: Vector3 = pos - anchor_point
		if cur_offset.length() > 0.001:
			var clearance_t: float = 1.0 - (_rope_length / SHORT_ROPE_CLEARANCE)
			clearance_t *= clearance_t
			var outward_dir: Vector3 = cur_offset.normalized()
			outward_dir.y = 0.0
			if outward_dir.length() > 0.01:
				outward_dir = outward_dir.normalized()
				player.velocity += outward_dir * CLEARANCE_FORCE * clearance_t * delta

	# --- Angular rate cap + tangential speed cap ---
	var to_player: Vector3 = pos - anchor_point
	var radial_flat := Vector3(to_player.x, 0.0, to_player.z)
	var radial_len: float = radial_flat.length()
	if radial_len > 0.5:
		var radial_dir: Vector3 = radial_flat / radial_len
		var tangent_dir := Vector3(-radial_dir.z, 0.0, radial_dir.x)
		var tang_speed: float = player.velocity.dot(tangent_dir)
		# Angular rate increases as rope shortens: tight orbits feel faster
		# ~1.75 rad/s at 20m, ~2.1 at 10m (21 m/s), ~2.45 at 5m (12 m/s)
		var effective_rope: float = maxf(_rope_length, MIN_ROPE_LENGTH)
		var dynamic_angular_rate: float = MAX_ANGULAR_RATE + 3.5 / effective_rope
		var angular_cap: float = dynamic_angular_rate * effective_rope
		var effective_cap: float = minf(MAX_TANGENTIAL_SPEED, angular_cap)
		if absf(tang_speed) > effective_cap:
			var excess: float = absf(tang_speed) - effective_cap
			player.velocity -= tangent_dir * signf(tang_speed) * excess

	# --- Horizontal speed cap (safety net) ---
	var h_speed := Vector2(player.velocity.x, player.velocity.z).length()
	if h_speed > MAX_SPEED_CAP:
		var excess_h: float = h_speed - MAX_SPEED_CAP
		var drag_h: float = excess_h * SPEED_CAP_DRAG * delta
		var new_h: float = maxf(h_speed - drag_h, MAX_SPEED_CAP)
		var ratio: float = new_h / h_speed
		player.velocity.x *= ratio
		player.velocity.z *= ratio

	# =================================================================
	# 7. MOVE — move_and_slide() handles floor and wall collisions.
	#    On the floor it blocks the downward component of our derived
	#    velocity, so the player glides horizontally.  In the air, the
	#    full velocity applies.
	# =================================================================
	var _t_move := Time.get_ticks_usec()
	player.move_and_slide()
	var _t_move_end := Time.get_ticks_usec()

	# --- Release conditions ---
	# Jump no longer cancels grapple — only shoot (click) releases.

	# --- Rope LOS check ---
	var _t_los: int = 0
	var _t_los_end: int = 0
	_los_frame_counter += 1
	if _los_frame_counter >= ROPE_LOS_INTERVAL:
		_los_frame_counter = 0
		_t_los = Time.get_ticks_usec()
		if _is_rope_obstructed():
			_do_release(false)
			return
		_t_los_end = Time.get_ticks_usec()

	# --- Safety: absurd distance = release ---
	if player.global_position.distance_to(anchor_point) > MAX_GRAPPLE_RANGE * 1.5:
		_do_release(false)

	_was_on_floor = on_floor

	# --- Debug timing report ---
	var _t_total := Time.get_ticks_usec()
	var total_us: float = _t_total - _t0
	var move_us: float = _t_move_end - _t_move
	var los_us: float = (_t_los_end - _t_los) if _t_los > 0 else 0.0
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	if total_us > DEBUG_SPIKE_THRESHOLD_US and (now_sec - _debug_last_print_time) > 1.0:
		_debug_last_print_time = now_sec
		print("[GRAPPLE SPIKE] total=%.0fµs  move_and_slide=%.0fµs  LOS_check=%.0fµs  other=%.0fµs" % [
			total_us, move_us, los_us, total_us - move_us - los_us])


func _is_rope_obstructed() -> bool:
	## Rope obstruction check — pill-based.
	##
	## 1. Center check — detect obstruction:
	##    a. Swept prism (prev_chest, current_chest, anchor).
	##    b. Player-to-anchor ray.
	##    c. Anchor-to-player ray (catches backface hits).
	## 2. If blocked, pill check — left/right half-capsules test if there's
	##    a way around.  At least one half clear -> don't cut.  Both blocked -> CUT.
	var _los_t0 := Time.get_ticks_usec()
	var space_state := player.get_world_3d().direct_space_state
	var player_chest: Vector3 = player.global_position + Vector3(0, 1.2, 0)

	# Exclude self, anchor collider, and all other players
	var excludes: Array[RID] = [player.get_rid()]
	if _anchor_collider_rid.is_valid():
		excludes.append(_anchor_collider_rid)
	for peer_id in NetworkManager.players:
		var other_player: CharacterBody3D = NetworkManager.players[peer_id]
		if other_player and other_player != player:
			excludes.append(other_player.get_rid())

	var rope_vec: Vector3 = anchor_point - player_chest
	var rope_len: float = rope_vec.length()
	if rope_len < 0.1:
		return false
	var rope_dir: Vector3 = rope_vec / rope_len

	# Build swing-aligned perpendicular basis.
	var radial_speed: float = player.velocity.dot(rope_dir)
	var tangential_vel: Vector3 = player.velocity - rope_dir * radial_speed
	var tang_len: float = tangential_vel.length()

	var swing_normal: Vector3
	if tang_len > 0.5:
		swing_normal = rope_dir.cross(tangential_vel).normalized()
	else:
		if absf(rope_dir.y) < 0.9:
			swing_normal = rope_dir.cross(Vector3.UP).normalized()
		else:
			swing_normal = rope_dir.cross(Vector3.RIGHT).normalized()

	_pill_swing_normal = swing_normal

	var _los_t_center := Time.get_ticks_usec()
	# --- Step 1: Center rope check with swept-triangle detection ---
	_has_center_contact = false
	_center_contact_cloud = []
	_center_contact_rid = RID()
	_arc_contacts = [[], []]

	var prev_chest: Vector3 = _last_los_chest if _last_los_chest.length() > 0.1 else player_chest
	_prev_los_chest = prev_chest
	_last_los_chest = player_chest

	var center_hit_result: Dictionary = {}

	# A) Swept-triangle check — thin prism (prev_chest, current_chest, anchor)
	var sweep_vec: Vector3 = player_chest - prev_chest
	var sweep_len: float = sweep_vec.length()
	if sweep_len > 0.05:
		var edge_a: Vector3 = player_chest - prev_chest
		var edge_b: Vector3 = anchor_point - prev_chest
		var tri_normal: Vector3 = edge_a.cross(edge_b)
		var tri_n_len: float = tri_normal.length()
		if tri_n_len > 0.001:
			tri_normal /= tri_n_len
		else:
			tri_normal = Vector3.UP
		var offset: Vector3 = tri_normal * 0.005
		_center_sweep_shape.points = PackedVector3Array([
			prev_chest + offset, player_chest + offset, anchor_point + offset,
			prev_chest - offset, player_chest - offset, anchor_point - offset])
		_center_sweep_query.transform = Transform3D.IDENTITY
		_center_sweep_query.exclude = excludes
		var sweep_overlaps := space_state.intersect_shape(_center_sweep_query, 8)
		if not sweep_overlaps.is_empty():
			var confirm_query := PhysicsRayQueryParameters3D.create(prev_chest, anchor_point)
			confirm_query.exclude = excludes
			confirm_query.collision_mask = 1
			var confirm_result := space_state.intersect_ray(confirm_query)
			if not confirm_result.is_empty():
				if confirm_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
					center_hit_result = confirm_result

	# B) Current rope ray — player chest to anchor
	if center_hit_result.is_empty():
		var rope_query := PhysicsRayQueryParameters3D.create(player_chest, anchor_point)
		rope_query.exclude = excludes
		rope_query.collision_mask = 1
		var rope_result := space_state.intersect_ray(rope_query)
		if not rope_result.is_empty():
			if rope_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
				center_hit_result = rope_result

	# C) Anchor to player ray — catches obstacles the player-side ray misses
	var anchor_ray_query := PhysicsRayQueryParameters3D.create(anchor_point, player_chest)
	anchor_ray_query.exclude = excludes
	anchor_ray_query.collision_mask = 1
	var anchor_ray_result := space_state.intersect_ray(anchor_ray_query)
	if not anchor_ray_result.is_empty():
		if anchor_ray_result.position.distance_to(player_chest) >= ROPE_LOS_MARGIN:
			if center_hit_result.is_empty():
				center_hit_result = anchor_ray_result

	# --- Clear path: no obstruction ---
	if center_hit_result.is_empty():
		_pill_half_blocked = [0, 0]
		return false

	# --- Blocked: run pill check ---
	_center_contact_point = center_hit_result.position
	_center_contact_rid = center_hit_result.get("rid", RID())
	_has_center_contact = true

	var pill_xform := _build_pill_transform(player_chest, rope_dir, swing_normal, rope_len)

	var left_pts := _build_half_capsule_points(rope_len, PILL_RADIUS, 1.0)
	_left_half_shape.points = left_pts
	_left_half_query.transform = pill_xform
	_left_half_query.exclude = excludes

	var right_pts := _build_half_capsule_points(rope_len, PILL_RADIUS, -1.0)
	_right_half_shape.points = right_pts
	_right_half_query.transform = pill_xform
	_right_half_query.exclude = excludes

	var left_contacts: Array[Vector3] = []
	var left_blocked := _check_pill_half_blocked(space_state, _left_half_query, left_contacts)

	var right_contacts: Array[Vector3] = []
	var right_blocked := _check_pill_half_blocked(space_state, _right_half_query, right_contacts)

	_pill_half_blocked = [1 if left_blocked else 0, 1 if right_blocked else 0]
	_arc_contacts = [left_contacts, right_contacts]

	if not left_blocked or not right_blocked:
		return false  # Way around — don't cut
	return true  # Both halves blocked — CUT


func _log_los_timing(t0: int, t_center: int, t_fan: int, t_pill: int, outcome: String) -> void:
	## Print LOS check timing breakdown if it exceeds the spike threshold.
	var t_end := Time.get_ticks_usec()
	var total_us: float = t_end - t0
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	if total_us > DEBUG_SPIKE_THRESHOLD_US and (now_sec - _debug_last_print_time) > 0.5:
		_debug_last_print_time = now_sec
		var center_us: float = (t_fan - t_center) if t_fan > 0 else (t_end - t_center)
		var fan_us: float = (t_pill - t_fan) if (t_fan > 0 and t_pill > 0) else 0.0
		var pill_us: float = (t_end - t_pill) if t_pill > 0 else 0.0
		var setup_us: float = t_center - t0
		print("[LOS SPIKE] total=%.0fµs  setup=%.0fµs  center=%.0fµs  fan=%.0fµs  pill=%.0fµs  outcome=%s" % [
			total_us, setup_us, center_us, fan_us, pill_us, outcome])


func _build_half_capsule_points(rope_len: float, radius: float,
		side_sign: float) -> PackedVector3Array:
	## Generate vertices for a thin SHELL on one side of the capsule.
	## This is NOT a solid half — it's a thin curved wall representing the
	## outside path the rope would take when going around an obstacle.
	##
	## Local space: Y-axis = rope direction (0 = player, rope_len = anchor).
	##              X-axis = swing_normal (split direction).
	## side_sign: +1.0 = left shell (+X side), -1.0 = right shell (-X side).
	##
	## The shell is built from two concentric layers of vertices:
	##   Outer layer: at full radius
	##   Inner layer: at radius - SHELL_THICKNESS
	## The convex hull of these two layers forms a thin curved wall.
	var points := PackedVector3Array()
	const SHELL_THICKNESS := 0.06  ## Thin wall thickness

	var inner_radius: float = maxf(radius - SHELL_THICKNESS, 0.01)
	# Capsule centered at Y = rope_len/2.  Cylinder extends from
	# cyl_bottom to cyl_top; hemispheres cap each end.
	var half_cyl: float = maxf((rope_len - 2.0 * radius) * 0.5, 0.0)
	var mid_y: float = rope_len * 0.5
	var cyl_bottom: float = mid_y - half_cyl
	var cyl_top: float = mid_y + half_cyl

	# Generate two layers (outer and inner) of the half-shell surface.
	# The shell covers a half-circle arc from -90° to +90° around the capsule
	# axis on the side_sign side (+X or -X).
	for layer in 2:
		var r: float = radius if layer == 0 else inner_radius

		# Cylinder body rings
		for yi in HALF_CAPSULE_SEGS + 1:
			var t: float = float(yi) / float(HALF_CAPSULE_SEGS)
			var y_local: float = cyl_bottom + t * (cyl_top - cyl_bottom)

			for ai in HALF_CAPSULE_SEGS + 1:
				# Half-circle arc from -90° to +90° (outward side)
				var angle: float = -PI * 0.5 + PI * float(ai) / float(HALF_CAPSULE_SEGS)
				var lx: float = cos(angle) * r * side_sign
				var lz: float = sin(angle) * r
				points.append(Vector3(lx, y_local, lz))

		# Bottom hemisphere cap (player end)
		for hi in range(1, HALF_CAPSULE_HEMI_STEPS + 1):
			var phi: float = (PI * 0.5) * float(hi) / float(HALF_CAPSULE_HEMI_STEPS)
			var y_local: float = cyl_bottom - sin(phi) * r
			var ring_r: float = cos(phi) * r
			if ring_r < 0.005:
				points.append(Vector3(0.0, y_local, 0.0))
				continue
			for ai in HALF_CAPSULE_SEGS + 1:
				var angle: float = -PI * 0.5 + PI * float(ai) / float(HALF_CAPSULE_SEGS)
				var lx: float = cos(angle) * ring_r * side_sign
				var lz: float = sin(angle) * ring_r
				points.append(Vector3(lx, y_local, lz))

		# Top hemisphere cap (anchor end)
		for hi in range(1, HALF_CAPSULE_HEMI_STEPS + 1):
			var phi: float = (PI * 0.5) * float(hi) / float(HALF_CAPSULE_HEMI_STEPS)
			var y_local: float = cyl_top + sin(phi) * r
			var ring_r: float = cos(phi) * r
			if ring_r < 0.005:
				points.append(Vector3(0.0, y_local, 0.0))
				continue
			for ai in HALF_CAPSULE_SEGS + 1:
				var angle: float = -PI * 0.5 + PI * float(ai) / float(HALF_CAPSULE_SEGS)
				var lx: float = cos(angle) * ring_r * side_sign
				var lz: float = sin(angle) * ring_r
				points.append(Vector3(lx, y_local, lz))

	return points


func _build_pill_transform(player_chest: Vector3, rope_dir: Vector3,
		swing_normal: Vector3, rope_len: float) -> Transform3D:
	## Build a Transform3D that places the pill centered on the rope.
	## Local Y = rope direction, local X = swing_normal (split direction).
	## Origin = player_chest (the Y=0 of local space is at the player end).
	## The capsule extends from Y=(-radius) to Y=(rope_len + radius).
	var basis_y: Vector3 = rope_dir
	var basis_x: Vector3 = swing_normal
	var basis_z: Vector3 = basis_y.cross(basis_x)
	if basis_z.length() < 0.001:
		# Fallback if swing_normal is parallel to rope
		if absf(rope_dir.y) < 0.9:
			basis_x = rope_dir.cross(Vector3.UP).normalized()
		else:
			basis_x = rope_dir.cross(Vector3.RIGHT).normalized()
		basis_z = basis_y.cross(basis_x)
	basis_z = basis_z.normalized()
	basis_x = basis_y.cross(basis_z).normalized()

	# Origin at player chest — local space Y=0 corresponds to player chest,
	# Y=rope_len is at the anchor.  Vertices are generated in this local space.
	return Transform3D(Basis(basis_x, basis_y, basis_z), player_chest)


func _check_pill_half_blocked(space_state: PhysicsDirectSpaceState3D,
		query: PhysicsShapeQueryParameters3D,
		out_contacts: Array[Vector3]) -> bool:
	## Check if a single half-capsule is blocked.
	## Returns true if blocked, false if clear path exists.

	# Step A: Check if the center obstruction obstacle overlaps this half
	var overlaps := space_state.intersect_shape(query, 32)
	var found_obstruction := false
	for overlap in overlaps:
		var rid: RID = overlap.get("rid", RID())
		if rid == _center_contact_rid:
			out_contacts.append(_center_contact_point)
			found_obstruction = true
	if found_obstruction:
		return true

	# Step B: Different objects — only contacts within ARC_CONTACT_RADIUS (3m)
	# of the center contact count.  Prevents distant unrelated objects from
	# accidentally blocking the pill half.
	var contacts: Array[Vector3] = []
	contacts.assign(space_state.collide_shape(query, 32))

	var found_nearby := false
	for ci in range(1, contacts.size(), 2):
		var contact_pos: Vector3 = contacts[ci]
		# Skip contacts near the anchor or player (safe zones)
		if contact_pos.distance_to(anchor_point) < ROPE_LOS_MARGIN:
			continue
		if contact_pos.distance_to(player.global_position) < ROPE_LOS_MARGIN:
			continue
		# Only count if within range of the center contact point
		if contact_pos.distance_to(_center_contact_point) > ARC_CONTACT_RADIUS:
			continue
		out_contacts.append(contact_pos)
		found_nearby = true

	return found_nearby


# ======================================================================
#  Server: release grapple
# ======================================================================

func _do_release(with_boost: bool) -> void:
	if not is_grappling:
		return

	var boosted := false
	if with_boost:
		boosted = _apply_release_boost()

	var release_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()
	_show_grapple_release.rpc(release_pos)
	if boosted:
		_play_release_woosh.rpc(release_pos)
	print("Player %d released grapple (speed: %.1f, boost: %s)" % [
		player.peer_id, player.velocity.length(), str(with_boost)])


func _apply_release_boost() -> bool:
	## Tilt velocity upward by 25° (capped at 30° above horizontal),
	## then add a speed boost that scales with current speed.
	## Returns true if the boost was actually applied.
	## Boost is blocked if less than 0.5s since the last boost.
	var now := Time.get_ticks_msec() / 1000.0
	if _last_boost_time >= 0.0 and (now - _last_boost_time) < 1.0:
		return false

	var vel := player.velocity
	var speed := vel.length()
	if speed < RELEASE_BOOST_MIN_SPEED:
		return false

	# --- Pitch tilt: rotate velocity upward by 10°, capped at 15° ---
	var horiz_speed := Vector2(vel.x, vel.z).length()
	if horiz_speed > 0.1:
		# Current pitch angle (negative = downward, positive = upward)
		var current_pitch := atan2(vel.y, horiz_speed)
		# Target pitch after adding 10°, capped at 15° upward
		var new_pitch := minf(current_pitch + RELEASE_PITCH_UP, RELEASE_PITCH_MAX)
		# Only apply if we're actually tilting upward from current
		if new_pitch > current_pitch:
			# Preserve total speed, redistribute between vertical and horizontal
			var horiz_dir := Vector2(vel.x, vel.z).normalized()
			var new_horiz := cos(new_pitch) * speed
			var new_vert := sin(new_pitch) * speed
			player.velocity.x = horiz_dir.x * new_horiz
			player.velocity.z = horiz_dir.y * new_horiz
			player.velocity.y = new_vert

	# --- Speed boost: 1 m/s at 2 m/s, scaling to 10 m/s at 50 m/s ---
	speed = player.velocity.length()  # Re-read after pitch change
	var t := clampf((speed - RELEASE_BOOST_MIN_SPEED) /
		(RELEASE_BOOST_MAX_SPEED - RELEASE_BOOST_MIN_SPEED), 0.0, 1.0)
	var boost := lerpf(RELEASE_BOOST_MIN, RELEASE_BOOST_MAX, t)
	var boost_dir := player.velocity.normalized()
	player.velocity += boost_dir * boost

	_last_boost_time = now
	return true


func reset_state() -> void:
	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()
	_shoot_was_held = false
	_los_frame_counter = 0
	_was_on_floor = false
	_low_momentum_timer = 0.0
	_last_los_chest = Vector3.ZERO
	_fresh_grapple = false
	_charges = MAX_CHARGES
	_recharge_timer = 0.0
	_last_boost_time = -1.0
	_pill_half_blocked = [0, 0]
	_pill_swing_normal = Vector3.ZERO
	_prev_los_chest = Vector3.ZERO
	_center_contact_point = Vector3.ZERO
	_has_center_contact = false
	_center_contact_cloud = []
	_center_contact_rid = RID()
	_arc_contacts = [[], []]
	cleanup()


# ======================================================================
#  Client: rope visual
# ======================================================================

func client_process_visuals(_delta: float) -> void:
	cleanup()
	if not is_grappling:
		if _debug_label:
			_debug_label.visible = false
		return

	var player_hand: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	var cam_pos: Vector3 = player.camera.global_position if player.camera else player_hand
	var scene_root := get_tree().current_scene

	# --- Red rope — always visible ---
	var im := ImmediateMesh.new()
	_rope_mesh_instance = MeshInstance3D.new()
	_rope_mesh_instance.mesh = im
	_rope_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rope_mesh_instance.top_level = true
	_rope_mesh_instance.material_override = _rope_material

	_build_rope_ribbon(im, player_hand, anchor_point, cam_pos)

	if scene_root:
		scene_root.add_child(_rope_mesh_instance)

	# --- Anchor light ---
	_anchor_light = OmniLight3D.new()
	_anchor_light.light_color = Color(0.3, 0.6, 1.0)
	_anchor_light.light_energy = 2.5
	_anchor_light.omni_range = 4.0
	_anchor_light.omni_attenuation = 1.5
	_anchor_light.position = anchor_point
	if scene_root:
		scene_root.add_child(_anchor_light)

	var show_debug: bool = GameManager.debug_grapple_visuals

	# --- Debug HUD label — rope state, pill status ---
	if _debug_label and show_debug:
		_debug_label.visible = true
		var lines: PackedStringArray = PackedStringArray()
		lines.append("Rope Length: %.1fm" % _rope_length)
		if _has_center_contact:
			lines.append("Contact: (%.1f, %.1f, %.1f)" % [_center_contact_point.x, _center_contact_point.y, _center_contact_point.z])
		lines.append("Pills: L=%s  R=%s" % [
			"BLOCKED" if _pill_half_blocked[0] == 1 else "clear",
			"BLOCKED" if _pill_half_blocked[1] == 1 else "clear"])
		_debug_label.text = "\n".join(lines)
	elif _debug_label:
		_debug_label.visible = false

	if show_debug:
		# --- Pill debug visualization ---
		_build_pill_visual(player_hand)

		# --- Contact point + sphere debug visualization ---
		_build_contact_debug_visual()


func _build_rope_ribbon(im: ImmediateMesh, from: Vector3, to: Vector3, cam_pos: Vector3) -> void:
	var rope_vec: Vector3 = to - from
	var rope_length: float = rope_vec.length()
	if rope_length < 0.01:
		return

	const HALF_WIDTH := 0.04  ## Thin rope
	const SEGMENTS := 12

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in SEGMENTS + 1:
		var t: float = float(i) / float(SEGMENTS)
		var pos: Vector3 = from.lerp(to, t)
		var view_dir: Vector3 = (cam_pos - pos).normalized()
		var rope_dir: Vector3 = rope_vec.normalized()
		var width_dir: Vector3 = rope_dir.cross(view_dir)
		if width_dir.length() < 0.001:
			width_dir = Vector3.UP.cross(rope_dir)
		width_dir = width_dir.normalized()
		im.surface_add_vertex(pos + width_dir * HALF_WIDTH)
		im.surface_add_vertex(pos - width_dir * HALF_WIDTH)
	im.surface_end()


func cleanup() -> void:
	if _rope_mesh_instance and is_instance_valid(_rope_mesh_instance):
		_rope_mesh_instance.queue_free()
		_rope_mesh_instance = null
	if _anchor_light and is_instance_valid(_anchor_light):
		_anchor_light.queue_free()
		_anchor_light = null
	if _pill_mesh_instance and is_instance_valid(_pill_mesh_instance):
		_pill_mesh_instance.queue_free()
		_pill_mesh_instance = null
	if _contact_mesh_instance and is_instance_valid(_contact_mesh_instance):
		_contact_mesh_instance.queue_free()
		_contact_mesh_instance = null


# ======================================================================
#  Pill debug visualization
# ======================================================================

func _build_pill_visual(player_chest: Vector3) -> void:
	## Draw solid half-capsule shells (left/right of the rope).
	## Color coding:
	##   Left half:  green (clear) / red (blocked)
	##   Right half: yellow (clear) / red (blocked)
	## Inner subdivisions (shrunk radius) drawn at 40% opacity.
	var pill_anchor: Vector3 = anchor_point
	var rope_vec: Vector3 = pill_anchor - player_chest
	var rope_len: float = rope_vec.length()
	if rope_len < 0.5:
		return
	var rope_dir: Vector3 = rope_vec / rope_len

	var swing_n: Vector3 = _pill_swing_normal
	if swing_n.length() < 0.5:
		if absf(rope_dir.y) < 0.9:
			swing_n = rope_dir.cross(Vector3.UP).normalized()
		else:
			swing_n = rope_dir.cross(Vector3.RIGHT).normalized()

	# Build the same transform used for physics
	var pill_xform := _build_pill_transform(player_chest, rope_dir, swing_n, rope_len)

	var im := ImmediateMesh.new()
	_pill_mesh_instance = MeshInstance3D.new()
	_pill_mesh_instance.mesh = im
	_pill_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pill_mesh_instance.top_level = true

	# Pick cached materials per half (full opacity for first subdivision, dim for rest)
	var all_fracs: Array[float] = [1.0, 0.5, 0.25, 0.75]

	for half_idx in 2:
		var sign_dir: float = 1.0 if half_idx == 0 else -1.0
		var blocked: bool = _pill_half_blocked[half_idx] == 1

		for fi in all_fracs.size():
			var frac: float = all_fracs[fi]
			var draw_radius: float = PILL_RADIUS * frac
			var is_subdiv: bool = fi > 0

			var mat: StandardMaterial3D
			if blocked:
				mat = _pill_subdiv_blocked_mat if is_subdiv else _pill_blocked_mat
			elif half_idx == 0:
				mat = _pill_subdiv_clear_left_mat if is_subdiv else _pill_clear_left_mat
			else:
				mat = _pill_subdiv_clear_right_mat if is_subdiv else _pill_clear_right_mat

			_draw_half_capsule_solid(im, pill_xform, draw_radius,
				rope_len, sign_dir, mat)

	# Also draw the center sweep triangle (using cached material)
	var prev_chest: Vector3 = _prev_los_chest if _prev_los_chest.length() > 0.1 else player_chest
	var sweep_vec: Vector3 = player_chest - prev_chest
	if sweep_vec.length() > 0.05:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _sweep_wire_mat)
		im.surface_add_vertex(prev_chest)
		im.surface_add_vertex(player_chest)
		im.surface_add_vertex(anchor_point)
		im.surface_add_vertex(prev_chest)
		im.surface_end()

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_pill_mesh_instance)


func _draw_half_capsule_solid(im: ImmediateMesh, xform: Transform3D,
		radius: float, rope_len: float, side_sign: float, mat: StandardMaterial3D) -> void:
	## Draw a solid (filled) half-capsule shell (one side of the pill).
	## xform: origin = player chest, Y = rope dir, X = swing_normal.
	## side_sign: +1.0 = left half (+X), -1.0 = right half (-X).
	## Renders as triangle strips between adjacent latitude rows.
	const ARC_SEGS := 8   # circumference segments for the half-circle
	const CYL_RINGS := 3  # number of rings along the cylinder body
	const HEMI_RINGS := 3 # latitude rings per hemisphere cap

	var half_cyl: float = maxf((rope_len - 2.0 * radius) * 0.5, 0.0)
	var mid_y: float = rope_len * 0.5
	var cyl_bottom: float = mid_y - half_cyl
	var cyl_top: float = mid_y + half_cyl

	# Build a list of "rows" — each row is an array of world-space vertices
	# forming a half-circle arc at a specific latitude.  Then we stitch
	# adjacent rows with triangle strips.
	var rows: Array[PackedVector3Array] = []

	# --- Bottom pole (single point) ---
	var pole_bottom := PackedVector3Array()
	var pole_pt: Vector3 = xform * Vector3(0.0, cyl_bottom - radius, 0.0)
	for _i in ARC_SEGS + 1:
		pole_bottom.append(pole_pt)
	rows.append(pole_bottom)

	# --- Bottom hemisphere rings (from pole upward to cyl_bottom) ---
	for lat_i in range(HEMI_RINGS, 0, -1):
		var phi: float = (PI * 0.5) * float(lat_i) / float(HEMI_RINGS)
		var y_local: float = cyl_bottom - sin(phi) * radius
		var ring_r: float = cos(phi) * radius
		var row := PackedVector3Array()
		for seg_i in ARC_SEGS + 1:
			var angle: float = -PI * 0.5 + PI * float(seg_i) / float(ARC_SEGS)
			var lx: float = cos(angle) * ring_r * side_sign
			var lz: float = sin(angle) * ring_r
			row.append(xform * Vector3(lx, y_local, lz))
		rows.append(row)

	# --- Cylinder body rings ---
	for ring_i in CYL_RINGS + 1:
		var t: float = float(ring_i) / float(CYL_RINGS)
		var y_local: float = cyl_bottom + t * (cyl_top - cyl_bottom)
		var row := PackedVector3Array()
		for seg_i in ARC_SEGS + 1:
			var angle: float = -PI * 0.5 + PI * float(seg_i) / float(ARC_SEGS)
			var lx: float = cos(angle) * radius * side_sign
			var lz: float = sin(angle) * radius
			row.append(xform * Vector3(lx, y_local, lz))
		rows.append(row)

	# --- Top hemisphere rings (from cyl_top upward to pole) ---
	for lat_i in range(1, HEMI_RINGS + 1):
		var phi: float = (PI * 0.5) * float(lat_i) / float(HEMI_RINGS)
		var y_local: float = cyl_top + sin(phi) * radius
		var ring_r: float = cos(phi) * radius
		var row := PackedVector3Array()
		if ring_r < 0.005:
			# Top pole — degenerate ring
			var pp: Vector3 = xform * Vector3(0.0, cyl_top + radius, 0.0)
			for _i in ARC_SEGS + 1:
				row.append(pp)
		else:
			for seg_i in ARC_SEGS + 1:
				var angle: float = -PI * 0.5 + PI * float(seg_i) / float(ARC_SEGS)
				var lx: float = cos(angle) * ring_r * side_sign
				var lz: float = sin(angle) * ring_r
				row.append(xform * Vector3(lx, y_local, lz))
		rows.append(row)

	# --- Stitch adjacent rows with triangle strips ---
	for ri in range(rows.size() - 1):
		var row_a: PackedVector3Array = rows[ri]
		var row_b: PackedVector3Array = rows[ri + 1]
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
		for si in row_a.size():
			im.surface_add_vertex(row_a[si])
			im.surface_add_vertex(row_b[si])
		im.surface_end()


# ======================================================================
#  Contact debug visualization — circles at contact points + 2.0m sphere
# ======================================================================

func _build_contact_debug_visual() -> void:
	## Draw small green-blue circles at each contact point from the obstruction
	## check, and a wireframe sphere around the center contact showing the
	## ARC_CONTACT_RADIUS (2.0m) disregard boundary.
	if not _has_center_contact:
		return

	var im := ImmediateMesh.new()
	_contact_mesh_instance = MeshInstance3D.new()
	_contact_mesh_instance.mesh = im
	_contact_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_contact_mesh_instance.top_level = true

	# All materials are pre-cached in setup() — no per-frame allocation.

	# --- Player-side contact (center hit, bright cyan) ---
	_draw_debug_circle(im, _contact_center_mat, _center_contact_point, 0.15, 12)

	# --- Anchor-side contact (dimmer cyan, from anchor→player ray) ---
	for pt in _center_contact_cloud:
		if pt.distance_to(_center_contact_point) > 0.01:
			_draw_debug_circle(im, _contact_cloud_mat, pt, 0.12, 10)

	# --- Arc contact circles (pill half contacts) ---
	for half_idx in 2:
		for contact_pos in _arc_contacts[half_idx]:
			_draw_debug_circle(im, _contact_arc_mat, contact_pos, 0.1, 10)

	# --- 3m range sphere around center contact (ARC_CONTACT_RADIUS filter boundary) ---
	_draw_debug_sphere_wireframe(im, _contact_sphere_mat, _center_contact_point, ARC_CONTACT_RADIUS, 16, 8)

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_contact_mesh_instance)


func _draw_debug_circle(im: ImmediateMesh, mat: StandardMaterial3D,
		center: Vector3, radius: float, segments: int) -> void:
	## Draw a small circle (3 rings: XY, XZ, YZ planes) at a world position.
	## This makes it visible from any angle.
	for axis in 3:
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		for i in segments + 1:
			var angle: float = TAU * float(i) / float(segments)
			var offset: Vector3
			match axis:
				0: offset = Vector3(cos(angle) * radius, sin(angle) * radius, 0.0)
				1: offset = Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
				2: offset = Vector3(0.0, cos(angle) * radius, sin(angle) * radius)
			im.surface_add_vertex(center + offset)
		im.surface_end()


func _draw_debug_sphere_wireframe(im: ImmediateMesh, mat: StandardMaterial3D,
		center: Vector3, radius: float, lon_segments: int, lat_segments: int) -> void:
	## Draw a wireframe sphere as latitude + longitude rings.
	# Latitude rings (horizontal circles at different heights)
	for i in range(1, lat_segments):
		var phi: float = PI * float(i) / float(lat_segments)
		var ring_y: float = cos(phi) * radius
		var ring_r: float = sin(phi) * radius
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		for j in lon_segments + 1:
			var theta: float = TAU * float(j) / float(lon_segments)
			var pos := center + Vector3(cos(theta) * ring_r, ring_y, sin(theta) * ring_r)
			im.surface_add_vertex(pos)
		im.surface_end()

	# Longitude rings (vertical great circles)
	for j in lon_segments:
		var theta: float = TAU * float(j) / float(lon_segments)
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		for i in lat_segments + 1:
			var phi: float = PI * float(i) / float(lat_segments)
			var pos := center + Vector3(
				sin(phi) * cos(theta) * radius,
				cos(phi) * radius,
				sin(phi) * sin(theta) * radius)
			im.surface_add_vertex(pos)
		im.surface_end()


# ======================================================================
#  RPCs — visual effects
# ======================================================================

@rpc("authority", "call_local", "reliable")
func _show_grapple_fire(from: Vector3, to: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.3, 0.6, 1.0)
	flash.light_energy = 8.0
	flash.omni_range = 4.0
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = to
	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.3)
	tween.tween_callback(flash.queue_free)
	var spark := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.3
	spark.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.8, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.6, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark.material_override = mat
	spark.top_level = true
	scene_root.add_child(spark)
	spark.global_position = to
	var spark_tween := get_tree().create_tween()
	spark_tween.tween_property(spark, "scale", Vector3.ZERO, 0.4).from(Vector3.ONE * 1.5)
	spark_tween.tween_callback(spark.queue_free)


@rpc("authority", "call_local", "reliable")
func _show_grapple_release(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.4, 0.7, 1.0)
	flash.light_energy = 4.0
	flash.omni_range = 3.0
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos
	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.2)
	tween.tween_callback(flash.queue_free)


@rpc("authority", "call_local", "reliable")
func _play_release_woosh(pos: Vector3) -> void:
	## Procedural whoosh sound on boosted grapple release.
	var sfx := AudioStreamPlayer3D.new()
	sfx.top_level = true
	sfx.max_distance = 40.0
	sfx.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE

	# Generate a short burst of filtered noise as a woosh
	var sample_rate := 22050
	var duration := 0.35
	var num_samples := int(sample_rate * duration)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = sample_rate
	gen.buffer_length = duration + 0.05

	sfx.stream = gen
	var scene_root := get_tree().current_scene
	if scene_root == null:
		sfx.queue_free()
		return
	scene_root.add_child(sfx)
	sfx.global_position = pos
	sfx.play()

	# Push samples: band-passed noise with pitch sweep and volume envelope
	var playback: AudioStreamGeneratorPlayback = sfx.get_stream_playback()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# Simple biquad low-pass state
	var lp_prev := 0.0
	var lp_prev2 := 0.0
	for i in num_samples:
		var t := float(i) / float(num_samples)
		# Volume envelope: quick attack, smooth decay
		var env := (1.0 - t) * (1.0 - t)
		if t < 0.05:
			env *= t / 0.05
		# Noise source
		var noise := rng.randf_range(-1.0, 1.0)
		# Low-pass cutoff sweeps down over time (woosh character)
		var cutoff := lerpf(0.6, 0.15, t)
		# Simple one-pole low-pass
		lp_prev = lp_prev + cutoff * (noise - lp_prev)
		var sample := lp_prev * env * 0.7
		playback.push_frame(Vector2(sample, sample))

	# Auto-cleanup after playback
	var cleanup_tween := get_tree().create_tween()
	cleanup_tween.tween_interval(duration + 0.1)
	cleanup_tween.tween_callback(sfx.queue_free)
