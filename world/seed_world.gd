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
@export var map_size: float = 400.0         ## Circular map diameter (world units)
@export var height_scale: float = 16.0      ## Max height variation (meters)
@export var noise_period: float = 128.0     ## Noise repeat period (larger = broader hills)
@export var height_range: float = 32.0      ## VoxelGeneratorNoise2D height range

## Structure generation
@export_group("Structures")
@export var num_walls: int = 200
@export var num_ramps: int = 200
@export var num_player_spawns: int = 40
@export var num_loot_spawns: int = 500
@export var num_dummies: int = 0
@export var structure_margin: float = 25.0  ## Keep structures this far from edges

## Signals
signal world_generation_complete

## Internal refs
var _voxel_terrain: VoxelTerrain = null
var _voxel_tool: VoxelTool = null
var _noise: FastNoiseLite = null
var _terrain_ready := false
var structures_complete := false  ## True after all walls/ramps have been spawned
var _structure_rng: RandomNumberGenerator = null  ## Stored for deferred heavy spawning

## Spiral tower reference (for crater carving integration)
var _tower: Node = null
var _tower_position: Vector3 = Vector3.INF  ## Tower center XZ for exclusion zone
const TOWER_EXCLUSION_RADIUS := 15.0        ## No walls/ramps within this of tower


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
	_noise = noise  # Store for direct height queries
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

	# --- Sky + Environment (with clouds) ---
	if not get_parent().has_node("WorldEnvironment"):
		var sky_shader := _create_cloud_sky_shader()
		var sky_mat := ShaderMaterial.new()
		sky_mat.shader = sky_shader

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

	# --- Spawn structures directly on the ground using noise height ---
	# No settle system needed — ground Y computed instantly from noise.
	var rng := RandomNumberGenerator.new()
	rng.seed = 10293847

	# Lightweight markers are created synchronously in _ready() so they
	# exist immediately when network_manager needs PlayerSpawnPoints.
	_spawn_player_spawns(rng)
	_spawn_loot_points(rng)

	# Heavy structures (walls, ramps) are started externally by network_manager
	# AFTER all synchronous setup is done. Calling call_deferred() on async
	# functions from _ready() crashes Godot 4.6.
	_structure_rng = rng


func _spawn_heavy_structures() -> void:
	## Spread heavy wall/ramp spawning across frames.
	## Called from network_manager after all synchronous setup is done.
	var rng := _structure_rng
	var structures_node := Node3D.new()
	structures_node.name = "Structures"
	add_child(structures_node)

	# Pre-compute tower position so walls/ramps can respect the exclusion zone.
	# The tower itself is spawned last (it awaits voxel generation).
	_precompute_tower_position(rng)

	await _spawn_walls_batched(rng, structures_node)
	await _spawn_ramps_batched(rng, structures_node)
	await _spawn_tower(rng, structures_node)
	_spawn_dummies(rng)

	structures_complete = true
	world_generation_complete.emit()
	print("[SeedWorld] World generation complete — all structures placed")


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


func get_height_from_noise(world_x: float, world_z: float) -> float:
	## Returns the exact terrain height at (x, z) by computing the same noise
	## that VoxelGeneratorNoise2D uses. No raycasts, no physics, instant.
	## NOTE: Does NOT account for craters (use get_height_at() for that).
	if _noise == null:
		return 0.0
	var n: float = _noise.get_noise_2d(world_x, world_z)
	return (n + 1.0) * 0.5 * height_range


func _get_slope_from_noise(world_x: float, world_z: float) -> float:
	## Returns the slope angle in degrees using noise height samples.
	## Same central-difference technique as get_normal_at() but instant.
	var eps := 2.0
	var hL := get_height_from_noise(world_x - eps, world_z)
	var hR := get_height_from_noise(world_x + eps, world_z)
	var hD := get_height_from_noise(world_x, world_z - eps)
	var hU := get_height_from_noise(world_x, world_z + eps)
	var normal := Vector3(hL - hR, 2.0 * eps, hD - hU).normalized()
	return rad_to_deg(acos(clampf(normal.dot(Vector3.UP), -1.0, 1.0)))


func _get_random_ground_pos(rng: RandomNumberGenerator, y_offset: float = 0.0,
		max_slope: float = 90.0, max_attempts: int = 10) -> Vector3:
	## Pick a random XZ within the circular map, compute ground Y from noise.
	## Retries if slope exceeds max_slope. Returns Vector3.INF on failure.
	var max_radius: float = map_size * 0.5 - structure_margin
	for attempt in max_attempts:
		var angle: float = rng.randf_range(0, TAU)
		var radius: float = sqrt(rng.randf()) * max_radius
		var x := cos(angle) * radius
		var z := sin(angle) * radius
		if max_slope < 90.0:
			if _get_slope_from_noise(x, z) > max_slope:
				continue
		return Vector3(x, get_height_from_noise(x, z) + y_offset, z)
	return Vector3.INF


# ======================================================================
#  Terrain deformation (craters) via VoxelTool
# ======================================================================

func create_crater(world_pos: Vector3, radius: float, _crater_depth: float,
		attacker_id: int = -1) -> void:
	## Deform the terrain to create a crater at the given world position.
	## Uses VoxelTool.do_sphere() with MODE_REMOVE for smooth SDF subtraction.
	## Also carves the spiral tower if one exists.
	## Server calls this, then syncs to clients.
	if _voxel_tool == null:
		return

	_apply_crater(world_pos, radius)

	# Also carve the tower (if it exists and is in range)
	if _tower and _tower.has_method("carve"):
		if attacker_id >= 0:
			_tower.set_last_attacker(attacker_id)
		_tower.carve(world_pos, radius)

	if multiplayer.is_server():
		_sync_crater.rpc(world_pos, radius)


@rpc("authority", "call_remote", "reliable")
func _sync_crater(world_pos: Vector3, radius: float) -> void:
	## Client-side: apply the same crater deformation locally.
	_apply_crater(world_pos, radius)

	# Also carve the tower on clients (no integrity check — server handles that)
	if _tower and _tower.has_method("carve_no_check"):
		_tower.carve_no_check(world_pos, radius)


func _apply_crater(world_pos: Vector3, radius: float) -> void:
	## Internal: remove a sphere of terrain at the given position.
	if _voxel_tool == null:
		return
	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	_voxel_tool.do_sphere(world_pos, radius)


# ======================================================================
#  Structure spawning (walls, ramps, spawns, loot, dummies)
# ======================================================================

func _spawn_walls_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn destructible walls, yielding every few walls to keep the
	## loading screen responsive and let the engine process frames.
	var wall_scene := preload("res://world/destructible_wall.tscn")
	var wall_sizes := [
		Vector3(10, 4, 1),
		Vector3(8, 3, 1),
		Vector3(12, 5, 1),
		Vector3(6, 3, 2),
		Vector3(14, 4, 1),
	]
	var tier_weights := [0.30, 0.35, 0.25, 0.10]
	var spawned := 0

	for i in num_walls:
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

		var pos := _get_random_ground_pos(rng, wall_size.y * 0.5, 30.0)
		if pos == Vector3.INF:
			continue

		# Skip if inside tower exclusion zone
		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue

		var wall: Node3D = wall_scene.instantiate()
		wall.name = "Wall_%d" % spawned
		wall.wall_size = wall_size
		wall.wall_tier = tier
		wall.position = pos
		wall.rotation.y = y_rot
		parent.add_child(wall)
		spawned += 1

		# Yield every 5 walls so the loading screen stays responsive
		if spawned % 5 == 0:
			await get_tree().process_frame

	print("[SeedWorld] Spawned %d walls" % spawned)


func _spawn_ramps_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn ramp structures, yielding every batch to spread load.
	var ramp_size := Vector3(4, 0.3, 8)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.5, 0.6, 0.5, 1)

	var angles_deg := [15.0, 20.0, 25.0, 30.0]
	var spawned := 0

	for i in num_ramps:
		var ramp_angle: float = angles_deg[rng.randi() % angles_deg.size()]
		var y_rot := rng.randf_range(0, TAU)

		var pos := _get_random_ground_pos(rng, 0.3, 25.0)
		if pos == Vector3.INF:
			continue

		# Skip if inside tower exclusion zone
		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue

		var ramp := StaticBody3D.new()
		ramp.name = "Ramp_%d" % spawned
		ramp.position = pos
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
		spawned += 1

		# Yield every 20 ramps (each is just 3 nodes, much lighter than walls)
		if spawned % 20 == 0:
			await get_tree().process_frame


func _spawn_player_spawns(rng: RandomNumberGenerator) -> void:
	## Create PlayerSpawnPoints markers directly on the ground.
	var container := get_parent().get_node_or_null("PlayerSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "PlayerSpawnPoints"
		get_parent().add_child(container)

	for child in container.get_children():
		child.queue_free()

	var spawned := 0
	for i in num_player_spawns:
		var pos := _get_random_ground_pos(rng, 1.0, 20.0)
		if pos == Vector3.INF:
			continue
		var marker := Marker3D.new()
		marker.name = "Spawn%d" % (spawned + 1)
		marker.position = pos
		container.add_child(marker)
		spawned += 1


func _spawn_loot_points(rng: RandomNumberGenerator) -> void:
	## Create LootSpawnPoints markers directly on the ground.
	var container := get_parent().get_node_or_null("LootSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "LootSpawnPoints"
		get_parent().add_child(container)

	for child in container.get_children():
		child.queue_free()

	var spawned := 0
	for i in num_loot_spawns:
		var pos := _get_random_ground_pos(rng, 0.5)
		if pos == Vector3.INF:
			continue
		var marker := Marker3D.new()
		marker.name = "Loot%d" % (spawned + 1)
		marker.position = pos
		container.add_child(marker)
		spawned += 1


func _spawn_dummies(rng: RandomNumberGenerator) -> void:
	## Spawn target dummies directly on the ground.
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

	var spawned := 0
	for i in num_dummies:
		var pos := _get_random_ground_pos(rng, 0.0, 25.0)
		if pos == Vector3.INF:
			continue
		var dummy: Node3D = dummy_scene.instantiate()
		dummy.name = "Dummy%d" % (spawned + 1)
		dummy.position = pos
		container.add_child(dummy)
		spawned += 1


func _precompute_tower_position(rng: RandomNumberGenerator) -> void:
	## Place the tower at map center (0, ground_height, 0).
	## Called before walls/ramps so they can respect the exclusion zone.
	## Consumes one RNG value to keep the seed sequence consistent.
	var _unused := rng.randi()  # Keep RNG sequence deterministic

	var ground_y := get_height_from_noise(0.0, 0.0)
	_tower_position = Vector3(0.0, ground_y, 0.0)
	print("[SeedWorld] Tower position: map center at %s" % str(_tower_position))


func _spawn_tower(_rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn the spiral tower at the pre-computed position.
	## Instantiates spiral_tower.tscn and awaits its voxel generation.
	if _tower_position == Vector3.INF:
		return  # Position wasn't computed

	var tower_scene := preload("res://world/spiral_tower.tscn")
	var tower: Node3D = tower_scene.instantiate()
	tower.name = "SpiralTower"
	tower.position = _tower_position
	parent.add_child(tower)

	# Store reference for crater integration
	_tower = tower

	# Wait for the tower's voxel generation to finish before continuing
	if tower.has_signal("generation_complete"):
		await tower.generation_complete

	print("[SeedWorld] Spiral tower spawned at %s" % str(_tower_position))


func _create_cloud_sky_shader() -> Shader:
	## Creates a sky shader with procedural clouds using layered noise.
	var shader := Shader.new()
	shader.code = """
shader_type sky;

// Sky colors
uniform vec3 sky_top_color : source_color = vec3(0.3, 0.5, 0.88);
uniform vec3 sky_horizon_color : source_color = vec3(0.6, 0.72, 0.9);
uniform vec3 ground_bottom_color : source_color = vec3(0.22, 0.32, 0.14);
uniform vec3 ground_horizon_color : source_color = vec3(0.45, 0.55, 0.4);
uniform float sky_curve : hint_range(0.0, 1.0) = 0.15;

// Cloud parameters
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow_color : source_color = vec3(0.7, 0.75, 0.85);
uniform float cloud_speed : hint_range(0.0, 0.1) = 0.008;
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.45;
uniform float cloud_sharpness : hint_range(0.0, 20.0) = 6.0;
uniform float cloud_density : hint_range(0.0, 1.0) = 0.7;
uniform float cloud_height : hint_range(0.0, 1.0) = 0.35;

// Hash-based noise (no texture needed)
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void sky() {
	vec3 dir = EYEDIR;
	float horizon_blend = smoothstep(-0.05, 0.0, dir.y);

	// Ground color
	float ground_t = clamp(-dir.y * 10.0, 0.0, 1.0);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, ground_t);

	// Sky gradient
	float sky_t = clamp(pow(max(dir.y, 0.0), sky_curve), 0.0, 1.0);
	vec3 sky = mix(sky_horizon_color, sky_top_color, sky_t);

	// Base sky (ground below horizon, sky above)
	vec3 col = mix(ground, sky, horizon_blend);

	// Clouds — project onto a flat plane at cloud_height
	if (dir.y > 0.01) {
		vec2 cloud_uv = dir.xz / (dir.y + cloud_height) * 3.0;
		cloud_uv += TIME * cloud_speed;

		float n = fbm(cloud_uv * 3.0);
		n += 0.5 * fbm(cloud_uv * 6.0 + vec2(1.7, 3.2));
		n *= 0.5;

		// Shape clouds
		float cloud = smoothstep(1.0 - cloud_coverage, 1.0 - cloud_coverage + (1.0 / cloud_sharpness), n);
		cloud *= cloud_density;

		// Fade clouds near horizon to avoid hard cutoff
		float horizon_fade = smoothstep(0.01, 0.15, dir.y);
		cloud *= horizon_fade;

		// Lit side vs shadow side based on noise detail
		float detail = fbm(cloud_uv * 12.0 + vec2(5.3, 2.1));
		vec3 cloud_col = mix(cloud_shadow_color, cloud_color, detail);

		col = mix(col, cloud_col, cloud * 0.85);
	}

	COLOR = col;
}
"""
	return shader
