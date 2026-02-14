extends RigidBody3D

## Bubble projectile: a near-weightless soap bubble that floats, drifts, and
## blocks shots. Pops on bullet damage or high-energy collisions.
##
## Physics model:
##   - RigidBody3D with mass=0.1 (extremely light)
##   - Zero gravity (floats in place)
##   - High linear_damp (air resistance bleeds off speed quickly)
##   - Brownian drift: tiny random forces applied every 0.12s
##   - Soft bubble-on-bubble separation via forces (not hard collision)
##   - Players push bubbles by applying impulses from player.gd
##
## Collision layers:
##   Layer 3 (bit 4): bubble body. Only walls (layer 1) stop them.
##   Hitscan raycasts use mask 0xFFFFFFFF, so they hit bubbles.
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

## Pop thresholds based on kinetic energy (0.5*m*v^2).
const POP_ENERGY_WALL := 0.8
const POP_ENERGY_OBJECT := 2.0
const POP_ENERGY_BUBBLE := 5.0

## Identity flag — used by _is_bubble() to distinguish from rubber balls.
var is_bubble := true

var _shooter_id: int = -1
var _damage: float = 5.0
var _lifetime: float = 0.0
var _has_popped: bool = false
var _nudge_timer: float = 0.0
var _wind_dir: Vector3 = Vector3.ZERO

## Cached Players container (avoids tree traversal every physics frame)
var _players_container: Node = null
var _players_cache_valid: bool = false


func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	_shooter_id = shooter_id
	_damage = damage
	linear_velocity = direction.normalized() * LAUNCH_SPEED


func _ready() -> void:
	_nudge_timer = randf_range(0.0, NUDGE_INTERVAL)
	_wind_dir = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()

	mass = BUBBLE_MASS
	gravity_scale = 0.0
	linear_damp = LINEAR_DAMP
	angular_damp = 10.0
	continuous_cd = true
	lock_rotation = true

	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = BOUNCE
	phys_mat.friction = FRICTION
	physics_material_override = phys_mat

	collision_layer = 4  # Layer 3: bubbles
	collision_mask = 1   # World only (bubble-to-bubble handled by BubbleSeparationManager)

	contact_monitor = true
	max_contacts_reported = 4
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)
		# Register with centralized spatial-hash separation manager
		var manager := _find_separation_manager()
		if manager:
			manager.register(self)

	_setup_visual()


func _exit_tree() -> void:
	if multiplayer.is_server():
		var manager := _find_separation_manager()
		if manager:
			manager.unregister(self)


func _setup_visual() -> void:
	var mesh_inst := get_node_or_null("MeshInstance3D")
	if mesh_inst == null:
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


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	_lifetime += delta
	if _lifetime >= LIFETIME and not _has_popped:
		_pop()
		return

	# Gentle persistent wind
	apply_central_force(_wind_dir * WIND_STRENGTH)

	# Brownian drift
	_nudge_timer -= delta
	if _nudge_timer <= 0.0:
		apply_central_force(Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.3, 0.3),
			randf_range(-1.0, 1.0)
		) * NUDGE_STRENGTH)
		_wind_dir = _wind_dir.rotated(Vector3.UP, randf_range(-0.2, 0.2))
		_nudge_timer = NUDGE_INTERVAL

	_check_player_overlap()


# ======================================================================
#  Collision / pop detection
# ======================================================================

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server() or _has_popped:
		return

	if _lifetime < 0.15 and body is CharacterBody3D and body.name.to_int() == _shooter_id:
		return

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
	elif body is CharacterBody3D:
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


func _find_separation_manager() -> BubbleSeparationManager:
	var scene := get_tree().current_scene
	if scene:
		return scene.get_node_or_null("BubbleSeparationManager") as BubbleSeparationManager
	return null


func _check_player_overlap() -> void:
	if _has_popped:
		return

	# Cache Players container lookup
	if not _players_cache_valid:
		_players_container = get_tree().current_scene.get_node_or_null("Players")
		_players_cache_valid = true

	if _players_container == null:
		return

	var hit_radius: float = BUBBLE_RADIUS + 0.4
	for child in _players_container.get_children():
		if not child is CharacterBody3D:
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


func apply_push_impulse(impulse: Vector3) -> void:
	if not _has_popped:
		apply_central_impulse(impulse)


# ======================================================================
#  Pop VFX
# ======================================================================

func _pop() -> void:
	if _has_popped:
		return
	_has_popped = true

	if multiplayer.is_server():
		_show_pop_fx.rpc(global_position)

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
