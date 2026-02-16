extends WeaponBase
class_name WeaponMelee

## Melee weapon: short-range sphere-cast "swing" instead of firing projectiles.
## Uses a shape cast for a forgiving hit area (not a thin raycast).
## Returns {"melee_hit": true, "hit_collider": Node} on hit.

func _do_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	var space_state := shooter.get_world_3d().direct_space_state
	if space_state == null:
		return {"melee_miss": true}

	var reach: float = weapon_data.weapon_range if weapon_data else 3.5

	# Toad dimension players are on layer 9 (256) instead of layer 8 (128)
	var player_bit: int = 256 if shooter.get("in_toad_dimension") else 128

	# Use a thick sphere cast (radius 0.5m) for forgiving melee hits.
	var shape := SphereShape3D.new()
	shape.radius = 0.5

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.exclude = [shooter.get_rid()]
	params.collision_mask = 1 | 2 | player_bit  # World(1) + items(2) + players
	params.motion = Vector3.ZERO

	# Sweep across a 120-degree arc (matching the visual swing effect)
	# to detect players anywhere in the swing, not just directly ahead.
	var arc_half_angle := deg_to_rad(60.0)
	var flat_dir := Vector3(aim_direction.x, 0.0, aim_direction.z).normalized()
	if flat_dir.length_squared() < 0.01:
		flat_dir = Vector3.FORWARD

	var hit_player: CharacterBody3D = null
	var hit_pos := aim_origin + aim_direction * reach
	var best_dist_sq := INF

	var arc_steps := 5   # Angles across the arc
	var reach_steps := 3 # Distance steps along each ray
	for a in range(arc_steps + 1):
		var arc_t := float(a) / float(arc_steps)
		var angle := lerpf(-arc_half_angle, arc_half_angle, arc_t)
		var sweep_dir := flat_dir.rotated(Vector3.UP, angle)

		for r in range(1, reach_steps + 1):
			var t := float(r) / float(reach_steps)
			var check_pos := aim_origin + sweep_dir * (reach * t)
			params.transform = Transform3D(Basis.IDENTITY, check_pos)
			var collisions := space_state.intersect_shape(params, 8)
			for col in collisions:
				var collider = col.get("collider")
				if collider is CharacterBody3D and collider != shooter:
					# Prefer the closest hit to the aim direction center
					var d_sq := check_pos.distance_squared_to(aim_origin)
					if d_sq < best_dist_sq:
						best_dist_sq = d_sq
						hit_player = collider
						hit_pos = check_pos
			# Don't break on first hit per ray — check all rays for closest

	if hit_player == null:
		return {"melee_miss": true, "shot_end": aim_origin + aim_direction * reach}

	return {
		"melee_hit": true,
		"hit_collider": hit_player,
		"hit_position": hit_pos,
		"shot_end": hit_pos,
	}
