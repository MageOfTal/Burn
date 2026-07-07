extends Node3D

## Procedural terrain using custom volumetric chunk system.
## SDF data is stored per-chunk and meshed with VoxelMesherTransvoxel.
## Collision meshes include a 1-voxel skirt overlap at chunk boundaries
## to eliminate Jolt Physics boundary-edge impulse artifacts.
##
## Key APIs:
##   - create_crater(pos, radius, depth)  — deforms terrain SDF
##   - get_height_at(x, z)                — raycast-based surface query
##   - get_normal_at(x, z)                — central-difference from height samples
##   - get_height_from_noise(x, z)        — instant noise lookup (no physics)
##
## Structures (walls, ramps) are spawned on top of the terrain surface.

## Terrain size and shape
@export_group("Terrain")
@export var map_size: float = 400.0         ## Circular map diameter (world units)
@export var height_scale: float = 16.0      ## Max height variation (meters)
@export var noise_period: float = 128.0     ## Noise repeat period (larger = broader hills)
@export var height_range: float = 32.0      ## Vertical span of noise terrain (meters)

## Structure generation
@export_group("Structures")
@export var num_walls: int = 200
@export var num_ramps: int = 200
@export var num_player_spawns: int = 40
@export var num_loot_spawns: int = 500
@export var num_obj_structures: int = 30
@export var num_dummies: int = 0
@export var structure_margin: float = 25.0  ## Keep structures this far from edges

## Signals
signal world_generation_complete

## Internal refs
var _terrain_system: TerrainSystem = null
var _noise: FastNoiseLite = null
var _terrain_ready := false
var structures_complete := false  ## True after all walls/ramps have been spawned
var _structure_rng: RandomNumberGenerator = null  ## Stored for deferred heavy spawning

## Spiral tower reference (for crater carving integration)
var _tower: Node = null
var _tower_position: Vector3 = Vector3.INF  ## Tower center XZ for exclusion zone
const TOWER_EXCLUSION_RADIUS := 15.0        ## No walls/ramps within this of tower


func _ready() -> void:
	# --- Noise setup (same as old VoxelGeneratorNoise2D) ---
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0 / noise_period
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.45
	noise.seed = 10293847
	_noise = noise

	# --- Terrain material ---
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.65, 0.35)

	# --- Custom terrain system (shared StaticBody3D, full collision everywhere) ---
	_terrain_system = TerrainSystem.new()
	_terrain_system.name = "TerrainSystem"
	add_child(_terrain_system)
	_terrain_system.setup(noise, height_range, mat)

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
		VideoSettings.call_deferred("apply_all")

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
	var t_total := Time.get_ticks_msec()
	var rng := _structure_rng
	var structures_node := Node3D.new()
	structures_node.name = "Structures"
	add_child(structures_node)

	var t_terrain := Time.get_ticks_msec()
	await _terrain_system.build_initial()
	print("[STARTUP] Terrain build: %dms" % (Time.get_ticks_msec() - t_terrain))

	# Pre-compute tower position so walls/ramps can respect the exclusion zone.
	_precompute_tower_position(rng)

	if not GameManager.debug_skip_structures:
		var t := Time.get_ticks_msec()
		await _spawn_walls_batched(rng, structures_node)
		print("[STARTUP] Walls: %dms" % (Time.get_ticks_msec() - t))
		t = Time.get_ticks_msec()
		await _spawn_ramps_batched(rng, structures_node)
		print("[STARTUP] Ramps: %dms" % (Time.get_ticks_msec() - t))
		t = Time.get_ticks_msec()
		await _spawn_smooth_ramps_batched(rng, structures_node)
		print("[STARTUP] Smooth ramps: %dms" % (Time.get_ticks_msec() - t))
		t = Time.get_ticks_msec()
		await _spawn_obj_structures_batched(rng, structures_node)
		print("[STARTUP] Obj structures: %dms" % (Time.get_ticks_msec() - t))
		t = Time.get_ticks_msec()
		await _spawn_tower(rng, structures_node)
		print("[STARTUP] Tower: %dms" % (Time.get_ticks_msec() - t))
	else:
		print("[SeedWorld] Skipping structures (debug toggle)")
		await get_tree().process_frame
	_spawn_dummies(rng)

	_spawn_test_platforms()
	_spawn_sine_ramps()
	_spawn_test_cube()
	_spawn_push_blocks()

	structures_complete = true
	world_generation_complete.emit()
	print("[STARTUP] Total: %dms" % (Time.get_ticks_msec() - t_total))


func reset_world() -> void:
	## Reset the terrain (clear all crater deformations) and destroy all structures.
	## Called by network_manager.reset_game() before re-spawning structures.
	## After calling this, call _spawn_heavy_structures() to rebuild.
	print("[SeedWorld] ======== RESETTING WORLD ========")

	# --- 1. Reset terrain system (clears SDF edits and destroys chunks) ---
	if _terrain_system:
		_terrain_system.reset()
		print("[SeedWorld] Terrain system reset (craters cleared)")

	# Clear structure bakes (positions change on reset due to RNG)
	for path in [WALL_BAKE_PATH, RAMP_BAKE_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)

	# --- 2. Destroy all structures (walls, ramps, tower) ---
	var structures := get_node_or_null("Structures")
	if structures:
		# Clear tower reference BEFORE freeing (tower is a child of Structures)
		_tower = null
		structures.queue_free()
		# Wait a frame so the node tree is actually cleaned up
		await get_tree().process_frame
		print("[SeedWorld] Structures removed")

	# --- 3. Clean up any leftover topple bodies / chunks in the scene root ---
	var scene_root := get_tree().current_scene
	if scene_root:
		for child in scene_root.get_children():
			if child.name.begins_with("TowerToppleBody") or child.name.begins_with("TowerChunk"):
				child.queue_free()

	# --- 4. Reset the Dummies container ---
	var dummies := get_parent().get_node_or_null("Dummies")
	if dummies:
		for child in dummies.get_children():
			child.queue_free()

	# --- 5. Reset state so _spawn_heavy_structures() works again ---
	structures_complete = false
	_tower = null
	_tower_position = Vector3.INF

	# Re-seed the RNG with the same seed so structures spawn identically
	var rng := RandomNumberGenerator.new()
	rng.seed = 10293847
	# Consume the same RNG calls as _ready() does for spawns/loot
	_spawn_player_spawns(rng)
	_spawn_loot_points(rng)
	_structure_rng = rng

	print("[SeedWorld] World reset complete — ready for _spawn_heavy_structures()")


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
	query.collision_mask = CollisionLayers.WORLD
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
	## used by the terrain system. No raycasts, no physics, instant.
	## NOTE: Does NOT account for craters (use get_height_at() for that).
	if _terrain_system:
		return _terrain_system.get_height_from_noise(world_x, world_z)
	if _noise == null:
		return 0.0
	return (_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5 * height_range


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
#  Terrain deformation (craters) via TerrainSystem
# ======================================================================

func create_crater(world_pos: Vector3, radius: float, _crater_depth: float,
		attacker_id: int = -1) -> void:
	## Deform the terrain to create a crater at the given world position.
	## Stamps the SDF grid and queues affected chunks for re-meshing.
	## Also carves the spiral tower if one exists.
	## Server calls this, then syncs to clients.
	if _terrain_system == null:
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
	if _terrain_system == null:
		return
	_terrain_system.deform(world_pos, radius)




# ======================================================================
#  Structure spawning (walls, ramps, spawns, loot, dummies)
# ======================================================================

const WALL_BAKE_PATH := "res://terrain/wall_bake.bin"

func _spawn_walls_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	var wall_scene := preload("res://world/destructible_wall.tscn")

	# Try loading baked wall parameters
	var wall_params: Array = _load_wall_bake()
	if wall_params.is_empty():
		wall_params = _generate_wall_params(rng)
		_save_wall_bake(wall_params)

	var t_total := Time.get_ticks_usec()
	var t_inst := 0
	var t_add := 0
	var spawned := 0

	for p in wall_params:
		var t0 := Time.get_ticks_usec()
		var wall: Node3D = wall_scene.instantiate()
		wall.name = "Wall_%d" % spawned
		wall.wall_size = p["size"]
		wall.wall_tier = p["tier"]
		wall.position = p["pos"]
		wall.rotation.y = p["rot"]
		var t1 := Time.get_ticks_usec()
		parent.add_child(wall)
		var t2 := Time.get_ticks_usec()
		t_inst += t1 - t0
		t_add += t2 - t1
		spawned += 1

		if spawned % 50 == 0:
			await get_tree().process_frame

	print("[SeedWorld] Spawned %d walls (inst=%dms add=%dms total=%dms)" % [
		spawned, t_inst / 1000, t_add / 1000, (Time.get_ticks_usec() - t_total) / 1000])


func _generate_wall_params(rng: RandomNumberGenerator) -> Array:
	var wall_sizes := [
		Vector3(10, 4, 1), Vector3(8, 3, 1), Vector3(12, 5, 1),
		Vector3(6, 3, 2), Vector3(14, 4, 1),
	]
	var tier_weights := [0.30, 0.35, 0.25, 0.10]
	var params: Array = []

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
		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue
		params.append({"size": wall_size, "tier": tier, "pos": pos, "rot": y_rot})

	return params


func _save_wall_bake(params: Array) -> void:
	var f := FileAccess.open(WALL_BAKE_PATH, FileAccess.WRITE)
	if f:
		f.store_var(params, true)
		f.close()


func _load_wall_bake() -> Array:
	if not FileAccess.file_exists(WALL_BAKE_PATH):
		return []
	var f := FileAccess.open(WALL_BAKE_PATH, FileAccess.READ)
	if not f:
		return []
	var data = f.get_var(true)
	f.close()
	if data is Array:
		return data
	return []


const RAMP_BAKE_PATH := "res://terrain/ramp_bake.bin"

func _spawn_ramps_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	var ramp_scene := preload("res://world/destructible_ramp.tscn")

	var ramp_params: Array = _load_ramp_bake()
	if ramp_params.is_empty():
		ramp_params = _generate_ramp_params(rng)
		_save_ramp_bake(ramp_params)

	var spawned := 0
	for p in ramp_params:
		var ramp: Node3D = ramp_scene.instantiate()
		ramp.name = "Ramp_%d" % spawned
		ramp.ramp_size = p["size"]
		ramp.ramp_tier = p["tier"]
		ramp.position = p["pos"]
		ramp.rotation.y = p["rot_y"]
		ramp.rotation.x = p["rot_x"]
		parent.add_child(ramp)
		spawned += 1
		if spawned % 50 == 0:
			await get_tree().process_frame

	print("[SeedWorld] Spawned %d destructible ramps" % spawned)


func _generate_ramp_params(rng: RandomNumberGenerator) -> Array:
	var ramp_sizes := [
		Vector3(4, 0.5, 8), Vector3(3, 0.5, 6),
		Vector3(5, 0.5, 10), Vector3(3, 0.5, 5),
	]
	var angles_deg := [15.0, 20.0, 25.0, 30.0]
	var tier_weights := [0.35, 0.35, 0.20, 0.10]
	var params: Array = []
	for i in num_ramps:
		var ramp_size: Vector3 = ramp_sizes[rng.randi() % ramp_sizes.size()]
		var ramp_angle: float = angles_deg[rng.randi() % angles_deg.size()]
		var y_rot := rng.randf_range(0, TAU)
		var roll := rng.randf()
		var tier: int = 0
		var cumulative := 0.0
		for t in tier_weights.size():
			cumulative += tier_weights[t]
			if roll <= cumulative:
				tier = t
				break
		var pos := _get_random_ground_pos(rng, 0.3, 25.0)
		if pos == Vector3.INF:
			continue
		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue
		params.append({"size": ramp_size, "tier": tier, "pos": pos, "rot_y": y_rot, "rot_x": deg_to_rad(ramp_angle)})
	return params


func _save_ramp_bake(params: Array) -> void:
	var f := FileAccess.open(RAMP_BAKE_PATH, FileAccess.WRITE)
	if f:
		f.store_var(params, true)
		f.close()


func _load_ramp_bake() -> Array:
	if not FileAccess.file_exists(RAMP_BAKE_PATH):
		return []
	var f := FileAccess.open(RAMP_BAKE_PATH, FileAccess.READ)
	if not f:
		return []
	var data = f.get_var(true)
	f.close()
	return data if data is Array else []


func _spawn_smooth_ramps_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn non-destructible smooth ramps (single mesh, no block grid).
	## Longer than block ramps, pink for visibility.
	var smooth_scene := preload("res://world/smooth_ramp.tscn")
	var ramp_sizes := [
		Vector3(5, 0.5, 14),
		Vector3(4, 0.5, 12),
		Vector3(6, 0.5, 16),
	]
	var angles_deg := [15.0, 20.0, 25.0, 30.0]
	var num_smooth := num_ramps / 4  # ~50 smooth ramps
	var spawned := 0

	for i in num_smooth:
		var ramp_size: Vector3 = ramp_sizes[rng.randi() % ramp_sizes.size()]
		var ramp_angle: float = angles_deg[rng.randi() % angles_deg.size()]
		var y_rot := rng.randf_range(0, TAU)

		var pos := _get_random_ground_pos(rng, 0.3, 25.0)
		if pos == Vector3.INF:
			continue

		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue

		var ramp: StaticBody3D = smooth_scene.instantiate()
		ramp.name = "SmoothRamp_%d" % spawned
		ramp.ramp_size = ramp_size
		ramp.position = pos
		ramp.rotation.y = y_rot
		ramp.rotation.x = deg_to_rad(ramp_angle)
		parent.add_child(ramp)
		spawned += 1

		if spawned % 10 == 0:
			await get_tree().process_frame

	print("[SeedWorld] Spawned %d smooth ramps" % spawned)


func _spawn_obj_structures_batched(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn destructible OBJ structures, yielding every batch for responsiveness.
	## Auto-discovers ObjStructureData .tres files from res://world/definitions/.
	var obj_defs: Array = []
	var dir := DirAccess.open("res://world/definitions/")
	if dir:
		dir.list_dir_begin()
		var file_name := dir.get_next()
		while file_name != "":
			if file_name.ends_with("_structure.tres"):
				var res := load("res://world/definitions/" + file_name)
				if res is ObjStructureData:
					obj_defs.append(res)
			file_name = dir.get_next()

	if obj_defs.is_empty():
		print("[SeedWorld] No ObjStructureData definitions found, skipping OBJ structures")
		return

	var obj_scene := preload("res://world/destructible_obj_structure.tscn")
	var spawned := 0

	for i in num_obj_structures:
		var data: ObjStructureData = obj_defs[rng.randi() % obj_defs.size()]

		var y_offset := data.grid_dimensions.y * BlockGridManager.BLOCK_SIZE * 0.5
		var pos := _get_random_ground_pos(rng, y_offset, 25.0)
		if pos == Vector3.INF:
			continue

		var y_rot := rng.randf_range(0, TAU)

		# Skip if inside tower exclusion zone
		if _tower_position != Vector3.INF:
			var dist_to_tower := Vector2(pos.x - _tower_position.x, pos.z - _tower_position.z).length()
			if dist_to_tower < TOWER_EXCLUSION_RADIUS:
				continue

		var obj_structure: Node3D = obj_scene.instantiate()
		obj_structure.name = "ObjStructure_%d" % spawned
		obj_structure.structure_data = data
		obj_structure.position = pos
		obj_structure.rotation.y = y_rot
		parent.add_child(obj_structure)
		if spawned < 3:
			print("[SeedWorld] ObjStructure_%d at %s (grid %s, %d cells)" % [
				spawned, pos, data.grid_dimensions, data.occupied_cells.size()])
		spawned += 1

		# Yield every 3 structures (OBJ structures have more blocks than walls)
		if spawned % 3 == 0:
			await get_tree().process_frame

	print("[SeedWorld] Spawned %d OBJ structures" % spawned)


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


func _spawn_test_platforms() -> void:
	## DEBUG: Upright wall + 40° upward ramp side by side for contact normal testing.
	## Wall 1 (white) stands upright. Wall 2 (red) is a ramp angled 40° upward,
	## hinged from the top-right edge of Wall 1. Walk along Z on the seam
	## so the capsule contacts both surfaces simultaneously.
	var pos_x := 15.0
	var pos_z := 0.0
	var ground_y := get_height_from_noise(pos_x, pos_z)
	var wall_height := 3.0
	var wall_depth := 1.0   # Top surface width the player walks on
	var wall_length := 12.0
	var ramp_width := 5.0
	var ramp_thickness := 0.6  # Must exceed capsule radius 0.4 to prevent phase-through

	var container := Node3D.new()
	container.name = "TestPlatforms"
	add_child(container)

	# --- Wall 1: Upright (white) ---
	var w1 := StaticBody3D.new()
	w1.name = "TestUpright"
	w1.collision_layer = CollisionLayers.WORLD
	w1.collision_mask = 0
	w1.position = Vector3(pos_x - wall_depth * 0.5, ground_y + wall_height * 0.5, pos_z)

	var shape1 := BoxShape3D.new()
	shape1.size = Vector3(wall_depth, wall_height, wall_length)
	var col1 := CollisionShape3D.new()
	col1.shape = shape1
	w1.add_child(col1)

	var mesh1 := MeshInstance3D.new()
	var box1 := BoxMesh.new()
	box1.size = shape1.size
	mesh1.mesh = box1
	w1.add_child(mesh1)
	container.add_child(w1)

	# --- Wall 2: Ramp tilted 40° upward (red) ---
	# Pivot at the seam — top-right edge of Wall 1.
	# The ramp hinges from this edge and slopes upward to the right.
	var seam := Vector3(pos_x, ground_y, pos_z)

	var pivot := Node3D.new()
	pivot.name = "TestTiltPivot"
	pivot.position = seam
	pivot.rotation.z = deg_to_rad(40)
	container.add_child(pivot)

	var w2 := StaticBody3D.new()
	w2.name = "TestTilted"
	w2.collision_layer = CollisionLayers.WORLD
	w2.collision_mask = 0
	w2.position = Vector3(ramp_width * 0.5, -ramp_thickness * 0.5, 0.0)

	var shape2 := BoxShape3D.new()
	shape2.size = Vector3(ramp_width, ramp_thickness, wall_length)
	var col2 := CollisionShape3D.new()
	col2.shape = shape2
	w2.add_child(col2)

	var mesh2 := MeshInstance3D.new()
	var box2 := BoxMesh.new()
	box2.size = shape2.size
	mesh2.mesh = box2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.2, 0.2)
	mesh2.material_override = mat
	w2.add_child(mesh2)
	pivot.add_child(w2)

	var top_y := ground_y + wall_height
	print("[TestPlatforms] Upright wall + 40° ramp at x=%.0f z=%.0f — top at y=%.1f" % [
		pos_x, pos_z, top_y])


func _spawn_test_cube() -> void:
	## DEBUG: Giant heavy RigidBody3D cube for wall-slide testing.
	var pos := Vector3(30, 0, 0)
	var ground_y := get_height_from_noise(pos.x, pos.z)

	var cube := RigidBody3D.new()
	cube.name = "TestCube"
	cube.mass = 50000.0
	cube.can_sleep = false
	cube.lock_rotation = true
	cube.collision_layer = CollisionLayers.WORLD
	cube.collision_mask = CollisionLayers.WORLD
	cube.position = Vector3(pos.x, ground_y + 15.0, pos.z)

	var shape := BoxShape3D.new()
	shape.size = Vector3(20, 20, 20)
	var col := CollisionShape3D.new()
	col.shape = shape
	cube.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = shape.size
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.3, 0.1)
	mesh.material_override = mat
	cube.add_child(mesh)

	add_child(cube)
	print("[TestCube] 50000kg cube at (%.0f, %.1f, %.0f) — 20m, no gravity" % [pos.x, ground_y + 15.0, pos.z])


func _spawn_push_blocks() -> void:
	## DEBUG: Row of pushable RigidBody3D blocks past the toad bowl area.
	## Twice player height (3.6m), half player mass (40kg).
	var count := 8
	var block_size := Vector3(1.5, 3.6, 1.5)
	var block_mass := 40.0
	var start_z := 40.0
	var spacing := 3.0

	var container := Node3D.new()
	container.name = "PushBlocks"
	add_child(container)

	for i in count:
		var x := float(i - count / 2) * spacing
		var z := start_z
		var ground_y := get_height_from_noise(x, z)

		var body := RigidBody3D.new()
		body.name = "PushBlock_%d" % i
		body.mass = block_mass
		body.collision_layer = CollisionLayers.ITEMS | CollisionLayers.WALL_SMOOTH
		body.collision_mask = CollisionLayers.DEFAULT_PHYSICS
		body.contact_monitor = false
		body.lock_rotation = false
		# Continuous CD so high-speed player↔box contacts don't tunnel through.
		# The phasing-into-box bug we diagnosed via [BOXLOG] traced to the
		# constraint solver missing fast motion in a single tick.
		body.continuous_cd = true

		var shape := BoxShape3D.new()
		shape.size = block_size
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)

		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = block_size
		mesh.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.6, 0.9)
		mesh.material_override = mat
		body.add_child(mesh)

		body.position = Vector3(x, ground_y + block_size.y * 0.5, z)
		container.add_child(body)

	print("[PushBlocks] Spawned %d blocks (%.0fkg, %.1fm tall) at z=%.0f" % [
		count, block_mass, block_size.y, start_z])


func _spawn_sine_ramps() -> void:
	## DEBUG: Sinusoidal ramps with varying max inclines for movement testing.
	## Each ramp is a smooth wave surface. The steepest point of the wave
	## matches the labelled max angle. Ramps are placed side by side near origin.
	var angles := [30.0, 50.0, 60.0, 70.0, 80.0]
	var colors := [
		Color(0.3, 0.7, 0.3),  # green  — 30°
		Color(0.7, 0.7, 0.2),  # yellow — 50°
		Color(0.8, 0.4, 0.1),  # orange — 60°
		Color(0.8, 0.2, 0.2),  # red    — 70°
		Color(0.6, 0.1, 0.6),  # purple — 80°
	]
	var wavelength := 20.0
	var ramp_width := 12.0
	var ramp_length := 60.0  # 3 complete wavelengths
	var spacing := 4.0
	var base_x := 40.0
	var base_z := 0.0
	var ground_y := get_height_from_noise(base_x, base_z) + 5.0  # elevated above terrain

	var container := Node3D.new()
	container.name = "SineTestRamps"
	add_child(container)

	for i in angles.size():
		var max_angle: float = angles[i]
		var amplitude := tan(deg_to_rad(max_angle)) * wavelength / (TAU)
		var ramp := _create_sine_ramp(ramp_width, ramp_length, wavelength, amplitude, colors[i])
		ramp.name = "SineRamp_%d" % int(max_angle)
		ramp.position = Vector3(base_x, ground_y, base_z + i * (ramp_width + spacing))
		container.add_child(ramp)

	# Flat approach platform so the player can walk onto the ramps
	var platform := StaticBody3D.new()
	platform.name = "SineRampPlatform"
	platform.collision_layer = CollisionLayers.WORLD
	platform.collision_mask = 0
	var total_z := angles.size() * (ramp_width + spacing) - spacing
	var plat_size := Vector3(6.0, 0.5, total_z + 4.0)
	var plat_shape := BoxShape3D.new()
	plat_shape.size = plat_size
	var plat_col := CollisionShape3D.new()
	plat_col.shape = plat_shape
	platform.add_child(plat_col)
	var plat_mesh := MeshInstance3D.new()
	var plat_box := BoxMesh.new()
	plat_box.size = plat_size
	plat_mesh.mesh = plat_box
	var plat_mat := StandardMaterial3D.new()
	plat_mat.albedo_color = Color(0.5, 0.5, 0.5)
	plat_mesh.material_override = plat_mat
	platform.add_child(plat_mesh)
	platform.position = Vector3(base_x - 3.0 - plat_size.x * 0.5, ground_y - 0.25, base_z + total_z * 0.5 - 2.0)
	container.add_child(platform)

	print("[SineRamps] %d ramps at x=%.0f z=%.0f, ground_y=%.1f" % [
		angles.size(), base_x, base_z, ground_y])


func _create_sine_ramp(width: float, length: float, wavelength: float,
		amplitude: float, color: Color) -> StaticBody3D:
	## Build a sinusoidal surface as ArrayMesh + ConcavePolygonShape3D.
	var body := StaticBody3D.new()
	body.collision_layer = CollisionLayers.WORLD
	body.collision_mask = 0

	var step := 0.5  # vertex spacing in meters
	var nx := int(length / step)
	var nz := int(width / step)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()

	# --- Vertices ---
	for iz in range(nz + 1):
		for ix in range(nx + 1):
			var x := float(ix) * step
			var z := float(iz) * step
			var y := amplitude * sin(TAU * x / wavelength)
			verts.append(Vector3(x, y, z))

			# Analytical normal: dy/dx = amplitude * TAU/wavelength * cos(...)
			var dydx := amplitude * TAU / wavelength * cos(TAU * x / wavelength)
			norms.append(Vector3(-dydx, 1.0, 0.0).normalized())

	# --- Triangles ---
	var row := nx + 1
	for iz in range(nz):
		for ix in range(nx):
			var i00 := iz * row + ix
			var i10 := i00 + 1
			var i01 := i00 + row
			var i11 := i01 + 1
			# Two triangles per quad
			indices.append(i00); indices.append(i01); indices.append(i10)
			indices.append(i10); indices.append(i01); indices.append(i11)

	# --- Visual mesh ---
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices

	var arr_mesh := ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	arr_mesh.surface_set_material(0, mat)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	body.add_child(mesh_inst)

	# --- Collision (trimesh from triangle faces) ---
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for t in range(indices.size()):
		faces[t] = verts[indices[t]]

	var col_shape := ConcavePolygonShape3D.new()
	col_shape.backface_collision = true
	col_shape.set_faces(faces)

	var col_node := CollisionShape3D.new()
	col_node.shape = col_shape
	body.add_child(col_node)

	return body



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
