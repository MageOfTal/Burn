extends WeaponBase
class_name WeaponHitscan

## Hitscan weapon: instant raycast from aim origin along aim direction.
## Server-side only.

func _do_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	var space_state := shooter.get_world_3d().direct_space_state

	# Apply spread
	if weapon_data.spread > 0.0:
		var spread_rad := deg_to_rad(weapon_data.spread)
		aim_direction = aim_direction.rotated(
			Vector3.UP, randf_range(-spread_rad, spread_rad)
		)
		aim_direction = aim_direction.rotated(
			aim_direction.cross(Vector3.UP).normalized(),
			randf_range(-spread_rad, spread_rad)
		)

	var end_point := aim_origin + aim_direction * weapon_data.weapon_range

	var query := PhysicsRayQueryParameters3D.create(aim_origin, end_point)
	query.exclude = [shooter.get_rid()]
	query.collision_mask = 0xFFFFFFFF  # Hit everything

	var result := space_state.intersect_ray(query)

	if result.is_empty():
		# Miss — still return shot_end for tracer FX
		return {"shot_end": end_point}

	return {
		"hit_position": result.position,
		"hit_normal": result.normal,
		"hit_collider": result.collider,
		"shot_end": result.position,
	}
