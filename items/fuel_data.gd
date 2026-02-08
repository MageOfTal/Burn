extends ItemData
class_name FuelData

## Fuel drop item. Picked up instantly and added to player's burn fuel pool.
## Does NOT occupy an inventory slot — consumed immediately on pickup.
## Different rarities give different amounts of fuel.

@export_group("Fuel Properties")
## Amount of burn fuel restored on pickup.
@export var fuel_amount: float = 100.0
