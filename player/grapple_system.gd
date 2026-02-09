extends Node
class_name GrappleSystem

## Grappling Hook subsystem — Spider-Man-style swing physics.
## Uses constraint-based pendulum: the player is kept on the surface of an
## invisible sphere centered on the anchor point. Gravity + WASD steering
## create the swing arc; the constraint strips radial velocity, preserving
## only tangential momentum. On release, velocity carries over naturally.
##
## Attached as a child of Player in player.tscn.
## Server-authoritative: server runs all physics, clients draw the rope.

# ======================================================================
#  Constants
# ======================================================================

const MAX_GRAPPLE_RANGE := 80.0       ## Raycast distance for finding anchor
const SWING_STEER_STRENGTH := 15.0    ## WASD influence on swing direction (m/s²)
const SWING_PUMP_STRENGTH := 8.0      ## Forward input pumps momentum along swing velocity
const SWING_GRAVITY := 17.5           ## Same as player gravity for consistency
const ROPE_REEL_SPEED := 4.5          ## Rope shortens per second for natural upswing
const ROPE_PULL_STRENGTH := 6.0      ## Upward pull when below anchor — keeps you off the ground
const RELEASE_UPWARD_BOOST := 3.0     ## Vertical speed added on jump-release
const MIN_ROPE_LENGTH := 3.0          ## Stop reeling at this distance

## Proximity dampening — reduces steering/pull when close to anchor to prevent
## bobbing and jittery oscillation near walls.
const PROXIMITY_DAMPEN_RANGE := 8.0   ## Distance below which dampening begins (meters)
const PROXIMITY_MIN_FACTOR := 0.1     ## Minimum multiplier at point-blank (10% control)

## Ground friction while grappled — normal-force-dependent, same feel as slide friction.
## Friction = GROUND_FRICTION_COEFF * normal_force
## Normal force = gravity * (1 - rope_upward_component)
## Anchor above you → rope lifts you → near-zero friction (graze and keep going).
## Anchor level/below → no lift → full friction (dragging yourself is slow).
const GROUND_FRICTION_COEFF := 0.53   ## Friction coefficient — ~20% above old value (was 0.44)
const GROUND_STEER_MULT := 0.3        ## WASD steering is weaker on ground

## Ground-stick — makes it progressively harder to leave the ground while grappling
## along the surface. Ramps up over ~1 second of continuous ground contact.
const GROUND_STICK_MAX := 14.0        ## Maximum downward force at full ramp (m/s²)
const GROUND_STICK_RAMP_TIME := 1.0   ## Seconds to reach full ground-stick strength

## Rope line-of-sight — cut if geometry obstructs the line
const ROPE_LOS_MARGIN := 2.0          ## Ignore obstruction within this distance of anchor
const ROPE_LOS_INTERVAL := 3          ## Check every N physics frames

# ======================================================================
#  Synced state (replicated via ServerSync)
# ======================================================================

var is_grappling: bool = false
var anchor_point: Vector3 = Vector3.ZERO

# ======================================================================
#  Internal state (server only)
# ======================================================================

var _rope_length: float = 0.0
var _shoot_was_held: bool = false      ## Edge detection for shoot toggle
var _los_frame_counter: int = 0        ## Frame counter for rope LOS checks
var _was_on_floor: bool = false        ## Track floor contact for impact detection
var _anchor_collider_rid: RID = RID()  ## RID of the object the hook is attached to

# ======================================================================
#  Client VFX state
# ======================================================================

var _rope_mesh_instance: MeshInstance3D = null
var _anchor_light: OmniLight3D = null
var _rope_material: StandardMaterial3D = null

# ======================================================================
#  Player reference
# ======================================================================

var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p
	# Pre-create the rope material once (reuse each frame)
	_rope_material = StandardMaterial3D.new()
	_rope_material.albedo_color = Color(0.4, 0.75, 1.0, 0.95)
	_rope_material.emission_enabled = true
	_rope_material.emission = Color(0.3, 0.6, 1.0)
	_rope_material.emission_energy_multiplier = 4.0
	_rope_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED


func is_active() -> bool:
	return is_grappling


func _get_proximity_factor() -> float:
	## Returns 1.0 at full range, smoothly drops to PROXIMITY_MIN_FACTOR near the anchor.
	## Uses smoothstep for a natural feel — no dampening far away, progressive near anchor.
	var dist: float = player.global_position.distance_to(anchor_point)
	if dist >= PROXIMITY_DAMPEN_RANGE:
		return 1.0
	var t: float = dist / PROXIMITY_DAMPEN_RANGE  # 0 at anchor, 1 at threshold
	# Smoothstep: 3t² - 2t³ (starts and ends with zero derivative)
	var smooth: float = t * t * (3.0 - 2.0 * t)
	return lerpf(PROXIMITY_MIN_FACTOR, 1.0, smooth)


func handle_shoot_input(shoot_held: bool) -> void:
	## Called every frame by player.gd while a grapple gadget is equipped.
	## Handles edge detection: press fires, re-press while grappling releases.
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
	## Server-only: raycast from camera to find anchor point.
	if is_grappling:
		return

	var space_state := player.get_world_3d().direct_space_state
	var cam_origin: Vector3 = player.camera.global_position
	var cam_forward: Vector3 = -player.camera.global_transform.basis.z

	var far_point := cam_origin + cam_forward * MAX_GRAPPLE_RANGE
	var query := PhysicsRayQueryParameters3D.create(cam_origin, far_point)
	query.exclude = [player.get_rid()]
	query.collision_mask = 1  # World geometry only

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return

	# Anchor found — start swinging
	anchor_point = result.position
	_rope_length = player.global_position.distance_to(anchor_point)
	_anchor_collider_rid = result.get("rid", RID())
	is_grappling = true
	_shoot_was_held = true  # Prevent immediate re-fire/release on same frame

	# End slide/crouch if active (same pattern as kamikaze_system.activate)
	var slide_crouch: SlideCrouchSystem = player.slide_crouch
	if slide_crouch.is_sliding:
		slide_crouch.end_slide()
	if slide_crouch.is_crouching:
		slide_crouch.end_crouch()

	# Broadcast fire VFX
	var hand_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	_show_grapple_fire.rpc(hand_pos, anchor_point)

	print("Player %d fired grapple (anchor: %s, rope: %.1fm)" % [
		player.peer_id, str(anchor_point), _rope_length])


# ======================================================================
#  Server: swing physics (constraint-based pendulum)
# ======================================================================

func process(delta: float) -> void:
	## Server-only: run swing physics each frame while grappling.
	if not is_grappling:
		return

	# --- Update camera look from input ---
	player.rotation.y = player.player_input.look_yaw
	player.camera_pivot.rotation.x = player.player_input.look_pitch

	var on_floor: bool = player.is_on_floor()

	# --- 1. Apply gravity ---
	if not on_floor:
		player.velocity.y -= SWING_GRAVITY * delta

	_was_on_floor = on_floor

	# --- 2. Ground friction — normal-force-dependent ---
	# The rope pulling upward reduces how hard you press into the ground,
	# so grazing the floor mid-swing barely slows you (low normal force),
	# while dragging yourself along with a slack/downward rope is very slow.
	if on_floor:
		# Compute rope pull direction and its upward component
		var to_anchor: Vector3 = anchor_point - player.global_position
		var rope_dir: Vector3 = to_anchor.normalized() if to_anchor.length() > 0.1 else Vector3.ZERO
		# How much the rope is pulling you upward (positive = lifting, negative = pressing down)
		var rope_upward: float = rope_dir.y  # ranges from -1 (straight down) to +1 (straight up)

		# Normal force: gravity pressing you down, minus any upward rope pull
		# When rope pulls upward (anchor above you), normal force drops → less friction
		# rope_upward of +0.7 means the rope is mostly lifting you → very little friction
		# rope_upward of -0.3 means the rope pulls you into the ground → more friction
		var normal_force: float = SWING_GRAVITY * (1.0 - clampf(rope_upward, -0.5, 0.95))
		var friction_decel: float = GROUND_FRICTION_COEFF * normal_force

		var horiz := Vector2(player.velocity.x, player.velocity.z)
		var horiz_speed := horiz.length()
		if horiz_speed > 0.01 and friction_decel > 0.01:
			var friction_loss: float = friction_decel * delta
			var new_speed: float = maxf(horiz_speed - friction_loss, 0.0)
			var ratio: float = new_speed / horiz_speed
			player.velocity.x *= ratio
			player.velocity.z *= ratio
		# Kill any downward velocity on floor
		if player.velocity.y < 0.0:
			player.velocity.y = 0.0

	# --- 3. Apply WASD steering (camera-relative horizontal) ---
	# Proximity dampening: reduce player control when very close to the anchor
	# to prevent jittery bobbing near walls.
	var prox: float = _get_proximity_factor()

	var input_dir: Vector2 = player.player_input.input_direction
	if input_dir.length() > 0.01:
		var cam_forward: Vector3 = -player.camera.global_transform.basis.z
		var cam_right: Vector3 = player.camera.global_transform.basis.x
		cam_forward.y = 0.0
		cam_right.y = 0.0
		if cam_forward.length() > 0.001:
			cam_forward = cam_forward.normalized()
		if cam_right.length() > 0.001:
			cam_right = cam_right.normalized()

		# Steering is heavily nerfed on ground
		var steer_mult: float = GROUND_STEER_MULT if on_floor else 1.0

		# Lateral steering (left/right) — scaled by proximity
		var steer: Vector3 = cam_right * input_dir.x * SWING_STEER_STRENGTH * steer_mult * prox
		# Forward pumping — only works in the air, scaled by proximity
		if not on_floor and input_dir.y < -0.1 and player.velocity.length() > 0.5:
			var swing_dir: Vector3 = player.velocity.normalized()
			steer += swing_dir * SWING_PUMP_STRENGTH * absf(input_dir.y) * prox
		# Backward = slight brake, scaled by proximity
		elif input_dir.y > 0.1:
			steer += cam_forward * input_dir.y * SWING_STEER_STRENGTH * 0.5 * steer_mult * prox

		player.velocity += steer * delta

	# --- 4. Upward rope pull — prevents sinking into the ground ---
	# When the anchor is above you, the taut rope actively pulls you upward.
	# Stronger when you're near or on the floor and the anchor is overhead.
	# Dampened by proximity to prevent oscillation when close to the anchor.
	var pull_dir: Vector3 = anchor_point - player.global_position
	var anchor_above: float = clampf(pull_dir.normalized().y, 0.0, 1.0)
	if anchor_above > 0.1:
		var pull_force: float = ROPE_PULL_STRENGTH * anchor_above * prox
		# Stronger pull when falling or on the ground — prevents dragging
		if player.velocity.y <= 0.0:
			player.velocity.y += pull_force * delta

	# --- 5. Reel rope shorter for upswing feel (only in air) ---
	if not on_floor:
		_rope_length = maxf(_rope_length - ROPE_REEL_SPEED * delta, MIN_ROPE_LENGTH)

	# --- 6. Predict next position ---
	var next_pos: Vector3 = player.global_position + player.velocity * delta

	# --- 7. Constraint: clamp to rope sphere ---
	var offset: Vector3 = next_pos - anchor_point
	var dist: float = offset.length()
	if dist > _rope_length and dist > 0.001:
		next_pos = anchor_point + offset.normalized() * _rope_length
		player.velocity = (next_pos - player.global_position) / maxf(delta, 0.001)

	# --- 8. Move (CharacterBody3D handles floor/wall collisions) ---
	player.move_and_slide()

	# --- 9. Check release conditions ---
	if player.player_input.action_jump:
		_do_release(true)
		return

	# Shoot release is handled by handle_shoot_input() in player.gd

	# --- 10. Rope line-of-sight: cut if geometry blocks the line ---
	_los_frame_counter += 1
	if _los_frame_counter >= ROPE_LOS_INTERVAL:
		_los_frame_counter = 0
		if _is_rope_obstructed():
			_do_release(false)
			return

	# --- 11. Safety: absurd distance = release ---
	if player.global_position.distance_to(anchor_point) > MAX_GRAPPLE_RANGE * 1.5:
		_do_release(false)


func _is_rope_obstructed() -> bool:
	## Raycast from player chest to anchor. If something blocks the line
	## (and isn't the object the hook is attached to or very close to it),
	## the rope is obstructed.
	var space_state := player.get_world_3d().direct_space_state
	var player_chest: Vector3 = player.global_position + Vector3(0, 1.0, 0)

	var excludes: Array[RID] = [player.get_rid()]
	# Exclude the object the hook is anchored to — swinging around it shouldn't cut the rope
	if _anchor_collider_rid.is_valid():
		excludes.append(_anchor_collider_rid)

	var query := PhysicsRayQueryParameters3D.create(player_chest, anchor_point)
	query.exclude = excludes
	query.collision_mask = 1

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return false  # Clear line of sight

	# Allow obstruction if the hit is very close to the anchor (wall the hook is on)
	var hit_pos: Vector3 = result.position
	if hit_pos.distance_to(anchor_point) < ROPE_LOS_MARGIN:
		return false  # Hit the wall the hook is attached to — fine

	return true  # Something in the way — cut the rope


# ======================================================================
#  Server: release grapple
# ======================================================================

func _do_release(with_boost: bool) -> void:
	## Release the grapple. Velocity carries over naturally from the swing.
	if not is_grappling:
		return

	# Optional upward boost on jump-release
	if with_boost:
		player.velocity.y += RELEASE_UPWARD_BOOST

	# No artificial speed floor — you keep whatever momentum you have

	var release_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)

	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()

	# Broadcast release VFX
	_show_grapple_release.rpc(release_pos)

	print("Player %d released grapple (speed: %.1f, boost: %s)" % [
		player.peer_id, player.velocity.length(), str(with_boost)])


func reset_state() -> void:
	## Hard reset — used on death.
	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()
	_shoot_was_held = false
	_los_frame_counter = 0
	_was_on_floor = false
	cleanup()


# ======================================================================
#  Client: rope visual
# ======================================================================

func client_process_visuals(_delta: float) -> void:
	## Client-side: draw a visible tube/ribbon rope from player hand to anchor.
	cleanup()

	if not is_grappling:
		return

	var im := ImmediateMesh.new()
	_rope_mesh_instance = MeshInstance3D.new()
	_rope_mesh_instance.mesh = im
	_rope_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rope_mesh_instance.top_level = true
	_rope_mesh_instance.material_override = _rope_material

	var player_hand: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	var cam_pos: Vector3 = player.camera.global_position if player.camera else player_hand
	_build_rope_ribbon(im, player_hand, anchor_point, cam_pos)

	# Glowing light at the anchor point so you can see where you're hooked
	_anchor_light = OmniLight3D.new()
	_anchor_light.light_color = Color(0.3, 0.6, 1.0)
	_anchor_light.light_energy = 2.5
	_anchor_light.omni_range = 4.0
	_anchor_light.omni_attenuation = 1.5
	_anchor_light.position = anchor_point

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_rope_mesh_instance)
		scene_root.add_child(_anchor_light)


func _build_rope_ribbon(im: ImmediateMesh, from: Vector3, to: Vector3, cam_pos: Vector3) -> void:
	## Build a camera-facing ribbon (flat strip) between two points.
	## The ribbon always faces the camera so it looks thick from any angle.
	var rope_vec: Vector3 = to - from
	var rope_length: float = rope_vec.length()
	if rope_length < 0.01:
		return

	const HALF_WIDTH := 0.06        # ribbon half-width (visible thickness)
	const SEGMENTS := 24            # subdivisions along the rope
	const SAG_FACTOR := 0.03        # subtle catenary dip in the middle

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	for i in SEGMENTS + 1:
		var t: float = float(i) / float(SEGMENTS)
		var pos: Vector3 = from.lerp(to, t)
		# Catenary sag
		pos.y -= sin(t * PI) * rope_length * SAG_FACTOR

		# Compute ribbon width direction: perpendicular to both the rope
		# direction and the camera view direction at this point.
		var view_dir: Vector3 = (cam_pos - pos).normalized()
		var rope_dir: Vector3 = rope_vec.normalized()
		var width_dir: Vector3 = rope_dir.cross(view_dir)
		if width_dir.length() < 0.001:
			# Fallback if camera is exactly along the rope
			width_dir = Vector3.UP.cross(rope_dir)
		width_dir = width_dir.normalized()

		# Two vertices: one on each side of the ribbon
		im.surface_add_vertex(pos + width_dir * HALF_WIDTH)
		im.surface_add_vertex(pos - width_dir * HALF_WIDTH)

	im.surface_end()


func cleanup() -> void:
	## Free rope mesh and anchor light.
	if _rope_mesh_instance and is_instance_valid(_rope_mesh_instance):
		_rope_mesh_instance.queue_free()
		_rope_mesh_instance = null
	if _anchor_light and is_instance_valid(_anchor_light):
		_anchor_light.queue_free()
		_anchor_light = null


# ======================================================================
#  RPCs — visual effects broadcast to all clients
# ======================================================================

@rpc("authority", "call_local", "reliable")
func _show_grapple_fire(from: Vector3, to: Vector3) -> void:
	## Flash at anchor point when grapple connects.
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Bright flash at anchor
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

	# Small impact spark at anchor
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
	## Small burst at release point.
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
