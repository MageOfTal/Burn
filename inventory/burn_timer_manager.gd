extends Node
class_name BurnTimerManager

## Server-side: processes burn timers for one player's inventory.
## Reads global burn multiplier from BurnClock autoload.
## Reads heat burn multiplier from sibling HeatSystem.

var inventory: Inventory = null
var heat_system: HeatSystem = null
var _burn_clock: Node = null


func _ready() -> void:
	inventory = get_parent().get_node_or_null("Inventory")
	heat_system = get_parent().get_node_or_null("HeatSystem")
	# Cache the BurnClock autoload once instead of looking it up every frame
	if has_node("/root/BurnClock"):
		_burn_clock = get_node("/root/BurnClock")


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or inventory == null:
		return
	if GameManager.debug_disable_burn_timers:
		return

	var global_mult: float = _burn_clock.get_burn_multiplier() if _burn_clock else 1.0
	var heat_mult: float = heat_system.get_burn_rate_multiplier() if heat_system else 1.0

	# Decrement all item timers
	for stack: ItemStack in inventory.items:
		stack.burn_time_remaining -= stack.item_data.base_burn_rate * global_mult * heat_mult * delta

	# Remove expired items
	var expired := inventory.remove_expired_items()
	for item_name in expired:
		print("Item burned away: %s" % item_name)

	# Decrement shoe burn timer
	if inventory.equipped_shoe != null:
		var shoe_rate: float = inventory.equipped_shoe.item_data.base_burn_rate * global_mult * heat_mult
		inventory.equipped_shoe.burn_time_remaining -= shoe_rate * delta
		if inventory.equipped_shoe.is_expired():
			var shoe_name: String = inventory.equipped_shoe.item_data.item_name
			inventory.equipped_shoe = null
			inventory.shoe_changed.emit()
			inventory.inventory_changed.emit()
			print("Shoes burned away: %s" % shoe_name)
