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

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var label: Label3D = $Label3D


func _ready() -> void:
	if item_data:
		burn_time_remaining = item_data.initial_burn_time
		_update_visual()

	body_entered.connect(_on_body_entered)


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


func _update_visual() -> void:
	if mesh and item_data:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = item_data.mesh_color
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
