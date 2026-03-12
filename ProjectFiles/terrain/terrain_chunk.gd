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

	state = State.READY
	return true


func rebuild(sdf_grid: TerrainSDFGrid, mesher: TerrainMesher) -> bool:
	## Rebuild after SDF modification (crater).
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
