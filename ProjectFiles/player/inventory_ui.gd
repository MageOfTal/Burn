extends Control

## Tab-key inventory UI. Shows 6 weapon slots with ammo sub-slots,
## a sidebar of available ammo items, and a fuel display.
## Click an ammo item to select it, then click a weapon's ammo slot to assign.
## Click an occupied ammo slot to unslot.

const RARITY_COLORS := {
	0: Color(0.7, 0.7, 0.7),      # Common — gray
	1: Color(0.3, 0.8, 0.3),      # Uncommon — green
	2: Color(0.3, 0.5, 1.0),      # Rare — blue
	3: Color(0.7, 0.3, 0.9),      # Epic — purple
	4: Color(1.0, 0.7, 0.1),      # Legendary — gold
}

const RARITY_NAMES := ["Common", "Uncommon", "Rare", "Epic", "Legendary"]

var _player: Player = null
var _inventory: Node = null  # Inventory
var _selected_ammo_index: int = -1  ## Inventory index of ammo selected for slotting
var _selected_trinket_index: int = -1  ## Trinket bag index of trinket selected for attaching
var _dirty: bool = true  ## When true, rebuild UI next frame
var _was_visible: bool = false  ## Track visibility changes to trigger rebuild


func setup(player: Player) -> void:
	_player = player
	_inventory = player.get_node_or_null("Inventory")
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


func _process(_delta: float) -> void:
	if not visible:
		_was_visible = false
		return
	if _player == null or _inventory == null:
		return

	# Rebuild when we first become visible
	if not _was_visible:
		_dirty = true
		_was_visible = true

	if _dirty:
		_dirty = false
		_rebuild_ui()


func _rebuild_ui() -> void:
	## Rebuild the entire UI. Only called when _dirty is set.

	# Clear existing children immediately
	for child in get_children():
		remove_child(child)
		child.free()

	# Semi-transparent background
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.6)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# Title
	var title := Label.new()
	title.text = "INVENTORY"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0, 30)
	title.size = Vector2(get_viewport_rect().size.x, 40)
	add_child(title)

	# Main layout: weapons on left, ammo on right
	var screen_size := get_viewport_rect().size
	var center_x := screen_size.x * 0.5
	var start_y := 100.0

	# --- Fuel display ---
	var fuel_label := Label.new()
	fuel_label.text = "🔥 FUEL: %.0f" % _inventory.burn_fuel
	fuel_label.add_theme_font_size_override("font_size", 24)
	if _inventory.burn_fuel < 100:
		fuel_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	elif _inventory.burn_fuel < 300:
		fuel_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2))
	else:
		fuel_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.1))
	fuel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fuel_label.position = Vector2(0, start_y)
	fuel_label.size = Vector2(screen_size.x, 30)
	add_child(fuel_label)

	start_y += 50.0

	# --- Weapon slots (left side) ---
	var weapon_section_label := Label.new()
	weapon_section_label.text = "WEAPONS"
	weapon_section_label.add_theme_font_size_override("font_size", 20)
	weapon_section_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	weapon_section_label.position = Vector2(center_x - 400, start_y)
	add_child(weapon_section_label)

	var ammo_section_label := Label.new()
	ammo_section_label.text = "AMMO MODULES"
	ammo_section_label.add_theme_font_size_override("font_size", 20)
	ammo_section_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	ammo_section_label.position = Vector2(center_x + 100, start_y)
	add_child(ammo_section_label)

	start_y += 35.0

	# Draw weapon slots (sequential positioning — skip gaps from empty/non-weapon slots)
	var weapon_count := 0
	for i in _inventory.items.size():
		if _inventory.items[i] == null:
			continue
		var stack: ItemStack = _inventory.items[i]
		if not stack.item_data is WeaponData:
			continue

		var slot_y: float = start_y + weapon_count * 110.0
		_draw_weapon_slot(i, stack, center_x - 400, slot_y)
		weapon_count += 1

	# --- Ammo items (right side) ---
	# Shows WeaponData items with can_slot_as_ammo
	var ammo_y := start_y
	var ammo_count := 0
	for i in _inventory.items.size():
		if _inventory.items[i] == null:
			continue
		var stack: ItemStack = _inventory.items[i]
		if not (stack.item_data is WeaponData and stack.item_data.can_slot_as_ammo):
			continue

		_draw_ammo_item(i, stack, center_x + 100, ammo_y)
		ammo_y += 70.0
		ammo_count += 1

	if ammo_count == 0:
		var no_ammo := Label.new()
		no_ammo.text = "No ammo modules found.\nPick up ammo from the world."
		no_ammo.add_theme_font_size_override("font_size", 14)
		no_ammo.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		no_ammo.position = Vector2(center_x + 100, ammo_y)
		add_child(no_ammo)
		ammo_y += 40.0  # Advance past the two-line label

	# --- Trinket section (below ammo, right side) ---
	ammo_y += 20.0

	var trinket_section_label := Label.new()
	trinket_section_label.text = "TRINKET BAG"
	trinket_section_label.add_theme_font_size_override("font_size", 20)
	trinket_section_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4))
	trinket_section_label.position = Vector2(center_x + 100, ammo_y)
	add_child(trinket_section_label)
	ammo_y += 30.0

	# Show trinkets in bag
	if _inventory.trinket_bag.size() == 0:
		var no_trinkets := Label.new()
		no_trinkets.text = "No trinkets.\nFind them in chests."
		no_trinkets.add_theme_font_size_override("font_size", 14)
		no_trinkets.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		no_trinkets.position = Vector2(center_x + 100, ammo_y)
		add_child(no_trinkets)
		ammo_y += 40.0
	else:
		for t_i in _inventory.trinket_bag.size():
			var t_stack: ItemStack = _inventory.trinket_bag[t_i]
			if t_stack == null or t_stack.item_data == null:
				continue
			_draw_trinket_bag_item(t_i, t_stack, center_x + 100, ammo_y)
			ammo_y += 55.0

	# Show shoe trinket slots (if shoe equipped)
	ammo_y += 10.0
	if _inventory.equipped_shoe != null and _inventory.equipped_shoe.item_data is ShoeData:
		var shoe_data: ShoeData = _inventory.equipped_shoe.item_data as ShoeData
		var shoe_rarity_color: Color = RARITY_COLORS.get(shoe_data.rarity, Color.WHITE)

		var shoe_trinket_label := Label.new()
		shoe_trinket_label.text = "SHOE TRINKET SLOTS (%s)" % shoe_data.item_name
		shoe_trinket_label.add_theme_font_size_override("font_size", 16)
		shoe_trinket_label.add_theme_color_override("font_color", shoe_rarity_color)
		shoe_trinket_label.position = Vector2(center_x + 100, ammo_y)
		add_child(shoe_trinket_label)
		ammo_y += 25.0

		# Show attached trinkets with detach buttons
		for s_i in _inventory.equipped_shoe.slotted_trinkets.size():
			var trinket = _inventory.equipped_shoe.slotted_trinkets[s_i]
			if trinket == null:
				continue
			var t_color: Color = RARITY_COLORS.get(trinket.rarity, Color.WHITE)

			var t_name := Label.new()
			t_name.text = trinket.item_name
			t_name.add_theme_font_size_override("font_size", 14)
			t_name.add_theme_color_override("font_color", t_color)
			t_name.position = Vector2(center_x + 100, ammo_y)
			add_child(t_name)

			var detach_btn := Button.new()
			detach_btn.text = "Detach"
			detach_btn.add_theme_font_size_override("font_size", 12)
			detach_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
			detach_btn.position = Vector2(center_x + 300, ammo_y - 2)
			detach_btn.size = Vector2(80, 22)
			detach_btn.pressed.connect(_on_unslot_trinket.bind(s_i))
			add_child(detach_btn)
			ammo_y += 25.0

		# Show empty slots with attach button (if trinket selected)
		var open_slots: int = shoe_data.max_trinket_slots - _inventory.equipped_shoe.slotted_trinkets.size()
		for _s in open_slots:
			if _selected_trinket_index >= 0:
				var attach_btn := Button.new()
				attach_btn.text = "[ Click to ATTACH trinket ]"
				attach_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
				attach_btn.add_theme_font_size_override("font_size", 13)
				attach_btn.position = Vector2(center_x + 100, ammo_y)
				attach_btn.size = Vector2(280, 24)
				attach_btn.pressed.connect(_on_slot_trinket)
				add_child(attach_btn)
			else:
				var empty_slot := Label.new()
				empty_slot.text = "[ Empty trinket slot ]"
				empty_slot.add_theme_font_size_override("font_size", 13)
				empty_slot.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
				empty_slot.position = Vector2(center_x + 100, ammo_y)
				add_child(empty_slot)
			ammo_y += 25.0

	# --- Help text ---
	var help := Label.new()
	help.text = "Ammo: Click to select, merge into weapon (permanent!) | Trinkets: Click to select, attach to shoe (removable!) | TAB to close"
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.position = Vector2(0, screen_size.y - 50)
	help.size = Vector2(screen_size.x, 20)
	add_child(help)


func _draw_weapon_slot(index: int, stack: ItemStack, x: float, y: float) -> void:
	var weapon_data: WeaponData = stack.item_data as WeaponData
	var rarity_color: Color = RARITY_COLORS.get(weapon_data.rarity, Color.WHITE)
	var is_equipped: bool = (_inventory.equipped_index == index)

	# Slot background panel
	var panel := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.15, 0.15, 0.2, 0.9)
	style.border_color = rarity_color if not is_equipped else Color(1.0, 1.0, 0.3)
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(x, y)
	panel.size = Vector2(420, 95)
	add_child(panel)

	# Slot number
	var slot_label := Label.new()
	slot_label.text = "[%d]" % (index + 1)
	slot_label.add_theme_font_size_override("font_size", 14)
	slot_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	slot_label.position = Vector2(x + 8, y + 5)
	add_child(slot_label)

	# Weapon name
	var name_label := Label.new()
	name_label.text = weapon_data.item_name
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", rarity_color)
	name_label.position = Vector2(x + 40, y + 5)
	add_child(name_label)

	# Rarity tag
	var rarity_label := Label.new()
	rarity_label.text = RARITY_NAMES[weapon_data.rarity]
	rarity_label.add_theme_font_size_override("font_size", 12)
	rarity_label.add_theme_color_override("font_color", rarity_color)
	rarity_label.position = Vector2(x + 40, y + 28)
	add_child(rarity_label)

	# Stats line
	var stats := Label.new()
	stats.text = "DMG: %.0f  |  ROF: %.1f/s  |  Fuel: %.0f" % [weapon_data.damage, 1.0 / maxf(weapon_data.fire_rate, 0.01), weapon_data.burn_fuel_cost]
	stats.add_theme_font_size_override("font_size", 12)
	stats.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	stats.position = Vector2(x + 40, y + 45)
	add_child(stats)

	# Burn timer
	var burn_label := Label.new()
	burn_label.text = "⏱ %.0fs" % stack.burn_time_remaining
	burn_label.add_theme_font_size_override("font_size", 12)
	burn_label.add_theme_color_override("font_color", Color(0.8, 0.6, 0.3))
	burn_label.position = Vector2(x + 350, y + 5)
	add_child(burn_label)

	# Equipped indicator
	if is_equipped:
		var eq_label := Label.new()
		eq_label.text = "▶ EQUIPPED"
		eq_label.add_theme_font_size_override("font_size", 11)
		eq_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
		eq_label.position = Vector2(x + 300, y + 28)
		add_child(eq_label)

	# --- Ammo sub-slot (only for weapons that accept ammo) ---
	if not weapon_data.can_receive_ammo:
		return  # No ammo slot for this weapon type

	var ammo_label := Label.new()
	if stack.slotted_ammo:
		var ammo_color: Color = RARITY_COLORS.get(stack.slotted_ammo.rarity, Color.WHITE)
		ammo_label.text = "⚡ MERGED: " + stack.slotted_ammo.item_name
		ammo_label.add_theme_color_override("font_color", ammo_color)
	else:
		if _selected_ammo_index >= 0:
			# Show clickable button to merge
			var ammo_btn := Button.new()
			ammo_btn.text = "[ Click to MERGE ammo (permanent!) ]"
			ammo_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.3))
			ammo_btn.pressed.connect(_on_slot_ammo.bind(index))
			ammo_btn.tooltip_text = "Merges ammo into weapon. Combines timers × 0.8. Permanent!"
			ammo_btn.add_theme_font_size_override("font_size", 13)
			ammo_btn.position = Vector2(x + 40, y + 65)
			ammo_btn.size = Vector2(370, 25)
			add_child(ammo_btn)
			return  # Skip the label below
		else:
			ammo_label.text = "[ Empty ammo slot ]"
			ammo_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))

	ammo_label.add_theme_font_size_override("font_size", 13)
	ammo_label.position = Vector2(x + 40, y + 65)
	add_child(ammo_label)


func _draw_ammo_item(index: int, stack: ItemStack, x: float, y: float) -> void:
	var weapon: WeaponData = stack.item_data as WeaponData
	var item_name: String = weapon.item_name
	var rarity: int = weapon.rarity
	var burn_cost: float = weapon.ammo_burn_cost_per_shot
	var dmg_mult: float = weapon.ammo_damage_mult

	var rarity_color: Color = RARITY_COLORS.get(rarity, Color.WHITE)
	var is_selected: bool = (_selected_ammo_index == index)

	var btn := Button.new()
	btn.text = item_name
	btn.add_theme_font_size_override("font_size", 16)

	if is_selected:
		btn.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
		btn.tooltip_text = "Selected — click a weapon slot to assign"
	else:
		btn.add_theme_color_override("font_color", rarity_color)
		btn.tooltip_text = "Click to select for slotting"

	btn.position = Vector2(x, y)
	btn.size = Vector2(280, 30)
	btn.pressed.connect(_on_select_ammo.bind(index))
	add_child(btn)

	# Info line
	var info := Label.new()
	info.text = "%s  |  +%.0f fuel/shot  |  %.0fx DMG  |  ⏱ %.0fs" % [
		RARITY_NAMES[rarity],
		burn_cost,
		dmg_mult,
		stack.burn_time_remaining
	]
	info.add_theme_font_size_override("font_size", 11)
	info.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	info.position = Vector2(x, y + 32)
	add_child(info)

	# Check if this ammo is already slotted somewhere
	var slotted_to := ""
	for i in _inventory.items.size():
		if _inventory.items[i] == null:
			continue
		var s: ItemStack = _inventory.items[i]
		if s.slotted_ammo_source_index == index:
			slotted_to = s.item_data.item_name
			break
	if slotted_to != "":
		var slotted_label := Label.new()
		slotted_label.text = "→ Slotted in: " + slotted_to
		slotted_label.add_theme_font_size_override("font_size", 11)
		slotted_label.add_theme_color_override("font_color", Color(0.3, 0.7, 0.3))
		slotted_label.position = Vector2(x, y + 48)
		add_child(slotted_label)


func _on_select_ammo(ammo_index: int) -> void:
	## Toggle ammo selection.
	if _selected_ammo_index == ammo_index:
		_selected_ammo_index = -1  # Deselect
	else:
		_selected_ammo_index = ammo_index
	_dirty = true  # Rebuild to show selected state


func _on_slot_ammo(weapon_index: int) -> void:
	## Assign the selected ammo to this weapon's ammo slot.
	if _selected_ammo_index < 0:
		return
	if _player and _player.has_method("rpc_slot_ammo"):
		_player.rpc_slot_ammo.rpc_id(1, _selected_ammo_index, weapon_index)
	_selected_ammo_index = -1
	_dirty = true  # Rebuild to reflect the change



# ======================================================================
#  Trinket UI
# ======================================================================

func _draw_trinket_bag_item(index: int, stack: ItemStack, x: float, y: float) -> void:
	var trinket_data = stack.item_data
	var rarity_color: Color = RARITY_COLORS.get(trinket_data.rarity, Color.WHITE)
	var is_selected: bool = (_selected_trinket_index == index)

	var btn := Button.new()
	btn.text = trinket_data.item_name
	btn.add_theme_font_size_override("font_size", 16)

	if is_selected:
		btn.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
		btn.tooltip_text = "Selected — click a shoe trinket slot to attach"
	else:
		btn.add_theme_color_override("font_color", rarity_color)
		btn.tooltip_text = "Click to select for attaching to shoe"

	btn.position = Vector2(x, y)
	btn.size = Vector2(280, 28)
	btn.pressed.connect(_on_select_trinket.bind(index))
	add_child(btn)

	# Info line
	var info := Label.new()
	var effect_text := ""
	if trinket_data is TrinketData and trinket_data.extra_jumps > 0:
		effect_text = "+%d Jump" % trinket_data.extra_jumps
	info.text = "%s  |  %s" % [
		RARITY_NAMES[trinket_data.rarity],
		effect_text if effect_text != "" else "Trinket",
	]
	info.add_theme_font_size_override("font_size", 11)
	info.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	info.position = Vector2(x, y + 30)
	add_child(info)


func _on_select_trinket(trinket_index: int) -> void:
	## Toggle trinket selection.
	if _selected_trinket_index == trinket_index:
		_selected_trinket_index = -1  # Deselect
	else:
		_selected_trinket_index = trinket_index
	_dirty = true


func _on_slot_trinket() -> void:
	## Attach the selected trinket to the equipped shoe.
	if _selected_trinket_index < 0:
		return
	if _player and _player.has_method("rpc_slot_trinket_on_shoe"):
		_player.rpc_slot_trinket_on_shoe.rpc_id(1, _selected_trinket_index)
	_selected_trinket_index = -1
	_dirty = true


func _on_unslot_trinket(trinket_slot_index: int) -> void:
	## Detach a trinket from the equipped shoe.
	if _player and _player.has_method("rpc_unslot_trinket_from_shoe"):
		_player.rpc_unslot_trinket_from_shoe.rpc_id(1, trinket_slot_index)
	_selected_trinket_index = -1
	_dirty = true
