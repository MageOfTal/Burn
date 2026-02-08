extends WeaponBase
class_name WeaponProjectile

## Projectile-based weapon: spawns a physics projectile instead of raycasting.
## Server-side only — projectile is added to the scene tree and synced via
## Godot's built-in multiplayer replication.

func _do_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	# ALWAYS fire the weapon's own projectile (e.g. rocket).
	# Ammo overrides are passed TO the projectile via set_ammo_override(),
	# so rockets explode into bubbles/balls rather than being replaced by them.
	var proj_scene: PackedScene = weapon_data.projectile_scene

	if proj_scene == null:
		push_warning("WeaponProjectile: no projectile_scene set on " + weapon_data.item_name)
		return {}

	# Spawn the projectile on the server
	var projectile: Node3D = proj_scene.instantiate()

	# Rarity damage bonus: +15% per rarity tier
	var rarity_mult: float = 1.0 + weapon_data.rarity * 0.15
	var scaled_damage: float = weapon_data.damage * rarity_mult

	# Apply ammo damage multiplier when ammo is slotted
	if ammo_data:
		scaled_damage *= get_ammo_damage_mult()

	# Set projectile properties (rocket_projectile.gd expects these)
	if projectile.has_method("launch"):
		projectile.launch(aim_direction, shooter.peer_id, scaled_damage)
	else:
		push_warning("WeaponProjectile: projectile scene missing launch() method")

	# Pass ammo data to the projectile for explosion scatter (rockets with ammo)
	if ammo_data and projectile.has_method("set_ammo_override"):
		projectile.set_ammo_override(ammo_data)

	# Add to a Projectiles container in the map (create if needed)
	var map := shooter.get_tree().current_scene
	var container := map.get_node_or_null("Projectiles")
	if container == null:
		container = Node3D.new()
		container.name = "Projectiles"
		map.add_child(container)
	container.add_child(projectile, true)

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

	projectile.global_position = aim_origin + aim_direction * spawn_offset

	# Return shot_end for muzzle flash (short distance — the rocket is the visual)
	return {"shot_end": aim_origin + aim_direction * minf(spawn_offset + 0.5, 2.0)}
