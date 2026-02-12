extends Control

## Player HUD: displays health, heat, 6 weapon slots, time currency,
## compass strip with markers, and zone info.
## Only active for the local player.

@onready var health_bar: ProgressBar = $MarginContainer/VBoxLeft/HealthBar
@onready var heat_bar: ProgressBar = $MarginContainer/VBoxLeft/HeatBar
@onready var time_currency_label: Label = $MarginContainer/VBoxLeft/TimeCurrencyLabel
@onready var shoe_slot_label: Label = $MarginContainer/VBoxLeft/ShoeSlotLabel
@onready var fuel_label: Label = $MarginContainer/VBoxLeft/FuelLabel
@onready var inventory_list: VBoxContainer = $MarginContainer/VBoxRight/InventoryList
@onready var fever_label: Label = $FeverLabel
@onready var inventory_hint: Label = $MarginContainer/VBoxRight/InventoryHint
@onready var ip_label: Label = $IPLabel

var _player: CharacterBody3D = null

## Cached subsystem references (resolved once in setup, not every frame)
var _heat_system: Node = null
var _inventory: Node = null

## Pre-created slot labels (reused every frame instead of queue_free + new)
var _slot_labels: Array[Label] = []
const SLOT_COUNT := 6

const RARITY_TAGS := ["C", "U", "R", "E", "L"]

## Zone info label (created in code, shown at bottom center)
var _zone_label: Label = null

# ======================================================================
#  Compass strip
# ======================================================================

const COMPASS_WIDTH := 600.0
const COMPASS_HEIGHT := 28.0
const COMPASS_FOV := 180.0  ## Degrees visible across the strip width
const CARDINALS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const CARDINAL_BEARINGS := [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]

var _compass_container: Control = null
var _compass_labels: Array[Label] = []   ## 8 cardinal direction labels
var _compass_ticks: Array[ColorRect] = [] ## Tick marks every 15°
var _compass_center_mark: ColorRect = null

## Player-placed world marker (MMB)
var _player_marker_pos: Vector3 = Vector3.INF
var _marker_icon: Label = null
var _marker_dist_label: Label = null
var _last_marker_count := 0

## Demon indicator on compass
var _demon_icon: Label = null
var _demon_dist_label: Label = null


func setup(player: CharacterBody3D) -> void:
	_player = player
	_heat_system = player.get_node_or_null("HeatSystem")
	_inventory = player.get_node_or_null("Inventory")

	# Show all LAN IPs so the host can pick the right one to share
	if ip_label:
		var lan_ips: Array[String] = []
		for ip in IP.get_local_addresses():
			if ip.begins_with("192.168.") or ip.begins_with("10."):
				lan_ips.append(ip)
		if lan_ips.size() == 0:
			ip_label.text = "IP: unknown"
		elif lan_ips.size() == 1:
			ip_label.text = "IP: %s" % lan_ips[0]
		else:
			ip_label.text = "IPs: %s" % " | ".join(lan_ips)

	# Pre-create the 6 inventory slot labels once (never freed, just updated)
	if inventory_list:
		for child in inventory_list.get_children():
			child.queue_free()
		_slot_labels.clear()
		for i in SLOT_COUNT:
			var entry := Label.new()
			entry.add_theme_font_size_override("font_size", 14)
			inventory_list.add_child(entry)
			_slot_labels.append(entry)

	if inventory_hint:
		inventory_hint.text = "1-6: switch  |  E: pickup  |  F: extend  |  X: scrap  |  TAB: inventory"

	# Create zone info label at bottom center
	_zone_label = Label.new()
	_zone_label.add_theme_font_size_override("font_size", 16)
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_zone_label.offset_top = -90
	_zone_label.offset_bottom = -70
	_zone_label.offset_left = -250
	_zone_label.offset_right = 250
	add_child(_zone_label)

	# Build compass strip
	_create_compass()


func _process(_delta: float) -> void:
	if _player == null:
		return

	_update_health()
	_update_heat()
	_update_fuel()
	_update_shoe_display()
	_update_inventory_display()
	_update_zone_display()
	_update_compass()
	_handle_marker_input()


func _update_health() -> void:
	if health_bar == null:
		return
	health_bar.value = _player.health
	health_bar.max_value = _player.MAX_HEALTH


func _update_heat() -> void:
	if heat_bar == null:
		return
	if _heat_system:
		heat_bar.value = _heat_system.heat_level
		heat_bar.max_value = _heat_system.max_heat
		heat_bar.visible = true
	else:
		heat_bar.visible = false

	if fever_label:
		fever_label.visible = _heat_system != null and _heat_system.is_fever

	# Time currency
	if time_currency_label and _inventory:
		time_currency_label.text = "TC: %.0f" % _inventory.time_currency


func _update_fuel() -> void:
	if fuel_label == null or _inventory == null:
		return
	fuel_label.text = "FUEL: %.0f" % _inventory.burn_fuel
	if _inventory.burn_fuel < 100.0:
		fuel_label.modulate = Color.RED
	elif _inventory.burn_fuel < 300.0:
		fuel_label.modulate = Color.YELLOW
	else:
		fuel_label.modulate = Color(1.0, 0.6, 0.2)


func _update_shoe_display() -> void:
	if shoe_slot_label == null or _inventory == null:
		return

	if _inventory.equipped_shoe == null:
		shoe_slot_label.text = "SHOES: ---"
		shoe_slot_label.modulate = Color(0.5, 0.5, 0.5, 1)
		return

	var shoe: ItemStack = _inventory.equipped_shoe
	var rarity_tag: String = RARITY_TAGS[shoe.item_data.rarity] if shoe.item_data else "?"
	var time_remaining := ceili(shoe.burn_time_remaining)
	var bonus_pct := 0.0
	var spd = shoe.item_data.get("speed_bonus") if shoe.item_data else null
	if spd != null:
		bonus_pct = spd * 100.0

	shoe_slot_label.text = "SHOES: [%s] %s - %ds (+%.0f%%)" % [
		rarity_tag, shoe.item_data.item_name, time_remaining, bonus_pct]

	if shoe.burn_time_remaining < 15.0:
		shoe_slot_label.modulate = Color.RED
	elif shoe.burn_time_remaining < 45.0:
		shoe_slot_label.modulate = Color.YELLOW
	else:
		shoe_slot_label.modulate = Color.WHITE


func _update_inventory_display() -> void:
	if _slot_labels.is_empty() or _inventory == null:
		return

	for i in SLOT_COUNT:
		var entry: Label = _slot_labels[i]
		var slot_num := i + 1
		var is_equipped: bool = (i == _inventory.equipped_index)

		if i < _inventory.items.size():
			var stack: ItemStack = _inventory.items[i]
			var time_str := "%ds" % ceili(stack.burn_time_remaining)
			var rarity_tag: String = RARITY_TAGS[stack.item_data.rarity] if stack.item_data else "?"
			var equip_marker := " <<" if is_equipped else ""
			entry.text = "[%d] [%s] %s - %s%s" % [
				slot_num, rarity_tag, stack.item_data.item_name, time_str, equip_marker]

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


func _update_zone_display() -> void:
	if _zone_label == null or _player == null:
		return
	if not has_node("/root/ZoneManager"):
		_zone_label.visible = false
		return

	var zm := get_node("/root/ZoneManager")
	if zm.zone_phase < 0:
		_zone_label.visible = false
		return

	_zone_label.visible = true

	# Check if player is outside zone
	var player_xz := Vector2(_player.global_position.x, _player.global_position.z)
	var dist_to_center := player_xz.distance_to(zm.zone_center)
	var outside: bool = dist_to_center > zm.zone_radius

	var text := ""
	if zm.is_shrinking:
		text = "ZONE SHRINKING  |  Radius: %.0fm" % zm.zone_radius
	elif zm.zone_phase < zm.ZONE_PHASES.size():
		text = "Phase %d  |  Shrinks in %.0fs  |  Zone: %.0fm" % [
			zm.zone_phase + 1, zm.next_shrink_time, zm.zone_radius]
	else:
		text = "FINAL ZONE  |  Radius: %.0fm" % zm.zone_radius

	if outside:
		var dist_outside: float = dist_to_center - zm.zone_radius
		text += "  |  OUTSIDE ZONE (%.0fm)" % dist_outside
		_zone_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.1))
	else:
		_zone_label.remove_theme_color_override("font_color")

	_zone_label.text = text


# ======================================================================
#  Compass strip — horizontal bar at top of screen
# ======================================================================

func _create_compass() -> void:
	## Build the compass UI: background strip, cardinal labels, tick marks,
	## center notch, and marker/demon indicator icons.
	_compass_container = Control.new()
	_compass_container.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_compass_container.offset_left = -COMPASS_WIDTH * 0.5
	_compass_container.offset_right = COMPASS_WIDTH * 0.5
	_compass_container.offset_top = 10.0
	_compass_container.offset_bottom = 10.0 + COMPASS_HEIGHT
	_compass_container.clip_contents = true
	_compass_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_compass_container)

	# Dark semi-transparent background
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.45)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compass_container.add_child(bg)

	# Cardinal direction labels (N, NE, E, SE, S, SW, W, NW)
	_compass_labels.clear()
	for i in CARDINALS.size():
		var lbl := Label.new()
		lbl.text = CARDINALS[i]
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# N is highlighted red, main cardinals are white, inter-cardinals are grey
		if CARDINALS[i] == "N":
			lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		elif CARDINALS[i].length() == 1:  # E, S, W
			lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		else:  # NE, SE, SW, NW
			lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		lbl.size = Vector2(30, COMPASS_HEIGHT)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_compass_container.add_child(lbl)
		_compass_labels.append(lbl)

	# Tick marks every 15° (24 ticks for 360°)
	_compass_ticks.clear()
	for i in 24:
		var tick := ColorRect.new()
		var deg: float = i * 15.0
		# Taller tick at cardinals (0, 90, 180, 270), shorter at others
		var is_cardinal := int(deg) % 90 == 0
		var tick_h := 12.0 if is_cardinal else 6.0
		tick.size = Vector2(1.0, tick_h)
		tick.color = Color(0.5, 0.5, 0.5, 0.6) if not is_cardinal else Color(0.8, 0.8, 0.8, 0.8)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_compass_container.add_child(tick)
		_compass_ticks.append(tick)

	# Center notch — thin white line at strip center
	_compass_center_mark = ColorRect.new()
	_compass_center_mark.size = Vector2(2.0, COMPASS_HEIGHT)
	_compass_center_mark.color = Color(1.0, 1.0, 1.0, 0.8)
	_compass_center_mark.position = Vector2(COMPASS_WIDTH * 0.5 - 1.0, 0.0)
	_compass_center_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compass_container.add_child(_compass_center_mark)

	# Player marker icon (cyan ▼ + distance) — hidden until MMB is pressed
	_marker_icon = Label.new()
	_marker_icon.text = "▼"
	_marker_icon.add_theme_font_size_override("font_size", 16)
	_marker_icon.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0))
	_marker_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marker_icon.size = Vector2(20, COMPASS_HEIGHT)
	_marker_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker_icon.visible = false
	_compass_container.add_child(_marker_icon)

	_marker_dist_label = Label.new()
	_marker_dist_label.add_theme_font_size_override("font_size", 11)
	_marker_dist_label.add_theme_color_override("font_color", Color(0.2, 0.9, 1.0))
	_marker_dist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marker_dist_label.size = Vector2(40, 16)
	_marker_dist_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker_dist_label.visible = false
	# Position just below the compass strip
	add_child(_marker_dist_label)

	# Demon indicator (red ▼ + distance)
	_demon_icon = Label.new()
	_demon_icon.text = "▼"
	_demon_icon.add_theme_font_size_override("font_size", 16)
	_demon_icon.add_theme_color_override("font_color", Color(1.0, 0.15, 0.1))
	_demon_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_demon_icon.size = Vector2(20, COMPASS_HEIGHT)
	_demon_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demon_icon.visible = false
	_compass_container.add_child(_demon_icon)

	_demon_dist_label = Label.new()
	_demon_dist_label.add_theme_font_size_override("font_size", 11)
	_demon_dist_label.add_theme_color_override("font_color", Color(1.0, 0.15, 0.1))
	_demon_dist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_demon_dist_label.size = Vector2(40, 16)
	_demon_dist_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_demon_dist_label.visible = false
	add_child(_demon_dist_label)


func _get_heading() -> float:
	## Player heading in degrees (0=North/+Z, 90=East/+X, clockwise).
	return fmod(-rad_to_deg(_player.rotation.y) + 360.0, 360.0)


func _bearing_to_px(bearing_deg: float, heading_deg: float) -> float:
	## Convert a world bearing to a pixel X offset within the compass strip.
	## Returns the X position relative to the compass container's left edge.
	## Values outside [0, COMPASS_WIDTH] are off-strip.
	var diff := bearing_deg - heading_deg
	diff = fmod(diff + 540.0, 360.0) - 180.0  # normalize to -180..180
	return COMPASS_WIDTH * 0.5 + diff / (COMPASS_FOV * 0.5) * (COMPASS_WIDTH * 0.5)


func _update_compass() -> void:
	if _compass_container == null or _player == null:
		return

	var heading := _get_heading()
	var half_w := COMPASS_WIDTH * 0.5

	# Position cardinal labels
	for i in _compass_labels.size():
		var px := _bearing_to_px(CARDINAL_BEARINGS[i], heading)
		var lbl: Label = _compass_labels[i]
		lbl.position = Vector2(px - lbl.size.x * 0.5, 0.0)
		lbl.visible = (px > -20.0 and px < COMPASS_WIDTH + 20.0)

	# Position tick marks (every 15°, 24 total)
	for i in _compass_ticks.size():
		var deg: float = i * 15.0
		var px := _bearing_to_px(deg, heading)
		var tick: ColorRect = _compass_ticks[i]
		tick.position = Vector2(px - tick.size.x * 0.5, COMPASS_HEIGHT - tick.size.y)
		tick.visible = (px > -5.0 and px < COMPASS_WIDTH + 5.0)

	# --- Player marker ---
	if _player_marker_pos != Vector3.INF:
		var to_marker: Vector3 = _player_marker_pos - _player.global_position
		var marker_bearing: float = fmod(rad_to_deg(atan2(to_marker.x, to_marker.z)) + 360.0, 360.0)
		var marker_dist: float = to_marker.length()
		var px := _bearing_to_px(marker_bearing, heading)

		# Clamp to edges if off-screen
		var clamped_px := clampf(px, 10.0, COMPASS_WIDTH - 10.0)
		_marker_icon.position = Vector2(clamped_px - _marker_icon.size.x * 0.5, 0.0)
		_marker_icon.visible = true
		# Show arrows at edges if clamped
		if px < 10.0:
			_marker_icon.text = "◀"
		elif px > COMPASS_WIDTH - 10.0:
			_marker_icon.text = "▶"
		else:
			_marker_icon.text = "▼"

		# Distance label below compass
		_marker_dist_label.text = "%.0fm" % marker_dist
		_marker_dist_label.visible = true
		# Position relative to parent (this Control), accounting for compass container offset
		var global_x := _compass_container.offset_left + clamped_px
		_marker_dist_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_marker_dist_label.offset_left = global_x - 20.0
		_marker_dist_label.offset_right = global_x + 20.0
		_marker_dist_label.offset_top = 10.0 + COMPASS_HEIGHT + 1.0
		_marker_dist_label.offset_bottom = 10.0 + COMPASS_HEIGHT + 17.0
	else:
		_marker_icon.visible = false
		_marker_dist_label.visible = false

	# --- Demon indicator ---
	var demon_sys: Node = _player.get_node_or_null("DemonSystem")

	if demon_sys and demon_sys.demon_active and not demon_sys.is_eliminated:
		var to_demon: Vector3 = Vector3(demon_sys.demon_position) - _player.global_position
		var demon_bearing: float = fmod(rad_to_deg(atan2(to_demon.x, to_demon.z)) + 360.0, 360.0)
		var demon_dist: float = Vector2(to_demon.x, to_demon.z).length()
		var px := _bearing_to_px(demon_bearing, heading)

		var clamped_px := clampf(px, 10.0, COMPASS_WIDTH - 10.0)
		_demon_icon.position = Vector2(clamped_px - _demon_icon.size.x * 0.5, 0.0)
		_demon_icon.visible = true
		if px < 10.0:
			_demon_icon.text = "◀"
		elif px > COMPASS_WIDTH - 10.0:
			_demon_icon.text = "▶"
		else:
			_demon_icon.text = "▼"

		# Pulse brighter when close
		var intensity := clampf(1.0 - (demon_dist - 10.0) / 40.0, 0.4, 1.0)
		_demon_icon.add_theme_color_override("font_color", Color(intensity, 0.1 * intensity, 0.08 * intensity))

		_demon_dist_label.text = "%.0fm" % demon_dist
		_demon_dist_label.visible = true
		_demon_dist_label.add_theme_color_override("font_color", Color(intensity, 0.1 * intensity, 0.08 * intensity))
		var global_x := _compass_container.offset_left + clamped_px
		_demon_dist_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_demon_dist_label.offset_left = global_x - 20.0
		_demon_dist_label.offset_right = global_x + 20.0
		_demon_dist_label.offset_top = 10.0 + COMPASS_HEIGHT + 1.0
		_demon_dist_label.offset_bottom = 10.0 + COMPASS_HEIGHT + 17.0
	else:
		_demon_icon.visible = false
		_demon_dist_label.visible = false


# ======================================================================
#  Marker placement (MMB)
# ======================================================================

func _handle_marker_input() -> void:
	## Check if player pressed MMB to place/remove a world marker.
	if _player == null:
		return
	var pi := _player.get_node_or_null("PlayerInput")
	if pi == null or pi.marker_count <= _last_marker_count:
		return
	_last_marker_count = pi.marker_count

	# Raycast from camera center forward to find terrain
	var camera: Camera3D = _player.camera
	if camera == null:
		return

	var cam_pos := camera.global_position
	var cam_forward := -camera.global_transform.basis.z
	var space_state := _player.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_forward * 200.0)
	query.collision_mask = 1  # Terrain/world only
	var result := space_state.intersect_ray(query)

	var new_pos: Vector3
	if not result.is_empty():
		new_pos = result.position
	else:
		new_pos = cam_pos + cam_forward * 200.0

	# Toggle: if marker already near the new point, remove it
	if _player_marker_pos != Vector3.INF and _player_marker_pos.distance_to(new_pos) < 10.0:
		_player_marker_pos = Vector3.INF
	else:
		_player_marker_pos = new_pos
