class_name TerrainMesher
extends RefCounted

## Wraps VoxelMesherTransvoxel to build terrain meshes from SDF data.
## Produces a single mesh per chunk used for both rendering and collision.

const CHUNK_SIZE := 16
const SKIRT := 0  # no overlap — Jolt's boundary_edges_active=false (default)
# handles boundary edges without needing skirt.  SKIRT>0 caused overlapping
# collision bodies whose double-contact resolution produced massive impulses.

var _mesher: VoxelMesherTransvoxel
var _min_pad: int
var _max_pad: int
var _material: Material

## Buffer size for chunks (includes skirt + padding on all sides).
## buf_side = CHUNK_SIZE + 2*SKIRT + min_pad + max_pad
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
	## Local offset from chunk origin to position the mesh correctly.
	## Mesh vertices are in buffer-local space; buffer starts at
	## chunk_origin - (SKIRT + min_pad) in each axis.
	var off: float = -float(_min_pad + SKIRT)
	return Vector3(off, off, off)


func get_region_min(block_pos: Vector3i) -> Vector3i:
	## World-space origin of the buffer region for a given chunk.
	var pad: int = _min_pad + SKIRT
	return Vector3i(
		block_pos.x * CHUNK_SIZE - pad,
		block_pos.y * CHUNK_SIZE - pad,
		block_pos.z * CHUNK_SIZE - pad)


func get_buf_size() -> Vector3i:
	return Vector3i(buf_side, buf_side, buf_side)


func build(sdf_grid: TerrainSDFGrid, block_pos: Vector3i) -> Array:
	## Build visual mesh + collision shape for a chunk.
	## Returns [ArrayMesh_or_null, ConcavePolygonShape3D_or_null].
	var region_min := get_region_min(block_pos)
	var bsize := get_buf_size()

	var buffer := VoxelBuffer.new()
	buffer.create(bsize.x, bsize.y, bsize.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.fill_f(1.0, VoxelBuffer.CHANNEL_SDF)
	sdf_grid.fill_buffer(buffer, region_min, bsize)

	# Build visual mesh (full buffer, includes overlap for seamless visuals)
	var mesh: Mesh = _mesher.build_mesh(buffer, [])
	if mesh == null or mesh.get_surface_count() == 0:
		return [null, null]

	var array_mesh: ArrayMesh = mesh as ArrayMesh
	if array_mesh and _material:
		for i in array_mesh.get_surface_count():
			array_mesh.surface_set_material(i, _material)

	# Collision: reuse the visual mesh faces directly.
	# The visual mesh extends slightly into neighboring chunks' padding region
	# (~1-2 cells), creating a small overlap zone at chunk boundaries. This is
	# acceptable — Jolt handles the doubled contacts gracefully, and the
	# alternative (aggressive per-vertex clipping) creates GAPS at boundaries
	# that physics bodies fall through when the surface sits near a chunk edge.
	var shape: ConcavePolygonShape3D = null
	var faces := mesh.get_faces()
	if not faces.is_empty():
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(faces)

	return [mesh, shape]
