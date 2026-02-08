extends ItemData
class_name WeaponData

## Weapon-specific item data.

@export_group("Combat")
@export var damage: float = 15.0
@export var fire_rate: float = 0.3  ## Seconds between shots.
## Burn fuel cost per shot (base cost, before ammo). All guns cost fuel to fire.
@export var burn_fuel_cost: float = 2.0
@export var weapon_range: float = 100.0
@export var spread: float = 0.0  ## Degrees of bullet spread.
@export var pellet_count: int = 1  ## Number of pellets per shot (shotguns use 6-12). Damage is split across pellets.
@export var is_hitscan: bool = true
@export var projectile_scene: PackedScene = null

@export_group("Heat")
## How much heat each shot generates.
@export var heat_per_shot: float = 2.0

@export_group("ADS / Scope")
## ADS FOV override (0 = no zoom, i.e. hip-fire only weapon).
@export var ads_fov: float = 0.0
## Spread multiplier while ADS (e.g. 0.3 = 30% of hip spread).
@export var ads_spread_mult: float = 0.3
## If true, show a scope overlay (sniper/bolt-action feel).
@export var has_scope: bool = false

@export_group("Barrel Offset")
## Where the barrel tip is relative to the WeaponMount origin, in local space.
## X = right, Y = up, Z = forward (negative Z = in front of the player).
@export var barrel_offset: Vector3 = Vector3(0.0, 0.0, -0.8)

@export_group("Ammo Slot")
## If true, this weapon can receive ammo modules (has an ammo slot).
## Simple projectile weapons like Bubble and Rubber Ball should be false.
@export var can_receive_ammo: bool = true

@export_group("Ammo Mode")
## If true, this weapon can also be slotted into other weapons as ammo.
## It will appear in both the WEAPONS and AMMO MODULES sections of the inventory.
@export var can_slot_as_ammo: bool = false
## Burn fuel cost per shot when used as ammo in another weapon.
@export var ammo_burn_cost_per_shot: float = 5.0
## Damage multiplier when used as ammo in another weapon.
@export var ammo_damage_mult: float = 0.5
## How many projectiles to scatter when used as ammo in an explosion weapon (e.g. rocket).
@export var ammo_explosion_spawn_count: int = 10

@export_group("Visuals")
## Path to the .glb gun model (res:// path).
@export var gun_model_path: String = ""
## Path to the fire sound .ogg (res:// path).
@export var fire_sound_path: String = ""
