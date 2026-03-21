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
	var _t_shape_dmg := Time.get_ticks_usec()
	if shape_idx < 0 or shape_idx >= _shape_to_key.size():
		if GameManager.debug_show_block_hits:
			print("[BLOCK_MISS] shape_idx=%d out of range (size=%d) on %s" % [
				shape_idx, _shape_to_key.size(), name])
		return
	var key: Vector3i = _shape_to_key[shape_idx]
	if parent_wall and is_instance_valid(parent_wall):
		# Debug: show which block the raycast resolved to
		if GameManager.debug_show_block_hits:
			var block_world: Vector3
			var has_block: bool
			var hp: float = 0.0
			if parent_wall is DestructibleBlockStructure:
				block_world = parent_wall.global_transform * parent_wall._block_local_pos(key)
				has_block = parent_wall._block_hp_dict.has(key)
				hp = parent_wall._block_hp_dict.get(key, 0.0)
			elif parent_wall.has_node("") and parent_wall.get("grid") != null:
				# FallingBlockCluster
				block_world = parent_wall.global_transform * parent_wall.grid.block_local_pos(key)
				has_block = parent_wall.grid.block_hp.has(key)
				hp = parent_wall.grid.block_hp.get(key, 0.0)
			else:
				block_world = global_position
				has_block = false
			DestructibleBlockStructure.debug_draw_block_hit(
				get_tree().current_scene, block_world,
				DestructibleBlockStructure.BLOCK_SIZE, has_block,
				"shape=%d key=%s hp=%.1f dmg=%.1f %s" % [shape_idx, str(key), hp, amount, parent_wall.name])
			# Also draw the shape's physics position for comparison
			var shape_xform: Transform3D = PhysicsServer3D.body_get_shape_transform(get_rid(), shape_idx)
			var shape_world: Vector3 = global_transform * shape_xform.origin
			if block_world.distance_to(shape_world) > 0.01:
				DestructibleBlockStructure.debug_draw_block_hit(
					get_tree().current_scene, shape_world,
					DestructibleBlockStructure.BLOCK_SIZE * 0.8, false,
					"MISMATCH shape_pos=%s vs block_pos=%s delta=%.3f" % [
						str(shape_world), str(block_world),
						block_world.distance_to(shape_world)])
		parent_wall._damage_block(key, amount, attacker_id)
		var _t_shape_us := Time.get_ticks_usec() - _t_shape_dmg
		if _t_shape_us > 200:
			print("[PERF] compound_hit_body.take_damage_at_shape %s: shape=%d key=%s total=%dus" % [
				name, shape_idx, str(key), _t_shape_us])


func take_damage(amount: float, attacker_id: int) -> void:
	## Fallback for non-shape-specific damage — distributes evenly across all blocks.
	if not multiplayer.is_server():
		return
	if parent_wall and is_instance_valid(parent_wall):
		parent_wall.take_damage(amount, attacker_id)
