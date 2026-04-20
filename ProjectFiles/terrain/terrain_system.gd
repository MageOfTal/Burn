class_name TerrainSystem
extends Node3D

## Custom volumetric terrain system replacing VoxelTerrain.
## Uses Zylann's VoxelBuffer + VoxelMesherTransvoxel for SDF meshing,
## but owns chunk lifecycle, positioning, and collision.
##
## All terrain collision lives on a single shared StaticBody3D.  This
## ensures Jolt resolves contacts from adjacent chunks in one manifold,
## eliminating the MULTI_BODY seam impulses that launched the player at
## chunk boundaries.

const CHUNK_SIZE := 16
const VIEW_DISTANCE := 256.0
const LOAD_BUDGET_INIT := 50   # chunks per yield during initial build
const LOAD_BUDGET_PLAY := 2    # chunks to submit per frame
const REBUILD_BUDGET := 4      # dirty chunk rebuilds per frame
const BAKE_PATH := "res://terrain/terrain_bake.bin"

var sdf_grid: TerrainSDFGrid
var _mesher: TerrainMesher
var _streaming: TerrainStreaming
var _deformer: TerrainDeformer

var _chunks: Dictionary = {}          # Vector3i -> TerrainChunk
var _pending: Dictionary = {}         # Vector3i -> true (submitted to thread pool)
var _dirty_queue: Array[Vector3i] = []
var _initial_load_done := false
var _players_node: Node = null
var _stream_frame: int = 0
const STREAM_INTERVAL := 10
var _stream_to_load: Array[Vector3i] = []
var _stream_to_unload: Array[Vector3i] = []

var _terrain_body: StaticBody3D
var _debug_collision_shown := false

# Noise + params
var _noise: FastNoiseLite
var _height_range: float

# Threading: pool of meshers (one per worker) + results queue
var _mesher_pool: Array[TerrainMesher] = []
var _mesher_mutex := Mutex.new()
var _results_mutex := Mutex.new()
var _results: Array[Dictionary] = []  # { block_pos, mesh, faces }
const MESHER_POOL_SIZE := 8


func setup(noise: FastNoiseLite, height_range: float, material: Material) -> void:
	## Call once after adding to the scene tree.
	_noise = noise
	_height_range = height_range

	sdf_grid = TerrainSDFGrid.new(noise, height_range)
	_mesher = TerrainMesher.new(material)
	_streaming = TerrainStreaming.new(VIEW_DISTANCE, height_range)
	_deformer = TerrainDeformer.new()

	_terrain_body = StaticBody3D.new()
	_terrain_body.name = "TerrainBody"
	_terrain_body.collision_layer = CollisionLayers.WORLD
	_terrain_body.collision_mask = 0
	add_child(_terrain_body)
	# Tag 3 = TERRAIN in the shielding system — infinite absorption (impassable).
	PhysicsServer3D.body_set_shielding_tag(_terrain_body.get_rid(), 3)

	# Create a pool of meshers for background threads (one per worker)
	for i in MESHER_POOL_SIZE:
		_mesher_pool.append(TerrainMesher.new(material))


# ------------------------------------------------------------------
#  Initial world build (called from seed_world during loading)
# ------------------------------------------------------------------

func build_initial() -> void:
	## Load full bake if available (instant), otherwise generate + bake.
	if await _load_full_bake():
		_initial_load_done = true
		call_deferred("_check_collision_holes")
		return

	# No bake — generate from scratch
	var positions: Array[Vector3] = [Vector3.ZERO]
	var info: Dictionary = _streaming.update(positions, {})
	var to_load: Array[Vector3i] = info["to_load"]

	print("[TerrainSystem] Initial build: %d chunks to generate" % to_load.size())

	for bp: Vector3i in to_load:
		_ensure_sdf_with_neighbors(bp)

	for bp: Vector3i in to_load:
		_submit_chunk(bp)

	while _pending.size() > 0:
		_harvest_results()
		await get_tree().process_frame

	_initial_load_done = true
	print("[TerrainSystem] Initial build complete: %d chunks (%d with geometry)" % [
		_chunks.size(),
		_count_visible_chunks()])

	_save_full_bake()
	call_deferred("_check_collision_holes")
	#call_deferred("debug_raycast_boundary_gaps", Vector3.ZERO, 64.0)


func _save_full_bake() -> void:
	## Save SDF + collision faces per chunk. Skips ALL generation on next load.
	var t := Time.get_ticks_msec()

	# SDF grid (needed for runtime deformation + streaming)
	var sdf_data: Dictionary = {}
	for bp: Vector3i in sdf_grid._chunks:
		sdf_data[bp] = sdf_grid._chunks[bp]

	# Per-chunk mesh data: verts, normals, indices (for mesh) + faces (for collision)
	var chunk_data: Dictionary = {}
	for bp: Vector3i in _chunks:
		var chunk: TerrainChunk = _chunks[bp]
		var entry: Dictionary = {}
		# Save mesh arrays (verts + normals + indices) for proper smooth lighting
		if not chunk._bake_mesh_arrays.is_empty():
			var arr: Array = chunk._bake_mesh_arrays
			entry["verts"] = arr[Mesh.ARRAY_VERTEX]  # PackedVector3Array
			entry["normals"] = arr[Mesh.ARRAY_NORMAL]  # PackedVector3Array
			entry["indices"] = arr[Mesh.ARRAY_INDEX]  # PackedInt32Array
		# Save collision faces
		if chunk._collision_shape and chunk._collision_shape.shape:
			var shape: ConcavePolygonShape3D = chunk._collision_shape.shape as ConcavePolygonShape3D
			if shape:
				entry["faces"] = shape.get_faces()
		if not entry.is_empty():
			chunk_data[bp] = entry

	var save_dict: Dictionary = {
		"version": 2,
		"sdf": sdf_data,
		"chunk_data": chunk_data,
		"mesh_offset": _mesher.get_mesh_offset(),
	}

	var f := FileAccess.open(BAKE_PATH, FileAccess.WRITE)
	if f:
		f.store_var(save_dict, true)
		f.close()
		print("[TerrainSystem] Baked %d chunks (%d with geometry) in %dms" % [
			sdf_data.size(), chunk_data.size(), Time.get_ticks_msec() - t])


func _load_full_bake() -> bool:
	## Load pre-baked terrain. Rebuilds meshes from faces (fast, no SDF/meshing).
	if not FileAccess.file_exists(BAKE_PATH):
		return false

	var t := Time.get_ticks_msec()
	var f := FileAccess.open(BAKE_PATH, FileAccess.READ)
	if not f:
		return false

	var save_dict = f.get_var(true)
	f.close()

	if not save_dict is Dictionary or not save_dict.has("version"):
		print("[TerrainSystem] Bake file outdated — regenerating")
		return false

	if save_dict["version"] < 2:
		print("[TerrainSystem] Bake version %d < 2 — regenerating" % save_dict["version"])
		return false

	# Restore SDF grid
	var sdf_data: Dictionary = save_dict["sdf"]
	for bp in sdf_data:
		sdf_grid._chunks[bp] = sdf_data[bp]

	# Restore chunks with proper smooth-normal meshes
	var chunk_data: Dictionary = save_dict["chunk_data"]
	var offset: Vector3 = save_dict.get("mesh_offset", _mesher.get_mesh_offset())
	var loaded := 0

	for bp: Vector3i in chunk_data:
		var entry: Dictionary = chunk_data[bp]

		# Build mesh from saved verts + normals + indices (smooth Transvoxel normals)
		var mesh: ArrayMesh = null
		if entry.has("verts") and entry.has("normals") and entry.has("indices"):
			mesh = ArrayMesh.new()
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = entry["verts"]
			arrays[Mesh.ARRAY_NORMAL] = entry["normals"]
			arrays[Mesh.ARRAY_INDEX] = entry["indices"]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			if _mesher._material:
				mesh.surface_set_material(0, _mesher._material)

		var faces: PackedVector3Array = entry.get("faces", PackedVector3Array())

		var chunk := TerrainChunk.new(bp)
		add_child(chunk)
		chunk.apply_data(mesh, faces, offset, _terrain_body)
		_chunks[bp] = chunk
		loaded += 1

		if loaded % 500 == 0:
			await get_tree().process_frame

	print("[TerrainSystem] Loaded bake: %d chunks in %dms" % [
		loaded, Time.get_ticks_msec() - t])
	return true


# ------------------------------------------------------------------
#  Per-frame streaming
# ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _initial_load_done:
		return

	# Detect debug collision toggle
	if GameManager.debug_show_collision != _debug_collision_shown:
		_debug_collision_shown = GameManager.debug_show_collision
		rebuild_all_debug_collision()

	# Harvest completed background chunk results every frame
	Profiler.begin("terrain_harvest")
	_harvest_results()
	Profiler.end("terrain_harvest")

	# Rebuild dirty chunks synchronously (craters need fast feedback)
	Profiler.begin("terrain_rebuild")
	var rebuilt := 0
	while not _dirty_queue.is_empty() and rebuilt < REBUILD_BUDGET:
		var bp: Vector3i = _dirty_queue.pop_front()
		if _chunks.has(bp):
			_chunks[bp].rebuild(sdf_grid, _mesher)
			rebuilt += 1
	Profiler.end("terrain_rebuild")

	# Streaming update: refresh the needed/to_load/to_unload lists periodically
	_stream_frame += 1
	if _stream_frame >= STREAM_INTERVAL:
		_stream_frame = 0
		Profiler.begin("terrain_stream_update")
		var positions := _get_player_positions()
		var loaded_keys: Array = _chunks.keys()
		var pos_packed := PackedVector3Array(positions)
		var min_by := -1
		var max_by := int(ceil(_height_range / 16.0)) + 1
		var info: Dictionary = BlockMeshBuilder.calc_streaming_update(
			pos_packed, loaded_keys, VIEW_DISTANCE, 16, min_by, max_by)
		_stream_to_unload.assign(info["to_unload"])
		_stream_to_load.assign(info["to_load"])
		# Unload immediately (cheap)
		for bp: Vector3i in _stream_to_unload:
			if not _pending.has(bp):
				_unload_chunk(bp)
		Profiler.end("terrain_stream_update")

	# Submit a few chunks every frame (spread the buffer fill cost)
	if not _stream_to_load.is_empty():
		Profiler.begin("terrain_submit")
		var submitted := 0
		while submitted < LOAD_BUDGET_PLAY and not _stream_to_load.is_empty():
			var bp: Vector3i = _stream_to_load.pop_front()
			if _chunks.has(bp) or _pending.has(bp):
				continue
			_ensure_sdf_with_neighbors(bp)
			_submit_chunk(bp)
			submitted += 1
		Profiler.end("terrain_submit")


# ------------------------------------------------------------------
#  Deformation (craters / digging)
# ------------------------------------------------------------------

func deform(world_pos: Vector3, radius: float) -> void:
	## Subtract a sphere from the terrain and queue affected chunks for rebuild.
	var dirty: Array[Vector3i] = _deformer.deform_sphere(sdf_grid, world_pos, radius)
	for bp in dirty:
		if _chunks.has(bp) and bp not in _dirty_queue:
			_dirty_queue.append(bp)


# ------------------------------------------------------------------
#  Height queries
# ------------------------------------------------------------------

func get_height_from_noise(world_x: float, world_z: float) -> float:
	return sdf_grid.get_height_from_noise(world_x, world_z)


# ------------------------------------------------------------------
#  Reset (new round)
# ------------------------------------------------------------------

func reset() -> void:
	## Destroy all chunks and clear SDF edits.  After calling this,
	## call build_initial() again to regenerate terrain.
	# Wait for any pending background tasks to finish
	while _pending.size() > 0:
		_harvest_results()
	for bp: Vector3i in _chunks.keys():
		_unload_chunk(bp)
	_chunks.clear()
	_pending.clear()
	_dirty_queue.clear()
	sdf_grid.clear()
	_initial_load_done = false
	# Delete bake so next build regenerates fresh
	if FileAccess.file_exists(BAKE_PATH):
		DirAccess.remove_absolute(BAKE_PATH)
		print("[TerrainSystem] Deleted bake file")


# ------------------------------------------------------------------
#  Internals
# ------------------------------------------------------------------

func _ensure_sdf_with_neighbors(bp: Vector3i) -> void:
	## Generate SDF data for a chunk and its immediate neighbors.
	## Neighbors are needed for the mesher's padding region.
	## This is cheap (~0.5ms/chunk) and must run on main thread
	## so the data is stable when workers read it.
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var nbp := bp + Vector3i(dx, dy, dz)
				if not sdf_grid.has_chunk(nbp):
					sdf_grid.generate_chunk(nbp)


func _acquire_mesher() -> TerrainMesher:
	_mesher_mutex.lock()
	var m: TerrainMesher = _mesher_pool.pop_back() if not _mesher_pool.is_empty() else null
	_mesher_mutex.unlock()
	return m


func _release_mesher(m: TerrainMesher) -> void:
	_mesher_mutex.lock()
	_mesher_pool.append(m)
	_mesher_mutex.unlock()


func _submit_chunk(bp: Vector3i) -> void:
	## Fill the VoxelBuffer on the main thread (GDScript, accesses sdf_grid),
	## then submit the filled buffer to a worker for C++ meshing.
	_pending[bp] = true

	# Main thread: fill buffer (GDScript loop, not thread-safe)
	var region_min := _mesher.get_region_min(bp)
	var bsize := _mesher.get_buf_size()
	var buffer := VoxelBuffer.new()
	buffer.create(bsize.x, bsize.y, bsize.z)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	buffer.fill_f(1.0, VoxelBuffer.CHANNEL_SDF)
	sdf_grid.fill_buffer(buffer, region_min, bsize)

	# Worker thread: C++ meshing + face extraction only
	var material := _mesher._material
	var sys := self
	WorkerThreadPool.add_task(func():
		var mesher := sys._acquire_mesher()
		if mesher == null:
			mesher = TerrainMesher.new(material)

		var mesh: Mesh = mesher._mesher.build_mesh(buffer, [])
		var faces := PackedVector3Array()
		var mesh_arrays: Array = []
		if mesh != null and mesh.get_surface_count() > 0:
			var array_mesh: ArrayMesh = mesh as ArrayMesh
			if array_mesh and material:
				for i in array_mesh.get_surface_count():
					array_mesh.surface_set_material(i, material)
			# Extract surface arrays NOW (before GPU upload) for bake + collision
			mesh_arrays = array_mesh.surface_get_arrays(0) if array_mesh else []
			faces = mesh.get_faces()
		else:
			mesh = null

		sys._release_mesher(mesher)

		sys._results_mutex.lock()
		sys._results.append({ "block_pos": bp, "mesh": mesh, "faces": faces, "mesh_arrays": mesh_arrays })
		sys._results_mutex.unlock()
	)


func _harvest_results() -> void:
	## Apply completed chunk results to the scene tree (main thread only).
	_results_mutex.lock()
	var batch := _results.duplicate()
	_results.clear()
	_results_mutex.unlock()

	var offset := _mesher.get_mesh_offset()
	for data: Dictionary in batch:
		var bp: Vector3i = data["block_pos"]
		_pending.erase(bp)

		var chunk := TerrainChunk.new(bp)
		add_child(chunk)
		chunk.apply_data(data["mesh"], data["faces"], offset, _terrain_body)
		chunk._bake_mesh_arrays = data.get("mesh_arrays", [])
		_chunks[bp] = chunk


func _unload_chunk(bp: Vector3i) -> void:
	if _chunks.has(bp):
		_chunks[bp].remove_collision()
		_chunks[bp].queue_free()
		_chunks.erase(bp)
	# Don't remove SDF data — neighbors might still need it for their skirt.
	# SDF cleanup happens in _process when no loaded chunk references it.


func _get_player_positions() -> Array[Vector3]:
	if _players_node == null:
		# Players node is a sibling of SeedWorld (our parent) under the scene root
		var seed_world := get_parent()
		if seed_world and seed_world.get_parent():
			_players_node = seed_world.get_parent().get_node_or_null("Players")
	var positions: Array[Vector3] = []
	if _players_node:
		for child in _players_node.get_children():
			if child is Node3D:
				positions.append(child.global_position)
	if positions.is_empty():
		positions.append(Vector3.ZERO)
	return positions


func _count_visible_chunks() -> int:
	var count := 0
	for bp: Vector3i in _chunks:
		if _chunks[bp].state == TerrainChunk.State.READY:
			count += 1
	return count


func rebuild_all_debug_collision() -> void:
	## Toggle debug collision visualization on all loaded chunks.
	print("[TerrainSystem] rebuild_all_debug_collision called, %d chunks, show=%s" % [_chunks.size(), GameManager.debug_show_collision])
	for bp: Vector3i in _chunks:
		var chunk: TerrainChunk = _chunks[bp]
		if chunk._collision_shape and chunk._collision_shape.shape:
			chunk._update_debug_collision_mesh(
				chunk._collision_shape.shape as ConcavePolygonShape3D,
				chunk._collision_shape.position)
		elif chunk._debug_collision_mesh:
			chunk._debug_collision_mesh.visible = false


# ------------------------------------------------------------------
#  Debug: check mesh triangle continuity at chunk boundaries
# ------------------------------------------------------------------

func debug_check_boundary_continuity(around_pos: Vector3 = Vector3.ZERO, radius: float = 64.0) -> void:
	## Inspect actual mesh triangles at chunk boundaries to find gaps.
	## Checks all loaded chunk pairs within `radius` of `around_pos`.
	print("\n[TerrainBoundaryCheck] Checking mesh continuity around (%.0f, %.0f, %.0f) r=%.0f..." % [
		around_pos.x, around_pos.y, around_pos.z, radius])

	var center_bp := Vector3i(
		floori(around_pos.x / CHUNK_SIZE),
		floori(around_pos.y / CHUNK_SIZE),
		floori(around_pos.z / CHUNK_SIZE))
	var bp_radius := ceili(radius / CHUNK_SIZE)

	var pairs_checked := 0
	var gaps_found := 0

	# Only check +X, +Y, +Z neighbors to avoid double-checking
	var axes := [Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, 0, 1)]

	for bp: Vector3i in _chunks:
		# Skip chunks far from the area of interest
		var world_center := Vector3(bp * CHUNK_SIZE) + Vector3(8, 8, 8)
		if world_center.distance_to(around_pos) > radius:
			continue

		for axis in axes:
			var neighbor_bp: Vector3i = bp + axis
			if not _chunks.has(neighbor_bp):
				continue

			var chunk_a: TerrainChunk = _chunks[bp]
			var chunk_b: TerrainChunk = _chunks[neighbor_bp]
			var result := _check_boundary_pair(chunk_a, chunk_b, axis)
			pairs_checked += 1
			if result > 0:
				gaps_found += result

	print("[TerrainBoundaryCheck] Done. Checked %d boundary pairs, found %d edge mismatches.\n" % [
		pairs_checked, gaps_found])


func _check_boundary_pair(chunk_a: TerrainChunk, chunk_b: TerrainChunk, axis: Vector3i) -> int:
	## Check if boundary VERTICES between two adjacent chunks match.
	## Returns number of unmatched vertices found.
	var faces_a := _get_world_faces(chunk_a)
	var faces_b := _get_world_faces(chunk_b)
	if faces_a.is_empty() or faces_b.is_empty():
		return 0

	var axis_idx: int
	var boundary_val: float
	if axis.x != 0:
		axis_idx = 0
		boundary_val = float(chunk_b.block_pos.x * CHUNK_SIZE)
	elif axis.y != 0:
		axis_idx = 1
		boundary_val = float(chunk_b.block_pos.y * CHUNK_SIZE)
	else:
		axis_idx = 2
		boundary_val = float(chunk_b.block_pos.z * CHUNK_SIZE)

	const PLANE_EPSILON := 0.05  # how close a vertex must be to the boundary plane
	const MATCH_EPSILON := 0.01  # how close two vertices must be to "match"

	# Collect unique boundary vertices from each chunk
	var verts_a := _extract_boundary_verts(faces_a, axis_idx, boundary_val, PLANE_EPSILON)
	var verts_b := _extract_boundary_verts(faces_b, axis_idx, boundary_val, PLANE_EPSILON)

	if verts_a.is_empty() and verts_b.is_empty():
		return 0

	# Count unmatched vertices (skip individual prints for now)
	var unmatched_a := 0
	for va: Vector3 in verts_a:
		var found := false
		for vb: Vector3 in verts_b:
			if va.distance_to(vb) < MATCH_EPSILON:
				found = true
				break
		if not found:
			unmatched_a += 1

	var unmatched_b := 0
	for vb: Vector3 in verts_b:
		var found := false
		for va: Vector3 in verts_a:
			if vb.distance_to(va) < MATCH_EPSILON:
				found = true
				break
		if not found:
			unmatched_b += 1

	# Find chunk A's closest vertex to the boundary (how far does A's mesh actually reach?)
	var a_max_toward_boundary: float = -INF
	var a_closest_vert := Vector3.ZERO
	for i in faces_a.size():
		var v := faces_a[i]
		var val: float = v[axis_idx]
		if val > a_max_toward_boundary:
			a_max_toward_boundary = val
			a_closest_vert = v
	var a_gap: float = boundary_val - a_max_toward_boundary

	# Find chunk B's closest vertex to the boundary from the other side
	var b_min_toward_boundary: float = INF
	var b_closest_vert := Vector3.ZERO
	for i in faces_b.size():
		var v := faces_b[i]
		var val: float = v[axis_idx]
		if val < b_min_toward_boundary:
			b_min_toward_boundary = val
			b_closest_vert = v

	var total := unmatched_a + unmatched_b
	print("  [BOUNDARY] %s↔%s axis=%d val=%.1f: A_verts=%d B_verts=%d  unmatched: A=%d B=%d  A_max=%.4f (gap=%.4f) B_min=%.4f  A_closest=(%.3f,%.3f,%.3f) B_closest=(%.3f,%.3f,%.3f)" % [
		chunk_a.name, chunk_b.name, axis_idx, boundary_val,
		verts_a.size(), verts_b.size(), unmatched_a, unmatched_b,
		a_max_toward_boundary, a_gap, b_min_toward_boundary,
		a_closest_vert.x, a_closest_vert.y, a_closest_vert.z,
		b_closest_vert.x, b_closest_vert.y, b_closest_vert.z])
	return total


func _get_world_faces(chunk: TerrainChunk) -> PackedVector3Array:
	## Get triangle faces from a chunk's collision shape in world space.
	if chunk._collision_shape == null or chunk._collision_shape.shape == null:
		return PackedVector3Array()
	var shape: ConcavePolygonShape3D = chunk._collision_shape.shape as ConcavePolygonShape3D
	if shape == null:
		return PackedVector3Array()
	var faces := shape.get_faces()
	# Transform from shape-local space to world space.
	# Shape is a child of the shared TerrainBody at position (0,0,0).
	# shape.position = chunk.position + mesh_offset
	# So world = shape.position + local_vertex
	var world_offset: Vector3 = chunk._collision_shape.position
	var world_faces := PackedVector3Array()
	world_faces.resize(faces.size())
	for i in faces.size():
		world_faces[i] = faces[i] + world_offset
	return world_faces


func _extract_boundary_verts(faces: PackedVector3Array, axis_idx: int, boundary_val: float, epsilon: float) -> Array[Vector3]:
	## Collect unique vertices that lie on the boundary plane.
	var verts: Array[Vector3] = []
	for i in faces.size():
		var v := faces[i]
		if absf(v[axis_idx] - boundary_val) < epsilon:
			# Deduplicate
			var dupe := false
			for existing in verts:
				if v.distance_to(existing) < 0.001:
					dupe = true
					break
			if not dupe:
				verts.append(v)
	return verts


func _check_collision_holes() -> void:
	## Fast physics raycast check for actual collision holes at chunk boundaries.
	if not is_inside_tree() or get_world_3d() == null:
		return
	# Wait a frame so physics shapes are registered
	await get_tree().physics_frame
	var t := Time.get_ticks_msec()
	var space := get_world_3d().direct_space_state
	if space == null:
		print("[COLLISION CHECK] No physics space available")
		return
	var step := 2.0
	var radius := 64.0
	var holes := 0
	var total := 0
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = CollisionLayers.WORLD

	# Sample chunk boundaries in the central area
	for bx in range(-4, 5):
		for bz in range(-4, 5):
			var boundary_x: float = bx * CHUNK_SIZE
			var boundary_z: float = bz * CHUNK_SIZE
			# Test along X boundary
			for z in range(int(boundary_x - radius), int(boundary_x + radius), int(step)):
				var from := Vector3(boundary_x, 100.0, float(z))
				var to := Vector3(boundary_x, -10.0, float(z))
				params.from = from
				params.to = to
				var result := space.intersect_ray(params)
				total += 1
				if result.is_empty():
					holes += 1
			# Test along Z boundary
			for x in range(int(boundary_z - radius), int(boundary_z + radius), int(step)):
				var from := Vector3(float(x), 100.0, boundary_z)
				var to := Vector3(float(x), -10.0, boundary_z)
				params.from = from
				params.to = to
				var result := space.intersect_ray(params)
				total += 1
				if result.is_empty():
					holes += 1

	if holes > 0:
		print("[COLLISION CHECK] HOLES FOUND: %d / %d rays (%.1f%%) in %dms" % [
			holes, total, float(holes) / total * 100.0, Time.get_ticks_msec() - t])
	else:
		print("[COLLISION CHECK] No holes — %d rays, all hit terrain (%dms)" % [
			total, Time.get_ticks_msec() - t])


# ------------------------------------------------------------------
#  Debug: mesh-based collision gap detection at chunk boundaries
# ------------------------------------------------------------------

func debug_raycast_boundary_gaps(around_pos: Vector3 = Vector3.ZERO, radius: float = 64.0) -> void:
	## Check actual mesh triangles for coverage gaps at chunk boundaries.
	## For each sample point along a boundary, tests whether any triangle
	## from either adjacent chunk covers that XZ position (vertical ray
	## through the triangle in XZ projection). No physics raycasts used —
	## operates directly on the ConcavePolygonShape3D face data.
	print("\n[TerrainMeshGapCheck] Checking mesh coverage at boundaries around (%.0f, %.0f, %.0f) r=%.0f..." % [
		around_pos.x, around_pos.y, around_pos.z, radius])

	var sample_step := 0.5  # spacing along the boundary (meters)
	# Offsets perpendicular to boundary: negative = chunk A side, positive = chunk B side
	var offsets: Array[float] = [-2.0, -1.0, -0.5, -0.2, 0.0, 0.2, 0.5, 1.0, 2.0]

	var total_samples := 0
	var total_gaps := 0
	var gap_details: Array[String] = []

	# Check each loaded chunk pair sharing a boundary
	var axes := [Vector3i(1, 0, 0), Vector3i(0, 0, 1)]  # X and Z boundaries
	for bp: Vector3i in _chunks:
		var world_center := Vector3(bp * CHUNK_SIZE) + Vector3(8, 8, 8)
		if world_center.distance_to(around_pos) > radius:
			continue

		for axis in axes:
			var neighbor_bp: Vector3i = bp + axis
			if not _chunks.has(neighbor_bp):
				continue

			var chunk_a: TerrainChunk = _chunks[bp]
			var chunk_b: TerrainChunk = _chunks[neighbor_bp]
			var faces_a := _get_world_faces(chunk_a)
			var faces_b := _get_world_faces(chunk_b)
			# Merge all triangles from both chunks into one list
			var all_faces := PackedVector3Array()
			all_faces.append_array(faces_a)
			all_faces.append_array(faces_b)
			if all_faces.is_empty():
				continue

			# Determine boundary position and sample axes
			var boundary_val: float
			var is_x_boundary: bool  # true = X boundary, false = Z boundary
			if axis.x != 0:
				boundary_val = float(neighbor_bp.x * CHUNK_SIZE)
				is_x_boundary = true
			else:
				boundary_val = float(neighbor_bp.z * CHUNK_SIZE)
				is_x_boundary = false

			# Determine the range along the boundary to sample
			# Use the chunk's Y range for vertical, and the perpendicular axis range
			var along_min: float
			var along_max: float
			if is_x_boundary:
				# Boundary is at X=boundary_val, sample along Z
				along_min = float(bp.z * CHUNK_SIZE)
				along_max = float(bp.z * CHUNK_SIZE + CHUNK_SIZE)
			else:
				# Boundary is at Z=boundary_val, sample along X
				along_min = float(bp.x * CHUNK_SIZE)
				along_max = float(bp.x * CHUNK_SIZE + CHUNK_SIZE)

			var along := along_min
			while along < along_max:
				for offset in offsets:
					var sample_x: float
					var sample_z: float
					if is_x_boundary:
						sample_x = boundary_val + offset
						sample_z = along
					else:
						sample_x = along
						sample_z = boundary_val + offset

					# Check if terrain surface exists here (skip air-only regions)
					var expected_y := sdf_grid.get_height_from_noise(sample_x, sample_z)
					var chunk_min_y := float(bp.y * CHUNK_SIZE)
					var chunk_max_y := float(bp.y * CHUNK_SIZE + CHUNK_SIZE)
					if expected_y < chunk_min_y - 2.0 or expected_y > chunk_max_y + 2.0:
						continue  # surface not in this chunk's Y range

					# Check if any triangle covers this XZ point
					var hit := _mesh_covers_xz(all_faces, sample_x, sample_z, expected_y, 10.0)
					total_samples += 1

					if not hit:
						total_gaps += 1
						var axis_name := "X" if is_x_boundary else "Z"
						if gap_details.size() < 20:
							gap_details.append(
								"  GAP at %s=%.0f offset=%.1f  (%.1f, %.1f) expected_y=%.1f  chunks=%s↔%s" % [
									axis_name, boundary_val, offset,
									sample_x, sample_z, expected_y,
									chunk_a.name, chunk_b.name])
				along += sample_step

	# Report
	if total_gaps == 0:
		print("[TerrainMeshGapCheck] PASS — %d sample points, 0 gaps." % total_samples)
	else:
		print("[TerrainMeshGapCheck] FAIL — %d samples, %d gaps:" % [total_samples, total_gaps])
		for line in gap_details:
			print(line)
		if total_gaps > gap_details.size():
			print("  ... and %d more." % (total_gaps - gap_details.size()))
	print("[TerrainMeshGapCheck] Done.\n")


func _mesh_covers_xz(faces: PackedVector3Array, px: float, pz: float, expected_y: float, y_tolerance: float) -> bool:
	## Check if any triangle in the face array covers the XZ point (px, pz).
	## A triangle "covers" the point if (px, pz) falls within the triangle's
	## XZ projection AND the triangle's Y at that point is within y_tolerance
	## of expected_y. faces is a flat array of vertices (3 per triangle).
	var tri_count: int = faces.size() / 3
	for t in tri_count:
		var i: int = t * 3
		var v0 := faces[i]
		var v1 := faces[i + 1]
		var v2 := faces[i + 2]

		# Quick AABB reject in XZ
		var min_x := minf(v0.x, minf(v1.x, v2.x))
		var max_x := maxf(v0.x, maxf(v1.x, v2.x))
		if px < min_x or px > max_x:
			continue
		var min_z := minf(v0.z, minf(v1.z, v2.z))
		var max_z := maxf(v0.z, maxf(v1.z, v2.z))
		if pz < min_z or pz > max_z:
			continue

		# Point-in-triangle test in XZ using sign of cross products
		var d1 := (px - v1.x) * (v0.z - v1.z) - (v0.x - v1.x) * (pz - v1.z)
		var d2 := (px - v2.x) * (v1.z - v2.z) - (v1.x - v2.x) * (pz - v2.z)
		var d3 := (px - v0.x) * (v2.z - v0.z) - (v2.x - v0.x) * (pz - v0.z)
		var has_neg := (d1 < 0.0) or (d2 < 0.0) or (d3 < 0.0)
		var has_pos := (d1 > 0.0) or (d2 > 0.0) or (d3 > 0.0)
		if has_neg and has_pos:
			continue  # point outside triangle

		# Point is inside triangle XZ projection — compute Y via barycentric
		var area := d1 + d2 + d3
		if absf(area) < 0.0001:
			continue  # degenerate triangle
		var u := d2 / area  # weight for v0
		var v := d3 / area  # weight for v1
		var w := d1 / area  # weight for v2
		var hit_y := u * v0.y + v * v1.y + w * v2.y

		if absf(hit_y - expected_y) < y_tolerance:
			return true

	return false
