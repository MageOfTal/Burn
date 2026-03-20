class_name TerrainSDFGrid
extends RefCounted

## Stores SDF data for terrain chunks.  Each chunk is a PackedFloat32Array
## of CHUNK_SIZE^3 floats indexed as  z * CS*CS + y * CS + x.
## Generates SDF from FastNoiseLite and supports sphere subtraction (craters).

const CHUNK_SIZE := 16
const CS := CHUNK_SIZE  # shorthand for index math
const CHUNK_VOLUME := CS * CS * CS  # 4096

var _chunks: Dictionary = {}  # Vector3i -> PackedFloat32Array
var _noise: FastNoiseLite
var _height_range: float


func _init(noise: FastNoiseLite, p_height_range: float) -> void:
	_noise = noise
	_height_range = p_height_range


# ------------------------------------------------------------------
#  Chunk lifecycle
# ------------------------------------------------------------------

func has_chunk(block_pos: Vector3i) -> bool:
	return _chunks.has(block_pos)


func generate_chunk(block_pos: Vector3i) -> void:
	## Fill a chunk's SDF from the noise height field.
	## Uses C++ TerrainFill module for ~10x speedup over GDScript loop.
	if ClassDB.class_exists(&"TerrainFill"):
		var tf = ClassDB.instantiate(&"TerrainFill")
		_chunks[block_pos] = tf.generate_chunk(block_pos, _noise, _height_range, CS)
	else:
		# Fallback: GDScript loop
		var sdf := PackedFloat32Array()
		sdf.resize(CHUNK_VOLUME)
		var ox: int = block_pos.x * CS
		var oy: int = block_pos.y * CS
		var oz: int = block_pos.z * CS
		var idx := 0
		for lz in CS:
			var wz := float(oz + lz)
			for ly in CS:
				var wy := float(oy + ly)
				for lx in CS:
					var wx := float(ox + lx)
					var surface_y := (_noise.get_noise_2d(wx, wz) + 1.0) * 0.5 * _height_range
					sdf[idx] = wy - surface_y
					idx += 1
		_chunks[block_pos] = sdf


func remove_chunk(block_pos: Vector3i) -> void:
	_chunks.erase(block_pos)


func clear() -> void:
	_chunks.clear()


# ------------------------------------------------------------------
#  SDF queries
# ------------------------------------------------------------------

func get_sdf_at(world_x: int, world_y: int, world_z: int) -> float:
	## Returns stored SDF at an integer world position.
	## Falls back to noise if the chunk is not loaded.
	var bx: int = floori(float(world_x) / CS)
	var by: int = floori(float(world_y) / CS)
	var bz: int = floori(float(world_z) / CS)
	var block_pos := Vector3i(bx, by, bz)

	if _chunks.has(block_pos):
		var lx: int = world_x - bx * CS
		var ly: int = world_y - by * CS
		var lz: int = world_z - bz * CS
		return _chunks[block_pos][lz * CS * CS + ly * CS + lx]

	# Not loaded — compute from noise
	var surface_y := (_noise.get_noise_2d(float(world_x), float(world_z)) + 1.0) * 0.5 * _height_range
	return float(world_y) - surface_y


func get_height_from_noise(world_x: float, world_z: float) -> float:
	if _noise == null:
		return 0.0
	return (_noise.get_noise_2d(world_x, world_z) + 1.0) * 0.5 * _height_range


# ------------------------------------------------------------------
#  Buffer assembly for meshing
# ------------------------------------------------------------------

func fill_buffer(buffer: VoxelBuffer, region_min: Vector3i, buf_size: Vector3i) -> void:
	## Fill a VoxelBuffer SDF channel from stored chunk data.
	## Note: C++ fill_buffer via Object::call is slower than GDScript due to
	## per-voxel Variant overhead. Keeping GDScript until we can access
	## VoxelBuffer's raw memory directly.
	var region_max: Vector3i = region_min + buf_size
	var bmin := Vector3i(
		floori(float(region_min.x) / CS),
		floori(float(region_min.y) / CS),
		floori(float(region_min.z) / CS))
	var bmax := Vector3i(
		floori(float(region_max.x - 1) / CS),
		floori(float(region_max.y - 1) / CS),
		floori(float(region_max.z - 1) / CS))
	var sdf_ch: int = VoxelBuffer.CHANNEL_SDF
	for cbz in range(bmin.z, bmax.z + 1):
		for cby in range(bmin.y, bmax.y + 1):
			for cbx in range(bmin.x, bmax.x + 1):
				var bp := Vector3i(cbx, cby, cbz)
				var co := bp * CS
				var omin_x: int = maxi(co.x, region_min.x)
				var omin_y: int = maxi(co.y, region_min.y)
				var omin_z: int = maxi(co.z, region_min.z)
				var omax_x: int = mini(co.x + CS, region_max.x)
				var omax_y: int = mini(co.y + CS, region_max.y)
				var omax_z: int = mini(co.z + CS, region_max.z)
				if _chunks.has(bp):
					var sdf: PackedFloat32Array = _chunks[bp]
					for wz in range(omin_z, omax_z):
						var lz_c: int = wz - co.z
						var lz_b: int = wz - region_min.z
						for wy in range(omin_y, omax_y):
							var ly_c: int = wy - co.y
							var ly_b: int = wy - region_min.y
							var row_c: int = lz_c * CS * CS + ly_c * CS
							for wx in range(omin_x, omax_x):
								var lx_c: int = wx - co.x
								var lx_b: int = wx - region_min.x
								buffer.set_voxel_f(sdf[row_c + lx_c],
									lx_b, ly_b, lz_b, sdf_ch)
				else:
					for wz in range(omin_z, omax_z):
						var fwz := float(wz)
						var lz_b: int = wz - region_min.z
						for wy in range(omin_y, omax_y):
							var fwy := float(wy)
							var ly_b: int = wy - region_min.y
							for wx in range(omin_x, omax_x):
								var fwx := float(wx)
								var lx_b: int = wx - region_min.x
								var sy := (_noise.get_noise_2d(fwx, fwz) + 1.0) * 0.5 * _height_range
								buffer.set_voxel_f(fwy - sy,
									lx_b, ly_b, lz_b, sdf_ch)


# ------------------------------------------------------------------
#  Sphere subtraction (craters / digging)
# ------------------------------------------------------------------

func stamp_sphere(center: Vector3, radius: float) -> Array[Vector3i]:
	## Subtract a sphere from the terrain SDF.
	## Returns list of block positions whose data was modified.
	var dirty: Dictionary = {}
	var r_ceil: int = int(ceil(radius)) + 1
	var min_wx: int = int(floor(center.x)) - r_ceil
	var max_wx: int = int(ceil(center.x)) + r_ceil
	var min_wy: int = int(floor(center.y)) - r_ceil
	var max_wy: int = int(ceil(center.y)) + r_ceil
	var min_wz: int = int(floor(center.z)) - r_ceil
	var max_wz: int = int(ceil(center.z)) + r_ceil
	var cx: float = center.x
	var cy: float = center.y
	var cz: float = center.z

	for wz in range(min_wz, max_wz + 1):
		var dz: float = float(wz) - cz
		for wy in range(min_wy, max_wy + 1):
			var dy: float = float(wy) - cy
			for wx in range(min_wx, max_wx + 1):
				var dx: float = float(wx) - cx
				var dist: float = sqrt(dx * dx + dy * dy + dz * dz)
				# CSG subtraction: max(existing, radius - dist)
				# radius - dist > 0 inside sphere  → air
				var removal_sdf: float = radius - dist

				var bx: int = floori(float(wx) / CS)
				var by: int = floori(float(wy) / CS)
				var bz_i: int = floori(float(wz) / CS)
				var bp := Vector3i(bx, by, bz_i)

				if not _chunks.has(bp):
					continue  # only modify loaded chunks

				var lx: int = wx - bx * CS
				var ly: int = wy - by * CS
				var lz: int = wz - bz_i * CS
				var idx: int = lz * CS * CS + ly * CS + lx
				var existing: float = _chunks[bp][idx]
				var new_val: float = maxf(existing, removal_sdf)
				if new_val != existing:
					_chunks[bp][idx] = new_val
					dirty[bp] = true

	var result: Array[Vector3i] = []
	for bp in dirty:
		result.append(bp)
	return result
