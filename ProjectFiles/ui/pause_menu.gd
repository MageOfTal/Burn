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
var _explosion_spheres_button: CheckButton = null
var _explosion_rays_button: CheckButton = null
var _lagger_delay_input: LineEdit = null
var _lagger_overhead_button: CheckButton = null
var _explosion_repeat_button: CheckButton = null
var _toad_density_input: LineEdit = null
var _toad_fog_density_input: LineEdit = null
var _toad_mass_input: LineEdit = null
var _toad_no_physics_button: CheckButton = null
var _toad_no_shadows_button: CheckButton = null
var _toad_show_hitboxes_button: CheckButton = null
var _quit_btn: Button = null
var _box_mass_input: LineEdit = null
var _momentum_damage_input: LineEdit = null
var _explosion_radius_input: LineEdit = null
var _explosion_damage_input: LineEdit = null
var _resistance_scale_input: LineEdit = null
var _surface_press_button: CheckButton = null
var _speed_50_button: CheckButton = null
var _explosion_diag_button: CheckButton = null
var _structure_layers_button: CheckButton = null
var _layer_overlay_timer: float = 0.0
var _layer_labels: Dictionary = {}
var _hitbox_mesh_node: MeshInstance3D = null

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
var _roughness_limiter_button: CheckButton = null
var _tonemap_option: OptionButton = null
var _adjustment_button: CheckButton = null
var _contrast_slider: HSlider = null
var _contrast_label: Label = null
var _saturation_slider: HSlider = null
var _saturation_label: Label = null
var _dof_button: CheckButton = null
var _dof_distance_slider: HSlider = null
var _dof_distance_label: Label = null
var _dof_blur_slider: HSlider = null
var _dof_blur_label: Label = null
var _auto_exposure_button: CheckButton = null
var _debanding_button: CheckButton = null
var _scaling_mode_option: OptionButton = null
var _sharpening_slider: HSlider = null
var _sharpening_label: Label = null
var _fps_hud_button: CheckButton = null
var _debris_button: CheckButton = null
var _detached_structures_button: CheckButton = null


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
	if GameManager.debug_show_structure_layers:
		_layer_overlay_timer += delta
		if _layer_overlay_timer >= 0.5:
			_layer_overlay_timer = 0.0
			_update_structure_layer_labels()
	elif not _layer_labels.is_empty() or _hitbox_mesh_node != null:
		_clear_structure_layer_labels()
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

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_main_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

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

	_add_check("Show Safe Zone (no-sever radius)", GameManager.debug_grapple_safe_zone, vbox) \
		.toggled.connect(func(p): GameManager.debug_grapple_safe_zone = p)

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

	_mass_pin_button = _add_check("Enable Mass-Ratio Pin", false, vbox)
	_mass_pin_button.toggled.connect(_on_mass_pin_toggled)

	_explosion_spheres_button = _add_check("Show Explosion Spheres (Tower Rubble)", false, vbox)
	_explosion_spheres_button.toggled.connect(_on_explosion_spheres_toggled)

	_explosion_rays_button = _add_check("Show Explosion Rays (Wall Blocks)", false, vbox)
	_explosion_rays_button.toggled.connect(_on_explosion_rays_toggled)

	_add_check("Show Block Hits", GameManager.debug_show_block_hits, vbox).toggled.connect(
		func(pressed: bool): GameManager.debug_show_block_hits = pressed)

	_lagger_delay_input = _add_scale_input("Lagger Delay (ms)",
		GameManager.debug_lagger_delay_ms,
		_on_lagger_delay_submitted, _on_lagger_delay_focus_lost, vbox)

	_lagger_overhead_button = _add_check("Lagger: Overhead Mode", GameManager.debug_lagger_overhead_mode, vbox)
	_lagger_overhead_button.toggled.connect(_on_lagger_overhead_toggled)

	_explosion_repeat_button = _add_check("Explosion Shielding 2000x Repeat", GameManager.debug_explosion_repeat, vbox)
	_explosion_repeat_button.toggled.connect(_on_explosion_repeat_toggled)

	_explosion_diag_button = _add_check("Explosion Diagnostics (Full Dump)", GameManager.debug_explosion_diagnostics, vbox)
	_explosion_diag_button.toggled.connect(_on_explosion_diag_toggled)

	_structure_layers_button = _add_check("Show Structure Collision Layers", GameManager.debug_show_structure_layers, vbox)
	_structure_layers_button.toggled.connect(_on_structure_layers_toggled)

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

	# ── Performance ─────────────────────────────────────────────────────
	_add_section_header("Performance", vbox)

	_debris_button = _add_check("Disable Debris", GameManager.disable_debris, vbox)
	_debris_button.toggled.connect(_on_debris_toggled)

	_detached_structures_button = _add_check("Disable Detached Structures", GameManager.debug_disable_detached_structures, vbox)
	_detached_structures_button.toggled.connect(_on_detached_structures_toggled)

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

	# ── Structure Collision ─────────────────────────────────────────────
	_add_section_header("Structure Collision", vbox)

	_momentum_damage_input = _add_scale_input("Momentum Damage Scale",
		GameManager.structure_momentum_damage_scale,
		_on_momentum_damage_submitted, _on_momentum_damage_focus_lost, vbox)

	_explosion_radius_input = _add_scale_input("Explosion Radius Scale",
		GameManager.structure_explosion_radius_scale,
		_on_explosion_radius_submitted, _on_explosion_radius_focus_lost, vbox)

	_explosion_damage_input = _add_scale_input("Explosion Damage Scale",
		GameManager.structure_explosion_damage_scale,
		_on_explosion_damage_submitted, _on_explosion_damage_focus_lost, vbox)

	_resistance_scale_input = _add_scale_input("Resistance Scale",
		GameManager.structure_resistance_scale,
		_on_resistance_scale_submitted, _on_resistance_scale_focus_lost, vbox)

	# Separator
	vbox.add_child(HSeparator.new())

	# ── Player Physics ─────────────────────────────────────────────────
	_add_section_header("Player Physics", vbox)

	_speed_50_button = _add_check("Speed 50", GameManager.debug_speed_50, vbox)
	_speed_50_button.toggled.connect(_on_speed_50_toggled)

	_add_check("No Slope Projection", GameManager.debug_no_slope_projection, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_slope_projection = p)
	_add_check("No Landing Restore", GameManager.debug_no_landing_restore, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_landing_restore = p)
	_add_check("Always Ground Move", GameManager.debug_always_ground_move, vbox) \
		.toggled.connect(func(p): GameManager.debug_always_ground_move = p)
	_add_check("Show Terrain Collision", GameManager.debug_show_collision, vbox) \
		.toggled.connect(func(p): GameManager.debug_show_collision = p)

	# ── Solver Diagnostics ─────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	_add_section_header("Solver Diagnostics", vbox)

	_add_check("Log Physics (grounding, snap, impulse)", GameManager.debug_grounding_log, vbox) \
		.toggled.connect(func(p): GameManager.debug_grounding_log = p)
	_add_check("Player Zero Friction", GameManager.debug_player_zero_friction, vbox) \
		.toggled.connect(func(p): GameManager.debug_player_zero_friction = p)
	_add_check("No Floor Speed Restore", GameManager.debug_no_floor_speed_restore, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_floor_speed_restore = p)
	_add_check("No Dynamic Impulse Correction", GameManager.debug_no_dynamic_speed_restore, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_dynamic_speed_restore = p)
	_add_check("No Wall Projection", GameManager.debug_no_wall_proj, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_wall_proj = p)
	_add_check("Wall Proj on Dynamic Bodies", GameManager.debug_wall_proj_dynamic, vbox) \
		.toggled.connect(func(p): GameManager.debug_wall_proj_dynamic = p)
	_add_check("No Wall Speed Scaling", GameManager.debug_no_wall_speed_scale, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_wall_speed_scale = p)
	_add_check("Dynamic Body Speed Scaling", GameManager.debug_dynamic_speed_scale, vbox) \
		.toggled.connect(func(p): GameManager.debug_dynamic_speed_scale = p)
	_add_check("Restore Full Speed (ignore solver)", GameManager.debug_restore_full_speed, vbox) \
		.toggled.connect(func(p): GameManager.debug_restore_full_speed = p)
	_add_check("No Dime Stop", GameManager.debug_no_dime_stop, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_dime_stop = p)

	# ── Wedge stability experiments ─────────────────────────────────
	# Toggle one at a time to compare feel when pushing a box against a wall.
	vbox.add_child(HSeparator.new())
	_add_section_header("Wedge Stability (box vs wall)", vbox)

	_add_check("Fix 1: Lerp direction by fraction (default)", GameManager.debug_wedge_lerp_direction, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_lerp_direction = p)
	_add_check("Fix 2: Hard-kill direction above threshold", GameManager.debug_wedge_hard_kill, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_hard_kill = p)
	_add_check("Fix 3: Skip velocity write when wedged", GameManager.debug_wedge_skip_inject, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_skip_inject = p)
	_add_check("Fix 4: Use post-solver velocity as base", GameManager.debug_wedge_postsolver_base, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_postsolver_base = p)
	_add_check("Box-Press Diagnostic Log (player+box+pressed-into+phase)", GameManager.debug_wedge_log, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_log = p)

	# Fraction lifecycle fixes (the actual root cause: deadband oscillation)
	_add_check("Fix 5: Decay fraction instead of reset", GameManager.debug_wedge_fraction_decay, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_fraction_decay = p)
	_add_check("Fix 6: Hold fraction while contact exists", GameManager.debug_wedge_fraction_hold, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_fraction_hold = p)
	_add_check("Fix 7: Stick to walls when pressing in (zero outward drift)", GameManager.debug_wedge_stick_to_walls, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_stick_to_walls = p)
	_add_check("Fix 8: Wall-proj full 3D normal (compound contact constraint)", GameManager.debug_wall_proj_full_normal, vbox) \
		.toggled.connect(func(p): GameManager.debug_wall_proj_full_normal = p)
	_add_check("Fix 9: Joint wedge-axis projection (geometric correct)", GameManager.debug_wedge_joint_proj, vbox) \
		.toggled.connect(func(p): GameManager.debug_wedge_joint_proj = p)
	# Wedge-cause isolation tests (turn ONE on, leave Fix 9 OFF, reproduce wedge,
	# see if the stutter still happens — proves which subsystem is responsible).
	_add_check("[Test] Disable Snap entirely", GameManager.debug_no_snap, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_snap = p)
	_add_check("[Test] Disable Slope-proj", GameManager.debug_no_slope_projection, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_slope_projection = p)
	_add_check("[Test] Disable Wall-proj", GameManager.debug_no_wall_proj, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_wall_proj = p)
	_add_check("[Test] Disable Walk-accel", GameManager.debug_no_walk_accel, vbox) \
		.toggled.connect(func(p): GameManager.debug_no_walk_accel = p)
	_add_check("[Test] Apply gravity always (every frame, world-Y)", GameManager.debug_gravity_always, vbox) \
		.toggled.connect(func(p): GameManager.debug_gravity_always = p)
	_add_check("Restore Even With Walls", GameManager.debug_restore_with_walls, vbox) \
		.toggled.connect(func(p): GameManager.debug_restore_with_walls = p)
	_add_check("Instant Acceleration", GameManager.debug_instant_accel, vbox) \
		.toggled.connect(func(p): GameManager.debug_instant_accel = p)

	# ── Render profiling toggles ──
	_add_check("No Shadows (perf test)", GameManager.debug_no_shadows, vbox) \
		.toggled.connect(_on_no_shadows_toggled)
	_add_check("Hide Clusters (perf test)", GameManager.debug_hide_clusters, vbox) \
		.toggled.connect(_on_hide_clusters_toggled)
	_add_scale_input("Shadow Distance", 800.0,
		_on_shadow_distance_changed, func(): pass, vbox)
	_add_check("Extend Snap Range (0.5m)", GameManager.debug_grounding_extend_snap, vbox) \
		.toggled.connect(func(p): GameManager.debug_grounding_extend_snap = p)
	_add_check("Dynamic Snap (vel.y × delta launch recovery)", GameManager.debug_dynamic_snap, vbox) \
		.toggled.connect(func(p): GameManager.debug_dynamic_snap = p)
	var _snap_budget_input := _add_labeled_input("Snap Budget (m)", str(GameManager.debug_snap_budget), vbox)
	_snap_budget_input.text_changed.connect(func(t):
		var v: float = clampf(float(t), 0.0, 1.0)
		GameManager.debug_snap_budget = v
		print("[SnapBudget] set to %.3fm" % v))
	_add_check("Surface Press (vel.y bias)", GameManager.debug_grounding_surface_press, vbox) \
		.toggled.connect(func(p): GameManager.debug_grounding_surface_press = p)
	var _press_input = _add_labeled_input("Press Strength", str(GameManager.debug_grounding_press_strength), vbox)
	_press_input.text_submitted.connect(func(t): GameManager.debug_grounding_press_strength = clampf(float(t), 0.1, 20.0))

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

	# ── Reflections & Specular ──────────────────────────────────────────
	_add_section_header("Reflections & Specular", vbox)

	_roughness_limiter_button = _add_check("Roughness Limiter", VideoSettings.settings["roughness_limiter"], vbox)
	_roughness_limiter_button.toggled.connect(_on_roughness_limiter_toggled)

	vbox.add_child(HSeparator.new())

	# ── Tonemap ────────────────────────────────────────────────────────
	_add_section_header("Tonemap", vbox)

	_tonemap_option = _add_option_row("Tonemap Mode", ["Linear", "Reinhardt", "Filmic", "ACES"], VideoSettings.settings["tonemap_mode"], vbox)
	_tonemap_option.item_selected.connect(_on_tonemap_changed)

	vbox.add_child(HSeparator.new())

	# ── Color Adjustments ──────────────────────────────────────────────
	_add_section_header("Color Adjustments", vbox)

	_adjustment_button = _add_check("Enable Adjustments", VideoSettings.settings["adjustment_enabled"], vbox)
	_adjustment_button.toggled.connect(_on_adjustment_toggled)

	var contrast_row := _add_slider_row("Contrast", 0.5, 2.0, VideoSettings.settings["adjustment_contrast"], 0.05, vbox)
	_contrast_slider = contrast_row[0]
	_contrast_label = contrast_row[1]
	_contrast_label.text = "%.2f" % VideoSettings.settings["adjustment_contrast"]
	_contrast_slider.value_changed.connect(_on_contrast_changed)

	var saturation_row := _add_slider_row("Saturation", 0.0, 2.0, VideoSettings.settings["adjustment_saturation"], 0.05, vbox)
	_saturation_slider = saturation_row[0]
	_saturation_label = saturation_row[1]
	_saturation_label.text = "%.2f" % VideoSettings.settings["adjustment_saturation"]
	_saturation_slider.value_changed.connect(_on_saturation_changed)

	vbox.add_child(HSeparator.new())

	# ── Camera Effects ─────────────────────────────────────────────────
	_add_section_header("Camera Effects", vbox)

	_dof_button = _add_check("Depth of Field", VideoSettings.settings["dof_enabled"], vbox)
	_dof_button.toggled.connect(_on_dof_toggled)

	var dof_dist_row := _add_slider_row("DOF Distance", 1.0, 200.0, VideoSettings.settings["dof_focus_distance"], 1.0, vbox)
	_dof_distance_slider = dof_dist_row[0]
	_dof_distance_label = dof_dist_row[1]
	_dof_distance_label.text = "%.0f" % VideoSettings.settings["dof_focus_distance"]
	_dof_distance_slider.value_changed.connect(_on_dof_distance_changed)

	var dof_blur_row := _add_slider_row("DOF Blur", 0.01, 0.2, VideoSettings.settings["dof_blur_amount"], 0.01, vbox)
	_dof_blur_slider = dof_blur_row[0]
	_dof_blur_label = dof_blur_row[1]
	_dof_blur_label.text = "%.2f" % VideoSettings.settings["dof_blur_amount"]
	_dof_blur_slider.value_changed.connect(_on_dof_blur_changed)

	_auto_exposure_button = _add_check("Auto Exposure", VideoSettings.settings["auto_exposure"], vbox)
	_auto_exposure_button.toggled.connect(_on_auto_exposure_toggled)

	vbox.add_child(HSeparator.new())

	# ── Rendering Quality ──────────────────────────────────────────────
	_add_section_header("Rendering Quality", vbox)

	_debanding_button = _add_check("Debanding", VideoSettings.settings["debanding"], vbox)
	_debanding_button.toggled.connect(_on_debanding_toggled)

	_scaling_mode_option = _add_option_row("3D Scaling", ["Bilinear", "FSR 1.0", "FSR 2.2"], VideoSettings.settings["scaling_3d_mode"], vbox)
	_scaling_mode_option.item_selected.connect(_on_scaling_mode_changed)

	var sharp_row := _add_slider_row("Sharpening", 0.0, 2.0, VideoSettings.settings["sharpening"], 0.1, vbox)
	_sharpening_slider = sharp_row[0]
	_sharpening_label = sharp_row[1]
	_sharpening_label.text = "%.1f" % VideoSettings.settings["sharpening"]
	_sharpening_slider.value_changed.connect(_on_sharpening_changed)

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


func _add_labeled_input(label_text: String, default_text: String, parent: Node) -> LineEdit:
	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var input := LineEdit.new()
	input.text = default_text
	input.custom_minimum_size = Vector2(80, 0)
	input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(input)
	parent.add_child(hbox)
	return input


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


# ── Reflections & Specular ──────────────────────────────────────────────

func _on_roughness_limiter_toggled(pressed: bool) -> void:
	VideoSettings.settings["roughness_limiter"] = pressed
	VideoSettings.apply_reflections()


# ── Tonemap ─────────────────────────────────────────────────────────────

func _on_tonemap_changed(index: int) -> void:
	VideoSettings.settings["tonemap_mode"] = index
	VideoSettings.apply_tonemap()


# ── Color Adjustments ──────────────────────────────────────────────────

func _on_adjustment_toggled(pressed: bool) -> void:
	VideoSettings.settings["adjustment_enabled"] = pressed
	VideoSettings.apply_adjustments()


func _on_contrast_changed(value: float) -> void:
	_contrast_label.text = "%.2f" % value
	VideoSettings.settings["adjustment_contrast"] = value
	VideoSettings.apply_adjustments()


func _on_saturation_changed(value: float) -> void:
	_saturation_label.text = "%.2f" % value
	VideoSettings.settings["adjustment_saturation"] = value
	VideoSettings.apply_adjustments()


# ── Camera Effects ─────────────────────────────────────────────────────

func _on_dof_toggled(pressed: bool) -> void:
	VideoSettings.settings["dof_enabled"] = pressed
	VideoSettings.apply_camera_effects()


func _on_dof_distance_changed(value: float) -> void:
	_dof_distance_label.text = "%.0f" % value
	VideoSettings.settings["dof_focus_distance"] = value
	VideoSettings.apply_camera_effects()


func _on_dof_blur_changed(value: float) -> void:
	_dof_blur_label.text = "%.2f" % value
	VideoSettings.settings["dof_blur_amount"] = value
	VideoSettings.apply_camera_effects()


func _on_auto_exposure_toggled(pressed: bool) -> void:
	VideoSettings.settings["auto_exposure"] = pressed
	VideoSettings.apply_camera_effects()


# ── Rendering Quality ──────────────────────────────────────────────────

func _on_debanding_toggled(pressed: bool) -> void:
	VideoSettings.settings["debanding"] = pressed
	VideoSettings.apply_rendering_quality()


func _on_scaling_mode_changed(index: int) -> void:
	VideoSettings.settings["scaling_3d_mode"] = index
	VideoSettings.apply_rendering_quality()


func _on_sharpening_changed(value: float) -> void:
	_sharpening_label.text = "%.1f" % value
	VideoSettings.settings["sharpening"] = value
	VideoSettings.apply_rendering_quality()


# ── Performance ──────────────────────────────────────────────────────────

func _on_fps_hud_toggled(pressed: bool) -> void:
	GameManager.show_fps_hud = pressed


func _on_debris_toggled(pressed: bool) -> void:
	GameManager.disable_debris = pressed


func _on_detached_structures_toggled(pressed: bool) -> void:
	GameManager.debug_disable_detached_structures = pressed
	print("[PauseMenu] Detached structures: %s" % ("DISABLED" if pressed else "ENABLED"))


# ── Player Physics ──────────────────────────────────────────────────────

func _on_surface_press_toggled(pressed: bool) -> void:
	GameManager.debug_disable_surface_press = pressed
	print("[PauseMenu] Surface press: %s" % ("DISABLED" if pressed else "ENABLED"))


func _on_speed_50_toggled(pressed: bool) -> void:
	GameManager.debug_speed_50 = pressed
	print("[PauseMenu] Speed 50: %s" % ("ON" if pressed else "OFF"))


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

	_set_check_silent(_roughness_limiter_button, s["roughness_limiter"])
	_set_option_silent(_tonemap_option, s["tonemap_mode"])
	_set_check_silent(_adjustment_button, s["adjustment_enabled"])
	_set_slider_silent(_contrast_slider, s["adjustment_contrast"])
	_contrast_label.text = "%.2f" % s["adjustment_contrast"]
	_set_slider_silent(_saturation_slider, s["adjustment_saturation"])
	_saturation_label.text = "%.2f" % s["adjustment_saturation"]
	_set_check_silent(_dof_button, s["dof_enabled"])
	_set_slider_silent(_dof_distance_slider, s["dof_focus_distance"])
	_dof_distance_label.text = "%.0f" % s["dof_focus_distance"]
	_set_slider_silent(_dof_blur_slider, s["dof_blur_amount"])
	_dof_blur_label.text = "%.2f" % s["dof_blur_amount"]
	_set_check_silent(_auto_exposure_button, s["auto_exposure"])
	_set_check_silent(_debanding_button, s["debanding"])
	_set_option_silent(_scaling_mode_option, s["scaling_3d_mode"])
	_set_slider_silent(_sharpening_slider, s["sharpening"])
	_sharpening_label.text = "%.1f" % s["sharpening"]


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
	# 1001 = enable mass-ratio pin, 1000 = disable (via custom get_process_info codes)
	PhysicsServer3D.get_process_info(1001 if pressed else 1000)
	print("[PauseMenu] Mass-ratio pin: %s" % ("ENABLED" if pressed else "DISABLED"))


func _on_explosion_spheres_toggled(pressed: bool) -> void:
	GameManager.debug_show_explosion_spheres = pressed
	print("[PauseMenu] Explosion spheres: %s" % ("ON" if pressed else "OFF"))


func _on_explosion_rays_toggled(pressed: bool) -> void:
	GameManager.debug_show_explosion_rays = pressed
	print("[PauseMenu] Explosion rays: %s" % ("ON" if pressed else "OFF"))


func _on_lagger_delay_submitted(text: String) -> void:
	var val := clampf(text.to_float(), 0.0, 1000.0)
	GameManager.debug_lagger_delay_ms = val
	_lagger_delay_input.text = "%.1f" % val
	_lagger_delay_input.release_focus()
	print("[PauseMenu] Lagger delay set to %.1f ms" % val)


func _on_lagger_delay_focus_lost() -> void:
	_on_lagger_delay_submitted(_lagger_delay_input.text)


func _on_lagger_overhead_toggled(pressed: bool) -> void:
	GameManager.debug_lagger_overhead_mode = pressed
	var mode := "overhead (every tick)" if pressed else "one-off (on fire)"
	print("[PauseMenu] Lagger mode: %s" % mode)


func _on_explosion_repeat_toggled(pressed: bool) -> void:
	GameManager.debug_explosion_repeat = pressed
	print("[PauseMenu] Explosion shielding 2000x repeat: %s" % ("ON" if pressed else "OFF"))


func _on_explosion_diag_toggled(pressed: bool) -> void:
	GameManager.debug_explosion_diagnostics = pressed
	print("[PauseMenu] Explosion diagnostics: %s" % ("ON" if pressed else "OFF"))


func _on_structure_layers_toggled(pressed: bool) -> void:
	GameManager.debug_show_structure_layers = pressed
	if not pressed:
		_clear_structure_layer_labels()
	print("[PauseMenu] Structure collision layers: %s" % ("ON" if pressed else "OFF"))


func _find_structures_node() -> Node:
	var tree := get_tree()
	if not tree or not tree.current_scene:
		return null
	var seed_world = tree.current_scene.get_node_or_null("SeedWorld")
	if seed_world == null:
		seed_world = tree.current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	if seed_world:
		return seed_world.get_node_or_null("Structures")
	return null


func _layer_bits_str(layer: int) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if layer & CollisionLayers.WORLD: parts.append("WORLD")
	if layer & CollisionLayers.ITEMS: parts.append("ITEMS")
	if layer & CollisionLayers.BUBBLES: parts.append("BUBBLES")
	if layer & CollisionLayers.RUBBER_BALLS: parts.append("RUBBER_BALLS")
	if layer & CollisionLayers.TOAD_WALLS: parts.append("TOAD_WALLS")
	if layer & CollisionLayers.DEBRIS: parts.append("DEBRIS")
	if layer & CollisionLayers.TOAD_RAIN: parts.append("TOAD_RAIN")
	if layer & CollisionLayers.PLAYERS_HIT: parts.append("PLAYERS_HIT")
	if layer & CollisionLayers.TOAD_PLAYERS: parts.append("TOAD_PLAYERS")
	if layer & CollisionLayers.PLAYERS_PUSH: parts.append("PLAYERS_PUSH")
	if layer & CollisionLayers.WALL_BLOCKS: parts.append("WALL_BLOCKS")
	if layer & CollisionLayers.WALL_SMOOTH: parts.append("WALL_SMOOTH")
	if parts.is_empty(): return "NONE(0)"
	return "%s(%d)" % ["|".join(parts), layer]


func _update_structure_layer_labels() -> void:
	var structures_node := _find_structures_node()
	if not structures_node:
		_clear_structure_layer_labels()
		return

	var scene_root := get_tree().current_scene
	if not scene_root:
		return

	# Create or reuse the hitbox wireframe mesh node
	if _hitbox_mesh_node == null or not is_instance_valid(_hitbox_mesh_node):
		_hitbox_mesh_node = MeshInstance3D.new()
		_hitbox_mesh_node.name = "DebugStructureHitboxes"
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.vertex_color_use_as_albedo = true
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hitbox_mesh_node.material_override = mat
		scene_root.add_child(_hitbox_mesh_node)

	var im: ImmediateMesh
	if _hitbox_mesh_node.mesh is ImmediateMesh:
		im = _hitbox_mesh_node.mesh
		im.clear_surfaces()
	else:
		im = ImmediateMesh.new()
		_hitbox_mesh_node.mesh = im

	const HITBOX_RANGE := 15.0
	const HITBOX_RANGE_SQ := HITBOX_RANGE * HITBOX_RANGE
	# Structure center can be offset from its blocks — use generous margin
	const STRUCT_CULL_RANGE := HITBOX_RANGE + 10.0

	var cam := get_viewport().get_camera_3d()
	if not cam:
		return
	var cam_pos := cam.global_position

	var half := 0.26  # Slightly larger than BLOCK_SIZE/2 so wireframe isn't flush with mesh
	var seen: Dictionary = {}

	im.surface_begin(Mesh.PRIMITIVE_LINES)

	for child in structures_node.get_children():
		var is_wall := child is DestructibleBlockStructure
		var is_cluster := child is FallingBlockCluster
		if not is_wall and not is_cluster:
			continue

		# Skip structures too far from camera
		if cam_pos.distance_to(child.global_position) > STRUCT_CULL_RANGE:
			continue

		var id := child.get_instance_id()
		seen[id] = true

		# Determine color from compound hit body status
		var hit_body: Node = child.get("_compound_hit_body")
		var has_wall_blocks := false
		var active_shapes := 0
		var color := Color(1.0, 0.2, 0.2, 0.6)  # Red = problem

		if hit_body != null and is_instance_valid(hit_body):
			var layer: int = hit_body.collision_layer
			has_wall_blocks = bool(layer & CollisionLayers.WALL_BLOCKS)
			var key_map: Dictionary = child.get("_key_to_shape")
			active_shapes = key_map.size() if key_map else 0
			if has_wall_blocks and active_shapes > 0:
				color = Color(0.2, 1.0, 0.2, 0.5)  # Green = correct
			elif has_wall_blocks:
				color = Color(1.0, 1.0, 0.2, 0.5)  # Yellow = layer ok but 0 shapes

		# Draw wireframe cube only for blocks within 15m of camera
		var xform: Transform3D = child.global_transform
		if is_wall:
			var hp_dict: Dictionary = child.get("_block_hp_dict")
			if hp_dict:
				for key: Vector3i in hp_dict:
					var local_pos: Vector3 = child._block_local_pos(key)
					var world_pos: Vector3 = xform * local_pos
					if cam_pos.distance_squared_to(world_pos) <= HITBOX_RANGE_SQ:
						_draw_wire_box_xform(im, xform, local_pos, half, color)
		elif is_cluster:
			var grid = child.get("grid")
			if grid:
				for key: Vector3i in grid.block_hp:
					var local_pos: Vector3 = grid.block_local_pos(key)
					var world_pos: Vector3 = xform * local_pos
					if cam_pos.distance_squared_to(world_pos) <= HITBOX_RANGE_SQ:
						_draw_wire_box_xform(im, xform, local_pos, half, color)

		# Tiny label per structure
		var label: Label3D
		if _layer_labels.has(id) and is_instance_valid(_layer_labels[id]):
			label = _layer_labels[id]
		else:
			label = Label3D.new()
			label.name = "DebugLayerLbl_%d" % id
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.font_size = 24
			label.outline_size = 6
			label.pixel_size = 0.004
			label.outline_modulate = Color.BLACK
			scene_root.add_child(label)
			_layer_labels[id] = label

		var type_char := "W" if is_wall else "C"
		var hit_layer := 0
		if hit_body and is_instance_valid(hit_body):
			hit_layer = hit_body.collision_layer
		var lbl := "[%s] %s  hit:%d  %dshp" % [type_char, child.name, hit_layer, active_shapes]
		if hit_body == null or (hit_body != null and not is_instance_valid(hit_body)):
			lbl += "  !!NO HIT BODY"
		elif not has_wall_blocks:
			lbl += "  !!MISSING WALL_BLOCKS"
		if is_cluster:
			if child.freeze:
				lbl += "  frozen"
		label.text = lbl
		label.modulate = color
		label.global_position = child.global_position + Vector3(0, 3.0, 0)

	im.surface_end()

	# Remove stale labels (for structures that moved out of range or were freed)
	var to_remove: Array = []
	for id in _layer_labels:
		if not seen.has(id):
			to_remove.append(id)
	for id in to_remove:
		if is_instance_valid(_layer_labels[id]):
			_layer_labels[id].queue_free()
		_layer_labels.erase(id)


func _draw_wire_box_xform(im: ImmediateMesh, xform: Transform3D, local_center: Vector3, h: float, color: Color) -> void:
	## Draw wireframe box transformed by xform so it rotates with the structure.
	var c0 := xform * (local_center + Vector3(-h, -h, -h))
	var c1 := xform * (local_center + Vector3( h, -h, -h))
	var c2 := xform * (local_center + Vector3( h, -h,  h))
	var c3 := xform * (local_center + Vector3(-h, -h,  h))
	var c4 := xform * (local_center + Vector3(-h,  h, -h))
	var c5 := xform * (local_center + Vector3( h,  h, -h))
	var c6 := xform * (local_center + Vector3( h,  h,  h))
	var c7 := xform * (local_center + Vector3(-h,  h,  h))
	for edge: Array in [[c0,c1],[c1,c2],[c2,c3],[c3,c0],
			[c4,c5],[c5,c6],[c6,c7],[c7,c4],
			[c0,c4],[c1,c5],[c2,c6],[c3,c7]]:
		im.surface_set_color(color)
		im.surface_add_vertex(edge[0])
		im.surface_set_color(color)
		im.surface_add_vertex(edge[1])


func _clear_structure_layer_labels() -> void:
	for label in _layer_labels.values():
		if is_instance_valid(label):
			label.queue_free()
	_layer_labels.clear()
	if _hitbox_mesh_node and is_instance_valid(_hitbox_mesh_node):
		_hitbox_mesh_node.queue_free()
		_hitbox_mesh_node = null
	_layer_overlay_timer = 0.0


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


# ── Structure collision scale helpers ────────────────────────────────────

func _add_scale_input(label_text: String, initial_value: float,
		submit_callback: Callable, focus_callback: Callable,
		parent: Control) -> LineEdit:
	## Build a labeled LineEdit row for a float scale value. Returns the LineEdit.
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)
	var input := LineEdit.new()
	input.custom_minimum_size = Vector2(80, 0)
	input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	input.text = "%.1f" % initial_value
	input.text_submitted.connect(submit_callback)
	input.focus_exited.connect(focus_callback)
	hbox.add_child(input)
	parent.add_child(hbox)
	return input


func _on_momentum_damage_submitted(text: String) -> void:
	var val := clampf(text.to_float(), 0.0, 10.0)
	GameManager.structure_momentum_damage_scale = val
	_momentum_damage_input.text = "%.1f" % val
	print("[PauseMenu] Momentum damage scale set to %.1f" % val)

func _on_momentum_damage_focus_lost() -> void:
	if _momentum_damage_input:
		_on_momentum_damage_submitted(_momentum_damage_input.text)


func _on_explosion_radius_submitted(text: String) -> void:
	var val := clampf(text.to_float(), 0.0, 10.0)
	GameManager.structure_explosion_radius_scale = val
	_explosion_radius_input.text = "%.1f" % val
	print("[PauseMenu] Explosion radius scale set to %.1f" % val)

func _on_explosion_radius_focus_lost() -> void:
	if _explosion_radius_input:
		_on_explosion_radius_submitted(_explosion_radius_input.text)


func _on_explosion_damage_submitted(text: String) -> void:
	var val := clampf(text.to_float(), 0.0, 10.0)
	GameManager.structure_explosion_damage_scale = val
	_explosion_damage_input.text = "%.1f" % val
	print("[PauseMenu] Explosion damage scale set to %.1f" % val)

func _on_explosion_damage_focus_lost() -> void:
	if _explosion_damage_input:
		_on_explosion_damage_submitted(_explosion_damage_input.text)


func _on_resistance_scale_submitted(text: String) -> void:
	var val := clampf(text.to_float(), 0.0, 10.0)
	GameManager.structure_resistance_scale = val
	_resistance_scale_input.text = "%.1f" % val
	print("[PauseMenu] Resistance scale set to %.1f" % val)

func _on_resistance_scale_focus_lost() -> void:
	if _resistance_scale_input:
		_on_resistance_scale_submitted(_resistance_scale_input.text)


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


func _find_sun() -> DirectionalLight3D:
	var sun := get_tree().current_scene.get_node_or_null("SeedWorld/Sun")
	if sun == null:
		sun = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Sun")
	return sun


func _on_no_shadows_toggled(pressed: bool) -> void:
	GameManager.debug_no_shadows = pressed
	var sun := _find_sun()
	if sun:
		sun.shadow_enabled = not pressed


func _on_hide_clusters_toggled(pressed: bool) -> void:
	GameManager.debug_hide_clusters = pressed
	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		for s in structures.get_children():
			if s is FallingBlockCluster:
				s.visible = not pressed


func _on_shadow_distance_changed(text: String) -> void:
	var sun := _find_sun()
	if sun:
		sun.directional_shadow_max_distance = float(text)
		print("[RenderDebug] Shadow distance = %s" % text)
