extends SpringArm3D

## Third-person camera with collision handling, asymmetric lerp, and player fade.
##
## SpringArm3D's built-in collision pulls the camera in when it would clip
## through walls.  This script adds:
##   1. Asymmetric smoothing — fast pull-in (near-instant), slow ease-out
##   2. Distance-based player fade — dithered dissolve when camera is close
##   3. Minimum camera distance — clamps at 0.5m, fades player instead
##
## The player mesh uses a dithered dissolve shader (`player_dissolve.gdshader`)
## whose `alpha_fade` uniform is driven by this script.

## Desired (max) camera distance — set by ADS or default.
## CombatVFX writes to this when toggling ADS; otherwise it stays at default.
var target_length: float = 2.2

## Current smoothed length (what we actually position the camera at).
var _current_length: float = 2.2

## Asymmetric speeds (exponential decay rates)
const PULL_IN_SPEED := 30.0    ## Near-instant pull-in when collision detected
const PUSH_OUT_SPEED := 4.0    ## Gentle ease-out when collision clears

## Player fade thresholds (camera distance in meters)
const FADE_START_DIST := 1.5   ## Start fading at this distance
const FADE_END_DIST := 0.5     ## Fully transparent at this distance
const FADE_SPEED := 12.0       ## Lerp speed for smooth fade transitions
const MIN_CAMERA_DIST := 0.3   ## Never let camera go closer than this

var _fade_alpha: float = 1.0

## Cache the player reference (two levels up: SpringArm3D -> CameraPivot -> Player)
var _player: CharacterBody3D = null
var _camera: Camera3D = null


func _ready() -> void:
	_player = get_parent().get_parent()
	if _player is CollisionObject3D:
		add_excluded_object(_player.get_rid())

	# Duplicate the dissolve material so each player instance has its own copy.
	# Without this, all players would share the same ShaderMaterial and fading
	# one player's mesh would fade all of them.
	if _player and _player.has_node("BodyMesh"):
		var bm: MeshInstance3D = _player.get_node("BodyMesh")
		if bm.material_override:
			bm.material_override = bm.material_override.duplicate()

	# Use a sphere shape instead of a thin ray — prevents the camera from
	# slipping through cracks between wall blocks and around edges.
	var sweep_shape := SphereShape3D.new()
	sweep_shape.radius = 0.3
	shape = sweep_shape

	# Margin pushes the camera inward on top of the shape radius.
	margin = 0.15

	# Only collide with world geometry
	collision_mask = 1

	target_length = spring_length
	_current_length = spring_length

	# Cache camera child
	for child in get_children():
		if child is Camera3D:
			_camera = child
			break


func _physics_process(delta: float) -> void:
	# Set spring_length to our desired max so SpringArm3D does the full sweep
	spring_length = target_length

	# get_hit_length() returns the actual distance after collision detection
	var hit_length := get_hit_length()

	# Clamp to minimum distance
	hit_length = maxf(hit_length, MIN_CAMERA_DIST)

	# Asymmetric smoothing: snap in fast, ease out slowly
	var speed: float
	if hit_length < _current_length - 0.01:
		speed = PULL_IN_SPEED
	else:
		speed = PUSH_OUT_SPEED

	_current_length = lerpf(_current_length, hit_length, 1.0 - exp(-speed * delta))

	# Override the camera child's Z position (SpringArm3D places it at hit_length,
	# but we want our smoothed value)
	if _camera:
		_camera.position.z = _current_length

	# Update player mesh fade based on camera distance
	_update_player_fade(delta)


func _update_player_fade(delta: float) -> void:
	if _player == null:
		return
	# Only fade the LOCAL player's own mesh
	if _player.peer_id != _player.multiplayer.get_unique_id():
		return

	# Calculate target alpha based on camera distance
	var target_alpha: float
	if _current_length <= FADE_END_DIST:
		target_alpha = 0.0
	elif _current_length >= FADE_START_DIST:
		target_alpha = 1.0
	else:
		target_alpha = (_current_length - FADE_END_DIST) / (FADE_START_DIST - FADE_END_DIST)

	_fade_alpha = lerpf(_fade_alpha, target_alpha, 1.0 - exp(-FADE_SPEED * delta))

	# Apply to body mesh shader
	var mesh: MeshInstance3D = _player.body_mesh
	if mesh:
		var mat := mesh.material_override
		if mat is ShaderMaterial:
			mat.set_shader_parameter("alpha_fade", _fade_alpha)

	# Apply to weapon mount children (so the gun fades too)
	var wm: Node3D = _player.weapon_mount
	if wm:
		for child in wm.get_children():
			if child is MeshInstance3D:
				_apply_fade_to_mesh(child)
			# Gun models are usually a scene root with MeshInstance3D children
			for grandchild in child.get_children():
				if grandchild is MeshInstance3D:
					_apply_fade_to_mesh(grandchild)


func _apply_fade_to_mesh(mesh: MeshInstance3D) -> void:
	## Apply fade to a mesh by creating or updating a dissolve material override.
	## For weapon models we clone the dissolve shader onto them on first encounter.
	var mat := mesh.material_override
	if mat is ShaderMaterial and mat.shader != null:
		mat.set_shader_parameter("alpha_fade", _fade_alpha)
		return

	# If no dissolve shader yet, create one from the same shader as the body mesh
	if _player.body_mesh and _player.body_mesh.material_override is ShaderMaterial:
		var source_shader: Shader = (_player.body_mesh.material_override as ShaderMaterial).shader
		if source_shader:
			var new_mat := ShaderMaterial.new()
			new_mat.shader = source_shader
			# Copy the base color from the existing material if possible
			var existing_mat := mesh.get_active_material(0)
			if existing_mat is StandardMaterial3D:
				new_mat.set_shader_parameter("albedo_color", existing_mat.albedo_color)
			else:
				new_mat.set_shader_parameter("albedo_color", Color(0.6, 0.6, 0.6, 1.0))
			new_mat.set_shader_parameter("alpha_fade", _fade_alpha)
			mesh.material_override = new_mat
