extends RigidBody3D

## Rocket projectile: flies in a straight line, explodes on contact.
## Server-authoritative: server handles collision, damage, and cleanup.
## Clients see the projectile via replication and the explosion via RPC.

const SPEED := 50.0
const EXPLOSION_RADIUS := 8.0
const MAX_LIFETIME := 5.0

var _direction: Vector3 = Vector3.FORWARD
var _shooter_id: int = -1
var _damage: float = 70.0
var _lifetime: float = 0.0
var _has_exploded: bool = false

## Ammo scatter override: when set, explosion spawns projectiles instead of dealing AOE damage
var _ammo_projectile_scene: PackedScene = null
var _ammo_explosion_spawn_count: int = 0
var _ammo_damage_mult: float = 1.0


func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	## Called by WeaponProjectile before adding to scene tree.
	_direction = direction.normalized()
	_shooter_id = shooter_id
	_damage = damage


func set_ammo_override(ammo: WeaponData) -> void:
	## Called by WeaponProjectile when ammo is slotted.
	## On explosion, this rocket will scatter ammo projectiles instead of dealing AOE damage.
	if ammo and ammo.can_slot_as_ammo:
		_ammo_projectile_scene = ammo.projectile_scene
		_ammo_explosion_spawn_count = ammo.ammo_explosion_spawn_count
		_ammo_damage_mult = ammo.ammo_damage_mult


func _ready() -> void:
	# Straight-line flight: no gravity, locked rotation
	gravity_scale = 0.0
	lock_rotation = true
	linear_velocity = _direction * SPEED

	# Orient rocket to face its travel direction
	if _direction.length() > 0.01:
		look_at(global_position + _direction, Vector3.UP)

	# Server handles collision
	if multiplayer.is_server():
		contact_monitor = true
		max_contacts_reported = 4
		body_entered.connect(_on_body_entered)

	# Setup smoke trail particles (all peers — visual only)
	_setup_smoke_trail()


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	_lifetime += delta
	if _lifetime >= MAX_LIFETIME and not _has_exploded:
		_explode()
		return

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


func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server() or _has_exploded:
		return

	# Ignore the shooter so the rocket doesn't self-destruct
	if body is CharacterBody3D and body.name.to_int() == _shooter_id:
		return

	_explode()


func _explode() -> void:
	if _has_exploded:
		return
	_has_exploded = true

	var explosion_pos := global_position

	# If ammo is loaded, scatter ammo projectiles instead of normal explosion
	if _ammo_projectile_scene and _ammo_explosion_spawn_count > 0:
		_scatter_ammo_projectiles(explosion_pos)
		# Show a lighter VFX (no structural damage, no crater)
		_show_ammo_scatter_fx.rpc(explosion_pos)
		queue_free()
		return

	# --- Normal explosion: damage nearby damageable nodes ---
	# We use a two-pass approach:
	#  1) Physics shape query for dynamic bodies (players, rigid bodies)
	#  2) Direct scene-tree scan for static bodies (destructible walls)
	# This is needed because intersect_shape can miss StaticBody3D nodes
	# or fill results with terrain triangles.

	var already_damaged: Array[Node] = []

	# Pass 1: Physics query (catches CharacterBody3D / RigidBody3D reliably)
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = EXPLOSION_RADIUS
	query.shape = sphere
	query.transform = Transform3D(Basis(), explosion_pos)
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var results := space_state.intersect_shape(query, 64)

	for result in results:
		var collider: Node = result["collider"]
		if collider == self:
			continue
		# Walk up the tree in case the collider is a child of the damageable node
		var target := _find_damageable(collider)
		if target and target not in already_damaged:
			# Use spatial damage for walls (per-block destruction)
			if target.has_method("take_damage_at"):
				target.take_damage_at(explosion_pos, _damage, EXPLOSION_RADIUS, _shooter_id)
				already_damaged.append(target)
			else:
				var dist := explosion_pos.distance_to(target.global_position)
				var falloff := clampf(1.0 - (dist / EXPLOSION_RADIUS), 0.0, 1.0)
				var dmg := _damage * falloff
				if dmg > 0.5:
					target.take_damage(dmg, _shooter_id)
					already_damaged.append(target)

	# Pass 2: Scene-tree scan for destructible walls in range
	# (catches walls that the physics query might miss)
	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		for child in structures.get_children():
			if child in already_damaged:
				continue
			if child.has_method("take_damage_at"):
				# Check if any part of the wall is within blast radius
				var dist := explosion_pos.distance_to(child.global_position)
				# Use generous range: wall center + half its largest dimension
				var wall_reach: float = 0.0
				if "wall_size" in child:
					wall_reach = child.wall_size.length() * 0.5
				if dist <= EXPLOSION_RADIUS + wall_reach:
					child.take_damage_at(explosion_pos, _damage, EXPLOSION_RADIUS, _shooter_id)
					already_damaged.append(child)

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


func _find_damageable(node: Node) -> Node:
	## Walk up the tree from a collider to find the best damageable ancestor.
	## Prefers take_damage_at (spatial/wall damage) over plain take_damage.
	var current := node
	var first_damageable: Node = null
	for _i in 4:  # Max 4 levels up
		if current == null:
			break
		# Prefer nodes with spatial damage (walls)
		if current.has_method("take_damage_at"):
			return current
		if first_damageable == null and current.has_method("take_damage"):
			first_damageable = current
		current = current.get_parent()
	return first_damageable


@rpc("authority", "call_local", "reliable")
func _show_explosion(pos: Vector3) -> void:
	## Visual explosion effect on all clients.
	var scene_root := get_tree().current_scene

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
