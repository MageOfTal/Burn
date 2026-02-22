extends WeaponBase
class_name WeaponProjectile

## Projectile-based weapon: spawns a physics projectile instead of raycasting.
## Server-side only — projectile is spawned via ProjectileSpawner so all
## clients see it. queue_free() on server auto-removes on clients.

func _do_fire(shooter: Player, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	# ALWAYS fire the weapon's own projectile (e.g. rocket).
	# Ammo overrides are passed TO the projectile via set_ammo_override(),
	# so rockets explode into bubbles/balls rather than being replaced by them.
	var proj_scene: PackedScene = weapon_data.projectile_scene

	if proj_scene == null:
		push_warning("WeaponProjectile: no projectile_scene set on " + weapon_data.item_name)
		return {}

	var scaled_damage: float = weapon_data.get_rarity_damage()

	# Apply ammo damage multiplier when ammo is slotted
	if ammo_data:
		scaled_damage *= get_ammo_damage_mult()

	# Spawn projectile in front of the barrel, but check for walls first
	# so the projectile doesn't clip through nearby geometry.
	var spawn_offset := get_safe_spawn_offset(shooter, aim_origin, aim_direction)
	var spawn_pos := aim_origin + aim_direction * spawn_offset

	# Spawn via ProjectileSpawner — replicates to all clients automatically.
	# queue_free() on server auto-removes on all clients.
	var ammo_path := ""
	if ammo_data and ammo_data.can_slot_as_ammo:
		ammo_path = ammo_data.get_source_path()
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
