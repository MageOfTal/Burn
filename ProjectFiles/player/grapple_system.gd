extends PlayerSubsystem
class_name GrappleSystem

## Grappling Hook — position-based constraint pendulum.
##
## Based on Jamie Fristrom's Spider-Man 2 technique: the rope is an invisible
## spherical wall.  Each frame we predict where the player will be, snap that
## position onto the sphere surface if it overshoots, and derive the new
## velocity from the corrected position.  The outward radial velocity is
## automatically eliminated; what remains is tangential (the swing).
##
## On the ground, Jolt's floor contact blocks the downward component of the
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
const RELEASE_PITCH_UP := deg_to_rad(20.0)   ## Tilt velocity 20° upward on release
const RELEASE_PITCH_MAX := deg_to_rad(25.0)  ## Never tilt above 25° upward
const RELEASE_BOOST_MIN_SPEED := 2.0         ## No boost below this speed (m/s)
const RELEASE_BOOST_MAX_SPEED := 43.0        ## Full boost at this speed (m/s)
const RELEASE_BOOST_MIN := 1.0               ## Boost at min speed (m/s)
const RELEASE_BOOST_MAX := 7.0               ## Boost at max speed (m/s)
const RELEASE_BOOST_SPEED_CAP := 50.0        ## Boost can't push total speed past this (m/s)
const MIN_ROPE_LENGTH := 3.0          ## Stop reeling at this distance
const ROPE_REEL_SPEED := 3.0          ## Rope shortens this many m/s (creates pull)

## Steering — A/D rotates velocity direction, W pumps swing arc, S brakes.
const STEER_RATE := 1.8               ## A/D rotation rate (rad/s at full input)
const SWING_PUMP_STRENGTH := 8.0      ## W pumps along swing velocity (air only)

## Launch nudge — small upward kick on fire to unstick from the floor.
const LAUNCH_NUDGE_SPEED := 8.0       ## Max directional speed added on fire (m/s)
const LAUNCH_NUDGE_COOLDOWN := 1.0    ## Seconds after release before nudge is allowed again


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

## Rope thickness — shared by the sweep prism, the leaf legs, the arc-sweep
## localizer, and the visual ribbon so they all agree on the rope's width.
const ROPE_RADIUS := 0.04

## Leaf go-around check — can the rope detour around the obstacle?
## For each side of the swing plane we test the surface the rope would sweep
## while wrapping around the obstacle: bent paths chest → bend → anchor,
## pinned at both ends and widest at the obstacle, with the bend direction
## fanned through a half-circle of LEAF_ARC_POINTS directions on that side.
## The result is a rounded leaf-of-revolution surface (a shallow double
## cone), tiled by fan triangles that share edges — continuous, no gaps.
## Only the surface is tested, never the interior (the obstacle itself sits
## there).  Tiles are extruded ±ROPE_RADIUS using the same prism trick as
## the center sweep.  The deviation tapers linearly to zero toward both
## ends, so the test never measures farther from the rope than the width
## being tried at the obstacle itself.  Widths are tried widest-first; the
## first width whose whole surface is clear proves the side is passable.
## Both sides fully blocked at every width → CUT.
const LEAF_MAX_WIDTH := 0.35          ## Widest detour distance at the bend point
const LEAF_WIDTH_FRACTIONS: Array[float] = [1.0, 0.75, 0.5, 0.25]
const LEAF_ARC_POINTS := 10           ## Bend directions per side (half-circle fan)

## Center sweep — an oriented slab covering the triangle (prev_chest,
## current_chest, anchor) the rope swept through between LOS checks,
## rope-diameter thick.  The slab is the triangle's bounding box in its own
## plane, so it over-covers the triangle slightly — extra candidates are
## filtered by per-obstacle localization afterwards.
##
## THREADING: all slab queries (sweep, leaf tiles, arc localizer) share ONE
## immutable BoxShape3D posed via per-query transforms.  Never mutate shape
## data (e.g. ConvexPolygonShape3D.points) per tick — under threaded physics
## shape data goes through a deferred command queue while queries execute
## immediately, giving null/stale shapes and data races (crash).  Query
## transforms are call parameters and are always same-tick correct.

## Binary search — find the interpolation t where the rope first contacts
## each obstacle within the swept triangle.
const BISECT_ITERATIONS := 4          ## 4 iterations → ~6% precision (~0.01m at 240Hz)


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

## Boost gate — must grapple for this long before release boost is allowed.
var _grapple_time: float = 0.0        ## Seconds spent in current grapple
const MIN_GRAPPLE_TIME_FOR_BOOST := 0.25

## Launch nudge cooldown — tracks when the last grapple was released.
var _last_release_time: float = -999.0 ## Time.get_ticks_msec()/1000 of last release


## Debug timing — spike detection
var _debug_last_print_time: float = 0.0          ## Throttle prints to 1/sec
const DEBUG_SPIKE_THRESHOLD_US := 500.0           ## Print if any section takes > 500µs

# ======================================================================
#  Client VFX state
# ======================================================================

var _rope_mesh_instance: MeshInstance3D = null
var _anchor_light: OmniLight3D = null
var _rope_material: StandardMaterial3D = null
var _spark_material: StandardMaterial3D = null
var _leaf_mesh_instance: MeshInstance3D = null
var _contact_mesh_instance: MeshInstance3D = null

## Pre-cached debug materials (created once in setup, reused every frame)
var _leaf_clear_left_mat: StandardMaterial3D = null        # Green (left side path clear)
var _leaf_clear_right_mat: StandardMaterial3D = null       # Yellow (right side path clear)
var _leaf_blocked_mat: StandardMaterial3D = null           # Red (path blocked)
var _leaf_narrow_clear_left_mat: StandardMaterial3D = null # Green 40% (narrower widths)
var _leaf_narrow_clear_right_mat: StandardMaterial3D = null # Yellow 40% (narrower widths)
var _leaf_narrow_blocked_mat: StandardMaterial3D = null    # Red 40% (narrower widths)
var _sweep_wire_mat: StandardMaterial3D = null             # Blue wireframe (center sweep triangle)
var _contact_center_mat: StandardMaterial3D = null         # Bright cyan (center contact)
var _safe_zone_mat: StandardMaterial3D = null              # Green semi-transparent (no-sever radius)
var _safe_zone_mesh_instance: MeshInstance3D = null

## Leaf debug state — set by server obstruction check, read by client visuals.
## 0 = clear, 1 = blocked.  Index 0 = left side (swing direction), 1 = right side.
var _side_blocked: Array[int] = [0, 0]
## Width fraction that cleared per side (-1.0 = blocked or not tested).
var _side_pass_frac: Array[float] = [-1.0, -1.0]
## The swing-perpendicular direction used to orient the leaf sides.
var _dbg_swing_normal: Vector3 = Vector3.ZERO
## Previous LOS chest position — stored for sweep triangle visualization.
var _prev_los_chest: Vector3 = Vector3.ZERO
## Every leaf surface tested this check: {chest, arc, side, frac, blocked}.
## arc = PackedVector3Array of bend points fanned across the side's half-circle.
var _leaf_candidates: Array[Dictionary] = []

## The ONE immutable query shape: a canonical 1×1×(rope diameter) slab.
## Every slab-shaped check (sweep triangle, leaf tiles, arc localizer) poses
## and scales it purely via the query transform — shape data is never
## mutated at runtime (see threading note above).
var _slab_shape: BoxShape3D = null
var _leaf_tile_query: PhysicsShapeQueryParameters3D = null
var _center_sweep_query: PhysicsShapeQueryParameters3D = null
var _arc_sweep_query: PhysicsShapeQueryParameters3D = null

## Debug: center-ray contact point (where the rope hits geometry).
var _center_contact_point: Vector3 = Vector3.ZERO
var _has_center_contact: bool = false
## Debug: RID of the center obstacle.
var _center_contact_rid: RID = RID()

## Debug: on-screen label showing bend angle, wrap count, rope state.
var _debug_label: Label = null

func setup(p: Player) -> void:
	super.setup(p)
	_rope_material = StandardMaterial3D.new()
	_rope_material.albedo_color = Color(0.3, 0.6, 1.0, 1.0)
	_rope_material.emission_enabled = true
	_rope_material.emission = Color(0.2, 0.5, 1.0)
	_rope_material.emission_energy_multiplier = 2.0
	_rope_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rope_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Pre-cache leaf debug materials (avoids per-frame allocations)
	_leaf_clear_left_mat = _make_leaf_mat(Color(0.1, 1.0, 0.2, 0.18))
	_leaf_clear_right_mat = _make_leaf_mat(Color(1.0, 1.0, 0.1, 0.18))
	_leaf_blocked_mat = _make_leaf_mat(Color(1.0, 0.15, 0.1, 0.3))
	_leaf_narrow_clear_left_mat = _make_leaf_mat(Color(0.1, 1.0, 0.2, 0.07))
	_leaf_narrow_clear_right_mat = _make_leaf_mat(Color(1.0, 1.0, 0.1, 0.07))
	_leaf_narrow_blocked_mat = _make_leaf_mat(Color(1.0, 0.15, 0.1, 0.12))

	# Pre-cache center sweep wireframe material
	_sweep_wire_mat = StandardMaterial3D.new()
	_sweep_wire_mat.albedo_color = Color(0.4, 0.75, 1.0, 0.4)
	_sweep_wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sweep_wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Pre-cache contact debug materials
	_contact_center_mat = _make_contact_mat(Color(0.2, 0.9, 1.0, 0.9))

	_safe_zone_mat = StandardMaterial3D.new()
	_safe_zone_mat.albedo_color = Color(0.2, 1.0, 0.3, 0.25)
	_safe_zone_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_safe_zone_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_safe_zone_mat.no_depth_test = true

	# The one immutable slab shape shared by all obstruction queries.
	# Created once here so its data is long flushed before gameplay; from
	# then on only query TRANSFORMS vary (threaded-physics safe — mutating
	# shape data per tick races the server command queue).
	_slab_shape = BoxShape3D.new()
	_slab_shape.size = Vector3(1.0, 1.0, ROPE_RADIUS * 2.0)
	_slab_shape.margin = 0.001

	_leaf_tile_query = PhysicsShapeQueryParameters3D.new()
	_leaf_tile_query.shape = _slab_shape
	_leaf_tile_query.collision_mask = 1 | 1024 | 2048
	_leaf_tile_query.collide_with_bodies = true
	_leaf_tile_query.collide_with_areas = false

	_center_sweep_query = PhysicsShapeQueryParameters3D.new()
	_center_sweep_query.shape = _slab_shape
	_center_sweep_query.collision_mask = 1 | 1024 | 2048
	_center_sweep_query.collide_with_bodies = true
	_center_sweep_query.collide_with_areas = false

	_arc_sweep_query = PhysicsShapeQueryParameters3D.new()
	_arc_sweep_query.shape = _slab_shape
	_arc_sweep_query.collision_mask = 1 | 1024 | 2048
	_arc_sweep_query.collide_with_bodies = true
	_arc_sweep_query.collide_with_areas = false

	# Fire-spark material — cached here instead of created per fire: a brand
	# new material's first draw compiles a render pipeline mid-gameplay.
	_spark_material = StandardMaterial3D.new()
	_spark_material.albedo_color = Color(0.5, 0.8, 1.0)
	_spark_material.emission_enabled = true
	_spark_material.emission = Color(0.3, 0.6, 1.0)
	_spark_material.emission_energy_multiplier = 5.0
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Pipeline warm-up — draw every runtime-created grapple material once NOW,
	# while the WorkerThreadPool is idle.  Async pipeline compilation runs on
	# the pool; first-drawing these at grapple fire can deadlock against
	# wedged terrain/mesh tasks (thread-stack capture 2026-07-07: main thread
	# waiting on pool work at fire, pool tasks waiting on main's queue flush).
	_warm_up_pipelines.call_deferred()

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


func _warm_up_pipelines() -> void:
	## Force one draw of every grapple material in each primitive topology we
	## use (triangle strips for rope/leaf, line strips for wireframes), plus
	## an omni light, so all pipelines compile at spawn instead of at fire.
	## The geometry is millimeter-sized; extra_cull_margin defeats frustum
	## culling so the draw actually submits.
	if not is_inside_tree() or player == null:
		return
	var mats: Array[StandardMaterial3D] = [
		_rope_material, _spark_material,
		_leaf_clear_left_mat, _leaf_clear_right_mat, _leaf_blocked_mat,
		_leaf_narrow_clear_left_mat, _leaf_narrow_clear_right_mat,
		_leaf_narrow_blocked_mat, _sweep_wire_mat,
		_contact_center_mat, _safe_zone_mat,
	]
	var im := ImmediateMesh.new()
	for mat in mats:
		if mat == null:
			continue
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3(0.001, 0.0, 0.0))
		im.surface_add_vertex(Vector3(0.0, 0.001, 0.0))
		im.surface_end()
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		im.surface_add_vertex(Vector3.ZERO)
		im.surface_add_vertex(Vector3(0.001, 0.0, 0.0))
		im.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0
	player.add_child(mi)

	# Warm the omni-light pipeline variants (fire flash + anchor light).
	var light := OmniLight3D.new()
	light.light_energy = 0.001
	light.omni_range = 0.05
	mi.add_child(light)

	get_tree().create_timer(1.0).timeout.connect(mi.queue_free)


func _make_leaf_mat(color: Color) -> StandardMaterial3D:
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
	if is_grappling:
		_grapple_time += delta
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
	query.collision_mask = 1 | 2048

	var result := space_state.intersect_ray(query)
	if result.is_empty():
		return

	# Reject hits beyond grapple range
	if hand_origin.distance_to(result.position) > MAX_GRAPPLE_RANGE:
		return

	anchor_point = result.position

	# Velocity is already correct — Jolt handles position integration, so
	# player.velocity reflects actual movement speed at all times.

	_rope_length = player.global_position.distance_to(anchor_point)
	_anchor_collider_rid = result.get("rid", RID())
	_low_momentum_timer = 0.0
	_fresh_grapple = true
	is_grappling = true
	_grapple_time = 0.0
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

	# Launch nudge — kick toward anchor to unstick from the floor
	# Suppressed if grapple was released less than LAUNCH_NUDGE_COOLDOWN seconds ago
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	var nudge_on_cooldown: bool = (now_sec - _last_release_time) < LAUNCH_NUDGE_COOLDOWN
	var anchor_dist: float = player.global_position.distance_to(anchor_point)
	var dist_factor: float = clampf((anchor_dist - 2.0) / (7.0 - 2.0), 0.0, 1.0)
	if dist_factor > 0.0 and not nudge_on_cooldown:
		var to_anchor: Vector3 = anchor_point - player.global_position
		var nudge_dir: Vector3 = to_anchor.normalized()
		var full_nudge: float = LAUNCH_NUDGE_SPEED * dist_factor

		if GameManager.debug_grapple_horiz_nudge:
			# Directional nudge toward anchor (vertical + horizontal)
			var nudge: Vector3 = nudge_dir * full_nudge

			# Cap vertical component so it doesn't push past 8.5 m/s upward
			if nudge.y > 0.0 and player.velocity.y + nudge.y > 8.5:
				nudge.y = maxf(8.5 - player.velocity.y, 0.0)

			# Cap horizontal component along the toward-anchor direction
			var horiz_dir := Vector3(to_anchor.x, 0.0, to_anchor.z)
			var horiz_len: float = horiz_dir.length()
			if horiz_len > 0.001:
				horiz_dir /= horiz_len
				var nudge_horiz: float = nudge.x * horiz_dir.x + nudge.z * horiz_dir.z
				var vel_horiz: float = player.velocity.x * horiz_dir.x + player.velocity.z * horiz_dir.z
				if nudge_horiz > 0.0 and vel_horiz + nudge_horiz > 8.5:
					var allowed: float = maxf(8.5 - vel_horiz, 0.0)
					var scale: float = allowed / nudge_horiz
					nudge.x *= scale
					nudge.z *= scale

			player.velocity += nudge
		else:
			# Vertical-only nudge
			var nudge_y: float = nudge_dir.y * full_nudge
			if nudge_y > 0.0 and player.velocity.y + nudge_y > 8.5:
				nudge_y = maxf(8.5 - player.velocity.y, 0.0)
			player.velocity.y += nudge_y

		# Ensure minimum vertical lift (tapered by distance)
		var lift: float = 7.0 * dist_factor
		if player.velocity.y < 0.0:
			player.velocity.y += lift
		elif player.velocity.y < lift:
			player.velocity.y = lift

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
	cam_query.collision_mask = 1 | 2048
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
	## 7. Jolt integrates velocity — floor/wall collisions handled natively
	##
	## On the ground, Jolt's floor contact blocks the downward velocity from
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
	# 7. MOVE — Jolt's solver handles floor/wall collisions natively.
	#    On the floor Jolt blocks the downward component of our derived
	#    velocity, so the player glides horizontally.  In the air, the
	#    full velocity applies.
	# =================================================================
	var _t_move := Time.get_ticks_usec()
	# No move_and_slide needed — Jolt integrates velocity on the RigidBody3D directly.
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
	var los_us: float = float(_t_los_end - _t_los) if _t_los > 0 else 0.0
	var now_sec: float = Time.get_ticks_msec() / 1000.0
	if total_us > DEBUG_SPIKE_THRESHOLD_US and (now_sec - _debug_last_print_time) > 1.0:
		_debug_last_print_time = now_sec
		print("[GRAPPLE SPIKE] total=%.0fµs  move=%.0fµs  LOS_check=%.0fµs  other=%.0fµs" % [
			total_us, move_us, los_us, total_us - move_us - los_us])


func _is_rope_obstructed() -> bool:
	## Rope obstruction check — interpolated multi-obstacle, leaf-based.
	##
	## Overview:
	## 1. Swept prism (prev_chest → current_chest → anchor) detects ALL obstacles
	##    the rope swept through between ticks — including thin objects that rays miss.
	## 2. For each obstacle, binary-search to find the interpolation t (0→1) where
	##    the rope first contacts it.  Uses rays first (fast path), falls back to
	##    a swept capsule for thin objects that rays miss.
	## 3. Sort obstacles by t (earliest contact first).
	## 4. Walk through in order: at each obstacle's interpolated chest position,
	##    run the leaf go-around check (bent detour paths on each side of the
	##    swing plane).  If both sides blocked at every width → CUT.
	##    If at least one side has a clear path → continue to next obstacle.
	## 5. If all obstacles have a clear go-around → no cut.
	##
	## Fallback: when the player barely moved (sweep_len < 0.05), skip the swept
	## prism and use traditional bidirectional rope rays instead.

	var _los_t0 := Time.get_ticks_usec()
	var space_state := player.get_world_3d().direct_space_state
	var player_chest: Vector3 = player.global_position + Vector3(0, 1.2, 0)

	# Exclude self and all other players (NOT the anchor collider — the
	# ROPE_LOS_MARGIN safe zone handles near-anchor hits, and excluding a
	# large monolithic body like terrain would make the entire body invisible).
	var excludes: Array[RID] = [player.get_rid()]
	for peer_id in NetworkManager.players:
		var other_player: Player = NetworkManager.players[peer_id]
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

	_dbg_swing_normal = swing_normal

	# Reset debug state
	_has_center_contact = false
	_center_contact_rid = RID()
	_leaf_candidates = []
	_side_blocked = [0, 0]
	_side_pass_frac = [-1.0, -1.0]

	var prev_chest: Vector3 = _last_los_chest if _last_los_chest.length() > 0.1 else player_chest
	_prev_los_chest = prev_chest
	_last_los_chest = player_chest

	# =================================================================
	#  PATH A: Player moved significantly — swept prism multi-obstacle
	# =================================================================
	var sweep_vec: Vector3 = player_chest - prev_chest
	var sweep_len: float = sweep_vec.length()

	if sweep_len > 0.05:
		# Oriented slab covering the swept triangle: Y axis toward the anchor,
		# X axis along the chest motion, thickness = rope diameter (canonical).
		# Slightly over-covers the triangle; localization filters extras.
		var mid_base: Vector3 = (prev_chest + player_chest) * 0.5
		var y_vec: Vector3 = anchor_point - mid_base
		var y_len: float = y_vec.length()
		if y_len < 0.1:
			return false
		var y_dir: Vector3 = y_vec / y_len
		var x_raw: Vector3 = player_chest - prev_chest
		var x_vec: Vector3 = x_raw - y_dir * x_raw.dot(y_dir)
		var x_dir: Vector3
		if x_vec.length() > 0.001:
			x_dir = x_vec.normalized()
		elif absf(y_dir.y) < 0.9:
			# Motion parallel to the rope — thin slab along the rope line.
			x_dir = y_dir.cross(Vector3.UP).normalized()
		else:
			x_dir = y_dir.cross(Vector3.RIGHT).normalized()

		var center: Vector3 = (prev_chest + player_chest + anchor_point) / 3.0
		var half_w: float = 0.001
		var half_l: float = 0.001
		for pt: Vector3 in [prev_chest, player_chest, anchor_point]:
			var d: Vector3 = pt - center
			half_w = maxf(half_w, absf(d.dot(x_dir)))
			half_l = maxf(half_l, absf(d.dot(y_dir)))
		half_w = maxf(half_w, ROPE_RADIUS)

		_center_sweep_query.transform = _slab_transform(center, x_dir, y_dir,
			half_w * 2.0, half_l * 2.0)
		_center_sweep_query.exclude = excludes
		var sweep_overlaps := space_state.intersect_shape(_center_sweep_query, 16)

		if sweep_overlaps.is_empty():
			# Also check current-frame rope rays (catches stationary obstacles
			# that the razor-thin prism might miss due to float precision)
			var fallback_result := _check_rope_rays(space_state, player_chest, excludes)
			if fallback_result.is_empty():
				return false
			# Single obstacle from ray — run leaf check at current position
			return _run_leaf_check_at(space_state, player_chest, rope_dir, rope_len,
				swing_normal, fallback_result.position,
				fallback_result.get("rid", RID()), excludes)

		# --- Collect unique obstacle RIDs from the swept prism ---
		var obstacle_rids: Array[RID] = []
		for overlap in sweep_overlaps:
			var rid: RID = overlap.get("rid", RID())
			if not rid.is_valid():
				continue
			# Skip if it's in our exclude list
			var dominated := false
			for ex in excludes:
				if rid == ex:
					dominated = true
					break
			if dominated:
				continue
			# Deduplicate
			var already := false
			for existing_rid in obstacle_rids:
				if rid == existing_rid:
					already = true
					break
			if not already:
				obstacle_rids.append(rid)

		if obstacle_rids.is_empty():
			return false

		# --- For each obstacle, find interpolation t and contact point ---
		# Each entry: { "t": float, "rid": RID, "contact": Vector3 }
		var obstacle_data: Array[Dictionary] = []

		for obs_rid in obstacle_rids:
			var result := _localize_obstacle(space_state, prev_chest, player_chest,
				obs_rid, excludes, obstacle_rids)
			if not result.is_empty():
				obstacle_data.append(result)

		if obstacle_data.is_empty():
			# Swept prism flagged objects but none could be localized on the rope.
			# Fall back to current-frame rope rays.
			var fallback_result := _check_rope_rays(space_state, player_chest, excludes)
			if fallback_result.is_empty():
				return false
			return _run_leaf_check_at(space_state, player_chest, rope_dir, rope_len,
				swing_normal, fallback_result.position,
				fallback_result.get("rid", RID()), excludes)

		# --- Sort by t (earliest contact first) ---
		obstacle_data.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return a["t"] < b["t"])

		# --- Walk through obstacles, leaf-check each one ---
		for obs in obstacle_data:
			var obs_t: float = obs["t"]

			# Interpolated chest position at this t
			var interp_chest: Vector3 = prev_chest.lerp(player_chest, obs_t)

			# Rope geometry from the interpolated position
			var interp_rope_vec: Vector3 = anchor_point - interp_chest
			var interp_rope_len: float = interp_rope_vec.length()
			if interp_rope_len < 0.1:
				continue
			var interp_rope_dir: Vector3 = interp_rope_vec / interp_rope_len

			# Build swing normal at this interpolated position
			var interp_swing_normal := _compute_swing_normal(interp_rope_dir)

			if _run_leaf_check_at(space_state, interp_chest, interp_rope_dir,
					interp_rope_len, interp_swing_normal, obs["contact"],
					obs["rid"], excludes):
				return true  # Both sides blocked — CUT

			# At least one side clear — can go around this obstacle, check next

		# All obstacles had a way around
		return false

	# =================================================================
	#  PATH B: Player barely moved — traditional rope ray check
	# =================================================================
	var center_hit_result := _check_rope_rays(space_state, player_chest, excludes)

	if center_hit_result.is_empty():
		return false

	# Single obstacle from rays — run leaf check at current position
	return _run_leaf_check_at(space_state, player_chest, rope_dir, rope_len,
		swing_normal, center_hit_result.position,
		center_hit_result.get("rid", RID()), excludes)


func _check_rope_rays(space_state: PhysicsDirectSpaceState3D,
		player_chest: Vector3, excludes: Array[RID]) -> Dictionary:
	## Bidirectional rope rays: player→anchor and anchor→player.
	## Returns the hit result Dictionary, or empty if no obstruction.
	var result: Dictionary = {}

	# Player chest to anchor
	var rope_query := PhysicsRayQueryParameters3D.create(player_chest, anchor_point)
	rope_query.exclude = excludes
	rope_query.collision_mask = 1 | 1024 | 2048
	var rope_result := space_state.intersect_ray(rope_query)
	if not rope_result.is_empty():
		if rope_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
			result = rope_result

	# Anchor to player chest (catches backface hits)
	var anchor_query := PhysicsRayQueryParameters3D.create(anchor_point, player_chest)
	anchor_query.exclude = excludes
	anchor_query.collision_mask = 1 | 1024 | 2048
	var anchor_result := space_state.intersect_ray(anchor_query)
	if not anchor_result.is_empty():
		if anchor_result.position.distance_to(player_chest) >= ROPE_LOS_MARGIN:
			if result.is_empty():
				result = anchor_result

	return result


func _run_leaf_check_at(space_state: PhysicsDirectSpaceState3D,
		chest: Vector3, rope_dir: Vector3, rope_len: float,
		swing_normal: Vector3, contact: Vector3, contact_rid: RID,
		excludes: Array[RID]) -> bool:
	## Leaf go-around check for one obstacle at the given chest position.
	## The bend arc sits where the obstacle contacts the rope; the detour
	## surface fans through a half-circle of directions on each side while
	## staying pinned at chest and anchor.
	## Sets debug state.  Returns true if BOTH sides are blocked at every
	## width (= CUT).  The right side is skipped when the left already passed.
	_center_contact_point = contact
	_center_contact_rid = contact_rid
	_has_center_contact = true
	_dbg_swing_normal = swing_normal

	# Bend base: the obstacle's contact projected onto the rope line.
	var along: float = clampf((contact - chest).dot(rope_dir),
		rope_len * 0.05, rope_len * 0.95)
	var bend_base: Vector3 = chest + rope_dir * along

	# Second perpendicular axis — together with swing_normal it spans the
	# plane of bend directions around the rope.
	var z_axis: Vector3 = rope_dir.cross(swing_normal).normalized()

	var left_frac := _side_pass_fraction(space_state, chest, bend_base,
		swing_normal, z_axis, 0, excludes)
	var right_frac := -1.0
	if left_frac < 0.0:
		right_frac = _side_pass_fraction(space_state, chest, bend_base,
			-swing_normal, z_axis, 1, excludes)

	_side_blocked = [1 if left_frac < 0.0 else 0, 1 if right_frac < 0.0 else 0]
	_side_pass_frac = [left_frac, right_frac]

	return left_frac < 0.0 and right_frac < 0.0


func _side_pass_fraction(space_state: PhysicsDirectSpaceState3D,
		chest: Vector3, bend_base: Vector3, side_dir: Vector3,
		z_axis: Vector3, side_idx: int, excludes: Array[RID]) -> float:
	## Try leaf detour surfaces on one side of the swing plane, widest first.
	## Each surface fans the bend point through a half-circle of directions
	## (side_dir at the middle, ±z_axis at the seams shared with the other
	## side).  Returns the width fraction of the first fully clear surface,
	## or -1.0 if every width is blocked.  Records surfaces for debug visuals.
	for frac in LEAF_WIDTH_FRACTIONS:
		var w: float = LEAF_MAX_WIDTH * frac
		var arc := PackedVector3Array()
		for k in LEAF_ARC_POINTS:
			var theta: float = -PI * 0.5 + PI * float(k) / float(LEAF_ARC_POINTS - 1)
			var dir: Vector3 = side_dir * cos(theta) + z_axis * sin(theta)
			arc.append(bend_base + dir * w)
		var blocked := _leaf_surface_blocked(space_state, chest, arc, excludes)
		_leaf_candidates.append({
			"chest": chest, "arc": arc, "side": side_idx,
			"frac": frac, "blocked": blocked })
		if not blocked:
			return frac
	return -1.0


func _leaf_surface_blocked(space_state: PhysicsDirectSpaceState3D,
		chest: Vector3, arc: PackedVector3Array,
		excludes: Array[RID]) -> bool:
	## Overlap-test one leaf surface: two triangle fans (apex at chest and at
	## anchor) meeting at the shared bend arc.  Adjacent tiles share edges,
	## so the coverage is continuous — nothing can slip between tiles.
	## Early-exits on the first blocked tile.
	for k in arc.size() - 1:
		if _fan_tile_blocked(space_state, chest, arc[k], arc[k + 1], excludes):
			return true
		if _fan_tile_blocked(space_state, anchor_point, arc[k], arc[k + 1], excludes):
			return true
	return false


func _fan_tile_blocked(space_state: PhysicsDirectSpaceState3D,
		apex: Vector3, p0: Vector3, p1: Vector3,
		excludes: Array[RID]) -> bool:
	## Overlap-test one fan tile: the triangle (apex, p0, p1) truncated near
	## the apex by the LOS safe margin (so the player's surroundings and the
	## anchor surface don't count as obstructions), rope-diameter thick.
	## Posed as an oriented slab in the tile's plane via the query transform
	## (never mutates shape data — threaded-physics safe).  The slab is the
	## quad's in-plane bounding box; the slight lateral over-cover lands on
	## the neighboring tile's part of the surface, so coverage stays exact.
	var corners := _fan_tile_corners(apex, p0, p1)
	if corners.is_empty():
		return false

	var mid_q: Vector3 = (corners[0] + corners[1]) * 0.5
	var mid_p: Vector3 = (corners[2] + corners[3]) * 0.5
	var y_vec: Vector3 = mid_p - mid_q
	var y_len: float = y_vec.length()
	if y_len < 0.01:
		return false
	var y_dir: Vector3 = y_vec / y_len
	var x_raw: Vector3 = corners[2] - corners[3]  # p1 - p0 (arc chord)
	var x_vec: Vector3 = x_raw - y_dir * x_raw.dot(y_dir)
	var x_len: float = x_vec.length()
	if x_len < 0.001:
		return false  # Degenerate sliver — apex colinear with the arc chord
	var x_dir: Vector3 = x_vec / x_len

	var center: Vector3 = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
	var half_w: float = 0.001
	var half_l: float = 0.001
	for i in 4:
		var d: Vector3 = corners[i] - center
		half_w = maxf(half_w, absf(d.dot(x_dir)))
		half_l = maxf(half_l, absf(d.dot(y_dir)))

	_leaf_tile_query.transform = _slab_transform(center, x_dir, y_dir,
		half_w * 2.0, half_l * 2.0)
	_leaf_tile_query.exclude = excludes
	return not space_state.intersect_shape(_leaf_tile_query, 1).is_empty()


func _fan_tile_corners(apex: Vector3, p0: Vector3, p1: Vector3) -> PackedVector3Array:
	## Corners of a fan tile truncated near its apex: [q0, q1, p1, p0] where
	## q0/q1 sit the safe-margin distance from the apex along each edge.
	## Returns empty if the tile is degenerate.
	var len0: float = apex.distance_to(p0)
	var len1: float = apex.distance_to(p1)
	if len0 < 0.05 or len1 < 0.05:
		return PackedVector3Array()
	var trim: float = minf(ROPE_LOS_MARGIN, minf(len0, len1) * 0.45)
	var q0: Vector3 = apex.lerp(p0, trim / len0)
	var q1: Vector3 = apex.lerp(p1, trim / len1)
	return PackedVector3Array([q0, q1, p1, p0])


func _slab_transform(center: Vector3, x_dir: Vector3, y_dir: Vector3,
		w: float, l: float) -> Transform3D:
	## Pose the canonical slab shape: X scaled to width w, Y scaled to
	## length l, Z (thickness = rope diameter) unscaled.  x_dir/y_dir must
	## be orthonormal.
	var z_dir: Vector3 = x_dir.cross(y_dir)
	return Transform3D(Basis(x_dir * w, y_dir * l, z_dir), center)


func _segment_slab_transform(a: Vector3, b: Vector3, width: float) -> Transform3D:
	## Pose the canonical slab along segment a → b (local Y axis) with the
	## given cross-section width, centered at the midpoint.  Caller
	## guarantees a ≠ b.
	var y_dir: Vector3 = (b - a).normalized()
	var x_dir: Vector3
	if absf(y_dir.y) < 0.9:
		x_dir = y_dir.cross(Vector3.UP).normalized()
	else:
		x_dir = y_dir.cross(Vector3.RIGHT).normalized()
	return _slab_transform((a + b) * 0.5, x_dir, y_dir, width, a.distance_to(b))


func _localize_obstacle(space_state: PhysicsDirectSpaceState3D,
		prev_chest: Vector3, cur_chest: Vector3,
		target_rid: RID, excludes: Array[RID],
		all_obstacle_rids: Array[RID]) -> Dictionary:
	## Find the interpolation t (0→1) where the rope from lerp(prev, cur, t) → anchor
	## first intersects the obstacle identified by target_rid.
	## Returns { "t": float, "rid": RID, "contact": Vector3 } or empty dict.
	##
	## Strategy:
	## 1. Binary search using raycasts (fast, works for most objects).
	## 2. If all rays miss (thin object), fall back to sweeping a thin
	##    rope-radius capsule through the rope's arc using cast_motion, with
	##    the exclude list set to block everything except target_rid so only
	##    that object can be hit.  get_rest_info then gives the contact point.

	# --- Fast path: binary search with rays ---
	var best_t: float = -1.0
	var best_contact: Vector3 = Vector3.ZERO
	var t_lo: float = 0.0
	var t_hi: float = 1.0

	# First check: does any ray from this range hit the target?
	# Probe at 5 evenly spaced t values to seed the binary search.
	# More probes = better chance of catching narrow-window obstacles.
	for probe_i in 5:
		var probe_t: float = float(probe_i) / 4.0  # 0.0, 0.25, 0.5, 0.75, 1.0
		var probe_chest: Vector3 = prev_chest.lerp(cur_chest, probe_t)
		var hit := _ray_hits_rid(space_state, probe_chest, target_rid, excludes)
		if not hit.is_empty():
			best_t = probe_t
			best_contact = hit.position
			t_hi = probe_t
			break

	if best_t >= 0.0:
		# Binary search to narrow down the earliest t
		for _i in BISECT_ITERATIONS:
			var t_mid: float = (t_lo + t_hi) * 0.5
			var mid_chest: Vector3 = prev_chest.lerp(cur_chest, t_mid)
			var hit := _ray_hits_rid(space_state, mid_chest, target_rid, excludes)
			if not hit.is_empty():
				t_hi = t_mid
				best_t = t_mid
				best_contact = hit.position
			else:
				t_lo = t_mid

		# Verify the contact is not in a safe zone
		if best_contact.distance_to(anchor_point) < ROPE_LOS_MARGIN:
			return {}
		if best_contact.distance_to(prev_chest.lerp(cur_chest, best_t)) < ROPE_LOS_MARGIN:
			return {}

		return { "t": best_t, "rid": target_rid, "contact": best_contact }

	# --- Fallback: rays missed — arc-sweep a thin capsule to localize thin objects ---
	# Build an exclude list that blocks everything EXCEPT target_rid.
	# This turns the physics query into an "include-only" filter for the target.
	var arc_excludes: Array[RID] = excludes.duplicate()
	for other_rid in all_obstacle_rids:
		if other_rid != target_rid:
			# Deduplicate — don't add if already in excludes
			var already := false
			for ex in arc_excludes:
				if other_rid == ex:
					already = true
					break
			if not already:
				arc_excludes.append(other_rid)

	# Thin rope-width slab along the rope at t=0 (prev_chest → anchor),
	# trimmed by the LOS safe margins at both ends so the anchor surface and
	# the player's surroundings can't produce an immediate hit.  Posed via
	# transform only (threaded-physics safe).
	# NOTE: pure translation over-sweeps toward the anchor end (the real rope
	# pivots at the anchor), but hits near the anchor land in the safe zone
	# and are discarded below anyway.
	var prev_rope_vec: Vector3 = anchor_point - prev_chest
	var prev_rope_len: float = prev_rope_vec.length()
	if prev_rope_len < 0.1:
		return {}
	var prev_rope_dir: Vector3 = prev_rope_vec / prev_rope_len
	var trim: float = minf(ROPE_LOS_MARGIN, prev_rope_len * 0.45)
	var cap_a: Vector3 = prev_chest + prev_rope_dir * trim
	var cap_b: Vector3 = anchor_point - prev_rope_dir * trim
	var cap_len: float = cap_a.distance_to(cap_b)
	if cap_len < 0.05:
		return {}
	var sweep_xform := _segment_slab_transform(cap_a, cap_b, ROPE_RADIUS * 2.0)
	_arc_sweep_query.transform = sweep_xform
	_arc_sweep_query.exclude = arc_excludes

	# Sweep motion = how the player chest moved this frame (the arc).
	# cast_motion returns [safe, unsafe] fractions along this motion vector.
	var sweep_motion: Vector3 = cur_chest - prev_chest
	_arc_sweep_query.motion = sweep_motion

	var motion_result := space_state.cast_motion(_arc_sweep_query)
	# motion_result = [safe_fraction, unsafe_fraction]
	# safe = furthest fraction with no penetration, unsafe = first fraction with penetration
	if motion_result[1] >= 1.0:
		# No collision found along the arc — target wasn't hit
		return {}

	# The unsafe fraction IS our t value (0→1 along prev_chest → cur_chest)
	var hit_t: float = motion_result[1]

	# Translate the slab to the unsafe position and use get_rest_info to
	# get the contact point.  Since our exclude list blocks everything except
	# target_rid, this is guaranteed to return the target's contact info.
	var hit_chest: Vector3 = prev_chest + sweep_motion * hit_t
	sweep_xform.origin += sweep_motion * hit_t
	_arc_sweep_query.transform = sweep_xform
	_arc_sweep_query.motion = Vector3.ZERO  # No motion for rest info query

	var rest_info := space_state.get_rest_info(_arc_sweep_query)
	if rest_info.is_empty():
		return {}

	var rest_rid: RID = rest_info.get("rid", RID())
	var rest_point: Vector3 = rest_info.get("point", Vector3.ZERO)

	# Verify RID matches (should always match since everything else is excluded,
	# but sanity check anyway)
	if rest_rid != target_rid:
		return {}

	# Verify safe zones
	if rest_point.distance_to(anchor_point) < ROPE_LOS_MARGIN:
		return {}
	if rest_point.distance_to(hit_chest) < ROPE_LOS_MARGIN:
		return {}

	return { "t": hit_t, "rid": target_rid, "contact": rest_point }


func _ray_hits_rid(space_state: PhysicsDirectSpaceState3D,
		chest: Vector3, target_rid: RID, excludes: Array[RID]) -> Dictionary:
	## Fire bidirectional rays from chest↔anchor.  Returns the hit result
	## Dictionary if either ray hits an object with the target_rid (and the
	## hit is outside the safe margin).  Returns empty dict otherwise.

	# Chest → anchor
	var fwd_query := PhysicsRayQueryParameters3D.create(chest, anchor_point)
	fwd_query.exclude = excludes
	fwd_query.collision_mask = 1 | 1024 | 2048
	var fwd_result := space_state.intersect_ray(fwd_query)
	if not fwd_result.is_empty():
		var hit_rid: RID = fwd_result.get("rid", RID())
		if hit_rid == target_rid:
			if fwd_result.position.distance_to(anchor_point) >= ROPE_LOS_MARGIN:
				return fwd_result

	# Anchor → chest (catches backface hits)
	var rev_query := PhysicsRayQueryParameters3D.create(anchor_point, chest)
	rev_query.exclude = excludes
	rev_query.collision_mask = 1 | 1024 | 2048
	var rev_result := space_state.intersect_ray(rev_query)
	if not rev_result.is_empty():
		var hit_rid: RID = rev_result.get("rid", RID())
		if hit_rid == target_rid:
			if rev_result.position.distance_to(chest) >= ROPE_LOS_MARGIN:
				return rev_result

	return {}


func _compute_swing_normal(rope_dir: Vector3) -> Vector3:
	## Compute a swing-perpendicular normal for the leaf side orientation.
	## Uses current velocity if available, otherwise falls back to world up.
	var rad_spd: float = player.velocity.dot(rope_dir)
	var tang_v: Vector3 = player.velocity - rope_dir * rad_spd
	if tang_v.length() > 0.5:
		return rope_dir.cross(tang_v).normalized()
	if absf(rope_dir.y) < 0.9:
		return rope_dir.cross(Vector3.UP).normalized()
	return rope_dir.cross(Vector3.RIGHT).normalized()


# ======================================================================
#  Server: release grapple
# ======================================================================

func _do_release(with_boost: bool) -> void:
	if not is_grappling:
		return

	var boosted := false
	if with_boost:
		boosted = _apply_release_boost()

	_last_release_time = Time.get_ticks_msec() / 1000.0
	var release_pos: Vector3 = player.global_position + Vector3(0, 1.2, 0)
	is_grappling = false
	anchor_point = Vector3.ZERO
	_rope_length = 0.0
	_anchor_collider_rid = RID()

	# When boosted on the ground, force airborne so the upward velocity
	# component actually launches the player instead of being pinned to the floor.
	if boosted and player.is_on_floor():
		player.movement.force_airborne()

	_show_grapple_release.rpc(release_pos)
	if boosted:
		_play_release_woosh.rpc(release_pos)
	print("Player %d released grapple (speed: %.1f, boost: %s)" % [
		player.peer_id, player.velocity.length(), str(boosted)])


func _apply_release_boost() -> bool:
	## Tilt velocity upward by 25° (capped at 30° above horizontal),
	## then add a speed boost that scales with current speed.
	## Returns true if the boost was actually applied.
	## Boost is blocked if grapple hasn't been active for at least 1 second.
	if _grapple_time < MIN_GRAPPLE_TIME_FOR_BOOST:
		return false

	var vel := player.velocity
	var speed := vel.length()
	if speed < RELEASE_BOOST_MIN_SPEED:
		return false

	# --- Pitch tilt: rotate velocity upward by 20°, capped at 25° ---
	var horiz_speed := Vector2(vel.x, vel.z).length()
	if horiz_speed > 0.1:
		# Current pitch angle (negative = downward, positive = upward)
		var current_pitch := atan2(vel.y, horiz_speed)
		# Target pitch after adding 20°, capped at 25° upward
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

	# --- Speed boost: 1 m/s at 2 m/s, scaling to 7 m/s at 43 m/s, capped at 50 m/s ---
	speed = player.velocity.length()  # Re-read after pitch change
	var t := clampf((speed - RELEASE_BOOST_MIN_SPEED) /
		(RELEASE_BOOST_MAX_SPEED - RELEASE_BOOST_MIN_SPEED), 0.0, 1.0)
	var boost := lerpf(RELEASE_BOOST_MIN, RELEASE_BOOST_MAX, t)
	var headroom := maxf(RELEASE_BOOST_SPEED_CAP - speed, 0.0)
	boost = minf(boost, headroom)
	var boost_dir := player.velocity.normalized()
	player.velocity += boost_dir * boost

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
	_grapple_time = 0.0
	_side_blocked = [0, 0]
	_side_pass_frac = [-1.0, -1.0]
	_dbg_swing_normal = Vector3.ZERO
	_prev_los_chest = Vector3.ZERO
	_center_contact_point = Vector3.ZERO
	_has_center_contact = false
	_center_contact_rid = RID()
	_leaf_candidates = []
	cleanup()


# ======================================================================
#  Client: rope visual
# ======================================================================

func client_process_visuals(_delta: float) -> void:
	if not is_grappling:
		cleanup()
		if _debug_label:
			_debug_label.visible = false
		return

	# Use the interpolated transform so the rope attaches to where the player
	# is visually rendered, not the last physics-tick position.
	var interp_pos: Vector3 = player.get_global_transform_interpolated().origin
	var player_hand: Vector3 = interp_pos + Vector3(0, 1.2, 0)
	var cam_pos: Vector3 = player.camera.global_position if player.camera else player_hand
	var scene_root := get_tree().current_scene

	# --- Rope — reuse existing MeshInstance3D, only rebuild geometry ---
	if not _rope_mesh_instance or not is_instance_valid(_rope_mesh_instance):
		var im := ImmediateMesh.new()
		_rope_mesh_instance = MeshInstance3D.new()
		_rope_mesh_instance.mesh = im
		_rope_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rope_mesh_instance.top_level = true
		_rope_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_rope_mesh_instance.material_override = _rope_material
		if scene_root:
			scene_root.add_child(_rope_mesh_instance)

	var im: ImmediateMesh = _rope_mesh_instance.mesh as ImmediateMesh
	im.clear_surfaces()
	_build_rope_ribbon(im, player_hand, anchor_point, cam_pos)

	# --- Anchor light — reuse, just update position ---
	if not _anchor_light or not is_instance_valid(_anchor_light):
		_anchor_light = OmniLight3D.new()
		_anchor_light.light_color = Color(0.3, 0.6, 1.0)
		_anchor_light.light_energy = 2.5
		_anchor_light.omni_range = 4.0
		_anchor_light.omni_attenuation = 1.5
		_anchor_light.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		if scene_root:
			scene_root.add_child(_anchor_light)
	_anchor_light.position = anchor_point

	var show_debug: bool = GameManager.debug_grapple_visuals

	# --- Debug HUD label — rope state, leaf status ---
	if _debug_label and show_debug:
		_debug_label.visible = true
		var lines: PackedStringArray = PackedStringArray()
		lines.append("Rope Length: %.1fm" % _rope_length)
		if _has_center_contact:
			lines.append("Contact: (%.1f, %.1f, %.1f)" % [_center_contact_point.x, _center_contact_point.y, _center_contact_point.z])
			var side_txt: PackedStringArray = PackedStringArray()
			for i in 2:
				if _side_blocked[i] == 1:
					side_txt.append("BLOCKED")
				elif _side_pass_frac[i] >= 0.0:
					side_txt.append("clear @ %.2fm" % (_side_pass_frac[i] * LEAF_MAX_WIDTH))
				else:
					side_txt.append("skipped")
			lines.append("Leaf: L=%s  R=%s" % [side_txt[0], side_txt[1]])
		_debug_label.text = "\n".join(lines)
	elif _debug_label:
		_debug_label.visible = false

	# --- Debug visuals (these are rebuilt each frame, acceptable for debug) ---
	_free_visual(_leaf_mesh_instance)
	_leaf_mesh_instance = null
	_free_visual(_contact_mesh_instance)
	_contact_mesh_instance = null
	if show_debug:
		_build_leaf_visual(player_hand)
		_build_contact_debug_visual()

	# --- Safe zone sphere (independent toggle) ---
	_free_visual(_safe_zone_mesh_instance)
	_safe_zone_mesh_instance = null
	if GameManager.debug_grapple_safe_zone:
		var sz_im := ImmediateMesh.new()
		_safe_zone_mesh_instance = MeshInstance3D.new()
		_safe_zone_mesh_instance.mesh = sz_im
		_safe_zone_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_safe_zone_mesh_instance.top_level = true
		_safe_zone_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_draw_debug_sphere_wireframe(sz_im, _safe_zone_mat, anchor_point, ROPE_LOS_MARGIN, 24, 12)
		if scene_root:
			scene_root.add_child(_safe_zone_mesh_instance)


func _build_rope_ribbon(im: ImmediateMesh, from: Vector3, to: Vector3, cam_pos: Vector3) -> void:
	var rope_vec: Vector3 = to - from
	var rope_length: float = rope_vec.length()
	if rope_length < 0.01:
		return

	const HALF_WIDTH := ROPE_RADIUS  ## Thin rope — matches the physics width
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


func _free_visual(node: Node) -> void:
	if node and is_instance_valid(node):
		var p := node.get_parent()
		if p:
			p.remove_child(node)
		node.queue_free()


func cleanup() -> void:
	_free_visual(_rope_mesh_instance)
	_rope_mesh_instance = null
	_free_visual(_anchor_light)
	_anchor_light = null
	_free_visual(_leaf_mesh_instance)
	_leaf_mesh_instance = null
	_free_visual(_contact_mesh_instance)
	_contact_mesh_instance = null
	_free_visual(_safe_zone_mesh_instance)
	_safe_zone_mesh_instance = null


# ======================================================================
#  Leaf debug visualization
# ======================================================================

func _build_leaf_visual(player_chest: Vector3) -> void:
	## Draw every leaf detour surface tested by the last obstruction check —
	## the same truncated fan tiles the physics queries used.
	## Color coding:
	##   Left side:  green (clear) / red (blocked)
	##   Right side: yellow (clear) / red (blocked)
	## Narrower widths drawn with the dimmer materials.
	## Also draws the center sweep triangle wireframe.
	var im := ImmediateMesh.new()
	_leaf_mesh_instance = MeshInstance3D.new()
	_leaf_mesh_instance.mesh = im
	_leaf_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_leaf_mesh_instance.top_level = true
	_leaf_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	for cand in _leaf_candidates:
		var narrow: bool = cand["frac"] < 1.0
		var mat: StandardMaterial3D
		if cand["blocked"]:
			mat = _leaf_narrow_blocked_mat if narrow else _leaf_blocked_mat
		elif cand["side"] == 0:
			mat = _leaf_narrow_clear_left_mat if narrow else _leaf_clear_left_mat
		else:
			mat = _leaf_narrow_clear_right_mat if narrow else _leaf_clear_right_mat

		var arc: PackedVector3Array = cand["arc"]
		var cand_chest: Vector3 = cand["chest"]
		for apex_idx in 2:
			var apex: Vector3 = cand_chest if apex_idx == 0 else anchor_point
			for k in arc.size() - 1:
				var corners := _fan_tile_corners(apex, arc[k], arc[k + 1])
				if corners.is_empty():
					continue
				# corners = [q0, q1, p1, p0] → strip order q0, q1, p0, p1
				im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
				im.surface_add_vertex(corners[0])
				im.surface_add_vertex(corners[1])
				im.surface_add_vertex(corners[3])
				im.surface_add_vertex(corners[2])
				im.surface_end()

	# Center sweep triangle wireframe (using cached material)
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
		scene_root.add_child(_leaf_mesh_instance)


# ======================================================================
#  Contact debug visualization — circle at the center contact point
# ======================================================================

func _build_contact_debug_visual() -> void:
	## Draw a small circle at the center contact point (where the rope hits
	## the obstacle) from the obstruction check.
	if not _has_center_contact:
		return

	var im := ImmediateMesh.new()
	_contact_mesh_instance = MeshInstance3D.new()
	_contact_mesh_instance.mesh = im
	_contact_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_contact_mesh_instance.top_level = true
	_contact_mesh_instance.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	# All materials are pre-cached in setup() — no per-frame allocation.
	_draw_debug_circle(im, _contact_center_mat, _center_contact_point, 0.15, 12)

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
	flash.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	spark.material_override = _spark_material
	spark.top_level = true
	spark.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	flash.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	# Simple low-pass state
	var lp_prev := 0.0
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
