extends CanvasLayer

## Pause menu with graphics settings.
## Toggled by Escape key. Pauses gameplay input while open.
## Autoloaded so it works from any scene.

var is_open := false

# UI refs (created in _ready)
var _overlay: ColorRect = null
var _panel: PanelContainer = null
var _vsync_button: CheckButton = null
var _fullscreen_button: CheckButton = null
var _fov_slider: HSlider = null
var _fov_label: Label = null
var _msaa_option: OptionButton = null
var _shadow_option: OptionButton = null
var _render_scale_slider: HSlider = null
var _render_scale_label: Label = null
var _brightness_slider: HSlider = null
var _brightness_label: Label = null
var _fog_button: CheckButton = null
var _fps_label: Label = null
var _fps_timer: float = 0.0
var _ground_pump_button: CheckButton = null
var _reel_speed_input: LineEdit = null
var _grapple_debug_visuals_button: CheckButton = null

## Saved settings
var _settings := {
	"vsync": true,
	"fullscreen": true,
	"fov": 70.0,
	"msaa": 0,
	"shadow_quality": 2,
	"render_scale": 1.0,
	"brightness": 1.0,
	"fog_enabled": true,
}


func _ready() -> void:
	layer = 100  # On top of everything
	_build_ui()
	_overlay.visible = false
	# Apply default settings
	_apply_vsync(true)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Don't open pause menu on the main menu screen
		var scene := get_tree().current_scene
		if scene and scene.scene_file_path == "res://ui/main_menu.tscn" and not is_open:
			return
		_toggle_menu()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open:
		return
	_fps_timer += delta
	if _fps_timer >= 0.25:
		_fps_timer = 0.0
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()


func _toggle_menu() -> void:
	is_open = not is_open
	_overlay.visible = is_open
	if is_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _build_ui() -> void:
	# Background overlay
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.5)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# Center panel
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(500, 750)
	_panel.position = Vector2(-250, -375)
	_overlay.add_child(_panel)

	# Panel style
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.border_color = Color(0.3, 0.4, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(20)
	_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# FPS counter
	_fps_label = Label.new()
	_fps_label.text = "FPS: --"
	_fps_label.add_theme_font_size_override("font_size", 14)
	_fps_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_fps_label)

	# Separator
	vbox.add_child(HSeparator.new())

	# --- VSync ---
	_vsync_button = _add_check("V-Sync", true, vbox)
	_vsync_button.toggled.connect(_on_vsync_toggled)

	# --- Fullscreen ---
	_fullscreen_button = _add_check("Fullscreen", true, vbox)
	_fullscreen_button.toggled.connect(_on_fullscreen_toggled)

	# --- FOV ---
	var fov_row := _add_slider_row("FOV", 50.0, 120.0, 70.0, 1.0, vbox)
	_fov_slider = fov_row[0]
	_fov_label = fov_row[1]
	_fov_slider.value_changed.connect(_on_fov_changed)

	# --- Render Scale ---
	var rs_row := _add_slider_row("Render Scale", 0.5, 1.0, 1.0, 0.05, vbox)
	_render_scale_slider = rs_row[0]
	_render_scale_label = rs_row[1]
	_render_scale_slider.value_changed.connect(_on_render_scale_changed)

	# --- Brightness ---
	var br_row := _add_slider_row("Brightness", 0.5, 2.0, 1.0, 0.05, vbox)
	_brightness_slider = br_row[0]
	_brightness_label = br_row[1]
	_brightness_slider.value_changed.connect(_on_brightness_changed)

	# --- MSAA ---
	var msaa_hbox := HBoxContainer.new()
	var msaa_label := Label.new()
	msaa_label.text = "Anti-Aliasing (MSAA)"
	msaa_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	msaa_hbox.add_child(msaa_label)
	_msaa_option = OptionButton.new()
	_msaa_option.add_item("Off", 0)
	_msaa_option.add_item("2x", 1)
	_msaa_option.add_item("4x", 2)
	_msaa_option.add_item("8x", 3)
	_msaa_option.selected = 0
	_msaa_option.item_selected.connect(_on_msaa_changed)
	msaa_hbox.add_child(_msaa_option)
	vbox.add_child(msaa_hbox)

	# --- Shadow Quality ---
	var shadow_hbox := HBoxContainer.new()
	var shadow_label := Label.new()
	shadow_label.text = "Shadow Quality"
	shadow_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shadow_hbox.add_child(shadow_label)
	_shadow_option = OptionButton.new()
	_shadow_option.add_item("Off", 0)
	_shadow_option.add_item("Low", 1)
	_shadow_option.add_item("Medium", 2)
	_shadow_option.add_item("High", 3)
	_shadow_option.selected = 2
	_shadow_option.item_selected.connect(_on_shadow_changed)
	shadow_hbox.add_child(_shadow_option)
	vbox.add_child(shadow_hbox)

	# --- Fog ---
	_fog_button = _add_check("Fog", true, vbox)
	_fog_button.toggled.connect(_on_fog_toggled)

	# Separator
	vbox.add_child(HSeparator.new())

	# --- Grapple Debug ---
	var grapple_title := Label.new()
	grapple_title.text = "Grapple Debug"
	grapple_title.add_theme_font_size_override("font_size", 18)
	grapple_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	grapple_title.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	vbox.add_child(grapple_title)

	var reel_hbox := HBoxContainer.new()
	var reel_label := Label.new()
	reel_label.text = "Reel Speed"
	reel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reel_hbox.add_child(reel_label)
	_reel_speed_input = LineEdit.new()
	_reel_speed_input.text = "3.0"
	_reel_speed_input.custom_minimum_size = Vector2(80, 0)
	_reel_speed_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reel_speed_input.text_submitted.connect(_on_reel_speed_submitted)
	reel_hbox.add_child(_reel_speed_input)
	vbox.add_child(reel_hbox)

	_grapple_debug_visuals_button = _add_check("Debug Visuals (pill, angles, spheres)", false, vbox)
	_grapple_debug_visuals_button.toggled.connect(_on_grapple_debug_visuals_toggled)

	# Separator
	vbox.add_child(HSeparator.new())

	# --- Buttons ---
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)

	var resume_btn := Button.new()
	resume_btn.text = "Resume"
	resume_btn.custom_minimum_size = Vector2(120, 40)
	resume_btn.pressed.connect(_toggle_menu)
	btn_row.add_child(resume_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit to Menu"
	quit_btn.custom_minimum_size = Vector2(140, 40)
	quit_btn.pressed.connect(_on_quit_pressed)
	btn_row.add_child(quit_btn)

	vbox.add_child(btn_row)


## --- Helpers ---

func _add_check(label_text: String, default: bool, parent: Node) -> CheckButton:
	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var btn := CheckButton.new()
	btn.button_pressed = default
	hbox.add_child(btn)
	parent.add_child(hbox)
	return btn


func _add_slider_row(label_text: String, min_val: float, max_val: float, default: float, step: float, parent: Node) -> Array:
	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(130, 0)
	hbox.add_child(label)
	var slider := HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step
	slider.value = default
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(200, 0)
	hbox.add_child(slider)
	var val_label := Label.new()
	val_label.text = str(default)
	val_label.custom_minimum_size = Vector2(50, 0)
	val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hbox.add_child(val_label)
	parent.add_child(hbox)
	return [slider, val_label]


## --- Setting callbacks ---

func _on_vsync_toggled(pressed: bool) -> void:
	_apply_vsync(pressed)
	_settings["vsync"] = pressed


func _apply_vsync(enabled: bool) -> void:
	if enabled:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func _on_fullscreen_toggled(pressed: bool) -> void:
	if pressed:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_settings["fullscreen"] = pressed


func _on_fov_changed(value: float) -> void:
	_fov_label.text = "%.0f" % value
	_settings["fov"] = value
	# Apply to local player's camera
	var camera := _find_local_camera()
	if camera:
		camera.fov = value


func _on_render_scale_changed(value: float) -> void:
	_render_scale_label.text = "%.0f%%" % (value * 100.0)
	_settings["render_scale"] = value
	get_viewport().scaling_3d_scale = value


func _on_brightness_changed(value: float) -> void:
	_brightness_label.text = "%.2f" % value
	_settings["brightness"] = value
	# Apply to environment
	var env := _find_environment()
	if env:
		env.tonemap_exposure = value * 0.9  # 0.9 is our baseline


func _on_msaa_changed(index: int) -> void:
	_settings["msaa"] = index
	match index:
		0: get_viewport().msaa_3d = Viewport.MSAA_DISABLED
		1: get_viewport().msaa_3d = Viewport.MSAA_2X
		2: get_viewport().msaa_3d = Viewport.MSAA_4X
		3: get_viewport().msaa_3d = Viewport.MSAA_8X


func _on_shadow_changed(index: int) -> void:
	_settings["shadow_quality"] = index
	# Find the sun directional light and adjust quality
	var sun := _find_sun()
	if sun == null:
		return
	match index:
		0:
			sun.shadow_enabled = false
		1:
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 80.0
			RenderingServer.directional_shadow_atlas_set_size(1024, true)
		2:
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 200.0
			RenderingServer.directional_shadow_atlas_set_size(2048, true)
		3:
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 400.0
			RenderingServer.directional_shadow_atlas_set_size(4096, true)


func _on_fog_toggled(pressed: bool) -> void:
	_settings["fog_enabled"] = pressed
	var env := _find_environment()
	if env:
		env.fog_enabled = pressed


func _on_reel_speed_submitted(text: String) -> void:
	var val := text.to_float()
	if val > 0.0 and val <= 50.0:
		GameManager.debug_grapple_reel_speed = val
		print("[PauseMenu] Grapple reel speed set to %.1f" % val)
	else:
		_reel_speed_input.text = "%.1f" % GameManager.debug_grapple_reel_speed


func _on_grapple_debug_visuals_toggled(pressed: bool) -> void:
	GameManager.debug_grapple_visuals = pressed
	print("[PauseMenu] Grapple debug visuals: %s" % ("ON" if pressed else "OFF"))


func _on_quit_pressed() -> void:
	_toggle_menu()
	NetworkManager.disconnect_game()


## --- Scene lookups ---

func _find_local_camera() -> Camera3D:
	var vp := get_viewport()
	if vp:
		return vp.get_camera_3d()
	return null


func _find_sun() -> DirectionalLight3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	# SeedWorld adds the Sun as a child
	var seed_world := scene.get_node_or_null("SeedWorld")
	if seed_world:
		for child in seed_world.get_children():
			if child is DirectionalLight3D:
				return child
	# Fallback: search root
	for child in scene.get_children():
		if child is DirectionalLight3D:
			return child
	return null


func _find_environment() -> Environment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var world_env := scene.get_node_or_null("WorldEnvironment")
	if world_env and world_env is WorldEnvironment:
		return world_env.environment
	# Search parent too
	for child in scene.get_children():
		if child is WorldEnvironment:
			return child.environment
	return null
