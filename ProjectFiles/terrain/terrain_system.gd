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
const LOAD_BUDGET_PLAY := 8    # chunks per frame during gameplay
const REBUILD_BUDGET := 4      # dirty chunk rebuilds per frame

var sdf_grid: TerrainSDFGrid
var _mesher: TerrainMesher
var _streaming: TerrainStreaming
var _deformer: TerrainDeformer

var _chunks: Dictionary = {}          # Vector3i -> TerrainChunk
var _dirty_queue: Array[Vector3i] = []
var _initial_load_done := false
var _players_node: Node = null        # cached reference to Players node
var _stream_frame: int = 0
const STREAM_INTERVAL := 10           # run streaming logic every N frames

## Single collision body shared by every chunk.  One body = one manifold
## per contacting object, so Jolt's solver handles boundary normals
## smoothly instead of producing conflicting impulses.
var _terrain_body: StaticBody3D

# Noise + params (kept for height queries and reset)
var _noise: FastNoiseLite
var _height_range: float


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


# ------------------------------------------------------------------
#  Initial world build (called from seed_world during loading)
# ------------------------------------------------------------------

func build_initial() -> void:
	## Generate and mesh all chunks in view.  Yields periodically.
	## Call this during the loading phase before players spawn.
	var positions: Array[Vector3] = [Vector3.ZERO]
	var info: Dictionary = _streaming.update(positions, {})
	var to_load: Array[Vector3i] = info["to_load"]

	print("[TerrainSystem] Initial build: %d chunks to generate" % to_load.size())
	var built := 0
	for bp: Vector3i in to_load:
		_generate_and_mesh(bp)
		built += 1
		if built % LOAD_BUDGET_INIT == 0:
			await get_tree().process_frame

	_initial_load_done = true
	print("[TerrainSystem] Initial build complete: %d chunks (%d with geometry)" % [
		_chunks.size(),
		_count_visible_chunks()])

	# Debug: check mesh continuity at chunk boundaries near origin
	debug_check_boundary_continuity(Vector3.ZERO, 64.0)


# ------------------------------------------------------------------
#  Per-frame streaming
# ------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _initial_load_done:
		return

	# Rebuild dirty chunks every frame (craters need fast feedback)
	var rebuilt := 0
	while not _dirty_queue.is_empty() and rebuilt < REBUILD_BUDGET:
		var bp: Vector3i = _dirty_queue.pop_front()
		if _chunks.has(bp):
			_chunks[bp].rebuild(sdf_grid, _mesher)
			rebuilt += 1

	# Streaming check is expensive — run every STREAM_INTERVAL frames
	_stream_frame += 1
	if _stream_frame < STREAM_INTERVAL:
		return
	_stream_frame = 0

	var positions := _get_player_positions()
	var info: Dictionary = _streaming.update(positions, _chunks)

	# Unload out-of-range chunks
	var to_unload: Array[Vector3i] = info["to_unload"]
	for bp: Vector3i in to_unload:
		_unload_chunk(bp)

	# Load new chunks (budgeted)
	var to_load: Array[Vector3i] = info["to_load"]
	var loaded := 0
	for bp: Vector3i in to_load:
		if loaded >= LOAD_BUDGET_PLAY:
			break
		_generate_and_mesh(bp)
		loaded += 1


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
	for bp: Vector3i in _chunks.keys():
		_unload_chunk(bp)
	_chunks.clear()
	_dirty_queue.clear()
	sdf_grid.clear()
	_initial_load_done = false


# ------------------------------------------------------------------
#  Internals
# ------------------------------------------------------------------

func _generate_and_mesh(bp: Vector3i) -> void:
	if not sdf_grid.has_chunk(bp):
		sdf_grid.generate_chunk(bp)
	# Neighbor chunks needed for skirt/padding are generated on the fly
	# by sdf_grid.fill_buffer() if they don't exist yet.

	var chunk := TerrainChunk.new(bp)
	add_child(chunk)
	chunk.build(sdf_grid, _mesher, _terrain_body)
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
