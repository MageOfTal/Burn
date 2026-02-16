extends ProjectileBase

## Rocket projectile: flies in a straight line, explodes on contact.
## Server-authoritative: server handles collision, damage, and cleanup.
## Clients see the projectile via replication and the explosion via RPC.
##
## Now extends ProjectileBase → PhysicsBodyBase, gaining:
##   - Unified launch/lifetime/termination interface
##   - Mass-weighted character push (rocket is lightweight + fast, so minimal push)
##   - Ammo override system from ProjectileBase

const SPEED := 50.0
const EXPLOSION_RADIUS := 8.0
const MAX_LIFETIME := 5.0

var _direction: Vector3 = Vector3.FORWARD
var _has_exploded: bool = false


func get_launch_speed() -> float:
	return SPEED


func get_max_lifetime() -> float:
	return MAX_LIFETIME


func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	_direction = direction.normalized()
	super.launch(direction, shooter_id, damage)


func _setup() -> void:
	# Straight-line flight: no gravity, locked rotation
	gravity_scale = 0.0
	lock_rotation = true
	linear_velocity = _direction * SPEED

	# Orient rocket to face its travel direction
	if _direction.length() > 0.01:
		look_at(global_position + _direction, Vector3.UP)

	# Setup smoke trail particles (all peers — visual only)
	_setup_smoke_trail()


func _server_process(delta: float) -> void:
	# Raycast forward to catch tunneling at high speed.
	# The rocket moves ~0.83m per frame at 60fps — if terrain is thin or at
	# a glancing angle, the physics engine can miss the collision.
	if not _has_exploded:
		var speed := linear_velocity.length()
		if speed > 1.0:
			var ray_dist := speed * delta * 1.5  # Look slightly ahead
			var space_state := get_world_3d().direct_space_state
			var query := PhysicsRayQueryParameters3D.create(
				global_position,
				global_position + linear_velocity.normalized() * ray_dist
			)
			query.collision_mask = collision_mask
			query.exclude = [get_rid()]
			var result := space_state.intersect_ray(query)
			if not result.is_empty():
				# Move to impact point and explode
				global_position = result.position
				_explode()


func _is_shooter_immune(body: Node) -> bool:
	## Rocket: permanent self-exclude (never damages shooter via body_entered).
	if body is CharacterBody3D and body.name.to_int() == _shooter_id:
		return true
	return false


func _on_body_hit(body: Node) -> void:
	_explode()


func _explode() -> void:
	if _has_exploded:
		return
	_has_exploded = true
	_is_terminated = true  # Prevent base lifetime kill from also firing

	var explosion_pos := get_global_transform_interpolated().origin

	# If ammo is loaded, scatter ammo projectiles instead of normal explosion
	if has_ammo_override():
		_scatter_ammo_projectiles(explosion_pos)
		# Show a lighter VFX (no structural damage, no crater)
		_show_ammo_scatter_fx.rpc(explosion_pos)
		queue_free()
		return

	# --- Shielded explosion damage (flat HP absorption + multi-point raycast) ---
	ExplosionHelper.do_explosion(
		get_world_3d(),
		explosion_pos, _damage, EXPLOSION_RADIUS, _shooter_id, self
	)

	# --- Create terrain crater (server deforms, then tells clients) ---
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world == null:
		seed_world = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	if seed_world and seed_world.has_method("create_crater"):
		seed_world.create_crater(explosion_pos, EXPLOSION_RADIUS * 0.4, 1.5, _shooter_id)

	# Show explosion VFX + crater on all clients
	_show_explosion.rpc(explosion_pos)

	# Remove projectile
	queue_free()


func _scatter_ammo_projectiles(explosion_pos: Vector3) -> void:
	## Scatter ammo projectiles outward from the explosion point.
	## No structural damage or crater — just a spray of projectiles.
	## Uses ProjectileSpawner so all clients see the scattered projectiles.
	var count := _ammo_explosion_spawn_count
	var per_projectile_damage: float = (_damage * _ammo_damage_mult) / count

	var map := get_tree().current_scene
	if not map.has_method("spawn_projectile"):
		push_warning("RocketProjectile: map has no spawn_projectile method")
		return

	# Distribute projectiles in a sphere using golden angle for even spacing
	var golden_ratio: float = (1.0 + sqrt(5.0)) / 2.0
	for i in count:
		# Fibonacci sphere distribution for even angular spacing
		var theta: float = acos(1.0 - 2.0 * (i + 0.5) / count)
		var phi: float = TAU * i / golden_ratio
		var scatter_dir := Vector3(
			sin(theta) * cos(phi),
			sin(theta) * sin(phi),
			cos(theta)
		).normalized()

		# Bias slightly upward so projectiles arc outward, not into the ground
		scatter_dir.y = maxf(scatter_dir.y, -0.2)
		scatter_dir = scatter_dir.normalized()

		var spawn_pos := explosion_pos + scatter_dir * 0.5  # Offset slightly outward
		map.spawn_projectile(
			_ammo_projectile_scene.resource_path, spawn_pos, scatter_dir,
			_shooter_id, per_projectile_damage
		)


@rpc("authority", "call_local", "reliable")
func _show_explosion(pos: Vector3) -> void:
	## Visual + audio explosion effect on all clients.
	var scene_root := get_tree().current_scene

	# --- Explosion sound ---
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

	# --- Bright flash light ---
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.5, 0.1)
	flash.light_energy = 20.0
	flash.omni_range = EXPLOSION_RADIUS * 1.5
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	# --- Explosion sphere (expanding fireball) ---
	var fireball := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
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

	# Animate: expand + fade
	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(fireball, "scale", Vector3.ONE * 6.0, 0.3).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.4)
	tween.tween_property(flash, "light_energy", 0.0, 0.3)
	tween.set_parallel(false)
	tween.tween_callback(fireball.queue_free)
	tween.tween_callback(flash.queue_free)


@rpc("authority", "call_local", "reliable")
func _show_ammo_scatter_fx(pos: Vector3) -> void:
	## Lighter explosion VFX for ammo scatter — no fireball, just a flash + expanding ring.
	var scene_root := get_tree().current_scene

	# Brief flash light (dimmer than normal explosion)
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.8, 0.9, 1.0)
	flash.light_energy = 10.0
	flash.omni_range = EXPLOSION_RADIUS * 0.8
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	# Small burst sphere (white/cyan instead of orange)
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

	# Animate: expand + fade quickly
	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(burst, "scale", Vector3.ONE * 4.0, 0.2).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tween.tween_property(flash, "light_energy", 0.0, 0.2)
	tween.set_parallel(false)
	tween.tween_callback(burst.queue_free)
	tween.tween_callback(flash.queue_free)


func _setup_smoke_trail() -> void:
	## Configure the SmokeTrail GPUParticles3D with a smoke material.
	var smoke := get_node_or_null("SmokeTrail")
	if smoke == null or not smoke is GPUParticles3D:
		return

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 0, 1)  # Emit backward (behind the rocket)
	mat.spread = 15.0
	mat.initial_velocity_min = 1.0
	mat.initial_velocity_max = 3.0
	mat.gravity = Vector3(0, 2.0, 0)  # Smoke drifts up slightly
	mat.scale_min = 0.3
	mat.scale_max = 0.8
	mat.damping_min = 2.0
	mat.damping_max = 4.0
	mat.color = Color(0.7, 0.7, 0.7, 0.6)

	# Fade out over lifetime using a color ramp
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1.0, 0.8, 0.3, 0.8))  # Start: bright orange
	gradient.set_color(1, Color(0.5, 0.5, 0.5, 0.0))  # End: transparent gray
	var gradient_tex := GradientTexture1D.new()
	gradient_tex.gradient = gradient
	mat.color_ramp = gradient_tex

	smoke.process_material = mat
	smoke.emitting = true

	# Use a simple quad mesh for smoke particles
	var quad := QuadMesh.new()
	quad.size = Vector2(0.4, 0.4)
	smoke.draw_pass_1 = quad

	# Billboard material so smoke always faces camera
	var smoke_mat := StandardMaterial3D.new()
	smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smoke_mat.vertex_color_use_as_albedo = true
	smoke_mat.albedo_color = Color(1, 1, 1, 1)
	quad.material = smoke_mat
