extends Resource
class_name ModifierData

## Data definition for a weapon modifier. Saved as .tres files.
##
## Modifiers alter weapon behavior through hook points (on_fire, on_hit, etc.).
## Each modifier has a runtime script (ModifierBase subclass) that implements
## the actual behavior. ModifierData is the serializable configuration;
## ModifierBase is the live instance attached to a weapon.
##
## Example modifiers (not yet implemented):
##   - Explosive: on_hit → spawn secondary explosion
##   - Burning: on_hit → apply DOT to target
##   - Phasing: on_fire → projectile ignores first wall hit

@export var modifier_id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D = null
@export var rarity: ItemData.Rarity = ItemData.Rarity.COMMON

## The script to instantiate for runtime behavior (must extend ModifierBase).
@export var modifier_script: GDScript = null

## Which weapon types this modifier can be attached to.
## Empty array = compatible with all weapon types.
@export var compatible_hitscan: bool = true
@export var compatible_projectile: bool = true
@export var compatible_melee: bool = true
