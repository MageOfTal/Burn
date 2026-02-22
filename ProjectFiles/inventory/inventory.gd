extends Node
class_name Inventory

## Manages 6 weapon slots for one player.
## Slots use null for empty positions — items stay in their slot when others expire.
## All mutations happen on the server. Clients receive full-state sync via RPC.

const MAX_SLOTS := 6
const STARTING_FUEL := 1000.0

## Fixed-size array: null = empty slot, ItemStack = occupied.
var items: Array = []
var time_currency: float = 0.0
var equipped_index: int = -1
var burn_fuel: float = STARTING_FUEL
var kill_currency: float = 0.0

## Shoe equipment slot (separate from the 6 item slots)
var equipped_shoe: ItemStack = null
## Whether the shoe slot is the currently selected slot (for extend/scrap targeting)
var shoe_selected: bool = false

## Trinket bag — separate storage for trinket items.
const MAX_TRINKETS := 4
var trinket_bag: Array = []  # Array of ItemStack (TrinketData items)

## Networking: peer_id of the owning player (set by player.gd).
## Server sends inventory RPCs to this peer when state changes.
var _owner_peer_id: int = -1

signal item_added(index: int, stack: ItemStack)
signal item_removed(index: int)
signal item_expired(index: int, item_name: String)
signal inventory_changed
signal weapon_equipped(index: int)
signal shoe_changed
signal trinket_bag_changed
signal fuel_changed(new_amount: float)


## Returns the number of occupied (non-null) slots.
func get_item_count() -> int:
	var count := 0
	for stack in items:
		if stack != null:
			count += 1
	return count


# ======================================================================
#  Core item management
# ======================================================================

func add_item(item_data: ItemData) -> int:
	## Add an item to inventory. Returns slot index, or -1 if full.
	## Fills the first empty (null) slot, or appends if room.
	# First, look for a null slot
	for i in items.size():
		if items[i] == null:
			var new_stack := ItemStack.create(item_data)
			items[i] = new_stack
			item_added.emit(i, new_stack)
			inventory_changed.emit()
			_notify_sync()
			return i
	# No null slot — append if under max
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
	if items[index] == null:
		return
	if items[index].item_data is WeaponData or items[index].item_data is ConsumableData or items[index].item_data is GadgetData:
		equipped_index = index
		weapon_equipped.emit(index)
		_notify_sync()


func remove_item(index: int) -> ItemStack:
	## Remove the item at the given index (set to null). Returns the removed stack.
	if index < 0 or index >= items.size():
		return null
	if items[index] == null:
		return null

	var stack: ItemStack = items[index]
	items[index] = null
	if equipped_index == index:
		equipped_index = -1
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
	if items[sacrifice_index] == null or items[target_index] == null:
		return false

	var sacrifice: ItemStack = items[sacrifice_index]
	var target: ItemStack = items[target_index]

	var time_added: float = sacrifice.item_data.time_currency_value / target.item_data.burn_cost_to_extend
	target.burn_time_remaining += time_added

	items[sacrifice_index] = null
	if equipped_index == sacrifice_index:
		equipped_index = -1
	item_removed.emit(sacrifice_index)
	inventory_changed.emit()
	_notify_sync()
	return true


func convert_to_time_currency(index: int) -> float:
	## Destroy the item and add its value to the player's time currency.
	if index < 0 or index >= items.size():
		return 0.0
	if items[index] == null:
		return 0.0

	var stack: ItemStack = items[index]
	var value := stack.item_data.time_currency_value
	time_currency += value

	items[index] = null
	if equipped_index == index:
		equipped_index = -1
	item_removed.emit(index)
	inventory_changed.emit()
	_notify_sync()
	return value


func spend_time_currency(amount: float, target_index: int) -> bool:
	## Spend time currency to extend a specific item's burn timer.
	if target_index < 0 or target_index >= items.size():
		return false
	if items[target_index] == null:
		return false
	if time_currency < amount:
		return false

	var target: ItemStack = items[target_index]
	var time_added := amount / target.item_data.burn_cost_to_extend
	target.burn_time_remaining += time_added
	time_currency -= amount
	inventory_changed.emit()
	_notify_sync()
	return true


func remove_expired_items() -> Array[String]:
	## Null out expired items (they stay in their slot). Returns names of removed items.
	var expired_names: Array[String] = []
	for i in items.size():
		if items[i] == null:
			continue
		var stack: ItemStack = items[i]
		if stack.is_expired():
			expired_names.append(stack.item_data.item_name)
			item_expired.emit(i, stack.item_data.item_name)

			# Clear ammo references pointing at this item
			for j in items.size():
				if items[j] == null:
					continue
				if items[j].slotted_ammo_source_index == i:
					items[j].slotted_ammo = null
					items[j].slotted_ammo_source_index = -1

			# Null out the slot (items stay in place)
			items[i] = null
			if equipped_index == i:
				equipped_index = -1

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


func get_shoe_extra_jumps() -> int:
	## Returns total extra jumps from trinkets attached to the equipped shoe.
	if equipped_shoe == null:
		return 0
	var total := 0
	for trinket in equipped_shoe.slotted_trinkets:
		if trinket is TrinketData:
			total += trinket.extra_jumps
	return total


# ======================================================================
#  Trinket bag
# ======================================================================

func add_trinket(trinket_data: ItemData) -> int:
	## Add a trinket to the trinket bag. Returns index, or -1 if full.
	if trinket_bag.size() >= MAX_TRINKETS:
		return -1
	var stack := ItemStack.create(trinket_data)
	trinket_bag.append(stack)
	trinket_bag_changed.emit()
	inventory_changed.emit()
	_notify_sync()
	return trinket_bag.size() - 1


func remove_trinket(index: int) -> ItemStack:
	## Remove a trinket from the bag by index. Returns the removed stack.
	if index < 0 or index >= trinket_bag.size():
		return null
	var stack: ItemStack = trinket_bag[index]
	trinket_bag.remove_at(index)
	trinket_bag_changed.emit()
	inventory_changed.emit()
	_notify_sync()
	return stack


func get_trinket_count() -> int:
	return trinket_bag.size()


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
	## NOTE: kill_currency is intentionally NOT cleared — it persists after death.
	items.clear()
	equipped_index = -1
	equipped_shoe = null
	shoe_selected = false
	trinket_bag.clear()
	burn_fuel = STARTING_FUEL
	shoe_changed.emit()
	trinket_bag_changed.emit()
	inventory_changed.emit()
	fuel_changed.emit(burn_fuel)
	_notify_sync()


func add_kill_currency(amount: float) -> void:
	kill_currency += amount
	_notify_sync()


func spend_kill_currency(amount: float) -> bool:
	if kill_currency < amount:
		return false
	kill_currency -= amount
	_notify_sync()
	return true


func has_kill_currency(amount: float) -> bool:
	return kill_currency >= amount


func get_serialized() -> Array:
	var result: Array = []
	for stack in items:
		if stack != null:
			result.append(stack.serialize())
		else:
			result.append(null)
	return result


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
	## Null slots are serialized with empty path so clients rebuild nulls correctly.
	## Rarity is included so clients can duplicate + override (items spawn at random rarity).
	var item_list: Array = []
	for stack in items:
		if stack == null:
			item_list.append({"path": "", "burn": 0.0, "qty": 0, "fuel_spent": 0.0, "ammo_path": "", "ammo_src": -1, "rarity": 0})
		else:
			item_list.append({
				"path": stack.item_data.get_source_path() if stack.item_data else "",
				"burn": stack.burn_time_remaining,
				"qty": stack.quantity,
				"fuel_spent": stack.fuel_spent_extending,
				"ammo_path": stack.slotted_ammo.get_source_path() if stack.slotted_ammo else "",
				"ammo_src": stack.slotted_ammo_source_index,
				"rarity": stack.item_data.rarity if stack.item_data else 0,
			})
	# Serialize trinket bag
	var trinket_list: Array = []
	for t_stack in trinket_bag:
		if t_stack == null or t_stack.item_data == null:
			trinket_list.append({"path": "", "burn": 0.0, "rarity": 0})
		else:
			trinket_list.append({
				"path": t_stack.item_data.get_source_path(),
				"burn": t_stack.burn_time_remaining,
				"rarity": t_stack.item_data.rarity,
			})

	# Serialize trinkets slotted on shoe
	var shoe_trinket_paths: Array = []
	if equipped_shoe and equipped_shoe.slotted_trinkets.size() > 0:
		for trinket in equipped_shoe.slotted_trinkets:
			shoe_trinket_paths.append(trinket.get_source_path() if trinket else "")

	return {
		"items": item_list,
		"equipped": equipped_index,
		"shoe_sel": shoe_selected,
		"tc": time_currency,
		"fuel": burn_fuel,
		"kc": kill_currency,
		"shoe_path": equipped_shoe.item_data.get_source_path() if equipped_shoe and equipped_shoe.item_data else "",
		"shoe_burn": equipped_shoe.burn_time_remaining if equipped_shoe else 0.0,
		"shoe_rarity": equipped_shoe.item_data.rarity if equipped_shoe and equipped_shoe.item_data else 0,
		"trinkets": trinket_list,
		"shoe_trinkets": shoe_trinket_paths,
	}


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_inventory(state: Dictionary) -> void:
	## Client-side: rebuild local inventory from server state.
	## Preserves null slots so items stay in their positions.
	## Rarity is applied by duplicating the base ItemData if it differs from the .tres default.
	items.clear()
	for entry: Dictionary in state["items"]:
		if entry["path"] == "":
			items.append(null)  # Empty slot
			continue
		var data: ItemData = load(entry["path"])
		if data == null:
			items.append(null)
			continue
		# Apply rarity override if the synced rarity differs from the .tres default
		if entry.has("rarity") and data.rarity != entry["rarity"]:
			var orig_path: String = data.resource_path
			data = data.duplicate()
			data._original_resource_path = orig_path
			data.rarity = entry["rarity"] as ItemData.Rarity
		var stack := ItemStack.create(data)
		stack.burn_time_remaining = entry["burn"]
		stack.quantity = entry["qty"]
		stack.fuel_spent_extending = entry["fuel_spent"]
		if entry["ammo_path"] != "":
			stack.slotted_ammo = load(entry["ammo_path"])
			stack.slotted_ammo_source_index = entry["ammo_src"]
		items.append(stack)

	equipped_index = state["equipped"]
	shoe_selected = state.get("shoe_sel", false)
	time_currency = state["tc"]
	burn_fuel = state["fuel"]
	kill_currency = state.get("kc", 0.0)

	if state["shoe_path"] != "":
		var shoe_data: ItemData = load(state["shoe_path"])
		if shoe_data:
			# Apply shoe rarity override
			var shoe_rarity: int = state.get("shoe_rarity", shoe_data.rarity)
			if shoe_data.rarity != shoe_rarity:
				var orig_shoe_path: String = shoe_data.resource_path
				shoe_data = shoe_data.duplicate()
				shoe_data._original_resource_path = orig_shoe_path
				shoe_data.rarity = shoe_rarity as ItemData.Rarity
			equipped_shoe = ItemStack.create(shoe_data)
			equipped_shoe.burn_time_remaining = state["shoe_burn"]
			# Rebuild trinkets slotted on shoe
			var shoe_trinket_paths: Array = state.get("shoe_trinkets", [])
			for t_path in shoe_trinket_paths:
				if t_path != "":
					var t_data: ItemData = load(t_path)
					if t_data:
						equipped_shoe.slotted_trinkets.append(t_data)
		else:
			equipped_shoe = null
	else:
		equipped_shoe = null

	# Rebuild trinket bag
	trinket_bag.clear()
	var trinket_entries: Array = state.get("trinkets", [])
	for t_entry: Dictionary in trinket_entries:
		if t_entry["path"] == "":
			continue
		var t_data: ItemData = load(t_entry["path"])
		if t_data == null:
			continue
		# Apply rarity override
		if t_entry.has("rarity") and t_data.rarity != t_entry["rarity"]:
			var orig_t_path: String = t_data.resource_path
			t_data = t_data.duplicate()
			t_data._original_resource_path = orig_t_path
			t_data.rarity = t_entry["rarity"] as ItemData.Rarity
		var t_stack := ItemStack.create(t_data)
		t_stack.burn_time_remaining = t_entry["burn"]
		trinket_bag.append(t_stack)

	inventory_changed.emit()
	shoe_changed.emit()
	trinket_bag_changed.emit()
	fuel_changed.emit(burn_fuel)
