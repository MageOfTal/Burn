extends Node3D

## Procedural terrain using Zylann's Voxel Tools GDExtension.
## Uses VoxelTerrain + VoxelMesherTransvoxel + VoxelGeneratorNoise2D
## for a smooth, destructible terrain with hills and bumps.
##
## The terrain is SDF-based (Signed Distance Field) which means digging
## creates smooth holes — not blocky Minecraft-style cuts.
##
## Key APIs preserved from old system:
##   - create_crater(pos, radius, depth)  — deforms terrain via VoxelTool
##   - get_height_at(x, z)                — raycast-based surface query
##   - get_normal_at(x, z)                — central-difference from height samples
##
## Structures (walls, ramps) are spawned on top of the terrain surface.

## Terrain size and shape
@export_group("Terrain")
@export var map_size: float = 224.0         ## World units per side (~56 cells × 4m)
@export var height_scale: float = 16.0      ## Max height variation (meters)
@export var noise_period: float = 128.0     ## Noise repeat period (larger = broader hills)
@export var height_range: float = 32.0      ## VoxelGeneratorNoise2D height range

## Structure generation
@export_group("Structures")
@export var num_walls: int = 200
@export var num_ramps: int = 100
@export var num_player_spawns: int = 8
@export var num_loot_spawns: int = 30
@export var num_dummies: int = 8
@export var structure_margin: float = 15.0  ## Keep structures this far from edges

## Internal refs
var _voxel_terrain: VoxelTerrain = null
var _voxel_tool: VoxelTool = null
var _terrain_ready := false


func _ready() -> void:
	# --- Create VoxelTerrain node ---
	_voxel_terrain = VoxelTerrain.new()
	_voxel_terrain.name = "VoxelTerrainNode"

	# --- Mesher: Transvoxel for smooth terrain ---
	var mesher := VoxelMesherTransvoxel.new()
	_voxel_terrain.mesher = mesher

	# --- Generator: Noise2D for hilly terrain ---
	var generator := VoxelGeneratorNoise2D.new()
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / noise_period
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.45
	noise.seed = 10293847
	generator.noise = noise
	# height_start: Y position of the lowest terrain surface.
	# height_range: vertical span the noise covers above height_start.
	# So terrain surface lives between Y=0 and Y=height_range.
	generator.height_start = 0.0
	generator.height_range = height_range
	# Channel must be SDF for smooth Transvoxel meshing (should be default, but be explicit)
	generator.channel = VoxelBuffer.CHANNEL_SDF
	_voxel_terrain.generator = generator

	# --- Terrain settings ---
	_voxel_terrain.mesh_block_size = 16
	_voxel_terrain.max_view_distance = 256
	_voxel_terrain.generate_collisions = true
	_voxel_terrain.collision_layer = 1   # Layer 1 — world geometry
	_voxel_terrain.collision_mask = 0    # Static terrain doesn't collide with anything itself

	# Constrain terrain to our map area (prevent infinite generation).
	# Bounds AABB is in data-block coordinates (each block = mesh_block_size voxels).
	# With mesh_block_size=16, one block covers 16 voxels = 16 world units.
	var half_extent := map_size * 0.5
	_voxel_terrain.bounds = AABB(
		Vector3(-half_extent, -64.0, -half_extent),
		Vector3(map_size, 128.0, map_size)
	)

	# --- Terrain material ---
	# Use a simple green material. For triplanar mapping in the future,
	# this can be replaced with a ShaderMaterial.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.65, 0.35)
	_voxel_terrain.material_override = mat

	add_child(_voxel_terrain)

	# Get the VoxelTool for editing (digging, craters)
	_voxel_tool = _voxel_terrain.get_voxel_tool()

	# --- Directional light ---
	if not get_parent().has_node("Sun"):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_color = Color(1, 1, 0.95)
		sun.light_energy = 0.8
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = map_size * 2.0
		sun.rotation_degrees = Vector3(-50, -45, 0)
		add_child(sun)

	# --- Sky + Environment ---
	if not get_parent().has_node("WorldEnvironment"):
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.3, 0.5, 0.88)          # Bright blue top
		sky_mat.sky_horizon_color = Color(0.6, 0.72, 0.9)     # Lighter blue horizon
		sky_mat.ground_bottom_color = Color(0.22, 0.32, 0.14) # Dark ground
		sky_mat.ground_horizon_color = Color(0.45, 0.55, 0.4) # Greenish horizon
		sky_mat.sky_curve = 0.15
		sky_mat.ground_curve = 0.02
		sky_mat.sky_energy_multiplier = 0.5
		sky_mat.use_debanding = true

		var sky := Sky.new()
		sky.sky_material = sky_mat
		sky.radiance_size = Sky.RADIANCE_SIZE_256

		var env := Environment.new()
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_sky_contribution = 0.2
		env.ambient_light_energy = 0.3
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		env.tonemap_white = 1.0
		env.tonemap_exposure = 0.9
		# Subtle distant fog only — very low density to avoid white haze
		env.fog_enabled = true
		env.fog_light_color = Color(0.5, 0.6, 0.75)
		env.fog_density = 0.0003
		env.fog_sky_affect = 0.05
		env.fog_height = 80.0
		env.fog_height_density = 0.003

		var world_env := WorldEnvironment.new()
		world_env.name = "WorldEnvironment"
		world_env.environment = env
		get_parent().add_child.call_deferred(world_env)

	_terrain_ready = true

	# --- Spawn structures after terrain is ready ---
	# Wait for chunks to load and mesh before placing structures
	await get_tree().create_timer(1.5).timeout

	var rng := RandomNumberGenerator.new()
	rng.seed = 10293847

	var structures_node := Node3D.new()
	structures_node.name = "Structures"
	add_child(structures_node)

	_spawn_walls(rng, structures_node)
	_spawn_ramps(rng, structures_node)
	_spawn_player_spawns(rng)
	_spawn_loot_points(rng)
	_spawn_dummies(rng)


# ======================================================================
#  Height query — raycast from above to find terrain surface
# ======================================================================

func get_height_at(world_x: float, world_z: float) -> float:
	## Returns the terrain height at the given world XZ position.
	## Uses a physics raycast from high above to find the surface.
	var space_state := get_world_3d().direct_space_state
	var from := Vector3(world_x, 100.0, world_z)
	var to := Vector3(world_x, -100.0, world_z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1  # World geometry only
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position.y
	return 0.0


func get_normal_at(world_x: float, world_z: float) -> Vector3:
	## Returns the approximate surface normal at the given world XZ position.
	var eps := 2.0
	var hL := get_height_at(world_x - eps, world_z)
	var hR := get_height_at(world_x + eps, world_z)
	var hD := get_height_at(world_x, world_z - eps)
	var hU := get_height_at(world_x, world_z + eps)
	return Vector3(hL - hR, 2.0 * eps, hD - hU).normalized()


func _get_random_surface_pos(rng: RandomNumberGenerator) -> Vector3:
	## Pick a random XZ position within margins, return the surface point.
	var half := map_size * 0.5
	var x := rng.randf_range(-half + structure_margin, half - structure_margin)
	var z := rng.randf_range(-half + structure_margin, half - structure_margin)
	var y := get_height_at(x, z)
	return Vector3(x, y, z)


func _get_slope_at(world_x: float, world_z: float) -> float:
	## Returns the slope angle in degrees at the given position.
	var n := get_normal_at(world_x, world_z)
	return rad_to_deg(acos(clampf(n.dot(Vector3.UP), -1.0, 1.0)))


# ======================================================================
#  Terrain deformation (craters) via VoxelTool
# ======================================================================

func create_crater(world_pos: Vector3, radius: float, _crater_depth: float) -> void:
	## Deform the terrain to create a crater at the given world position.
	## Uses VoxelTool.do_sphere() with MODE_REMOVE for smooth SDF subtraction.
	## Server calls this, then syncs to clients.
	if _voxel_tool == null:
		return

	_apply_crater(world_pos, radius)

	if multiplayer.is_server():
		_sync_crater.rpc(world_pos, radius)


@rpc("authority", "call_remote", "reliable")
func _sync_crater(world_pos: Vector3, radius: float) -> void:
	## Client-side: apply the same crater deformation locally.
	_apply_crater(world_pos, radius)


func _apply_crater(world_pos: Vector3, radius: float) -> void:
	## Internal: remove a sphere of terrain at the given position.
	if _voxel_tool == null:
		return
	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	_voxel_tool.do_sphere(world_pos, radius)


# ======================================================================
#  Structure spawning (walls, ramps, spawns, loot, dummies)
# ======================================================================

func _spawn_walls(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn destructible walls with random tiers on the terrain surface.
	var wall_scene := preload("res://world/destructible_wall.tscn")
	var wall_sizes := [
		Vector3(10, 4, 1),
		Vector3(8, 3, 1),
		Vector3(12, 5, 1),
		Vector3(6, 3, 2),
		Vector3(14, 4, 1),
	]
	var tier_weights := [0.30, 0.35, 0.25, 0.10]

	for i in num_walls:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		if slope > 30.0:
			continue

		var wall_size: Vector3 = wall_sizes[rng.randi() % wall_sizes.size()]
		var y_rot := rng.randf_range(0, TAU)

		var roll := rng.randf()
		var tier: int = 0
		var cumulative := 0.0
		for t in tier_weights.size():
			cumulative += tier_weights[t]
			if roll <= cumulative:
				tier = t
				break

		var wall: Node3D = wall_scene.instantiate()
		wall.name = "Wall_%d" % i
		wall.wall_size = wall_size
		wall.wall_tier = tier
		wall.position = Vector3(pos.x, pos.y + wall_size.y * 0.5, pos.z)
		wall.rotation.y = y_rot
		parent.add_child(wall)


func _spawn_ramps(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn ramp structures on the terrain surface.
	var ramp_size := Vector3(4, 0.3, 8)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.5, 0.6, 0.5, 1)

	var angles_deg := [15.0, 20.0, 25.0, 30.0]

	for i in num_ramps:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		if slope > 25.0:
			continue

		var ramp_angle: float = angles_deg[rng.randi() % angles_deg.size()]
		var y_rot := rng.randf_range(0, TAU)

		var ramp := StaticBody3D.new()
		ramp.name = "Ramp_%d" % i
		ramp.position = Vector3(pos.x, pos.y + 0.3, pos.z)
		ramp.rotation.y = y_rot
		ramp.rotation.x = deg_to_rad(ramp_angle)
		parent.add_child(ramp)

		var col := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = ramp_size
		col.shape = box_shape
		ramp.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = ramp_size
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = ramp_mat
		ramp.add_child(mesh_inst)


func _spawn_player_spawns(rng: RandomNumberGenerator) -> void:
	## Create PlayerSpawnPoints node with markers on the terrain.
	var container := get_parent().get_node_or_null("PlayerSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "PlayerSpawnPoints"
		get_parent().add_child(container)

	for child in container.get_children():
		child.queue_free()

	for i in num_player_spawns:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		if slope > 20.0:
			pos = _get_random_surface_pos(rng)

		var marker := Marker3D.new()
		marker.name = "Spawn%d" % (i + 1)
		marker.position = Vector3(pos.x, pos.y + 1.0, pos.z)
		container.add_child(marker)


func _spawn_loot_points(rng: RandomNumberGenerator) -> void:
	## Create LootSpawnPoints node with markers on the terrain.
	var container := get_parent().get_node_or_null("LootSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "LootSpawnPoints"
		get_parent().add_child(container)

	for child in container.get_children():
		child.queue_free()

	for i in num_loot_spawns:
		var pos := _get_random_surface_pos(rng)
		var marker := Marker3D.new()
		marker.name = "Loot%d" % (i + 1)
		marker.position = Vector3(pos.x, pos.y + 0.5, pos.z)
		container.add_child(marker)


func _spawn_dummies(rng: RandomNumberGenerator) -> void:
	## Spawn target dummies on the terrain surface.
	var dummy_scene := load("res://world/target_dummy.tscn")
	if dummy_scene == null:
		return

	var container := get_parent().get_node_or_null("Dummies")
	if container == null:
		container = Node3D.new()
		container.name = "Dummies"
		get_parent().add_child(container)

	for child in container.get_children():
		child.queue_free()

	for i in num_dummies:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		if slope > 25.0:
			pos = _get_random_surface_pos(rng)

		var dummy: Node3D = dummy_scene.instantiate()
		dummy.name = "Dummy%d" % (i + 1)
		dummy.position = pos
		container.add_child(dummy)
