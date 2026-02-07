extends Resource
class_name ItemStack

## Runtime representation of an item in a player's inventory.
## Pairs the static ItemData definition with runtime burn state.

@export var item_data: ItemData = null
@export var burn_time_remaining: float = 0.0
@export var quantity: int = 1


static func create(data: ItemData) -> ItemStack:
	var stack := ItemStack.new()
	stack.item_data = data
	stack.burn_time_remaining = data.initial_burn_time
	stack.quantity = 1
	return stack


func is_expired() -> bool:
	return burn_time_remaining <= 0.0


func serialize() -> Dictionary:
	## Convert to dictionary for network transmission.
	return {
		"item_name": item_data.item_name if item_data else "",
		"item_type": item_data.item_type if item_data else 0,
		"rarity": item_data.rarity if item_data else 0,
		"burn_time_remaining": burn_time_remaining,
		"initial_burn_time": item_data.initial_burn_time if item_data else 0.0,
		"quantity": quantity,
		"damage": item_data.damage if item_data is WeaponData else 0.0,
	}
