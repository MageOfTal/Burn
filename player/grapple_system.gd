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
const RELEASE_UPWARD_BOOST := 3.0     ## Vertical speed added on jump-release
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

## Rope line-of-sight — cut if geometry obstructs the line.
const ROPE_LOS_MARGIN := 3.0
const ROPE_LOS_INTERVAL := 3

## Pill obstruction shape — one capsule centered on the rope, split into
## two ConvexPolygonShape3D halves (left/right of the swing plane).
## Each half is a half-capsule: flat face on the split plane, hemisphere outward.
## If blocked, shrink radius and retry.
const PILL_RADIUS := 0.35             ## Capsule radius for the go-around check
const ARC_CONTACT_RADIUS := 2.0       ## Different-object contacts beyond this from the cloud are ignored
const CLOUD_FAN_RAYS := 5             ## Rays fanned across swing plane to map center obstacle extent
const HALF_CAPSULE_SEGS := 6          ## Circumference segments for half-capsule vertices
const HALF_CAPSULE_HEMI_STEPS := 3    ## Latitude steps for the hemisphere cap
## Center sweep — a flat triangle (prev_chest, current_chest, anchor) covering
## the area the rope swept through between LOS checks.  Uses ConvexPolygonShape3D
## with 3 coplanar vertices — the physics engine treats this as a triangle.

## Bend-angle tolerance — rope survives small deflections around thin obstacles.
const MAX_BEND_ANGLE_DEG := 5.0       ## Rope tolerates up to this bend before cutting
const BEND_STRAIGHTENED_DEG := 0.5    ## Below this = rope considered straight again

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

## Bend-angle tolerance — tracks whether the rope is deflected around an obstacle.
var _rope_is_bent: bool = false
var _bend_contact_point: Vector3 = Vector3.ZERO  ## Obstacle contact causing the bend
var _bend_angle_deg: float = 0.0                 ## Current bend angle in degrees at anchor

# ======================================================================
#  Client VFX state
# ======================================================================

var _rope_mesh_instance: MeshInstance3D = null
var _anchor_light: OmniLight3D = null
var _rope_material: StandardMaterial3D = null
var _pill_mesh_instance: MeshInstance3D = null
var _contact_mesh_instance: MeshInstance3D = null
var _bent_rope_mesh: MeshInstance3D = null
var _bent_rope_material: StandardMaterial3D = null
var _bent_contact_material: StandardMaterial3D = null

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

# ======================================================================
#  Player reference
# ======================================================================

var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p
	_rope_material = StandardMaterial3D.new()
	_rope_material.albedo_color = Color(0.4, 0.75, 1.0, 0.95)
	_rope_material.emission_enabled = true
	_rope_material.emission = Color(0.3, 0.6, 1.0)
	_rope_material.emission_energy_multiplier = 4.0
	_rope_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Pre-create bent rope debug materials (cached to avoid per-frame allocation)
	_bent_rope_material = StandardMaterial3D.new()
	_bent_rope_material.albedo_color = Color(1.0, 0.6, 0.1, 0.85)
	_bent_rope_material.emission_enabled = true
	_bent_rope_material.emission = Color(1.0, 0.5, 0.0)
	_bent_rope_material.emission_energy_multiplier = 3.0
	_bent_rope_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bent_rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bent_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_bent_contact_material = StandardMaterial3D.new()
	_bent_contact_material.albedo_color = Color(1.0, 0.4, 0.0, 0.9)
	_bent_contact_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_bent_contact_material.no_depth_test = true

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


func is_active() -> bool:
	return is_grappling


func _get_proximity_factor() -> float:
	var dist: float = player.global_position.distance_to(anchor_point)
	if dist >= PROXIMITY_DAMPEN_RANGE:
		return 1.0
	var t: float = dist / PROXIMITY_DAMPEN_RANGE
	var smooth: float = t * t * (3.0 - 2.0 * t)
	return lerpf(PROXIMITY_MIN_FACTOR, 1.0, smooth)


func handle_shoot_input(shoot_held: bool) -> void:
	var just_pressed: bool = shoot_held and not _shoot_was_held
	_shoot_was_held = shoot_held
	if just_pressed:
		if is_grappling:
			_do_release(false)
		else:
			try_fire()


# ======================================================================
#  Server: fire grapple
# ======================================================================

func try_fire() -> void:
	if is_grappling:
		return

	var space_state := player.get_world_3d().direct_space_state
	# Fire from hand position (where the rope visually attaches), aim along
	# camera forward.  This keeps the fire origin consistent with the LOS
	# check so hills that block the hand also block the shot.
	var hand_origin: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	var cam_forward: Vector3 = -player.camera.global_transform.basis.z

	var far_point := hand_origin + cam_forward * MAX_GRAPPLE_RANGE
	var query := PhysicsRayQueryParameters3D.create(hand_origin, far_point)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return

	anchor_point = result.position
	_rope_length = player.global_position.distance_to(anchor_point)
	_anchor_collider_rid = result.get("rid", RID())
	_low_momentum_timer = 0.0
	_fresh_grapple = true
	is_grappling = true
	_shoot_was_held = true
	_last_los_chest = hand_origin
	_rope_is_bent = false
	_bend_contact_point = Vector3.ZERO
	_bend_angle_deg = 0.0

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
	player.move_and_slide()

	# --- Release conditions ---
	if player.player_input.action_jump:
		_do_release(true)
		return

	# --- Rope LOS check ---
	_los_frame_counter += 1
	if _los_frame_counter >= ROPE_LOS_INTERVAL:
		_los_frame_counter = 0
		if _is_rope_obstructed():
			_do_release(false)
			return

	# --- Safety: absurd distance = release ---
	if player.global_position.distance_to(anchor_point) > MAX_GRAPPLE_RANGE * 1.5:
		_do_release(false)

	_was_on_floor = on_floor


func _is_rope_obstructed() -> bool:
	## Rope obstruction check with swept triangle + half-capsule "go around" paths.
	##
	## 1. Center check — two parts:
	##    a. Swept-triangle: a flat triangle (prev_chest, current_chest, anchor)
	##       tests the exact area the rope swept through between LOS checks.
	##    b. Current rope: single ray from current chest → anchor.
	##    First hit = center contact.
	## 2. Cloud fan: CLOUD_FAN_RAYS spread in the swing plane to map the center
	##    obstacle's 2D extent.  Same-RID hits build the contact cloud.
	## 3. One pill centered on the rope, split into left/right halves (thin shells).
	##    Each half is a ConvexPolygonShape3D — the outer shell surface of one
	##    side of the capsule.  This checks the path the rope would take going
	##    around the obstacle, not the full interior volume.
	##    If blocked, shrink the radius (0.5×, 0.25×, 0.75×) to see if the rope
	##    can squeeze through a narrower gap.
	##    a. intersect_shape() — if center obstacle RID overlaps → blocked (same object).
	##    b. collide_shape() — different objects: only contacts within ARC_CONTACT_RADIUS
	##       of the nearest cloud point count.
	## 4. Both halves blocked at all subdivisions → rope cut.
	var space_state := player.get_world_3d().direct_space_state
	# Use hand position — matches the fire raycast origin, so the LOS
	# check and fire ray agree on what terrain blocks the rope.
	var player_chest: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	var excludes: Array[RID] = [player.get_rid()]
	if _anchor_collider_rid.is_valid():
		excludes.append(_anchor_collider_rid)

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

	# --- Step 1: Center rope check with swept-triangle detection ---
	# The rope sweeps a triangle between LOS checks: prev_chest → current_chest
	# → anchor.  A flat ConvexPolygonShape3D (3 coplanar verts) tests if ANY
	# geometry intersects this swept area — no gaps, no discrete rays.
	# If the triangle is degenerate (player didn't move), falls back to a
	# single ray from current_chest → anchor.
	_has_center_contact = false
	_center_contact_cloud = []
	_center_contact_rid = RID()
	_arc_contacts = [[], []]

	var prev_chest: Vector3 = _last_los_chest if _last_los_chest.length() > 0.1 else player_chest
	_prev_los_chest = prev_chest  # Store for debug visualization
	_last_los_chest = player_chest  # Update for next check

	var center_hit_result: Dictionary = {}

	# A) Swept-triangle check — flat triangle (prev_chest, current_chest, anchor)
	var sweep_vec: Vector3 = player_chest - prev_chest
	var sweep_len: float = sweep_vec.length()
	if sweep_len > 0.05:
		# Set the 3 vertices of the triangle directly in world space.
		# ConvexPolygonShape3D points are in local space of the query transform,
		# so we use an identity transform and pass world-space coords.
		_center_sweep_shape.points = PackedVector3Array([prev_chest, player_chest, anchor_point])
		_center_sweep_query.transform = Transform3D.IDENTITY
		_center_sweep_query.exclude = excludes
		var sweep_overlaps := space_state.intersect_shape(_center_sweep_query, 8)
		if not sweep_overlaps.is_empty():
			# Geometry intersects the swept triangle — find the contact point.
			# Ray from prev_chest toward anchor to locate the actual hit.
			var confirm_query := PhysicsRayQueryParameters3D.create(prev_chest, anchor_point)
			confirm_query.exclude = excludes
			confirm_query.collision_mask = 1
			var confirm_result := space_state.intersect_ray(confirm_query)
			if not confirm_result.is_empty():
				if confirm_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
					center_hit_result = confirm_result

	# B) Current rope ray — standard single ray from current chest to anchor
	if center_hit_result.is_empty():
		var rope_query := PhysicsRayQueryParameters3D.create(player_chest, anchor_point)
		rope_query.exclude = excludes
		rope_query.collision_mask = 1
		var rope_result := space_state.intersect_ray(rope_query)
		if not rope_result.is_empty():
			if rope_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
				center_hit_result = rope_result

	if center_hit_result.is_empty():
		_pill_half_blocked = [0, 0]
		if _rope_is_bent:
			# Obstacle left the center ray.  Only snap if the bend was
			# significant — i.e. the angle had grown past the straightened
			# threshold while the obstacle was present.  For thin bars the
			# angle never gets large so the rope just clears.
			if _bend_angle_deg > BEND_STRAIGHTENED_DEG:
				# Rope was meaningfully bent and obstacle vanished → snap
				_rope_is_bent = false
				_bend_angle_deg = 0.0
				return true
			# Bend was negligible — just clear state
			_rope_is_bent = false
			_bend_angle_deg = 0.0
		return false

	# Record center contact
	_center_contact_point = center_hit_result.position
	_center_contact_rid = center_hit_result.get("rid", RID())
	_has_center_contact = true

	# Track bend angle at contact point
	_bend_angle_deg = _compute_bend_angle_deg(player_chest, _center_contact_point)
	_bend_contact_point = _center_contact_point
	_rope_is_bent = true

	# --- Step 2: Build contact cloud via fan rays ---
	# Cast rays fanned out in the swing plane across the obstacle to map its
	# 2D extent.  Only hits on the same RID contribute to the cloud.
	_center_contact_cloud.append(_center_contact_point)  # The center hit is always in the cloud

	var fan_spread: float = PILL_RADIUS  # Max offset from center in swing_normal direction
	for fi in CLOUD_FAN_RAYS:
		# Spread from -fan_spread to +fan_spread
		var t: float = -1.0 + 2.0 * float(fi) / float(CLOUD_FAN_RAYS - 1) if CLOUD_FAN_RAYS > 1 else 0.0
		var fan_offset: Vector3 = swing_normal * t * fan_spread
		var fan_from: Vector3 = player_chest + fan_offset
		var fan_to: Vector3 = anchor_point + fan_offset
		var fan_query := PhysicsRayQueryParameters3D.create(fan_from, fan_to)
		fan_query.exclude = excludes
		fan_query.collision_mask = 1
		var fan_result := space_state.intersect_ray(fan_query)
		if not fan_result.is_empty():
			var hit_rid: RID = fan_result.get("rid", RID())
			if hit_rid == _center_contact_rid:
				_center_contact_cloud.append(fan_result.position)

	# --- Step 3-4: Check half-capsule shapes with shrinking radius ---
	# One pill centered on the rope, split into left/right halves along the
	# swing plane.  Each half is a ConvexPolygonShape3D (flat face on the
	# split plane, hemisphere on the outside).  If blocked, shrink radius
	# and retry to see if it can squeeze through a gap.
	#
	# Subdivision levels (radius multiplier):
	# Level 0: 1.0× (full radius)
	# Level 1: 0.5× (half radius)
	# Level 2: 0.25×, 0.75× (quarter and three-quarter)
	# Stop at the first clear path.

	# Build the pill transform: centered on the rope, Y = rope direction,
	# X = swing_normal (the split direction).
	var pill_transform := _build_pill_transform(player_chest, rope_dir, swing_normal, rope_len)

	var subdiv_levels: Array[Array] = [
		[1.0],
		[0.5],
		[0.25, 0.75],
	]

	for half_idx in 2:
		var sign_dir: float = 1.0 if half_idx == 0 else -1.0
		var half_shape: ConvexPolygonShape3D = _left_half_shape if half_idx == 0 else _right_half_shape
		var half_query: PhysicsShapeQueryParameters3D = _left_half_query if half_idx == 0 else _right_half_query
		var half_is_blocked := true
		var half_contacts: Array[Vector3] = []

		for level in subdiv_levels:
			var level_clear := false
			for frac: float in level:
				var draw_radius: float = PILL_RADIUS * frac
				# Build half-capsule vertices in local space, then set shape
				var verts := _build_half_capsule_points(
					rope_len, draw_radius, sign_dir)
				half_shape.points = verts
				half_query.transform = pill_transform
				half_query.exclude = excludes

				var is_blocked := _check_pill_half_blocked(
					space_state, half_query, half_contacts)
				if not is_blocked:
					level_clear = true
					break  # This radius is clear → half is clear

			if level_clear:
				half_is_blocked = false
				break  # No need to check finer subdivisions

		_arc_contacts[half_idx] = half_contacts
		_pill_half_blocked[half_idx] = 1 if half_is_blocked else 0

		# Lazy evaluation: if left half is clear, skip right half
		if half_idx == 0 and _pill_half_blocked[0] == 0:
			_pill_half_blocked[1] = 0
			return false

	# Both halves blocked — but does the bend angle exceed tolerance?
	var both_blocked: bool = _pill_half_blocked[0] == 1 and _pill_half_blocked[1] == 1
	if both_blocked:
		if _bend_angle_deg <= MAX_BEND_ANGLE_DEG:
			return false  # Within bend tolerance — rope survives
		_rope_is_bent = false
		_bend_angle_deg = 0.0
		return true  # Exceeds tolerance → cut
	return false


func _compute_bend_angle_deg(player_chest: Vector3, contact_point: Vector3) -> float:
	## Compute the bend angle at the anchor between the straight and bent rope.
	## Straight: anchor → player_chest.  Bent: anchor → contact_point.
	var straight_dir: Vector3 = (player_chest - anchor_point).normalized()
	var bent_dir: Vector3 = (contact_point - anchor_point).normalized()
	return rad_to_deg(acos(clampf(straight_dir.dot(bent_dir), -1.0, 1.0)))


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

	# Step A: Check if the center obstacle itself overlaps this half
	var overlaps := space_state.intersect_shape(query, 32)
	for overlap in overlaps:
		if overlap.get("rid", RID()) == _center_contact_rid:
			out_contacts.append(_center_contact_point)
			return true

	# Step B: Different objects — get contact points, filter by cloud distance
	var contacts: Array[Vector3] = []
	contacts.assign(space_state.collide_shape(query, 32))

	var found_nearby := false
	for ci in range(1, contacts.size(), 2):
		var contact_pos: Vector3 = contacts[ci]
		# Skip contacts near the anchor
		if contact_pos.distance_to(anchor_point) < ROPE_LOS_MARGIN:
			continue
		# Check distance to nearest cloud point
		var min_dist: float = INF
		for cloud_pt in _center_contact_cloud:
			var d: float = contact_pos.distance_to(cloud_pt)
			if d < min_dist:
				min_dist = d
		if min_dist <= ARC_CONTACT_RADIUS:
			out_contacts.append(contact_pos)
			found_nearby = true

	return found_nearby


# ======================================================================
#  Server: release grapple
# ======================================================================

func _do_release(with_boost: bool) -> void:
	if not is_grappling:
		return
	if with_boost:
		player.velocity.y += RELEASE_UPWARD_BOOST
	var release_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()
	_rope_is_bent = false
	_bend_contact_point = Vector3.ZERO
	_bend_angle_deg = 0.0
	_show_grapple_release.rpc(release_pos)
	print("Player %d released grapple (speed: %.1f, boost: %s)" % [
		player.peer_id, player.velocity.length(), str(with_boost)])


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
	_rope_is_bent = false
	_bend_contact_point = Vector3.ZERO
	_bend_angle_deg = 0.0
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
		return

	var player_hand: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	var cam_pos: Vector3 = player.camera.global_position if player.camera else player_hand

	var scene_root := get_tree().current_scene

	# --- Bent rope replaces regular rope when active ---
	var show_bent: bool = _rope_is_bent and _bend_contact_point.length() > 0.1
	if show_bent:
		# Draw the bent rope: hand → contact → anchor (orange, two segments)
		var im_bent := ImmediateMesh.new()
		_bent_rope_mesh = MeshInstance3D.new()
		_bent_rope_mesh.mesh = im_bent
		_bent_rope_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bent_rope_mesh.top_level = true
		_bent_rope_mesh.material_override = _bent_rope_material
		_build_rope_ribbon(im_bent, player_hand, _bend_contact_point, cam_pos)
		_build_rope_ribbon(im_bent, _bend_contact_point, anchor_point, cam_pos)
		_draw_debug_circle(im_bent, _bent_contact_material, _bend_contact_point, 0.2, 12)
		if scene_root:
			scene_root.add_child(_bent_rope_mesh)
	else:
		# Draw the straight rope: hand → anchor (blue)
		var im := ImmediateMesh.new()
		_rope_mesh_instance = MeshInstance3D.new()
		_rope_mesh_instance.mesh = im
		_rope_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rope_mesh_instance.top_level = true
		_rope_mesh_instance.material_override = _rope_material
		_build_rope_ribbon(im, player_hand, anchor_point, cam_pos)
		if scene_root:
			scene_root.add_child(_rope_mesh_instance)

	_anchor_light = OmniLight3D.new()
	_anchor_light.light_color = Color(0.3, 0.6, 1.0)
	_anchor_light.light_energy = 2.5
	_anchor_light.omni_range = 4.0
	_anchor_light.omni_attenuation = 1.5
	_anchor_light.position = anchor_point
	if scene_root:
		scene_root.add_child(_anchor_light)

	# --- Pill debug visualization ---
	_build_pill_visual(player_hand)

	# --- Contact point + sphere debug visualization ---
	_build_contact_debug_visual()


func _build_rope_ribbon(im: ImmediateMesh, from: Vector3, to: Vector3, cam_pos: Vector3) -> void:
	var rope_vec: Vector3 = to - from
	var rope_length: float = rope_vec.length()
	if rope_length < 0.01:
		return

	const HALF_WIDTH := 0.06
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
	if _bent_rope_mesh and is_instance_valid(_bent_rope_mesh):
		_bent_rope_mesh.queue_free()
		_bent_rope_mesh = null


# ======================================================================
#  Pill debug visualization
# ======================================================================

func _build_pill_visual(player_chest: Vector3) -> void:
	## Draw solid half-capsule shells (left/right of the rope).
	## The pill is centered on the rope — one shape, two halves.
	## Color coding:
	##   Left half:  green (clear) / red (blocked)
	##   Right half: yellow (clear) / red (blocked)
	## Inner subdivisions (shrunk radius) drawn at 40% opacity.
	var rope_vec: Vector3 = anchor_point - player_chest
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

	# Colors per half
	var half_colors: Array[Color] = []
	for half_idx in 2:
		if _pill_half_blocked[half_idx] == 1:
			half_colors.append(Color(1.0, 0.15, 0.1, 0.25))  # Red (blocked)
		else:
			if half_idx == 0:
				half_colors.append(Color(0.1, 1.0, 0.2, 0.15))  # Green (clear)
			else:
				half_colors.append(Color(1.0, 1.0, 0.1, 0.15))  # Yellow (clear)

	# Draw shells for all subdivision levels
	var all_fracs: Array[float] = [1.0, 0.5, 0.25, 0.75]

	for half_idx in 2:
		var sign_dir: float = 1.0 if half_idx == 0 else -1.0
		var base_color: Color = half_colors[half_idx]

		for fi in all_fracs.size():
			var frac: float = all_fracs[fi]
			var draw_radius: float = PILL_RADIUS * frac

			var alpha_mult: float = 1.0 if fi == 0 else 0.4
			var draw_color := Color(
				base_color.r, base_color.g, base_color.b,
				base_color.a * alpha_mult)

			_draw_half_capsule_solid(im, pill_xform, draw_radius,
				rope_len, sign_dir, draw_color)

	# Also draw the center sweep triangle
	var prev_chest: Vector3 = _prev_los_chest if _prev_los_chest.length() > 0.1 else player_chest
	var sweep_vec: Vector3 = player_chest - prev_chest
	if sweep_vec.length() > 0.05:
		var center_wire_mat := StandardMaterial3D.new()
		center_wire_mat.albedo_color = Color(0.4, 0.75, 1.0, 0.4)
		center_wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		center_wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, center_wire_mat)
		im.surface_add_vertex(prev_chest)
		im.surface_add_vertex(player_chest)
		im.surface_add_vertex(anchor_point)
		im.surface_add_vertex(prev_chest)
		im.surface_end()

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_pill_mesh_instance)


func _draw_half_capsule_solid(im: ImmediateMesh, xform: Transform3D,
		radius: float, rope_len: float, side_sign: float, color: Color) -> void:
	## Draw a solid (filled) half-capsule shell (one side of the pill).
	## xform: origin = player chest, Y = rope dir, X = swing_normal.
	## side_sign: +1.0 = left half (+X), -1.0 = right half (-X).
	## Renders as triangle strips between adjacent latitude rows.
	const ARC_SEGS := 8   # circumference segments for the half-circle
	const CYL_RINGS := 3  # number of rings along the cylinder body
	const HEMI_RINGS := 3 # latitude rings per hemisphere cap

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

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

	# Material for the center contact circle (bright cyan)
	var center_mat := StandardMaterial3D.new()
	center_mat.albedo_color = Color(0.2, 0.9, 1.0, 0.9)
	center_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	center_mat.no_depth_test = true

	# Material for cloud points (dimmer cyan — shows the obstacle extent mapping)
	var cloud_mat := StandardMaterial3D.new()
	cloud_mat.albedo_color = Color(0.15, 0.7, 0.85, 0.7)
	cloud_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cloud_mat.no_depth_test = true

	# Material for arc contact circles (green-blue)
	var arc_mat := StandardMaterial3D.new()
	arc_mat.albedo_color = Color(0.1, 0.8, 0.6, 0.9)
	arc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arc_mat.no_depth_test = true

	# Material for the 1.5m sphere wireframe (white, semi-transparent)
	var sphere_mat := StandardMaterial3D.new()
	sphere_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.3)
	sphere_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sphere_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_mat.no_depth_test = true

	# --- Center contact circle (main hit, larger) ---
	_draw_debug_circle(im, center_mat, _center_contact_point, 0.15, 12)

	# --- Cloud points (fan ray hits on same obstacle, smaller) ---
	for cloud_pt in _center_contact_cloud:
		if cloud_pt.distance_to(_center_contact_point) > 0.01:  # Skip duplicate of center
			_draw_debug_circle(im, cloud_mat, cloud_pt, 0.08, 8)

	# --- Arc contact circles ---
	for half_idx in 2:
		for contact_pos in _arc_contacts[half_idx]:
			_draw_debug_circle(im, arc_mat, contact_pos, 0.1, 10)

	# --- 1.5m wireframe sphere around each cloud point (merged envelope) ---
	# Just draw around center contact to keep it clean — the cloud points show the extent
	_draw_debug_sphere_wireframe(im, sphere_mat, _center_contact_point, ARC_CONTACT_RADIUS, 16, 8)

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
