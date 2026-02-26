class_name WeaponFactory

## Static utility for creating weapon instances from WeaponData.
## Centralizes the weapon type → script mapping that was previously
## an if/else chain in player.gd equip_weapon().

const WeaponProjectileScript = preload("res://weapons/weapon_projectile.gd")
const WeaponMeleeScript = preload("res://weapons/weapon_melee.gd")
const WeaponLaggerScript = preload("res://weapons/weapon_lagger.gd")


static func create_weapon(data: WeaponData) -> WeaponBase:
	## Create and configure a weapon node from WeaponData.
	## Returns null if data is null.
	if data == null:
		return null

	var weapon: WeaponBase
	if data.is_debug_lagger:
		weapon = WeaponLaggerScript.new()
	elif data.is_hitscan:
		weapon = WeaponHitscan.new()
	elif data.projectile_scene != null:
		weapon = WeaponProjectileScript.new()
	else:
		weapon = WeaponMeleeScript.new()

	weapon.setup(data)
	return weapon
