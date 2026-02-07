extends Node3D

## Map logic: spawns initial loot on server, manages world items.

## Item definitions to spawn across the map.
var item_definitions: Array[ItemData] = []

@onready var loot_spawn_points: Node3D = $LootSpawnPoints


func _ready() -> void:
	if not multiplayer.is_server():
		return

	# Load all item definitions
	_load_item_definitions()

	# Start the burn clock
	if has_node("/root/BurnClock"):
		get_node("/root/BurnClock").start()

	# Spawn initial loot after a brief delay to let everything initialize
	await get_tree().create_timer(0.5).timeout
	_spawn_initial_loot()


func _load_item_definitions() -> void:
	# Load weapon definitions from the definitions folder
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
				item_definitions.append(res)
		file_name = dir.get_next()
	dir.list_dir_end()
	print("Loaded %d item definitions" % item_definitions.size())


func _spawn_initial_loot() -> void:
	if loot_spawn_points == null:
		return

	for spawn_point in loot_spawn_points.get_children():
		if spawn_point is LootSpawnPoint:
			# If spawn point has its own loot table, use it
			spawn_point.spawn_random_item()
		elif spawn_point is Marker3D:
			# Generic spawn point: pick a random item from all definitions
			_spawn_random_at(spawn_point.global_position)


func _spawn_random_at(pos: Vector3) -> void:
	if item_definitions.is_empty():
		return

	var item_data: ItemData = item_definitions[randi() % item_definitions.size()]
	var world_item_scene := preload("res://items/world_item.tscn")
	var world_item: WorldItem = world_item_scene.instantiate()
	world_item.setup(item_data)
	world_item.global_position = pos

	var container := get_node_or_null("WorldItems")
	if container:
		container.add_child(world_item, true)
	else:
		add_child(world_item, true)
