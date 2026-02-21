extends ProjectileBase

## Bubble projectile: a near-weightless soap bubble that floats, drifts, and
## blocks shots. Pops on bullet damage or high-energy collisions.
##
## Physics model:
##   - ProjectileBase → PhysicsBodyBase with mass=0.1 (extremely light)
##   - Zero gravity (floats in place)
##   - High linear_damp (air resistance bleeds off speed quickly)
##   - Brownian drift: tiny random forces applied every 0.12s
##   - Overlap repulsion: Jolt broadphase query (intersect_shape) finds one neighbor, bubble drifts away
##   - Player overlap via distance check (_check_player_overlap)
##
## Collision layers:
##   Layer 3 (bit 4): bubble body. Walls (1) and tower debris (2) stop them.
##   Hitscan raycasts include layer 3 in their mask, so they hit bubbles.
##
## Pop condition: kinetic energy (0.5*m*v^2) exceeds threshold.

const BUBBLE_MASS := 0.1
const BUBBLE_RADIUS := 0.6
const LIFETIME := 16.0
const LAUNCH_SPEED := 8.0
const LINEAR_DAMP := 2.5
const NUDGE_STRENGTH := 0.5
const NUDGE_INTERVAL := 0.12
const WIND_STRENGTH := 0.08
const BOUNCE := 0.5
const FRICTION := 0.0
const OVERLAP_PUSH := 2.0   # Repulsion force strength at full overlap

## Pop thresholds based on kinetic energy (0.5*m*v^2).
const POP_ENERGY_WALL := 0.8
const POP_ENERGY_OBJECT := 2.0
const POP_ENERGY_BUBBLE := 5.0

## Identity flag — used by _is_bubble() to distinguish from rubber balls.
## Checked via node.get("is_bubble") by other bubbles.
var is_bubble := true

var _has_popped: bool = false
var _nudge_timer: float = 0.0
var _wind_dir: Vector3 = Vector3.ZERO
var _players_container: Node = null
var _players_cache_valid: bool = false

# Pre-allocated physics query for O(1) bubble overlap detection via Jolt broadphase.
var _overlap_query: PhysicsShapeQueryParameters3D = null
var _overlap_shape_rid: RID = RID()


func get_launch_speed() -> float:
	return LAUNCH_SPEED


func get_max_lifetime() -> float:
	return LIFETIME


func get_shooter_immunity_time() -> float:
	return 0.15


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _overlap_shape_rid.is_valid():
			PhysicsServer3D.free_rid(_overlap_shape_rid)
			_overlap_shape_rid = RID()

func _ready() -> void:
	super._ready()
	# Reduce contact tracking overhead: bubbles only need the first body hit to pop.
	max_contacts_reported = 1
	# Clients don't process body_entered (server guard) — skip contact tracking entirely.
	if not multiplayer.is_server():
		contact_monitor = false


func _setup() -> void:
	_nudge_timer = randf_range(0.0, NUDGE_INTERVAL)
	_wind_dir = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()

	mass = BUBBLE_MASS
	gravity_scale = 0.0
	linear_damp = LINEAR_DAMP
	angular_damp = 10.0
	continuous_cd = false  # Bubbles are large (1.2m) and heavily damped — won't tunnel
	lock_rotation = true

	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = BOUNCE
	phys_mat.friction = FRICTION
	physics_material_override = phys_mat

	if GameManager.debug_bubble_no_collision:
		collision_layer = 4  # Keep layer so Area3D sensors still detect it
		collision_mask = 0   # Don't collide with anything
	else:
		collision_layer = 4  # Layer 3: bubbles
		collision_mask = 1   # World only — bubble overlap detected via intersect_shape query
	if GameManager.debug_bubble_no_ccd:
		continuous_cd = false
	if GameManager.debug_bubble_no_contact_monitor:
		contact_monitor = false

	add_to_group("bubbles")

	# Pre-allocate overlap query for Jolt broadphase lookups (server only).
	# Shape must be created via PhysicsServer3D so Jolt registers the radius
	# properly — a bare SphereShape3D.new() stays at radius 0 on the Jolt side.
	if multiplayer.is_server():
		_overlap_shape_rid = PhysicsServer3D.sphere_shape_create()
		PhysicsServer3D.shape_set_data(_overlap_shape_rid, BUBBLE_RADIUS)
		_overlap_query = PhysicsShapeQueryParameters3D.new()
		_overlap_query.shape_rid = _overlap_shape_rid
		_overlap_query.collision_mask = 4  # Layer 3 (bubbles) only
		_overlap_query.collide_with_bodies = true
		_overlap_query.collide_with_areas = false
		_overlap_query.exclude = [get_rid()]

	_setup_visual()



func _setup_visual() -> void:
	var mesh_inst := get_node_or_null("MeshInstance3D")
	if mesh_inst == null:
		return
	if GameManager.debug_hide_bubbles:
		mesh_inst.visible = false
		return
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.7, 0.85, 1.0, 0.25)
	mat.metallic = 0.6
	mat.roughness = 0.1
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.7, 1.0)
	mat.emission_energy_multiplier = 0.3
	mat.rim_enabled = true
	mat.rim = 0.8
	mat.rim_tint = 0.3
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = mat


func _server_process(delta: float) -> void:
	if _has_popped:
		return
	if GameManager.debug_bubble_no_processing:
		return

	# Gentle persistent wind
	apply_central_force(_wind_dir * WIND_STRENGTH)

	# Brownian drift + overlap repulsion + player overlap at ~8Hz
	_nudge_timer -= delta
	if _nudge_timer <= 0.0:
		apply_central_force(Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.3, 0.3),
			randf_range(-1.0, 1.0)
		) * NUDGE_STRENGTH)
		_wind_dir = _wind_dir.rotated(Vector3.UP, randf_range(-0.2, 0.2))
		_nudge_timer = NUDGE_INTERVAL

		# Drift away from first overlapping bubble (Jolt broadphase query, O(1) amortized)
		if not GameManager.debug_bubble_no_separation:
			var my_pos: Vector3 = global_position
			_overlap_query.transform = Transform3D(Basis(), my_pos)
			var space := get_world_3d().direct_space_state
			var results: Array[Dictionary] = space.intersect_shape(_overlap_query, 1)
			if results.size() > 0:
				var other: Node = results[0].collider
				var dist_sq: float = my_pos.distance_squared_to(other.global_position)
				if dist_sq > 0.0001:
					var dist: float = sqrt(dist_sq)
					apply_central_force((my_pos - other.global_position) / dist * OVERLAP_PUSH)

		_check_player_overlap()


# ======================================================================
#  Collision / pop detection
# ======================================================================

func _on_body_hit(body: Node) -> void:
	if _has_popped:
		return

	# Shooter immunity handled by base class _on_body_entered → _is_shooter_immune

	var bubble_speed := linear_velocity.length()
	var bubble_ke := 0.5 * mass * bubble_speed * bubble_speed

	if _is_bubble(body):
		var other: RigidBody3D = body as RigidBody3D
		var rel_speed: float = (linear_velocity - other.linear_velocity).length()
		var rel_ke := 0.5 * mass * rel_speed * rel_speed
		if rel_ke > POP_ENERGY_BUBBLE:
			_pop()
		return

	var impactor_ke := 0.0
	if body is RigidBody3D:
		impactor_ke = 0.5 * body.mass * body.linear_velocity.length_squared()
	elif body is Player:
		impactor_ke = 0.5 * 80.0 * body.velocity.length_squared()

	var collision_ke := maxf(bubble_ke, impactor_ke)

	if body is StaticBody3D:
		if bubble_ke > POP_ENERGY_WALL:
			_pop()
	else:
		if collision_ke > POP_ENERGY_OBJECT:
			_pop()


func _is_bubble(node: Node) -> bool:
	return node is RigidBody3D and node != self and node.get("is_bubble") == true


func _check_character_overlaps() -> void:
	# Skip the expensive intersect_shape() query entirely for bubbles.
	# Bubbles weigh 0.1kg — the reduced-mass push on players is effectively zero.
	# Player damage is handled by _check_player_overlap() instead (simple distance check).
	return


func _check_player_overlap() -> void:
	if _has_popped:
		return

	# Cached reference to the Players node for overlap checks
	if not _players_cache_valid:
		var scene := get_tree().current_scene
		if scene:
			_players_container = scene.get_node_or_null("Players")
		_players_cache_valid = true

	if _players_container == null:
		return

	var hit_radius: float = BUBBLE_RADIUS + 0.4
	for child in _players_container.get_children():
		if not child is Player:
			continue
		if _lifetime < 0.15 and child.name.to_int() == _shooter_id:
			continue
		var dist: float = global_position.distance_to(child.global_position + Vector3(0, 0.8, 0))
		if dist < hit_radius:
			if child.has_method("take_damage"):
				child.take_damage(_damage, _shooter_id)
			_pop()
			return


func take_damage(_amount: float, _attacker_id: int) -> void:
	if not _has_popped:
		_pop()


# ======================================================================
#  Pop / destruction
# ======================================================================

func _on_destroyed() -> void:
	## Lifetime expired — pop with the same VFX as a player hit.
	if _has_popped:
		return
	_has_popped = true
	_show_pop_fx.rpc(get_global_transform_interpolated().origin)


func _pop() -> void:
	## Bubble-specific destruction: sets _has_popped flag and calls base _terminate().
	if _has_popped:
		return
	_has_popped = true
	# Use _is_terminated + queue_free from base, but trigger VFX first
	if multiplayer.is_server():
		_show_pop_fx.rpc(get_global_transform_interpolated().origin)
	# Don't call _terminate() since we handle queue_free directly here
	# (base _terminate would call _on_destroyed which we don't use — we have _pop)
	_is_terminated = true
	queue_free()


@rpc("authority", "call_local", "unreliable")
func _show_pop_fx(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene

	var pop_sphere := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = BUBBLE_RADIUS
	sphere_mesh.height = BUBBLE_RADIUS * 2.0
	pop_sphere.mesh = sphere_mesh
	pop_sphere.top_level = true

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.8, 0.9, 1.0, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.8, 1.0)
	mat.emission_energy_multiplier = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pop_sphere.material_override = mat
	scene_root.add_child(pop_sphere)
	pop_sphere.global_position = pos

	var flash := OmniLight3D.new()
	flash.light_color = Color(0.6, 0.8, 1.0)
	flash.light_energy = 2.0
	flash.omni_range = 3.0
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(pop_sphere, "scale", Vector3.ONE * 2.0, 0.2).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.2)
	tween.tween_property(flash, "light_energy", 0.0, 0.15)
	tween.set_parallel(false)
	tween.tween_callback(pop_sphere.queue_free)
	tween.tween_callback(flash.queue_free)
