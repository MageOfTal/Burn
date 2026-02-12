extends WeaponBase
class_name WeaponProjectile

## Projectile-based weapon: spawns a physics projectile instead of raycasting.
## Server-side only — projectile is spawned via ProjectileSpawner so all
## clients see it. queue_free() on server auto-removes on clients.

func _do_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	# ALWAYS fire the weapon's own projectile (e.g. rocket).
	# Ammo overrides are passed TO the projectile via set_ammo_override(),
	# so rockets explode into bubbles/balls rather than being replaced by them.
	var proj_scene: PackedScene = weapon_data.projectile_scene

	if proj_scene == null:
		push_warning("WeaponProjectile: no projectile_scene set on " + weapon_data.item_name)
		return {}

	# Rarity damage bonus: +15% per rarity tier
	var rarity_mult: float = 1.0 + weapon_data.rarity * 0.15
	var scaled_damage: float = weapon_data.damage * rarity_mult

	# Apply ammo damage multiplier when ammo is slotted
	if ammo_data:
		scaled_damage *= get_ammo_damage_mult()

	# Spawn projectile in front of the barrel, but check for walls first
	# so the projectile doesn't clip through nearby geometry.
	var spawn_offset := 1.0
	var space_state := shooter.get_world_3d().direct_space_state
	if space_state:
		var ray_query := PhysicsRayQueryParameters3D.create(
			aim_origin, aim_origin + aim_direction * spawn_offset
		)
		ray_query.exclude = [shooter.get_rid()]
		ray_query.collision_mask = 1  # Terrain / structures
		var ray_result := space_state.intersect_ray(ray_query)
		if not ray_result.is_empty():
			# Wall in the way — spawn just before the hit point
			spawn_offset = maxf(aim_origin.distance_to(ray_result.position) - 0.1, 0.2)

	var spawn_pos := aim_origin + aim_direction * spawn_offset

	# Spawn via ProjectileSpawner — replicates to all clients automatically.
	# queue_free() on server auto-removes on all clients.
	var ammo_path := ""
	if ammo_data and ammo_data.can_slot_as_ammo:
		ammo_path = ammo_data.resource_path
	var map := shooter.get_tree().current_scene
	if map.has_method("spawn_projectile"):
		map.spawn_projectile(
			proj_scene.resource_path, spawn_pos, aim_direction,
			shooter.peer_id, scaled_damage, ammo_path
		)
	else:
		push_warning("WeaponProjectile: map has no spawn_projectile method")

	# Return shot_end for muzzle flash (short distance — the rocket is the visual)
	return {"shot_end": aim_origin + aim_direction * minf(spawn_offset + 0.5, 2.0)}
