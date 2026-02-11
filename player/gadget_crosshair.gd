extends Control
class_name GadgetCrosshair

## Gray X crosshair that appears only when the player has a gadget equipped
## (grappling hook, etc.).  Uses _draw() for pixel-perfect centering that
## matches the white-dot crosshair at screen center.

const X_SIZE := 6.0        ## Half-length of each X arm (pixels)
const X_THICKNESS := 2.0   ## Line width
const X_COLOR := Color(0.75, 0.75, 0.75, 0.5)

var _player: CharacterBody3D = null


func setup(player: CharacterBody3D) -> void:
	_player = player
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	# Anchor to screen center (same as white dot Crosshair)
	set_anchors_preset(Control.PRESET_CENTER)
	pivot_offset = Vector2.ZERO


func _process(_delta: float) -> void:
	if _player == null:
		visible = false
		return

	var should_show := _is_gadget_equipped()
	if visible != should_show:
		visible = should_show
		if should_show:
			queue_redraw()


func _is_gadget_equipped() -> bool:
	var inventory: Node = _player.get_node_or_null("Inventory")
	if inventory == null:
		return false
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return false
	var equipped: ItemStack = inventory.items[inventory.equipped_index]
	if equipped == null or equipped.item_data == null:
		return false
	return equipped.item_data is GadgetData or equipped.item_data is ConsumableData


func _draw() -> void:
	if not visible:
		return
	# Draw an X centered at (0, 0) — our position is anchored to screen center
	draw_line(Vector2(-X_SIZE, -X_SIZE), Vector2(X_SIZE, X_SIZE), X_COLOR, X_THICKNESS, true)
	draw_line(Vector2(-X_SIZE, X_SIZE), Vector2(X_SIZE, -X_SIZE), X_COLOR, X_THICKNESS, true)
