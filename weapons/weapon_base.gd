extends Node3D
class_name WeaponBase

## Base weapon behavior. Attached to the player's weapon mount point.
## Server-authoritative: only the server processes firing logic.

var weapon_data: WeaponData = null
var cooldown_remaining: float = 0.0


func setup(data: WeaponData) -> void:
	weapon_data = data


func can_fire() -> bool:
	return weapon_data != null and cooldown_remaining <= 0.0


func try_fire(shooter: CharacterBody3D, aim_origin: Vector3, aim_direction: Vector3) -> Dictionary:
	## Attempts to fire. Returns hit info dictionary or empty dict on miss.
	## Only call on the server.
	if not can_fire():
		return {}

	cooldown_remaining = weapon_data.fire_rate
	return _do_fire(shooter, aim_origin, aim_direction)


func _do_fire(_shooter: CharacterBody3D, _aim_origin: Vector3, _aim_direction: Vector3) -> Dictionary:
	## Override in subclasses.
	return {}


func _physics_process(delta: float) -> void:
	if cooldown_remaining > 0.0:
		cooldown_remaining -= delta
