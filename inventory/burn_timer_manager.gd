extends Node
class_name BurnTimerManager

## Server-side: processes burn timers for one player's inventory.
## Reads global burn multiplier from BurnClock autoload.
## Reads heat burn multiplier from sibling HeatSystem.
## Periodically syncs burn state to the owning client so their HUD
## shows live countdowns (not just stale values from the last mutation).

const SYNC_INTERVAL := 1.0  ## Seconds between periodic inventory syncs to client

var inventory: Inventory = null
var heat_system: HeatSystem = null
var _burn_clock: Node = null
var _sync_timer: float = 0.0


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

	# Decrement all item timers (skip null slots)
	for stack in inventory.items:
		if stack == null:
			continue
		stack.burn_time_remaining -= stack.item_data.base_burn_rate * global_mult * heat_mult * delta

	# Remove expired items (this calls _notify_sync internally)
	var prev_equipped := inventory.equipped_index
	var expired := inventory.remove_expired_items()
	for item_name in expired:
		print("Item burned away: %s" % item_name)

	# If the equipped weapon slot was cleared by expiry, tell the player to
	# drop its current_weapon so a burned-out weapon can't keep firing.
	if expired.size() > 0 and prev_equipped >= 0 and inventory.equipped_index == -1:
		var player := get_parent()
		if player and player.has_method("clear_equipped_weapon"):
			player.clear_equipped_weapon()

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

	# Periodic sync: push current burn timers to the owning client every SYNC_INTERVAL
	# so their HUD shows live countdowns, not stale values from the last mutation.
	_sync_timer += delta
	if _sync_timer >= SYNC_INTERVAL:
		_sync_timer = 0.0
		if inventory.items.size() > 0 or inventory.equipped_shoe != null:
			inventory._notify_sync()
