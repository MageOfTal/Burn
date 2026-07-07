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
var _smooth_shape_rids: Array = []  ## One RID per cuboid in greedy box decomposition
									## (untyped because C++ kernel returns plain Array)

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

## Persistent stress-solver state. Currently unused — kept for the future
## localized-solver path. See BOND_GRAPH_PLAN.md.
var _stress_persistent_state: Dictionary = {}

## Flat indices of blocks destroyed since the last stress solve. Currently unused.
var _stress_dirty_seeds: PackedInt32Array = PackedInt32Array()

# ─────────────────────────────────────────────────────────────────────────────
# Bond graph state (see BOND_GRAPH_PLAN.md)
#
# Each bond connects two adjacent occupied blocks. Storage is canonical: a
# bond is owned by the lower-indexed of the two blocks. Per-block, we store
# 3 bonds — the +X, +Y, +Z neighbors. Bonds in the -X/-Y/-Z direction are
# owned by the *neighbor* in that direction.
#
# Indexing: bond_idx = block_grid_idx * 3 + axis, where axis ∈ {0=X, 1=Y, 2=Z}.
#
# A bond is INTACT when _bond_strength[i] > 0 and _bond_broken[i] == 0.
# A bond is BROKEN when _bond_broken[i] != 0 OR when either of its endpoint
# blocks is gone from _block_hp_dict.
#
# Bonds at the structure boundary (no neighbor) have strength 0 and are
# pre-marked broken — ignored.
# ─────────────────────────────────────────────────────────────────────────────

## Maximum damage each bond can absorb before breaking. Sized grid_size * 3.
var _bond_strength: PackedFloat32Array = PackedFloat32Array()

## Accumulated damage on each bond. Sized grid_size * 3. Compared against
## _bond_strength to determine if a bond should break.
var _bond_damage: PackedFloat32Array = PackedFloat32Array()

## 1 if bond is broken, 0 if intact. Sized grid_size * 3.
var _bond_broken: PackedByteArray = PackedByteArray()

# ─── Terrain anchor bonds (one per block) ────────────────────────────────
# Each block in `_ground_mask` has an additional "bond to terrain" that holds
# it in place against gravity. These bonds break the same way inter-block
# bonds do — accumulate damage from blasts/bullets/impacts, snap when damage
# exceeds strength. Once a block's anchor breaks, it stops being a BFS seed
# and can be detached as a free cluster like any unsupported block.
#
# Sized grid_size (one entry per block, vs grid_size*3 for inter-block bonds).
# Index is the same flat grid index as _block_grid.
var _anchor_bond_strength: PackedFloat32Array = PackedFloat32Array()
var _anchor_bond_damage: PackedFloat32Array = PackedFloat32Array()
var _anchor_bond_broken: PackedByteArray = PackedByteArray()

## Multiplier from block HP to bond strength. Tunable. Higher = bonds are
## tougher than the blocks they connect; structures hold together longer
## under marginal damage.
var bond_strength_factor: float = 1.0

## How much damage to apply per unit of explosion energy. Tunable. The
## explosion path passes its `structure_damage` × this factor as the energy
## value to damage_bonds_in_radius.
var bond_damage_explosion_factor: float = 0.5


## How much bond damage a bullet inflicts on the bonds touching the hit block,
## as a fraction of the block damage applied. 0.5 = each bond touching the hit
## block takes 50% of the block damage value.
var bond_damage_bullet_factor: float = 0.5

## How much bond damage a momentum impact inflicts in a small radius around
## the impact point. Multiplies the impact damage value passed to
## take_momentum_damage_at.
var bond_damage_momentum_factor: float = 0.75

## Radius (in world units) around a momentum impact within which bonds take
## damage. Kept small so heavy collisions weaken local supports without
## propagating through the whole structure.
var bond_damage_momentum_radius: float = 1.5

## Bonds-only destruction mode. When true, blocks never lose HP from damage —
## only bonds accumulate damage. Blocks "die" only when the connectivity check
## detaches them as part of a falling cluster. Faithful to The Finals model.
var bonds_only_destruction: bool = true

# ─── Gravity stress solver (see GRAVITY_STRESS_PLAN.md) ─────────────────────
# Quasi-static elastic-brittle analysis: 6-DOF blocks joined by glued-face
# interfaces that carry force AND moment. Runs inside the integrity check when
# the bond graph changed; breaks interfaces whose combined edge stress exceeds
# capacity, then the ordinary connectivity check detaches whatever came loose.
# Capacities couple to bond damage (κ = 1 − damage/strength): blast-weakened
# joints hold less, so explosions weaken and gravity finishes the job.
# Limits are in block-weight units. Tension governs overhangs via bending:
# a 1-thick cantilever survives n ≤ √(tension/3) blocks; a 1-thick roof span
# supported at both ends survives ~√(8·tension/6) blocks. Default 90 →
# cantilever ≈5 blocks (2.7m), roof span ≈11 blocks (5.5m) — strict enough
# that bad builds collapse, forgiving enough that typical map geometry
# survives the spawn check. Drop toward 50 for harsher realism.

## Tensile capacity of a pristine bond, in block-weights.
var stress_tension_blocks: float = 90.0

## Compressive capacity, in block-weights (~10× tension, masonry-like).
var stress_compression_blocks: float = 900.0

## Shear capacity, in block-weights (0.75× tension, brittle materials).
var stress_shear_blocks: float = 67.5

## True when bond/anchor damage or topology changed since the last gravity
## solve. Cleared when the solver runs; keeps the (ms-scale) solve off the
## per-bullet hot path when nothing structural actually changed.
var _gravity_stress_dirty: bool = false

## Async gravity solve. On big structures a solve is tens-to-hundreds of ms
## of CPU — far too much to block the main thread (the original synchronous
## call was THE rocket-lag spike: ~476ms on the 17k-block house). Solves run
## on StressSolver's dedicated thread against COW snapshots of the bond
## arrays; the result merges back in _physics_process 1-N frames later. The
## merge is safe because the solver only SETS broken flags — OR-ing with live
## state can't resurrect a bond, and damage accumulated during the solve is
## preserved.
var _gravity_task_id: int = -1


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
		GameManager.plog("[Foundation] %s  SKIP: no space_state" % name)
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

	GameManager.plog("[Foundation] %s  rays=%d  hits=%d  max_extra=%d  pos=%s" % [
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

	# Build ground mask: every foundation block is a terrain anchor (not just
	# the lowest one). If we only anchored the bottom row, a bond breaking
	# between foundation rows would let the upper foundation rows "detach"
	# into a falling cluster, which renders with the structure's wall material
	# and looks like the foundation just changed color.
	_ground_mask.resize(new_grid_size)
	_ground_mask.fill(0)
	for i in _foundation_grid.size():
		if _foundation_grid[i] == 1:
			_ground_mask[i] = 1
	# Also anchor the lowest occupied block per column for any column whose
	# foundation didn't reach the rest of the structure (defensive).
	for bx in _num_x:
		for bz in _num_z:
			for by in _num_y:
				if new_grid[_grid_idx_raw(bx, by, bz, _num_y, _num_z)]:
					_ground_mask[_grid_idx_raw(bx, by, bz, _num_y, _num_z)] = 1
					break

	# Grid grew in Y (foundation rows added), so the bond arrays we sized at
	# initial setup are now too small. Re-init from the expanded grid before
	# any damage event tries to index past the old end.
	_init_bond_graph()

	# Shift structure down to keep original blocks at the same world position.
	global_position.y -= max_extra_rows * BLOCK_SIZE * 0.5

	GameManager.plog("[Foundation] %s  extra_rows=%d  new_num_y=%d  foundation_blocks=%d  total_blocks=%d  shift=%.2f" % [
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
		GameManager.plog("[GroundMask] %s  grounded=%d/%d columns" % [name, grounded, _num_x * _num_z])


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
		# The anchor bonds were initialized in _ready() against an all-zero
		# ground mask (all pre-broken). Re-init from the real mask, otherwise
		# the structure has no effective anchors and detaches wholesale on the
		# first integrity check.
		_init_anchor_bonds()
		var _t_gm_us := Time.get_ticks_usec() - _t_gm
		var _t_foundation_us := Time.get_ticks_usec() - _t_foundation_total
		GameManager.plog("[PERF] _deferred_build_foundation %s (no expand): build=%dus ground_mask=%dus total=%dus" % [
			name, _t_build_us, _t_gm_us, _t_foundation_us])
		_queue_creation_integrity_check()
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
	GameManager.plog("[PERF] _deferred_build_foundation %s (expanded): build=%dus mesh=%dus foundation_mesh=%dus collision=%dus hitbody=%dus total=%dus blocks=%d" % [
		name, _t_build_us, _t_mesh_rebuild_us, _t_foundation_mesh_us, _t_col_rebuild_us, _t_hitbody_us, _t_foundation_us, _block_hp_dict.size()])
	_queue_creation_integrity_check()


func _queue_creation_integrity_check() -> void:
	## Called once the foundation pass has produced real terrain anchors.
	## Runs the first integrity check (gravity stress + connectivity) so a
	## structure built with inadequate support collapses at spawn — no damage
	## required. Server-only; clients receive the result via detach RPCs.
	if not multiplayer.is_server():
		return
	if not GameManager.gravity_stress_enabled:
		return
	_gravity_stress_dirty = true
	if not _integrity_check_pending:
		_integrity_check_pending = true
		call_deferred("_deferred_integrity_check")


# ─────────────────────────────────────────────────────────────────────────────
# Bond graph (see BOND_GRAPH_PLAN.md)
# ─────────────────────────────────────────────────────────────────────────────

const _BOND_AXIS_X: int = 0
const _BOND_AXIS_Y: int = 1
const _BOND_AXIS_Z: int = 2


func _bond_idx(block_grid_idx: int, axis: int) -> int:
	## Canonical bond index. The bond is owned by the lower-indexed block
	## (this one) and connects to its neighbor in +axis direction.
	return block_grid_idx * 3 + axis


func _bond_idx_at(bx: int, by: int, bz: int, axis: int) -> int:
	return (bx * _num_y * _num_z + by * _num_z + bz) * 3 + axis


func _has_neighbor(bx: int, by: int, bz: int, axis: int) -> bool:
	## True if (bx, by, bz) has a +axis neighbor inside the grid AND that
	## neighbor is currently occupied (block exists in _block_grid).
	if axis == _BOND_AXIS_X:
		if bx + 1 >= _num_x:
			return false
		return _block_grid[_grid_idx(bx + 1, by, bz)] == 1
	elif axis == _BOND_AXIS_Y:
		if by + 1 >= _num_y:
			return false
		return _block_grid[_grid_idx(bx, by + 1, bz)] == 1
	else:
		if bz + 1 >= _num_z:
			return false
		return _block_grid[_grid_idx(bx, by, bz + 1)] == 1


func _init_bond_graph() -> void:
	## C++ kernel populates strengths for every adjacent pair in _block_grid.
	## Single-block structures skip — nothing to bond to, naturally inert.
	if _block_hp_dict.size() < 2:
		_bond_strength = PackedFloat32Array()
		_bond_damage = PackedFloat32Array()
		_bond_broken = PackedByteArray()
		_anchor_bond_strength = PackedFloat32Array()
		_anchor_bond_damage = PackedFloat32Array()
		_anchor_bond_broken = PackedByteArray()
		return
	var strength := _block_hp * bond_strength_factor
	var result: Dictionary = BlockMeshBuilder.compute_bond_graph(
		_block_grid, _num_x, _num_y, _num_z, strength)
	_bond_strength = result["bond_strength"]
	_bond_damage = result["bond_damage"]
	_bond_broken = result["bond_broken"]
	_init_anchor_bonds()


func _init_anchor_bonds() -> void:
	## Set up the per-block terrain anchor bond from the current ground mask.
	## Each block that touches terrain gets an anchor bond with the same
	## strength as a regular inter-block bond. Other blocks are pre-broken
	## (treated as having no anchor) so they can never seed the BFS.
	## Reads _ground_mask, so call AFTER the foundation pass populates it.
	var grid_size := _block_grid.size()
	_anchor_bond_strength.resize(grid_size)
	_anchor_bond_damage.resize(grid_size)
	_anchor_bond_broken.resize(grid_size)
	_anchor_bond_strength.fill(0.0)
	_anchor_bond_damage.fill(0.0)
	_anchor_bond_broken.fill(1)
	if _ground_mask.size() != grid_size:
		return
	var anchor_strength: float = _block_hp * bond_strength_factor
	for i in grid_size:
		if _ground_mask[i] == 1 and _block_grid[i] == 1:
			_anchor_bond_strength[i] = anchor_strength
			_anchor_bond_broken[i] = 0


func _damage_anchors_in_radius(world_pos: Vector3, energy: float, radius: float) -> int:
	## Damage terrain anchor bonds within `radius` of world_pos. Same cubic
	## falloff as the inter-block bond kernel (no DDA shielding here — anchors
	## are local to each block; their "strength" already factors in bedrock).
	## Returns number of anchors that broke.
	if radius <= 0.0 or energy <= 0.0:
		return 0
	if _anchor_bond_strength.is_empty():
		return 0
	var inv_radius := 1.0 / radius
	var ny_nz := _num_y * _num_z
	var grid_size := _block_grid.size()
	var local_hit: Vector3 = global_transform.affine_inverse() * world_pos
	var broken := 0
	# Spatial pre-filter — skip blocks well outside radius.
	var r_blocks := radius / BLOCK_SIZE + 1.0
	var min_bx: int = maxi(0, int(local_hit.x / BLOCK_SIZE + _num_x * 0.5 - r_blocks))
	var max_bx: int = mini(_num_x, int(local_hit.x / BLOCK_SIZE + _num_x * 0.5 + r_blocks) + 1)
	var min_by: int = maxi(0, int(local_hit.y / BLOCK_SIZE + _num_y * 0.5 - r_blocks))
	var max_by: int = mini(_num_y, int(local_hit.y / BLOCK_SIZE + _num_y * 0.5 + r_blocks) + 1)
	var min_bz: int = maxi(0, int(local_hit.z / BLOCK_SIZE + _num_z * 0.5 - r_blocks))
	var max_bz: int = mini(_num_z, int(local_hit.z / BLOCK_SIZE + _num_z * 0.5 + r_blocks) + 1)
	for bx in range(min_bx, max_bx):
		for by in range(min_by, max_by):
			for bz in range(min_bz, max_bz):
				var idx := bx * ny_nz + by * _num_z + bz
				if idx >= grid_size:
					continue
				if _anchor_bond_broken[idx] != 0:
					continue
				if _ground_mask[idx] != 1 or _block_grid[idx] != 1:
					continue
				var bp := Vector3(
					(bx + 0.5 - _num_x * 0.5) * BLOCK_SIZE,
					(by + 0.5 - _num_y * 0.5) * BLOCK_SIZE,
					(bz + 0.5 - _num_z * 0.5) * BLOCK_SIZE)
				var d := local_hit.distance_to(bp)
				if d > radius:
					continue
				var norm_d := d * inv_radius
				var falloff: float = 1.0 / (1.0 + (norm_d * 3.0) ** 3)
				_anchor_bond_damage[idx] += energy * falloff
				if _anchor_bond_damage[idx] >= _anchor_bond_strength[idx]:
					_anchor_bond_broken[idx] = 1
					broken += 1
	return broken


func _bond_world_midpoint(block_grid_idx: int, axis: int) -> Vector3:
	## World-space midpoint of a bond, useful for distance checks during
	## radial damage application.
	var rem := block_grid_idx % (_num_y * _num_z)
	var bx := block_grid_idx / (_num_y * _num_z)
	var by := rem / _num_z
	var bz := rem % _num_z
	var local := _block_local_pos(Vector3i(bx, by, bz))
	# Offset toward +axis neighbor by half a block.
	var off := 0.5 * BLOCK_SIZE
	if axis == _BOND_AXIS_X:
		local.x += off
	elif axis == _BOND_AXIS_Y:
		local.y += off
	else:
		local.z += off
	return global_transform * local


func damage_bonds_in_radius(world_pos: Vector3, energy: float, radius: float) -> int:
	## Apply radial bond damage with DDA voxel-walk shielding. Each bond inside
	## the blast radius gets `energy × cubic_falloff(d) − absorbed_along_ray`
	## damage; absorption is the sum of block HPs the ray crosses on its way
	## from blast → bond. Offloaded to C++ (BlockMeshBuilder.damage_bonds_radial_shielded).
	## Returns the number of bonds that broke this call (for diagnostics).
	if radius <= 0.0 or energy <= 0.0:
		return 0
	if _bond_strength.is_empty():
		return 0

	# C++ kernel works in the structure's LOCAL coordinates.
	var hit_local: Vector3 = global_transform.affine_inverse() * world_pos
	var result: Dictionary = BlockMeshBuilder.damage_bonds_radial_shielded(
		_block_grid, _bond_strength, _bond_damage, _bond_broken,
		_num_x, _num_y, _num_z, BLOCK_SIZE,
		hit_local, energy, radius, _block_hp)

	_bond_damage = result["bond_damage"]
	_bond_broken = result["bond_broken"]
	var broken: int = result["broken"]
	var damaged: int = result["damaged"]

	# Same blast also damages terrain anchors. Without this, the foundation
	# can't fragment — every foundation block is its own BFS seed and BFS
	# never sees an "unsupported" component. Anchors break with the same
	# falloff curve, so a direct hit reliably tears the foundation.
	var anchor_broken := _damage_anchors_in_radius(world_pos, energy, radius)

	if damaged > 0 or broken > 0 or anchor_broken > 0:
		# Bond capacities changed (κ = 1 − damage/strength) — the next
		# integrity check must re-run the gravity stress solve.
		_gravity_stress_dirty = true
		GameManager.plog("[BondGraph] %s blast pos=%s energy=%.1f r=%.1f → damaged=%d broken=%d anchor_broken=%d" % [
			name, str(world_pos).substr(0, 30), energy, radius, damaged, broken, anchor_broken])

	return broken


func _damage_bonds_at_block(key: Vector3i, energy: float) -> int:
	## Apply `energy` damage to every intact bond touching the block at `key`.
	## Used by the bullet path: a hitscan hit damages local bonds in addition
	## to dealing block HP damage. Returns the number of bonds that broke.
	if energy <= 0.0 or _bond_strength.is_empty():
		return 0
	_gravity_stress_dirty = true  # capacities shrink even when nothing breaks
	var here_idx := _grid_idx(key.x, key.y, key.z)
	var broken := 0

	# This block's own +X/+Y/+Z bonds.
	for axis in 3:
		var bi := here_idx * 3 + axis
		if _bond_broken[bi] != 0:
			continue
		_bond_damage[bi] += energy
		if _bond_damage[bi] >= _bond_strength[bi]:
			_bond_broken[bi] = 1
			broken += 1

	# Neighbor-owned bonds (-X/-Y/-Z).
	if key.x > 0:
		var bi := _grid_idx(key.x - 1, key.y, key.z) * 3 + _BOND_AXIS_X
		if _bond_broken[bi] == 0:
			_bond_damage[bi] += energy
			if _bond_damage[bi] >= _bond_strength[bi]:
				_bond_broken[bi] = 1
				broken += 1
	if key.y > 0:
		var bi := _grid_idx(key.x, key.y - 1, key.z) * 3 + _BOND_AXIS_Y
		if _bond_broken[bi] == 0:
			_bond_damage[bi] += energy
			if _bond_damage[bi] >= _bond_strength[bi]:
				_bond_broken[bi] = 1
				broken += 1
	if key.z > 0:
		var bi := _grid_idx(key.x, key.y, key.z - 1) * 3 + _BOND_AXIS_Z
		if _bond_broken[bi] == 0:
			_bond_damage[bi] += energy
			if _bond_damage[bi] >= _bond_strength[bi]:
				_bond_broken[bi] = 1
				broken += 1

	# Also damage the block's terrain anchor (if it has one). A bullet hitting
	# a foundation block weakens its anchor, same way it weakens its bonds to
	# neighbors.
	var here_grid_idx := here_idx
	if here_grid_idx < _anchor_bond_strength.size() and _anchor_bond_broken[here_grid_idx] == 0:
		_anchor_bond_damage[here_grid_idx] += energy
		if _anchor_bond_damage[here_grid_idx] >= _anchor_bond_strength[here_grid_idx]:
			_anchor_bond_broken[here_grid_idx] = 1

	return broken


func _break_block_bonds(key: Vector3i) -> int:
	## When a block is destroyed (HP→0), all 6 bonds touching it must break.
	## 3 are owned by this block (+X, +Y, +Z); 3 are owned by lower-indexed
	## neighbors (-X, -Y, -Z). Returns the number of bonds newly broken.
	if _bond_strength.is_empty():
		return 0
	_gravity_stress_dirty = true  # topology changed — loads redistribute
	var here_idx := _grid_idx(key.x, key.y, key.z)
	var broken := 0

	# This block's own bonds.
	for axis in 3:
		var bi := here_idx * 3 + axis
		if _bond_broken[bi] == 0:
			_bond_broken[bi] = 1
			broken += 1

	# Neighbor-owned bonds (the -X, -Y, -Z directions).
	if key.x > 0:
		var nidx := _grid_idx(key.x - 1, key.y, key.z)
		var bi := nidx * 3 + _BOND_AXIS_X
		if _bond_broken[bi] == 0:
			_bond_broken[bi] = 1
			broken += 1
	if key.y > 0:
		var nidx := _grid_idx(key.x, key.y - 1, key.z)
		var bi := nidx * 3 + _BOND_AXIS_Y
		if _bond_broken[bi] == 0:
			_bond_broken[bi] = 1
			broken += 1
	if key.z > 0:
		var nidx := _grid_idx(key.x, key.y, key.z - 1)
		var bi := nidx * 3 + _BOND_AXIS_Z
		if _bond_broken[bi] == 0:
			_bond_broken[bi] = 1
			broken += 1

	return broken


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

	# Initialize bond graph from the populated block grid. Each pair of
	# adjacent occupied blocks gets a bond at the canonical lower-block side.
	_init_bond_graph()

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
		GameManager.plog("[StructureReady] %s  blocks=%d  spawn_blocks=%dus  greedy_mesh=%dus  smooth_col=%dus  total=%dus%s" % [
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
	# A gravity solve may still be queued/running on the StressSolver thread;
	# it holds COW snapshots, not references to this node. Cancel so the
	# result is discarded instead of accumulating in the solver's table.
	if _gravity_task_id >= 0:
		StressSolver.cancel(_gravity_task_id)
		_gravity_task_id = -1
	for rid in _smooth_shape_rids:
		if rid.is_valid():
			PhysicsServer3D.free_rid(rid)
	_smooth_shape_rids.clear()


func _process(_delta: float) -> void:
	Profiler.begin("destructible_mesh")
	# Deferred mesh rebuild: blocks were destroyed, rebuild once then sleep
	if _mesh_dirty:
		_mesh_dirty = false
		var t_mesh := Time.get_ticks_usec()
		_rebuild_greedy_mesh()
		var t_mesh_end := Time.get_ticks_usec()
		var _mesh_us := t_mesh_end - t_mesh
		GameManager.plog("[GreedyMesh] %s  blocks=%d  time=%dus" % [name, _block_hp_dict.size(), _mesh_us])
		GameManager.frame_add("greedy_mesh", _mesh_us)
		set_process(false)
	Profiler.end("destructible_mesh")


const DETACH_FALL_GRAVITY := 17.5  ## Same as player gravity (m/s²)

func _physics_process(delta: float) -> void:
	Profiler.begin("destructible_physics")
	if _foundation_pending:
		_foundation_pending = false
		_deferred_build_foundation()
		if not _is_falling and _gravity_task_id < 0:
			set_physics_process(false)
			Profiler.end("destructible_physics")
			return
	if _gravity_task_id >= 0:
		_poll_gravity_solve()
	if not _is_falling:
		if _gravity_task_id < 0:
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


func _diag_identify_shielders(space_state: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude_rids: Array[RID], target_key: Vector3i) -> void:
	## Cast intersect_ray_all along the explosion→block path and log every body hit.
	if not space_state:
		return
	var q := PhysicsRayQueryParameters3D.new()
	q.from = from
	q.to = to
	q.collision_mask = CollisionLayers.SHIELDING
	q.exclude = exclude_rids
	var hits := space_state.intersect_ray_all(q, 32)
	var compound_rid: RID = _compound_hit_body.get_rid() if (_compound_hit_body and is_instance_valid(_compound_hit_body)) else RID()
	print("[ShieldDiag]     ray %s→%s  %d hits:" % [
		str(from).substr(0, 25), str(to).substr(0, 25), hits.size()])
	for hit in hits:
		var collider: Object = hit.get("collider")
		var rid: RID = hit.get("rid", RID())
		var pos: Vector3 = hit.get("position", Vector3.ZERO)
		var shp := PhysicsServer3D.body_get_shielding_hp(rid) if rid.is_valid() else 0.0
		var is_self := rid == compound_rid
		var cname: String = collider.name if collider else "null"
		var cclass: String = collider.get_class() if collider else "null"
		var layer: int = collider.collision_layer if collider is CollisionObject3D else 0
		print("[ShieldDiag]       %s (%s) layer=%d shp_hp=%.1f rid=%s %s pos=%s" % [
			cname, cclass, layer, shp, str(rid).substr(0, 15),
			"<<SELF>>" if is_self else "", str(pos).substr(0, 25)])
	if hits.is_empty():
		print("[ShieldDiag]       NO HITS (mask=%d)" % CollisionLayers.SHIELDING)


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
	if not bonds_only_destruction:
		_block_hp_dict[key] -= amount
		_update_compound_shielding_hp()

	# Bullet bond damage: every shot that lands on a block also damages the
	# bonds touching it. Small per-hit damage, so a wall takes several rounds
	# to weaken. Independent of block HP — bonds may break before the block
	# itself dies, producing the "loosened wall" effect.
	if amount > 0.0 and bond_damage_bullet_factor > 0.0 and not _bond_strength.is_empty():
		var bullet_energy: float = amount * bond_damage_bullet_factor
		var _broken := _damage_bonds_at_block(key, bullet_energy)
		if _broken > 0:
			GameManager.plog("[BondGraph] %s bullet key=%s energy=%.1f broke=%d" % [
				name, str(key), bullet_energy, _broken])

	# Bonds-only mode: never let HP drive destruction; queue a connectivity
	# check so any newly-disconnected chunks fall.
	if bonds_only_destruction:
		if not _integrity_check_pending:
			_integrity_check_pending = true
			call_deferred("_deferred_integrity_check")
		Profiler.end("struct_damage_block")
		return

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
		_mark_dirty_stress_seed(key)
		_break_block_bonds(key)
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
		GameManager.plog("[PERF] _damage_block %s key=%s: disable=%dus smooth_col=%dus rpc=%dus debris=%dus total=%dus blocks=%d" % [
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
		GameManager.plog("[PERF] _sync_block_destroyed(client) %s key=%s: total=%dus blocks=%d" % [
			name, str(key), _t_sync_us, _block_hp_dict.size()])


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float, _attacker_id: int, exclude_rids: Array[RID] = [], impact_speed: float = INF) -> void:
	## Damage blocks within blast_radius of hit_pos. Only blocks in range take damage.
	## Shielding uses flat HP absorption: each wall block or player between the
	## explosion and a target block absorbs damage equal to its current HP.
	## exclude_rids: physics bodies to ignore in shielding raycasts (e.g. the rocket).
	Profiler.begin("struct_take_damage_at")
	GameManager.plog("[TakeDamageAt-ENTRY] %s  blocks=%d  is_server=%s  hit_pos=%s  global_pos=%s" % [
		name, _block_hp_dict.size(), str(multiplayer.is_server()), str(hit_pos), str(global_position)])
	if not multiplayer.is_server():
		Profiler.end("struct_take_damage_at")
		return

	_last_attacker_id = _attacker_id
	var t_total := Time.get_ticks_usec()

	var space_state := get_world_3d().direct_space_state
	var debug_rays := GameManager.debug_show_explosion_rays

	var destroyed_keys: Array[Vector3i] = []
	var destroyed_positions: Array[Vector3] = []
	var destroyed_overkill: Array[float] = []
	var debug_ray_data: Array = []
	# Snapshot block HPs before C++ modifies them (for debug ray visualization).
	var _dbg_old_hp: Dictionary = _block_hp_dict.duplicate() if debug_rays else {}

	# C++ computes damage, shielding, applies HP, and returns destroyed/survived info.
	var explosion_result: Dictionary = {}

	var t_pass1 := Time.get_ticks_usec()
	var t_query_setup := Time.get_ticks_usec()
	var query: PhysicsRayQueryParameters3D = null
	if space_state and not bonds_only_destruction:
		query = ExplosionHelper._make_shielding_query(hit_pos, exclude_rids)
	var t_query_setup_end := Time.get_ticks_usec()
	var t_calc_explosion := Time.get_ticks_usec()
	if space_state and not bonds_only_destruction:
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

	# Generate debug ray data directly from C++ results (ground truth).
	if debug_rays and not explosion_result.is_empty():
		var diag := GameManager.debug_explosion_diagnostics
		var self_shield: float = explosion_result.get("self_shield", 0.0)
		var shielded_out: int = explosion_result.get("shielded_out", 0)
		if diag:
			print("[ShieldDiag] %s  self_shield=%.2f  shielded_out=%d" % [name, self_shield, shielded_out])

		# Destroyed blocks: C++ provides raw_dmg, final_dmg, raw absorption per block
		var d_keys: Array = explosion_result.get("destroyed_keys", [])
		var d_raw: PackedFloat32Array = explosion_result.get("destroyed_raw_dmg", PackedFloat32Array())
		var d_final: PackedFloat32Array = explosion_result.get("destroyed_final_dmg", PackedFloat32Array())
		var d_abs: PackedFloat32Array = explosion_result.get("destroyed_abs", PackedFloat32Array())
		for i in d_keys.size():
			var block_pos: Vector3 = global_transform * _block_local_pos(d_keys[i])
			debug_ray_data.append({
				"from": hit_pos, "to": block_pos,
				"raw_dmg": d_raw[i], "final_dmg": d_final[i],
				"hits": [],
			})
			# Log blocks where shielding is unexpectedly high + identify what's shielding
			if diag and d_raw[i] > 0.0 and d_final[i] < d_raw[i] - 0.01:
				var ray_abs_val: float = d_abs[i] if d_abs.size() > i else -1.0
				var effective_abs: float = maxf(ray_abs_val - self_shield, 0.0) if ray_abs_val >= 0.0 else -1.0
				print("[ShieldDiag]   DESTROYED %s  raw=%.1f  final=%.1f  absorbed=%.1f  ray_abs=%.1f  eff_abs=%.1f  self_shield=%.1f" % [
					str(d_keys[i]), d_raw[i], d_final[i], d_raw[i] - d_final[i],
					ray_abs_val, effective_abs, self_shield])
				_diag_identify_shielders(space_state, hit_pos, block_pos, exclude_rids, d_keys[i])

		# Survived blocks: C++ provides raw_dmg, final_dmg, raw absorption per block
		var s_keys_dbg: Array = explosion_result.get("survived_keys", [])
		var s_raw: PackedFloat32Array = explosion_result.get("survived_raw_dmg", PackedFloat32Array())
		var s_final: PackedFloat32Array = explosion_result.get("survived_final_dmg", PackedFloat32Array())
		var s_abs: PackedFloat32Array = explosion_result.get("survived_abs", PackedFloat32Array())
		for i in s_keys_dbg.size():
			var block_pos: Vector3 = global_transform * _block_local_pos(s_keys_dbg[i])
			debug_ray_data.append({
				"from": hit_pos, "to": block_pos,
				"raw_dmg": s_raw[i], "final_dmg": s_final[i],
				"hits": [],
			})
			if diag and s_raw[i] > 0.0 and s_final[i] < s_raw[i] - 0.01:
				var ray_abs_val: float = s_abs[i] if s_abs.size() > i else -1.0
				var effective_abs: float = maxf(ray_abs_val - self_shield, 0.0) if ray_abs_val >= 0.0 else -1.0
				print("[ShieldDiag]   SURVIVED %s  raw=%.1f  final=%.1f  absorbed=%.1f  ray_abs=%.1f  eff_abs=%.1f  self_shield=%.1f" % [
					str(s_keys_dbg[i]), s_raw[i], s_final[i], s_raw[i] - s_final[i],
					ray_abs_val, effective_abs, self_shield])
				_diag_identify_shielders(space_state, hit_pos, block_pos, exclude_rids, s_keys_dbg[i])

		# Blocks in range but not in either list = fully shielded (final_dmg < 0.5)
		var _dbg_hit: Dictionary = {}
		for k in d_keys:
			_dbg_hit[k] = true
		for k in s_keys_dbg:
			_dbg_hit[k] = true
		for key: Vector3i in _dbg_old_hp:
			if _dbg_hit.has(key):
				continue
			var block_pos: Vector3 = global_transform * _block_local_pos(key)
			var dist := hit_pos.distance_to(block_pos)
			if dist > blast_radius:
				continue
			var norm_dist := dist / blast_radius
			var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
			debug_ray_data.append({
				"from": hit_pos, "to": block_pos,
				"raw_dmg": amount * falloff, "final_dmg": 0.0,
				"hits": [],
			})

	# Erase destroyed blocks — disable compound body shapes (instant vs queue_free).
	var t_erase := Time.get_ticks_usec()
	if destroyed_keys.size() > 0 and _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
	for i in destroyed_keys.size():
		var key: Vector3i = destroyed_keys[i]
		_disable_hit_shape(key)
		_block_hp_dict.erase(key)
		_clear_block_grids(key.x, key.y, key.z)
		_mark_dirty_stress_seed(key)
		# Block destruction cascades to bond breaks: all 6 bonds touching
		# this block are now broken.
		_break_block_bonds(key)
	if destroyed_keys.size() > 0 and _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
	var t_erase_end := Time.get_ticks_usec()

	# Damage bonds in the blast radius. Bonds may break on intact blocks too,
	# producing the "weakened wall" effect — connectivity check after this
	# call will detect any chunks now disconnected from ground.
	if amount > 0.0 and blast_radius > 0.0:
		var bond_energy: float = amount * bond_damage_explosion_factor
		damage_bonds_in_radius(hit_pos, bond_energy, blast_radius)

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

	# Batch structural integrity check after all blocks destroyed this frame.
	# In bonds-only mode, always run it — bonds may have broken even though
	# no blocks died directly.
	var t_integrity := Time.get_ticks_usec()
	if destroyed_keys.size() > 0 or bonds_only_destruction:
		_check_structural_integrity()
	var t_integrity_end := Time.get_ticks_usec()

	var t_total_end := Time.get_ticks_usec()
	var _total_us := t_total_end - t_total
	GameManager.plog("[TakeDamageAt] %s  blocks=%d  pass1=%dus(query=%d calc=%d)  erase=%dus  debris=%dus(rpcs=%d spawned=%d rpc_time=%d spawn_time=%d)  collision=%dus  integrity=%dus  destroyed=%d  total=%dus" % [
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

	# Apply damage (HP path skipped in bonds-only mode)
	if not bonds_only_destruction:
		_block_hp_dict[target_key] -= damage

	# Bond damage: localized to the impact point. Heavy/fast collisions
	# weaken nearby supports regardless of whether this single block dies.
	if damage > 0.0 and bond_damage_momentum_factor > 0.0 and not _bond_strength.is_empty():
		var momentum_energy: float = damage * bond_damage_momentum_factor
		damage_bonds_in_radius(hit_world_pos, momentum_energy, bond_damage_momentum_radius)

	# Bonds-only: never destroy blocks here. Queue a connectivity check so any
	# newly-detached chunks fall this frame. Block returns "not destroyed" — the
	# caller treats the impact as fully absorbed by the structure.
	if bonds_only_destruction:
		if not _integrity_check_pending:
			_integrity_check_pending = true
			call_deferred("_deferred_integrity_check")
		var block_pos_local := _block_local_pos(target_key)
		Profiler.end("struct_momentum_dmg")
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": target_key, "block_pos": global_transform * block_pos_local }

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
	_break_block_bonds(target_key)
	_block_hp_dict.erase(target_key)
	_clear_block_grids(target_key.x, target_key.y, target_key.z)
	_mark_dirty_stress_seed(target_key)
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
	GameManager.plog("[PERF] take_momentum_damage_at %s key=%s: search=%dus erase=%dus smooth_col=%dus rpc=%dus debris=%dus total=%dus blocks=%d" % [
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
	GameManager.plog("[PERF] _deferred_integrity_check %s: %dus  blocks=%d" % [name, us, _block_hp_dict.size()])
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

## When true, every Nth integrity check does a full solve and asserts the
## persistent state matches what localized would have produced. Set to 0
## to disable. Set to 1 to validate every call (very expensive).
var stress_validate_every: int = 0
var _stress_validate_counter: int = 0


func _mark_dirty_stress_seed(key: Vector3i) -> void:
	## Append a destroyed block's flat index to the dirty-seed list. The next
	## _check_structural_integrity() call will use these as seeds for the
	## localized solver. Safe to call before or after the block is erased
	## from _block_grid; only the index is needed.
	_stress_dirty_seeds.append(_grid_idx(key.x, key.y, key.z))


func _start_gravity_solve() -> void:
	## Queue the gravity solve on StressSolver's dedicated thread. NOT on
	## WorkerThreadPool: long solves there starved Jolt physics jobs and
	## terrain chunk meshing (micro-stutter + map holes). The job dict holds
	## COW snapshots — main-thread writes during the solve fork the buffers,
	## the worker keeps reading its consistent snapshot — and carries no
	## reference to this node, so freeing mid-solve is safe (see cancel()).
	_gravity_task_id = StressSolver.submit_solve({
		"grid": _block_grid,
		"mask": _ground_mask,
		"bond_strength": _bond_strength,
		"bond_damage": _bond_damage,
		"bond_broken": _bond_broken,
		"anchor_strength": _anchor_bond_strength,
		"anchor_damage": _anchor_bond_damage,
		"anchor_broken": _anchor_bond_broken,
		"nx": _num_x, "ny": _num_y, "nz": _num_z,
		"gravity": (global_transform.basis.inverse() * Vector3.DOWN).normalized(),
		"params": {
			"tension": stress_tension_blocks,
			"compression": stress_compression_blocks,
			"shear": stress_shear_blocks,
			# Failure decisions need ~1% accuracy on utilization. Measured on
			# the 17k-block house: maxU differs by 1e-4 between tol=1e-6 and
			# 1e-3, while the solve drops 179ms → 105ms. The kernel's 1e-6
			# default stays for the validation suite.
			"tolerance": 1.0e-3,
		},
	})
	set_physics_process(true)


func _poll_gravity_solve() -> void:
	## Called from _physics_process while a solve job is in flight.
	var gs: Dictionary = StressSolver.take_result(_gravity_task_id)
	if gs.is_empty():
		return
	_gravity_task_id = -1
	if not gs["converged"]:
		push_warning("[GravityStress] %s CG did not converge (blocks=%d) — using best iterate" % [
			name, _block_hp_dict.size()])
	GameManager.tick_add("gravity_stress", int(gs.get("solve_us", 0)))
	var gs_bonds: int = gs["broke_bonds"]
	var gs_anchors: int = gs["broke_anchors"]
	if gs_bonds > 0 or gs_anchors > 0:
		GameManager.plog("[GravityStress] %s broke bonds=%d anchors=%d maxU=%.2f cg=%d passes=%d %dus (async)" % [
			name, gs_bonds, gs_anchors, float(gs["max_utilization"]),
			int(gs["cg_iters"]), int(gs["passes"]), int(gs.get("solve_us", 0))])
		# OR-merge: the solver only sets broken flags, and damage that arrived
		# during the solve only ADDS broken flags — union is always correct.
		var nb: PackedByteArray = gs["bond_broken"]
		if nb.size() == _bond_broken.size():
			_bond_broken = BlockMeshBuilder.or_byte_arrays(_bond_broken, nb)
		var na: PackedByteArray = gs["anchor_broken"]
		if na.size() == _anchor_bond_broken.size():
			_anchor_bond_broken = BlockMeshBuilder.or_byte_arrays(_anchor_bond_broken, na)
		# Breaks change the load paths — follow-on failures possible. Re-dirty
		# and re-check: the connectivity pass detaches what came loose and the
		# next solve continues the cascade.
		_gravity_stress_dirty = true
	if _gravity_stress_dirty and not _integrity_check_pending:
		_integrity_check_pending = true
		call_deferred("_deferred_integrity_check")


func _check_structural_integrity() -> void:
	## Server-only: force-equilibrium stress solver + connectivity check.
	## Finds blocks that are either disconnected from ground OR cannot be
	## held in static equilibrium within material strength limits.
	##
	## Uses the localized solver: persistent contact stress is reused across
	## calls, and only blocks adjacent to recently-destroyed seeds (tracked
	## via _stress_dirty_seeds) get re-propagated. Falls back to a full solve
	## when persistent state is empty/stale, when the active set explodes,
	## or when topology changes beyond destruction.
	if not multiplayer.is_server():
		return
	if _block_hp_dict.is_empty():
		return
	if _is_detached_structure:
		return
	if _foundation_pending:
		# _ground_mask is still zero-initialized; solver would treat all blocks
		# as unanchored and detach the entire structure. Skip until the first
		# physics tick has populated it via _deferred_build_foundation().
		return

	Profiler.begin("struct_integrity")
	var t_si_total := Time.get_ticks_usec()

	# ── Gravity stress solve (see GRAVITY_STRESS_PLAN.md) ──
	# Elastic-brittle interface analysis: breaks bonds/anchors whose static
	# load under gravity exceeds remaining capacity. Detects instability in
	# UNDAMAGED structures too (bad overhangs, top-heavy builds). Runs ASYNC
	# on a worker thread; the result merges in _physics_process a frame or
	# two later and re-queues this check, so collapse cascades over frames
	# with near-zero main-thread cost instead of a single giant spike.
	if GameManager.gravity_stress_enabled and _gravity_stress_dirty \
			and not _bond_strength.is_empty() and _gravity_task_id < 0:
		_gravity_stress_dirty = false
		_start_gravity_solve()

	# Bond-graph connectivity check: BFS from ground anchors, traversing only
	# intact bonds. Disconnected blocks become components and detach. Damage
	# breaks bonds via the explosion / bullet / momentum paths; the gravity
	# solve above breaks them from static overload. See BOND_GRAPH_PLAN.md.
	#
	# Effective ground mask: a block is anchored only if its terrain bond is
	# still intact. Once an anchor breaks (tracked in _anchor_bond_broken),
	# the block is no longer a BFS seed and can be torn loose like any block.
	var effective_ground_mask: PackedByteArray = _ground_mask
	if not _anchor_bond_broken.is_empty():
		effective_ground_mask = _ground_mask.duplicate()
		var n := effective_ground_mask.size()
		for i in n:
			if _anchor_bond_broken[i] != 0:
				effective_ground_mask[i] = 0
	var _t_solver := Time.get_ticks_usec()
	var components: Array = BlockMeshBuilder.calc_bond_connectivity_components(
		_block_grid, effective_ground_mask, _bond_broken,
		_num_x, _num_y, _num_z, _block_hp_dict.size())
	var _t_solver_us := Time.get_ticks_usec() - _t_solver

	if components.is_empty():
		GameManager.tick_add("structural_integrity", Time.get_ticks_usec() - t_si_total)
		Profiler.end("struct_integrity")
		return

	var t_detach := Time.get_ticks_usec()
	_detach_clusters(components)
	var t_detach_end := Time.get_ticks_usec()

	var si_us := Time.get_ticks_usec() - t_si_total
	GameManager.plog("[StructuralIntegrity] %s  blocks=%d  components=%d  solver=%dus  detach=%dus  total=%dus" % [
		name, _block_hp_dict.size(), components.size(),
		_t_solver_us, t_detach_end - t_detach, si_us,
	])
	GameManager.tick_add("structural_integrity", si_us)
	Profiler.end("struct_integrity")


func _validate_stress_against_full(localized_components: Array) -> void:
	## Run the full solver and compare component sets. Triggers a push_error if
	## they diverge — used during development to catch persistent-state bugs.
	var full_components: Array = BlockMeshBuilder.calc_stress_integrity_components(
		_block_grid, _ground_mask, PackedFloat32Array(),
		_num_x, _num_y, _num_z, _block_hp_dict.size(),
		stress_max_load, stress_horizontal_transfer)

	# Compare by total block count and component sizes (sorted).
	var local_blocks: int = 0
	var local_sizes: Array[int] = []
	for c: Array in localized_components:
		local_sizes.append(c.size())
		local_blocks += c.size()
	var full_blocks: int = 0
	var full_sizes: Array[int] = []
	for c: Array in full_components:
		full_sizes.append(c.size())
		full_blocks += c.size()
	local_sizes.sort()
	full_sizes.sort()

	if local_blocks != full_blocks or local_sizes != full_sizes:
		push_error("[StressValidate] DIVERGENCE on %s: localized=%d blocks in %s components, full=%d blocks in %s components" % [
			name, local_blocks, str(local_sizes), full_blocks, str(full_sizes)])
		# Reset persistent state so next call re-establishes a clean baseline.
		_stress_persistent_state = {}
	else:
		GameManager.plog("[StressValidate] OK on %s: %d components, %d blocks" % [
			name, localized_components.size(), local_blocks])


func _split_component_by_material(keys: Array[Vector3i]) -> Array:
	## Partition a detached component into connected single-material pieces.
	## Foundation (stone) and wall blocks never share a falling cluster — each
	## piece keeps its true material instead of the majority-vote repaint.
	## Returns Array of { "keys": Array[Vector3i], "is_foundation": bool }.
	if _foundation_grid.size() != _block_grid.size():
		return [{ "keys": keys, "is_foundation": false }]
	var fkeys: Array[Vector3i] = []
	var wkeys: Array[Vector3i] = []
	for key in keys:
		if _foundation_grid[_grid_idx(key.x, key.y, key.z)] == 1:
			fkeys.append(key)
		else:
			wkeys.append(key)
	if fkeys.is_empty():
		return [{ "keys": wkeys, "is_foundation": false }]
	if wkeys.is_empty():
		return [{ "keys": fkeys, "is_foundation": true }]
	# Mixed: removing the other material can disconnect a part (e.g. two
	# stone feet joined only through the wall above), so each side splits
	# into its own connected subsets.
	var parts: Array = []
	for sub: Array in _connected_subsets(fkeys):
		parts.append({ "keys": sub, "is_foundation": true })
	for sub: Array in _connected_subsets(wkeys):
		parts.append({ "keys": sub, "is_foundation": false })
	return parts


func _connected_subsets(keys: Array[Vector3i]) -> Array:
	## 6-adjacency connected components restricted to `keys`.
	var remaining: Dictionary = {}
	for key in keys:
		remaining[key] = true
	var out: Array = []
	while not remaining.is_empty():
		var seed_key: Vector3i = remaining.keys()[0]
		remaining.erase(seed_key)
		var comp: Array[Vector3i] = [seed_key]
		var qi := 0
		while qi < comp.size():
			var cur := comp[qi]
			qi += 1
			for off in NEIGHBOR_OFFSETS:
				var nb := cur + off
				if remaining.has(nb):
					remaining.erase(nb)
					comp.append(nb)
		out.append(comp)
	return out


func _detach_clusters(components: Array) -> void:
	## Batch-detach all unsupported components in a single bulk-mode session.
	## Enters bulk mode ONCE for compound hit body and smooth collision body,
	## deduplicates column rebuilds across all components, single shielding update.
	var t_total := Time.get_ticks_usec()

	# ── Collect per-component data (centroids, valid keys, HPs) ──
	var t_collect := Time.get_ticks_usec()
	var cluster_data: Array = []  # Array of {keys, hps, centroid_world, mass}
	var all_valid_keys: Array[Vector3i] = []

	# Single-block components are dispatched to FragmentPool (multimesh-backed
	# indestructible debris). They make up most of a typical detach event but
	# don't need a full FallingBlockCluster's compound hit body, bond graph,
	# or settle logic.
	var fragment_positions := PackedVector3Array()
	var fragment_colors := PackedColorArray()

	var wall_color: Color = _structure_material.albedo_color if _structure_material else Color(0.7, 0.55, 0.35)
	var stone_color: Color = Color(0.55, 0.55, 0.50)
	for component in components:
		var valid_keys: Array[Vector3i] = []
		for key in component:
			if _block_hp_dict.has(key):
				valid_keys.append(key)
		if valid_keys.is_empty():
			continue
		all_valid_keys.append_array(valid_keys)

		# A cluster renders with exactly ONE material, so a mixed
		# foundation+wall chunk would repaint its minority blocks on detach
		# (the color-transmute bug — resurfaced when the gravity stress solver
		# started breaking structures at their supports, where stone meets
		# wall). Cleave mixed components along the material interface into
		# connected single-material pieces instead. Pure components (the
		# common case) come back as a single part, no extra work.
		for part: Dictionary in _split_component_by_material(valid_keys):
			var pkeys: Array[Vector3i] = part["keys"]
			var is_foundation: bool = part["is_foundation"]
			var centroid_local := Vector3.ZERO
			var block_hps: Array[float] = []
			for key in pkeys:
				centroid_local += _block_local_pos(key)
				block_hps.append(_block_hp_dict[key])
			centroid_local /= float(pkeys.size())
			var centroid_world: Vector3 = global_transform * centroid_local

			# Fast path: single block becomes a multimesh fragment instead of a
			# full RigidBody3D + StaticBody3D + MeshInstance3D cluster. Saves
			# 30-70us of GDScript node-creation + add_child time per fragment.
			if pkeys.size() == 1:
				fragment_positions.append(centroid_world)
				fragment_colors.append(stone_color if is_foundation else wall_color)
				continue

			cluster_data.append({
				"keys": pkeys,
				"hps": block_hps,
				"centroid": centroid_world,
				"mass": pkeys.size() * _get_block_mass(),
				"is_foundation": is_foundation,
			})
	var t_collect_end := Time.get_ticks_usec()

	if cluster_data.is_empty() and fragment_positions.is_empty():
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
	if not cluster_data.is_empty():
		var all_keys: Array = []
		var all_hps: Array = []
		var all_centroids := PackedVector3Array()
		var all_masses := PackedFloat32Array()
		var all_is_foundation := PackedByteArray()
		all_centroids.resize(cluster_data.size())
		all_masses.resize(cluster_data.size())
		all_is_foundation.resize(cluster_data.size())
		for i in cluster_data.size():
			all_keys.append(cluster_data[i]["keys"])
			all_hps.append(cluster_data[i]["hps"])
			all_centroids[i] = cluster_data[i]["centroid"]
			all_masses[i] = cluster_data[i]["mass"]
			all_is_foundation[i] = 1 if cluster_data[i]["is_foundation"] else 0
		_sync_cluster_detach_batch.rpc(all_keys, all_hps, all_centroids, all_masses,
			_last_attacker_id, _num_x, _num_y, _num_z, _get_block_mass(),
			all_is_foundation, ClusterSync.allocate_ids(cluster_data.size()))

	# Fragments (single-block components) go to the multimesh pool. Same RPC
	# pattern (call_local) so server and clients each spawn into their own pool.
	# attacker_id and per-block HP are tracked server-side for damage routing.
	if not fragment_positions.is_empty():
		_sync_fragment_spawn_batch.rpc(fragment_positions, fragment_colors,
			_block_hp, _last_attacker_id)
	var t_rpc_end := Time.get_ticks_usec()

	var t_total_us := Time.get_ticks_usec() - t_total
	GameManager.tick_add("detach_clusters", t_total_us)
	GameManager.plog("[DetachClusters] %s  components=%d  blocks=%d  collect=%dus  erase=%dus  collision=%dus  rpc=%dus  total=%dus" % [
		name, cluster_data.size(), all_valid_keys.size(),
		t_collect_end - t_collect,
		t_erase_end - t_erase,
		t_col_end - t_col,
		t_rpc_end - t_rpc,
		t_total_us,
	])

	# Detaching removed weight and load paths — what remains may now be
	# overloaded (or relieved). Queue one more integrity check so the gravity
	# solve re-runs next frame; collapse propagates frame by frame and
	# terminates because the block count strictly decreases.
	_gravity_stress_dirty = true
	if not _integrity_check_pending:
		_integrity_check_pending = true
		call_deferred("_deferred_integrity_check")


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
	GameManager.plog("[SyncClusterDetach] %s  keys=%d  client_cleanup=%dus  type_convert=%dus  spawn_structure=%dus  total=%dus" % [
		name, block_keys.size(),
		t_client_cleanup_end - t_client_cleanup,
		t_type_convert_end - t_type_convert,
		t_spawn_end - t_spawn,
		sync_total,
	])


@rpc("authority", "call_local", "reliable")
func _sync_fragment_spawn_batch(positions: PackedVector3Array,
		colors: PackedColorArray, hp: float, attacker_id: int) -> void:
	## All peers: spawn N single-block fragments via FragmentPool.
	## No bond graph, no compound hit body, no per-fragment node — each is just
	## a slot in the shared MultiMesh + a PhysicsServer3D body, but they're
	## still real game entities (server-auth physics, bullet hits, HP, free
	## on death). Used for single-block components from detach events.
	var t0 := Time.get_ticks_usec()
	var n: int = positions.size()
	# Pre-grow the pool ONCE for the full count; otherwise the per-spawn loop
	# triggers a mid-loop grow when the free list runs out, which is a
	# noticeable spike on large detach events.
	FragmentPool.ensure_capacity(n)
	for i in n:
		FragmentPool.acquire(positions[i], Vector3.ZERO, colors[i], hp, attacker_id)
	var us := Time.get_ticks_usec() - t0
	if us > 200:
		GameManager.plog("[SyncFragmentSpawn] %s  count=%d  total=%dus" % [name, n, us])


@rpc("authority", "call_local", "reliable")
func _sync_cluster_detach_batch(all_keys: Array, all_hps: Array,
		all_centroids: PackedVector3Array, all_masses: PackedFloat32Array,
		attacker_id: int, grid_num_x: int, grid_num_y: int,
		grid_num_z: int, mass_per_block: float,
		all_is_foundation: PackedByteArray = PackedByteArray(),
		all_sync_ids: PackedInt32Array = PackedInt32Array()) -> void:
	## All peers: remove ALL detached blocks once, rebuild collision once,
	## then spawn all falling clusters. Replaces N individual _sync_cluster_detach RPCs.
	## all_sync_ids: server-allocated ClusterSync ids, parallel to all_keys.
	## Clusters are named from these ids so node paths match across peers and
	## client transforms follow the server via ClusterSync.
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

	# Spawn all clusters via batched C++ call (one build_clusters_batch for all).
	var t_spawn := Time.get_ticks_usec()
	if GameManager.debug_disable_detached_structures or n_clusters == 0:
		var t_batch_us := Time.get_ticks_usec() - t_batch_total
		GameManager.plog("[SyncClusterDetachBatch] %s  clusters=%d  SKIPPED  total=%dus" % [
			name, n_clusters, t_batch_us])
		return

	var shared_hit_shape := BoxShape3D.new()
	shared_hit_shape.size = Vector3.ONE * BLOCK_SIZE
	var compound_body_script: GDScript = preload("res://world/compound_hit_body.gd")

	# Phase 1: Build HP dicts and create all cluster bodies + hit bodies (need RIDs).
	var t_create := Time.get_ticks_usec()
	var hp_dicts: Array = []
	var clusters: Array = []
	var cluster_body_rids: Array = []
	var hit_body_rids: Array = []

	# Per-cluster tight grid dims (3 ints each) for the batched C++ build.
	var cluster_dims := PackedInt32Array()
	cluster_dims.resize(n_clusters * 3)

	for i in n_clusters:
		var cluster_keys: Array = all_keys[i]
		var cluster_hps: Array = all_hps[i]
		# Rebase keys to a tight AABB. Wire keys stay in STRUCTURE grid coords
		# (the client-erase step above needs them); the rebase here runs the
		# same arithmetic on every peer, so all peers build identical cluster
		# grids. Without this, every cluster carries the FULL structure grid
		# (e.g. 21,780 cells for a 20-block chunk of the big house) through
		# its bond arrays and every downstream kernel — ~0.6MB of dead weight
		# per chunk and full-grid loop costs on every damage event.
		var kmin: Vector3i = cluster_keys[0]
		var kmax: Vector3i = cluster_keys[0]
		for key_variant in cluster_keys:
			var key: Vector3i = key_variant
			kmin = kmin.min(key)
			kmax = kmax.max(key)
		var hp_dict: Dictionary = {}
		for j in cluster_keys.size():
			hp_dict[(cluster_keys[j] as Vector3i) - kmin] = float(cluster_hps[j])
		hp_dicts.append(hp_dict)
		var tight: Vector3i = kmax - kmin + Vector3i.ONE
		cluster_dims[i * 3 + 0] = tight.x
		cluster_dims[i * 3 + 1] = tight.y
		cluster_dims[i * 3 + 2] = tight.z

		var shell: Dictionary = ClusterPool.acquire()
		var cluster: RigidBody3D = shell["rb"]
		# Deterministic name from the sync id — node paths must match across
		# peers for the cluster's own RPCs (splits, block destruction) to
		# resolve on clients. randi() fallback only for id 0 (no sync).
		var sid: int = all_sync_ids[i] if i < all_sync_ids.size() else 0
		cluster.sync_id = sid
		cluster.name = ("FallingCluster_%d" % sid) if sid != 0 \
			else ("FallingCluster_%s_%d" % [name, randi() % 10000])
		cluster.mass = all_masses[i]
		cluster.cluster_mass = all_masses[i]
		cluster.attacker_id = attacker_id
		# Constant collision/physics properties are pre-configured in
		# ClusterPool._create_shell(); skip them here.

		# Grid manager — tight rebased dims, not the parent structure's.
		cluster.grid = BlockGridManager.new()
		cluster.grid.num_x = cluster_dims[i * 3 + 0]
		cluster.grid.num_y = cluster_dims[i * 3 + 1]
		cluster.grid.num_z = cluster_dims[i * 3 + 2]
		cluster.grid.block_hp = hp_dict
		cluster._mass_per_block = mass_per_block

		# Mesh instance (from pool shell — already has script none + correct settings)
		var mesh_inst: MeshInstance3D = shell["mesh_inst"]
		cluster.add_child(mesh_inst)
		cluster._mesh_instance = mesh_inst

		# Compound hit body (from pool — script + collision layer preset)
		cluster._shared_hit_shape = shared_hit_shape
		var hit_body: StaticBody3D = shell["hit_body"]
		hit_body.parent_wall = cluster
		cluster._compound_hit_body = hit_body

		clusters.append(cluster)
		cluster_body_rids.append(cluster.get_rid())
		hit_body_rids.append(hit_body.get_rid())
	var t_create_us := Time.get_ticks_usec() - t_create

	# Phase 2: One batched C++ call — all grids, meshes, collision shapes, hit bodies.
	var t_build := Time.get_ticks_usec()
	var results: Array = BlockMeshBuilder.build_clusters_batch(
		hp_dicts, grid_num_x, grid_num_y, grid_num_z, BLOCK_SIZE,
		cluster_body_rids, hit_body_rids, shared_hit_shape.get_rid(),
		true, cluster_dims)
	var t_build_us := Time.get_ticks_usec() - t_build

	# Phase 3: Unpack results, assemble subtrees outside the scene tree.
	var t_finish := Time.get_ticks_usec()
	var structures_node := get_parent()
	var scene_root := get_tree().current_scene
	var parent_node: Node = structures_node if structures_node else scene_root

	for i in n_clusters:
		var cluster: FallingBlockCluster = clusters[i]
		var result: Dictionary = results[i]

		cluster.grid.block_grid = result["block_grid"]
		cluster.grid.centroid = result["centroid"]
		cluster._mesh_instance.mesh = result["mesh"]
		cluster._col_shapes = result["col_shapes"]
		cluster._col_shape_count = result["col_count"]

		var shape_keys: Array = result["shape_to_key"]
		cluster._shape_to_key.clear()
		cluster._key_to_shape.clear()
		for si in shape_keys.size():
			var key: Vector3i = shape_keys[si]
			cluster._shape_to_key.append(key)
			cluster._key_to_shape[key] = si
		cluster._compound_hit_body._shape_to_key = cluster._shape_to_key

		# Add hit body as child while cluster is still outside the tree (cheap).
		cluster.add_child(cluster._compound_hit_body)

		# Clusters are single-material by construction (_detach_clusters cleaves
		# mixed components along the stone/wall interface), so this material is
		# exact — no majority-vote repaint.
		var is_foundation: bool = i < all_is_foundation.size() and all_is_foundation[i] == 1
		var cluster_material: Material = _foundation_material if is_foundation else _structure_material
		if cluster_material:
			cluster.set_material(cluster_material)
		# Pool shells default to shadows OFF (fragment-scale tuning); chunks
		# torn off a shadowed structure must keep casting shadows or they
		# visibly brighten the moment they detach.
		cluster._mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		cluster.set_debris_config(_debris_size, _debris_lifetime, _debris_mass,
			_debris_name, _block_hp)

		# Propagate bond config + initialize the cluster's bond graph. Without
		# this the cluster has empty bond arrays, every damage_bonds_in_radius
		# call early-returns, and the cluster is indestructible.
		cluster._block_hp_max = _block_hp
		cluster.bonds_only_destruction = bonds_only_destruction
		cluster.bond_strength_factor = bond_strength_factor
		cluster.bond_damage_explosion_factor = bond_damage_explosion_factor
		cluster.bond_damage_bullet_factor = bond_damage_bullet_factor
		cluster.bond_damage_momentum_factor = bond_damage_momentum_factor
		cluster.bond_damage_momentum_radius = bond_damage_momentum_radius
		cluster._init_bond_graph()

	# Batch add: add all clusters to the scene tree.
	# Each add_child triggers enter_tree cascade for cluster + children.
	var t_tree := Time.get_ticks_usec()
	for i in n_clusters:
		var cluster: FallingBlockCluster = clusters[i]
		parent_node.add_child(cluster)
		cluster.global_transform = Transform3D(global_transform.basis, all_centroids[i])
		PhysicsServer3D.body_set_shielding_tag(cluster._compound_hit_body.get_rid(), 1)
		cluster._update_compound_shielding_hp()
		PhysicsServer3D.body_set_shielding_tag(cluster.get_rid(), 4)
		PhysicsServer3D.body_set_shielding_hp(cluster.get_rid(), all_masses[i] * _block_hp / mass_per_block)
	var t_tree_us := Time.get_ticks_usec() - t_tree
	var t_finish_us := Time.get_ticks_usec() - t_finish
	var t_spawn_us := Time.get_ticks_usec() - t_spawn

	var t_batch_us := Time.get_ticks_usec() - t_batch_total
	GameManager.plog("[SyncClusterDetachBatch] %s  clusters=%d  client_cleanup=%dus  create=%dus  build=%dus  finish=%dus(tree=%d)  spawn=%dus  total=%dus" % [
		name, n_clusters, t_client_cleanup_us, t_create_us, t_build_us, t_finish_us, t_tree_us, t_spawn_us, t_batch_us])


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
	GameManager.plog("[SpawnDetachedStructure] name=%s  blocks=%d  parent=%s  struct_pos=%s  sample_block_pos=%s  script=%s" % [
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

	# Build the RigidBody3D from a pre-allocated shell when available.
	var t_body := Time.get_ticks_usec()
	var shell: Dictionary = ClusterPool.acquire()
	var cluster: RigidBody3D = shell["rb"]
	cluster.name = "FallingCluster_%s_%d" % [name, randi() % 10000]
	# Hand the pool's shell parts to the cluster so init_cluster_blocks doesn't
	# have to .new() them. add_child still happens inside init.
	cluster._mesh_instance = shell["mesh_inst"]
	cluster._compound_hit_body = shell["hit_body"]
	cluster.mass = cluster_mass
	cluster.cluster_mass = cluster_mass
	cluster.attacker_id = attacker_id
	# Constant collision/physics properties pre-configured in
	# ClusterPool._create_shell(); skip them here.
	var t_body_end := Time.get_ticks_usec()

	# init_cluster_blocks handles mesh, collision shapes, AND compound hit body.
	# Propagate bond config + per-block HP BEFORE init_cluster_blocks so the
	# cluster's _init_bond_graph() reads the right strength factor.
	var t_init := Time.get_ticks_usec()
	cluster._block_hp_max = _block_hp
	cluster.bonds_only_destruction = bonds_only_destruction
	cluster.bond_strength_factor = bond_strength_factor
	cluster.bond_damage_explosion_factor = bond_damage_explosion_factor
	cluster.bond_damage_bullet_factor = bond_damage_bullet_factor
	cluster.bond_damage_momentum_factor = bond_damage_momentum_factor
	cluster.bond_damage_momentum_radius = bond_damage_momentum_radius
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

	GameManager.plog("[SpawnCluster] %s  blocks=%d  prep=%dus  body=%dus  init=%dus  add_child=%dus  total=%dus" % [
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
		GameManager.plog("[SMOOTH_COL] %s body=%dus shape=%dus boxes=%d" % [
			name, t1 - t0, t2 - t1, _smooth_shape_rids.size()])


func _rebuild_smooth_collision_mesh() -> void:
	## Rebuild smooth collision as a greedy axis-aligned box decomposition of
	## the block grid. Each contiguous filled cuboid becomes one BoxShape3D.
	##
	## Replaces the prior trimesh (ConcavePolygonShape3D). The trimesh has
	## intrinsic contact-stability problems against dynamic bodies pressed
	## into it: even with Jolt's EnhancedInternalEdgeRemoval and manifold
	## reduction enabled, multi-contact resolution against many adjacent
	## triangles produces alternating per-frame impulses that translate to
	## visible shake on dynamic bodies (e.g. PushBlocks against a wall).
	## Confirmed by A/B test: trimesh + manifold reduction on still shakes;
	## box decomposition does not.
	##
	## Algorithm: scan filled blocks in (x,y,z) order. For each unclaimed
	## block, greedily extend +X then +Y then +Z to find the largest cuboid
	## of solid unclaimed blocks. Mark them claimed, emit one BoxShape, repeat.
	## Solid wall column = 1 box. Hollow tower = ~6-12 boxes. Decomposition
	## is exact — every filled block is in exactly one box.
	if _collision_body == null or not is_instance_valid(_collision_body):
		return

	var _t_total := Time.get_ticks_usec()
	var body_rid := _collision_body.get_rid()

	# Hand off the entire greedy decomp + body shape rebuild to C++ — saves
	# ~10x over the GDScript version. The kernel frees the previous shape RIDs
	# and returns the new ones.
	_smooth_shape_rids = BlockMeshBuilder.rebuild_smooth_collision_box_shapes(
		body_rid, _block_grid, _num_x, _num_y, _num_z, BLOCK_SIZE,
		_smooth_shape_rids)
	var box_count: int = _smooth_shape_rids.size()
	var _t_decomp_us := Time.get_ticks_usec() - _t_total

	var _t_total_us := Time.get_ticks_usec() - _t_total
	if _t_total_us > 200:
		GameManager.plog("[PERF] _rebuild_smooth_collision %s: decomp=%dus boxes=%d total=%dus" % [
			name, _t_decomp_us, box_count, _t_total_us])
	GameManager.tick_add("smooth_collision", _t_total_us)


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
			GameManager.plog("[PERF] _rebuild_greedy_mesh %s (split): grid_split=%dus struct_mesh=%dus foundation_mesh=%dus total=%dus blocks=%d" % [
				name, _t_split_us, _t_struct_mesh_us, _t_foundation_mesh_us, _t_greedy_us, _block_hp_dict.size()])
	else:
		var _t_mesh := Time.get_ticks_usec()
		_mesh_instance.mesh = BlockMeshBuilder.build_block_mesh(
			_block_grid, _num_x, _num_y, _num_z, BLOCK_SIZE, Vector3.ZERO, true)
		var _t_mesh_us := Time.get_ticks_usec() - _t_mesh
		if _t_mesh_us > 200:
			GameManager.plog("[PERF] _rebuild_greedy_mesh %s: mesh=%dus blocks=%d" % [name, _t_mesh_us, _block_hp_dict.size()])

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
