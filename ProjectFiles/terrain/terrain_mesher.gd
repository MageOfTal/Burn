class_name TerrainMesher
extends RefCounted

## Wraps VoxelMesherTransvoxel to build terrain meshes from SDF data.
## Produces a single mesh per chunk used for both rendering and collision.
##
## Two build paths:
##   build()      — synchronous, used for dirty chunk rebuilds (craters)
##   build_data() — thread-safe, returns raw data without touching scene tree

const CHUNK_SIZE := 16
const SKIRT := 0

var _mesher: VoxelMesherTransvoxel
var _min_pad: int
var _max_pad: int
var _material: Material

var buf_side: int


func _init(material: Material) -> void:
	_mesher = VoxelMesherTransvoxel.new()
	_min_pad = _mesher.get_minimum_padding()
	_max_pad = _mesher.get_maximum_padding()
	_material = material
	buf_side = CHUNK_SIZE + 2 * SKIRT + _min_pad + _max_pad


func get_min_pad() -> int:
	return _min_pad


func get_max_pad() -> int:
	return _max_pad


func get_mesh_offset() -> Vector3:
	var off: float = -float(_min_pad + SKIRT)
	return Vector3(off, off, off)


func get_region_min(block_pos: Vector3i) -> Vector3i:
	var pad: int = _min_pad + SKIRT
	return Vector3i(
		block_pos.x * CHUNK_SIZE - pad,
		block_pos.y * CHUNK_SIZE - pad,
		block_pos.z * CHUNK_SIZE - pad)


func get_buf_size() -> Vector3i:
	return Vector3i(buf_side, buf_side, buf_side)


func build_data(sdf_grid: TerrainSDFGrid, block_pos: Vector3i) -> Dictionary:
	## Thread-safe: generates mesh + collision faces from SDF data.
	## Returns { "mesh": ArrayMesh or null, "faces": PackedVector3Array }.
	## Does not touch the scene tree — safe to call from any thread.
	var region_min := get_region_min(block_pos)
	var bsize := get_buf_size()

	var buffer := VoxelBuffer.new()
	buffer.create(bsize.x, bsize.y, bsize.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.fill_f(1.0, VoxelBuffer.CHANNEL_SDF)
	sdf_grid.fill_buffer(buffer, region_min, bsize)

	var mesh: Mesh = _mesher.build_mesh(buffer, [])
	if mesh == null or mesh.get_surface_count() == 0:
		return { "mesh": null, "faces": PackedVector3Array() }

	var array_mesh: ArrayMesh = mesh as ArrayMesh
	if array_mesh and _material:
		for i in array_mesh.get_surface_count():
			array_mesh.surface_set_material(i, _material)

	var faces := mesh.get_faces()
	return { "mesh": mesh, "faces": faces }


func build(sdf_grid: TerrainSDFGrid, block_pos: Vector3i) -> Array:
	## Synchronous build. Used for dirty rebuilds (craters) where latency matters.
	## Returns [ArrayMesh_or_null, ConcavePolygonShape3D_or_null].
	var data := build_data(sdf_grid, block_pos)
	if data["mesh"] == null:
		return [null, null]

	var shape: ConcavePolygonShape3D = null
	var faces: PackedVector3Array = data["faces"]
	if not faces.is_empty():
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(faces)

	return [data["mesh"], shape]
