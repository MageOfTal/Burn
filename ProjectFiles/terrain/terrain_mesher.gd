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
	# Transvoxel's default edge_clamp_margin (0.02) forcibly keeps mesh
	# vertices 2% of a cell (20 mm) away from grid corners — a dead zone that
	# kinked the mesh into steep sliver triangles along contour lines where
	# the terrain surface crosses integer grid heights (measured 46–77° facets
	# on 13–19° terrain; the "weird bump on smooth ground" spots). A hair
	# above zero keeps its divide-by-zero/degenerate-triangle protection while
	# making the displacement sub-0.1 mm.
	_mesher.edge_clamp_margin = 0.0001
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
	# Background fill = "1 m outside", in the same gained scale as fill_buffer.
	buffer.fill_f(1.0 * TerrainSDFGrid.SDF_WRITE_GAIN, VoxelBuffer.CHANNEL_SDF)
	sdf_grid.fill_buffer(buffer, region_min, bsize)

	var mesh: Mesh = _mesher.build_mesh(buffer, [])
	if mesh == null or mesh.get_surface_count() == 0:
		return { "mesh": null, "faces": PackedVector3Array() }

	var array_mesh: ArrayMesh = mesh as ArrayMesh
	if array_mesh and _material:
		for i in array_mesh.get_surface_count():
			array_mesh.surface_set_material(i, _material)

	var faces := filter_degenerate_faces(mesh.get_faces())
	return { "mesh": mesh, "faces": faces }


static func filter_degenerate_faces(faces: PackedVector3Array) -> PackedVector3Array:
	## Drop zero-area triangles.  The mesher's edge clamping can collapse a
	## triangle's vertices together; Jolt culls such triangles, and a chunk
	## whose ONLY triangles are degenerate then fails its whole shape build
	## ("Need triangles to create a mesh shape!" — was ~1257 errors/session).
	## Consumers already treat empty faces as "no collision".
	const MIN_CROSS_SQ := 1e-12  # (2×area)² — drops only true degenerates
	var count := faces.size()

	# Fast path: most chunks have no degenerate faces.
	var has_bad := false
	for i in range(0, count, 3):
		var cross := (faces[i + 1] - faces[i]).cross(faces[i + 2] - faces[i])
		if cross.length_squared() <= MIN_CROSS_SQ:
			has_bad = true
			break
	if not has_bad:
		return faces

	var out := PackedVector3Array()
	out.resize(count)
	var kept := 0
	for i in range(0, count, 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		if (b - a).cross(c - a).length_squared() > MIN_CROSS_SQ:
			out[kept] = a
			out[kept + 1] = b
			out[kept + 2] = c
			kept += 3
	out.resize(kept)
	return out


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
