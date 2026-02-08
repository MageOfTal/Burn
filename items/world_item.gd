extends Area3D
class_name WorldItem

## An item lying on the ground that players can pick up.
## Server-authoritative: server manages pickup and burn timers.

@export var item_data: ItemData = null

var burn_time_remaining: float = 0.0

## Pickup immunity: the peer_id that just dropped this item can't pick it up
## until the timer expires. Prevents drop-pickup loops.
var _immune_peer_id: int = -1
var _immune_timer: float = 0.0
const PICKUP_IMMUNITY_TIME := 2.0

const SCRAP_POPUP_RANGE := 4.0  ## Distance to show the scrap popup
const SCRAP_FUEL_BY_RARITY := [30.0, 75.0, 175.0, 400.0, 800.0]

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var label: Label3D = $Label3D
var _scrap_label: Label3D = null


func _ready() -> void:
	if item_data:
		burn_time_remaining = item_data.initial_burn_time
		_update_visual()

	body_entered.connect(_on_body_entered)

	# Ensure item isn't stuck in terrain or structures (server only, deferred so position is set)
	if multiplayer.is_server():
		_ensure_above_ground.call_deferred()


func setup(data: ItemData) -> void:
	item_data = data
	burn_time_remaining = data.initial_burn_time
	if is_inside_tree():
		_update_visual()


func set_pickup_immunity(peer_id: int) -> void:
	## Prevent a specific player from picking this item up for a short time.
	_immune_peer_id = peer_id
	_immune_timer = PICKUP_IMMUNITY_TIME


func _process(delta: float) -> void:
	# Update label with remaining time
	if label and item_data:
		var time_str := "%ds" % ceili(burn_time_remaining)
		label.text = "%s [%s]" % [item_data.item_name, time_str]

	# Server decrements burn timer for ground items (at base rate only)
	if multiplayer.is_server():
		burn_time_remaining -= item_data.base_burn_rate * delta if item_data else 0.0
		if burn_time_remaining <= 0.0:
			queue_free()

		# Decrement pickup immunity timer
		if _immune_timer > 0.0:
			_immune_timer -= delta
			if _immune_timer <= 0.0:
				_immune_peer_id = -1

	# Show/hide scrap popup when local player is nearby (client-side only)
	_update_scrap_popup()


## Rarity colors for world item boxes (matches common BR color schemes)
const RARITY_COLORS := {
	ItemData.Rarity.COMMON: Color(0.6, 0.6, 0.6, 1),       # Gray
	ItemData.Rarity.UNCOMMON: Color(0.2, 0.8, 0.2, 1),      # Green
	ItemData.Rarity.RARE: Color(0.3, 0.5, 1.0, 1),          # Blue
	ItemData.Rarity.EPIC: Color(0.7, 0.3, 0.9, 1),          # Purple
	ItemData.Rarity.LEGENDARY: Color(1.0, 0.7, 0.1, 1),     # Gold
}

func _update_visual() -> void:
	if mesh and item_data:
		var mat := StandardMaterial3D.new()
		# Use the item's mesh_color if it's set (shoes have custom colors),
		# otherwise fall back to rarity-based color
		if item_data.mesh_color != Color.WHITE:
			mat.albedo_color = item_data.mesh_color
		else:
			mat.albedo_color = RARITY_COLORS.get(item_data.rarity, Color.WHITE)
		# Add glow for epic and legendary items
		if item_data.rarity >= ItemData.Rarity.EPIC:
			mat.emission_enabled = true
			mat.emission = mat.albedo_color
			mat.emission_energy_multiplier = 1.5
		mesh.material_override = mat


func is_immune_to(peer_id: int) -> bool:
	## Returns true if this specific player can't pick up the item yet.
	return _immune_peer_id == peer_id and _immune_timer > 0.0


func _on_body_entered(body: Node3D) -> void:
	## When a player walks into the pickup area, they can pick it up.
	## For simplicity, auto-pickup on contact. Can change to button press later.
	if not multiplayer.is_server():
		return
	if body is CharacterBody3D and body.has_method("_on_item_pickup"):
		# Check pickup immunity
		if body.has_method("get") and body.get("peer_id") is int:
			if is_immune_to(body.peer_id):
				return
		body._on_item_pickup(self)


func _update_scrap_popup() -> void:
	## Client-side: show a floating "X: SCRAP [+fuel]" popup when the local player is nearby.
	if item_data == null:
		return

	# Find the local player
	var players_container := get_tree().current_scene.get_node_or_null("Players")
	if players_container == null:
		_hide_scrap_popup()
		return

	var local_id := multiplayer.get_unique_id()
	var local_player: Node = players_container.get_node_or_null(str(local_id))
	if local_player == null:
		_hide_scrap_popup()
		return

	var dist: float = global_position.distance_to(local_player.global_position)
	if dist < SCRAP_POPUP_RANGE:
		_show_scrap_popup()
	else:
		_hide_scrap_popup()


func _show_scrap_popup() -> void:
	if _scrap_label != null:
		return  # Already showing

	var rarity: int = item_data.rarity
	var fuel: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	fuel += burn_time_remaining * 0.1

	_scrap_label = Label3D.new()
	_scrap_label.text = "[X] SCRAP  +%.0f fuel" % fuel
	_scrap_label.font_size = 48
	_scrap_label.modulate = Color(1.0, 0.6, 0.2)
	_scrap_label.outline_modulate = Color(0, 0, 0)
	_scrap_label.outline_size = 6
	_scrap_label.position = Vector3(0, 1.2, 0)
	_scrap_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_scrap_label)


func _hide_scrap_popup() -> void:
	if _scrap_label != null:
		_scrap_label.queue_free()
		_scrap_label = null


func _ensure_above_ground() -> void:
	## Raycast downward to find the actual surface, then snap the item on top.
	## Prevents items from spawning inside terrain or under structures.
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	# Cast a ray from well above the item straight down to find the surface
	var ray_start := global_position + Vector3(0, 5.0, 0)
	var ray_end := global_position - Vector3(0, 10.0, 0)
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1  # Terrain / structures layer
	query.collide_with_areas = false

	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		# Snap to 0.5m above the surface so the item sits visibly on top
		var surface_y: float = result.position.y
		if global_position.y < surface_y + 0.3:
			global_position.y = surface_y + 0.5
