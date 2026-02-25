extends DestructibleBlockStructure

## Destructible structure generated from a pre-voxelized OBJ mesh.
## Uses ObjStructureData (created by tools/obj-voxelizer/voxelize.js) to define
## which grid cells are occupied. Texture from the original mesh is projected
## onto the greedy mesh via triplanar UV mapping.
##
## Lowest durability tier: 12 HP per block (same as WOOD ramps).
## All block grid, damage, meshing, and debris logic lives in the
## DestructibleBlockStructure base class.

@export var structure_data: ObjStructureData = null

## Compatibility alias for seed_world.gd
var obj_size: Vector3:
	get: return structure_size
	set(v): structure_size = v

## Occupied cell lookup set (built from structure_data before super._ready())
var _occupied_set: Dictionary = {}


func _ready() -> void:
	# When spawning from detach data, skip structure_data setup entirely —
	# the base class _init_from_detach path handles block spawning directly.
	if not _init_from_detach.is_empty():
		super._ready()
		return

	if structure_data == null:
		push_error("DestructibleObjStructure: no structure_data assigned!")
		queue_free()
		return

	# Pre-build occupied lookup set BEFORE super._ready() spawns blocks.
	# super._ready() calls _should_spawn_block() which reads _occupied_set.
	for cell: Vector3i in structure_data.occupied_cells:
		_occupied_set[cell] = true

	# Set grid dimensions from baked data
	structure_size = Vector3(
		structure_data.grid_dimensions.x * BLOCK_SIZE,
		structure_data.grid_dimensions.y * BLOCK_SIZE,
		structure_data.grid_dimensions.z * BLOCK_SIZE,
	)

	# Base class _ready() now builds blocks (respecting _should_spawn_block),
	# greedy mesh (using _compute_quad_uvs), material (using _create_structure_material),
	# and smooth collision.
	super._ready()


func _should_spawn_block(bx: int, by: int, bz: int) -> bool:
	return _occupied_set.has(Vector3i(bx, by, bz))


func _get_tier_info() -> Dictionary:
	# White color base (texture handles visuals), lowest durability
	return { "color": Color.WHITE, "block_hp": 12.0 }


func _get_debris_config() -> Dictionary:
	return {
		"size": 0.12,
		"per_block": 2,
		"impulse": 3.0,
		"lifetime": 5.0,
		"max_total": 40,
		"mass": 0.4,
		"name": "ObjDebris",
	}


func _create_structure_material(tier_info: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	if structure_data and structure_data.texture:
		mat.albedo_texture = structure_data.texture
		mat.albedo_color = Color.WHITE
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	else:
		# Fallback: bright orange so untextured structures are easy to spot
		mat.albedo_color = Color(1.0, 0.5, 0.1)
	return mat


func _compute_quad_uvs(normal: Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Array[Vector2]:
	## Triplanar UV projection: map vertex position to 0-1 UV range based on
	## the original mesh AABB. Each face normal determines which two axes to
	## use for U and V.
	return [
		_triplanar_uv(p0, normal),
		_triplanar_uv(p1, normal),
		_triplanar_uv(p2, normal),
		_triplanar_uv(p3, normal),
	]


func _triplanar_uv(pos: Vector3, normal: Vector3) -> Vector2:
	## Compute UV for a vertex via triplanar projection.
	## Positions are in structure-local space (centered at origin).
	##
	## Map the vertex position to a 0-1 range across the structure extent.
	## Structure-local goes from -half to +half, so normalized = (pos + half) / structure_size.
	var half := structure_size * 0.5
	var norm_pos := (pos + half) / structure_size  # 0-1 across the full grid

	var u: float
	var v: float
	var abs_n := normal.abs()

	if abs_n.x >= abs_n.y and abs_n.x >= abs_n.z:
		# X-dominant face: use Z for U, Y for V
		u = norm_pos.z
		v = norm_pos.y
	elif abs_n.y >= abs_n.z:
		# Y-dominant face: use X for U, Z for V
		u = norm_pos.x
		v = norm_pos.z
	else:
		# Z-dominant face: use X for U, Y for V
		u = norm_pos.x
		v = norm_pos.y

	return Vector2(clampf(u, 0.0, 1.0), clampf(v, 0.0, 1.0))
