extends Node
class_name Inventory

## Manages 6 weapon slots for one player.
## All mutations happen on the server. Clients receive updates via RPC.

const MAX_SLOTS := 6
const STARTING_FUEL := 1000.0

var items: Array[ItemStack] = []
var time_currency: float = 0.0
var equipped_index: int = -1
var burn_fuel: float = STARTING_FUEL  ## Player's burn fuel pool (used to fire weapons)

## Shoe equipment slot (separate from the 6 item slots)
var equipped_shoe: ItemStack = null

signal item_added(index: int, stack: ItemStack)
signal item_removed(index: int)
signal item_expired(index: int, item_name: String)
signal inventory_changed
signal weapon_equipped(index: int)
signal shoe_changed
signal fuel_changed(new_amount: float)


func add_item(item_data: ItemData) -> int:
	## Add an item to inventory. Returns slot index, or -1 if full.
	if items.size() >= MAX_SLOTS:
		return -1

	var stack := ItemStack.create(item_data)
	items.append(stack)
	var idx := items.size() - 1
	item_added.emit(idx, stack)
	inventory_changed.emit()
	return idx


func equip_slot(index: int) -> void:
	## Equip the weapon in the given slot.
	if index < 0 or index >= items.size():
		return
	if items[index].item_data is WeaponData:
		equipped_index = index
		weapon_equipped.emit(index)


func remove_item(index: int) -> ItemStack:
	## Remove and return the item at the given index.
	if index < 0 or index >= items.size():
		return null

	var stack := items[index]
	items.remove_at(index)
	# Adjust equipped index after removal
	if equipped_index == index:
		equipped_index = -1
	elif equipped_index > index:
		equipped_index -= 1
	item_removed.emit(index)
	inventory_changed.emit()
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

	# Calculate time added based on sacrifice value and target's cost
	var time_added: float = sacrifice.item_data.time_currency_value / target.item_data.burn_cost_to_extend
	target.burn_time_remaining += time_added

	# Remove the sacrificed item (adjust target index if needed)
	items.remove_at(sacrifice_index)
	# Adjust equipped index after removal
	if equipped_index == sacrifice_index:
		equipped_index = -1
	elif equipped_index > sacrifice_index:
		equipped_index -= 1
	item_removed.emit(sacrifice_index)
	inventory_changed.emit()
	return true


func convert_to_time_currency(index: int) -> float:
	## Destroy the item and add its value to the player's time currency.
	if index < 0 or index >= items.size():
		return 0.0

	var stack := items[index]
	var value := stack.item_data.time_currency_value
	time_currency += value

	items.remove_at(index)
	# Adjust equipped index after removal
	if equipped_index == index:
		equipped_index = -1
	elif equipped_index > index:
		equipped_index -= 1
	item_removed.emit(index)
	inventory_changed.emit()
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
	return true


func remove_expired_items() -> Array[String]:
	## Remove all items with burn_time_remaining <= 0. Returns names of removed items.
	var expired_names: Array[String] = []
	var i := items.size() - 1
	while i >= 0:
		if items[i].is_expired():
			expired_names.append(items[i].item_data.item_name)
			item_expired.emit(i, items[i].item_data.item_name)

			# Clear ammo references from any weapons that had this item slotted
			for j in items.size():
				if items[j].slotted_ammo_source_index == i:
					items[j].slotted_ammo = null
					items[j].slotted_ammo_source_index = -1
				elif items[j].slotted_ammo_source_index > i:
					items[j].slotted_ammo_source_index -= 1

			items.remove_at(i)
			# Adjust equipped index
			if equipped_index == i:
				equipped_index = -1
			elif equipped_index > i:
				equipped_index -= 1
		i -= 1

	if expired_names.size() > 0:
		inventory_changed.emit()
	return expired_names


func equip_shoe(shoe_data: ItemData) -> ItemStack:
	## Equip a shoe. Returns the previously equipped shoe (or null).
	var old_shoe := equipped_shoe
	equipped_shoe = ItemStack.create(shoe_data)
	shoe_changed.emit()
	inventory_changed.emit()
	return old_shoe


func remove_shoe() -> ItemStack:
	## Remove and return the equipped shoe.
	var old := equipped_shoe
	equipped_shoe = null
	shoe_changed.emit()
	inventory_changed.emit()
	return old


func get_shoe_speed_bonus() -> float:
	## Returns the speed bonus from the equipped shoe (0.0 if none).
	if equipped_shoe == null:
		return 0.0
	if equipped_shoe.item_data and equipped_shoe.item_data.item_type == ItemData.ItemType.SHOE:
		return equipped_shoe.item_data.get("speed_bonus") if equipped_shoe.item_data.get("speed_bonus") != null else 0.0
	return 0.0


func get_serialized() -> Array:
	## Serialize the full inventory for network transmission.
	var result: Array = []
	for stack in items:
		result.append(stack.serialize())
	return result


func add_fuel(amount: float) -> void:
	## Add burn fuel to the player's pool.
	burn_fuel += amount
	fuel_changed.emit(burn_fuel)


func spend_fuel(amount: float) -> bool:
	## Spend burn fuel. Returns true if successful, false if insufficient.
	if burn_fuel < amount:
		return false
	burn_fuel -= amount
	fuel_changed.emit(burn_fuel)
	return true


func has_fuel(amount: float) -> bool:
	## Check if the player has enough burn fuel.
	return burn_fuel >= amount


func clear_all() -> void:
	## Remove all items (used on death/respawn).
	items.clear()
	equipped_index = -1
	equipped_shoe = null
	burn_fuel = STARTING_FUEL
	shoe_changed.emit()
	inventory_changed.emit()
	fuel_changed.emit(burn_fuel)
