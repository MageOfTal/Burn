extends ItemData
class_name AmmoData

## Ammo-specific item data. When slotted into a weapon, overrides the
## weapon's projectile behavior. The gun's base stats (damage, fire_rate, etc.)
## are multiplied by the ammo's multipliers.
##
## Ammo items occupy regular inventory slots and have burn timers like
## everything else. They can be slotted into any weapon via the Tab inventory UI.

@export_group("Ammo Properties")
## The projectile scene to fire when this ammo is slotted.
@export var projectile_scene: PackedScene = null
## Burn fuel cost per shot when using this ammo (added to weapon's base cost).
@export var burn_cost_per_shot: float = 5.0
## Multiplier applied to the gun's base damage.
@export var damage_mult: float = 1.0
## Multiplier applied to projectile visual/collision size (for future enchantments).
@export var size_mult: float = 1.0
## How many projectiles to spawn when an explosion-type weapon detonates.
## Only used by weapons that have explosions (e.g. rocket launcher).
@export var explosion_spawn_count: int = 10
