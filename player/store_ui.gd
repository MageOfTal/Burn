extends Control

## Full-screen store UI for spending kill currency on persistent bonuses.
## Opened by server RPC when the player presses E near a KillStore.
## Shows all bonuses with BUY/OWNED/too-expensive states.

const KillStoreScript = preload("res://world/kill_store.gd")

var _player: Player = null
var _inventory: Node = null
var _dirty: bool = true
var _is_open: bool = false


func setup(player: Player) -> void:
	_player = player
	_inventory = player.get_node_or_null("Inventory")
	_dirty = true


func open_store() -> void:
	_is_open = true
	visible = true
	_dirty = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	var pi := _player.get_node_or_null("PlayerInput")
	if pi:
		pi.store_open = true


func close_store() -> void:
	_is_open = false
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var pi := _player.get_node_or_null("PlayerInput")
	if pi:
		pi.store_open = false


func _process(_delta: float) -> void:
	if not _is_open:
		return
	if _player == null or _inventory == null:
		return

	# Auto-close if player dies
	if not _player.is_alive:
		close_store()
		return

	# Close on Escape or E press
	if Input.is_action_just_pressed("ui_cancel") or Input.is_action_just_pressed("pickup"):
		close_store()
		return

	if _dirty:
		_dirty = false
		_rebuild_ui()


func _rebuild_ui() -> void:
	# Clear existing children
	for child in get_children():
		child.queue_free()

	var tokens: float = _inventory.kill_currency

	# Semi-transparent dark background
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.05, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# Main container — centered panel
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -380
	panel.offset_right = 380
	panel.offset_top = -320
	panel.offset_bottom = 320
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.14, 0.95)
	style.border_color = Color(0.3, 0.85, 1.0, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "KILL STORE"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Currency display
	var currency_lbl := Label.new()
	currency_lbl.text = "TOKENS: %d" % int(tokens)
	currency_lbl.add_theme_font_size_override("font_size", 20)
	if tokens >= 5:
		currency_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.1))
	elif tokens >= 1:
		currency_lbl.add_theme_color_override("font_color", Color(0.9, 0.15, 0.15))
	else:
		currency_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	currency_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(currency_lbl)

	# Separator
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	vbox.add_child(sep)

	# Scroll container for the bonus list
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var bonus_vbox := VBoxContainer.new()
	bonus_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bonus_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(bonus_vbox)

	# Tier headers and bonuses
	var tier_labels := ["--- TIER 1 (1 Token) ---", "--- TIER 2 (2 Tokens) ---", "--- TIER 3 (3 Tokens) ---", "--- TIER 4 (5 Tokens) ---"]
	var tier_ranges := [[0, 4], [4, 8], [8, 11], [11, 13]]

	for tier_idx in tier_labels.size():
		var tier_header := Label.new()
		tier_header.text = tier_labels[tier_idx]
		tier_header.add_theme_font_size_override("font_size", 13)
		tier_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
		tier_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bonus_vbox.add_child(tier_header)

		for i in range(tier_ranges[tier_idx][0], tier_ranges[tier_idx][1]):
			if i >= KillStoreScript.BONUS_CATALOG.size():
				break
			var bonus: Dictionary = KillStoreScript.BONUS_CATALOG[i]
			var row := _create_bonus_row(bonus, tokens)
			bonus_vbox.add_child(row)

	# Close hint
	var hint := Label.new()
	hint.text = "[E] or [ESC] Close"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)


func _create_bonus_row(bonus: Dictionary, tokens: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var bonus_id: int = bonus["id"]
	var cost: int = bonus["cost"]
	var owned: bool = bonus_id in _player.active_bonuses
	var can_afford: bool = tokens >= cost

	# Cost label
	var cost_lbl := Label.new()
	cost_lbl.text = "[%d]" % cost
	cost_lbl.add_theme_font_size_override("font_size", 14)
	cost_lbl.custom_minimum_size.x = 30
	if owned:
		cost_lbl.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
	elif can_afford:
		cost_lbl.add_theme_color_override("font_color", Color(0.3, 0.85, 1.0))
	else:
		cost_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	row.add_child(cost_lbl)

	# Name + description
	var info_vbox := VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vbox.add_theme_constant_override("separation", 0)

	var name_lbl := Label.new()
	name_lbl.text = bonus["name"]
	name_lbl.add_theme_font_size_override("font_size", 14)
	if owned:
		name_lbl.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
	elif can_afford:
		name_lbl.add_theme_color_override("font_color", Color.WHITE)
	else:
		name_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	info_vbox.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = bonus["desc"]
	desc_lbl.add_theme_font_size_override("font_size", 11)
	if owned:
		desc_lbl.add_theme_color_override("font_color", Color(0.15, 0.6, 0.15))
	elif can_afford:
		desc_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	else:
		desc_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
	info_vbox.add_child(desc_lbl)

	row.add_child(info_vbox)

	# Action button/label
	if owned:
		var owned_lbl := Label.new()
		owned_lbl.text = "OWNED"
		owned_lbl.add_theme_font_size_override("font_size", 13)
		owned_lbl.add_theme_color_override("font_color", Color(0.2, 0.8, 0.2))
		owned_lbl.custom_minimum_size.x = 65
		owned_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(owned_lbl)
	elif can_afford:
		var buy_btn := Button.new()
		buy_btn.text = "BUY"
		buy_btn.custom_minimum_size = Vector2(65, 28)
		buy_btn.pressed.connect(_on_buy_pressed.bind(bonus_id))
		row.add_child(buy_btn)
	else:
		var na_lbl := Label.new()
		na_lbl.text = "--"
		na_lbl.add_theme_font_size_override("font_size", 13)
		na_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
		na_lbl.custom_minimum_size.x = 65
		na_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(na_lbl)

	return row


func _on_buy_pressed(bonus_id: int) -> void:
	if _player == null:
		return
	# Host (peer 1) calls directly since call_remote RPCs skip the sender
	if _player.multiplayer.get_unique_id() == 1:
		_player.rpc_buy_bonus(bonus_id)
	else:
		_player.rpc_buy_bonus.rpc_id(1, bonus_id)
	# Rebuild UI to reflect the change and keep cursor visible
	_dirty = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
