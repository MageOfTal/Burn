extends Node3D

## Map logic: spawns initial loot on server, manages world items.
## The SeedWorld child generates terrain, structures, and spawn points.

## Item definitions split by type for weighted spawning.
var weapon_definitions: Array[ItemData] = []
var shoe_definitions: Array[ItemData] = []
var fuel_definitions: Array[ItemData] = []
var ammo_definitions: Array[ItemData] = []

## Loot spawn chances (must sum to 1.0).
const FUEL_SPAWN_CHANCE := 0.15
const AMMO_SPAWN_CHANCE := 0.10
const SHOE_SPAWN_CHANCE := 0.20
## Remaining 55% = weapons


func _ready() -> void:
	if not multiplayer.is_server():
		return

	# Load all item definitions
	_load_item_definitions()

	# Start the burn clock
	if has_node("/root/BurnClock"):
		get_node("/root/BurnClock").start()

	# Wait for terrain and structures to generate.
	# SeedWorld._ready waits 1.5s for voxel chunks, then spawns structures/points.
	# We wait longer to ensure everything is placed before spawning loot on top.
	await get_tree().create_timer(3.0).timeout
	_spawn_initial_loot()
	_spawn_debug_rocket_launcher()
	_spawn_debug_rubber_ball()
	_spawn_debug_bubble_blower()
	_spawn_debug_ammo()


func _load_item_definitions() -> void:
	## Load item definitions and split into categories for weighted spawning.
	var dir := DirAccess.open("res://items/definitions/")
	if dir == null:
		push_warning("Could not open items/definitions/ directory")
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var res := load("res://items/definitions/" + file_name)
			if res is ItemData:
				match res.item_type:
					ItemData.ItemType.SHOE:
						shoe_definitions.append(res)
					ItemData.ItemType.FUEL:
						fuel_definitions.append(res)
					ItemData.ItemType.AMMO:
						ammo_definitions.append(res)
					_:
						weapon_definitions.append(res)
		file_name = dir.get_next()
	dir.list_dir_end()
	print("Loaded %d weapons, %d shoes, %d fuel, %d ammo" % [weapon_definitions.size(), shoe_definitions.size(), fuel_definitions.size(), ammo_definitions.size()])


func _spawn_initial_loot() -> void:
	var loot_spawn_points := get_node_or_null("LootSpawnPoints")
	if loot_spawn_points == null:
		push_warning("No LootSpawnPoints node found — terrain may not have generated yet")
		return

	for spawn_point in loot_spawn_points.get_children():
		if spawn_point is Marker3D:
			_spawn_random_at(spawn_point.global_position)

	print("Spawned loot at %d locations" % loot_spawn_points.get_child_count())


func _spawn_random_at(pos: Vector3) -> void:
	## Weighted random spawn: 15% fuel, 10% ammo, 20% shoes, 55% weapons.
	var item_data: ItemData = null
	var roll := randf()

	if roll < FUEL_SPAWN_CHANCE and not fuel_definitions.is_empty():
		item_data = fuel_definitions[randi() % fuel_definitions.size()]
	elif roll < FUEL_SPAWN_CHANCE + AMMO_SPAWN_CHANCE and not ammo_definitions.is_empty():
		item_data = ammo_definitions[randi() % ammo_definitions.size()]
	elif roll < FUEL_SPAWN_CHANCE + AMMO_SPAWN_CHANCE + SHOE_SPAWN_CHANCE and not shoe_definitions.is_empty():
		item_data = shoe_definitions[randi() % shoe_definitions.size()]
	elif not weapon_definitions.is_empty():
		item_data = weapon_definitions[randi() % weapon_definitions.size()]
	else:
		return

	var world_item_scene := preload("res://items/world_item.tscn")
	var world_item: WorldItem = world_item_scene.instantiate()
	world_item.setup(item_data)
	# Use local position before adding to tree (global_position requires being in tree)
	world_item.position = pos

	var container := get_node_or_null("WorldItems")
	if container:
		container.add_child(world_item, true)
	else:
		add_child(world_item, true)


func _spawn_debug_rocket_launcher() -> void:
	## DEBUG: Spawn a rocket launcher at every player spawn point for testing.
	## Remove this function when done testing!
	var rocket_data := load("res://items/definitions/gun_jeg_rocket_launcher.tres") as ItemData
	if rocket_data == null:
		return

	var spawn_points := get_node_or_null("PlayerSpawnPoints")
	if spawn_points == null:
		return

	for spawn in spawn_points.get_children():
		var world_item_scene := preload("res://items/world_item.tscn")
		var world_item: WorldItem = world_item_scene.instantiate()
		world_item.setup(rocket_data)
		world_item.position = spawn.global_position + Vector3(2, 0, 2)

		var container := get_node_or_null("WorldItems")
		if container:
			container.add_child(world_item, true)
		else:
			add_child(world_item, true)

	print("DEBUG: Spawned rocket launchers at all spawn points")


func _spawn_debug_rubber_ball() -> void:
	## DEBUG: Spawn a rubber ball launcher at every player spawn point for testing.
	## Remove this function when done testing!
	var ball_data := load("res://items/definitions/gun_rubber_ball_launcher.tres") as ItemData
	if ball_data == null:
		return

	var spawn_points := get_node_or_null("PlayerSpawnPoints")
	if spawn_points == null:
		return

	for spawn in spawn_points.get_children():
		var world_item_scene := preload("res://items/world_item.tscn")
		var world_item: WorldItem = world_item_scene.instantiate()
		world_item.setup(ball_data)
		world_item.position = spawn.global_position + Vector3(-2, 0, 2)

		var container := get_node_or_null("WorldItems")
		if container:
			container.add_child(world_item, true)
		else:
			add_child(world_item, true)

	print("DEBUG: Spawned rubber ball launchers at all spawn points")


func _spawn_debug_bubble_blower() -> void:
	## DEBUG: Spawn a bubble blower at every player spawn point for testing.
	## Remove this function when done testing!
	var bubble_data := load("res://items/definitions/gun_bubble_blower.tres") as ItemData
	if bubble_data == null:
		return

	var spawn_points := get_node_or_null("PlayerSpawnPoints")
	if spawn_points == null:
		return

	for spawn in spawn_points.get_children():
		var world_item_scene := preload("res://items/world_item.tscn")
		var world_item: WorldItem = world_item_scene.instantiate()
		world_item.setup(bubble_data)
		world_item.position = spawn.global_position + Vector3(0, 0, 3)

		var container := get_node_or_null("WorldItems")
		if container:
			container.add_child(world_item, true)
		else:
			add_child(world_item, true)

	print("DEBUG: Spawned bubble blowers at all spawn points")


func _spawn_debug_ammo() -> void:
	## DEBUG: Spawn extra bubble blowers and rubber ball launchers near spawn points.
	## These weapons double as ammo — pick one up, slot it into another gun.
	## Remove this function when done testing!
	var bubble_data := load("res://items/definitions/gun_bubble_blower.tres") as ItemData
	var ball_data := load("res://items/definitions/gun_rubber_ball_launcher.tres") as ItemData

	var spawn_points := get_node_or_null("PlayerSpawnPoints")
	if spawn_points == null:
		return

	for spawn in spawn_points.get_children():
		if bubble_data:
			var world_item_scene := preload("res://items/world_item.tscn")
			var world_item: WorldItem = world_item_scene.instantiate()
			world_item.setup(bubble_data)
			world_item.position = spawn.global_position + Vector3(3, 0, -2)
			var container := get_node_or_null("WorldItems")
			if container:
				container.add_child(world_item, true)
			else:
				add_child(world_item, true)

		if ball_data:
			var world_item_scene := preload("res://items/world_item.tscn")
			var world_item: WorldItem = world_item_scene.instantiate()
			world_item.setup(ball_data)
			world_item.position = spawn.global_position + Vector3(-3, 0, -2)
			var container := get_node_or_null("WorldItems")
			if container:
				container.add_child(world_item, true)
			else:
				add_child(world_item, true)

	print("DEBUG: Spawned dual-use weapons (ammo-capable) at all spawn points")
