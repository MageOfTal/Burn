extends ItemData
class_name WeaponData

## Weapon-specific item data.

@export_group("Combat")
@export var damage: float = 15.0
@export var fire_rate: float = 0.3  ## Seconds between shots.
@export var weapon_range: float = 100.0
@export var spread: float = 0.0  ## Degrees of bullet spread.
@export var is_hitscan: bool = true
@export var projectile_scene: PackedScene = null

@export_group("Heat")
## How much heat each shot generates.
@export var heat_per_shot: float = 2.0

@export_group("Visuals")
## Path to the .glb gun model (res:// path).
@export var gun_model_path: String = ""
## Path to the fire sound .ogg (res:// path).
@export var fire_sound_path: String = ""
