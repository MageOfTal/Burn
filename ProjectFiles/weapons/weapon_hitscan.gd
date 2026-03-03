extends WeaponBase
class_name WeaponHitscan

## Hitscan weapon: instant raycast from aim origin along aim direction.
## Supports multi-pellet shotgun firing — each pellet gets independent spread.
## Server-side only.

func _do_fire(shooter: Player, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	# If ammo is slotted with a projectile scene, fire projectiles instead
	if has_ammo_override():
		return _fire_ammo_projectile(shooter, aim_origin, aim_direction)

	var space_state := shooter.get_world_3d().direct_space_state
	var count := maxi(weapon_data.pellet_count, 1)
	if is_shotgun_boosted():
		count *= 2

	var player_bit: int = CollisionLayers.player_bit(shooter.get("in_toad_dimension"))

	var pellets: Array[Dictionary] = []
	for i in count:
		var pellet_dir := _apply_spread(aim_direction)
		var end_point := aim_origin + pellet_dir * weapon_data.weapon_range

		var query := PhysicsRayQueryParameters3D.create(aim_origin, end_point)
		query.exclude = [shooter.get_rid()]
		query.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.BUBBLES | CollisionLayers.RUBBER_BALLS | CollisionLayers.TOAD_WALLS | CollisionLayers.WALL_BLOCKS | player_bit

		var result := space_state.intersect_ray(query)

		if result.is_empty():
			pellets.append({"shot_end": end_point})
		else:
			pellets.append({
				"hit_position": result.position,
				"hit_normal": result.normal,
				"hit_collider": result.collider,
				"hit_shape": result.shape,
				"shot_end": result.position,
			})

	# Single-pellet: flat format for compatibility
	if count == 1:
		return pellets[0]

	return {"pellets": pellets}


func _fire_ammo_projectile(shooter: Player, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	## Fire ammo projectile(s) instead of raycasting when ammo is slotted.
	## Uses ProjectileSpawner so all clients see the projectiles.
	var count := maxi(weapon_data.pellet_count, 1)
	if is_shotgun_boosted():
		count *= 2

	var ammo_mult := get_ammo_damage_mult()
	var per_projectile_damage: float = (weapon_data.get_rarity_damage() * ammo_mult) / count
	var per_projectile_structure_damage: float = (weapon_data.get_rarity_structure_damage() * ammo_mult) / count

	var proj_scene: PackedScene = get_ammo_projectile_scene()
	if proj_scene == null:
		return {}

	var map := shooter.get_tree().current_scene
	if not map.has_method("spawn_projectile"):
		push_warning("WeaponHitscan: map has no spawn_projectile method")
		return {}

	for i in count:
		var pellet_dir := _apply_spread(aim_direction)

		var spawn_offset := get_safe_spawn_offset(shooter, aim_origin, pellet_dir)
		var spawn_pos := aim_origin + pellet_dir * spawn_offset
		map.spawn_projectile(
			proj_scene.resource_path, spawn_pos, pellet_dir,
			shooter.peer_id, per_projectile_damage, per_projectile_structure_damage
		)

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
