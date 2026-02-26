extends Node3D
class_name DestructibleBlockStructure

## Base class for destructible block-grid structures (walls, ramps, etc.).
## Manages a grid of StaticBody3D blocks with greedy meshing for visuals,
## AoE/hitscan damage with flat HP shielding, debris spawning, and RPC sync.
##
## Subclasses override _get_tier_info() and _get_debris_config() to provide
## their specific tier data and debris parameters.
##
## Server-authoritative: only the server tracks block health and spawns debris.
##
## GREEDY MESHING: blocks keep individual StaticBody3D for collision/damage,
## but the visual mesh is a single greedy-meshed surface. When blocks are
## destroyed the mesh rebuilds. This reduces draw calls from N_blocks to 1
## per structure.

const BLOCK_SIZE := 0.5
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
const FallingBlockClusterScript: GDScript = preload("res://world/falling_block_cluster.gd")

## Dimensions of the structure in world units. Subclasses provide a
## compatibility alias (wall_size / ramp_size) that delegates here.
var structure_size: Vector3 = Vector3(10, 4, 1)

## Block grid: Dictionary[Vector3i -> { "body": StaticBody3D, "hp": float }]
var _blocks: Dictionary = {}
var _num_x: int = 0
var _num_y: int = 0
var _num_z: int = 0

## Flat occupancy grid: 1 = block exists, 0 = empty. Indexed via _grid_idx().
## Avoids Dictionary hashing in BFS inner loops (~20x faster than _blocks.has()).
var _block_grid: PackedByteArray = PackedByteArray()
var _block_hp: float = 35.0
var _structure_material: StandardMaterial3D = null

## Shared resources (created once, reused by all blocks)
var _block_shape: BoxShape3D = null
var _block_script: GDScript = preload("res://world/wall_block.gd")

## Greedy mesh — single MeshInstance3D for the entire structure
var _mesh_instance: MeshInstance3D = null
var _mesh_dirty: bool = false

## Smooth collision — single StaticBody3D for player physics (layer 12, bit 2048).
## Per-block bodies are on layer 11 (bit 1024) for weapon raycasts only.
## This eliminates seam bouncing when the player slides along the wall.
var _collision_body: StaticBody3D = null
## Maps Vector2i(bx, bz) → Array[CollisionShape3D] for column shape rebuild.
var _col_shapes: Dictionary = {}

## Cached debris config from subclass (populated in _ready)
var _debris_size: float = 0.15
var _debris_per_block: int = 2
var _debris_lifetime: float = 5.0
var _debris_max_total: int = 40
var _debris_mass: float = 0.5
var _debris_name: String = "Debris"

## Tracks the last attacker who damaged this structure, for kill credit on
## falling clusters spawned by structural integrity failure.
var _last_attacker_id: int = -1

## When set before adding to scene, _ready() will skip the triple-loop and
## only spawn blocks from this data.  Used by the "disable falling clusters"
## debug toggle to split unsupported blocks into a new structure instance.
## Keys: "block_keys": Array[Vector3i], "block_hps": Dictionary[Vector3i→float]
var _init_from_detach: Dictionary = {}

## True for structures created via _spawn_detached_structure().  These have
## no y=0 ground blocks, so _check_structural_integrity() must not cascade
## (it would re-detach ALL blocks every time a single block is destroyed).
var _is_detached_structure: bool = false

## Falling state for detached structures (gravity simulation)
var _is_falling: bool = false
var _fall_velocity: float = 0.0
var _fall_ray_local: Vector3 = Vector3.ZERO  ## Bottom-center of blocks in local space


# ======================================================================
#  Virtual methods — subclasses MUST override these
# ======================================================================

func _get_tier_info() -> Dictionary:
	## Return { "color": Color, "block_hp": float } for the current tier.
	push_error("DestructibleBlockStructure._get_tier_info() not overridden!")
	return { "color": Color.MAGENTA, "block_hp": 35.0 }


func _get_debris_config() -> Dictionary:
	## Return debris parameters for this structure type.
	## Keys: "size", "per_block", "lifetime", "max_total", "mass", "name"
	push_error("DestructibleBlockStructure._get_debris_config() not overridden!")
	return {
		"size": 0.15, "per_block": 2,
		"lifetime": 5.0, "max_total": 40, "mass": 0.5, "name": "Debris",
	}


func _should_spawn_block(_bx: int, _by: int, _bz: int) -> bool:
	## Return true if a block should exist at grid position (bx, by, bz).
	## Default: all cells in the rectangular grid are populated.
	## Subclasses override to create non-rectangular shapes (e.g. OBJ voxelization).
	return true


func _create_structure_material(tier_info: Dictionary) -> StandardMaterial3D:
	## Create the material for the greedy mesh. Default: flat color from tier info.
	## Subclasses override to add textures, custom shaders, etc.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tier_info["color"]
	return mat


func _compute_quad_uvs(_normal: Vector3,
		_p0: Vector3, _p1: Vector3, _p2: Vector3, _p3: Vector3) -> Array[Vector2]:
	## Return [uv0, uv1, uv2, uv3] for the four quad vertices.
	## Default: simple 0-1 per face (unchanged behavior for walls/ramps).
	## Subclasses override for custom UV projection (e.g. triplanar mapping).
	return [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]


const MASS_PER_HP := 0.5  ## kg per HP point — mass scales with block HP

func _get_block_mass() -> float:
	## Mass per block (kg) for falling cluster physics.
	## Scales with block HP so reinforced blocks are heaviest:
	##   Wood(15hp)=7.5kg, Stone(35hp)=17.5kg, Metal(70hp)=35kg, Reinforced(140hp)=70kg
	return _block_hp * MASS_PER_HP


func _grid_idx(bx: int, by: int, bz: int) -> int:
	## Flat index into _block_grid for grid coordinate (bx, by, bz).
	return bx * _num_y * _num_z + by * _num_z + bz


# ======================================================================
#  Lifecycle
# ======================================================================

func _ready() -> void:
	# When spawning from detach data, use the pre-computed material and block_hp
	# from the parent structure. This avoids relying on subclass exports (which
	# default to wrong values on bare new() instances).
	var is_detach := not _init_from_detach.is_empty()

	if is_detach:
		_is_detached_structure = true
		_block_hp = _init_from_detach["block_hp"]
		_structure_material = _init_from_detach.get("material")
		if _structure_material == null:
			_structure_material = StandardMaterial3D.new()
			_structure_material.albedo_color = Color.MAGENTA  # Fallback
	else:
		var tier_info: Dictionary = _get_tier_info()
		_block_hp = tier_info["block_hp"]
		_structure_material = _create_structure_material(tier_info)

	var debris_cfg: Dictionary = _get_debris_config()
	_debris_size = debris_cfg["size"]
	_debris_per_block = debris_cfg["per_block"]
	_debris_lifetime = debris_cfg["lifetime"]
	_debris_max_total = debris_cfg["max_total"]
	_debris_mass = debris_cfg["mass"]
	_debris_name = debris_cfg["name"]

	# Create shared resources
	_block_shape = BoxShape3D.new()
	_block_shape.size = Vector3.ONE * BLOCK_SIZE

	# Calculate grid dimensions
	_num_x = maxi(int(structure_size.x / BLOCK_SIZE), 1)
	_num_y = maxi(int(structure_size.y / BLOCK_SIZE), 1)
	_num_z = maxi(int(structure_size.z / BLOCK_SIZE), 1)

	# Initialize flat occupancy grid (used by BFS and column scanning)
	_block_grid.resize(_num_x * _num_y * _num_z)
	_block_grid.fill(0)

	# Build block grid (collision only — no per-block meshes)
	var t_blocks := Time.get_ticks_usec()
	if is_detach:
		# Detached structure: spawn only the provided blocks with their HPs
		var detach_keys: Array = _init_from_detach["block_keys"]
		var detach_hps: Dictionary = _init_from_detach["block_hps"]
		for key: Vector3i in detach_keys:
			_spawn_block(key.x, key.y, key.z)
			if _blocks.has(key):
				var hp: float = detach_hps.get(key, _block_hp)
				_blocks[key]["hp"] = hp
				PhysicsServer3D.body_set_shielding_hp(
					_blocks[key]["body"].get_rid(), hp)
		_init_from_detach = {}  # Clear to free references
	else:
		for bx in _num_x:
			for by in _num_y:
				for bz in _num_z:
					if _should_spawn_block(bx, by, bz):
						_spawn_block(bx, by, bz)
	var t_blocks_end := Time.get_ticks_usec()

	# Build single greedy-meshed visual
	var t_mesh := Time.get_ticks_usec()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _structure_material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	_rebuild_greedy_mesh()
	var t_mesh_end := Time.get_ticks_usec()

	# Build smooth collision shell for player physics (no seam bouncing)
	var t_smooth := Time.get_ticks_usec()
	_build_smooth_collision()
	var t_smooth_end := Time.get_ticks_usec()

	var ready_total := Time.get_ticks_usec() - t_blocks
	if ready_total > 5000:
		print("[StructureReady] %s  blocks=%d  spawn_blocks=%dus  greedy_mesh=%dus  smooth_col=%dus  total=%dus%s" % [
			name, _blocks.size(),
			t_blocks_end - t_blocks,
			t_mesh_end - t_mesh,
			t_smooth_end - t_smooth,
			ready_total,
			"  (detach)" if is_detach else "",
		])

	# Detached structures: compute bottom-center for ground raycast and start falling
	if is_detach and not _blocks.is_empty():
		_is_falling = true
		var sum_x := 0.0
		var sum_z := 0.0
		var min_y := INF
		for key: Vector3i in _blocks:
			var body: StaticBody3D = _blocks[key]["body"]
			if is_instance_valid(body):
				sum_x += body.position.x
				sum_z += body.position.z
				var bottom_y := body.position.y - BLOCK_SIZE * 0.5
				if bottom_y < min_y:
					min_y = bottom_y
		var count := float(_blocks.size())
		_fall_ray_local = Vector3(sum_x / count, min_y, sum_z / count)

	set_physics_process(_is_falling)

	# Disable per-frame processing — only needed when _mesh_dirty is set
	set_process(false)


func _process(_delta: float) -> void:
	# Deferred mesh rebuild: blocks were destroyed, rebuild once then sleep
	if _mesh_dirty:
		_mesh_dirty = false
		var t_mesh := Time.get_ticks_usec()
		_rebuild_greedy_mesh()
		var t_mesh_end := Time.get_ticks_usec()
		var _mesh_us := t_mesh_end - t_mesh
		print("[GreedyMesh] %s  blocks=%d  time=%dus" % [name, _blocks.size(), _mesh_us])
		GameManager.frame_add("greedy_mesh", _mesh_us)
		set_process(false)


const DETACH_FALL_GRAVITY := 17.5  ## Same as player gravity (m/s²)

func _physics_process(delta: float) -> void:
	if not _is_falling:
		set_physics_process(false)
		return

	_fall_velocity += DETACH_FALL_GRAVITY * delta
	var move_dist := _fall_velocity * delta

	# Cast ray downward from bottom-center to detect ground (layer 1 = terrain)
	var bottom_world := to_global(_fall_ray_local)
	var space_state := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.from = bottom_world
	params.to = bottom_world + Vector3(0, -(move_dist + 0.05), 0)
	params.collision_mask = CollisionLayers.WORLD

	var result := space_state.intersect_ray(params)
	if result:
		# Hit ground — snap bottom to surface and stop falling
		var hit_y: float = result["position"].y
		var overshoot := bottom_world.y - hit_y
		if overshoot > 0:
			global_position.y -= overshoot
		_is_falling = false
		_fall_velocity = 0.0
		set_physics_process(false)
	else:
		global_position.y -= move_dist
		# Kill if fallen out of the world
		if global_position.y < -200:
			queue_free()


# ======================================================================
#  Block management
# ======================================================================

func _spawn_block(bx: int, by: int, bz: int) -> void:
	## Create a single block at grid position (bx, by, bz).
	## Block has collision only — no individual mesh (greedy mesh handles visuals).
	## Layer 11 (1024): weapon raycast detection only, NOT player physics.
	var block_body := StaticBody3D.new()
	block_body.set_script(_block_script)
	block_body.name = "Block_%d_%d_%d" % [bx, by, bz]
	block_body.grid_key = Vector3i(bx, by, bz)
	block_body.parent_wall = self
	block_body.collision_layer = CollisionLayers.WALL_BLOCKS
	block_body.collision_mask = 0

	# Position relative to structure center (local space)
	var local_offset := Vector3(
		(bx + 0.5 - _num_x * 0.5) * BLOCK_SIZE,
		(by + 0.5 - _num_y * 0.5) * BLOCK_SIZE,
		(bz + 0.5 - _num_z * 0.5) * BLOCK_SIZE
	)
	block_body.position = local_offset

	var col := CollisionShape3D.new()
	col.shape = _block_shape.duplicate()
	block_body.add_child(col)

	# No MeshInstance3D — greedy mesh handles all rendering
	add_child(block_body)

	# Tag for fast C++ shielding classification (skips Object::get() probes).
	# Tag 1 = WALL_BLOCK. HP cached on the physics body for zero-overhead reads.
	PhysicsServer3D.body_set_shielding_tag(block_body.get_rid(), 1)
	PhysicsServer3D.body_set_shielding_hp(block_body.get_rid(), _block_hp)

	_blocks[Vector3i(bx, by, bz)] = {
		"body": block_body,
		"hp": _block_hp,
	}
	_block_grid[_grid_idx(bx, by, bz)] = 1


# ======================================================================
#  Damage
# ======================================================================

func take_damage(_amount: float, _attacker_id: int) -> void:
	## No-op: structure-level take_damage exists so explosion scans find us.
	## Actual damage goes through take_damage_at() (explosions) or
	## _damage_block() (hitscan bullets hitting individual blocks).
	pass


func _damage_block(key: Vector3i, amount: float, _attacker_id: int) -> void:
	## Called by wall_block.gd when a bullet hits a specific block.
	if not multiplayer.is_server():
		return
	if not _blocks.has(key):
		return

	var block_data: Dictionary = _blocks[key]
	var block_body: StaticBody3D = block_data["body"]
	if not is_instance_valid(block_body):
		_blocks.erase(key)
		_block_grid[_grid_idx(key.x, key.y, key.z)] = 0
		return

	_last_attacker_id = _attacker_id
	block_data["hp"] -= amount
	PhysicsServer3D.body_set_shielding_hp(block_body.get_rid(), block_data["hp"])
	if block_data["hp"] <= 0.0:
		var block_pos: Vector3 = block_body.global_position
		var debris_count := randi_range(1, 2)
		var ok_frac := clampf(-block_data["hp"] / _block_hp, 0.0, 1.0)

		# Use the attacker's position as the blast origin so debris flies away
		# from the shooter. Falls back to a random offset if attacker not found.
		var blast_origin := block_pos + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized() * 0.5
		var players_node := get_tree().current_scene.get_node_or_null("Players")
		if players_node and _attacker_id >= 0:
			var attacker := players_node.get_node_or_null(str(_attacker_id))
			if attacker and is_instance_valid(attacker):
				blast_origin = attacker.global_position

		# Server: destroy block, sync to clients. Debris spawns on all peers via RPC.
		block_body.queue_free()
		_blocks.erase(key)
		_block_grid[_grid_idx(key.x, key.y, key.z)] = 0
		_mesh_dirty = true
		set_process(true)  # Wake up _process to rebuild mesh next frame
		_rebuild_column(key.x, key.z)
		_sync_block_destroyed.rpc(key, block_pos, blast_origin, debris_count, INF, ok_frac)

		# Host also spawns debris locally (RPC is call_remote, host needs it too).
		_spawn_debris(block_pos, blast_origin, debris_count, INF, ok_frac)

		# Check if destroying this block left floating islands
		_check_structural_integrity()

		if _blocks.is_empty():
			queue_free()


@rpc("authority", "call_remote", "reliable")
func _sync_block_destroyed(key: Vector3i, block_pos: Vector3 = Vector3.ZERO,
		blast_center: Vector3 = Vector3.ZERO, debris_count: int = 0,
		impact_speed: float = INF, overkill_frac: float = 0.0) -> void:
	## Client-side: remove a destroyed block, rebuild mesh, and spawn cosmetic debris.
	if _blocks.has(key):
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if is_instance_valid(block_body):
			block_body.queue_free()
		_blocks.erase(key)
		_block_grid[_grid_idx(key.x, key.y, key.z)] = 0
		_mesh_dirty = true
		set_process(true)
		_rebuild_column(key.x, key.z)

	# Spawn cosmetic debris on the client.
	if debris_count > 0:
		_spawn_debris(block_pos, blast_center, debris_count, impact_speed, overkill_frac)


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float, _attacker_id: int, exclude_rids: Array[RID] = [], impact_speed: float = INF) -> void:
	## Damage blocks within blast_radius of hit_pos. Only blocks in range take damage.
	## Shielding uses flat HP absorption: each wall block or player between the
	## explosion and a target block absorbs damage equal to its current HP.
	## exclude_rids: physics bodies to ignore in shielding raycasts (e.g. the rocket).
	print("[TakeDamageAt-ENTRY] %s  blocks=%d  is_server=%s  hit_pos=%s  global_pos=%s" % [
		name, _blocks.size(), str(multiplayer.is_server()), str(hit_pos), str(global_position)])
	if not multiplayer.is_server():
		return

	_last_attacker_id = _attacker_id
	var t_total := Time.get_ticks_usec()

	var space_state := get_world_3d().direct_space_state
	var debug_rays := GameManager.debug_show_explosion_rays

	var debris_spawned := 0
	var destroyed_keys: Array[Vector3i] = []
	var destroyed_positions: Array[Vector3] = []
	var destroyed_overkill: Array[float] = []
	var debug_ray_data: Array = []

	# Two-pass damage: compute all damage first (read-only), then apply.
	# This prevents block HP mutations from affecting shielding calculations
	# for later blocks, which caused directional bias in single-pass.
	var damage_map: Dictionary = {}  # Vector3i -> float

	# --- Pass 1: Compute damage for all blocks (read-only) ---
	var t_pass1 := Time.get_ticks_usec()
	if space_state:
		# C++ production path: single call does collection + distance filter +
		# falloff + multi-threaded shielding raycasts. Returns Dictionary[Vector3i -> float].
		var query := ExplosionHelper._make_shielding_query(hit_pos, exclude_rids)
		var repeat_count := 2000 if GameManager.debug_explosion_repeat else 1
		for _i in repeat_count:
			damage_map = space_state.calc_structure_explosion(
				query, _blocks, global_transform, BLOCK_SIZE,
				_num_x, _num_y, _num_z, blast_radius, amount
			)

		# Draw debug rays if enabled (visualize C++ results without changing behavior).
		if debug_rays:
			for key: Vector3i in _blocks:
				var block_data: Dictionary = _blocks[key]
				var block_body: StaticBody3D = block_data["body"]
				if not is_instance_valid(block_body):
					continue
				var block_world_pos: Vector3 = block_body.global_position
				var d: float = hit_pos.distance_to(block_world_pos)
				if d > blast_radius:
					continue
				var nd: float = d / blast_radius
				var fo: float = 1.0 / (1.0 + (nd * 3.0) ** 3)
				var dmg_raw: float = amount * fo
				var final_dmg: float = float(damage_map.get(key, 0.0))
				debug_ray_data.append({
					"from": hit_pos, "to": block_world_pos,
					"raw_dmg": dmg_raw, "final_dmg": final_dmg,
					"hits": [],
				})
	var t_pass1_end := Time.get_ticks_usec()

	# --- Pass 2: Apply all damage simultaneously ---
	var t_pass2 := Time.get_ticks_usec()
	for key: Vector3i in damage_map:
		if not _blocks.has(key):
			continue
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		block_data["hp"] -= damage_map[key]
		PhysicsServer3D.body_set_shielding_hp(block_body.get_rid(), block_data["hp"])
		if block_data["hp"] <= 0.0:
			destroyed_keys.append(key)
			destroyed_positions.append(block_body.global_position)
			destroyed_overkill.append(clampf(-block_data["hp"] / _block_hp, 0.0, 1.0))
			block_body.queue_free()
	var t_pass2_end := Time.get_ticks_usec()

	# Draw debug rays if toggled on
	var t_debug := Time.get_ticks_usec()
	if debug_rays and not debug_ray_data.is_empty():
		ExplosionHelper.draw_debug_rays(debug_ray_data)
	var t_debug_end := Time.get_ticks_usec()

	# Clean up destroyed entries and sync to clients (with debris info).
	var t_debris := Time.get_ticks_usec()
	var rpc_count := 0
	var debris_spawn_count := 0
	for i in destroyed_keys.size():
		var key := destroyed_keys[i]
		var block_pos := destroyed_positions[i]
		var ok_frac := destroyed_overkill[i]
		_blocks.erase(key)
		_block_grid[_grid_idx(key.x, key.y, key.z)] = 0

		# Determine debris count for this block.
		var to_spawn := 0
		if debris_spawned < _debris_max_total:
			to_spawn = mini(_debris_per_block, _debris_max_total - debris_spawned)
			debris_spawned += to_spawn

		# Sync to clients (they spawn debris). Host spawns debris locally.
		# Mirror the explosion center through the block so debris flies OUTWARD
		# from the blast, not into it. blast_center semantics = "where debris
		# should fly toward", so we reflect hit_pos to the far side.
		var debris_origin := block_pos + (block_pos - hit_pos)
		_sync_block_destroyed.rpc(key, block_pos, debris_origin, to_spawn, impact_speed, ok_frac)
		rpc_count += 1
		if to_spawn > 0:
			_spawn_debris(block_pos, debris_origin, to_spawn, impact_speed, ok_frac)
			debris_spawn_count += to_spawn
	var t_debris_end := Time.get_ticks_usec()

	var t_columns := Time.get_ticks_usec()
	var num_columns_rebuilt := 0
	if destroyed_keys.size() > 0:
		_mesh_dirty = true
		set_process(true)
		# Rebuild smooth collision for affected columns
		var rebuilt_columns: Dictionary = {}
		for key in destroyed_keys:
			var col_key := Vector2i(key.x, key.z)
			if not rebuilt_columns.has(col_key):
				rebuilt_columns[col_key] = true
				_rebuild_column(key.x, key.z)
				num_columns_rebuilt += 1
	var t_columns_end := Time.get_ticks_usec()

	# Batch structural integrity check after all blocks destroyed this frame
	var t_integrity := Time.get_ticks_usec()
	if destroyed_keys.size() > 0:
		_check_structural_integrity()
	var t_integrity_end := Time.get_ticks_usec()

	var t_total_end := Time.get_ticks_usec()
	var _total_us := t_total_end - t_total
	print("[TakeDamageAt] %s  blocks=%d  pass1=%dus  pass2=%dus  debug_rays=%dus  debris=%dus(rpcs=%d spawned=%d)  columns=%dus(%d)  integrity=%dus  destroyed=%d  total=%dus" % [
		name, _blocks.size(),
		t_pass1_end - t_pass1,
		t_pass2_end - t_pass2,
		t_debug_end - t_debug,
		t_debris_end - t_debris, rpc_count, debris_spawn_count,
		t_columns_end - t_columns, num_columns_rebuilt,
		t_integrity_end - t_integrity,
		destroyed_keys.size(),
		_total_us,
	])
	GameManager.tick_add("take_damage_at", _total_us)

	# If all blocks gone, remove the structure node entirely
	if _blocks.is_empty():
		queue_free()


# ======================================================================
#  Momentum damage — targeted block-by-block carving from physics impacts
# ======================================================================

func take_momentum_damage_at(hit_world_pos: Vector3, damage: float,
		p_attacker_id: int, impact_speed: float = INF) -> Dictionary:
	## Damage the block nearest to hit_world_pos via momentum carving.
	## Unlike take_damage_at() (AoE with shielding), this targets a SINGLE block.
	## Breakthrough explosions are handled by the caller using per-block momentum.
	## Returns { "absorbed": float, "block_destroyed": bool, "block_key": Vector3i,
	##           "block_pos": Vector3 }
	var empty_result := { "absorbed": 0.0, "block_destroyed": false,
		"block_key": Vector3i.ZERO, "block_pos": Vector3.ZERO }
	if not multiplayer.is_server():
		return empty_result
	if _blocks.is_empty():
		return empty_result

	_last_attacker_id = p_attacker_id

	# Transform world position to local grid coordinates
	var local_pos: Vector3 = global_transform.affine_inverse() * hit_world_pos
	var gx := roundi(local_pos.x / BLOCK_SIZE + _num_x * 0.5 - 0.5)
	var gy := roundi(local_pos.y / BLOCK_SIZE + _num_y * 0.5 - 0.5)
	var gz := roundi(local_pos.z / BLOCK_SIZE + _num_z * 0.5 - 0.5)
	var target_key := Vector3i(gx, gy, gz)

	# If exact key doesn't exist, find the nearest block within 2 cells
	if not _blocks.has(target_key):
		var best_key := Vector3i(-1, -1, -1)
		var best_dist_sq := 999.0
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for dz in range(-2, 3):
					var candidate := Vector3i(gx + dx, gy + dy, gz + dz)
					if _blocks.has(candidate):
						var d := Vector3(dx, dy, dz).length_squared()
						if d < best_dist_sq:
							best_dist_sq = d
							best_key = candidate
		if best_dist_sq > 998.0:
			return empty_result
		target_key = best_key

	var block_data: Dictionary = _blocks[target_key]
	var block_body: StaticBody3D = block_data["body"]
	var hp_before: float = block_data["hp"]
	var absorbed: float = minf(damage, hp_before)

	# Apply damage
	block_data["hp"] -= damage
	if block_data["hp"] > 0.0:
		PhysicsServer3D.body_set_shielding_hp(block_body.get_rid(), block_data["hp"])
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": target_key, "block_pos": block_body.global_position }

	# Block destroyed
	var block_pos: Vector3 = block_body.global_position
	var ok_frac := clampf(-block_data["hp"] / _block_hp, 0.0, 1.0)
	block_body.queue_free()
	_blocks.erase(target_key)
	_block_grid[_grid_idx(target_key.x, target_key.y, target_key.z)] = 0
	_mesh_dirty = true
	set_process(true)
	_rebuild_column(target_key.x, target_key.z)

	# Sync destruction + debris to clients
	var debris_count := randi_range(1, 2)
	_sync_block_destroyed.rpc(target_key, block_pos, hit_world_pos, debris_count, impact_speed, ok_frac)
	_spawn_debris(block_pos, hit_world_pos, debris_count, impact_speed, ok_frac)

	# Structural integrity check (may detach more blocks)
	if not _blocks.is_empty():
		_check_structural_integrity()
	if _blocks.is_empty():
		queue_free()

	return { "absorbed": absorbed, "block_destroyed": true,
		"block_key": target_key, "block_pos": block_pos }


# ======================================================================
#  Debris (delegates to DebrisHelper static utility)
# ======================================================================

func _spawn_debris(block_pos: Vector3, blast_center: Vector3, count: int,
		impact_speed: float = INF, overkill_frac: float = 0.0) -> void:
	DebrisHelper.spawn_debris(
		get_parent(), block_pos, blast_center, count, _structure_material,
		impact_speed, overkill_frac,
		{
			"size": _debris_size,
			"lifetime": _debris_lifetime, "mass": _debris_mass,
			"name": _debris_name,
		}
	)


# ======================================================================
#  Structural integrity — BFS flood-fill from ground blocks
# ======================================================================
#
# After any block destruction, checks if remaining blocks are still connected
# to the ground row (y=0). Unsupported blocks detach as FallingBlockCluster
# physics objects that fall, deal contact damage, and sync across network.

func _check_structural_integrity() -> void:
	## Server-only: find blocks not connected to ground and detach them.
	if not multiplayer.is_server():
		return
	if _blocks.is_empty():
		return
	# Detached structures have no y=0 ground blocks by definition.  Skip the
	# integrity cascade — otherwise every single block destruction would
	# re-detach ALL remaining blocks into yet another new structure, creating
	# an infinite chain of ephemeral objects.
	if _is_detached_structure:
		return

	var t_si_total := Time.get_ticks_usec()

	# C++ BFS: returns PackedInt32Array of (bx,by,bz) triplets for unsupported blocks.
	# Handles ground seed collection, BFS expansion, early exit, and result gathering
	# entirely in native code with raw pointer access (~20-40x faster than GDScript).
	var space_state := get_world_3d().direct_space_state
	var result := space_state.calc_structural_integrity(
		_block_grid, _num_x, _num_y, _num_z, _blocks.size())

	# Early exit: no unsupported blocks (C++ already logged BFS timing)
	if result.is_empty():
		GameManager.tick_add("structural_integrity", Time.get_ticks_usec() - t_si_total)
		return

	# Parse triplets into Vector3i array
	var unsupported: Array[Vector3i] = []
	var count := result.size() / 3
	unsupported.resize(count)
	for i in count:
		var base := i * 3
		unsupported[i] = Vector3i(result[base], result[base + 1], result[base + 2])

	# Group unsupported blocks into connected components, each becomes a cluster
	var t_comp := Time.get_ticks_usec()
	var components := _find_connected_components(unsupported)
	var t_comp_end := Time.get_ticks_usec()

	var t_detach := Time.get_ticks_usec()
	for component in components:
		_detach_cluster(component)
	var t_detach_end := Time.get_ticks_usec()

	var si_us := Time.get_ticks_usec() - t_si_total
	print("[StructuralIntegrity] %s  blocks=%d  unsupported=%d  components=%dus(%d)  detach=%dus  total=%dus" % [
		name, _blocks.size(), unsupported.size(),
		t_comp_end - t_comp, components.size(),
		t_detach_end - t_detach,
		si_us,
	])
	GameManager.tick_add("structural_integrity", si_us)


func _find_connected_components(keys: Array[Vector3i]) -> Array:
	## Given a list of block keys, group into connected components via BFS.
	## Returns Array of Array[Vector3i], each sub-array is one component.
	var key_set: Dictionary = {}
	for key in keys:
		key_set[key] = true

	var visited: Dictionary = {}
	var components: Array = []

	for start_key in keys:
		if visited.has(start_key):
			continue
		var component: Array[Vector3i] = []
		var queue: Array[Vector3i] = [start_key]
		visited[start_key] = true
		var head := 0
		while head < queue.size():
			var current: Vector3i = queue[head]
			head += 1
			component.append(current)
			for offset in NEIGHBOR_OFFSETS:
				var neighbor: Vector3i = current + offset
				if key_set.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)

	return components


func _detach_cluster(block_keys: Array[Vector3i]) -> void:
	## Remove unsupported blocks from the structure and spawn a FallingBlockCluster.
	## Server-authoritative: server computes, then RPCs to all peers.
	if block_keys.is_empty():
		return

	var t_detach_total := Time.get_ticks_usec()

	# Compute centroid and collect per-block HP before erasing
	var t_collect := Time.get_ticks_usec()
	var centroid_local := Vector3.ZERO
	var valid_count := 0
	var valid_keys: Array[Vector3i] = []
	var block_hps: Array[float] = []

	for key in block_keys:
		if not _blocks.has(key):
			continue
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if is_instance_valid(block_body):
			centroid_local += block_body.position
			valid_count += 1
			valid_keys.append(key)
			block_hps.append(block_data["hp"])

	if valid_count == 0:
		return

	centroid_local /= float(valid_count)
	var centroid_world: Vector3 = global_transform * centroid_local
	var cluster_mass: float = valid_count * _get_block_mass()
	var t_collect_end := Time.get_ticks_usec()

	# Remove blocks from the structure (server side)
	var t_erase := Time.get_ticks_usec()
	for key in valid_keys:
		if _blocks.has(key):
			var block_data: Dictionary = _blocks[key]
			var block_body: StaticBody3D = block_data["body"]
			if is_instance_valid(block_body):
				block_body.queue_free()
			_blocks.erase(key)
			_block_grid[_grid_idx(key.x, key.y, key.z)] = 0
	var t_erase_end := Time.get_ticks_usec()

	# Rebuild visuals and smooth collision for affected columns
	var t_col_rebuild := Time.get_ticks_usec()
	_mesh_dirty = true
	set_process(true)
	var rebuilt_columns: Dictionary = {}
	var num_col_rebuilt := 0
	for key in valid_keys:
		var col_key := Vector2i(key.x, key.z)
		if not rebuilt_columns.has(col_key):
			rebuilt_columns[col_key] = true
			_rebuild_column(key.x, key.z)
			num_col_rebuilt += 1
	var t_col_rebuild_end := Time.get_ticks_usec()

	# Sync to all peers — pass per-block HP and grid info for cluster init
	var t_rpc := Time.get_ticks_usec()
	_sync_cluster_detach.rpc(valid_keys, block_hps, centroid_world, cluster_mass,
		_last_attacker_id, _num_x, _num_y, _num_z, _get_block_mass())
	var t_rpc_end := Time.get_ticks_usec()

	print("[DetachCluster] %s  blocks=%d  collect=%dus  erase=%dus  columns=%dus(%d)  rpc+spawn=%dus  total=%dus" % [
		name, valid_count,
		t_collect_end - t_collect,
		t_erase_end - t_erase,
		t_col_rebuild_end - t_col_rebuild, num_col_rebuilt,
		t_rpc_end - t_rpc,
		Time.get_ticks_usec() - t_detach_total,
	])


@rpc("authority", "call_local", "reliable")
func _sync_cluster_detach(block_keys: Array, block_hps: Array, spawn_pos: Vector3,
		cluster_mass: float, attacker_id: int, grid_num_x: int, grid_num_y: int,
		grid_num_z: int, mass_per_block: float) -> void:
	## All peers: remove detached blocks (clients only) and create the falling cluster.
	var t_sync_total := Time.get_ticks_usec()

	# Clients: remove blocks from local _blocks + rebuild mesh/collision
	var t_client_cleanup := Time.get_ticks_usec()
	if not multiplayer.is_server():
		for key_variant in block_keys:
			var key: Vector3i = key_variant
			if _blocks.has(key):
				var block_data: Dictionary = _blocks[key]
				var block_body: StaticBody3D = block_data["body"]
				if is_instance_valid(block_body):
					block_body.queue_free()
				_blocks.erase(key)
				_block_grid[_grid_idx(key.x, key.y, key.z)] = 0

		_mesh_dirty = true
		set_process(true)
		var rebuilt_columns: Dictionary = {}
		for key_variant in block_keys:
			var key: Vector3i = key_variant
			var col_key := Vector2i(key.x, key.z)
			if not rebuilt_columns.has(col_key):
				rebuilt_columns[col_key] = true
				_rebuild_column(key.x, key.z)
	var t_client_cleanup_end := Time.get_ticks_usec()

	var t_type_convert := Time.get_ticks_usec()
	var typed_keys: Array[Vector3i] = []
	var typed_hps: Array[float] = []
	for i in block_keys.size():
		typed_keys.append(block_keys[i] as Vector3i)
		typed_hps.append(float(block_hps[i]))
	var t_type_convert_end := Time.get_ticks_usec()

	var t_spawn := Time.get_ticks_usec()
	if not GameManager.debug_disable_detached_structures:
		# Default: spawn a new static structure from the detached blocks
		_spawn_detached_structure(typed_keys, typed_hps)
	var t_spawn_end := Time.get_ticks_usec()

	var sync_total := Time.get_ticks_usec() - t_sync_total
	if sync_total > 5000:
		print("[SyncClusterDetach] %s  keys=%d  client_cleanup=%dus  type_convert=%dus  spawn_structure=%dus  total=%dus" % [
			name, block_keys.size(),
			t_client_cleanup_end - t_client_cleanup,
			t_type_convert_end - t_type_convert,
			t_spawn_end - t_spawn,
			sync_total,
		])


func _spawn_detached_structure(block_keys: Array[Vector3i],
		block_hps: Array[float]) -> void:
	## Spawn a new structure instance from detached blocks (debug: no falling).
	## The new structure is the same class as self, placed at the same transform,
	## with only the given blocks populated at their current HPs.
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Build HP dictionary for init
	var hp_dict: Dictionary = {}
	for i in block_keys.size():
		hp_dict[block_keys[i]] = block_hps[i]

	# Create a new instance of the same concrete class.
	# Pass pre-computed material and block_hp so _ready() doesn't need to
	# derive them from subclass exports (which default to wrong values on
	# bare new() instances, and OBJ structures would queue_free immediately).
	var new_structure: DestructibleBlockStructure = get_script().new()
	new_structure.name = "%s_detached_%d" % [name, randi() % 10000]
	new_structure.structure_size = structure_size
	new_structure._init_from_detach = {
		"block_keys": block_keys,
		"block_hps": hp_dict,
		"block_hp": _block_hp,
		"material": _structure_material.duplicate() if _structure_material else null,
	}

	# Add under the same parent (Structures node) so explosion scans find it.
	# Set transform BEFORE add_child so _ready() creates block physics bodies
	# at the correct global positions (avoids a deferred transform update).
	var structures_node := get_parent()
	if structures_node:
		# Same parent as self → local transform is correct
		new_structure.transform = transform
		structures_node.add_child(new_structure)
	else:
		# Fallback: different parent → use global_transform after add
		scene_root.add_child(new_structure)
		new_structure.global_transform = global_transform

	# Diagnostic: print creation details + first block's global position
	var sample_block_pos := "N/A"
	if not new_structure._blocks.is_empty():
		var first_key: Vector3i = new_structure._blocks.keys()[0]
		var first_body: StaticBody3D = new_structure._blocks[first_key]["body"]
		if is_instance_valid(first_body):
			sample_block_pos = str(first_body.global_position)
	print("[SpawnDetachedStructure] name=%s  blocks=%d  parent=%s  struct_pos=%s  sample_block_pos=%s  script=%s" % [
		new_structure.name, new_structure._blocks.size(),
		new_structure.get_parent().name if new_structure.get_parent() else "null",
		str(new_structure.global_position), sample_block_pos,
		str(new_structure.get_script().resource_path)])


func _spawn_falling_cluster(block_keys: Array[Vector3i], block_hps: Array[float],
		spawn_pos: Vector3, cluster_mass: float, attacker_id: int,
		grid_num_x: int, grid_num_y: int, grid_num_z: int,
		mass_per_block: float) -> void:
	## Build and add a FallingBlockCluster from the given block keys.
	var t_spawn_total := Time.get_ticks_usec()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Compute centroid in grid-local coordinates for mesh/shape building
	var t_centroid := Time.get_ticks_usec()
	var centroid_local := Vector3.ZERO
	for key in block_keys:
		centroid_local += Vector3(
			(key.x + 0.5 - grid_num_x * 0.5) * BLOCK_SIZE,
			(key.y + 0.5 - grid_num_y * 0.5) * BLOCK_SIZE,
			(key.z + 0.5 - grid_num_z * 0.5) * BLOCK_SIZE
		)
	centroid_local /= float(block_keys.size())

	# Build per-block HP dictionary
	var block_hp_dict: Dictionary = {}
	for i in block_keys.size():
		block_hp_dict[block_keys[i]] = block_hps[i]
	var t_centroid_end := Time.get_ticks_usec()

	# Build the RigidBody3D
	var t_body := Time.get_ticks_usec()
	var cluster := RigidBody3D.new()
	cluster.set_script(FallingBlockClusterScript)
	cluster.name = "FallingCluster_%s_%d" % [name, randi() % 10000]
	cluster.mass = cluster_mass
	cluster.cluster_mass = cluster_mass
	cluster.attacker_id = attacker_id
	cluster.collision_layer = CollisionLayers.ITEMS | CollisionLayers.WALL_SMOOTH
	cluster.collision_mask = CollisionLayers.DEFAULT_PHYSICS | CollisionLayers.DEBRIS
	cluster.contact_monitor = true
	cluster.max_contacts_reported = 4
	cluster.gravity_scale = 1.0
	cluster.continuous_cd = true
	var t_body_end := Time.get_ticks_usec()

	# Build greedy mesh for the cluster
	var t_mesh := Time.get_ticks_usec()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ClusterMesh"
	mesh_inst.mesh = _build_cluster_mesh(block_keys, centroid_local)
	if _structure_material:
		mesh_inst.material_override = _structure_material.duplicate()
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	cluster.add_child(mesh_inst)
	var t_mesh_end := Time.get_ticks_usec()

	# Build per-column box collision shapes (matches structure's smooth collision)
	var t_shapes := Time.get_ticks_usec()
	_build_cluster_column_shapes(cluster, block_keys, centroid_local,
		grid_num_x, grid_num_y, grid_num_z)
	var t_shapes_end := Time.get_ticks_usec()

	# Initialize per-block tracking BEFORE adding to scene
	var t_init := Time.get_ticks_usec()
	cluster.init_cluster_blocks(block_hp_dict, grid_num_x, grid_num_y, grid_num_z,
		mass_per_block)
	var t_init_end := Time.get_ticks_usec()

	# Add under Structures node (same parent as this structure) so the
	# explosion system's scene scan finds clusters alongside regular structures.
	var t_addchild := Time.get_ticks_usec()
	var structures_node := get_parent()
	if structures_node:
		structures_node.add_child(cluster)
	else:
		scene_root.add_child(cluster)
	cluster.global_transform = Transform3D(global_transform.basis, spawn_pos)
	var t_addchild_end := Time.get_ticks_usec()

	print("[SpawnCluster] %s  blocks=%d  centroid=%dus  body=%dus  mesh=%dus  shapes=%dus  init=%dus  add_child=%dus  total=%dus" % [
		name, block_keys.size(),
		t_centroid_end - t_centroid,
		t_body_end - t_body,
		t_mesh_end - t_mesh,
		t_shapes_end - t_shapes,
		t_init_end - t_init,
		t_addchild_end - t_addchild,
		Time.get_ticks_usec() - t_spawn_total,
	])


func _build_cluster_mesh(block_keys: Array[Vector3i], centroid_local: Vector3) -> Mesh:
	## Build a greedy mesh for a set of block keys, relative to centroid_local.
	var key_set: Dictionary = {}
	for key in block_keys:
		key_set[key] = true

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bs := BLOCK_SIZE
	var hs := bs * 0.5

	for key in block_keys:
		# Block center relative to cluster centroid
		var cx: float = (key.x + 0.5 - _num_x * 0.5) * bs - centroid_local.x
		var cy: float = (key.y + 0.5 - _num_y * 0.5) * bs - centroid_local.y
		var cz: float = (key.z + 0.5 - _num_z * 0.5) * bs - centroid_local.z

		# +X face
		if not key_set.has(Vector3i(key.x + 1, key.y, key.z)):
			var n := Vector3(1, 0, 0)
			var x := cx + hs
			_add_quad_simple(st, n,
				Vector3(x, cy - hs, cz - hs), Vector3(x, cy - hs, cz + hs),
				Vector3(x, cy + hs, cz + hs), Vector3(x, cy + hs, cz - hs))

		# -X face
		if not key_set.has(Vector3i(key.x - 1, key.y, key.z)):
			var n := Vector3(-1, 0, 0)
			var x := cx - hs
			_add_quad_simple(st, n,
				Vector3(x, cy - hs, cz + hs), Vector3(x, cy - hs, cz - hs),
				Vector3(x, cy + hs, cz - hs), Vector3(x, cy + hs, cz + hs))

		# +Y face (top)
		if not key_set.has(Vector3i(key.x, key.y + 1, key.z)):
			var n := Vector3(0, 1, 0)
			var y := cy + hs
			_add_quad_simple(st, n,
				Vector3(cx - hs, y, cz - hs), Vector3(cx + hs, y, cz - hs),
				Vector3(cx + hs, y, cz + hs), Vector3(cx - hs, y, cz + hs))

		# -Y face (bottom)
		if not key_set.has(Vector3i(key.x, key.y - 1, key.z)):
			var n := Vector3(0, -1, 0)
			var y := cy - hs
			_add_quad_simple(st, n,
				Vector3(cx - hs, y, cz + hs), Vector3(cx + hs, y, cz + hs),
				Vector3(cx + hs, y, cz - hs), Vector3(cx - hs, y, cz - hs))

		# +Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z + 1)):
			var n := Vector3(0, 0, 1)
			var z := cz + hs
			_add_quad_simple(st, n,
				Vector3(cx + hs, cy - hs, z), Vector3(cx - hs, cy - hs, z),
				Vector3(cx - hs, cy + hs, z), Vector3(cx + hs, cy + hs, z))

		# -Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z - 1)):
			var n := Vector3(0, 0, -1)
			var z := cz - hs
			_add_quad_simple(st, n,
				Vector3(cx - hs, cy - hs, z), Vector3(cx + hs, cy - hs, z),
				Vector3(cx + hs, cy + hs, z), Vector3(cx - hs, cy + hs, z))

	return st.commit()


func _add_quad_simple(st: SurfaceTool, normal: Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	## Emit a quad as 2 triangles with simple UVs. Used for cluster meshes.
	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(p1)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)

	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)
	st.set_normal(normal)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(p3)


func _build_cluster_column_shapes(cluster: RigidBody3D,
		block_keys: Array[Vector3i], centroid_local: Vector3,
		num_x: int, num_y: int, num_z: int) -> void:
	## Build per-column box collision shapes for a cluster, matching the
	## structure's smooth collision approach. One BoxShape3D per contiguous
	## vertical run of blocks in each (x, z) column.
	var bs := BLOCK_SIZE

	# Group blocks by (x, z) column
	var columns: Dictionary = {}  # Vector2i -> Array[int] (sorted Y indices)
	for key in block_keys:
		var col_key := Vector2i(key.x, key.z)
		if not columns.has(col_key):
			columns[col_key] = []
		columns[col_key].append(key.y)

	for col_key: Vector2i in columns:
		var y_list: Array = columns[col_key]
		y_list.sort()

		# Find contiguous Y runs
		var run_start: int = y_list[0]
		var run_end: int = y_list[0]

		for i in range(1, y_list.size()):
			if y_list[i] == run_end + 1:
				run_end = y_list[i]
			else:
				_add_cluster_column_shape(cluster, col_key.x, col_key.y,
					run_start, run_end, centroid_local, num_x, num_y, num_z)
				run_start = y_list[i]
				run_end = y_list[i]

		# Final run
		_add_cluster_column_shape(cluster, col_key.x, col_key.y,
			run_start, run_end, centroid_local, num_x, num_y, num_z)


func _add_cluster_column_shape(cluster: RigidBody3D,
		bx: int, bz: int, by_start: int, by_end: int,
		centroid_local: Vector3, num_x: int, num_y: int, num_z: int) -> void:
	## Add a BoxShape3D for one contiguous vertical run within a cluster.
	var bs := BLOCK_SIZE
	var run_count: int = by_end - by_start + 1
	var run_height: float = run_count * bs

	var box := BoxShape3D.new()
	box.size = Vector3(bs, run_height, bs)

	var col := CollisionShape3D.new()
	col.shape = box

	# Position relative to centroid (same coordinate system as cluster mesh)
	var cx: float = (bx + 0.5 - num_x * 0.5) * bs - centroid_local.x
	var cy: float = ((by_start + by_end) * 0.5 + 0.5 - num_y * 0.5) * bs - centroid_local.y
	var cz: float = (bz + 0.5 - num_z * 0.5) * bs - centroid_local.z
	col.position = Vector3(cx, cy, cz)

	cluster.add_child(col)


# ======================================================================
#  Smooth collision — one body per structure, no seam bouncing
# ======================================================================
#
# Per-block StaticBody3D nodes are on layer 11 (1024) for weapon raycasts
# only. This single body on layer 12 (2048) handles player physics collision.
# One CollisionShape3D per contiguous vertical run of blocks. Rebuilt per-
# column when blocks are destroyed.

func _build_smooth_collision() -> void:
	## Create the smooth collision body and populate all column shapes.
	_collision_body = StaticBody3D.new()
	_collision_body.name = "SmoothCollision"
	_collision_body.collision_layer = CollisionLayers.WALL_SMOOTH
	_collision_body.collision_mask = 0
	add_child(_collision_body)

	for bx in _num_x:
		for bz in _num_z:
			_build_column_shapes(bx, bz)


func _rebuild_column(bx: int, bz: int) -> void:
	## Remove and recreate collision shapes for one (bx, bz) column.
	var col_key := Vector2i(bx, bz)
	if _col_shapes.has(col_key):
		for shape_node: CollisionShape3D in _col_shapes[col_key]:
			if is_instance_valid(shape_node):
				shape_node.queue_free()
		_col_shapes.erase(col_key)

	if _collision_body == null or not is_instance_valid(_collision_body):
		return

	_build_column_shapes(bx, bz)


func _build_column_shapes(bx: int, bz: int) -> void:
	## Scan blocks in this column, find contiguous Y runs, create shapes.
	if _collision_body == null or not is_instance_valid(_collision_body):
		return

	var col_key := Vector2i(bx, bz)
	var shapes: Array = []

	# Collect which Y indices still have blocks in this column (flat array lookup)
	var y_present: Array[int] = []
	var base_idx := bx * _num_y * _num_z + bz
	for by in _num_y:
		if _block_grid[base_idx + by * _num_z] == 1:
			y_present.append(by)

	if y_present.is_empty():
		_col_shapes[col_key] = shapes
		return

	# Find contiguous runs
	var run_start: int = y_present[0]
	var run_end: int = y_present[0]

	for i in range(1, y_present.size()):
		if y_present[i] == run_end + 1:
			run_end = y_present[i]
		else:
			# Emit shape for previous run
			_add_column_shape(shapes, bx, bz, run_start, run_end)
			run_start = y_present[i]
			run_end = y_present[i]

	# Emit final run
	_add_column_shape(shapes, bx, bz, run_start, run_end)

	_col_shapes[col_key] = shapes


func _add_column_shape(shapes: Array,
		bx: int, bz: int, by_start: int, by_end: int) -> void:
	## Add a single CollisionShape3D for a contiguous vertical run.
	var run_count: int = by_end - by_start + 1
	var run_height: float = run_count * BLOCK_SIZE

	var box := BoxShape3D.new()
	box.size = Vector3(BLOCK_SIZE, run_height, BLOCK_SIZE)

	var col := CollisionShape3D.new()
	col.shape = box

	# Position in structure local space (same coordinate system as _spawn_block)
	var cx: float = (bx + 0.5 - _num_x * 0.5) * BLOCK_SIZE
	var cy: float = ((by_start + by_end) * 0.5 + 0.5 - _num_y * 0.5) * BLOCK_SIZE
	var cz: float = (bz + 0.5 - _num_z * 0.5) * BLOCK_SIZE
	col.position = Vector3(cx, cy, cz)

	_collision_body.add_child(col)
	shapes.append(col)


# ======================================================================
#  GREEDY MESHING — single draw call per structure
# ======================================================================
#
# For each of the 6 face directions, we iterate every block. If the block
# exists and has no neighbor in that direction, we emit a quad. Each
# exposed block face = 1 quad = 2 triangles. This is still a HUGE
# improvement: 1 MeshInstance per structure instead of 1 per block.

func _rebuild_greedy_mesh() -> void:
	if _mesh_instance == null:
		return

	if _blocks.is_empty():
		_mesh_instance.mesh = null
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_x := _num_x * BLOCK_SIZE * 0.5
	var half_y := _num_y * BLOCK_SIZE * 0.5
	var half_z := _num_z * BLOCK_SIZE * 0.5
	var bs := BLOCK_SIZE

	for key: Vector3i in _blocks:
		var bx: int = key.x
		var by: int = key.y
		var bz: int = key.z

		# Block center in local space (relative to structure origin)
		var cx: float = (bx + 0.5) * bs - half_x
		var cy: float = (by + 0.5) * bs - half_y
		var cz: float = (bz + 0.5) * bs - half_z
		var hs := bs * 0.5  # half-size

		# +X face
		if not _blocks.has(Vector3i(bx + 1, by, bz)):
			var n := Vector3(1, 0, 0)
			var x := cx + hs
			_add_quad(st, n,
				Vector3(x, cy - hs, cz - hs),
				Vector3(x, cy - hs, cz + hs),
				Vector3(x, cy + hs, cz + hs),
				Vector3(x, cy + hs, cz - hs))

		# -X face
		if not _blocks.has(Vector3i(bx - 1, by, bz)):
			var n := Vector3(-1, 0, 0)
			var x := cx - hs
			_add_quad(st, n,
				Vector3(x, cy - hs, cz + hs),
				Vector3(x, cy - hs, cz - hs),
				Vector3(x, cy + hs, cz - hs),
				Vector3(x, cy + hs, cz + hs))

		# +Y face (top)
		if not _blocks.has(Vector3i(bx, by + 1, bz)):
			var n := Vector3(0, 1, 0)
			var y := cy + hs
			_add_quad(st, n,
				Vector3(cx - hs, y, cz - hs),
				Vector3(cx + hs, y, cz - hs),
				Vector3(cx + hs, y, cz + hs),
				Vector3(cx - hs, y, cz + hs))

		# -Y face (bottom)
		if not _blocks.has(Vector3i(bx, by - 1, bz)):
			var n := Vector3(0, -1, 0)
			var y := cy - hs
			_add_quad(st, n,
				Vector3(cx - hs, y, cz + hs),
				Vector3(cx + hs, y, cz + hs),
				Vector3(cx + hs, y, cz - hs),
				Vector3(cx - hs, y, cz - hs))

		# +Z face
		if not _blocks.has(Vector3i(bx, by, bz + 1)):
			var n := Vector3(0, 0, 1)
			var z := cz + hs
			_add_quad(st, n,
				Vector3(cx + hs, cy - hs, z),
				Vector3(cx - hs, cy - hs, z),
				Vector3(cx - hs, cy + hs, z),
				Vector3(cx + hs, cy + hs, z))

		# -Z face
		if not _blocks.has(Vector3i(bx, by, bz - 1)):
			var n := Vector3(0, 0, -1)
			var z := cz - hs
			_add_quad(st, n,
				Vector3(cx - hs, cy - hs, z),
				Vector3(cx + hs, cy - hs, z),
				Vector3(cx + hs, cy + hs, z),
				Vector3(cx - hs, cy + hs, z))

	_mesh_instance.mesh = st.commit()


func _add_quad(st: SurfaceTool, normal: Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	## Emit a quad as 2 triangles. Winding is CCW: p0->p1->p2, p0->p2->p3.
	var uvs := _compute_quad_uvs(normal, p0, p1, p2, p3)
	st.set_normal(normal)
	st.set_uv(uvs[0])
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(uvs[1])
	st.add_vertex(p1)
	st.set_normal(normal)
	st.set_uv(uvs[2])
	st.add_vertex(p2)

	st.set_normal(normal)
	st.set_uv(uvs[0])
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(uvs[2])
	st.add_vertex(p2)
	st.set_normal(normal)
	st.set_uv(uvs[3])
	st.add_vertex(p3)
