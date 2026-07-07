extends ProjectileBase

## Grenade projectile: arcs with gravity, bounces off surfaces, and detonates
## after a 5-second fuse timer. Explosion uses the same shielded damage system
## as rockets (ExplosionHelper).
##
## Extends ProjectileBase -> PhysicsBodyBase.

const SPEED := 30.0
const EXPLOSION_RADIUS := 7.0
const MAX_LIFETIME := 10.0
const FUSE_TIME := 5.0
const GRENADE_HP := 3.0

var _direction: Vector3 = Vector3.FORWARD
var _has_exploded: bool = false
var _hp: float = GRENADE_HP
var _hit_pending: bool = false
var _fuse_timer: float = 0.0


func get_launch_speed() -> float:
	return SPEED


func get_max_lifetime() -> float:
	return MAX_LIFETIME


func launch(direction: Vector3, shooter_id: int, damage: float, structure_damage: float = -1.0) -> void:
	_direction = direction.normalized()
	super.launch(direction, shooter_id, damage, structure_damage)


func _setup() -> void:
	# Grenade arcs under gravity and tumbles freely.
	gravity_scale = 1.0
	lock_rotation = false
	linear_velocity = _direction * SPEED

	# Bouncy physics material so grenades skip off surfaces.
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.4
	phys_mat.friction = 0.6
	physics_material_override = phys_mat

	# Orient toward travel direction at launch.
	if _direction.length() > 0.01:
		look_at(global_position + _direction, Vector3.UP)


func _server_process(delta: float) -> void:
	# Handle deferred explosion from body_entered or chain detonation.
	if _hit_pending:
		_hit_pending = false
		_do_explode()
		return

	# Fuse timer — explode after FUSE_TIME seconds regardless of collision.
	if not _has_exploded:
		_fuse_timer += delta
		if _fuse_timer >= FUSE_TIME:
			_has_exploded = true
			_is_terminated = true
			_do_explode()
			return


func take_damage(amount: float, attacker_id: int) -> void:
	## Grenades can be destroyed by explosions (chain detonation).
	if _has_exploded or _is_terminated:
		return
	_hp -= amount
	if _hp <= 0.0:
		_has_exploded = true
		_is_terminated = true
		_hit_pending = true


func _is_shooter_immune(body: Node) -> bool:
	## Grenade: shooter immune for a short window so it doesn't explode in their face
	## on a wall bounce. After that, self-damage is possible.
	if body is Player and body.peer_id == _shooter_id:
		return _lifetime < 0.5
	return false


func _on_body_hit(body: Node) -> void:
	# Grenades bounce — do NOT explode on contact.
	# The fuse timer handles detonation.
	pass


func _do_explode() -> void:
	var explosion_pos := global_position

	# Remove from physics queries before explosion raycasts.
	collision_layer = 0
	collision_mask = 0

	if has_ammo_override():
		_scatter_ammo_projectiles(explosion_pos)
		_show_ammo_scatter_fx.rpc(explosion_pos)
		queue_free()
		return

	ExplosionHelper.do_explosion(
		get_world_3d(),
		explosion_pos, _damage, _structure_damage, EXPLOSION_RADIUS, _shooter_id, self,
		linear_velocity.length()
	)

	# Terrain crater (smaller than rocket).
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world == null:
		seed_world = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	if seed_world and seed_world.has_method("create_crater"):
		seed_world.create_crater(explosion_pos, EXPLOSION_RADIUS * 0.3, 1.0, _shooter_id)

	_show_explosion.rpc(explosion_pos)
	queue_free()


func _scatter_ammo_projectiles(explosion_pos: Vector3) -> void:
	var count := _ammo_explosion_spawn_count
	var per_projectile_damage: float = (_damage * _ammo_damage_mult) / count
	var per_projectile_structure_damage: float = (_structure_damage * _ammo_damage_mult) / count

	var map := get_tree().current_scene
	if not map.has_method("spawn_projectile"):
		return

	var golden_ratio: float = (1.0 + sqrt(5.0)) / 2.0
	for i in count:
		var theta: float = acos(1.0 - 2.0 * (i + 0.5) / count)
		var phi: float = TAU * i / golden_ratio
		var scatter_dir := Vector3(
			sin(theta) * cos(phi),
			sin(theta) * sin(phi),
			cos(theta)
		).normalized()
		scatter_dir.y = maxf(scatter_dir.y, -0.2)
		scatter_dir = scatter_dir.normalized()

		var spawn_pos := explosion_pos + scatter_dir * 0.5
		map.spawn_projectile(
			_ammo_projectile_scene.resource_path, spawn_pos, scatter_dir,
			_shooter_id, per_projectile_damage, per_projectile_structure_damage
		)


@rpc("authority", "call_local", "reliable")
func _show_explosion(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene

	# Explosion sound
	var snd := AudioStreamPlayer3D.new()
	snd.stream = preload("res://assets/audio/sfx/explosion.ogg")
	snd.max_distance = 80.0
	snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	snd.top_level = true
	snd.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	scene_root.add_child(snd)
	snd.global_position = pos
	snd.play()
	snd.finished.connect(snd.queue_free)

	# Flash light
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.5, 0.1)
	flash.light_energy = 16.0
	flash.omni_range = EXPLOSION_RADIUS * 1.5
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	# Fireball
	var fireball := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.4
	sphere_mesh.height = 0.8
	fireball.mesh = sphere_mesh
	fireball.top_level = true

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.1, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.0)
	mat.emission_energy_multiplier = 8.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fireball.material_override = mat
	scene_root.add_child(fireball)
	fireball.global_position = pos

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(fireball, "scale", Vector3.ONE * 5.0, 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.4)
	tween.tween_property(flash, "light_energy", 0.0, 0.3)
	tween.set_parallel(false)
	tween.tween_callback(fireball.queue_free)
	tween.tween_callback(flash.queue_free)


@rpc("authority", "call_local", "reliable")
func _show_ammo_scatter_fx(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene

	var flash := OmniLight3D.new()
	flash.light_color = Color(0.8, 0.9, 1.0)
	flash.light_energy = 10.0
	flash.omni_range = EXPLOSION_RADIUS * 0.8
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	var burst := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.3
	sphere_mesh.height = 0.6
	burst.mesh = sphere_mesh
	burst.top_level = true

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.95, 1.0, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.85, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	burst.material_override = mat
	scene_root.add_child(burst)
	burst.global_position = pos

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(burst, "scale", Vector3.ONE * 4.0, 0.2).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tween.tween_property(flash, "light_energy", 0.0, 0.2)
	tween.set_parallel(false)
	tween.tween_callback(burst.queue_free)
	tween.tween_callback(flash.queue_free)
