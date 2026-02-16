extends Control
class_name HUDCompass

## Compass strip widget — horizontal bar at top of screen showing cardinal
## directions, tick marks, a player-placed marker, and a demon indicator.

const COMPASS_WIDTH := 600.0
const COMPASS_HEIGHT := 28.0
const COMPASS_FOV := 180.0  ## Degrees visible across the strip width
const CARDINALS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const CARDINAL_BEARINGS := [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]

var _player: CharacterBody3D = null

var _compass_container: Control = null
var _compass_labels: Array[Label] = []
var _compass_ticks: Array[ColorRect] = []
var _compass_center_mark: ColorRect = null

## Player-placed world marker (MMB)
var _player_marker_pos: Vector3 = Vector3.INF
var _marker_icon: Label = null
var _marker_dist_label: Label = null
var _last_marker_count := 0
var _marker_raycast_pending := false  ## Set true in _process, consumed in _physics_process

## Demon indicator on compass
var _demon_icon: Label = null
var _demon_dist_label: Label = null


func setup(player: CharacterBody3D) -> void:
	_player = player
	_build_compass()


func _build_compass() -> void:
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
		if CARDINALS[i] == "N":
			lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
		elif CARDINALS[i].length() == 1:
			lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		else:
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
	# Position just below the compass strip — added to parent (HUD root), not compass container
	get_parent().add_child(_marker_dist_label)

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
	get_parent().add_child(_demon_dist_label)


func update_compass() -> void:
	if _compass_container == null or _player == null:
		return

	_handle_marker_input()

	var heading := _get_heading()

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

	_update_player_marker(heading)
	_update_demon_indicator(heading)


func _get_heading() -> float:
	return fmod(-rad_to_deg(_player.rotation.y) + 360.0, 360.0)


func _bearing_to_px(bearing_deg: float, heading_deg: float) -> float:
	var diff := bearing_deg - heading_deg
	diff = fmod(diff + 540.0, 360.0) - 180.0
	return COMPASS_WIDTH * 0.5 + diff / (COMPASS_FOV * 0.5) * (COMPASS_WIDTH * 0.5)


func _update_player_marker(heading: float) -> void:
	if _player_marker_pos != Vector3.INF:
		var to_marker: Vector3 = _player_marker_pos - _player.global_position
		var marker_bearing: float = fmod(rad_to_deg(atan2(to_marker.x, to_marker.z)) + 360.0, 360.0)
		var marker_dist: float = to_marker.length()
		var px := _bearing_to_px(marker_bearing, heading)

		var clamped_px := clampf(px, 10.0, COMPASS_WIDTH - 10.0)
		_marker_icon.position = Vector2(clamped_px - _marker_icon.size.x * 0.5, 0.0)
		_marker_icon.visible = true
		if px < 10.0:
			_marker_icon.text = "◀"
		elif px > COMPASS_WIDTH - 10.0:
			_marker_icon.text = "▶"
		else:
			_marker_icon.text = "▼"

		_marker_dist_label.text = "%.0fm" % marker_dist
		_marker_dist_label.visible = true
		var global_x := _compass_container.offset_left + clamped_px
		_marker_dist_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_marker_dist_label.offset_left = global_x - 20.0
		_marker_dist_label.offset_right = global_x + 20.0
		_marker_dist_label.offset_top = 10.0 + COMPASS_HEIGHT + 1.0
		_marker_dist_label.offset_bottom = 10.0 + COMPASS_HEIGHT + 17.0
	else:
		_marker_icon.visible = false
		_marker_dist_label.visible = false


func _update_demon_indicator(heading: float) -> void:
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


func _handle_marker_input() -> void:
	## Detect marker input press. The actual raycast is deferred to
	## physics_process_marker() because physics queries are unsafe outside
	## the physics tick when threaded physics is enabled.
	if _player == null:
		return
	var pi := _player.get_node_or_null("PlayerInput")
	if pi == null or pi.marker_count <= _last_marker_count:
		return
	_last_marker_count = pi.marker_count
	_marker_raycast_pending = true


func physics_process_marker() -> void:
	## Called from player_hud._physics_process() — runs the marker placement
	## raycast safely inside the physics tick.
	if not _marker_raycast_pending:
		return
	_marker_raycast_pending = false

	if _player == null:
		return
	var camera: Camera3D = _player.camera
	if camera == null:
		return

	var cam_pos := camera.global_position
	var cam_forward := -camera.global_transform.basis.z
	var space_state := _player.get_world_3d().direct_space_state
	if space_state == null:
		return
	var query := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_forward * 200.0)
	query.collision_mask = 1
	var result := space_state.intersect_ray(query)

	var new_pos: Vector3
	if not result.is_empty():
		new_pos = result.position
	else:
		new_pos = cam_pos + cam_forward * 200.0

	if _player_marker_pos != Vector3.INF and _player_marker_pos.distance_to(new_pos) < 10.0:
		_player_marker_pos = Vector3.INF
	else:
		_player_marker_pos = new_pos
