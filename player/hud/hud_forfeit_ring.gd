extends Control
class_name HUDForfeitRing

## Forfeit ring widget — hold P to self-kill. Shows a circular progress
## indicator at screen center with a "FORFEIT" label.

const FORFEIT_DURATION := 3.0

var _player: Player = null

var _ring: Control = null
var _label: Label = null
var _hold_time: float = 0.0


func setup(player: Player) -> void:
	_player = player
	_build_ring()


func _build_ring() -> void:
	_ring = Control.new()
	_ring.set_anchors_preset(Control.PRESET_CENTER)
	_ring.offset_left = -50
	_ring.offset_right = 50
	_ring.offset_top = -50
	_ring.offset_bottom = 50
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.visible = false
	_ring.draw.connect(_draw_ring)
	add_child(_ring)

	_label = Label.new()
	_label.text = "FORFEIT"
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.2, 0.9))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_CENTER)
	_label.offset_top = 55
	_label.offset_bottom = 75
	_label.offset_left = -50
	_label.offset_right = 50
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.visible = false
	add_child(_label)


func update_forfeit_ring() -> void:
	if _player == null or _ring == null:
		return
	var pi: Node = _player.get_node_or_null("PlayerInput")
	if pi == null:
		return

	if pi.action_forfeit and _player.is_alive:
		_hold_time += get_process_delta_time()
		_ring.visible = true
		_label.visible = true
		_ring.queue_redraw()
	else:
		if _hold_time > 0.0:
			_hold_time = 0.0
			_ring.visible = false
			_label.visible = false


func _draw_ring() -> void:
	if _ring == null or not is_instance_valid(_ring):
		return
	if _hold_time <= 0.0:
		return
	var center := _ring.size / 2.0
	var radius := 40.0
	var width := 4.0
	var progress := clampf(_hold_time / FORFEIT_DURATION, 0.0, 1.0)

	# Background ring (dark grey, full circle)
	_ring.draw_arc(center, radius, 0.0, TAU, 64, Color(0.3, 0.3, 0.3, 0.5), width)

	# Progress arc (red, fills clockwise from top)
	var start_angle := -PI / 2.0
	var end_angle := start_angle + TAU * progress
	var color := Color(1.0, 0.2, 0.1, 0.9)
	if progress > 0.8:
		color = Color(1.0, 0.0, 0.0, 1.0)
	_ring.draw_arc(center, radius, start_angle, end_angle, 64, color, width)
