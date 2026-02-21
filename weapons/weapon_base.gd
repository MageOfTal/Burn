extends Node3D
class_name WeaponBase

## Base weapon behavior. Attached to the player's weapon mount point.
## Server-authoritative: only the server processes firing logic.

var weapon_data: WeaponData = null
var cooldown_remaining: float = 0.0
## Set by player before firing. If non-null, overrides the weapon's projectile.
var ammo_data: WeaponData = null


func setup(data: WeaponData) -> void:
	weapon_data = data


func can_fire() -> bool:
	return weapon_data != null and cooldown_remaining <= 0.0


func is_shotgun_boosted() -> bool:
	## Returns true if this is the double barrel shotgun and boost debug is active.
	return (GameManager.debug_shotgun_boost
		and weapon_data != null
		and weapon_data.get_source_path() == "res://items/definitions/gun_jeg_double_barrel_shotgun.tres")


func try_fire(shooter: Player, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	## Attempts to fire. Returns hit info dictionary or empty dict on miss.
	## Only call on the server.
	if not can_fire():
		return {}

	cooldown_remaining = weapon_data.fire_rate * (0.5 if is_shotgun_boosted() else 1.0)
	return _do_fire(shooter, aim_origin, aim_direction)


func _do_fire(_shooter: Player, _aim_origin: Vector3, _aim_direction: Vector3) -> Dictionary:
	## Override in subclasses.
	return {}


func _physics_process(delta: float) -> void:
	if cooldown_remaining > 0.0:
		cooldown_remaining -= delta


## --- Projectile spawn helper ---

func get_safe_spawn_offset(shooter: Player, origin: Vector3, direction: Vector3, base_offset: float = 1.0) -> float:
	## Raycast from origin along direction to prevent spawning projectiles inside walls.
	## Returns a safe offset distance (may be shorter than base_offset if a wall is close).
	var space_state := shooter.get_world_3d().direct_space_state
	if space_state:
		var ray_query := PhysicsRayQueryParameters3D.create(
			origin, origin + direction * base_offset
		)
		ray_query.exclude = [shooter.get_rid()]
		ray_query.collision_mask = 1  # Terrain / structures
		var ray_result := space_state.intersect_ray(ray_query)
		if not ray_result.is_empty():
			return maxf(origin.distance_to(ray_result.position) - 0.1, 0.2)
	return base_offset


## --- Ammo helper methods ---
## These extract ammo properties from a WeaponData with can_slot_as_ammo.

func has_ammo_override() -> bool:
	## Returns true if ammo_data is set and has a projectile scene.
	return ammo_data != null and ammo_data.can_slot_as_ammo and ammo_data.projectile_scene != null


func get_ammo_projectile_scene() -> PackedScene:
	## Returns the projectile scene from slotted ammo.
	if ammo_data != null:
		return ammo_data.projectile_scene
	return null


func get_ammo_damage_mult() -> float:
	## Returns the damage multiplier from slotted ammo.
	if ammo_data != null:
		return ammo_data.ammo_damage_mult
	return 1.0


func get_ammo_explosion_spawn_count() -> int:
	## Returns the explosion scatter count from slotted ammo.
	if ammo_data != null:
		return ammo_data.ammo_explosion_spawn_count
	return 0
