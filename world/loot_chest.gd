extends StaticBody3D
class_name LootChest

## Loot chest that spawns on the map. Players press E to open.
## Contains 1 fuel item + 2-3 random items. Refills after a timer.
## Server-authoritative: server manages loot generation, open state, and refill.

const CHEST_REFILL_TIME := 120.0      ## Seconds until chest refills after being opened
const CHEST_ITEM_COUNT_MIN := 2       ## Min non-fuel items per chest
const CHEST_ITEM_COUNT_MAX := 3       ## Max non-fuel items per chest
const CHEST_INTERACT_RANGE := 3.0     ## E key range
const CHEST_POPUP_RANGE := 5.0        ## Distance to show prompt label

## Loot pools — set by blockout_map before adding to tree
var weapon_pool: Array[ItemData] = []
var shoe_pool: Array[ItemData] = []
var fuel_pool: Array[ItemData] = []

## Server state
var is_open: bool = false
var refill_timer: float = 0.0
var _loot_items: Array[ItemData] = []

## Client visual state
var _lid_mesh: MeshInstance3D = null
var _body_mesh: MeshInstance3D = null
var _glow_light: OmniLight3D = null
var _prompt_label: Label3D = null
var _cached_local_player: Node = null
var _player_cache_timer: float = 0.0
const PLAYER_CACHE_INTERVAL := 1.0


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0

	_build_visuals()

	if multiplayer.is_server():
		_generate_loot()


func _build_visuals() -> void:
	## Create chest mesh, lid, and glow.
	# Body (bottom half of chest)
	_body_mesh = MeshInstance3D.new()
	var body_box := BoxMesh.new()
	body_box.size = Vector3(1.2, 0.6, 0.8)
	_body_mesh.mesh = body_box
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.55, 0.35, 0.15)
	_body_mesh.material_override = body_mat
	_body_mesh.position.y = 0.3
	add_child(_body_mesh)

	# Lid (top, hinges at back edge)
	_lid_mesh = MeshInstance3D.new()
	var lid_box := BoxMesh.new()
	lid_box.size = Vector3(1.2, 0.15, 0.8)
	_lid_mesh.mesh = lid_box
	var lid_mat := StandardMaterial3D.new()
	lid_mat.albedo_color = Color(0.65, 0.4, 0.18)
	_lid_mesh.material_override = lid_mat
	# Position at top of body (hinge point is the back edge)
	_lid_mesh.position.y = 0.675
	add_child(_lid_mesh)

	# Glow light (visible when chest has loot)
	_glow_light = OmniLight3D.new()
	_glow_light.light_color = Color(1.0, 0.85, 0.3)
	_glow_light.light_energy = 1.5
	_glow_light.omni_range = 3.0
	_glow_light.position.y = 1.0
	add_child(_glow_light)

	# Collision shape
	var col := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.2, 0.75, 0.8)
	col.shape = box_shape
	col.position.y = 0.375
	add_child(col)

	# Prompt label
	_prompt_label = Label3D.new()
	_prompt_label.font_size = 48
	_prompt_label.outline_size = 6
	_prompt_label.outline_modulate = Color(0, 0, 0)
	_prompt_label.position = Vector3(0, 1.5, 0)
	_prompt_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prompt_label.visible = false
	add_child(_prompt_label)


func _generate_loot() -> void:
	## Server-only: fill chest with 1 fuel + 2-3 random items.
	_loot_items.clear()

	# 1 fuel item
	if not fuel_pool.is_empty():
		_loot_items.append(fuel_pool[randi() % fuel_pool.size()])

	# 2-3 random items (weapons, shoes, gadgets, consumables)
	var item_count := randi_range(CHEST_ITEM_COUNT_MIN, CHEST_ITEM_COUNT_MAX)
	var combined_pool: Array[ItemData] = []
	combined_pool.append_array(weapon_pool)
	combined_pool.append_array(shoe_pool)
	if not combined_pool.is_empty():
		for _i in item_count:
			_loot_items.append(combined_pool[randi() % combined_pool.size()])


func open(_peer_id: int) -> void:
	## Server-only: open chest and spawn items into the world.
	if not multiplayer.is_server() or is_open:
		return

	is_open = true
	refill_timer = CHEST_REFILL_TIME

	# Spawn items above the chest in a spread pattern
	var center := global_position + Vector3(0, 1.2, 0)
	var count := _loot_items.size()
	for i in count:
		var item_data: ItemData = _loot_items[i]
		var angle: float = (float(i) / maxf(count, 1)) * TAU
		var offset := Vector3(cos(angle) * 0.8, 0, sin(angle) * 0.8)
		_spawn_world_item(item_data, center + offset)

	_loot_items.clear()

	# Sync to clients
	_sync_state.rpc(true, refill_timer)
	print("Chest opened at %s — spawned %d items" % [str(global_position), count])


func _spawn_world_item(item_data: ItemData, pos: Vector3) -> void:
	var world_item_scene := preload("res://items/world_item.tscn")
	var world_item: WorldItem = world_item_scene.instantiate()
	world_item.setup(item_data)
	world_item.position = pos

	var container := get_tree().current_scene.get_node_or_null("WorldItems")
	if container:
		container.add_child(world_item, true)
	else:
		get_tree().current_scene.add_child(world_item, true)


func _process(delta: float) -> void:
	# Server: handle refill timer
	if multiplayer.is_server() and is_open:
		refill_timer -= delta
		if refill_timer <= 0.0:
			_refill()

	# Client: update visuals
	_update_visuals(delta)
	_update_prompt(delta)


func _refill() -> void:
	## Server-only: refill chest and close it.
	_generate_loot()
	is_open = false
	refill_timer = 0.0
	_sync_state.rpc(false, 0.0)
	print("Chest refilled at %s" % str(global_position))


func _update_visuals(_delta: float) -> void:
	if _lid_mesh == null:
		return

	if is_open:
		# Lid open (rotated back)
		_lid_mesh.rotation.x = lerpf(_lid_mesh.rotation.x, -PI * 0.5, 0.15)
		_lid_mesh.position.y = lerpf(_lid_mesh.position.y, 0.975, 0.15)
		_lid_mesh.position.z = lerpf(_lid_mesh.position.z, -0.3, 0.15)
		if _glow_light:
			_glow_light.light_energy = lerpf(_glow_light.light_energy, 0.0, 0.15)
	else:
		# Lid closed
		_lid_mesh.rotation.x = lerpf(_lid_mesh.rotation.x, 0.0, 0.15)
		_lid_mesh.position.y = lerpf(_lid_mesh.position.y, 0.675, 0.15)
		_lid_mesh.position.z = lerpf(_lid_mesh.position.z, 0.0, 0.15)
		if _glow_light:
			_glow_light.light_energy = lerpf(_glow_light.light_energy, 1.5, 0.15)


func _update_prompt(delta: float) -> void:
	if _prompt_label == null:
		return

	# Cache local player lookup
	_player_cache_timer -= delta
	if _player_cache_timer <= 0.0 or not is_instance_valid(_cached_local_player):
		_player_cache_timer = PLAYER_CACHE_INTERVAL
		_cached_local_player = _find_local_player()

	if _cached_local_player == null:
		_prompt_label.visible = false
		return

	var dist: float = global_position.distance_to(_cached_local_player.global_position)

	if dist < CHEST_POPUP_RANGE:
		_prompt_label.visible = true
		if is_open:
			_prompt_label.text = "EMPTY (%.0fs)" % maxf(refill_timer, 0.0)
			_prompt_label.modulate = Color(0.6, 0.6, 0.6)
		else:
			_prompt_label.text = "[E] OPEN"
			_prompt_label.modulate = Color(1.0, 0.85, 0.3)
	else:
		_prompt_label.visible = false


func _find_local_player() -> Node:
	var players := get_tree().current_scene.get_node_or_null("Players")
	if players == null:
		return null
	return players.get_node_or_null(str(multiplayer.get_unique_id()))


@rpc("authority", "call_remote", "reliable")
func _sync_state(open_state: bool, timer: float) -> void:
	## Client RPC: sync chest open/close state.
	is_open = open_state
	refill_timer = timer
