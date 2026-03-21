extends Node3D
class_name DestructibleBlockStructure

## Base class for destructible block-grid structures (walls, ramps, etc.).
## Manages a grid of blocks with compound hit body for weapon targeting,
## greedy meshing for visuals, AoE/hitscan damage with flat HP shielding,
## debris spawning, and RPC sync.
##
## Subclasses override _get_tier_info() and _get_debris_config() to provide
## their specific tier data and debris parameters.
##
## Server-authoritative: only the server tracks block health and spawns debris.
##
## GREEDY MESHING: one MeshInstance3D for the entire structure. When blocks are
## destroyed the mesh rebuilds. This reduces draw calls from N_blocks to 1.
##
## COMPOUND HIT BODY: one StaticBody3D (layer 11) with N shapes via
## PhysicsServer3D. Weapon raycasts hit individual shapes, routed to blocks
## via shape_index → grid_key mapping (compound_hit_body.gd script).

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

## Block HP: Dictionary[Vector3i → float]
var _block_hp_dict: Dictionary = {}
var _num_x: int = 0
var _num_y: int = 0
var _num_z: int = 0

## Flat occupancy grid: 1 = block exists, 0 = empty. Indexed via _grid_idx().
## Avoids Dictionary hashing in BFS inner loops (~20x faster than Dictionary.has()).
var _block_grid: PackedByteArray = PackedByteArray()
var _ground_mask: PackedByteArray = PackedByteArray()  ## 1 = terrain-contacting (anchor)
var _block_hp: float = 35.0
var _structure_material: StandardMaterial3D = null

## Shared resources (created once, reused by all blocks)
var _block_shape: BoxShape3D = null

## Compound hit body — one StaticBody3D with N shapes (layer 11 WALL_BLOCKS).
## Weapon raycasts hit individual shapes; shape_index → grid_key mapping
## routes damage to the correct block via compound_hit_body.gd script.
var _compound_hit_body: StaticBody3D = null
var _shape_to_key: Array[Vector3i] = []   ## shape_index → grid_key
var _key_to_shape: Dictionary = {}        ## Vector3i → shape_index
var _compound_body_script: GDScript = preload("res://world/compound_hit_body.gd")

## Greedy mesh — single MeshInstance3D for the entire structure
var _mesh_instance: MeshInstance3D = null
var _foundation_mesh_instance: MeshInstance3D = null  ## Separate stone-colored mesh for foundation
var _mesh_dirty: bool = false
var _integrity_check_pending: bool = false
var _foundation_pending: bool = false

## Smooth collision — single StaticBody3D for player physics (layer 12, bit 2048).
## Compound hit body handles weapon raycasts on layer 11 (bit 1024).
## This eliminates seam bouncing when the player slides along the wall.
var _collision_body: StaticBody3D = null

## Temporary storage for hit bodies being reparented to a falling cluster.
## Populated by _detach_clusters(), consumed by _sync_cluster_detach() (call_local).
## Smooth collision mesh shape RID (ConcavePolygonShape3D / trimesh).
## Jolt's MeshShape has internal edge smoothing — eliminates ghost collisions
## at block boundaries that compound box shapes suffer from.
var _smooth_shape_rid: RID = RID()

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


const FOUNDATION_HP := 35.0  ## Stone-tier HP for foundation blocks

## Grid marking foundation blocks (1 = foundation). Same indexing as _block_grid.
## Used by _deferred_build_foundation to build a separate stone-colored mesh.
var _foundation_grid: PackedByteArray = PackedByteArray()

func _build_foundation() -> void:
	## Raycast downward from the lowest block in each column to find terrain,
	## then extend the grid downward so foundation blocks reach into terrain.
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		print("[Foundation] %s  SKIP: no space_state" % name)
		return

	# For each (bx, bz) column, find the lowest occupied block and raycast down.
	var max_extra_rows := 0
	var column_depths: PackedInt32Array = PackedInt32Array()
	var column_lowest_y: PackedInt32Array = PackedInt32Array()  # lowest occupied y per column
	column_depths.resize(_num_x * _num_z)
	column_lowest_y.resize(_num_x * _num_z)
	column_depths.fill(0)
	column_lowest_y.fill(-1)

	var ray_count := 0
	var hit_count := 0

	for bx in _num_x:
		for bz in _num_z:
			# Find lowest occupied block in this column
			var lowest_y := -1
			for by in _num_y:
				if _block_grid[_grid_idx(bx, by, bz)]:
					lowest_y = by
					break
			if lowest_y < 0:
				continue
			column_lowest_y[bx * _num_z + bz] = lowest_y

			# World position of the bottom face of the lowest block
			var local_pos := _block_local_pos(Vector3i(bx, lowest_y, bz))
			var world_pos: Vector3 = global_transform * (local_pos - Vector3(0, BLOCK_SIZE * 0.5, 0))

			var query := PhysicsRayQueryParameters3D.new()
			query.from = world_pos + Vector3(0, 0.01, 0)
			query.to = world_pos - Vector3(0, 20.0, 0)
			query.collision_mask = CollisionLayers.WORLD
			ray_count += 1

			var result := space_state.intersect_ray(query)
			if result:
				hit_count += 1
				var hit_y: float = result["position"].y
				var gap: float = world_pos.y - hit_y
				var rows: int = ceili(gap / BLOCK_SIZE) + 1
				if rows > 0:
					column_depths[bx * _num_z + bz] = rows
					max_extra_rows = maxi(max_extra_rows, rows)

	print("[Foundation] %s  rays=%d  hits=%d  max_extra=%d  pos=%s" % [
		name, ray_count, hit_count, max_extra_rows, str(global_position)])

	if max_extra_rows == 0:
		return

	# Expand the grid: shift all existing blocks up by max_extra_rows.
	var old_num_y := _num_y
	_num_y += max_extra_rows
	var new_grid_size := _num_x * _num_y * _num_z
	var new_grid := PackedByteArray()
	new_grid.resize(new_grid_size)
	new_grid.fill(0)
	_foundation_grid.resize(new_grid_size)
	_foundation_grid.fill(0)

	# Copy existing blocks shifted up
	var new_hp_dict: Dictionary = {}
	for key: Vector3i in _block_hp_dict:
		var new_key := Vector3i(key.x, key.y + max_extra_rows, key.z)
		new_hp_dict[new_key] = _block_hp_dict[key]
		new_grid[_grid_idx_raw(new_key.x, new_key.y, new_key.z, _num_y, _num_z)] = 1

	# Fill foundation columns: from y=0 up to (max_extra_rows + lowest_y - 1)
	# so foundation connects to the lowest existing block in each column.
	var foundation_count := 0
	for bx in _num_x:
		for bz in _num_z:
			var ci := bx * _num_z + bz
			var depth: int = column_depths[ci]
			var lowest_y: int = column_lowest_y[ci]
			if lowest_y < 0:
				continue  # no blocks in this column
			# Fill from y=0 up to (max_extra_rows + lowest_y - 1) in new grid coords.
			# The old lowest_y shifted up becomes (lowest_y + max_extra_rows).
			# Foundation fills from y=0 to (lowest_y + max_extra_rows - 1).
			var fill_top: int = lowest_y + max_extra_rows  # exclusive
			if depth <= 0:
				# No raycast hit — fill full depth if column had blocks
				fill_top = maxi(fill_top, max_extra_rows)
			for by in fill_top:
				var idx := _grid_idx_raw(bx, by, bz, _num_y, _num_z)
				if not new_grid[idx]:  # don't overwrite existing blocks
					new_hp_dict[Vector3i(bx, by, bz)] = FOUNDATION_HP
					new_grid[idx] = 1
					_foundation_grid[idx] = 1
					foundation_count += 1

	_block_hp_dict = new_hp_dict
	_block_grid = new_grid

	# Build ground mask: lowest occupied block per column is the terrain anchor.
	_ground_mask.resize(new_grid_size)
	_ground_mask.fill(0)
	for bx in _num_x:
		for bz in _num_z:
			for by in _num_y:
				if new_grid[_grid_idx_raw(bx, by, bz, _num_y, _num_z)]:
					_ground_mask[_grid_idx_raw(bx, by, bz, _num_y, _num_z)] = 1
					break

	# Shift structure down to keep original blocks at the same world position.
	global_position.y -= max_extra_rows * BLOCK_SIZE * 0.5

	print("[Foundation] %s  extra_rows=%d  new_num_y=%d  foundation_blocks=%d  total_blocks=%d  shift=%.2f" % [
		name, max_extra_rows, _num_y, foundation_count, _block_hp_dict.size(),
		max_extra_rows * BLOCK_SIZE * 0.5])


static func _grid_idx_raw(bx: int, by: int, bz: int, num_y: int, num_z: int) -> int:
	return bx * num_y * num_z + by * num_z + bz


func _build_ground_mask() -> void:
	## Raycast down from the bottom block of each column to check terrain contact.
	## Blocks whose bottom face is within half a BLOCK_SIZE of terrain are grounded.
	_ground_mask.resize(_num_x * _num_y * _num_z)
	_ground_mask.fill(0)

	if not is_inside_tree():
		return
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	var grounded := 0
	for bx in _num_x:
		for bz in _num_z:
			# Find lowest occupied block in this column
			for by in _num_y:
				var idx := _grid_idx(bx, by, bz)
				if not _block_grid[idx]:
					continue
				# Raycast from bottom face of this block
				var local_pos := _block_local_pos(Vector3i(bx, by, bz))
				var bottom_world: Vector3 = global_transform * (local_pos - Vector3(0, BLOCK_SIZE * 0.5, 0))
				var query := PhysicsRayQueryParameters3D.new()
				query.from = bottom_world + Vector3(0, 0.01, 0)
				query.to = bottom_world - Vector3(0, BLOCK_SIZE, 0)
				query.collision_mask = CollisionLayers.WORLD
				var result := space_state.intersect_ray(query)
				if result:
					_ground_mask[idx] = 1
					grounded += 1
				break  # only check lowest block per column

	if grounded > 0:
		print("[GroundMask] %s  grounded=%d/%d columns" % [name, grounded, _num_x * _num_z])


static var _foundation_material: StandardMaterial3D

func _deferred_build_foundation() -> void:
	## Called after first physics step so terrain collision is available.
	## Builds foundation, ground mask, and rebuilds mesh/collision/hitbody.
	var _t_foundation_total := Time.get_ticks_usec()
	var old_num_y := _num_y
	var _t_build := Time.get_ticks_usec()
	_build_foundation()
	var _t_build_us := Time.get_ticks_usec() - _t_build

	# If foundation didn't expand, just compute ground mask from raycasts.
	if _num_y == old_num_y:
		var _t_gm := Time.get_ticks_usec()
		_build_ground_mask()
		var _t_gm_us := Time.get_ticks_usec() - _t_gm
		var _t_foundation_us := Time.get_ticks_usec() - _t_foundation_total
		print("[PERF] _deferred_build_foundation %s (no expand): build=%dus ground_mask=%dus total=%dus" % [
			name, _t_build_us, _t_gm_us, _t_foundation_us])
		return

	# Grid expanded — rebuild everything.
	# Build structure-only grid (exclude foundation blocks) for the main mesh.
	var _t_mesh_rebuild := Time.get_ticks_usec()
	var struct_grid := PackedByteArray()
	struct_grid.resize(_block_grid.size())
	for i in _block_grid.size():
		struct_grid[i] = _block_grid[i] if not _foundation_grid[i] else 0

	# Rebuild main mesh (structure blocks only, keeps original material)
	if _mesh_instance:
		_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
			struct_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
	var _t_mesh_rebuild_us := Time.get_ticks_usec() - _t_mesh_rebuild

	# Build foundation mesh (stone color)
	var _t_foundation_mesh := Time.get_ticks_usec()
	if _foundation_material == null:
		_foundation_material = StandardMaterial3D.new()
		_foundation_material.albedo_color = Color(0.55, 0.55, 0.50)  # Stone color
	if _foundation_mesh_instance == null:
		_foundation_mesh_instance = MeshInstance3D.new()
		_foundation_mesh_instance.name = "FoundationMesh"
		_foundation_mesh_instance.material_override = _foundation_material
		_foundation_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(_foundation_mesh_instance)
	_foundation_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
		_foundation_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
	var _t_foundation_mesh_us := Time.get_ticks_usec() - _t_foundation_mesh

	# Rebuild collision from full grid (both structure + foundation)
	var _t_col_rebuild := Time.get_ticks_usec()
	_cached_faces = PackedVector3Array()
	_rebuild_smooth_collision_mesh()
	var _t_col_rebuild_us := Time.get_ticks_usec() - _t_col_rebuild

	# Rebuild compound hit body with all block positions
	var _t_hitbody := Time.get_ticks_usec()
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		_compound_hit_body.queue_free()
	_compound_hit_body = StaticBody3D.new()
	_compound_hit_body.set_script(_compound_body_script)
	_compound_hit_body.name = "CompoundHitBody"
	_compound_hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
	_compound_hit_body.collision_mask = 0
	_compound_hit_body.parent_wall = self

	var positions := PackedVector3Array()
	_shape_to_key.clear()
	_key_to_shape.clear()
	positions.resize(_block_hp_dict.size())
	_shape_to_key.resize(_block_hp_dict.size())
	var idx := 0
	for key: Vector3i in _block_hp_dict:
		positions[idx] = _block_local_pos(key)
		_shape_to_key[idx] = key
		_key_to_shape[key] = idx
		idx += 1
	BlockMeshBuilder.bulk_add_shapes(
		_compound_hit_body.get_rid(), _block_shape.get_rid(), positions)
	_compound_hit_body._shape_to_key = _shape_to_key
	add_child(_compound_hit_body)
	PhysicsServer3D.body_set_shielding_tag(_compound_hit_body.get_rid(), 1)
	_update_compound_shielding_hp()
	var _t_hitbody_us := Time.get_ticks_usec() - _t_hitbody

	var _t_foundation_us := Time.get_ticks_usec() - _t_foundation_total
	print("[PERF] _deferred_build_foundation %s (expanded): build=%dus mesh=%dus foundation_mesh=%dus collision=%dus hitbody=%dus total=%dus blocks=%d" % [
		name, _t_build_us, _t_mesh_rebuild_us, _t_foundation_mesh_us, _t_col_rebuild_us, _t_hitbody_us, _t_foundation_us, _block_hp_dict.size()])


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


func _clear_block_grids(bx: int, by: int, bz: int) -> void:
	## Clear occupancy, ground mask, and foundation grid at (bx, by, bz).
	var idx := _grid_idx(bx, by, bz)
	_block_grid[idx] = 0
	if idx < _ground_mask.size():
		_ground_mask[idx] = 0
	if idx < _foundation_grid.size():
		_foundation_grid[idx] = 0


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
	_ground_mask.resize(_num_x * _num_y * _num_z)
	_ground_mask.fill(0)

	# Build block HP dict and flat occupancy grid
	var t_blocks := Time.get_ticks_usec()
	if is_detach:
		# Detached structure: populate only the provided blocks with their HPs
		var detach_keys: Array = _init_from_detach["block_keys"]
		var detach_hps: Dictionary = _init_from_detach["block_hps"]
		for key: Vector3i in detach_keys:
			var hp: float = detach_hps.get(key, _block_hp)
			_block_hp_dict[key] = hp
			_block_grid[_grid_idx(key.x, key.y, key.z)] = 1
		_init_from_detach = {}  # Clear to free references
	else:
		for bx in _num_x:
			for by in _num_y:
				for bz in _num_z:
					if _should_spawn_block(bx, by, bz):
						_block_hp_dict[Vector3i(bx, by, bz)] = _block_hp
						_block_grid[_grid_idx(bx, by, bz)] = 1
		# Foundation and ground mask need terrain collision for raycasting.
		# Wait until after the first physics step so Jolt has flushed shapes.
		if not is_detach:
			_foundation_pending = true

	# Build compound hit body (one StaticBody3D with N shapes, layer 11).
	_compound_hit_body = StaticBody3D.new()
	_compound_hit_body.set_script(_compound_body_script)
	_compound_hit_body.name = "CompoundHitBody"
	_compound_hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
	_compound_hit_body.collision_mask = 0
	_compound_hit_body.parent_wall = self

	# Add all block shapes in one C++ call (bulk_add_shapes).
	var positions := PackedVector3Array()
	_shape_to_key.clear()
	positions.resize(_block_hp_dict.size())
	_shape_to_key.resize(_block_hp_dict.size())
	var idx := 0
	for key: Vector3i in _block_hp_dict:
		positions[idx] = _block_local_pos(key)
		_shape_to_key[idx] = key
		_key_to_shape[key] = idx
		idx += 1
	BlockMeshBuilder.bulk_add_shapes(
		_compound_hit_body.get_rid(), _block_shape.get_rid(), positions)
	_compound_hit_body._shape_to_key = _shape_to_key
	add_child(_compound_hit_body)

	# Tag for C++ shielding classification (tag 1 = WALL_BLOCK, average HP).
	PhysicsServer3D.body_set_shielding_tag(_compound_hit_body.get_rid(), 1)
	_update_compound_shielding_hp()

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
			name, _block_hp_dict.size(),
			t_blocks_end - t_blocks,
			t_mesh_end - t_mesh,
			t_smooth_end - t_smooth,
			ready_total,
			"  (detach)" if is_detach else "",
		])

	# Detached structures: compute bottom-center for ground raycast and start falling
	if is_detach and not _block_hp_dict.is_empty():
		_is_falling = true
		var sum_x := 0.0
		var sum_z := 0.0
		var min_y := INF
		for key: Vector3i in _block_hp_dict:
			var pos := _block_local_pos(key)
			sum_x += pos.x
			sum_z += pos.z
			var bottom_y := pos.y - BLOCK_SIZE * 0.5
			if bottom_y < min_y:
				min_y = bottom_y
		var count := float(_block_hp_dict.size())
		_fall_ray_local = Vector3(sum_x / count, min_y, sum_z / count)

	set_physics_process(_is_falling or _foundation_pending)

	# Disable per-frame processing — only needed when _mesh_dirty is set
	set_process(false)


func _exit_tree() -> void:
	if _smooth_shape_rid.is_valid():
		PhysicsServer3D.free_rid(_smooth_shape_rid)
		_smooth_shape_rid = RID()


func _process(_delta: float) -> void:
	Profiler.begin("destructible_mesh")
	# Deferred mesh rebuild: blocks were destroyed, rebuild once then sleep
	if _mesh_dirty:
		_mesh_dirty = false
		var t_mesh := Time.get_ticks_usec()
		_rebuild_greedy_mesh()
		var t_mesh_end := Time.get_ticks_usec()
		var _mesh_us := t_mesh_end - t_mesh
		print("[GreedyMesh] %s  blocks=%d  time=%dus" % [name, _block_hp_dict.size(), _mesh_us])
		GameManager.frame_add("greedy_mesh", _mesh_us)
		set_process(false)
	Profiler.end("destructible_mesh")


const DETACH_FALL_GRAVITY := 17.5  ## Same as player gravity (m/s²)

func _physics_process(delta: float) -> void:
	Profiler.begin("destructible_physics")
	if _foundation_pending:
		_foundation_pending = false
		_deferred_build_foundation()
		if not _is_falling:
			set_physics_process(false)
			Profiler.end("destructible_physics")
			return
	if not _is_falling:
		set_physics_process(false)
		Profiler.end("destructible_physics")
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
			_clear_physics_before_free()
			queue_free()
	Profiler.end("destructible_physics")


func _clear_physics_before_free() -> void:
	## Zero collision layers on both collision bodies so Jolt drops them from
	## the broadphase immediately. Prevents phantom collisions (e.g. rockets
	## hitting a stale body) during the queue_free() deferral window.
	if _collision_body and is_instance_valid(_collision_body):
		_collision_body.collision_layer = 0
		_collision_body.collision_mask = 0
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		_compound_hit_body.collision_layer = 0


# ======================================================================
#  Debug visualization — hit block wireframe
# ======================================================================

static var _debug_hit_mat: StandardMaterial3D
static var _debug_miss_mat: StandardMaterial3D
static var _debug_hitbox_mat: StandardMaterial3D

static func _get_debug_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

static func debug_draw_block_hit(scene_root: Node, world_pos: Vector3, block_size: float,
		hit: bool, label: String = "") -> void:
	## Draw a wireframe cube at world_pos. Green = hit, red = miss. Fades after 2s.
	if not GameManager.debug_show_block_hits:
		return
	if _debug_hit_mat == null:
		_debug_hit_mat = _get_debug_mat(Color(0, 1, 0, 0.6))
		_debug_miss_mat = _get_debug_mat(Color(1, 0, 0, 0.6))
		_debug_hitbox_mat = _get_debug_mat(Color(1, 1, 0, 0.25))

	var hs := block_size * 0.5

	# Wireframe box
	var lines := PackedVector3Array()
	var corners: Array[Vector3] = [
		Vector3(-hs, -hs, -hs), Vector3( hs, -hs, -hs),
		Vector3( hs,  hs, -hs), Vector3(-hs,  hs, -hs),
		Vector3(-hs, -hs,  hs), Vector3( hs, -hs,  hs),
		Vector3( hs,  hs,  hs), Vector3(-hs,  hs,  hs),
	]
	var edges: Array[int] = [0,1, 1,2, 2,3, 3,0, 4,5, 5,6, 6,7, 7,4, 0,4, 1,5, 2,6, 3,7]
	lines.resize(edges.size())
	for i in edges.size():
		lines[i] = corners[edges[i]]

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = _debug_hit_mat if hit else _debug_miss_mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.global_position = world_pos
	scene_root.add_child(inst)

	# Also draw a small solid cube for visibility
	var solid := BoxMesh.new()
	solid.size = Vector3.ONE * block_size * 0.3
	var solid_inst := MeshInstance3D.new()
	solid_inst.mesh = solid
	solid_inst.material_override = _debug_hit_mat if hit else _debug_miss_mat
	solid_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	solid_inst.global_position = world_pos
	scene_root.add_child(solid_inst)

	if label != "":
		print("[BLOCK_HIT] %s  pos=%s  hit=%s" % [label, str(world_pos), str(hit)])

	# Auto-remove after 2 seconds
	var tree := scene_root.get_tree()
	if tree:
		tree.create_timer(2.0).timeout.connect(func():
			if is_instance_valid(inst): inst.queue_free()
			if is_instance_valid(solid_inst): solid_inst.queue_free()
		)


# ======================================================================
#  Block management — helpers
# ======================================================================

func _block_local_pos(key: Vector3i) -> Vector3:
	## Compute block position in structure-local space from grid coordinates.
	return Vector3(
		(key.x + 0.5 - _num_x * 0.5) * BLOCK_SIZE,
		(key.y + 0.5 - _num_y * 0.5) * BLOCK_SIZE,
		(key.z + 0.5 - _num_z * 0.5) * BLOCK_SIZE
	)


func _disable_hit_shape(key: Vector3i) -> void:
	## Disable the compound body shape for a destroyed/removed block.
	if not _key_to_shape.has(key):
		return
	var shape_idx: int = _key_to_shape[key]
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shape_disabled(
			_compound_hit_body.get_rid(), shape_idx, true)
	_key_to_shape.erase(key)


func _update_compound_shielding_hp() -> void:
	## Update the compound body's cached shielding HP (average of all blocks).
	if not (_compound_hit_body and is_instance_valid(_compound_hit_body)):
		return
	var count := _block_hp_dict.size()
	var total := 0.0
	for hp: float in _block_hp_dict.values():
		total += hp
	var avg := total / maxf(float(count), 1.0) if count > 0 else 0.0
	PhysicsServer3D.body_set_shielding_hp(_compound_hit_body.get_rid(), avg)


# ======================================================================
#  Damage
# ======================================================================

func take_damage(_amount: float, _attacker_id: int) -> void:
	## No-op: structure-level take_damage exists so explosion scans find us.
	## Actual damage goes through take_damage_at() (explosions) or
	## _damage_block() (hitscan bullets hitting individual blocks).
	pass


func _damage_block(key: Vector3i, amount: float, _attacker_id: int) -> void:
	## Called by compound_hit_body.gd when a bullet hits a specific block shape.
	if not multiplayer.is_server():
		return
	if not _block_hp_dict.has(key):
		return

	Profiler.begin("struct_damage_block")
	var t_dmg_total := Time.get_ticks_usec()
	_last_attacker_id = _attacker_id
	_block_hp_dict[key] -= amount
	_update_compound_shielding_hp()
	if _block_hp_dict[key] <= 0.0:
		var block_pos: Vector3 = global_transform * _block_local_pos(key)
		var debris_count := randi_range(1, 2)
		var ok_frac := clampf(-_block_hp_dict[key] / _block_hp, 0.0, 1.0)

		# Use the attacker's position as the blast origin so debris flies away
		# from the shooter. Falls back to a random offset if attacker not found.
		var blast_origin := block_pos + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized() * 0.5
		var players_node := get_tree().current_scene.get_node_or_null("Players")
		if players_node and _attacker_id >= 0:
			var attacker := players_node.get_node_or_null(str(_attacker_id))
			if attacker and is_instance_valid(attacker):
				blast_origin = attacker.global_position

		# Server: destroy block, sync to clients. Debris spawns on all peers via RPC.
		var t_disable := Time.get_ticks_usec()
		_disable_hit_shape(key)
		_block_hp_dict.erase(key)
		_clear_block_grids(key.x, key.y, key.z)
		var t_disable_us := Time.get_ticks_usec() - t_disable
		_mesh_dirty = true
		set_process(true)  # Wake up _process to rebuild mesh next frame
		_cached_faces = PackedVector3Array()
		var t_col := Time.get_ticks_usec()
		_rebuild_smooth_collision_mesh()
		var t_col_us := Time.get_ticks_usec() - t_col
		var spd := DebrisHelper.calc_hitscan_speed(ok_frac)
		var t_rpc := Time.get_ticks_usec()
		_sync_block_destroyed.rpc(key, block_pos, blast_origin, debris_count, spd)
		var t_rpc_us := Time.get_ticks_usec() - t_rpc

		# Host also spawns debris locally (RPC is call_remote, host needs it too).
		var t_debris := Time.get_ticks_usec()
		_spawn_debris(block_pos, blast_origin, debris_count, spd)
		var t_debris_us := Time.get_ticks_usec() - t_debris

		var dmg_us := Time.get_ticks_usec() - t_dmg_total
		print("[PERF] _damage_block %s key=%s: disable=%dus smooth_col=%dus rpc=%dus debris=%dus total=%dus blocks=%d" % [
			name, str(key), t_disable_us, t_col_us, t_rpc_us, t_debris_us, dmg_us, _block_hp_dict.size()])
		GameManager.tick_add("damage_block", dmg_us)

		Profiler.end("struct_damage_block")
		# Defer structural integrity check to end of frame so multi-pellet
		# damage (shotgun) applies all hits before checking for detachment.
		if not _integrity_check_pending:
			_integrity_check_pending = true
			call_deferred("_deferred_integrity_check")
		return
	Profiler.end("struct_damage_block")


@rpc("authority", "call_remote", "reliable")
func _sync_block_destroyed(key: Vector3i, block_pos: Vector3 = Vector3.ZERO,
		blast_center: Vector3 = Vector3.ZERO, debris_count: int = 0,
		debris_speed: float = 8.0) -> void:
	## Client-side: remove a destroyed block, rebuild mesh, and spawn cosmetic debris.
	var _t_sync := Time.get_ticks_usec()
	if _block_hp_dict.has(key):
		_disable_hit_shape(key)
		_block_hp_dict.erase(key)
		_clear_block_grids(key.x, key.y, key.z)
		_mesh_dirty = true
		set_process(true)
		_cached_faces = PackedVector3Array()
		var _t_col := Time.get_ticks_usec()
		_rebuild_smooth_collision_mesh()
		var _t_col_us := Time.get_ticks_usec() - _t_col

	# Spawn cosmetic debris on the client.
	var _t_debris := Time.get_ticks_usec()
	if debris_count > 0:
		_spawn_debris(block_pos, blast_center, debris_count, debris_speed)
	var _t_debris_us := Time.get_ticks_usec() - _t_debris
	var _t_sync_us := Time.get_ticks_usec() - _t_sync
	if _t_sync_us > 200:
		print("[PERF] _sync_block_destroyed(client) %s key=%s: total=%dus blocks=%d" % [
			name, str(key), _t_sync_us, _block_hp_dict.size()])


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float, _attacker_id: int, exclude_rids: Array[RID] = [], impact_speed: float = INF) -> void:
	## Damage blocks within blast_radius of hit_pos. Only blocks in range take damage.
	## Shielding uses flat HP absorption: each wall block or player between the
	## explosion and a target block absorbs damage equal to its current HP.
	## exclude_rids: physics bodies to ignore in shielding raycasts (e.g. the rocket).
	print("[TakeDamageAt-ENTRY] %s  blocks=%d  is_server=%s  hit_pos=%s  global_pos=%s" % [
		name, _block_hp_dict.size(), str(multiplayer.is_server()), str(hit_pos), str(global_position)])
	if not multiplayer.is_server():
		return

	Profiler.begin("struct_take_damage_at")
	_last_attacker_id = _attacker_id
	var t_total := Time.get_ticks_usec()

	var space_state := get_world_3d().direct_space_state
	var debug_rays := GameManager.debug_show_explosion_rays

	var destroyed_keys: Array[Vector3i] = []
	var destroyed_positions: Array[Vector3] = []
	var destroyed_overkill: Array[float] = []
	var debug_ray_data: Array = []

	# C++ computes damage, shielding, applies HP, and returns destroyed/survived info.
	var explosion_result: Dictionary = {}

	var t_pass1 := Time.get_ticks_usec()
	var t_query_setup := Time.get_ticks_usec()
	var query: PhysicsRayQueryParameters3D = null
	if space_state:
		query = ExplosionHelper._make_shielding_query(hit_pos, exclude_rids)
	var t_query_setup_end := Time.get_ticks_usec()
	var t_calc_explosion := Time.get_ticks_usec()
	if space_state:
		var compound_rid := _compound_hit_body.get_rid() if (_compound_hit_body and is_instance_valid(_compound_hit_body)) else RID()
		var repeat_count := 2000 if GameManager.debug_explosion_repeat else 1
		for _i in repeat_count:
			explosion_result = space_state.calc_structure_explosion(
				query, _block_hp_dict, _block_grid, global_transform, BLOCK_SIZE,
				_num_x, _num_y, _num_z, blast_radius, amount, _block_hp,
				compound_rid
			)
	var t_calc_explosion_end := Time.get_ticks_usec()

	# Unpack C++ results.
	if not explosion_result.is_empty():
		destroyed_keys.assign(explosion_result["destroyed_keys"])
		destroyed_positions.assign(explosion_result["destroyed_positions"])
		destroyed_overkill.assign(explosion_result["destroyed_overkill"])

		# Update survived blocks — HP only (compound body shielding HP updated once below).
		var s_keys: Array = explosion_result["survived_keys"]
		var s_hps: PackedFloat32Array = explosion_result["survived_hps"]
		for i in s_keys.size():
			_block_hp_dict[s_keys[i]] = s_hps[i]
		_update_compound_shielding_hp()
	var t_pass1_end := Time.get_ticks_usec()

	# Erase destroyed blocks — disable compound body shapes (instant vs queue_free).
	var t_erase := Time.get_ticks_usec()
	if destroyed_keys.size() > 0 and _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
	for i in destroyed_keys.size():
		var key: Vector3i = destroyed_keys[i]
		_disable_hit_shape(key)
		_block_hp_dict.erase(key)
		_clear_block_grids(key.x, key.y, key.z)
	if destroyed_keys.size() > 0 and _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
	var t_erase_end := Time.get_ticks_usec()

	# Draw debug rays if toggled on
	var t_debug := Time.get_ticks_usec()
	if debug_rays and not debug_ray_data.is_empty():
		ExplosionHelper.draw_debug_rays(debug_ray_data)
	var t_debug_end := Time.get_ticks_usec()

	# Sync destroyed blocks to clients and spawn debris.
	# Debris speed uses the same cubic falloff as damage — blocks near the blast
	# center produce fast debris, blocks at the edge produce slow debris.
	var t_debris := Time.get_ticks_usec()
	var rpc_count := 0
	var debris_spawn_count := 0
	var t_debris_rpcs := Time.get_ticks_usec()
	for i in destroyed_keys.size():
		var key := destroyed_keys[i]
		var block_pos := destroyed_positions[i]
		var ok_frac := destroyed_overkill[i]
		var norm_dist := hit_pos.distance_to(block_pos) / blast_radius
		var spd := DebrisHelper.calc_explosion_speed(norm_dist, ok_frac)
		var to_spawn := randi_range(1, _debris_per_block)
		var debris_origin := block_pos + (block_pos - hit_pos)
		_sync_block_destroyed.rpc(key, block_pos, debris_origin, to_spawn, spd)
		rpc_count += 1
	var t_debris_rpcs_end := Time.get_ticks_usec()
	var t_debris_spawn := Time.get_ticks_usec()
	# Batch debris spawn — build arrays and do one C++ call instead of per-block loop.
	var n_destroyed := destroyed_keys.size()
	if n_destroyed > 0:
		var batch_positions := PackedVector3Array()
		var batch_centers := PackedVector3Array()
		var batch_counts := PackedInt32Array()
		var batch_speeds := PackedFloat32Array()
		batch_positions.resize(n_destroyed)
		batch_centers.resize(n_destroyed)
		batch_counts.resize(n_destroyed)
		batch_speeds.resize(n_destroyed)
		for i in n_destroyed:
			var block_pos := destroyed_positions[i]
			var ok_frac := destroyed_overkill[i]
			var norm_dist := hit_pos.distance_to(block_pos) / blast_radius
			batch_positions[i] = block_pos
			batch_centers[i] = block_pos + (block_pos - hit_pos)
			batch_counts[i] = randi_range(1, _debris_per_block)
			batch_speeds[i] = DebrisHelper.calc_explosion_speed(norm_dist, ok_frac)
			debris_spawn_count += batch_counts[i]
		DebrisHelper.spawn_debris_batch(
			batch_positions, batch_centers, batch_counts, batch_speeds,
			_structure_material,
			{"lifetime": _debris_lifetime, "mass": _debris_mass})
	var t_debris_spawn_end := Time.get_ticks_usec()
	var t_debris_end := Time.get_ticks_usec()

	var t_columns := Time.get_ticks_usec()
	if destroyed_keys.size() > 0:
		_mesh_dirty = true
		set_process(true)
		_cached_faces = PackedVector3Array()
		_rebuild_smooth_collision_mesh()
	var t_columns_end := Time.get_ticks_usec()

	# Batch structural integrity check after all blocks destroyed this frame
	var t_integrity := Time.get_ticks_usec()
	if destroyed_keys.size() > 0:
		_check_structural_integrity()
	var t_integrity_end := Time.get_ticks_usec()

	var t_total_end := Time.get_ticks_usec()
	var _total_us := t_total_end - t_total
	print("[TakeDamageAt] %s  blocks=%d  pass1=%dus(query=%d calc=%d)  erase=%dus  debris=%dus(rpcs=%d spawned=%d rpc_time=%d spawn_time=%d)  collision=%dus  integrity=%dus  destroyed=%d  total=%dus" % [
		name, _block_hp_dict.size(),
		t_pass1_end - t_pass1, t_query_setup_end - t_query_setup, t_calc_explosion_end - t_calc_explosion,
		t_erase_end - t_erase,
		t_debris_end - t_debris, rpc_count, debris_spawn_count, t_debris_rpcs_end - t_debris_rpcs, t_debris_spawn_end - t_debris_spawn,
		t_columns_end - t_columns,
		t_integrity_end - t_integrity,
		destroyed_keys.size(),
		_total_us,
	])
	GameManager.tick_add("take_damage_at", _total_us)
	Profiler.end("struct_take_damage_at")

	# If all blocks gone, remove the structure node entirely
	if _block_hp_dict.is_empty():
		_clear_physics_before_free()
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
	Profiler.begin("struct_momentum_dmg")
	var _t_momentum_total := Time.get_ticks_usec()
	var empty_result := { "absorbed": 0.0, "block_destroyed": false,
		"block_key": Vector3i.ZERO, "block_pos": Vector3.ZERO }
	if not multiplayer.is_server():
		Profiler.end("struct_momentum_dmg")
		return empty_result
	if _block_hp_dict.is_empty():
		Profiler.end("struct_momentum_dmg")
		return empty_result

	_last_attacker_id = p_attacker_id

	# Transform world position to local grid coordinates
	var local_pos: Vector3 = global_transform.affine_inverse() * hit_world_pos
	var gx := roundi(local_pos.x / BLOCK_SIZE + _num_x * 0.5 - 0.5)
	var gy := roundi(local_pos.y / BLOCK_SIZE + _num_y * 0.5 - 0.5)
	var gz := roundi(local_pos.z / BLOCK_SIZE + _num_z * 0.5 - 0.5)
	var target_key := Vector3i(gx, gy, gz)

	# If exact key doesn't exist, find the nearest block within 2 cells
	var _t_search := Time.get_ticks_usec()
	if not _block_hp_dict.has(target_key):
		var best_key := Vector3i(-1, -1, -1)
		var best_dist_sq := 999.0
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				for dz in range(-2, 3):
					var candidate := Vector3i(gx + dx, gy + dy, gz + dz)
					if _block_hp_dict.has(candidate):
						var d := Vector3(dx, dy, dz).length_squared()
						if d < best_dist_sq:
							best_dist_sq = d
							best_key = candidate
		if best_dist_sq > 998.0:
			Profiler.end("struct_momentum_dmg")
			return empty_result
		target_key = best_key
	var _t_search_us := Time.get_ticks_usec() - _t_search

	var hp_before: float = _block_hp_dict[target_key]
	var absorbed: float = minf(damage, hp_before)

	# Apply damage
	_block_hp_dict[target_key] -= damage
	if _block_hp_dict[target_key] > 0.0:
		_update_compound_shielding_hp()
		var block_pos_local := _block_local_pos(target_key)
		Profiler.end("struct_momentum_dmg")
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": target_key, "block_pos": global_transform * block_pos_local }

	# Block destroyed
	var block_pos: Vector3 = global_transform * _block_local_pos(target_key)
	var ok_frac := clampf(-_block_hp_dict[target_key] / _block_hp, 0.0, 1.0)
	var _t_erase := Time.get_ticks_usec()
	_disable_hit_shape(target_key)
	_block_hp_dict.erase(target_key)
	_clear_block_grids(target_key.x, target_key.y, target_key.z)
	var _t_erase_us := Time.get_ticks_usec() - _t_erase
	_mesh_dirty = true
	set_process(true)
	var _t_col := Time.get_ticks_usec()
	_rebuild_smooth_collision_mesh()
	var _t_col_us := Time.get_ticks_usec() - _t_col
	_update_compound_shielding_hp()

	# Sync destruction + debris to clients
	var debris_count := randi_range(1, 2)
	var spd := DebrisHelper.calc_momentum_speed(impact_speed)
	var _t_rpc := Time.get_ticks_usec()
	_sync_block_destroyed.rpc(target_key, block_pos, hit_world_pos, debris_count, spd)
	var _t_rpc_us := Time.get_ticks_usec() - _t_rpc
	var _t_debris := Time.get_ticks_usec()
	_spawn_debris(block_pos, hit_world_pos, debris_count, spd)
	var _t_debris_us := Time.get_ticks_usec() - _t_debris

	# Defer structural integrity check to end of frame
	if not _block_hp_dict.is_empty() and not _integrity_check_pending:
		_integrity_check_pending = true
		call_deferred("_deferred_integrity_check")

	var _t_momentum_us := Time.get_ticks_usec() - _t_momentum_total
	print("[PERF] take_momentum_damage_at %s key=%s: search=%dus erase=%dus smooth_col=%dus rpc=%dus debris=%dus total=%dus blocks=%d" % [
		name, str(target_key), _t_search_us, _t_erase_us, _t_col_us, _t_rpc_us, _t_debris_us, _t_momentum_us, _block_hp_dict.size()])
	GameManager.tick_add("momentum_damage", _t_momentum_us)
	Profiler.end("struct_momentum_dmg")
	return { "absorbed": absorbed, "block_destroyed": true,
		"block_key": target_key, "block_pos": block_pos }


# ======================================================================
#  Debris (delegates to DebrisHelper static utility)
# ======================================================================

func _spawn_debris(block_pos: Vector3, blast_center: Vector3, count: int,
		debris_speed: float) -> void:
	DebrisHelper.spawn_debris(
		get_parent(), block_pos, blast_center, count, _structure_material,
		debris_speed,
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

func _deferred_integrity_check() -> void:
	## Runs at end of frame after all damage in this tick is applied.
	_integrity_check_pending = false
	var t0 := Time.get_ticks_usec()
	_check_structural_integrity()
	var us := Time.get_ticks_usec() - t0
	print("[PERF] _deferred_integrity_check %s: %dus  blocks=%d" % [name, us, _block_hp_dict.size()])
	GameManager.tick_add("deferred_integrity", us)
	if _block_hp_dict.is_empty():
		_clear_physics_before_free()
		queue_free()


## Stress model parameters (in units of block-weight).
## max_load: how many blocks of weight one face can bear in compression.
##   A 1-wide pillar snaps when it exceeds this height.
##   Tensile strength = 30% of this. Shear strength = 40% of this.
## horizontal_transfer: how readily load spreads sideways (0–1).
##   0 = load only flows vertically. 1 = full lateral distribution.
var stress_max_load: float = 15.0
var stress_horizontal_transfer: float = 0.6

func _check_structural_integrity() -> void:
	## Server-only: force-equilibrium stress solver + connectivity check.
	## Finds blocks that are either disconnected from ground OR cannot be
	## held in static equilibrium within material strength limits.
	if not multiplayer.is_server():
		return
	if _block_hp_dict.is_empty():
		return
	if _is_detached_structure:
		return

	Profiler.begin("struct_integrity")
	var t_si_total := Time.get_ticks_usec()

	# C++ force-equilibrium solver: ground-BFS + iterative stress solve + components.
	# Pass ground_mask so the solver knows which blocks are terrain-anchored.
	var _t_solver := Time.get_ticks_usec()
	var components: Array = BlockMeshBuilder.calc_stress_integrity_components(
		_block_grid, _ground_mask, _num_x, _num_y, _num_z, _block_hp_dict.size(),
		stress_max_load, stress_horizontal_transfer)
	var _t_solver_us := Time.get_ticks_usec() - _t_solver

	if components.is_empty():
		GameManager.tick_add("structural_integrity", Time.get_ticks_usec() - t_si_total)
		Profiler.end("struct_integrity")
		return

	var t_detach := Time.get_ticks_usec()
	_detach_clusters(components)
	var t_detach_end := Time.get_ticks_usec()

	var si_us := Time.get_ticks_usec() - t_si_total
	print("[StructuralIntegrity] %s  blocks=%d  components=%d  solver=%dus  detach=%dus  total=%dus" % [
		name, _block_hp_dict.size(), components.size(),
		_t_solver_us, t_detach_end - t_detach, si_us,
	])
	GameManager.tick_add("structural_integrity", si_us)
	Profiler.end("struct_integrity")


func _detach_clusters(components: Array) -> void:
	## Batch-detach all unsupported components in a single bulk-mode session.
	## Enters bulk mode ONCE for compound hit body and smooth collision body,
	## deduplicates column rebuilds across all components, single shielding update.
	var t_total := Time.get_ticks_usec()

	# ── Collect per-component data (centroids, valid keys, HPs) ──
	var t_collect := Time.get_ticks_usec()
	var cluster_data: Array = []  # Array of {keys, hps, centroid_world, mass}
	var all_valid_keys: Array[Vector3i] = []

	for component in components:
		var centroid_local := Vector3.ZERO
		var valid_count := 0
		var valid_keys: Array[Vector3i] = []
		var block_hps: Array[float] = []

		for key in component:
			if not _block_hp_dict.has(key):
				continue
			centroid_local += _block_local_pos(key)
			valid_count += 1
			valid_keys.append(key)
			block_hps.append(_block_hp_dict[key])

		if valid_count == 0:
			continue

		centroid_local /= float(valid_count)
		var centroid_world: Vector3 = global_transform * centroid_local
		var cluster_mass: float = valid_count * _get_block_mass()

		cluster_data.append({
			"keys": valid_keys,
			"hps": block_hps,
			"centroid": centroid_world,
			"mass": cluster_mass,
		})
		all_valid_keys.append_array(valid_keys)
	var t_collect_end := Time.get_ticks_usec()

	if cluster_data.is_empty():
		return

	# ── Erase blocks: single bulk-mode session for compound hit body ──
	var t_erase := Time.get_ticks_usec()
	var has_compound := _compound_hit_body and is_instance_valid(_compound_hit_body)
	if has_compound:
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
	for key in all_valid_keys:
		if _block_hp_dict.has(key):
			_disable_hit_shape(key)
			_block_hp_dict.erase(key)
			_clear_block_grids(key.x, key.y, key.z)
	if has_compound:
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
	_update_compound_shielding_hp()
	var t_erase_end := Time.get_ticks_usec()

	# ── Rebuild smooth collision mesh ──
	var t_col := Time.get_ticks_usec()
	_mesh_dirty = true
	set_process(true)
	_cached_faces = PackedVector3Array()
	_rebuild_smooth_collision_mesh()
	var t_col_end := Time.get_ticks_usec()

	# ── Single batched RPC for all clusters ──
	var t_rpc := Time.get_ticks_usec()
	var all_keys: Array = []
	var all_hps: Array = []
	var all_centroids := PackedVector3Array()
	var all_masses := PackedFloat32Array()
	all_centroids.resize(cluster_data.size())
	all_masses.resize(cluster_data.size())
	for i in cluster_data.size():
		all_keys.append(cluster_data[i]["keys"])
		all_hps.append(cluster_data[i]["hps"])
		all_centroids[i] = cluster_data[i]["centroid"]
		all_masses[i] = cluster_data[i]["mass"]
	_sync_cluster_detach_batch.rpc(all_keys, all_hps, all_centroids, all_masses,
		_last_attacker_id, _num_x, _num_y, _num_z, _get_block_mass())
	var t_rpc_end := Time.get_ticks_usec()

	print("[DetachClusters] %s  components=%d  blocks=%d  collect=%dus  erase=%dus  collision=%dus  rpc=%dus  total=%dus" % [
		name, cluster_data.size(), all_valid_keys.size(),
		t_collect_end - t_collect,
		t_erase_end - t_erase,
		t_col_end - t_col,
		t_rpc_end - t_rpc,
		Time.get_ticks_usec() - t_total,
	])


@rpc("authority", "call_local", "reliable")
func _sync_cluster_detach(block_keys: Array, block_hps: Array, spawn_pos: Vector3,
		cluster_mass: float, attacker_id: int, grid_num_x: int, grid_num_y: int,
		grid_num_z: int, mass_per_block: float) -> void:
	## All peers: remove detached blocks (clients only) and create the falling cluster.
	var t_sync_total := Time.get_ticks_usec()

	# Server: blocks already cleaned up in _detach_clusters(). Client: erase now.
	var t_client_cleanup := Time.get_ticks_usec()
	if multiplayer.is_server():
		pass  # Blocks already erased and shapes disabled in _detach_clusters()
	else:
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
		for key_variant in block_keys:
			var key: Vector3i = key_variant
			if _block_hp_dict.has(key):
				_disable_hit_shape(key)
				_block_hp_dict.erase(key)
				_clear_block_grids(key.x, key.y, key.z)
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)

		_mesh_dirty = true
		set_process(true)
		_cached_faces = PackedVector3Array()
		_rebuild_smooth_collision_mesh()
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
		_spawn_falling_cluster(typed_keys, typed_hps, spawn_pos, cluster_mass,
			attacker_id, grid_num_x, grid_num_y, grid_num_z, mass_per_block)
	var t_spawn_end := Time.get_ticks_usec()

	var sync_total := Time.get_ticks_usec() - t_sync_total
	print("[SyncClusterDetach] %s  keys=%d  client_cleanup=%dus  type_convert=%dus  spawn_structure=%dus  total=%dus" % [
		name, block_keys.size(),
		t_client_cleanup_end - t_client_cleanup,
		t_type_convert_end - t_type_convert,
		t_spawn_end - t_spawn,
		sync_total,
	])


@rpc("authority", "call_local", "reliable")
func _sync_cluster_detach_batch(all_keys: Array, all_hps: Array,
		all_centroids: PackedVector3Array, all_masses: PackedFloat32Array,
		attacker_id: int, grid_num_x: int, grid_num_y: int,
		grid_num_z: int, mass_per_block: float) -> void:
	## All peers: remove ALL detached blocks once, rebuild collision once,
	## then spawn all falling clusters. Replaces N individual _sync_cluster_detach RPCs.
	var t_batch_total := Time.get_ticks_usec()
	var n_clusters := all_keys.size()

	# Client: erase all blocks from all clusters in one bulk session.
	var t_client_cleanup := Time.get_ticks_usec()
	if not multiplayer.is_server():
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
		for cluster_keys: Array in all_keys:
			for key_variant in cluster_keys:
				var key: Vector3i = key_variant
				if _block_hp_dict.has(key):
					_disable_hit_shape(key)
					_block_hp_dict.erase(key)
					_clear_block_grids(key.x, key.y, key.z)
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
		_mesh_dirty = true
		set_process(true)
		_cached_faces = PackedVector3Array()
		_rebuild_smooth_collision_mesh()
	var t_client_cleanup_us := Time.get_ticks_usec() - t_client_cleanup

	# Spawn each cluster.
	var t_spawn := Time.get_ticks_usec()
	for i in n_clusters:
		var cluster_keys: Array = all_keys[i]
		var cluster_hps: Array = all_hps[i]
		var typed_keys: Array[Vector3i] = []
		var typed_hps: Array[float] = []
		for j in cluster_keys.size():
			typed_keys.append(cluster_keys[j] as Vector3i)
			typed_hps.append(float(cluster_hps[j]))
		if not GameManager.debug_disable_detached_structures:
			_spawn_falling_cluster(typed_keys, typed_hps, all_centroids[i],
				all_masses[i], attacker_id, grid_num_x, grid_num_y, grid_num_z,
				mass_per_block)
	var t_spawn_us := Time.get_ticks_usec() - t_spawn

	var t_batch_us := Time.get_ticks_usec() - t_batch_total
	print("[SyncClusterDetachBatch] %s  clusters=%d  client_cleanup=%dus  spawn=%dus  total=%dus" % [
		name, n_clusters, t_client_cleanup_us, t_spawn_us, t_batch_us])


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
	if not new_structure._block_hp_dict.is_empty():
		var first_key: Vector3i = new_structure._block_hp_dict.keys()[0]
		sample_block_pos = str(new_structure.global_transform * new_structure._block_local_pos(first_key))
	print("[SpawnDetachedStructure] name=%s  blocks=%d  parent=%s  struct_pos=%s  sample_block_pos=%s  script=%s" % [
		new_structure.name, new_structure._block_hp_dict.size(),
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

	# Build per-block HP dictionary
	var t_prep := Time.get_ticks_usec()
	var block_hp_dict: Dictionary = {}
	for i in block_keys.size():
		block_hp_dict[block_keys[i]] = block_hps[i]
	var t_prep_end := Time.get_ticks_usec()

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

	# init_cluster_blocks handles mesh, collision shapes, AND compound hit body.
	var t_init := Time.get_ticks_usec()
	cluster.init_cluster_blocks(block_hp_dict, grid_num_x, grid_num_y, grid_num_z,
		mass_per_block)
	if _structure_material:
		cluster.set_material(_structure_material.duplicate())
	cluster.set_debris_config(_debris_size, _debris_lifetime, _debris_mass,
		_debris_name, _block_hp)
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

	# Register with C++ shielding system so explosions see this cluster
	var cluster_rid := cluster.get_rid()
	PhysicsServer3D.body_set_shielding_tag(cluster_rid, 4)  # damageable
	var total_hp := 0.0
	for hp: float in block_hp_dict.values():
		total_hp += hp
	PhysicsServer3D.body_set_shielding_hp(cluster_rid, total_hp)
	var t_addchild_end := Time.get_ticks_usec()

	print("[SpawnCluster] %s  blocks=%d  prep=%dus  body=%dus  init=%dus  add_child=%dus  total=%dus" % [
		name, block_keys.size(),
		t_prep_end - t_prep,
		t_body_end - t_body,
		t_init_end - t_init,
		t_addchild_end - t_addchild,
		Time.get_ticks_usec() - t_spawn_total,
	])


func _build_cluster_mesh(block_keys: Array[Vector3i], centroid_local: Vector3) -> Mesh:
	## Build a mesh for a set of block keys, relative to centroid_local.
	## Uses ArrayMesh with indexed geometry for fast bulk upload.
	var key_set: Dictionary = {}
	for key in block_keys:
		key_set[key] = true

	var block_count := block_keys.size()
	var max_verts := block_count * 24  # 6 faces * 4 verts
	var max_idx := block_count * 36    # 6 faces * 6 indices

	var verts := PackedVector3Array()
	verts.resize(max_verts)
	var norms := PackedVector3Array()
	norms.resize(max_verts)
	var uv_arr := PackedVector2Array()
	uv_arr.resize(max_verts)
	var idx := PackedInt32Array()
	idx.resize(max_idx)

	var vi := 0
	var ii := 0
	var bs := BLOCK_SIZE
	var hs := bs * 0.5
	var uv0 := Vector2(0, 0)
	var uv1 := Vector2(1, 0)
	var uv2 := Vector2(1, 1)
	var uv3 := Vector2(0, 1)

	for key in block_keys:
		var cx: float = (key.x + 0.5 - _num_x * 0.5) * bs - centroid_local.x
		var cy: float = (key.y + 0.5 - _num_y * 0.5) * bs - centroid_local.y
		var cz: float = (key.z + 0.5 - _num_z * 0.5) * bs - centroid_local.z

		# +X face
		if not key_set.has(Vector3i(key.x + 1, key.y, key.z)):
			var x := cx + hs
			verts[vi] = Vector3(x, cy - hs, cz - hs); verts[vi + 1] = Vector3(x, cy - hs, cz + hs)
			verts[vi + 2] = Vector3(x, cy + hs, cz + hs); verts[vi + 3] = Vector3(x, cy + hs, cz - hs)
			norms[vi] = Vector3.RIGHT; norms[vi + 1] = Vector3.RIGHT; norms[vi + 2] = Vector3.RIGHT; norms[vi + 3] = Vector3.RIGHT
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6
		# -X face
		if not key_set.has(Vector3i(key.x - 1, key.y, key.z)):
			var x := cx - hs
			verts[vi] = Vector3(x, cy - hs, cz + hs); verts[vi + 1] = Vector3(x, cy - hs, cz - hs)
			verts[vi + 2] = Vector3(x, cy + hs, cz - hs); verts[vi + 3] = Vector3(x, cy + hs, cz + hs)
			norms[vi] = Vector3.LEFT; norms[vi + 1] = Vector3.LEFT; norms[vi + 2] = Vector3.LEFT; norms[vi + 3] = Vector3.LEFT
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6
		# +Y face (top)
		if not key_set.has(Vector3i(key.x, key.y + 1, key.z)):
			var y := cy + hs
			verts[vi] = Vector3(cx - hs, y, cz - hs); verts[vi + 1] = Vector3(cx + hs, y, cz - hs)
			verts[vi + 2] = Vector3(cx + hs, y, cz + hs); verts[vi + 3] = Vector3(cx - hs, y, cz + hs)
			norms[vi] = Vector3.UP; norms[vi + 1] = Vector3.UP; norms[vi + 2] = Vector3.UP; norms[vi + 3] = Vector3.UP
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6
		# -Y face (bottom)
		if not key_set.has(Vector3i(key.x, key.y - 1, key.z)):
			var y := cy - hs
			verts[vi] = Vector3(cx - hs, y, cz + hs); verts[vi + 1] = Vector3(cx + hs, y, cz + hs)
			verts[vi + 2] = Vector3(cx + hs, y, cz - hs); verts[vi + 3] = Vector3(cx - hs, y, cz - hs)
			norms[vi] = Vector3.DOWN; norms[vi + 1] = Vector3.DOWN; norms[vi + 2] = Vector3.DOWN; norms[vi + 3] = Vector3.DOWN
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6
		# +Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z + 1)):
			var z := cz + hs
			verts[vi] = Vector3(cx + hs, cy - hs, z); verts[vi + 1] = Vector3(cx - hs, cy - hs, z)
			verts[vi + 2] = Vector3(cx - hs, cy + hs, z); verts[vi + 3] = Vector3(cx + hs, cy + hs, z)
			norms[vi] = Vector3.BACK; norms[vi + 1] = Vector3.BACK; norms[vi + 2] = Vector3.BACK; norms[vi + 3] = Vector3.BACK
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6
		# -Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z - 1)):
			var z := cz - hs
			verts[vi] = Vector3(cx - hs, cy - hs, z); verts[vi + 1] = Vector3(cx + hs, cy - hs, z)
			verts[vi + 2] = Vector3(cx + hs, cy + hs, z); verts[vi + 3] = Vector3(cx - hs, cy + hs, z)
			norms[vi] = Vector3.FORWARD; norms[vi + 1] = Vector3.FORWARD; norms[vi + 2] = Vector3.FORWARD; norms[vi + 3] = Vector3.FORWARD
			uv_arr[vi] = uv0; uv_arr[vi + 1] = uv1; uv_arr[vi + 2] = uv2; uv_arr[vi + 3] = uv3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

	verts.resize(vi); norms.resize(vi); uv_arr.resize(vi); idx.resize(ii)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uv_arr
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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
	## Create the smooth collision body with a ConcavePolygonShape3D (trimesh).
	var t0 := Time.get_ticks_usec()
	_collision_body = StaticBody3D.new()
	_collision_body.name = "SmoothCollision"
	_collision_body.collision_layer = CollisionLayers.WALL_SMOOTH
	_collision_body.collision_mask = 0
	add_child(_collision_body)
	var t1 := Time.get_ticks_usec()
	_rebuild_smooth_collision_mesh()
	var t2 := Time.get_ticks_usec()
	if t2 - t0 > 3000:
		print("[SMOOTH_COL] %s body=%dus shape=%dus faces=%d" % [
			name, t1 - t0, t2 - t1, _cached_faces.size() / 3])


func _rebuild_smooth_collision_mesh() -> void:
	## Rebuild the trimesh collision shape from the greedy mesh faces.
	if _collision_body == null or not is_instance_valid(_collision_body):
		return

	var _t_smooth_total := Time.get_ticks_usec()
	var body_rid := _collision_body.get_rid()
	var _t_clear := Time.get_ticks_usec()
	PhysicsServer3D.body_clear_shapes(body_rid)
	var _t_clear_us := Time.get_ticks_usec() - _t_clear

	var _t_free := Time.get_ticks_usec()
	if _smooth_shape_rid.is_valid():
		PhysicsServer3D.free_rid(_smooth_shape_rid)
		_smooth_shape_rid = RID()
	var _t_free_us := Time.get_ticks_usec() - _t_free

	# If cached faces are stale (destruction path), rebuild from grid
	var _t_faces := Time.get_ticks_usec()
	if _cached_faces.is_empty():
		_cached_faces = BlockMeshBuilder.build_collision_faces(_block_grid, _num_x, _num_y, _num_z, BLOCK_SIZE)
	var _t_faces_us := Time.get_ticks_usec() - _t_faces
	if _cached_faces.is_empty():
		return

	var _t_create := Time.get_ticks_usec()
	_smooth_shape_rid = PhysicsServer3D.concave_polygon_shape_create()
	PhysicsServer3D.shape_set_data(_smooth_shape_rid, {"faces": _cached_faces, "backface_collision": false})
	PhysicsServer3D.body_add_shape(body_rid, _smooth_shape_rid)
	var _t_create_us := Time.get_ticks_usec() - _t_create

	var _t_smooth_us := Time.get_ticks_usec() - _t_smooth_total
	if _t_smooth_us > 200:
		print("[PERF] _rebuild_smooth_collision %s: clear=%dus free=%dus faces=%dus(%d tris) create=%dus total=%dus" % [
			name, _t_clear_us, _t_free_us, _t_faces_us, _cached_faces.size() / 3, _t_create_us, _t_smooth_us])
	GameManager.tick_add("smooth_collision", _t_smooth_us)


# ======================================================================
#  GREEDY MESHING — single draw call per structure
# ======================================================================
#
# For each of the 6 face directions, we iterate every block. If the block
# exists and has no neighbor in that direction, we emit a quad. Each
# exposed block face = 1 quad = 2 triangles. This is still a HUGE
# improvement: 1 MeshInstance per structure instead of 1 per block.

var _cached_faces: PackedVector3Array = PackedVector3Array()

func _rebuild_greedy_mesh() -> void:
	if _mesh_instance == null:
		return
	if _block_hp_dict.is_empty():
		_mesh_instance.mesh = null
		if _foundation_mesh_instance:
			_foundation_mesh_instance.mesh = null
		_cached_faces = PackedVector3Array()
		return

	var _t_greedy_total := Time.get_ticks_usec()
	# If we have a foundation grid, build separate meshes for structure vs foundation.
	if _foundation_grid.size() == _block_grid.size():
		var _t_split := Time.get_ticks_usec()
		var struct_grid := PackedByteArray()
		struct_grid.resize(_block_grid.size())
		for i in _block_grid.size():
			struct_grid[i] = _block_grid[i] if not _foundation_grid[i] else 0
		var _t_split_us := Time.get_ticks_usec() - _t_split
		var _t_struct_mesh := Time.get_ticks_usec()
		_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
			struct_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
		var _t_struct_mesh_us := Time.get_ticks_usec() - _t_struct_mesh
		var _t_foundation_mesh_us := 0
		if _foundation_mesh_instance:
			var _t_fm := Time.get_ticks_usec()
			_foundation_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
				_foundation_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
			_t_foundation_mesh_us = Time.get_ticks_usec() - _t_fm
		var _t_greedy_us := Time.get_ticks_usec() - _t_greedy_total
		if _t_greedy_us > 200:
			print("[PERF] _rebuild_greedy_mesh %s (split): grid_split=%dus struct_mesh=%dus foundation_mesh=%dus total=%dus blocks=%d" % [
				name, _t_split_us, _t_struct_mesh_us, _t_foundation_mesh_us, _t_greedy_us, _block_hp_dict.size()])
	else:
		var _t_mesh := Time.get_ticks_usec()
		_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
			_block_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
		var _t_mesh_us := Time.get_ticks_usec() - _t_mesh
		if _t_mesh_us > 200:
			print("[PERF] _rebuild_greedy_mesh %s: mesh=%dus blocks=%d" % [name, _t_mesh_us, _block_hp_dict.size()])

	# Build collision faces from the full block grid (both structure + foundation).
	var _t_faces := Time.get_ticks_usec()
	_cached_faces = BlockMeshBuilder.build_collision_faces(_block_grid, _num_x, _num_y, _num_z, BLOCK_SIZE)
	var _t_faces_us := Time.get_ticks_usec() - _t_faces
	var _t_greedy_total_us := Time.get_ticks_usec() - _t_greedy_total
	GameManager.tick_add("greedy_mesh_rebuild", _t_greedy_total_us)


func _build_faces_from_grid() -> PackedVector3Array:
	## Build collision triangle faces from the flat occupancy grid.
	## Uses O(1) array lookups — no Dictionary, no GPU readback.
	var faces := PackedVector3Array()
	faces.resize(_block_hp_dict.size() * 36)
	var fi := 0
	var bs := BLOCK_SIZE
	var hs := bs * 0.5
	# Must match BlockMeshBuilder.build_block_mesh with centroid=ZERO:
	# C++ uses (bx + 0.5 - half) * bs, where half = num * 0.5
	# Same as _block_local_pos: (bx + 0.5 - num * 0.5) * bs
	var half_x := _num_x * bs * 0.5
	var half_y := _num_y * bs * 0.5
	var half_z := _num_z * bs * 0.5
	var ny_nz := _num_y * _num_z

	for bx in _num_x:
		for by in _num_y:
			for bz in _num_z:
				if not _block_grid[bx * ny_nz + by * _num_z + bz]:
					continue
				var cx: float = (bx + 0.5) * bs - half_x
				var cy: float = (by + 0.5) * bs - half_y
				var cz: float = (bz + 0.5) * bs - half_z

				# +X
				if bx + 1 >= _num_x or not _block_grid[(bx + 1) * ny_nz + by * _num_z + bz]:
					var x := cx + hs
					faces[fi] = Vector3(x, cy - hs, cz - hs); faces[fi+1] = Vector3(x, cy - hs, cz + hs); faces[fi+2] = Vector3(x, cy + hs, cz + hs)
					faces[fi+3] = Vector3(x, cy - hs, cz - hs); faces[fi+4] = Vector3(x, cy + hs, cz + hs); faces[fi+5] = Vector3(x, cy + hs, cz - hs)
					fi += 6
				# -X
				if bx - 1 < 0 or not _block_grid[(bx - 1) * ny_nz + by * _num_z + bz]:
					var x := cx - hs
					faces[fi] = Vector3(x, cy - hs, cz + hs); faces[fi+1] = Vector3(x, cy - hs, cz - hs); faces[fi+2] = Vector3(x, cy + hs, cz - hs)
					faces[fi+3] = Vector3(x, cy - hs, cz + hs); faces[fi+4] = Vector3(x, cy + hs, cz - hs); faces[fi+5] = Vector3(x, cy + hs, cz + hs)
					fi += 6
				# +Y
				if by + 1 >= _num_y or not _block_grid[bx * ny_nz + (by + 1) * _num_z + bz]:
					var y := cy + hs
					faces[fi] = Vector3(cx - hs, y, cz - hs); faces[fi+1] = Vector3(cx + hs, y, cz - hs); faces[fi+2] = Vector3(cx + hs, y, cz + hs)
					faces[fi+3] = Vector3(cx - hs, y, cz - hs); faces[fi+4] = Vector3(cx + hs, y, cz + hs); faces[fi+5] = Vector3(cx - hs, y, cz + hs)
					fi += 6
				# -Y
				if by - 1 < 0 or not _block_grid[bx * ny_nz + (by - 1) * _num_z + bz]:
					var y := cy - hs
					faces[fi] = Vector3(cx - hs, y, cz + hs); faces[fi+1] = Vector3(cx + hs, y, cz + hs); faces[fi+2] = Vector3(cx + hs, y, cz - hs)
					faces[fi+3] = Vector3(cx - hs, y, cz + hs); faces[fi+4] = Vector3(cx + hs, y, cz - hs); faces[fi+5] = Vector3(cx - hs, y, cz - hs)
					fi += 6
				# +Z
				if bz + 1 >= _num_z or not _block_grid[bx * ny_nz + by * _num_z + bz + 1]:
					var z := cz + hs
					faces[fi] = Vector3(cx + hs, cy - hs, z); faces[fi+1] = Vector3(cx - hs, cy - hs, z); faces[fi+2] = Vector3(cx - hs, cy + hs, z)
					faces[fi+3] = Vector3(cx + hs, cy - hs, z); faces[fi+4] = Vector3(cx - hs, cy + hs, z); faces[fi+5] = Vector3(cx + hs, cy + hs, z)
					fi += 6
				# -Z
				if bz - 1 < 0 or not _block_grid[bx * ny_nz + by * _num_z + bz - 1]:
					var z := cz - hs
					faces[fi] = Vector3(cx - hs, cy - hs, z); faces[fi+1] = Vector3(cx + hs, cy - hs, z); faces[fi+2] = Vector3(cx + hs, cy + hs, z)
					faces[fi+3] = Vector3(cx - hs, cy - hs, z); faces[fi+4] = Vector3(cx + hs, cy + hs, z); faces[fi+5] = Vector3(cx - hs, cy + hs, z)
					fi += 6
	faces.resize(fi)
	return faces
