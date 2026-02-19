extends PlayerSubsystem
class_name ItemManager

## Item management subsystem.
## Owns item pickup, drop, extend lifespan (F key), scrap ground item (X key),
## and scrap equipped item (O key) logic.
## Attached as a child of Player in player.tscn.

## --- Extend Item Lifespan (F key) ---
## Spend burn fuel to add time to the equipped weapon. Each press adds a fixed
## chunk of time, but the cost scales up based on how much fuel has already been
## spent on this item — up to 2.5x the base cost.
const EXTEND_BASE_COST := 50.0       ## Fuel cost for the first extension press
const EXTEND_TIME_ADDED := 30.0      ## Seconds added per extension press
const EXTEND_MAX_COST_MULT := 2.5    ## Maximum cost multiplier after many extensions
const EXTEND_SCALE_RATE := 0.003     ## How fast cost ramps up per fuel spent (higher = faster)

## --- Scrap Ground Item (X key) ---
## Scrap a nearby ground item into burn fuel.
## --- Scrap Equipped Item (O key) ---
## Scrap the equipped weapon/item from inventory into burn fuel.
## Rarer items give significantly more fuel.
const SCRAP_FUEL_BY_RARITY := [10.0, 30.0, 65.0, 130.0, 250.0]  # Common → Legendary
const SCRAP_PICKUP_RANGE := 4.0  ## Max distance to scrap a ground item

func setup(p: CharacterBody3D) -> void:
	super.setup(p)


## ======================================================================
##  Item Pickup (called from world_item.gd via player proxy)
## ======================================================================

func try_pickup_item(world_item: Node) -> void:
	## Server-only: pick up a specific WorldItem (already identified as closest
	## by the unified _find_closest_interactable() in player.gd).
	## Validates range and immunity before picking up.
	if not multiplayer.is_server() or not player.is_alive:
		return
	if not is_instance_valid(world_item) or not ("item_data" in world_item) or world_item.item_data == null:
		return
	if world_item.item_data.item_type == ItemData.ItemType.FUEL:
		return
	if world_item.has_method("is_immune_to") and world_item.is_immune_to(player.peer_id):
		return
	var dist: float = player.global_position.distance_to(world_item.global_position)
	if dist > SCRAP_PICKUP_RANGE:
		return
	on_item_pickup(world_item)


func on_item_pickup(world_item: Node) -> void:
	## Server-only: called when this player walks into a WorldItem.
	if not multiplayer.is_server() or not player.is_alive:
		return
	var inventory: Inventory = player.inventory
	if inventory == null:
		return

	var item_data: ItemData = world_item.item_data
	if item_data == null:
		return

	# Fuel pickups: consumed instantly, don't occupy a slot
	if item_data.item_type == ItemData.ItemType.FUEL and item_data is FuelData:
		inventory.add_fuel(item_data.fuel_amount)
		world_item.queue_free()
		print("Player %d picked up %s (+%.0f fuel)" % [player.peer_id, item_data.item_name, item_data.fuel_amount])
		return

	# Trinkets go into the trinket bag
	if item_data.item_type == ItemData.ItemType.TRINKET:
		var t_idx := inventory.add_trinket(item_data)
		if t_idx < 0:
			return  # Trinket bag full
		# Preserve world item's remaining burn time
		var t_stack: ItemStack = inventory.trinket_bag[t_idx]
		if t_stack and world_item.burn_time_remaining < WorldItem.PERMANENT_THRESHOLD:
			t_stack.burn_time_remaining = world_item.burn_time_remaining
		world_item.queue_free()
		print("Player %d picked up trinket %s" % [player.peer_id, item_data.item_name])
		return

	# Shoes go into the dedicated shoe slot
	if item_data.item_type == ItemData.ItemType.SHOE:
		# Eject trinkets from old shoe before swapping
		_eject_shoe_trinkets()
		var old_shoe: ItemStack = inventory.equip_shoe(item_data)
		# Preserve the world item's remaining burn time instead of resetting
		# (skip permanent items — they use 999999 as a marker, not a real timer)
		if inventory.equipped_shoe and world_item.burn_time_remaining < WorldItem.PERMANENT_THRESHOLD:
			inventory.equipped_shoe.burn_time_remaining = world_item.burn_time_remaining
		# Extended Mags bonus: +40% burn timer on shoe pickup
		if 7 in player.active_bonuses and inventory.equipped_shoe:
			inventory.equipped_shoe.burn_time_remaining *= 1.4
		# Drop old shoe back into the world with its remaining burn time
		if old_shoe != null and old_shoe.item_data != null:
			drop_item_as_world_item(old_shoe)
		world_item.queue_free()
		print("Player %d equipped %s" % [player.peer_id, item_data.item_name])
		return

	var idx := inventory.add_item(item_data)
	if idx < 0:
		return  # Inventory full

	# Preserve the world item's remaining burn time instead of resetting
	# (skip permanent items — they use 999999 as a marker, not a real timer)
	var stack: ItemStack = inventory.items[idx]
	if stack and world_item.burn_time_remaining < WorldItem.PERMANENT_THRESHOLD:
		stack.burn_time_remaining = world_item.burn_time_remaining

	# Extended Mags bonus: +40% burn timer on item pickup
	if 7 in player.active_bonuses and idx >= 0:
		if stack:
			stack.burn_time_remaining *= 1.4

	# Remove the world item
	world_item.queue_free()
	print("Player %d picked up %s" % [player.peer_id, item_data.item_name])


func drop_item_as_world_item(stack: ItemStack) -> void:
	## Server-only: spawn a WorldItem on the ground with the remaining burn time.
	## Preserves the item's current rarity (which may have been rolled at spawn).
	# Drop slightly behind the player
	var drop_pos := player.global_position - player.transform.basis.z * 1.5
	drop_pos.y = player.global_position.y

	var item_path: String = stack.item_data.get_source_path()
	if item_path == "":
		push_warning("ItemManager: cannot drop %s — no resource path" % stack.item_data.item_name)
		return

	var map := get_tree().current_scene
	if map.has_method("spawn_world_item"):
		map.spawn_world_item(
			item_path,
			drop_pos,
			stack.burn_time_remaining,
			player.peer_id,  # pickup immunity
			stack.item_data.rarity  # preserve rolled rarity
		)
	else:
		push_warning("ItemManager: map has no spawn_world_item method")


func _eject_shoe_trinkets() -> void:
	## Server-only: move all trinkets from the equipped shoe back to trinket bag.
	## If bag is full, drop to world. Called before shoe swap or on death.
	var inventory: Inventory = player.inventory
	if inventory == null or inventory.equipped_shoe == null:
		return
	for trinket_data in inventory.equipped_shoe.slotted_trinkets:
		if trinket_data == null:
			continue
		if inventory.trinket_bag.size() < Inventory.MAX_TRINKETS:
			var stack := ItemStack.create(trinket_data)
			inventory.trinket_bag.append(stack)
			print("Trinket %s returned to bag (shoe swap)" % trinket_data.item_name)
		else:
			var stack := ItemStack.create(trinket_data)
			drop_item_as_world_item(stack)
			print("Trinket %s dropped to world (bag full, shoe swap)" % trinket_data.item_name)
	inventory.equipped_shoe.slotted_trinkets.clear()
	inventory.trinket_bag_changed.emit()


## ======================================================================
##  Extend equipped item lifespan (F key)
## ======================================================================

func try_extend_equipped_item() -> void:
	## Server-only: extend the equipped weapon's burn timer by spending fuel.
	if not multiplayer.is_server():
		return
	var inventory: Inventory = player.inventory
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return

	var stack: ItemStack = inventory.items[inventory.equipped_index]
	if stack == null or stack.item_data == null:
		return

	# Calculate scaling cost
	var progress: float = 1.0 - exp(-EXTEND_SCALE_RATE * stack.fuel_spent_extending)
	var cost_mult: float = 1.0 + (EXTEND_MAX_COST_MULT - 1.0) * progress
	var fuel_cost: float = EXTEND_BASE_COST * cost_mult

	if not inventory.has_fuel(fuel_cost):
		return

	inventory.spend_fuel(fuel_cost)
	stack.burn_time_remaining += EXTEND_TIME_ADDED
	stack.fuel_spent_extending += fuel_cost
	print("Player %d extended %s by %.0fs (cost: %.0f fuel, total spent: %.0f)" % [
		player.peer_id, stack.item_data.item_name, EXTEND_TIME_ADDED, fuel_cost, stack.fuel_spent_extending])


## ======================================================================
##  Scrap ground item (X key)
## ======================================================================

func try_scrap_ground_item() -> void:
	## Server-only: scrap the nearest ground WorldItem within range for fuel.
	if not multiplayer.is_server():
		return

	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return

	var player_pos := player.global_position
	var best_item: Node = null
	var best_dist := SCRAP_PICKUP_RANGE

	for child in world_items.get_children():
		if not child is Area3D or not child.has_method("setup"):
			continue
		if not "item_data" in child or child.item_data == null:
			continue
		var dist: float = player_pos.distance_to(child.global_position)
		if dist < best_dist:
			best_dist = dist
			best_item = child

	if best_item == null:
		return

	var item_data: ItemData = best_item.item_data
	# Fuel canisters cannot be scrapped
	if item_data.item_type == ItemData.ItemType.FUEL:
		return
	var rarity: int = item_data.rarity
	var max_fuel: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	# Fuel scales linearly with time remaining: full timer = full fuel, expired = nothing
	var initial_time: float = maxf(item_data.initial_burn_time, 0.1)
	var time_fraction: float = 1.0
	if "burn_time_remaining" in best_item:
		time_fraction = clampf(best_item.burn_time_remaining / initial_time, 0.0, 1.0)
	var fuel_gained: float = max_fuel * time_fraction
	# Scavenger bonus: +50% scrap fuel
	if 3 in player.active_bonuses:
		fuel_gained *= 1.5

	player.inventory.add_fuel(fuel_gained)
	print("Player %d scrapped ground item %s for %.0f fuel" % [player.peer_id, item_data.item_name, fuel_gained])
	best_item.queue_free()


## ======================================================================
##  Scrap equipped item (O key)
## ======================================================================

func try_scrap_equipped_item() -> void:
	## Server-only: scrap the currently equipped weapon/item from inventory for fuel.
	if not multiplayer.is_server():
		return

	var inventory: Inventory = player.inventory
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return

	var stack: ItemStack = inventory.items[inventory.equipped_index]
	if stack == null or stack.item_data == null:
		return
	# Fuel canisters cannot be scrapped
	if stack.item_data.item_type == ItemData.ItemType.FUEL:
		return

	var rarity: int = stack.item_data.rarity
	var max_fuel: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	# Fuel scales linearly with time remaining: full timer = full fuel, expired = nothing
	var initial_time: float = maxf(stack.item_data.initial_burn_time, 0.1)
	var time_fraction: float = clampf(stack.burn_time_remaining / initial_time, 0.0, 1.0)
	var fuel_gained: float = max_fuel * time_fraction
	# Scavenger bonus: +50% scrap fuel
	if 3 in player.active_bonuses:
		fuel_gained *= 1.5

	var item_name: String = stack.item_data.item_name
	var idx := inventory.equipped_index

	# Clear equipped weapon via player helper
	player.clear_equipped_weapon()

	inventory.remove_item(idx)
	inventory.add_fuel(fuel_gained)
	print("Player %d scrapped %s for %.0f fuel" % [player.peer_id, item_name, fuel_gained])
