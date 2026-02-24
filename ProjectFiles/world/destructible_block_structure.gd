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

## Dimensions of the structure in world units. Subclasses provide a
## compatibility alias (wall_size / ramp_size) that delegates here.
var structure_size: Vector3 = Vector3(10, 4, 1)

## Block grid: Dictionary[Vector3i -> { "body": StaticBody3D, "hp": float }]
var _blocks: Dictionary = {}
var _num_x: int = 0
var _num_y: int = 0
var _num_z: int = 0
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
var _debris_impulse: float = 3.5
var _debris_lifetime: float = 5.0
var _debris_max_total: int = 40
var _debris_mass: float = 0.5
var _debris_name: String = "Debris"


# ======================================================================
#  Virtual methods — subclasses MUST override these
# ======================================================================

func _get_tier_info() -> Dictionary:
	## Return { "color": Color, "block_hp": float } for the current tier.
	push_error("DestructibleBlockStructure._get_tier_info() not overridden!")
	return { "color": Color.MAGENTA, "block_hp": 35.0 }


func _get_debris_config() -> Dictionary:
	## Return debris parameters for this structure type.
	## Keys: "size", "per_block", "impulse", "lifetime", "max_total", "mass", "name"
	push_error("DestructibleBlockStructure._get_debris_config() not overridden!")
	return {
		"size": 0.15, "per_block": 2, "impulse": 3.5,
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


# ======================================================================
#  Lifecycle
# ======================================================================

func _ready() -> void:
	var tier_info: Dictionary = _get_tier_info()
	_block_hp = tier_info["block_hp"]

	var debris_cfg: Dictionary = _get_debris_config()
	_debris_size = debris_cfg["size"]
	_debris_per_block = debris_cfg["per_block"]
	_debris_impulse = debris_cfg["impulse"]
	_debris_lifetime = debris_cfg["lifetime"]
	_debris_max_total = debris_cfg["max_total"]
	_debris_mass = debris_cfg["mass"]
	_debris_name = debris_cfg["name"]

	# Create shared resources
	_block_shape = BoxShape3D.new()
	_block_shape.size = Vector3.ONE * BLOCK_SIZE

	_structure_material = _create_structure_material(tier_info)

	# Calculate grid dimensions
	_num_x = maxi(int(structure_size.x / BLOCK_SIZE), 1)
	_num_y = maxi(int(structure_size.y / BLOCK_SIZE), 1)
	_num_z = maxi(int(structure_size.z / BLOCK_SIZE), 1)

	# Build block grid (collision only — no per-block meshes)
	for bx in _num_x:
		for by in _num_y:
			for bz in _num_z:
				if _should_spawn_block(bx, by, bz):
					_spawn_block(bx, by, bz)

	# Build single greedy-meshed visual
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _structure_material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	_rebuild_greedy_mesh()

	# Build smooth collision shell for player physics (no seam bouncing)
	_build_smooth_collision()

	# Disable per-frame processing — only needed when _mesh_dirty is set
	set_process(false)


func _process(_delta: float) -> void:
	# Deferred mesh rebuild: blocks were destroyed, rebuild once then sleep
	if _mesh_dirty:
		_mesh_dirty = false
		_rebuild_greedy_mesh()
		set_process(false)


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
	block_body.collision_layer = 1024  # Layer 11: block detection (weapons only)
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

	_blocks[Vector3i(bx, by, bz)] = {
		"body": block_body,
		"hp": _block_hp,
	}


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
		return

	block_data["hp"] -= amount
	if block_data["hp"] <= 0.0:
		var block_pos: Vector3 = block_body.global_position
		var debris_count := randi_range(1, 2)

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
		_mesh_dirty = true
		set_process(true)  # Wake up _process to rebuild mesh next frame
		_rebuild_column(key.x, key.z)
		_sync_block_destroyed.rpc(key, block_pos, blast_origin, debris_count)

		# Host also spawns debris locally (RPC is call_remote, host needs it too).
		_spawn_debris(block_pos, blast_origin, debris_count)

		if _blocks.is_empty():
			queue_free()


@rpc("authority", "call_remote", "reliable")
func _sync_block_destroyed(key: Vector3i, block_pos: Vector3 = Vector3.ZERO,
		blast_center: Vector3 = Vector3.ZERO, debris_count: int = 0) -> void:
	## Client-side: remove a destroyed block, rebuild mesh, and spawn cosmetic debris.
	if _blocks.has(key):
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if is_instance_valid(block_body):
			block_body.queue_free()
		_blocks.erase(key)
		_mesh_dirty = true
		set_process(true)
		_rebuild_column(key.x, key.z)

	# Spawn cosmetic debris on the client.
	if debris_count > 0:
		_spawn_debris(block_pos, blast_center, debris_count)


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float, _attacker_id: int, exclude_rids: Array[RID] = []) -> void:
	## Damage blocks within blast_radius of hit_pos. Only blocks in range take damage.
	## Shielding uses flat HP absorption: each wall block or player between the
	## explosion and a target block absorbs damage equal to its current HP.
	## exclude_rids: physics bodies to ignore in shielding raycasts (e.g. the rocket).
	if not multiplayer.is_server():
		return

	var space_state := get_world_3d().direct_space_state
	var debug_rays := GameManager.debug_show_explosion_rays

	var debris_spawned := 0
	var destroyed_keys: Array[Vector3i] = []
	var destroyed_positions: Array[Vector3] = []
	var debug_ray_data: Array = []

	# Two-pass damage: compute all damage first (read-only), then apply.
	# This prevents block HP mutations from affecting shielding calculations
	# for later blocks, which caused directional bias in single-pass.
	var damage_map: Dictionary = {}  # Vector3i -> float

	var t_total_start := Time.get_ticks_usec()

	# --- Pass 1: Compute damage for all blocks (read-only) ---
	# Phase A: Collect all blocks in range (cheap math, no physics).
	var block_keys: Array[Vector3i] = []
	var to_points := PackedVector3Array()
	var target_rids: Array[RID] = []
	var raw_damages := PackedFloat32Array()

	for key: Vector3i in _blocks:
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if not is_instance_valid(block_body):
			continue

		var block_world_pos: Vector3 = block_body.global_position
		var dist: float = hit_pos.distance_to(block_world_pos)

		if dist > blast_radius or dist <= 0.3:
			continue

		# Base damage with cubic distance falloff
		var norm_dist: float = dist / blast_radius
		var falloff: float = 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
		var dmg: float = amount * falloff

		block_keys.append(key)
		to_points.append(block_world_pos)
		target_rids.append(block_body.get_rid())
		raw_damages.append(dmg)

	var t_collect := Time.get_ticks_usec()

	# Phase B: Batch shielding (parallelized in C++ via WorkerThreadPool).
	if not to_points.is_empty() and space_state:
		if debug_rays:
			# Debug path: sequential with per-ray intersect_ray_all for hit positions.
			for i in block_keys.size():
				var ray_excludes: Array[RID] = [target_rids[i]]
				ray_excludes.append_array(exclude_rids)
				var result: Array = ExplosionHelper.calc_ray_shielding_debug(
					space_state, hit_pos, to_points[i], ray_excludes, null
				)
				var final_dmg := maxf(raw_damages[i] - result[0], 0.0)
				debug_ray_data.append({
					"from": hit_pos, "to": to_points[i],
					"raw_dmg": raw_damages[i], "final_dmg": final_dmg,
					"hits": result[1],
				})
				if final_dmg >= 0.5:
					damage_map[block_keys[i]] = final_dmg
		else:
			# Production path: single C++ call, parallelized across worker threads.
			var absorptions := space_state.calc_ray_shielding_batch(
				ExplosionHelper._make_shielding_query(hit_pos, exclude_rids),
				to_points, target_rids, raw_damages
			)
			for i in absorptions.size():
				var final_dmg := maxf(raw_damages[i] - absorptions[i], 0.0)
				if final_dmg >= 0.5:
					damage_map[block_keys[i]] = final_dmg

	var t_batch := Time.get_ticks_usec()
	print("[take_damage_at] blocks=%d  in_range=%d  collect=%dus  batch=%dus  total_pass1=%dus" % [
		_blocks.size(), to_points.size(),
		t_collect - t_total_start,
		t_batch - t_collect,
		t_batch - t_total_start,
	])

	# --- Pass 2: Apply all damage simultaneously ---
	for key: Vector3i in damage_map:
		if not _blocks.has(key):
			continue
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		block_data["hp"] -= damage_map[key]
		if block_data["hp"] <= 0.0:
			destroyed_keys.append(key)
			destroyed_positions.append(block_body.global_position)
			block_body.queue_free()

	# Draw debug rays if toggled on
	if debug_rays and not debug_ray_data.is_empty():
		ExplosionHelper.draw_debug_rays(debug_ray_data)

	# Clean up destroyed entries and sync to clients (with debris info).
	for i in destroyed_keys.size():
		var key := destroyed_keys[i]
		var block_pos := destroyed_positions[i]
		_blocks.erase(key)

		# Determine debris count for this block.
		var to_spawn := 0
		if debris_spawned < _debris_max_total:
			to_spawn = mini(_debris_per_block, _debris_max_total - debris_spawned)
			debris_spawned += to_spawn

		# Sync to clients (they spawn debris). Host spawns debris locally.
		_sync_block_destroyed.rpc(key, block_pos, hit_pos, to_spawn)
		if to_spawn > 0:
			_spawn_debris(block_pos, hit_pos, to_spawn)

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

	# If all blocks gone, remove the structure node entirely
	if _blocks.is_empty():
		queue_free()


# ======================================================================
#  Debris (delegates to DebrisHelper static utility)
# ======================================================================

func _spawn_debris(block_pos: Vector3, blast_center: Vector3, count: int) -> void:
	DebrisHelper.spawn_debris(
		get_parent(), block_pos, blast_center, count, _structure_material,
		{
			"size": _debris_size, "impulse": _debris_impulse,
			"lifetime": _debris_lifetime, "mass": _debris_mass,
			"name": _debris_name,
		}
	)


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
	_collision_body.collision_layer = 2048  # Layer 12: smooth wall collision
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

	# Collect which Y indices still have blocks in this column
	var y_present: Array[int] = []
	for by in _num_y:
		if _blocks.has(Vector3i(bx, by, bz)):
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
