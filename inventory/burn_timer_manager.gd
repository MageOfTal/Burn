extends Node
class_name BurnTimerManager

## Server-side: processes burn timers for one player's inventory.
## Reads global burn multiplier from BurnClock autoload.
## Reads heat burn multiplier from sibling HeatSystem (when available).

var inventory: Inventory = null
var heat_system: Node = null  # Will be typed to HeatSystem when that exists


func _ready() -> void:
	# Find sibling Inventory node
	inventory = get_parent().get_node_or_null("Inventory")
	# Heat system will be connected in M1.6
	heat_system = get_parent().get_node_or_null("HeatSystem")


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if inventory == null:
		return

	var global_mult: float = 1.0
	if Engine.has_singleton("BurnClock"):
		global_mult = BurnClock.get_burn_multiplier()
	elif has_node("/root/BurnClock"):
		global_mult = get_node("/root/BurnClock").get_burn_multiplier()

	var heat_mult: float = 1.0
	if heat_system != null and heat_system.has_method("get_burn_rate_multiplier"):
		heat_mult = heat_system.get_burn_rate_multiplier()

	# Decrement all item timers
	for stack: ItemStack in inventory.items:
		var effective_rate: float = stack.item_data.base_burn_rate * global_mult * heat_mult
		stack.burn_time_remaining -= effective_rate * delta

	# Remove any expired items
	var expired := inventory.remove_expired_items()
	for item_name in expired:
		print("Item burned away: %s" % item_name)
