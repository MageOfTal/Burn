extends StaticBody3D

## Compound hit body for FallingBlockCluster — one StaticBody3D with N shapes,
## one per block. Maps shape_index → grid_key for hitscan targeting.
## Much faster than N individual StaticBody3D nodes (per-block).

var parent_wall: Node = null
var _shape_to_key: Array[Vector3i] = []


func take_damage_at_shape(amount: float, attacker_id: int, shape_idx: int) -> void:
	## Called by hitscan weapons when a bullet hits a specific shape (block).
	if not multiplayer.is_server():
		return
	if shape_idx < 0 or shape_idx >= _shape_to_key.size():
		return
	if parent_wall and is_instance_valid(parent_wall):
		parent_wall._damage_block(_shape_to_key[shape_idx], amount, attacker_id)


func take_damage(amount: float, attacker_id: int) -> void:
	## Fallback for non-shape-specific damage — distributes evenly across all blocks.
	if not multiplayer.is_server():
		return
	if parent_wall and is_instance_valid(parent_wall):
		parent_wall.take_damage(amount, attacker_id)
