extends Control
class_name HUDVictoryScreen

## Victory/game-over overlay widget — shown when a winner is declared.

var _victory_overlay: Control = null


func show_victory_screen(winner_id: int, winner_name: String, my_id: int) -> void:
	## Display the victory overlay. Called by NetworkManager RPC on all peers.
	if _victory_overlay != null:
		return

	_victory_overlay = ColorRect.new()
	_victory_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_victory_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var is_winner: bool = (winner_id == my_id)

	if is_winner:
		_victory_overlay.color = Color(0.05, 0.1, 0.0, 0.75)
	else:
		_victory_overlay.color = Color(0.05, 0.05, 0.1, 0.75)

	# Main title
	var title := Label.new()
	if winner_id == -1:
		title.text = "DRAW"
		title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	elif is_winner:
		title.text = "VICTORY"
		title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
	else:
		title.text = "GAME OVER"
		title.add_theme_color_override("font_color", Color(0.8, 0.4, 0.3))
	title.add_theme_font_size_override("font_size", 64)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_CENTER)
	title.offset_left = -400
	title.offset_right = 400
	title.offset_top = -100
	title.offset_bottom = -30
	_victory_overlay.add_child(title)

	# Winner name subtitle
	var sub := Label.new()
	if winner_id == -1:
		sub.text = "Everyone was eliminated!"
	elif is_winner:
		sub.text = "You are the last one standing!"
	else:
		sub.text = "%s is the last one standing!" % winner_name
	sub.add_theme_font_size_override("font_size", 24)
	sub.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub.set_anchors_preset(Control.PRESET_CENTER)
	sub.offset_left = -400
	sub.offset_right = 400
	sub.offset_top = 0
	sub.offset_bottom = 50
	_victory_overlay.add_child(sub)

	# Fade in
	_victory_overlay.modulate = Color(1, 1, 1, 0)
	add_child(_victory_overlay)
	var tween := create_tween()
	tween.tween_property(_victory_overlay, "modulate:a", 1.0, 1.0)
