extends ItemData
class_name ConsumableData

## Consumable-specific item data. Single-use items with special effects.

@export_group("Consumable")
## Which consumable effect this item triggers when used.
@export_enum("KAMIKAZE_MISSILE", "MEDKIT") var consumable_effect: int = 0
