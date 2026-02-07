extends Area3D
class_name WorldItem

## An item lying on the ground that players can pick up.
## Server-authoritative: server manages pickup and burn timers.

@export var item_data: ItemData = null

var burn_time_remaining: float = 0.0

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


func _update_visual() -> void:
	if mesh and item_data:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = item_data.mesh_color
		mesh.material_override = mat


func _on_body_entered(body: Node3D) -> void:
	## When a player walks into the pickup area, they can pick it up.
	## For simplicity, auto-pickup on contact. Can change to button press later.
	if not multiplayer.is_server():
		return
	if body is CharacterBody3D and body.has_method("_on_item_pickup"):
		body._on_item_pickup(self)
