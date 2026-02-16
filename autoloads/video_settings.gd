extends Node

## Central video/graphics settings manager.
## Owns all settings state, handles save/load to disk, and applies
## settings to the Godot rendering pipeline (Viewport, Environment,
## RenderingServer, DirectionalLight3D).
##
## Autoloaded BEFORE PauseMenu so settings are available at startup.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION := "video"

# ── Settings with defaults that match pre-existing game behavior ──────────
var settings := {
	# Display
	"vsync": true,
	"fullscreen": true,
	"fov": 70.0,
	"render_scale": 1.0,
	"brightness": 1.0,

	# Anti-aliasing
	"msaa": 0,           # 0=Off, 1=2x, 2=4x, 3=8x
	"fxaa": false,
	"taa": false,

	# Shadows
	"shadow_quality": 2, # 0=Off, 1=Low, 2=Medium, 3=High
	"shadow_filter": 0,  # 0=Hard, 1=Soft Low, 2=Soft Medium, 3=Soft High

	# Post-processing
	"ssao_enabled": false,
	"ssao_quality": 1,   # 0=Low, 1=Medium, 2=High
	"ssil_enabled": false,
	"ssil_quality": 1,
	"ssr_enabled": false,
	"ssr_quality": 1,
	"glow_enabled": false,
	"glow_intensity": 0.5,

	# Fog
	"fog_enabled": true,
	"volumetric_fog": false,

	# GI
	"gi_mode": 0,        # 0=None, 1=SDFGI
}

# ── Presets ───────────────────────────────────────────────────────────────
const PRESET_LOW := {
	"vsync": true, "fullscreen": true, "fov": 70.0,
	"render_scale": 0.75, "brightness": 1.0,
	"msaa": 0, "fxaa": false, "taa": false,
	"shadow_quality": 1, "shadow_filter": 0,
	"ssao_enabled": false, "ssao_quality": 0,
	"ssil_enabled": false, "ssil_quality": 0,
	"ssr_enabled": false, "ssr_quality": 0,
	"glow_enabled": false, "glow_intensity": 0.5,
	"fog_enabled": true, "volumetric_fog": false,
	"gi_mode": 0,
}

const PRESET_MEDIUM := {
	"vsync": true, "fullscreen": true, "fov": 70.0,
	"render_scale": 1.0, "brightness": 1.0,
	"msaa": 1, "fxaa": false, "taa": false,
	"shadow_quality": 2, "shadow_filter": 1,
	"ssao_enabled": true, "ssao_quality": 1,
	"ssil_enabled": false, "ssil_quality": 0,
	"ssr_enabled": false, "ssr_quality": 0,
	"glow_enabled": true, "glow_intensity": 0.5,
	"fog_enabled": true, "volumetric_fog": false,
	"gi_mode": 0,
}

const PRESET_HIGH := {
	"vsync": true, "fullscreen": true, "fov": 70.0,
	"render_scale": 1.0, "brightness": 1.0,
	"msaa": 2, "fxaa": false, "taa": true,
	"shadow_quality": 3, "shadow_filter": 2,
	"ssao_enabled": true, "ssao_quality": 2,
	"ssil_enabled": true, "ssil_quality": 1,
	"ssr_enabled": true, "ssr_quality": 1,
	"glow_enabled": true, "glow_intensity": 0.8,
	"fog_enabled": true, "volumetric_fog": true,
	"gi_mode": 0,
}

const PRESET_ULTRA := {
	"vsync": true, "fullscreen": true, "fov": 70.0,
	"render_scale": 1.0, "brightness": 1.0,
	"msaa": 2, "fxaa": true, "taa": true,
	"shadow_quality": 3, "shadow_filter": 3,
	"ssao_enabled": true, "ssao_quality": 2,
	"ssil_enabled": true, "ssil_quality": 2,
	"ssr_enabled": true, "ssr_quality": 2,
	"glow_enabled": true, "glow_intensity": 1.0,
	"fog_enabled": true, "volumetric_fog": true,
	"gi_mode": 1,
}

const PRESETS := {
	"low": PRESET_LOW,
	"medium": PRESET_MEDIUM,
	"high": PRESET_HIGH,
	"ultra": PRESET_ULTRA,
}


func _ready() -> void:
	load_settings()
	# Apply viewport-level settings immediately (vsync, fullscreen, AA, render scale).
	# Environment-dependent settings (SSAO, SSR, etc.) are applied later when
	# seed_world.gd calls apply_all() after the WorldEnvironment enters the tree.
	apply_display()
	apply_anti_aliasing()


# ── Save / Load ──────────────────────────────────────────────────────────

func load_settings() -> void:
	var config := ConfigFile.new()
	var err := config.load(SETTINGS_PATH)
	if err != OK:
		return  # First run — use defaults
	for key in settings.keys():
		if config.has_section_key(SECTION, key):
			settings[key] = config.get_value(SECTION, key)


func save_settings() -> void:
	var config := ConfigFile.new()
	for key in settings.keys():
		config.set_value(SECTION, key, settings[key])
	config.save(SETTINGS_PATH)


# ── Apply All ────────────────────────────────────────────────────────────

func apply_all() -> void:
	apply_display()
	apply_anti_aliasing()
	apply_shadows()
	apply_post_processing()
	apply_fog()
	apply_gi()
	apply_fov()


# ── Display ──────────────────────────────────────────────────────────────

func apply_display() -> void:
	# VSync
	if settings["vsync"]:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	# Fullscreen
	if settings["fullscreen"]:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

	# Render scale
	get_viewport().scaling_3d_scale = settings["render_scale"]

	# Brightness (tonemap exposure)
	var env := _find_environment()
	if env:
		env.tonemap_exposure = settings["brightness"] * 0.9  # 0.9 is baseline


# ── Anti-Aliasing ────────────────────────────────────────────────────────

func apply_anti_aliasing() -> void:
	var vp := get_viewport()

	# MSAA
	match settings["msaa"]:
		0: vp.msaa_3d = Viewport.MSAA_DISABLED
		1: vp.msaa_3d = Viewport.MSAA_2X
		2: vp.msaa_3d = Viewport.MSAA_4X
		3: vp.msaa_3d = Viewport.MSAA_8X

	# FXAA
	if settings["fxaa"]:
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	else:
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED

	# TAA
	vp.use_taa = settings["taa"]


# ── Shadows ──────────────────────────────────────────────────────────────

func apply_shadows() -> void:
	var sun := _find_sun()

	# Shadow quality (atlas size + distance)
	if sun:
		match settings["shadow_quality"]:
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

	# Shadow filter quality (global RenderingServer setting)
	match settings["shadow_filter"]:
		0:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_HARD)
		1:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_LOW)
		2:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
		3:
			RenderingServer.directional_soft_shadow_filter_set_quality(
				RenderingServer.SHADOW_QUALITY_SOFT_HIGH)


# ── Post-Processing ─────────────────────────────────────────────────────

func apply_post_processing() -> void:
	var env := _find_environment()
	if env == null:
		return

	# --- SSAO ---
	env.ssao_enabled = settings["ssao_enabled"]
	if settings["ssao_enabled"]:
		env.ssao_radius = 1.0
		env.ssao_intensity = 2.0
		match settings["ssao_quality"]:
			0:  # Low
				env.ssao_power = 1.0
				RenderingServer.environment_set_ssao_quality(
					RenderingServer.ENV_SSAO_QUALITY_VERY_LOW, true, 0.5, 2, 50.0, 300.0)
			1:  # Medium
				env.ssao_power = 1.5
				RenderingServer.environment_set_ssao_quality(
					RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, 50.0, 300.0)
			2:  # High
				env.ssao_power = 2.0
				RenderingServer.environment_set_ssao_quality(
					RenderingServer.ENV_SSAO_QUALITY_HIGH, true, 0.5, 4, 50.0, 300.0)

	# --- SSIL ---
	env.ssil_enabled = settings["ssil_enabled"]
	if settings["ssil_enabled"]:
		env.ssil_radius = 5.0
		env.ssil_intensity = 1.0
		env.ssil_normal_rejection = 1.0
		match settings["ssil_quality"]:
			0:
				RenderingServer.environment_set_ssil_quality(
					RenderingServer.ENV_SSIL_QUALITY_VERY_LOW, true, 0.5, 2, 50.0, 300.0)
			1:
				RenderingServer.environment_set_ssil_quality(
					RenderingServer.ENV_SSIL_QUALITY_MEDIUM, true, 0.5, 2, 50.0, 300.0)
			2:
				RenderingServer.environment_set_ssil_quality(
					RenderingServer.ENV_SSIL_QUALITY_HIGH, true, 0.5, 4, 50.0, 300.0)

	# --- SSR ---
	env.ssr_enabled = settings["ssr_enabled"]
	if settings["ssr_enabled"]:
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.ssr_depth_tolerance = 0.2
		match settings["ssr_quality"]:
			0:
				env.ssr_max_steps = 8
			1:
				env.ssr_max_steps = 32
			2:
				env.ssr_max_steps = 64

	# --- Glow / Bloom ---
	env.glow_enabled = settings["glow_enabled"]
	if settings["glow_enabled"]:
		env.glow_intensity = settings["glow_intensity"]
		env.glow_bloom = 0.1
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
		env.glow_hdr_threshold = 1.0
		env.glow_hdr_scale = 2.0


# ── Fog ──────────────────────────────────────────────────────────────────

func apply_fog() -> void:
	var env := _find_environment()
	if env == null:
		return

	if settings["volumetric_fog"]:
		# Volumetric fog replaces flat fog
		env.fog_enabled = false
		env.volumetric_fog_enabled = true
		env.volumetric_fog_density = 0.01
		env.volumetric_fog_albedo = Color(0.5, 0.6, 0.75)
		env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env.volumetric_fog_length = 200.0
		env.volumetric_fog_detail_spread = 0.6
		env.volumetric_fog_ambient_inject = 0.0
	else:
		env.volumetric_fog_enabled = false
		env.fog_enabled = settings["fog_enabled"]


# ── Global Illumination ─────────────────────────────────────────────────

func apply_gi() -> void:
	var env := _find_environment()
	if env == null:
		return

	var use_sdfgi: bool = (settings["gi_mode"] == 1)
	env.sdfgi_enabled = use_sdfgi
	if use_sdfgi:
		env.sdfgi_use_occlusion = true
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.2
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_100_PERCENT


# ── FOV ──────────────────────────────────────────────────────────────────

func apply_fov() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera:
		camera.fov = settings["fov"]


# ── Presets ──────────────────────────────────────────────────────────────

func apply_preset(preset_name: String) -> void:
	var preset: Dictionary = PRESETS.get(preset_name, {})
	if preset.is_empty():
		push_warning("[VideoSettings] Unknown preset: %s" % preset_name)
		return
	for key in preset.keys():
		settings[key] = preset[key]
	apply_all()
	save_settings()


# ── Scene Lookups ────────────────────────────────────────────────────────

func _find_environment() -> Environment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var world_env := scene.get_node_or_null("WorldEnvironment")
	if world_env and world_env is WorldEnvironment:
		return world_env.environment
	for child in scene.get_children():
		if child is WorldEnvironment:
			return child.environment
	return null


func _find_sun() -> DirectionalLight3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var seed_world := scene.get_node_or_null("SeedWorld")
	if seed_world:
		for child in seed_world.get_children():
			if child is DirectionalLight3D:
				return child
	for child in scene.get_children():
		if child is DirectionalLight3D:
			return child
	return null
