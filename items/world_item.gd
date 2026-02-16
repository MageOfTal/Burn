extends Area3D
class_name WorldItem

## An item lying on the ground that players can pick up.
## Server-authoritative: server manages pickup and burn timers.

@export var item_data: ItemData = null

var burn_time_remaining: float = 0.0
var _setup_called := false

## Pickup immunity: the peer_id that just dropped this item can't pick it up
## until the timer expires. Prevents drop-pickup loops.
var _immune_peer_id: int = -1
var _immune_timer: float = 0.0
const PICKUP_IMMUNITY_TIME := 2.0

## Deferred ground check: runs once on the first physics frame instead of
## call_deferred from _ready(), which is unsafe with threaded physics.
var _needs_ground_check: bool = false

const SCRAP_POPUP_RANGE := 4.0
const SCRAP_FUEL_BY_RARITY := [10.0, 30.0, 65.0, 130.0, 250.0]

## Rarity colors for world item boxes
const RARITY_COLORS := {
	ItemData.Rarity.COMMON: Color(0.6, 0.6, 0.6, 1),
	ItemData.Rarity.UNCOMMON: Color(0.2, 0.8, 0.2, 1),
	ItemData.Rarity.RARE: Color(0.3, 0.5, 1.0, 1),
	ItemData.Rarity.EPIC: Color(0.7, 0.3, 0.9, 1),
	ItemData.Rarity.LEGENDARY: Color(1.0, 0.7, 0.1, 1),
}

const PICKUP_POPUP_RANGE := 4.0

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var label: Label3D = $Label3D

## Proximity popup components (created in _ready, handle cached player + distance)
var _scrap_proximity: ProximityLabel = null
var _pickup_proximity: ProximityLabel = null


func _ready() -> void:
	# Only set burn_time if setup() wasn't already called (e.g. editor-placed items).
	# For spawner-created items, setup() runs before _ready() and the spawn function
	# may set a custom burn_time (like 999999 for permanent items) that we must preserve.
	if item_data and not _setup_called:
		burn_time_remaining = item_data.initial_burn_time
	if item_data:
		_update_visual()

	body_entered.connect(_on_body_entered)

	if multiplayer.is_server():
		_needs_ground_check = true

	_setup_proximity_labels()


func setup(data: ItemData) -> void:
	item_data = data
	burn_time_remaining = data.initial_burn_time
	_setup_called = true
	if is_inside_tree():
		_update_visual()


func set_pickup_immunity(peer_id: int) -> void:
	_immune_peer_id = peer_id
	_immune_timer = PICKUP_IMMUNITY_TIME


const PERMANENT_THRESHOLD := 999990.0  ## Items with burn_time >= this never expire

const RARITY_NAMES := ["Common", "Uncommon", "Rare", "Epic", "Legendary"]

func _process(delta: float) -> void:
	# Update floating label with rarity prefix
	if label and item_data:
		var rarity_tag: String = RARITY_NAMES[clampi(item_data.rarity, 0, 4)]
		if burn_time_remaining >= PERMANENT_THRESHOLD:
			label.text = "[%s] %s" % [rarity_tag, item_data.item_name]
		else:
			label.text = "[%s] %s [%ds]" % [rarity_tag, item_data.item_name, ceili(burn_time_remaining)]
		label.modulate = RARITY_COLORS.get(item_data.rarity, Color.WHITE)

	# Server: burn timer + immunity
	if multiplayer.is_server():
		if item_data and burn_time_remaining < PERMANENT_THRESHOLD:
			burn_time_remaining -= item_data.base_burn_rate * delta
			if burn_time_remaining <= 0.0:
				queue_free()
				return

		if _immune_timer > 0.0:
			_immune_timer -= delta
			if _immune_timer <= 0.0:
				_immune_peer_id = -1

	# Client: disable proximity popups for fuel items (auto-picked up)
	var is_fuel := item_data != null and item_data.item_type == ItemData.ItemType.FUEL
	var should_show := item_data != null and not is_fuel
	if _scrap_proximity:
		_scrap_proximity.set_process(should_show)
		if not should_show and _scrap_proximity.label:
			_scrap_proximity._hide_label()
	if _pickup_proximity:
		_pickup_proximity.set_process(should_show)
		if not should_show and _pickup_proximity.label:
			_pickup_proximity._hide_label()


func _physics_process(_delta: float) -> void:
	if _needs_ground_check:
		_needs_ground_check = false
		_ensure_above_ground()


func _update_visual() -> void:
	if mesh == null or item_data == null:
		return
	var mat := StandardMaterial3D.new()
	# Box color is determined exclusively by rarity
	mat.albedo_color = RARITY_COLORS.get(item_data.rarity, Color.WHITE)
	if item_data.rarity >= ItemData.Rarity.RARE:
		mat.emission_enabled = true
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 0.5 + item_data.rarity * 0.4  # Rare=1.3, Epic=1.7, Legendary=2.1
	mesh.material_override = mat


func is_immune_to(peer_id: int) -> bool:
	return _immune_peer_id == peer_id and _immune_timer > 0.0


func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	if body is CharacterBody3D and body.has_method("_on_item_pickup"):
		if body.get("peer_id") is int:
			if is_immune_to(body.peer_id):
				return
		# Only auto-pickup fuel items — everything else requires pressing E
		if item_data and item_data.item_type == ItemData.ItemType.FUEL:
			body._on_item_pickup(self)


# ======================================================================
#  Proximity popups (client-side, via ProximityLabel components)
# ======================================================================

func _setup_proximity_labels() -> void:
	# Pickup label — create/destroy style, green text, static "[E] PICKUP" (top)
	_pickup_proximity = ProximityLabel.new()
	_pickup_proximity.popup_range = PICKUP_POPUP_RANGE
	_pickup_proximity.label_offset = Vector3(0, 1.5, 0)
	_pickup_proximity.label_color = Color(0.3, 1.0, 0.4)
	_pickup_proximity.use_visibility_toggle = false
	_pickup_proximity.update_callback = _on_pickup_label_update
	_pickup_proximity.visibility_callback = _is_closest_item_check
	add_child(_pickup_proximity)

	# Scrap label — create/destroy style, orange text, updates fuel value each frame (bottom)
	_scrap_proximity = ProximityLabel.new()
	_scrap_proximity.popup_range = SCRAP_POPUP_RANGE
	_scrap_proximity.label_offset = Vector3(0, 1.2, 0)
	_scrap_proximity.label_color = Color(1.0, 0.6, 0.2)
	_scrap_proximity.use_visibility_toggle = false
	_scrap_proximity.update_callback = _on_scrap_label_update
	_scrap_proximity.visibility_callback = _is_closest_item_check
	add_child(_scrap_proximity)


func _on_scrap_label_update(lbl: Label3D, _player: Node, _dist: float) -> void:
	## Called every frame the scrap label is visible — keep fuel value accurate.
	var max_fuel: float = SCRAP_FUEL_BY_RARITY[clampi(item_data.rarity, 0, 4)]
	var initial_time: float = maxf(item_data.initial_burn_time, 0.1)
	var time_fraction: float = clampf(burn_time_remaining / initial_time, 0.0, 1.0)
	var fuel: float = max_fuel * time_fraction
	lbl.text = "[X] SCRAP  +%.0f fuel" % fuel


func _on_pickup_label_update(lbl: Label3D, _player: Node, _dist: float) -> void:
	## Called every frame the pickup label is visible — static text.
	lbl.text = "[E] PICKUP"


func _is_closest_item_check(player: Node, my_dist: float) -> bool:
	## Only show popups on the CLOSEST non-fuel item — prevents popup spam.
	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return true
	var player_pos: Vector3 = player.global_position
	for child in world_items.get_children():
		if child == self:
			continue
		if not child is Area3D or not ("item_data" in child) or child.item_data == null:
			continue
		if child.item_data.item_type == ItemData.ItemType.FUEL:
			continue
		var other_dist: float = player_pos.distance_to(child.global_position)
		if other_dist < my_dist:
			return false
	return true


func _ensure_above_ground() -> void:
	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	var ray_start := global_position + Vector3(0, 5.0, 0)
	var ray_end := global_position - Vector3(0, 10.0, 0)
	var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	query.collision_mask = 1
	query.collide_with_areas = false

	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		var surface_y: float = result.position.y
		if global_position.y < surface_y + 0.3:
			global_position.y = surface_y + 0.5
