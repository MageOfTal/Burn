class_name TerrainStreaming
extends RefCounted

## Determines which terrain chunks should be loaded based on player positions.
## Returns sets of chunks to load and unload each tick.

const CHUNK_SIZE := 16

var _view_distance: float
var _height_range: float
var _min_by: int
var _max_by: int

# Cache: only rebuild needed set when players move to a different chunk.
var _cached_needed: Dictionary = {}
var _cached_player_chunks: Array[Vector2i] = []


func _init(view_distance: float, height_range: float) -> void:
	_view_distance = view_distance
	_height_range = height_range
	_min_by = -1
	_max_by = int(ceil(height_range / CHUNK_SIZE)) + 1


func update(player_positions: Array[Vector3], loaded: Dictionary) -> Dictionary:
	## Returns { "needed": Dictionary, "to_load": Array[Vector3i], "to_unload": Array[Vector3i] }
	if player_positions.is_empty():
		player_positions = [Vector3.ZERO]

	# Check if any player moved to a different chunk
	var current_chunks: Array[Vector2i] = []
	for pos in player_positions:
		current_chunks.append(Vector2i(int(floor(pos.x / CHUNK_SIZE)), int(floor(pos.z / CHUNK_SIZE))))

	var chunks_changed := current_chunks.size() != _cached_player_chunks.size()
	if not chunks_changed:
		for i in current_chunks.size():
			if current_chunks[i] != _cached_player_chunks[i]:
				chunks_changed = true
				break

	# Rebuild needed set only when chunks changed
	if chunks_changed or _cached_needed.is_empty():
		_cached_player_chunks = current_chunks
		_cached_needed.clear()
		var range_blocks: int = int(ceil(_view_distance / CHUNK_SIZE))
		var vd_sq: float = _view_distance * _view_distance
		for pos in player_positions:
			var cx: int = int(floor(pos.x / CHUNK_SIZE))
			var cz: int = int(floor(pos.z / CHUNK_SIZE))
			for bx in range(cx - range_blocks, cx + range_blocks + 1):
				for bz in range(cz - range_blocks, cz + range_blocks + 1):
					var dx: float = (float(bx) + 0.5) * CHUNK_SIZE - pos.x
					var dz: float = (float(bz) + 0.5) * CHUNK_SIZE - pos.z
					if dx * dx + dz * dz > vd_sq:
						continue
					for by in range(_min_by, _max_by + 1):
						_cached_needed[Vector3i(bx, by, bz)] = true

	# to_load: needed but not loaded
	var to_load: Array[Vector3i] = []
	for bp: Vector3i in _cached_needed:
		if not loaded.has(bp):
			to_load.append(bp)

	# Sort by squared distance to nearest player (closest first)
	if to_load.size() > 1:
		var positions := player_positions
		to_load.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
			return _min_dist_sq(a, positions) < _min_dist_sq(b, positions))

	# to_unload: loaded but not needed
	var to_unload: Array[Vector3i] = []
	for bp: Vector3i in loaded:
		if not _cached_needed.has(bp):
			to_unload.append(bp)

	return { "needed": _cached_needed, "to_load": to_load, "to_unload": to_unload }


func _min_dist_sq(bp: Vector3i, positions: Array[Vector3]) -> float:
	var center := Vector3(
		(float(bp.x) + 0.5) * CHUNK_SIZE,
		(float(bp.y) + 0.5) * CHUNK_SIZE,
		(float(bp.z) + 0.5) * CHUNK_SIZE)
	var best: float = INF
	for p in positions:
		var d := center.distance_squared_to(p)
		if d < best:
			best = d
	return best
