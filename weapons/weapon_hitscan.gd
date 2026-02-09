extends WeaponBase
class_name WeaponHitscan

## Hitscan weapon: instant raycast from aim origin along aim direction.
## Supports multi-pellet shotgun firing — each pellet gets independent spread.
## Server-side only.

func _do_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	# If ammo is slotted with a projectile scene, fire projectiles instead
	if has_ammo_override():
		return _fire_ammo_projectile(shooter, aim_origin, aim_direction)

	var space_state := shooter.get_world_3d().direct_space_state
	var count := maxi(weapon_data.pellet_count, 1)

	var pellets: Array[Dictionary] = []
	for i in count:
		var pellet_dir := _apply_spread(aim_direction)
		var end_point := aim_origin + pellet_dir * weapon_data.weapon_range

		var query := PhysicsRayQueryParameters3D.create(aim_origin, end_point)
		query.exclude = [shooter.get_rid()]
		query.collision_mask = 0xFFFFFFFF

		var result := space_state.intersect_ray(query)

		if result.is_empty():
			pellets.append({"shot_end": end_point})
		else:
			pellets.append({
				"hit_position": result.position,
				"hit_normal": result.normal,
				"hit_collider": result.collider,
				"shot_end": result.position,
			})

	# Single-pellet: flat format for compatibility
	if count == 1:
		return pellets[0]

	return {"pellets": pellets}


func _fire_ammo_projectile(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	## Fire ammo projectile(s) instead of raycasting when ammo is slotted.
	var count := maxi(weapon_data.pellet_count, 1)

	var rarity_mult: float = 1.0 + weapon_data.rarity * 0.15
	var per_projectile_damage: float = (weapon_data.damage * rarity_mult * get_ammo_damage_mult()) / count

	var proj_scene: PackedScene = get_ammo_projectile_scene()
	if proj_scene == null:
		return {}

	var map := shooter.get_tree().current_scene
	var container := map.get_node_or_null("Projectiles")
	if container == null:
		container = Node3D.new()
		container.name = "Projectiles"
		map.add_child(container)

	for i in count:
		var pellet_dir := _apply_spread(aim_direction)

		var projectile: Node3D = proj_scene.instantiate()
		if projectile.has_method("launch"):
			projectile.launch(pellet_dir, shooter.peer_id, per_projectile_damage)

		container.add_child(projectile, true)

		# Spawn in front of barrel with wall check
		var spawn_offset := 1.0
		var space_state := shooter.get_world_3d().direct_space_state
		if space_state:
			var ray_query := PhysicsRayQueryParameters3D.create(
				aim_origin, aim_origin + pellet_dir * spawn_offset
			)
			ray_query.exclude = [shooter.get_rid()]
			ray_query.collision_mask = 1
			var ray_result := space_state.intersect_ray(ray_query)
			if not ray_result.is_empty():
				spawn_offset = maxf(aim_origin.distance_to(ray_result.position) - 0.1, 0.2)

		projectile.global_position = aim_origin + pellet_dir * spawn_offset

	return {"shot_end": aim_origin + aim_direction * 2.0}


# ======================================================================
#  Shared spread helper (used by both hitscan and ammo-projectile paths)
# ======================================================================

func _apply_spread(base_direction: Vector3) -> Vector3:
	## Apply random cone spread to a direction. Returns base_direction unchanged if spread == 0.
	if weapon_data.spread <= 0.0:
		return base_direction

	var spread_rad := deg_to_rad(weapon_data.spread)
	var angle := randf() * TAU
	var radius := randf_range(0.0, spread_rad)

	# Build perpendicular axes
	var right := base_direction.cross(Vector3.UP)
	if right.length() < 0.001:
		right = base_direction.cross(Vector3.RIGHT)
	right = right.normalized()
	var up := right.cross(base_direction).normalized()

	var result := base_direction.rotated(right, radius * cos(angle))
	result = result.rotated(up, radius * sin(angle))
	return result.normalized()
