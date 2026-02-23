extends CanvasLayer

## Pause menu with debug toggles and a dedicated Video Settings sub-page.
## Toggled by Escape key. Pauses gameplay input while open.
## Autoloaded so it works from any scene.
##
## Graphics/video settings are delegated to the VideoSettings autoload.
## This script handles only the UI construction and signal wiring.

var is_open := false

# ── Main panel UI refs ───────────────────────────────────────────────────
var _overlay: ColorRect = null
var _main_panel: PanelContainer = null
var _fps_label: Label = null
var _fps_timer: float = 0.0
var _reel_speed_input: LineEdit = null
var _grapple_debug_visuals_button: CheckButton = null
var _grapple_horiz_nudge_button: CheckButton = null
var _velocity_iter_slider: HSlider = null
var _velocity_iter_label: Label = null
var _mass_pin_button: CheckButton = null
var _toad_density_input: LineEdit = null
var _toad_fog_density_input: LineEdit = null
var _toad_mass_input: LineEdit = null
var _toad_no_physics_button: CheckButton = null
var _toad_no_shadows_button: CheckButton = null
var _toad_show_hitboxes_button: CheckButton = null
var _quit_btn: Button = null
var _box_mass_input: LineEdit = null

# ── Video Settings panel UI refs ─────────────────────────────────────────
var _video_panel: PanelContainer = null
var _video_fps_label: Label = null
var _vsync_button: CheckButton = null
var _fullscreen_button: CheckButton = null
var _fov_slider: HSlider = null
var _fov_label: Label = null
var _render_scale_slider: HSlider = null
var _render_scale_label: Label = null
var _brightness_slider: HSlider = null
var _brightness_label: Label = null
var _msaa_option: OptionButton = null
var _fxaa_button: CheckButton = null
var _taa_button: CheckButton = null
var _shadow_option: OptionButton = null
var _shadow_filter_option: OptionButton = null
var _ssao_button: CheckButton = null
var _ssao_quality_option: OptionButton = null
var _ssil_button: CheckButton = null
var _ssil_quality_option: OptionButton = null
var _ssr_button: CheckButton = null
var _ssr_quality_option: OptionButton = null
var _glow_button: CheckButton = null
var _glow_slider: HSlider = null
var _glow_label: Label = null
var _gi_option: OptionButton = null
var _fog_button: CheckButton = null
var _volumetric_fog_button: CheckButton = null
var _fps_hud_button: CheckButton = null


func _ready() -> void:
	layer = 100  # On top of everything
	_build_main_panel()
	_build_video_panel()
	_overlay.visible = false


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		# Don't open pause menu on the main menu screen or in the lobby
		var scene := get_tree().current_scene
		if scene and scene.scene_file_path == "res://ui/main_menu.tscn" and not is_open:
			return
		if GameManager.current_state == GameManager.GameState.LOBBY and not is_open:
			return
		_toggle_menu()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not is_open:
		return
	_fps_timer += delta
	if _fps_timer >= 0.25:
		_fps_timer = 0.0
		var fps_text := "FPS: %d" % Engine.get_frames_per_second()
		_fps_label.text = fps_text
		if _video_fps_label:
			_video_fps_label.text = fps_text


func _toggle_menu() -> void:
	is_open = not is_open
	_overlay.visible = is_open
	if is_open:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_update_quit_button()
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Save settings when closing menu (batch save)
		VideoSettings.save_settings()
		# Always return to main panel when closing
		_main_panel.visible = true
		_video_panel.visible = false


# ══════════════════════════════════════════════════════════════════════════
# MAIN PANEL (debug toggles + video settings button)
# ══════════════════════════════════════════════════════════════════════════

func _build_main_panel() -> void:
	# Background overlay
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.5)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	# Center panel — shorter now without graphics settings
	_main_panel = PanelContainer.new()
	_main_panel.set_anchors_preset(Control.PRESET_CENTER)
	_main_panel.custom_minimum_size = Vector2(500, 900)
	_main_panel.position = Vector2(-250, -450)
	_overlay.add_child(_main_panel)

	_main_panel.add_theme_stylebox_override("panel", _make_panel_style())

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_main_panel.add_child(vbox)

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

	# --- Video Settings button ---
	var video_btn := Button.new()
	video_btn.text = "Video Settings"
	video_btn.custom_minimum_size = Vector2(0, 40)
	video_btn.pressed.connect(_on_video_settings_pressed)
	vbox.add_child(video_btn)

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
	_reel_speed_input.text = "%.1f" % GameManager.debug_grapple_reel_speed
	_reel_speed_input.custom_minimum_size = Vector2(80, 0)
	_reel_speed_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reel_speed_input.text_submitted.connect(_on_reel_speed_submitted)
	reel_hbox.add_child(_reel_speed_input)
	vbox.add_child(reel_hbox)

	_grapple_debug_visuals_button = _add_check("Debug Visuals (pill, angles, spheres)", false, vbox)
	_grapple_debug_visuals_button.toggled.connect(_on_grapple_debug_visuals_toggled)

	_grapple_horiz_nudge_button = _add_check("Launch Nudge: Include Horizontal", true, vbox)
	_grapple_horiz_nudge_button.toggled.connect(_on_grapple_horiz_nudge_toggled)

	# Separator
	vbox.add_child(HSeparator.new())

	# --- Physics Debug ---
	var phys_title := Label.new()
	phys_title.text = "Physics Debug"
	phys_title.add_theme_font_size_override("font_size", 18)
	phys_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	phys_title.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	vbox.add_child(phys_title)

	var vi_row := _add_slider_row("Velocity Iters", 1.0, 20.0, 10.0, 1.0, vbox)
	_velocity_iter_slider = vi_row[0]
	_velocity_iter_label = vi_row[1]
	_velocity_iter_slider.value_changed.connect(_on_velocity_iter_changed)

	_mass_pin_button = _add_check("Disable Mass-Ratio Pin", false, vbox)
	_mass_pin_button.toggled.connect(_on_mass_pin_toggled)

	# Separator
	vbox.add_child(HSeparator.new())

	# --- Toad Dimension ---
	var toad_title := Label.new()
	toad_title.text = "Toad Dimension"
	toad_title.add_theme_font_size_override("font_size", 18)
	toad_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toad_title.add_theme_color_override("font_color", Color(0.3, 0.8, 0.3))
	vbox.add_child(toad_title)

	var toad_hbox := HBoxContainer.new()
	var toad_label := Label.new()
	toad_label.text = "Rain Density (toads/tick)"
	toad_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toad_hbox.add_child(toad_label)
	_toad_density_input = LineEdit.new()
	_toad_density_input.custom_minimum_size = Vector2(80, 0)
	_toad_density_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toad_density_input.text_submitted.connect(_on_toad_density_submitted)
	_toad_density_input.focus_exited.connect(_on_toad_density_focus_lost)
	toad_hbox.add_child(_toad_density_input)
	vbox.add_child(toad_hbox)
	_refresh_toad_density_text()

	var fog_hbox := HBoxContainer.new()
	var fog_label := Label.new()
	fog_label.text = "Fog Density"
	fog_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fog_hbox.add_child(fog_label)
	_toad_fog_density_input = LineEdit.new()
	_toad_fog_density_input.custom_minimum_size = Vector2(80, 0)
	_toad_fog_density_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toad_fog_density_input.text_submitted.connect(_on_toad_fog_density_submitted)
	_toad_fog_density_input.focus_exited.connect(_on_toad_fog_density_focus_lost)
	fog_hbox.add_child(_toad_fog_density_input)
	vbox.add_child(fog_hbox)
	_refresh_toad_fog_density_text()

	var mass_hbox := HBoxContainer.new()
	var mass_label := Label.new()
	mass_label.text = "Toad Mass (kg)"
	mass_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mass_hbox.add_child(mass_label)
	_toad_mass_input = LineEdit.new()
	_toad_mass_input.custom_minimum_size = Vector2(80, 0)
	_toad_mass_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toad_mass_input.text = "%.1f" % GameManager.debug_toad_mass
	_toad_mass_input.text_submitted.connect(_on_toad_mass_submitted)
	_toad_mass_input.focus_exited.connect(_on_toad_mass_focus_lost)
	mass_hbox.add_child(_toad_mass_input)
	vbox.add_child(mass_hbox)

	_toad_no_physics_button = _add_check("Disable Toad Physics", GameManager.debug_toad_no_physics, vbox)
	_toad_no_physics_button.toggled.connect(_on_toad_no_physics_toggled)

	_toad_no_shadows_button = _add_check("Disable Toad Shadows", GameManager.debug_toad_no_shadows, vbox)
	_toad_no_shadows_button.toggled.connect(_on_toad_no_shadows_toggled)

	_toad_show_hitboxes_button = _add_check("Show Toad Hitboxes", GameManager.debug_toad_show_hitboxes, vbox)
	_toad_show_hitboxes_button.toggled.connect(_on_toad_show_hitboxes_toggled)

	# Separator
	vbox.add_child(HSeparator.new())

	# ── Debug Push Box ──────────────────────────────────────────────────
	_add_section_header("Debug Push Box", vbox)

	var box_mass_hbox := HBoxContainer.new()
	box_mass_hbox.add_theme_constant_override("separation", 8)
	var box_mass_label := Label.new()
	box_mass_label.text = "Box Mass (kg)"
	box_mass_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box_mass_hbox.add_child(box_mass_label)
	_box_mass_input = LineEdit.new()
	_box_mass_input.custom_minimum_size = Vector2(80, 0)
	_box_mass_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_box_mass_input.text = "4.0"
	var box_node := get_tree().current_scene.get_node_or_null("DebugPushBox") if get_tree().current_scene else null
	if box_node is RigidBody3D:
		_box_mass_input.text = "%.1f" % box_node.mass
	_box_mass_input.text_submitted.connect(_on_box_mass_submitted)
	_box_mass_input.focus_exited.connect(_on_box_mass_focus_lost)
	box_mass_hbox.add_child(_box_mass_input)
	vbox.add_child(box_mass_hbox)

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

	_quit_btn = Button.new()
	_quit_btn.text = "Quit to Menu"
	_quit_btn.custom_minimum_size = Vector2(140, 40)
	_quit_btn.pressed.connect(_on_quit_pressed)
	btn_row.add_child(_quit_btn)

	vbox.add_child(btn_row)


# ══════════════════════════════════════════════════════════════════════════
# VIDEO SETTINGS PANEL
# ══════════════════════════════════════════════════════════════════════════

func _build_video_panel() -> void:
	_video_panel = PanelContainer.new()
	_video_panel.set_anchors_preset(Control.PRESET_CENTER)
	_video_panel.custom_minimum_size = Vector2(550, 800)
	_video_panel.position = Vector2(-275, -400)
	_video_panel.visible = false
	_overlay.add_child(_video_panel)

	_video_panel.add_theme_stylebox_override("panel", _make_panel_style())

	# ScrollContainer so the long list of settings can scroll
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_video_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "VIDEO SETTINGS"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# FPS counter
	_video_fps_label = Label.new()
	_video_fps_label.text = "FPS: --"
	_video_fps_label.add_theme_font_size_override("font_size", 14)
	_video_fps_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_video_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_video_fps_label)

	vbox.add_child(HSeparator.new())

	# ── Presets ──────────────────────────────────────────────────────────
	var preset_label := Label.new()
	preset_label.text = "Quality Presets"
	preset_label.add_theme_font_size_override("font_size", 16)
	preset_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(preset_label)

	var preset_row := HBoxContainer.new()
	preset_row.alignment = BoxContainer.ALIGNMENT_CENTER
	preset_row.add_theme_constant_override("separation", 8)
	for preset_name in ["Low", "Medium", "High", "Ultra"]:
		var btn := Button.new()
		btn.text = preset_name
		btn.custom_minimum_size = Vector2(90, 32)
		btn.pressed.connect(_on_preset_pressed.bind(preset_name.to_lower()))
		preset_row.add_child(btn)
	vbox.add_child(preset_row)

	vbox.add_child(HSeparator.new())

	# ── Display ──────────────────────────────────────────────────────────
	_add_section_header("Display", vbox)

	_vsync_button = _add_check("V-Sync", VideoSettings.settings["vsync"], vbox)
	_vsync_button.toggled.connect(_on_vsync_toggled)

	_fullscreen_button = _add_check("Fullscreen", VideoSettings.settings["fullscreen"], vbox)
	_fullscreen_button.toggled.connect(_on_fullscreen_toggled)

	var fov_row := _add_slider_row("FOV", 50.0, 120.0, VideoSettings.settings["fov"], 1.0, vbox)
	_fov_slider = fov_row[0]
	_fov_label = fov_row[1]
	_fov_label.text = "%.0f" % VideoSettings.settings["fov"]
	_fov_slider.value_changed.connect(_on_fov_changed)

	var rs_row := _add_slider_row("Render Scale", 0.5, 1.0, VideoSettings.settings["render_scale"], 0.05, vbox)
	_render_scale_slider = rs_row[0]
	_render_scale_label = rs_row[1]
	_render_scale_label.text = "%.0f%%" % (VideoSettings.settings["render_scale"] * 100.0)
	_render_scale_slider.value_changed.connect(_on_render_scale_changed)

	var br_row := _add_slider_row("Brightness", 0.5, 2.0, VideoSettings.settings["brightness"], 0.05, vbox)
	_brightness_slider = br_row[0]
	_brightness_label = br_row[1]
	_brightness_label.text = "%.2f" % VideoSettings.settings["brightness"]
	_brightness_slider.value_changed.connect(_on_brightness_changed)

	vbox.add_child(HSeparator.new())

	# ── Anti-Aliasing ────────────────────────────────────────────────────
	_add_section_header("Anti-Aliasing", vbox)

	_msaa_option = _add_option_row("MSAA", ["Off", "2x", "4x", "8x"], VideoSettings.settings["msaa"], vbox)
	_msaa_option.item_selected.connect(_on_msaa_changed)

	_fxaa_button = _add_check("FXAA", VideoSettings.settings["fxaa"], vbox)
	_fxaa_button.toggled.connect(_on_fxaa_toggled)

	_taa_button = _add_check("TAA", VideoSettings.settings["taa"], vbox)
	_taa_button.toggled.connect(_on_taa_toggled)

	vbox.add_child(HSeparator.new())

	# ── Shadows ──────────────────────────────────────────────────────────
	_add_section_header("Shadows", vbox)

	_shadow_option = _add_option_row("Shadow Quality", ["Off", "Low", "Medium", "High"], VideoSettings.settings["shadow_quality"], vbox)
	_shadow_option.item_selected.connect(_on_shadow_changed)

	_shadow_filter_option = _add_option_row("Shadow Softness", ["Hard", "Soft Low", "Soft Medium", "Soft High"], VideoSettings.settings["shadow_filter"], vbox)
	_shadow_filter_option.item_selected.connect(_on_shadow_filter_changed)

	vbox.add_child(HSeparator.new())

	# ── Lighting & Effects ───────────────────────────────────────────────
	_add_section_header("Lighting & Effects", vbox)

	_ssao_button = _add_check("SSAO", VideoSettings.settings["ssao_enabled"], vbox)
	_ssao_button.toggled.connect(_on_ssao_toggled)

	_ssao_quality_option = _add_option_row("SSAO Quality", ["Low", "Medium", "High"], VideoSettings.settings["ssao_quality"], vbox)
	_ssao_quality_option.item_selected.connect(_on_ssao_quality_changed)

	_ssil_button = _add_check("SSIL", VideoSettings.settings["ssil_enabled"], vbox)
	_ssil_button.toggled.connect(_on_ssil_toggled)

	_ssil_quality_option = _add_option_row("SSIL Quality", ["Low", "Medium", "High"], VideoSettings.settings["ssil_quality"], vbox)
	_ssil_quality_option.item_selected.connect(_on_ssil_quality_changed)

	_ssr_button = _add_check("SSR", VideoSettings.settings["ssr_enabled"], vbox)
	_ssr_button.toggled.connect(_on_ssr_toggled)

	_ssr_quality_option = _add_option_row("SSR Quality", ["Low", "Medium", "High"], VideoSettings.settings["ssr_quality"], vbox)
	_ssr_quality_option.item_selected.connect(_on_ssr_quality_changed)

	_glow_button = _add_check("Glow / Bloom", VideoSettings.settings["glow_enabled"], vbox)
	_glow_button.toggled.connect(_on_glow_toggled)

	var glow_row := _add_slider_row("Glow Intensity", 0.0, 2.0, VideoSettings.settings["glow_intensity"], 0.05, vbox)
	_glow_slider = glow_row[0]
	_glow_label = glow_row[1]
	_glow_label.text = "%.2f" % VideoSettings.settings["glow_intensity"]
	_glow_slider.value_changed.connect(_on_glow_intensity_changed)

	_gi_option = _add_option_row("Global Illumination", ["None", "SDFGI"], VideoSettings.settings["gi_mode"], vbox)
	_gi_option.item_selected.connect(_on_gi_changed)

	vbox.add_child(HSeparator.new())

	# ── Fog ──────────────────────────────────────────────────────────────
	_add_section_header("Fog", vbox)

	_fog_button = _add_check("Fog", VideoSettings.settings["fog_enabled"], vbox)
	_fog_button.toggled.connect(_on_fog_toggled)

	_volumetric_fog_button = _add_check("Volumetric Fog", VideoSettings.settings["volumetric_fog"], vbox)
	_volumetric_fog_button.toggled.connect(_on_volumetric_fog_toggled)

	vbox.add_child(HSeparator.new())

	# ── Performance ──────────────────────────────────────────────────────
	_add_section_header("Performance", vbox)

	_fps_hud_button = _add_check("Show FPS", false, vbox)
	_fps_hud_button.toggled.connect(_on_fps_hud_toggled)

	vbox.add_child(HSeparator.new())

	# ── Back button ──────────────────────────────────────────────────────
	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(120, 40)
	back_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	back_btn.pressed.connect(_on_video_back_pressed)
	vbox.add_child(back_btn)


# ══════════════════════════════════════════════════════════════════════════
# UI HELPERS
# ══════════════════════════════════════════════════════════════════════════

func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.border_color = Color(0.3, 0.4, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(20)
	return style


func _add_section_header(text: String, parent: Node) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.6, 0.75, 1.0))
	parent.add_child(label)


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


func _add_option_row(label_text: String, items: Array, default_index: int, parent: Node) -> OptionButton:
	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var option := OptionButton.new()
	for i in items.size():
		option.add_item(items[i], i)
	option.selected = default_index
	hbox.add_child(option)
	parent.add_child(hbox)
	return option


# ══════════════════════════════════════════════════════════════════════════
# NAVIGATION
# ══════════════════════════════════════════════════════════════════════════

func _on_video_settings_pressed() -> void:
	_main_panel.visible = false
	_video_panel.visible = true


func _on_video_back_pressed() -> void:
	VideoSettings.save_settings()
	_video_panel.visible = false
	_main_panel.visible = true


# ══════════════════════════════════════════════════════════════════════════
# VIDEO SETTINGS CALLBACKS
# ══════════════════════════════════════════════════════════════════════════

# ── Presets ──────────────────────────────────────────────────────────────

func _on_preset_pressed(preset_name: String) -> void:
	VideoSettings.apply_preset(preset_name)
	_refresh_all_video_controls()


# ── Display ──────────────────────────────────────────────────────────────

func _on_vsync_toggled(pressed: bool) -> void:
	VideoSettings.settings["vsync"] = pressed
	VideoSettings.apply_display()


func _on_fullscreen_toggled(pressed: bool) -> void:
	VideoSettings.settings["fullscreen"] = pressed
	VideoSettings.apply_display()


func _on_fov_changed(value: float) -> void:
	_fov_label.text = "%.0f" % value
	VideoSettings.settings["fov"] = value
	VideoSettings.apply_fov()


func _on_render_scale_changed(value: float) -> void:
	_render_scale_label.text = "%.0f%%" % (value * 100.0)
	VideoSettings.settings["render_scale"] = value
	VideoSettings.apply_display()


func _on_brightness_changed(value: float) -> void:
	_brightness_label.text = "%.2f" % value
	VideoSettings.settings["brightness"] = value
	VideoSettings.apply_display()


# ── Anti-Aliasing ────────────────────────────────────────────────────────

func _on_msaa_changed(index: int) -> void:
	VideoSettings.settings["msaa"] = index
	VideoSettings.apply_anti_aliasing()


func _on_fxaa_toggled(pressed: bool) -> void:
	VideoSettings.settings["fxaa"] = pressed
	VideoSettings.apply_anti_aliasing()


func _on_taa_toggled(pressed: bool) -> void:
	VideoSettings.settings["taa"] = pressed
	VideoSettings.apply_anti_aliasing()


# ── Shadows ──────────────────────────────────────────────────────────────

func _on_shadow_changed(index: int) -> void:
	VideoSettings.settings["shadow_quality"] = index
	VideoSettings.apply_shadows()


func _on_shadow_filter_changed(index: int) -> void:
	VideoSettings.settings["shadow_filter"] = index
	VideoSettings.apply_shadows()


# ── Post-Processing ─────────────────────────────────────────────────────

func _on_ssao_toggled(pressed: bool) -> void:
	VideoSettings.settings["ssao_enabled"] = pressed
	VideoSettings.apply_post_processing()


func _on_ssao_quality_changed(index: int) -> void:
	VideoSettings.settings["ssao_quality"] = index
	VideoSettings.apply_post_processing()


func _on_ssil_toggled(pressed: bool) -> void:
	VideoSettings.settings["ssil_enabled"] = pressed
	VideoSettings.apply_post_processing()


func _on_ssil_quality_changed(index: int) -> void:
	VideoSettings.settings["ssil_quality"] = index
	VideoSettings.apply_post_processing()


func _on_ssr_toggled(pressed: bool) -> void:
	VideoSettings.settings["ssr_enabled"] = pressed
	VideoSettings.apply_post_processing()


func _on_ssr_quality_changed(index: int) -> void:
	VideoSettings.settings["ssr_quality"] = index
	VideoSettings.apply_post_processing()


func _on_glow_toggled(pressed: bool) -> void:
	VideoSettings.settings["glow_enabled"] = pressed
	VideoSettings.apply_post_processing()


func _on_glow_intensity_changed(value: float) -> void:
	_glow_label.text = "%.2f" % value
	VideoSettings.settings["glow_intensity"] = value
	VideoSettings.apply_post_processing()


func _on_gi_changed(index: int) -> void:
	VideoSettings.settings["gi_mode"] = index
	VideoSettings.apply_gi()


# ── Fog ──────────────────────────────────────────────────────────────────

func _on_fog_toggled(pressed: bool) -> void:
	VideoSettings.settings["fog_enabled"] = pressed
	VideoSettings.apply_fog()


func _on_volumetric_fog_toggled(pressed: bool) -> void:
	VideoSettings.settings["volumetric_fog"] = pressed
	VideoSettings.apply_fog()


# ── Performance ──────────────────────────────────────────────────────────

func _on_fps_hud_toggled(pressed: bool) -> void:
	GameManager.show_fps_hud = pressed


# ══════════════════════════════════════════════════════════════════════════
# PRESET UI REFRESH
# ══════════════════════════════════════════════════════════════════════════

func _refresh_all_video_controls() -> void:
	## Update every video settings UI control to match VideoSettings.settings
	## without triggering signal callbacks (block signals during update).
	var s := VideoSettings.settings

	_set_check_silent(_vsync_button, s["vsync"])
	_set_check_silent(_fullscreen_button, s["fullscreen"])
	_set_slider_silent(_fov_slider, s["fov"])
	_fov_label.text = "%.0f" % s["fov"]
	_set_slider_silent(_render_scale_slider, s["render_scale"])
	_render_scale_label.text = "%.0f%%" % (s["render_scale"] * 100.0)
	_set_slider_silent(_brightness_slider, s["brightness"])
	_brightness_label.text = "%.2f" % s["brightness"]

	_set_option_silent(_msaa_option, s["msaa"])
	_set_check_silent(_fxaa_button, s["fxaa"])
	_set_check_silent(_taa_button, s["taa"])

	_set_option_silent(_shadow_option, s["shadow_quality"])
	_set_option_silent(_shadow_filter_option, s["shadow_filter"])

	_set_check_silent(_ssao_button, s["ssao_enabled"])
	_set_option_silent(_ssao_quality_option, s["ssao_quality"])
	_set_check_silent(_ssil_button, s["ssil_enabled"])
	_set_option_silent(_ssil_quality_option, s["ssil_quality"])
	_set_check_silent(_ssr_button, s["ssr_enabled"])
	_set_option_silent(_ssr_quality_option, s["ssr_quality"])
	_set_check_silent(_glow_button, s["glow_enabled"])
	_set_slider_silent(_glow_slider, s["glow_intensity"])
	_glow_label.text = "%.2f" % s["glow_intensity"]
	_set_option_silent(_gi_option, s["gi_mode"])

	_set_check_silent(_fog_button, s["fog_enabled"])
	_set_check_silent(_volumetric_fog_button, s["volumetric_fog"])


func _set_check_silent(btn: CheckButton, value: bool) -> void:
	btn.set_block_signals(true)
	btn.button_pressed = value
	btn.set_block_signals(false)


func _set_slider_silent(slider: HSlider, value: float) -> void:
	slider.set_block_signals(true)
	slider.value = value
	slider.set_block_signals(false)


func _set_option_silent(option: OptionButton, index: int) -> void:
	option.set_block_signals(true)
	option.selected = index
	option.set_block_signals(false)


# ══════════════════════════════════════════════════════════════════════════
# DEBUG CALLBACKS (unchanged from original)
# ══════════════════════════════════════════════════════════════════════════

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


func _on_grapple_horiz_nudge_toggled(pressed: bool) -> void:
	GameManager.debug_grapple_horiz_nudge = pressed
	print("[PauseMenu] Grapple horizontal nudge: %s" % ("ON" if pressed else "OFF"))


func _on_velocity_iter_changed(value: float) -> void:
	var iters := int(value)
	_velocity_iter_label.text = "%d" % iters
	GameManager.debug_velocity_iterations = iters
	var space_rid := get_viewport().world_3d.space
	PhysicsServer3D.space_set_param(space_rid, PhysicsServer3D.SPACE_PARAM_SOLVER_ITERATIONS, iters)
	print("[PauseMenu] Physics solver iterations: %d" % iters)


func _on_mass_pin_toggled(pressed: bool) -> void:
	# 1000 = disable mass-ratio pin, 1001 = enable (via custom get_process_info codes)
	PhysicsServer3D.get_process_info(1000 if pressed else 1001)
	print("[PauseMenu] Mass-ratio pin: %s" % ("DISABLED" if pressed else "ENABLED"))


func _on_toad_density_submitted(text: String) -> void:
	var val := int(text.to_float())
	if val >= 1:
		var toad_dim := get_node_or_null("/root/ToadDimension")
		if toad_dim:
			toad_dim.toads_per_tick = val
			print("[PauseMenu] Toad rain density set to %d toads/tick" % val)
	_refresh_toad_density_text()


func _on_toad_no_physics_toggled(pressed: bool) -> void:
	GameManager.debug_toad_no_physics = pressed
	# Apply to all existing toad bodies
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim:
		toad_dim.apply_toad_physics_toggle(not pressed)
	print("[PauseMenu] Toad physics disabled: %s" % ("ON" if pressed else "OFF"))


func _on_toad_no_shadows_toggled(pressed: bool) -> void:
	GameManager.debug_toad_no_shadows = pressed
	# Apply to all existing toad bodies
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim:
		toad_dim.apply_toad_shadow_toggle(not pressed)
	print("[PauseMenu] Toad shadows disabled: %s" % ("ON" if pressed else "OFF"))


func _on_toad_show_hitboxes_toggled(pressed: bool) -> void:
	GameManager.debug_toad_show_hitboxes = pressed
	# Apply to all existing toad bodies in the scene (all sources: rain, rail cannon, bowl)
	for node in get_tree().get_nodes_in_group("toad_bodies"):
		if node.has_method("set_hitbox_visible"):
			node.set_hitbox_visible(pressed)
	print("[PauseMenu] Toad hitboxes: %s" % ("ON" if pressed else "OFF"))


func _on_toad_density_focus_lost() -> void:
	## Apply toad density when the user clicks away (not just on Enter).
	if _toad_density_input == null:
		return
	_on_toad_density_submitted(_toad_density_input.text)


func _refresh_toad_density_text() -> void:
	if _toad_density_input == null:
		return
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim:
		_toad_density_input.text = "%d" % toad_dim.toads_per_tick
	else:
		_toad_density_input.text = "45"


func _on_toad_fog_density_submitted(text: String) -> void:
	var val := text.to_float()
	if val > 0.0 and val <= 1.0:
		var toad_dim := get_node_or_null("/root/ToadDimension")
		if toad_dim:
			toad_dim.apply_fog_density(val)
			print("[PauseMenu] Toad fog density set to %.4f" % val)
	_refresh_toad_fog_density_text()


func _on_toad_fog_density_focus_lost() -> void:
	## Apply fog density when the user clicks away (not just on Enter).
	if _toad_fog_density_input == null:
		return
	_on_toad_fog_density_submitted(_toad_fog_density_input.text)


func _refresh_toad_fog_density_text() -> void:
	if _toad_fog_density_input == null:
		return
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim:
		_toad_fog_density_input.text = "%.4f" % toad_dim.toad_fog_density
	else:
		_toad_fog_density_input.text = "0.0030"


func _on_toad_mass_submitted(text: String) -> void:
	var val := text.to_float()
	if val > 0.0 and val <= 1000.0:
		GameManager.debug_toad_mass = val
		# Apply to all existing toad bodies
		for node in get_tree().get_nodes_in_group("toad_bodies"):
			if node is RigidBody3D and not node.freeze:
				node.mass = val
		print("[PauseMenu] Toad mass set to %.1f kg" % val)
	else:
		_toad_mass_input.text = "%.1f" % GameManager.debug_toad_mass


func _on_toad_mass_focus_lost() -> void:
	if _toad_mass_input == null:
		return
	_on_toad_mass_submitted(_toad_mass_input.text)


func _on_box_mass_submitted(text: String) -> void:
	var val := text.to_float()
	if val > 0.0 and val <= 10000.0:
		var box := get_tree().current_scene.get_node_or_null("DebugPushBox") if get_tree().current_scene else null
		if box is RigidBody3D:
			box.mass = val
			print("[PauseMenu] Debug box mass set to %.1f kg" % val)
		else:
			print("[PauseMenu] DebugPushBox not found in scene")
	else:
		_box_mass_input.text = "4.0"


func _on_box_mass_focus_lost() -> void:
	if _box_mass_input == null:
		return
	_on_box_mass_submitted(_box_mass_input.text)


func _update_quit_button() -> void:
	if _quit_btn == null:
		return
	# Disconnect old signals
	if _quit_btn.pressed.is_connected(_on_quit_pressed):
		_quit_btn.pressed.disconnect(_on_quit_pressed)
	if _quit_btn.pressed.is_connected(_on_reset_pressed):
		_quit_btn.pressed.disconnect(_on_reset_pressed)
	# Reconnect based on role
	if NetworkManager.is_server:
		_quit_btn.text = "Reset Game"
		_quit_btn.pressed.connect(_on_reset_pressed)
	else:
		_quit_btn.text = "Disconnect"
		_quit_btn.pressed.connect(_on_quit_pressed)


func _on_reset_pressed() -> void:
	_toggle_menu()
	NetworkManager.reset_game()


func _on_quit_pressed() -> void:
	_toggle_menu()
	NetworkManager.disconnect_game()
