extends Node
class_name Inventory

## Manages 6 weapon slots for one player.
## All mutations happen on the server. Clients receive full-state sync via RPC.

const MAX_SLOTS := 6
const STARTING_FUEL := 1000.0

var items: Array[ItemStack] = []
var time_currency: float = 0.0
var equipped_index: int = -1
var burn_fuel: float = STARTING_FUEL

## Shoe equipment slot (separate from the 6 item slots)
var equipped_shoe: ItemStack = null

## Networking: peer_id of the owning player (set by player.gd).
## Server sends inventory RPCs to this peer when state changes.
var _owner_peer_id: int = -1

signal item_added(index: int, stack: ItemStack)
signal item_removed(index: int)
signal item_expired(index: int, item_name: String)
signal inventory_changed
signal weapon_equipped(index: int)
signal shoe_changed
signal fuel_changed(new_amount: float)


# ======================================================================
#  Core item management
# ======================================================================

func add_item(item_data: ItemData) -> int:
	## Add an item to inventory. Returns slot index, or -1 if full.
	if items.size() >= MAX_SLOTS:
		return -1

	var stack := ItemStack.create(item_data)
	items.append(stack)
	var idx := items.size() - 1
	item_added.emit(idx, stack)
	inventory_changed.emit()
	_notify_sync()
	return idx


func equip_slot(index: int) -> void:
	## Equip the weapon, consumable, or gadget in the given slot.
	if index < 0 or index >= items.size():
		return
	if items[index].item_data is WeaponData or items[index].item_data is ConsumableData or items[index].item_data is GadgetData:
		equipped_index = index
		weapon_equipped.emit(index)
		_notify_sync()


func remove_item(index: int) -> ItemStack:
	## Remove and return the item at the given index.
	if index < 0 or index >= items.size():
		return null

	var stack := items[index]
	items.remove_at(index)
	_adjust_equipped_after_removal(index)
	item_removed.emit(index)
	inventory_changed.emit()
	_notify_sync()
	return stack


func sacrifice_item(sacrifice_index: int, target_index: int) -> bool:
	## Destroy the sacrifice item and add its time_currency_value to the target's burn timer.
	if sacrifice_index == target_index:
		return false
	if sacrifice_index < 0 or sacrifice_index >= items.size():
		return false
	if target_index < 0 or target_index >= items.size():
		return false

	var sacrifice := items[sacrifice_index]
	var target := items[target_index]

	var time_added: float = sacrifice.item_data.time_currency_value / target.item_data.burn_cost_to_extend
	target.burn_time_remaining += time_added

	items.remove_at(sacrifice_index)
	_adjust_equipped_after_removal(sacrifice_index)
	item_removed.emit(sacrifice_index)
	inventory_changed.emit()
	_notify_sync()
	return true


func convert_to_time_currency(index: int) -> float:
	## Destroy the item and add its value to the player's time currency.
	if index < 0 or index >= items.size():
		return 0.0

	var stack := items[index]
	var value := stack.item_data.time_currency_value
	time_currency += value

	items.remove_at(index)
	_adjust_equipped_after_removal(index)
	item_removed.emit(index)
	inventory_changed.emit()
	_notify_sync()
	return value


func spend_time_currency(amount: float, target_index: int) -> bool:
	## Spend time currency to extend a specific item's burn timer.
	if target_index < 0 or target_index >= items.size():
		return false
	if time_currency < amount:
		return false

	var target := items[target_index]
	var time_added := amount / target.item_data.burn_cost_to_extend
	target.burn_time_remaining += time_added
	time_currency -= amount
	inventory_changed.emit()
	_notify_sync()
	return true


func remove_expired_items() -> Array[String]:
	## Remove all items with burn_time_remaining <= 0. Returns names of removed items.
	var expired_names: Array[String] = []
	var i := items.size() - 1
	while i >= 0:
		if items[i].is_expired():
			expired_names.append(items[i].item_data.item_name)
			item_expired.emit(i, items[i].item_data.item_name)

			# Clear ammo references pointing at this item
			for j in items.size():
				if items[j].slotted_ammo_source_index == i:
					items[j].slotted_ammo = null
					items[j].slotted_ammo_source_index = -1
				elif items[j].slotted_ammo_source_index > i:
					items[j].slotted_ammo_source_index -= 1

			items.remove_at(i)
			_adjust_equipped_after_removal(i)
		i -= 1

	if expired_names.size() > 0:
		inventory_changed.emit()
		_notify_sync()
	return expired_names


# ======================================================================
#  Shoe slot
# ======================================================================

func equip_shoe(shoe_data: ItemData) -> ItemStack:
	## Equip a shoe. Returns the previously equipped shoe (or null).
	var old_shoe := equipped_shoe
	equipped_shoe = ItemStack.create(shoe_data)
	shoe_changed.emit()
	inventory_changed.emit()
	_notify_sync()
	return old_shoe


func remove_shoe() -> ItemStack:
	var old := equipped_shoe
	equipped_shoe = null
	shoe_changed.emit()
	inventory_changed.emit()
	_notify_sync()
	return old


func get_shoe_speed_bonus() -> float:
	if equipped_shoe == null or equipped_shoe.item_data == null:
		return 0.0
	if equipped_shoe.item_data.item_type == ItemData.ItemType.SHOE:
		var spd = equipped_shoe.item_data.get("speed_bonus")
		return spd if spd != null else 0.0
	return 0.0


# ======================================================================
#  Fuel
# ======================================================================

func add_fuel(amount: float) -> void:
	burn_fuel += amount
	fuel_changed.emit(burn_fuel)
	_notify_sync()


func spend_fuel(amount: float) -> bool:
	if burn_fuel < amount:
		return false
	burn_fuel -= amount
	fuel_changed.emit(burn_fuel)
	_notify_sync()
	return true


func has_fuel(amount: float) -> bool:
	return burn_fuel >= amount


func spend_fuel_silent(amount: float) -> bool:
	## Spend fuel without triggering full inventory sync RPC.
	## Used for high-frequency fuel drains (medkit healing) since burn_fuel
	## is already replicated via ServerSync.
	if burn_fuel < amount:
		return false
	burn_fuel -= amount
	fuel_changed.emit(burn_fuel)
	return true


# ======================================================================
#  Utility
# ======================================================================

func clear_all() -> void:
	## Remove all items (used on death/respawn).
	items.clear()
	equipped_index = -1
	equipped_shoe = null
	burn_fuel = STARTING_FUEL
	shoe_changed.emit()
	inventory_changed.emit()
	fuel_changed.emit(burn_fuel)
	_notify_sync()


func get_serialized() -> Array:
	var result: Array = []
	for stack in items:
		result.append(stack.serialize())
	return result


func _adjust_equipped_after_removal(removed_index: int) -> void:
	## Fix equipped_index after an item is removed from the array.
	if equipped_index == removed_index:
		equipped_index = -1
	elif equipped_index > removed_index:
		equipped_index -= 1


# ======================================================================
#  Network Sync (server → owning client)
# ======================================================================

func _notify_sync() -> void:
	## Server-only: send full inventory state to the owning client.
	## Host (peer 1) doesn't need this — their local Inventory IS the server's.
	if not multiplayer.is_server():
		return
	if _owner_peer_id <= 1:
		return
	# Verify the peer is still connected before sending
	if not multiplayer.multiplayer_peer or not _owner_peer_id in multiplayer.get_peers():
		return
	_rpc_sync_inventory.rpc_id(_owner_peer_id, _serialize_full_state())


func _serialize_full_state() -> Dictionary:
	## Pack full inventory into a serializable Dictionary.
	var item_list: Array = []
	for stack in items:
		item_list.append({
			"path": stack.item_data.resource_path if stack.item_data else "",
			"burn": stack.burn_time_remaining,
			"qty": stack.quantity,
			"fuel_spent": stack.fuel_spent_extending,
			"ammo_path": stack.slotted_ammo.resource_path if stack.slotted_ammo else "",
			"ammo_src": stack.slotted_ammo_source_index,
		})
	return {
		"items": item_list,
		"equipped": equipped_index,
		"tc": time_currency,
		"fuel": burn_fuel,
		"shoe_path": equipped_shoe.item_data.resource_path if equipped_shoe and equipped_shoe.item_data else "",
		"shoe_burn": equipped_shoe.burn_time_remaining if equipped_shoe else 0.0,
	}


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_inventory(state: Dictionary) -> void:
	## Client-side: rebuild local inventory from server state.
	items.clear()
	for entry: Dictionary in state["items"]:
		if entry["path"] == "":
			continue
		var data: ItemData = load(entry["path"])
		if data == null:
			continue
		var stack := ItemStack.create(data)
		stack.burn_time_remaining = entry["burn"]
		stack.quantity = entry["qty"]
		stack.fuel_spent_extending = entry["fuel_spent"]
		if entry["ammo_path"] != "":
			stack.slotted_ammo = load(entry["ammo_path"])
			stack.slotted_ammo_source_index = entry["ammo_src"]
		items.append(stack)

	equipped_index = state["equipped"]
	time_currency = state["tc"]
	burn_fuel = state["fuel"]

	if state["shoe_path"] != "":
		var shoe_data: ItemData = load(state["shoe_path"])
		if shoe_data:
			equipped_shoe = ItemStack.create(shoe_data)
			equipped_shoe.burn_time_remaining = state["shoe_burn"]
		else:
			equipped_shoe = null
	else:
		equipped_shoe = null

	inventory_changed.emit()
	shoe_changed.emit()
	fuel_changed.emit(burn_fuel)
