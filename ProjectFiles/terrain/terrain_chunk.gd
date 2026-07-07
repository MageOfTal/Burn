class_name TerrainChunk
extends Node3D

## A single terrain chunk: visual MeshInstance3D + collision shape.
##
## Collision shapes are children of a shared StaticBody3D owned by
## TerrainSystem, not per-chunk bodies.  This means all terrain contacts
## belong to a single physics body, so Jolt's solver resolves them
## together — eliminating the MULTI_BODY seam impulses that occurred
## when adjacent chunks were separate bodies with mismatched normals.

const CHUNK_SIZE := 16

enum State { PENDING, READY, DIRTY }

var block_pos: Vector3i
var state: int = State.PENDING

var _mesh_instance: MeshInstance3D
var _collision_shape: CollisionShape3D
var _terrain_body: StaticBody3D  # shared body from TerrainSystem
var _debug_collision_mesh: MeshInstance3D
var _bake_mesh_arrays: Array = []  # saved for baking (verts, normals, indices)

static var _debug_material: StandardMaterial3D


func _init(p_block_pos: Vector3i) -> void:
	block_pos = p_block_pos
	name = "TC_%d_%d_%d" % [block_pos.x, block_pos.y, block_pos.z]

	# Position at chunk world origin
	position = Vector3(block_pos * CHUNK_SIZE)


func build(sdf_grid: TerrainSDFGrid, mesher: TerrainMesher, terrain_body: StaticBody3D) -> bool:
	## Generate visual + collision mesh. Returns true if geometry was produced.
	_terrain_body = terrain_body
	var result: Array = mesher.build(sdf_grid, block_pos)
	var mesh: Mesh = result[0]
	var shape: ConcavePolygonShape3D = result[1]

	if mesh == null:
		# Chunk is entirely air or entirely solid — no surface here
		_clear_visuals()
		remove_collision()
		state = State.READY
		return false

	var offset: Vector3 = mesher.get_mesh_offset()

	# --- Visual ---
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Mesh"
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh
	_mesh_instance.position = offset

	# --- Collision (on shared body) ---
	if shape != null:
		if _collision_shape == null:
			_collision_shape = CollisionShape3D.new()
			_collision_shape.name = "Col_%d_%d_%d" % [block_pos.x, block_pos.y, block_pos.z]
			_terrain_body.add_child(_collision_shape)
		_collision_shape.shape = shape
		_collision_shape.position = position + offset
	else:
		remove_collision()

	_update_debug_collision_mesh(shape, position + offset)

	state = State.READY
	return true


func _update_debug_collision_mesh(shape: ConcavePolygonShape3D, col_pos: Vector3) -> void:
	if not GameManager.debug_show_collision:
		if _debug_collision_mesh:
			_debug_collision_mesh.visible = false
		return
	if shape == null:
		if _debug_collision_mesh:
			_debug_collision_mesh.visible = false
		return

	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.albedo_color = Color(1.0, 0.0, 0.0, 0.25)
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.no_depth_test = true

	var faces: PackedVector3Array = shape.get_faces()
	if faces.is_empty():
		return

	# Convert triangles to wireframe lines
	var tri_count: int = faces.size() / 3
	var lines := PackedVector3Array()
	lines.resize(tri_count * 6)  # 3 edges * 2 verts per triangle
	for t in tri_count:
		var i: int = t * 3
		var li: int = t * 6
		lines[li]     = faces[i]
		lines[li + 1] = faces[i + 1]
		lines[li + 2] = faces[i + 1]
		lines[li + 3] = faces[i + 2]
		lines[li + 4] = faces[i + 2]
		lines[li + 5] = faces[i]

	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)

	if _debug_collision_mesh == null:
		_debug_collision_mesh = MeshInstance3D.new()
		_debug_collision_mesh.name = "DebugCol"
		_debug_collision_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_debug_collision_mesh)
	_debug_collision_mesh.mesh = mesh
	_debug_collision_mesh.material_override = _debug_material
	_debug_collision_mesh.position = col_pos - position
	_debug_collision_mesh.visible = true


func apply_data(mesh: Mesh, faces: PackedVector3Array, mesh_offset: Vector3, terrain_body: StaticBody3D) -> bool:
	## Apply pre-computed mesh + collision data (from background thread).
	## Only does scene tree operations — safe for main thread only.
	_terrain_body = terrain_body

	if mesh == null:
		_clear_visuals()
		remove_collision()
		state = State.READY
		return false

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Mesh"
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh
	_mesh_instance.position = mesh_offset

	# Choke point for ALL face sources (background mesher, crater rebuilds,
	# AND baked caches — old bake .bin files carry degenerate triangles that
	# fail Jolt's shape build with "Need triangles to create a mesh shape!").
	faces = TerrainMesher.filter_degenerate_faces(faces)

	if not faces.is_empty():
		if _collision_shape == null:
			_collision_shape = CollisionShape3D.new()
			_collision_shape.name = "Col_%d_%d_%d" % [block_pos.x, block_pos.y, block_pos.z]
			_terrain_body.add_child(_collision_shape)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		_collision_shape.shape = shape
		_collision_shape.position = position + mesh_offset
	else:
		remove_collision()

	_update_debug_collision_mesh(
		_collision_shape.shape as ConcavePolygonShape3D if _collision_shape else null,
		position + mesh_offset)

	state = State.READY
	return true


func rebuild(sdf_grid: TerrainSDFGrid, mesher: TerrainMesher) -> bool:
	## Rebuild after SDF modification (crater). Synchronous.
	return build(sdf_grid, mesher, _terrain_body)


func remove_collision() -> void:
	## Remove this chunk's collision shape from the shared body.
	if _collision_shape != null:
		if _collision_shape.get_parent():
			_collision_shape.get_parent().remove_child(_collision_shape)
		_collision_shape.queue_free()
		_collision_shape = null


func _clear_visuals() -> void:
	if _mesh_instance:
		_mesh_instance.mesh = null
