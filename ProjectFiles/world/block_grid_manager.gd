extends RefCounted
class_name BlockGridManager

## Shared block grid data and geometry for DestructibleBlockStructure and
## FallingBlockCluster.  Owns the per-block HP dictionary, flat occupancy grid,
## and pure-data helpers: position math, greedy mesh building, column collision
## shape computation, and BFS connectivity.
##
## Does NOT own any scene tree nodes, physics bodies, or RPCs.  The owning
## node (structure or cluster) is responsible for creating MeshInstance3D,
## CollisionShape3D, StaticBody3D hit bodies, and network sync.

# ======================================================================
#  Constants
# ======================================================================

const BLOCK_SIZE := 0.5
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]

## Default UVs when no callback is provided.
const DEFAULT_UV0 := Vector2(0, 0)
const DEFAULT_UV1 := Vector2(1, 0)
const DEFAULT_UV2 := Vector2(1, 1)
const DEFAULT_UV3 := Vector2(0, 1)


# ======================================================================
#  Data
# ======================================================================

## Grid dimensions in blocks.
var num_x: int = 1
var num_y: int = 1
var num_z: int = 1

## Per-block HP.  Dictionary[Vector3i -> float].
var block_hp: Dictionary = {}

## Flat occupancy grid for fast BFS.  1 = block exists, 0 = empty.
## Indexed via grid_idx().
var block_grid: PackedByteArray = PackedByteArray()

## Centroid offset in grid-local space.  Structures leave this at ZERO
## (their origin IS the grid center).  Clusters compute it from block
## positions so the RigidBody3D center of mass is meaningful.
var centroid: Vector3 = Vector3.ZERO


# ======================================================================
#  Initialization
# ======================================================================

func init_grid(p_num_x: int, p_num_y: int, p_num_z: int) -> void:
	num_x = p_num_x
	num_y = p_num_y
	num_z = p_num_z
	block_grid.resize(num_x * num_y * num_z)
	block_grid.fill(0)


func init_from_dict(block_hp_dict: Dictionary, p_num_x: int, p_num_y: int, p_num_z: int) -> void:
	## Fast C++ path: build flat grid + centroid from block_hp dict in one native call.
	## Also sets block_hp to the input dict (shared reference).
	num_x = p_num_x
	num_y = p_num_y
	num_z = p_num_z
	block_hp = block_hp_dict
	var result: Dictionary = BlockMeshBuilder.init_block_grid(block_hp_dict, num_x, num_y, num_z, BLOCK_SIZE)
	block_grid = result["block_grid"]
	centroid = result["centroid"]


func set_block(key: Vector3i, hp: float) -> void:
	block_hp[key] = hp
	var ix := key.x
	var iy := key.y
	var iz := key.z
	if ix >= 0 and ix < num_x and iy >= 0 and iy < num_y and iz >= 0 and iz < num_z:
		block_grid[grid_idx(ix, iy, iz)] = 1


func erase_block(key: Vector3i) -> void:
	block_hp.erase(key)
	var ix := key.x
	var iy := key.y
	var iz := key.z
	if ix >= 0 and ix < num_x and iy >= 0 and iy < num_y and iz >= 0 and iz < num_z:
		block_grid[grid_idx(ix, iy, iz)] = 0


func has_block(key: Vector3i) -> bool:
	return block_hp.has(key)


func block_count() -> int:
	return block_hp.size()


func is_empty() -> bool:
	return block_hp.is_empty()


# ======================================================================
#  Position math
# ======================================================================

func grid_idx(bx: int, by: int, bz: int) -> int:
	return bx * num_y * num_z + by * num_z + bz


func block_local_pos(key: Vector3i) -> Vector3:
	## Block position in grid-local space, offset by centroid.
	return Vector3(
		(key.x + 0.5 - num_x * 0.5) * BLOCK_SIZE - centroid.x,
		(key.y + 0.5 - num_y * 0.5) * BLOCK_SIZE - centroid.y,
		(key.z + 0.5 - num_z * 0.5) * BLOCK_SIZE - centroid.z
	)


func block_local_pos_raw(key: Vector3i) -> Vector3:
	## Block position without centroid subtraction (grid center = origin).
	return Vector3(
		(key.x + 0.5 - num_x * 0.5) * BLOCK_SIZE,
		(key.y + 0.5 - num_y * 0.5) * BLOCK_SIZE,
		(key.z + 0.5 - num_z * 0.5) * BLOCK_SIZE
	)


func compute_centroid() -> void:
	## Recompute centroid from current blocks.
	centroid = Vector3.ZERO
	if block_hp.is_empty():
		return
	for key: Vector3i in block_hp:
		centroid += block_local_pos_raw(key)
	centroid /= float(block_hp.size())


func nearest_block_key(local_pos: Vector3) -> Vector3i:
	## Convert a centroid-relative local position to the nearest grid key.
	## Adds centroid back so math works relative to the grid.
	var shifted := local_pos + centroid
	var gx := roundi(shifted.x / BLOCK_SIZE + num_x * 0.5 - 0.5)
	var gy := roundi(shifted.y / BLOCK_SIZE + num_y * 0.5 - 0.5)
	var gz := roundi(shifted.z / BLOCK_SIZE + num_z * 0.5 - 0.5)
	return Vector3i(gx, gy, gz)


func get_total_hp() -> float:
	var total := 0.0
	for hp: float in block_hp.values():
		total += hp
	return total


# ======================================================================
#  Greedy mesh building
# ======================================================================

func build_mesh(uv_callback: Callable = Callable()) -> ArrayMesh:
	## Build a face-culled block mesh from current blocks.
	## Vertex positions are relative to `centroid`.
	## If uv_callback is valid it is called per face as:
	##   uv_callback(normal: Vector3, p0, p1, p2, p3: Vector3) -> Array[Vector2]
	## Otherwise default 0-1 UVs are used (via C++ fast path).
	if block_hp.is_empty():
		return null

	# Fast C++ path when no UV callback is needed.
	var use_callback := uv_callback.is_valid()
	if not use_callback:
		return BlockMeshBuilder.build_block_mesh(
			block_grid, num_x, num_y, num_z, BLOCK_SIZE, centroid, true)

	var bc := block_hp.size()
	var max_verts := bc * 24  # 6 faces * 4 verts
	var max_idx := bc * 36    # 6 faces * 6 indices

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

	for key: Vector3i in block_hp:
		var cx: float = (key.x + 0.5 - num_x * 0.5) * bs - centroid.x
		var cy: float = (key.y + 0.5 - num_y * 0.5) * bs - centroid.y
		var cz: float = (key.z + 0.5 - num_z * 0.5) * bs - centroid.z

		# +X face
		if not block_hp.has(Vector3i(key.x + 1, key.y, key.z)):
			var n := Vector3.RIGHT
			var x := cx + hs
			var p0 := Vector3(x, cy - hs, cz - hs)
			var p1 := Vector3(x, cy - hs, cz + hs)
			var p2 := Vector3(x, cy + hs, cz + hs)
			var p3 := Vector3(x, cy + hs, cz - hs)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

		# -X face
		if not block_hp.has(Vector3i(key.x - 1, key.y, key.z)):
			var n := Vector3.LEFT
			var x := cx - hs
			var p0 := Vector3(x, cy - hs, cz + hs)
			var p1 := Vector3(x, cy - hs, cz - hs)
			var p2 := Vector3(x, cy + hs, cz - hs)
			var p3 := Vector3(x, cy + hs, cz + hs)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

		# +Y face (top)
		if not block_hp.has(Vector3i(key.x, key.y + 1, key.z)):
			var n := Vector3.UP
			var y := cy + hs
			var p0 := Vector3(cx - hs, y, cz - hs)
			var p1 := Vector3(cx + hs, y, cz - hs)
			var p2 := Vector3(cx + hs, y, cz + hs)
			var p3 := Vector3(cx - hs, y, cz + hs)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

		# -Y face (bottom)
		if not block_hp.has(Vector3i(key.x, key.y - 1, key.z)):
			var n := Vector3.DOWN
			var y := cy - hs
			var p0 := Vector3(cx - hs, y, cz + hs)
			var p1 := Vector3(cx + hs, y, cz + hs)
			var p2 := Vector3(cx + hs, y, cz - hs)
			var p3 := Vector3(cx - hs, y, cz - hs)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

		# +Z face
		if not block_hp.has(Vector3i(key.x, key.y, key.z + 1)):
			var n := Vector3.BACK
			var z := cz + hs
			var p0 := Vector3(cx + hs, cy - hs, z)
			var p1 := Vector3(cx - hs, cy - hs, z)
			var p2 := Vector3(cx - hs, cy + hs, z)
			var p3 := Vector3(cx + hs, cy + hs, z)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
			idx[ii] = vi; idx[ii + 1] = vi + 1; idx[ii + 2] = vi + 2
			idx[ii + 3] = vi; idx[ii + 4] = vi + 2; idx[ii + 5] = vi + 3
			vi += 4; ii += 6

		# -Z face
		if not block_hp.has(Vector3i(key.x, key.y, key.z - 1)):
			var n := Vector3.FORWARD
			var z := cz - hs
			var p0 := Vector3(cx - hs, cy - hs, z)
			var p1 := Vector3(cx + hs, cy - hs, z)
			var p2 := Vector3(cx + hs, cy + hs, z)
			var p3 := Vector3(cx - hs, cy + hs, z)
			verts[vi] = p0; verts[vi + 1] = p1; verts[vi + 2] = p2; verts[vi + 3] = p3
			norms[vi] = n; norms[vi + 1] = n; norms[vi + 2] = n; norms[vi + 3] = n
			if use_callback:
				var face_uvs: Array[Vector2] = uv_callback.call(n, p0, p1, p2, p3)
				uv_arr[vi] = face_uvs[0]; uv_arr[vi + 1] = face_uvs[1]; uv_arr[vi + 2] = face_uvs[2]; uv_arr[vi + 3] = face_uvs[3]
			else:
				uv_arr[vi] = DEFAULT_UV0; uv_arr[vi + 1] = DEFAULT_UV1; uv_arr[vi + 2] = DEFAULT_UV2; uv_arr[vi + 3] = DEFAULT_UV3
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
	if vi > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ======================================================================
#  Column collision shape computation
# ======================================================================

func compute_column_shapes() -> Array[Dictionary]:
	## Compute all per-column contiguous-Y-run box shapes.
	## Returns Array of { "position": Vector3, "size": Vector3 }.
	## Positions are relative to centroid.
	## Uses C++ fast path via BlockMeshBuilder.
	if block_hp.is_empty():
		return []
	return BlockMeshBuilder.compute_column_shapes(block_grid, num_x, num_y, num_z, BLOCK_SIZE, centroid)


func compute_column_shapes_for(bx: int, bz: int) -> Array[Dictionary]:
	## Compute shapes for a single (bx, bz) column.
	## Uses the flat block_grid for fast Y scanning.
	var result: Array[Dictionary] = []
	var y_present: Array[int] = []
	var base_idx := bx * num_y * num_z + bz
	for by in num_y:
		if block_grid[base_idx + by * num_z] == 1:
			y_present.append(by)
	if y_present.is_empty():
		return result
	_emit_column_runs(result, bx, bz, y_present)
	return result


func _emit_column_runs(out: Array[Dictionary], bx: int, bz: int,
		y_sorted: Array) -> void:
	## Find contiguous Y runs and emit {position, size} dicts.
	var bs := BLOCK_SIZE
	var run_start: int = y_sorted[0]
	var run_end: int = y_sorted[0]

	for i in range(1, y_sorted.size()):
		if y_sorted[i] == run_end + 1:
			run_end = y_sorted[i]
		else:
			_emit_one_shape(out, bx, bz, run_start, run_end)
			run_start = y_sorted[i]
			run_end = y_sorted[i]

	_emit_one_shape(out, bx, bz, run_start, run_end)


func _emit_one_shape(out: Array[Dictionary], bx: int, bz: int,
		by_start: int, by_end: int) -> void:
	var bs := BLOCK_SIZE
	var run_count: int = by_end - by_start + 1
	var size := Vector3(bs, run_count * bs, bs)
	var pos := Vector3(
		(bx + 0.5 - num_x * 0.5) * bs - centroid.x,
		((by_start + by_end) * 0.5 + 0.5 - num_y * 0.5) * bs - centroid.y,
		(bz + 0.5 - num_z * 0.5) * bs - centroid.z
	)
	out.append({ "position": pos, "size": size })


# ======================================================================
#  BFS connectivity
# ======================================================================

func find_connected_components(keys: Array[Vector3i]) -> Array:
	## Group the given block keys into connected components via 6-neighbor BFS.
	## Returns Array of Array[Vector3i].
	var key_set: Dictionary = {}
	for key in keys:
		key_set[key] = true

	var visited: Dictionary = {}
	var components: Array = []

	for start_key in keys:
		if visited.has(start_key):
			continue
		var component: Array[Vector3i] = []
		var queue: Array[Vector3i] = [start_key]
		visited[start_key] = true
		var head := 0
		while head < queue.size():
			var current: Vector3i = queue[head]
			head += 1
			component.append(current)
			for offset in NEIGHBOR_OFFSETS:
				var neighbor: Vector3i = current + offset
				if key_set.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)

	return components


func find_all_components() -> Array:
	## BFS on ALL current blocks via C++ fast path.  Used by cluster fragmentation.
	return BlockMeshBuilder.find_connected_components(block_grid, num_x, num_y, num_z)
