extends PhysicsBodyBase
class_name TowerChunk

## Falling debris chunk from a collapsed spiral tower.
## Deals damage to players, terrain, and structures on first impact.
## Damage scales with velocity, mass, and impact angle.
## Chunks are DESTRUCTIBLE — explosions (rockets, grenades) deal damage to them.
## Pushes nearby characters via mass-weighted physics (inherited from PhysicsBodyBase).
##
## Server-authoritative: only the server runs damage logic.
## Created by spiral_tower.gd via _sync_collapse_impact RPC.

# ======================================================================
#  Constants
# ======================================================================

const MIN_DAMAGE_SPEED := 3.0          ## Minimum impact speed to deal damage (m/s)
const DAMAGE_MULTIPLIER := 1.5         ## Damage = speed * sqrt(mass_kg) * this * angle_mult
const CRATER_BASE_RADIUS := 0.5        ## Base crater radius on terrain hit
const CRATER_MASS_SCALE := 0.003       ## Extra crater radius per kg of mass
const MAX_DAMAGE_EVENTS := 3           ## Max separate damage events per chunk
const MINI_DEBRIS_COUNT := 3           ## Small cosmetic debris on destruction
const MINI_DEBRIS_LIFETIME := 6.0      ## Auto-cleanup for cosmetic debris (seconds)
## Whether to spawn permanent transparent spheres at impact sites (toggled in pause menu)

# ======================================================================
#  Properties (set by spiral_tower.gd before adding to scene)
# ======================================================================

var chunk_mass: float = 200.0          ## Mass in kg for damage calculation (set by spiral_tower.gd)
var attacker_id: int = -1              ## Player who caused the collapse

# ======================================================================
#  Internal state
# ======================================================================

var _damage_events: int = 0            ## How many things we've damaged so far
var _hit_points: float = 0.0           ## Destructible HP (set in _ready)


func _ready() -> void:
	# HP scales with mass — heavier slabs take more punishment
	_hit_points = chunk_mass * 2.0

	if not multiplayer.is_server():
		return
	body_entered.connect(_on_body_entered)


# ======================================================================
#  Incoming damage (from explosions — rockets, grenades, other chunks)
# ======================================================================

func take_damage(amount: float, from_attacker_id: int = -1) -> void:
	## Called by ExplosionHelper.do_explosion() when an explosion reaches
	## this fragment. ExplosionHelper walks the scene tree looking for
	## nodes with take_damage(), so this just works with no changes needed
	## to the explosion system.
	if not multiplayer.is_server():
		return
	_hit_points -= amount
	print("[TowerChunk] %s took %.1f damage (HP: %.1f remaining)" % [name, amount, _hit_points])
	if _hit_points <= 0.0:
		_destroy(from_attacker_id)


func _destroy(killer_id: int) -> void:
	## Fragment is destroyed — spawn small cosmetic debris on all clients,
	## then remove this chunk on all peers.
	print("[TowerChunk] %s destroyed! Spawning mini debris" % name)
	_sync_chunk_destroyed.rpc(global_position, chunk_mass)


@rpc("authority", "call_local", "reliable")
func _sync_chunk_destroyed(pos: Vector3, frag_mass: float) -> void:
	## Spawn small cosmetic box debris where the chunk was destroyed,
	## then free this node on all peers.
	var scene_root := get_tree().current_scene
	if scene_root == null:
		queue_free()
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = int(pos.x * 1000.0) ^ int(pos.z * 7919.0)

	for i in MINI_DEBRIS_COUNT:
		var debris := RigidBody3D.new()
		debris.name = "TowerMiniDebris_%d" % i
		debris.collision_layer = CollisionLayers.DEBRIS
		debris.collision_mask = CollisionLayers.WORLD
		var debris_size := rng.randf_range(0.3, 0.8)
		debris.mass = frag_mass * 0.05

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(debris_size, debris_size, debris_size)
		col.shape = box
		debris.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(debris_size, debris_size, debris_size)
		mesh_inst.mesh = box_mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.42, 0.40)
		mat.roughness = 0.85
		mesh_inst.material_override = mat
		debris.add_child(mesh_inst)

		scene_root.add_child(debris)
		debris.global_position = pos + Vector3(
			rng.randf_range(-0.5, 0.5),
			rng.randf_range(0.2, 1.0),
			rng.randf_range(-0.5, 0.5)
		)

		# Scatter impulse
		var scatter := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(0.5, 2.0),
			rng.randf_range(-1.0, 1.0)
		).normalized()
		debris.apply_central_impulse(scatter * rng.randf_range(2.0, 5.0))
		debris.apply_torque_impulse(Vector3(
			rng.randf_range(-3.0, 3.0),
			rng.randf_range(-3.0, 3.0),
			rng.randf_range(-3.0, 3.0)
		))

		# Auto-cleanup timer
		var timer := Timer.new()
		timer.one_shot = true
		timer.wait_time = MINI_DEBRIS_LIFETIME
		timer.timeout.connect(func(): debris.queue_free() if is_instance_valid(debris) else null)
		debris.add_child(timer)
		timer.start()

	# Remove the chunk on this peer (both server and clients)
	queue_free()


# ======================================================================
#  Contact damage (fragment hitting ground, players, structures)
# ======================================================================

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return
	if _damage_events >= MAX_DAMAGE_EVENTS:
		return

	var impact_speed := linear_velocity.length()
	if impact_speed < MIN_DAMAGE_SPEED:
		return

	# --- Impact angle bonus ---
	# Steeper (more vertical) impacts deal more damage, up to 1.5x
	var down_dot := absf(linear_velocity.normalized().dot(Vector3.DOWN))
	var angle_mult := 1.0 + down_dot * 0.5  # 1.0 (horizontal) to 1.5 (vertical)

	# Damage scales with speed, sqrt(mass), and impact angle.
	# Using sqrt(mass) so heavier slabs hit harder but not linearly —
	# a 1000kg slab isn't 5x deadlier than a 200kg slab, just ~2.2x.
	# Examples at vertical impact (angle_mult = 1.5):
	#   200kg slab at 10 m/s: 10 * 14.1 * 1.5 * 1.5 ≈ 318 damage (lethal)
	#   200kg slab at  5 m/s:  5 * 14.1 * 1.5 * 1.5 ≈ 159 damage (heavy hit)
	#  1000kg slab at 10 m/s: 10 * 31.6 * 1.5 * 1.5 ≈ 711 damage (overkill)
	var mass_factor: float = sqrt(chunk_mass)
	var base_damage: float = impact_speed * mass_factor * DAMAGE_MULTIPLIER * angle_mult

	# --- Damage player ---
	if body.has_method("take_damage"):
		body.take_damage(base_damage, attacker_id)
		_damage_events += 1
		print("[TowerChunk] Hit player %s for %.1f damage (speed: %.1f, mass: %.2f, angle: %.2f)" % [
			body.name, base_damage, impact_speed, chunk_mass, angle_mult])
		_do_impact_explosion(base_damage)
		return

	# --- Damage destructible structure ---
	# Walk up to find damageable parent (same as rocket pattern)
	var target := _find_damageable(body)
	if target:
		if target.has_method("take_damage_at"):
			var chunk_radius: float = 1.0 + mass_factor * 0.15
			target.take_damage_at(global_position, base_damage, chunk_radius, attacker_id)
		elif target.has_method("take_damage"):
			target.take_damage(base_damage, attacker_id)
		_damage_events += 1
		_do_impact_explosion(base_damage)
		return

	# --- Terrain impact (create crater) ---
	# If we hit something on layer 1 (world geometry) that isn't damageable,
	# it's likely terrain. Create a small crater.
	if body is StaticBody3D:
		var seed_world := _find_seed_world()
		if seed_world and seed_world.has_method("create_crater"):
			var crater_radius: float = CRATER_BASE_RADIUS + chunk_mass * CRATER_MASS_SCALE
			seed_world.create_crater(global_position, crater_radius, 0.3, attacker_id)
		_damage_events += 1
		_do_impact_explosion(base_damage)


# ======================================================================
#  Impact explosion — AoE damage + debug visualization
# ======================================================================

func _do_impact_explosion(contact_damage: float) -> void:
	## After a fragment impacts something, it also creates a shockwave
	## (area-of-effect explosion) that damages nearby players/structures.
	## The explosion is 30% of the contact damage.
	var explosion_radius: float = 3.0 + chunk_mass * 0.005
	var explosion_damage: float = contact_damage * 0.3
	var impact_pos := global_position

	# AoE damage via the centralized explosion system
	# Tower chunk uses same damage for players and structures
	ExplosionHelper.do_explosion(
		get_world_3d(),
		impact_pos,
		explosion_damage,
		explosion_damage,
		explosion_radius,
		attacker_id,
		self  # Exclude this chunk from its own explosion
	)

	print("[TowerChunk] Impact explosion at %s (damage: %.1f, radius: %.1fm)" % [
		str(impact_pos), explosion_damage, explosion_radius])

	# Spawn debug sphere on all clients
	if GameManager.debug_show_explosion_spheres:
		_sync_debug_sphere.rpc(impact_pos, explosion_radius)


@rpc("authority", "call_local", "reliable")
func _sync_debug_sphere(pos: Vector3, radius: float) -> void:
	## Spawn a permanent transparent orange sphere showing the explosion radius.
	## These persist until the game ends for debugging purposes.
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var sphere_node := MeshInstance3D.new()
	sphere_node.name = "DebugExplosionSphere"

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = radius
	sphere_mesh.height = radius * 2.0
	sphere_mesh.radial_segments = 16
	sphere_mesh.rings = 8
	sphere_node.mesh = sphere_mesh

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.0, 0.15)  # Transparent orange
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	sphere_node.material_override = mat

	scene_root.add_child(sphere_node)
	sphere_node.global_position = pos


# ======================================================================
#  Utility
# ======================================================================

func _find_damageable(node: Node) -> Node:
	## Walk up the tree to find a damageable ancestor.
	var current := node
	var first_damageable: Node = null
	for _i in 4:
		if current == null:
			break
		if current.has_method("take_damage_at"):
			return current
		if first_damageable == null and current.has_method("take_damage"):
			first_damageable = current
		current = current.get_parent()
	return first_damageable


func _find_seed_world() -> Node:
	var sw := get_tree().current_scene.get_node_or_null("SeedWorld")
	if sw == null:
		sw = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	return sw
