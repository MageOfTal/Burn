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

	# Use a thick sphere cast (radius 0.5m) for forgiving melee hits.
	# This makes it much easier to connect than a thin raycast.
	var shape := SphereShape3D.new()
	shape.radius = 0.5

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, aim_origin)
	params.motion = aim_direction * reach
	params.exclude = [shooter.get_rid()]
	params.collision_mask = 1 | 2  # Hit anything — we filter for players below

	var _results := space_state.cast_motion(params)

	# Direct collision check along the path
	# Use intersect_shape at multiple points along the swing arc
	var hit_player: CharacterBody3D = null
	var hit_pos := aim_origin + aim_direction * reach
	var steps := 4
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var check_pos := aim_origin + aim_direction * (reach * t)
		params.transform = Transform3D(Basis.IDENTITY, check_pos)
		params.motion = Vector3.ZERO
		var collisions := space_state.intersect_shape(params, 8)
		for col in collisions:
			var collider = col.get("collider")
			if collider is CharacterBody3D and collider != shooter:
				hit_player = collider
				hit_pos = check_pos
				break
		if hit_player:
			break

	if hit_player == null:
		return {"melee_miss": true, "shot_end": aim_origin + aim_direction * reach}

	return {
		"melee_hit": true,
		"hit_collider": hit_player,
		"hit_position": hit_pos,
		"shot_end": hit_pos,
	}
