extends Node
class_name CombatVFX

## Weapon visual effects subsystem.
## Owns tracer lines, muzzle flashes, melee arcs, ADS visuals, and scope overlay.
## Attached as a child of Player in player.tscn.

## --- ADS constants ---
const DEFAULT_FOV := 70.0
const ADS_LERP_SPEED := 12.0         ## How fast FOV/spring transitions
const ADS_SPRING_LENGTH := 1.0       ## Camera pulls closer when aiming
const DEFAULT_SPRING_LENGTH := 2.2

## State
var _scope_overlay: ColorRect = null

## Player reference
var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p


## ======================================================================
##  RPCs: weapon visual effects (run on all clients)
## ======================================================================

@rpc("authority", "call_local", "unreliable")
func show_melee_swing_fx(from_pos: Vector3, swing_dir: Vector3) -> void:
	## Visual effect: wide green arc sweep for melee weapons.
	var im := ImmediateMesh.new()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = im
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 1.0, 0.3, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.8, 0.2)
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var reach := 3.5
	var arc_half_angle := deg_to_rad(60.0)
	var segments := 10
	var arc_height := 0.8

	var flat_dir := Vector3(swing_dir.x, 0.0, swing_dir.z).normalized()
	if flat_dir.length_squared() < 0.01:
		flat_dir = Vector3.FORWARD

	# Top face
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var angle := lerpf(-arc_half_angle, arc_half_angle, t)
		var rotated_dir := flat_dir.rotated(Vector3.UP, angle)
		var inner := from_pos + rotated_dir * (reach * 0.15)
		var tip := from_pos + rotated_dir * reach
		im.surface_add_vertex(inner + Vector3.UP * arc_height * 0.5)
		im.surface_add_vertex(tip + Vector3.UP * arc_height * 0.5)
	im.surface_end()

	# Bottom face for thickness
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var angle := lerpf(-arc_half_angle, arc_half_angle, t)
		var rotated_dir := flat_dir.rotated(Vector3.UP, angle)
		var inner := from_pos + rotated_dir * (reach * 0.15)
		var tip := from_pos + rotated_dir * reach
		im.surface_add_vertex(inner - Vector3.UP * arc_height * 0.5)
		im.surface_add_vertex(tip - Vector3.UP * arc_height * 0.5)
	im.surface_end()

	get_tree().current_scene.add_child(mesh_inst)

	var tween := player.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.25)
	tween.tween_callback(mesh_inst.queue_free)


@rpc("authority", "call_local", "unreliable")
func show_shot_fx(from_pos: Vector3, to_pos: Vector3) -> void:
	## Visual effect: tracer line + muzzle flash + fire sound.
	_play_fire_sound()

	# Tracer line
	var tracer := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	tracer.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.3, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from_pos)
	im.surface_add_vertex(to_pos)
	im.surface_end()

	tracer.top_level = true
	player.add_child(tracer)

	# Muzzle flash light
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.3)
	flash.light_energy = 5.0
	flash.omni_range = 3.0
	flash.top_level = true
	player.add_child(flash)
	flash.global_position = from_pos

	var tween := get_tree().create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.1)
	tween.parallel().tween_property(flash, "light_energy", 0.0, 0.08)
	tween.tween_callback(tracer.queue_free)
	tween.tween_callback(flash.queue_free)


@rpc("authority", "call_local", "unreliable")
func show_shotgun_fx(from_pos: Vector3, shot_ends: Array[Vector3]) -> void:
	## Visual effect for multi-pellet weapons: multiple tracer lines + muzzle flash + fire sound.
	_play_fire_sound()

	# Draw all pellet tracers in a single ImmediateMesh
	var tracer := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	tracer.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.3, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for end_pos in shot_ends:
		im.surface_add_vertex(from_pos)
		im.surface_add_vertex(end_pos)
	im.surface_end()

	tracer.top_level = true
	player.add_child(tracer)

	# Muzzle flash light (brighter for shotguns)
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.3)
	flash.light_energy = 8.0
	flash.omni_range = 4.0
	flash.top_level = true
	player.add_child(flash)
	flash.global_position = from_pos

	var tween := get_tree().create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.12)
	tween.parallel().tween_property(flash, "light_energy", 0.0, 0.1)
	tween.tween_callback(tracer.queue_free)
	tween.tween_callback(flash.queue_free)


## ======================================================================
##  Shared fire sound helper
## ======================================================================

func _play_fire_sound() -> void:
	## Play fire sound with overlap support.
	## If the stream hasn't been loaded yet (RPC arrived before ServerSync
	## delivered the sound path), load it on-demand from the synced path.
	if player.fire_sound_player == null:
		return
	if player.fire_sound_player.stream == null and player.equipped_fire_sound_path != "":
		if ResourceLoader.exists(player.equipped_fire_sound_path):
			player.fire_sound_player.stream = load(player.equipped_fire_sound_path)
			player._last_synced_fire_sound_path = player.equipped_fire_sound_path
	if player.fire_sound_player.stream == null:
		return
	if player.fire_sound_player.playing:
		var one_shot := AudioStreamPlayer3D.new()
		one_shot.stream = player.fire_sound_player.stream
		one_shot.max_distance = 60.0
		one_shot.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		one_shot.top_level = true
		player.add_child(one_shot)
		one_shot.global_position = player.global_position
		one_shot.play()
		one_shot.finished.connect(one_shot.queue_free)
	else:
		player.fire_sound_player.play()


## ======================================================================
##  ADS visuals + scope overlay (client-side)
## ======================================================================

func process_ads_visuals(delta: float, is_aiming: bool, w_data: WeaponData) -> void:
	## Client-side: smooth FOV zoom, spring arm pull-in, and scope overlay for ADS.
	var base_fov := DEFAULT_FOV
	if player.has_node("/root/PauseMenu"):
		base_fov = player.get_node("/root/PauseMenu")._settings.get("fov", DEFAULT_FOV)
	var target_fov := base_fov
	var target_spring := DEFAULT_SPRING_LENGTH
	var show_scope := false

	if is_aiming and w_data and w_data.ads_fov > 0.0:
		target_fov = w_data.ads_fov
		target_spring = ADS_SPRING_LENGTH
		show_scope = w_data.has_scope

	# Smooth FOV transition
	player.camera.fov = lerpf(player.camera.fov, target_fov, ADS_LERP_SPEED * delta)
	# Smooth spring arm transition
	player.spring_arm.spring_length = lerpf(player.spring_arm.spring_length, target_spring, ADS_LERP_SPEED * delta)

	# Scope overlay
	update_scope_overlay(show_scope, delta)


func update_scope_overlay(scope_visible: bool, delta: float) -> void:
	## Show/hide the scope overlay vignette when ADS with a scoped weapon.
	if scope_visible and _scope_overlay == null:
		_scope_overlay = ColorRect.new()
		_scope_overlay.color = Color(0, 0, 0, 0.0)
		_scope_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_scope_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var scope_hud := player.get_node_or_null("HUDLayer")
		if scope_hud:
			scope_hud.add_child(_scope_overlay)
			# Crosshair lines
			var h_line := ColorRect.new()
			h_line.color = Color(0, 0, 0, 0.8)
			h_line.set_anchors_preset(Control.PRESET_CENTER)
			h_line.custom_minimum_size = Vector2(300, 1)
			h_line.position = Vector2(-150, 0)
			h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_scope_overlay.add_child(h_line)
			var v_line := ColorRect.new()
			v_line.color = Color(0, 0, 0, 0.8)
			v_line.set_anchors_preset(Control.PRESET_CENTER)
			v_line.custom_minimum_size = Vector2(1, 300)
			v_line.position = Vector2(0, -150)
			v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_scope_overlay.add_child(v_line)

	if _scope_overlay:
		var target_alpha := 0.6 if scope_visible else 0.0
		_scope_overlay.color.a = lerpf(_scope_overlay.color.a, target_alpha, ADS_LERP_SPEED * delta)
		if not scope_visible and _scope_overlay.color.a < 0.01:
			_scope_overlay.queue_free()
			_scope_overlay = null
