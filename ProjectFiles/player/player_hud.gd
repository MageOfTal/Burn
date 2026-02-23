extends Control

## Player HUD: displays health, heat, equipment slot boxes along the bottom,
## time currency, compass strip with markers, zone info, kill feed, forfeit ring,
## demon vignette, victory screen, and FPS counter.
## Only active for the local player.
##
## Bottom bar layout:
##   [0: Shoe] ---- gap ---- [1] [2] [3] [4] [5] [6]
##   Selected slot gets a dark border outline.
##
## Composite widgets are extracted into player/hud/ scripts:
##   HUDCompass, HUDKillFeed, HUDForfeitRing, HUDDemonVignette, HUDVictoryScreen

@onready var health_bar: ProgressBar = $MarginContainer/VBoxLeft/HealthBar
@onready var heat_bar: ProgressBar = $MarginContainer/VBoxLeft/HeatBar
@onready var time_currency_label: Label = $MarginContainer/VBoxLeft/TimeCurrencyLabel
@onready var kill_currency_label: Label = $MarginContainer/VBoxLeft/KillCurrencyLabel
@onready var fuel_label: Label = $MarginContainer/VBoxLeft/FuelLabel
@onready var fever_label: Label = $FeverLabel
@onready var ip_label: Label = $IPLabel

var _player: Player = null

## Cached subsystem references (resolved once in setup, not every frame)
var _heat_system: Node = null
var _inventory: Node = null

const SLOT_COUNT := 6
const RARITY_TAGS := ["C", "U", "R", "E", "L"]

## Bottom bar slot boxes
var _slot_boxes: Array[PanelContainer] = []  ## Indices 0-5 for weapon slots 1-6
var _slot_box_labels: Array[Label] = []
var _shoe_box: PanelContainer = null
var _shoe_box_label: Label = null
var _hint_label: Label = null  ## Keybind hints above the bottom bar

## Shared style resources (created once, reused)
var _style_normal: StyleBoxFlat = null
var _style_selected: StyleBoxFlat = null
var _style_empty: StyleBoxFlat = null

const BOX_WIDTH := 130
const BOX_HEIGHT := 48
const BOX_GAP := 4       ## Gap between weapon slot boxes
const SHOE_GAP := 20     ## Gap between shoe box and weapon boxes
const BOX_FONT_SIZE := 11
const BOTTOM_MARGIN := 15

## Zone info label (created in code, shown at bottom center)
var _zone_label: Label = null

## FPS counter (top-left corner)
var _fps_hud_label: Label = null
var _fps_hud_timer: float = 0.0
var _physics_tick_count: int = 0
var _physics_tps: int = 0

## Wall-clock TPS measurement — uses monotonic Time.get_ticks_msec() so it's
## independent of both _process delta and _physics_process delta.  This catches
## physics falling behind real time (e.g. max_physics_steps_per_frame cap).
var _wallclock_last_ms: int = 0         ## Time.get_ticks_msec() at last TPS reset
var _wallclock_tick_count: int = 0      ## physics ticks since last reset
var _wallclock_tps: int = 0             ## TPS derived from wall-clock elapsed

## FPS throttle — cycle through caps with F9/F10
const FPS_CAPS := [0, 120, 60, 30, 15, 10, 5]  ## 0 = unlimited
var _fps_cap_index: int = 0
var _f9_was_pressed: bool = false

## Extracted widgets
var _compass: HUDCompass = null
var _kill_feed: HUDKillFeed = null
var _forfeit_ring: HUDForfeitRing = null
var _demon_vignette: HUDDemonVignette = null
var _zone_vignette: HUDZoneVignette = null
var _victory_screen: HUDVictoryScreen = null


func setup(player: Player) -> void:
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

	# --- Create shared box styles ---
	_style_normal = StyleBoxFlat.new()
	_style_normal.bg_color = Color(0.1, 0.1, 0.1, 0.25)
	_style_normal.border_color = Color(0.3, 0.3, 0.3, 0.4)
	_style_normal.set_border_width_all(1)
	_style_normal.set_corner_radius_all(4)
	_style_normal.set_content_margin_all(4)

	_style_selected = StyleBoxFlat.new()
	_style_selected.bg_color = Color(0.1, 0.1, 0.1, 0.3)
	_style_selected.border_color = Color(0.9, 0.9, 0.9, 1.0)
	_style_selected.set_border_width_all(2)
	_style_selected.set_corner_radius_all(4)
	_style_selected.set_content_margin_all(4)

	_style_empty = StyleBoxFlat.new()
	_style_empty.bg_color = Color(0.05, 0.05, 0.05, 0.15)
	_style_empty.border_color = Color(0.2, 0.2, 0.2, 0.3)
	_style_empty.set_border_width_all(1)
	_style_empty.set_corner_radius_all(4)
	_style_empty.set_content_margin_all(4)

	# --- Build bottom bar ---
	_build_bottom_bar()

	# Create zone info label at bottom center (above the slot bar)
	_zone_label = Label.new()
	_zone_label.add_theme_font_size_override("font_size", 16)
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_zone_label.offset_top = -(BOTTOM_MARGIN + BOX_HEIGHT + 30)
	_zone_label.offset_bottom = -(BOTTOM_MARGIN + BOX_HEIGHT + 10)
	_zone_label.offset_left = -250
	_zone_label.offset_right = 250
	add_child(_zone_label)

	# --- Extracted widgets ---

	# Zone vignette (red haze when outside fire circle — behind everything)
	_zone_vignette = HUDZoneVignette.new()
	_zone_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_zone_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_zone_vignette)
	move_child(_zone_vignette, 0)
	_zone_vignette.setup(player)

	# Demon vignette (added early so it renders behind most HUD elements)
	_demon_vignette = HUDDemonVignette.new()
	_demon_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_demon_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_demon_vignette)
	move_child(_demon_vignette, 1)
	_demon_vignette.setup(player)

	# Compass strip
	_compass = HUDCompass.new()
	_compass.set_anchors_preset(Control.PRESET_FULL_RECT)
	_compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_compass)
	_compass.setup(player)

	# Kill feed
	_kill_feed = HUDKillFeed.new()
	_kill_feed.set_anchors_preset(Control.PRESET_FULL_RECT)
	_kill_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_kill_feed)
	_kill_feed.setup(player)

	# Forfeit ring
	_forfeit_ring = HUDForfeitRing.new()
	_forfeit_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	_forfeit_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_forfeit_ring)
	_forfeit_ring.setup(player)

	# Victory screen (builds on demand when show_victory_screen is called)
	_victory_screen = HUDVictoryScreen.new()
	_victory_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_victory_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_victory_screen)

	# FPS counter (top-left corner)
	_fps_hud_label = Label.new()
	_fps_hud_label.text = ""
	_fps_hud_label.add_theme_font_size_override("font_size", 14)
	_fps_hud_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_fps_hud_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_fps_hud_label.offset_left = 10
	_fps_hud_label.offset_top = 10
	_fps_hud_label.offset_right = 350
	_fps_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fps_hud_label.visible = GameManager.show_fps_hud
	add_child(_fps_hud_label)


func _build_bottom_bar() -> void:
	## Build the bottom bar: shoe box on the left, 6 weapon boxes to the right.
	## All positioned manually at the bottom-center of the screen.

	# Total width: shoe_box + shoe_gap + 6 * box_width + 5 * box_gap
	var weapon_bar_width: float = SLOT_COUNT * BOX_WIDTH + (SLOT_COUNT - 1) * BOX_GAP
	var total_width: float = BOX_WIDTH + SHOE_GAP + weapon_bar_width
	var start_x: float = -total_width / 2.0

	# --- Shoe box (slot 0, left side) ---
	_shoe_box = _create_slot_box()
	_shoe_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_shoe_box.offset_left = start_x
	_shoe_box.offset_right = start_x + BOX_WIDTH
	_shoe_box.offset_top = -(BOTTOM_MARGIN + BOX_HEIGHT)
	_shoe_box.offset_bottom = -BOTTOM_MARGIN
	add_child(_shoe_box)
	_shoe_box_label = _shoe_box.get_child(0) as Label

	# --- Weapon boxes (slots 1-6) ---
	var weapon_start_x: float = start_x + BOX_WIDTH + SHOE_GAP
	_slot_boxes.clear()
	_slot_box_labels.clear()
	for i in SLOT_COUNT:
		var box := _create_slot_box()
		box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		var x_offset: float = weapon_start_x + i * (BOX_WIDTH + BOX_GAP)
		box.offset_left = x_offset
		box.offset_right = x_offset + BOX_WIDTH
		box.offset_top = -(BOTTOM_MARGIN + BOX_HEIGHT)
		box.offset_bottom = -BOTTOM_MARGIN
		add_child(box)
		_slot_boxes.append(box)
		_slot_box_labels.append(box.get_child(0) as Label)

	# --- Keybind hint label (centered above the bottom bar) ---
	_hint_label = Label.new()
	_hint_label.text = "E: pickup  |  F: extend  |  X: scrap ground  |  O: scrap equipped  |  TAB: inventory"
	_hint_label.add_theme_font_size_override("font_size", 11)
	_hint_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 0.7))
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint_label.offset_left = -total_width / 2.0
	_hint_label.offset_right = total_width / 2.0
	_hint_label.offset_top = -(BOTTOM_MARGIN + BOX_HEIGHT + 18)
	_hint_label.offset_bottom = -(BOTTOM_MARGIN + BOX_HEIGHT + 2)
	add_child(_hint_label)


func _create_slot_box() -> PanelContainer:
	## Creates a single slot box (PanelContainer with a Label child).
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(BOX_WIDTH, BOX_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", _style_empty)

	var label := Label.new()
	label.add_theme_font_size_override("font_size", BOX_FONT_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label)

	return panel


func _physics_process(_delta: float) -> void:
	_physics_tick_count += 1
	_wallclock_tick_count += 1

	# Wall-clock TPS: compare ticks against monotonic clock, not _process delta
	var now_ms: int = Time.get_ticks_msec()
	if _wallclock_last_ms == 0:
		_wallclock_last_ms = now_ms  # First tick — seed the clock
	var wall_elapsed_ms: int = now_ms - _wallclock_last_ms
	if wall_elapsed_ms >= 1000:
		_wallclock_tps = roundi(float(_wallclock_tick_count) / (float(wall_elapsed_ms) / 1000.0))
		_wallclock_tick_count = 0
		_wallclock_last_ms = now_ms

	# Compass marker raycast must run in physics tick (threaded physics safety).
	if _compass:
		_compass.physics_process_marker()


func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return

	_update_health()
	_update_heat()
	_update_fuel()
	_update_kill_currency()
	_update_bottom_bar()
	_update_zone_display()
	_update_fps_hud(delta)

	# Delegate to widgets
	if _compass:
		_compass.update_compass()
	if _forfeit_ring:
		_forfeit_ring.update_forfeit_ring()
	if _zone_vignette:
		_zone_vignette.update_zone_vignette()
	if _demon_vignette:
		_demon_vignette.update_demon_vignette()


# ======================================================================
#  Public API — called by external systems (NetworkManager RPCs)
# ======================================================================

func add_kill_feed_entry(bbcode_text: String) -> void:
	## Called by NetworkManager RPC to add a kill feed entry.
	if _kill_feed:
		_kill_feed.add_kill_feed_entry(bbcode_text)


func show_victory_screen(winner_id: int, winner_name: String, my_id: int) -> void:
	## Called by NetworkManager RPC to display the victory overlay.
	if _victory_screen:
		_victory_screen.show_victory_screen(winner_id, winner_name, my_id)


# ======================================================================
#  Core HUD updates (health, heat, fuel, bottom bar, zone)
# ======================================================================

func _update_health() -> void:
	if health_bar == null:
		return
	health_bar.value = _player.health
	if _player.has_method("get_max_health"):
		health_bar.max_value = _player.get_max_health()
	else:
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


func _update_kill_currency() -> void:
	if kill_currency_label == null or _inventory == null:
		return
	var tokens: float = _inventory.kill_currency
	if tokens == floorf(tokens):
		kill_currency_label.text = "KILLS: %d" % int(tokens)
	else:
		kill_currency_label.text = "KILLS: %s" % str(snapped(tokens, 0.01)).rstrip("0")
	if tokens >= 5.0:
		kill_currency_label.modulate = Color(1.0, 0.85, 0.1)  # Gold
	elif tokens >= 1.0:
		kill_currency_label.modulate = Color(0.9, 0.15, 0.15)  # Crimson
	else:
		kill_currency_label.modulate = Color(0.5, 0.5, 0.5)  # Gray


func _update_bottom_bar() -> void:
	## Update all slot boxes in the bottom bar (shoe + 6 weapon slots).
	if _inventory == null:
		return

	# --- Shoe box ---
	if _shoe_box and _shoe_box_label:
		var shoe_selected: bool = _inventory.shoe_selected
		if _inventory.equipped_shoe != null and _inventory.equipped_shoe.item_data != null:
			var shoe: ItemStack = _inventory.equipped_shoe
			var rarity_tag: String = RARITY_TAGS[shoe.item_data.rarity] if shoe.item_data else "?"
			var time_remaining := ceili(shoe.burn_time_remaining)
			var bonus_pct := 0.0
			var spd = shoe.item_data.get("speed_bonus") if shoe.item_data else null
			if spd != null:
				bonus_pct = spd * 100.0
			_shoe_box_label.text = "0: [%s] %s\n%ds (+%.0f%%)" % [
				rarity_tag, shoe.item_data.item_name, time_remaining, bonus_pct]

			# Color by burn time
			if shoe.burn_time_remaining < 15.0:
				_shoe_box_label.modulate = Color.RED
			elif shoe.burn_time_remaining < 45.0:
				_shoe_box_label.modulate = Color.YELLOW
			else:
				_shoe_box_label.modulate = Color.WHITE

			_shoe_box.add_theme_stylebox_override("panel", _style_selected if shoe_selected else _style_normal)
		else:
			_shoe_box_label.text = "0: ---"
			_shoe_box_label.modulate = Color(0.4, 0.4, 0.4, 1)
			_shoe_box.add_theme_stylebox_override("panel", _style_selected if shoe_selected else _style_empty)

	# --- Weapon slot boxes (1-6) ---
	for i in SLOT_COUNT:
		if i >= _slot_boxes.size():
			break
		var box: PanelContainer = _slot_boxes[i]
		var label: Label = _slot_box_labels[i]
		var slot_num := i + 1
		var is_equipped: bool = (i == _inventory.equipped_index) and not _inventory.shoe_selected

		if i < _inventory.items.size() and _inventory.items[i] != null:
			var stack: ItemStack = _inventory.items[i]
			var time_str := "%ds" % ceili(stack.burn_time_remaining)
			var rarity_tag: String = RARITY_TAGS[stack.item_data.rarity] if stack.item_data else "?"
			label.text = "%d: [%s] %s\n%s" % [
				slot_num, rarity_tag, stack.item_data.item_name, time_str]

			if is_equipped:
				label.modulate = Color.CYAN
			elif stack.burn_time_remaining < 15.0:
				label.modulate = Color.RED
			elif stack.burn_time_remaining < 45.0:
				label.modulate = Color.YELLOW
			else:
				label.modulate = Color.WHITE

			box.add_theme_stylebox_override("panel", _style_selected if is_equipped else _style_normal)
		else:
			label.text = "%d: ---" % slot_num
			label.modulate = Color(0.4, 0.4, 0.4, 1)
			box.add_theme_stylebox_override("panel", _style_empty)


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
#  FPS HUD
# ======================================================================

func _update_fps_hud(delta: float) -> void:
	# Handle FPS throttle input (works even when HUD is hidden)
	var f9_pressed: bool = Input.is_key_pressed(KEY_F9)
	if f9_pressed and not _f9_was_pressed:
		_fps_cap_index = (_fps_cap_index + 1) % FPS_CAPS.size()
		Engine.max_fps = FPS_CAPS[_fps_cap_index]
		print("[HUD] FPS cap: %s" % ("unlimited" if FPS_CAPS[_fps_cap_index] == 0 else str(FPS_CAPS[_fps_cap_index])))
	_f9_was_pressed = f9_pressed

	if _fps_hud_label == null:
		return
	_fps_hud_label.visible = GameManager.show_fps_hud
	if not _fps_hud_label.visible:
		return
	_fps_hud_timer += delta
	if _fps_hud_timer >= 1.0:
		# Scale tick count to exactly 1 second to compensate for timer overshoot
		var elapsed: float = _fps_hud_timer
		_physics_tps = roundi(float(_physics_tick_count) / elapsed)
		_physics_tick_count = 0
		_fps_hud_timer = 0.0  # Hard reset — carry-remainder drifts under heavy load

	var cap_str: String = "" if _fps_cap_index == 0 else " | CAP: %d" % FPS_CAPS[_fps_cap_index]
	_fps_hud_label.text = "FPS: %d | TPS: %d/%d%s" % [
		Engine.get_frames_per_second(),
		_wallclock_tps,
		Engine.physics_ticks_per_second,
		cap_str]
