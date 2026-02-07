extends Control

## Player HUD: displays health, heat, 6 weapon slots, time currency.
## Only active for the local player.

@onready var health_bar: ProgressBar = $MarginContainer/VBoxLeft/HealthBar
@onready var heat_bar: ProgressBar = $MarginContainer/VBoxLeft/HeatBar
@onready var time_currency_label: Label = $MarginContainer/VBoxLeft/TimeCurrencyLabel
@onready var inventory_list: VBoxContainer = $MarginContainer/VBoxRight/InventoryList
@onready var fever_label: Label = $FeverLabel
@onready var inventory_hint: Label = $MarginContainer/VBoxRight/InventoryHint

var _player: CharacterBody3D = null


func setup(player: CharacterBody3D) -> void:
	_player = player


func _process(_delta: float) -> void:
	if _player == null:
		return

	# Health
	if health_bar:
		health_bar.value = _player.health
		health_bar.max_value = _player.MAX_HEALTH

	# Heat
	if heat_bar:
		var heat_system := _player.get_node_or_null("HeatSystem")
		if heat_system:
			heat_bar.value = heat_system.heat_level
			heat_bar.max_value = heat_system.max_heat
			heat_bar.visible = true
		else:
			heat_bar.visible = false

	# Time currency
	var inventory := _player.get_node_or_null("Inventory") as Inventory
	if inventory and time_currency_label:
		time_currency_label.text = "TC: %.0f" % inventory.time_currency

	# Fever indicator
	if fever_label:
		var heat_sys := _player.get_node_or_null("HeatSystem")
		fever_label.visible = heat_sys != null and heat_sys.get("is_fever") == true

	# Weapon slot hint
	if inventory_hint:
		inventory_hint.text = "1-6: switch weapon"

	_update_inventory_display()


func _update_inventory_display() -> void:
	if inventory_list == null or _player == null:
		return

	var inventory := _player.get_node_or_null("Inventory") as Inventory
	if inventory == null:
		return

	# Clear existing entries
	for child in inventory_list.get_children():
		child.queue_free()

	# Show all 6 slots (empty or filled)
	for i in 6:
		var entry := Label.new()
		var slot_num := i + 1
		var is_equipped := (i == inventory.equipped_index)

		if i < inventory.items.size():
			var stack: ItemStack = inventory.items[i]
			var time_str := "%ds" % ceili(stack.burn_time_remaining)
			var rarity_names := ["C", "U", "R", "E", "L"]
			var rarity_tag: String = rarity_names[stack.item_data.rarity] if stack.item_data else "?"
			var equip_marker := " <<" if is_equipped else ""
			entry.text = "[%d] [%s] %s - %s%s" % [slot_num, rarity_tag, stack.item_data.item_name, time_str, equip_marker]

			# Color by equipped state or burn time urgency
			if is_equipped:
				entry.modulate = Color.CYAN
			elif stack.burn_time_remaining < 15.0:
				entry.modulate = Color.RED
			elif stack.burn_time_remaining < 45.0:
				entry.modulate = Color.YELLOW
			else:
				entry.modulate = Color.WHITE
		else:
			entry.text = "[%d] ---" % slot_num
			entry.modulate = Color(0.4, 0.4, 0.4, 1)

		entry.add_theme_font_size_override("font_size", 14)
		inventory_list.add_child(entry)
