extends Node
class_name ItemManager

## Item management subsystem.
## Owns item pickup, drop, extend lifespan (F key), and scrap (X key) logic.
## Attached as a child of Player in player.tscn.

## --- Extend Item Lifespan (F key) ---
## Spend burn fuel to add time to the equipped weapon. Each press adds a fixed
## chunk of time, but the cost scales up based on how much fuel has already been
## spent on this item — up to 2.5x the base cost.
const EXTEND_BASE_COST := 50.0       ## Fuel cost for the first extension press
const EXTEND_TIME_ADDED := 30.0      ## Seconds added per extension press
const EXTEND_MAX_COST_MULT := 2.5    ## Maximum cost multiplier after many extensions
const EXTEND_SCALE_RATE := 0.003     ## How fast cost ramps up per fuel spent (higher = faster)

## --- Scrap Item (X key) ---
## Scrap a nearby ground item (priority) or the equipped weapon into burn fuel.
## Rarer items give significantly more fuel.
const SCRAP_FUEL_BY_RARITY := [10.0, 25.0, 50.0, 100.0, 200.0]  # Common → Legendary (reduced)
const SCRAP_PICKUP_RANGE := 4.0  ## Max distance to scrap a ground item

## Player reference
var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p


## ======================================================================
##  Item Pickup (called from world_item.gd via player proxy)
## ======================================================================

func try_pickup_nearby_item() -> void:
	## Server-only: find the nearest non-fuel WorldItem within range and pick it up.
	## Fuel is auto-picked up on contact; this handles everything else via E key.
	if not multiplayer.is_server() or not player.is_alive:
		return

	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return

	var player_pos := player.global_position
	var best_item: Node = null
	var best_dist := SCRAP_PICKUP_RANGE  # Reuse the same 4m range

	for child in world_items.get_children():
		if not child is Area3D or not child.has_method("setup"):
			continue
		if not "item_data" in child or child.item_data == null:
			continue
		# Skip fuel — fuel is auto-picked up on contact
		if child.item_data.item_type == ItemData.ItemType.FUEL:
			continue
		# Check pickup immunity
		if child.has_method("is_immune_to") and child.is_immune_to(player.peer_id):
			continue
		var dist: float = player_pos.distance_to(child.global_position)
		if dist < best_dist:
			best_dist = dist
			best_item = child

	if best_item == null:
		return

	on_item_pickup(best_item)


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

	# Shoes go into the dedicated shoe slot
	if item_data.item_type == ItemData.ItemType.SHOE:
		var old_shoe: ItemStack = inventory.equip_shoe(item_data)
		# Drop old shoe back into the world with its remaining burn time
		if old_shoe != null and old_shoe.item_data != null:
			drop_item_as_world_item(old_shoe)
		world_item.queue_free()
		print("Player %d equipped %s" % [player.peer_id, item_data.item_name])
		return

	var idx := inventory.add_item(item_data)
	if idx < 0:
		return  # Inventory full

	# Remove the world item
	world_item.queue_free()
	print("Player %d picked up %s" % [player.peer_id, item_data.item_name])


func drop_item_as_world_item(stack: ItemStack) -> void:
	## Server-only: spawn a WorldItem on the ground with the remaining burn time.
	# Drop slightly behind the player
	var drop_pos := player.global_position - player.transform.basis.z * 1.5
	drop_pos.y = player.global_position.y

	var map := get_tree().current_scene
	if map.has_method("spawn_world_item"):
		map.spawn_world_item(
			stack.item_data.resource_path,
			drop_pos,
			stack.burn_time_remaining,
			player.peer_id  # pickup immunity
		)
	else:
		push_warning("ItemManager: map has no spawn_world_item method")


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
	if stack.item_data == null:
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
##  Scrap item (X key)
## ======================================================================

func try_scrap_item() -> void:
	## Server-only: look for a nearby ground item to scrap first, then fall back
	## to scrapping the equipped weapon.
	if not multiplayer.is_server():
		return

	# Priority 1: scrap a nearby WorldItem on the ground
	var scrapped_ground := _try_scrap_ground_item()
	if scrapped_ground:
		return

	# Priority 2: scrap the equipped weapon
	var inventory: Inventory = player.inventory
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return

	var stack: ItemStack = inventory.items[inventory.equipped_index]
	if stack.item_data == null:
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

	var item_name: String = stack.item_data.item_name
	var idx := inventory.equipped_index

	# Clear equipped weapon via player helper
	player.clear_equipped_weapon()

	inventory.remove_item(idx)
	inventory.add_fuel(fuel_gained)
	print("Player %d scrapped %s for %.0f fuel" % [player.peer_id, item_name, fuel_gained])


func _try_scrap_ground_item() -> bool:
	## Look for the nearest WorldItem within range and scrap it for fuel.
	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return false

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
		return false

	var item_data: ItemData = best_item.item_data
	# Fuel canisters cannot be scrapped
	if item_data.item_type == ItemData.ItemType.FUEL:
		return false
	var rarity: int = item_data.rarity
	var max_fuel: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	# Fuel scales linearly with time remaining: full timer = full fuel, expired = nothing
	var initial_time: float = maxf(item_data.initial_burn_time, 0.1)
	var time_fraction: float = 1.0
	if "burn_time_remaining" in best_item:
		time_fraction = clampf(best_item.burn_time_remaining / initial_time, 0.0, 1.0)
	var fuel_gained: float = max_fuel * time_fraction

	player.inventory.add_fuel(fuel_gained)
	print("Player %d scrapped ground item %s for %.0f fuel" % [player.peer_id, item_data.item_name, fuel_gained])
	best_item.queue_free()
	return true
