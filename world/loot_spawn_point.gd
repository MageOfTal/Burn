extends Marker3D
class_name LootSpawnPoint

## A location where loot can spawn. Configured with a loot table.

@export var loot_table: Array[ItemData] = []
@export var spawn_weights: Array[float] = []
@export var respawn_time: float = 30.0

var _current_item: Node = null
var _respawn_timer: float = 0.0
var _has_spawned: bool = false


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# Respawn logic
	if _current_item == null and _has_spawned:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			spawn_random_item()


func spawn_random_item() -> void:
	if loot_table.is_empty():
		return

	var item_data := _pick_weighted_random()
	if item_data == null:
		return

	var map := get_tree().current_scene
	if not map.has_method("spawn_world_item"):
		push_warning("LootSpawnPoint: map has no spawn_world_item method")
		return

	map.spawn_world_item(item_data.resource_path, global_position)

	# Grab the spawned node (last child of WorldItems) to track for respawn
	var container := map.get_node_or_null("WorldItems")
	if container and container.get_child_count() > 0:
		_current_item = container.get_child(container.get_child_count() - 1)
		_current_item.tree_exited.connect(_on_item_removed)

	_has_spawned = true


func _on_item_removed() -> void:
	_current_item = null
	_respawn_timer = respawn_time


func _pick_weighted_random() -> ItemData:
	if loot_table.size() == 1:
		return loot_table[0]

	# If no weights specified, equal chance
	if spawn_weights.is_empty():
		return loot_table[randi() % loot_table.size()]

	var total_weight: float = 0.0
	for w in spawn_weights:
		total_weight += w

	var roll := randf() * total_weight
	var cumulative: float = 0.0
	for i in loot_table.size():
		cumulative += spawn_weights[i] if i < spawn_weights.size() else 1.0
		if roll <= cumulative:
			return loot_table[i]

	return loot_table[loot_table.size() - 1]
