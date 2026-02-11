extends Node

## Debug free camera — toggled with F3.
##
## When active:
##   - Sets GameManager.debug_freecam_active = true (player skips physics)
##   - Spawns a Camera3D at the player camera's position
##   - WASD + mouse to fly, Space = up, Ctrl = down, Shift = fast
##   - Grapple rope + pill visuals keep rendering (frozen state)
##
## When deactivated:
##   - Restores player camera
##   - Sets flag back to false so player resumes normal play

const FLY_SPEED := 15.0
const FLY_SPEED_FAST := 45.0
const MOUSE_SENSITIVITY := 0.002

var is_active := false
var _cam: Camera3D = null
var _yaw := 0.0
var _pitch := 0.0
var _mouse_delta := Vector2.ZERO

## HUD label shown while freecam is active
var _label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	# F3 toggles freecam (F5-F12 are reserved by Godot editor debugger)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F3:
			_toggle()
			get_viewport().set_input_as_handled()
			return

	# While active, capture mouse motion
	if is_active and event is InputEventMouseMotion:
		_mouse_delta += event.relative
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not is_active or _cam == null:
		return

	# Mouse look
	_yaw -= _mouse_delta.x * MOUSE_SENSITIVITY
	_pitch -= _mouse_delta.y * MOUSE_SENSITIVITY
	_pitch = clampf(_pitch, -PI / 2.0, PI / 2.0)
	_mouse_delta = Vector2.ZERO

	_cam.rotation = Vector3(_pitch, _yaw, 0.0)

	# WASD + Space/Ctrl movement
	var forward := -_cam.global_transform.basis.z
	var right := _cam.global_transform.basis.x
	var up := Vector3.UP

	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move += forward
	if Input.is_physical_key_pressed(KEY_S):
		move -= forward
	if Input.is_physical_key_pressed(KEY_D):
		move += right
	if Input.is_physical_key_pressed(KEY_A):
		move -= right
	if Input.is_physical_key_pressed(KEY_SPACE):
		move += up
	if Input.is_physical_key_pressed(KEY_CTRL):
		move -= up

	var speed := FLY_SPEED_FAST if Input.is_physical_key_pressed(KEY_SHIFT) else FLY_SPEED

	if move.length() > 0.001:
		move = move.normalized()
	_cam.global_position += move * speed * delta


func _toggle() -> void:
	if is_active:
		_deactivate()
	else:
		_activate()


func _activate() -> void:
	# Find local player
	var local_player := _find_local_player()
	if local_player == null:
		print("[DebugFreecam] No local player found — cannot activate")
		return

	is_active = true
	GameManager.debug_freecam_active = true

	# Spawn camera at player camera position/rotation
	var player_cam: Camera3D = local_player.camera
	_cam = Camera3D.new()
	_cam.fov = player_cam.fov
	_cam.global_position = player_cam.global_position
	_cam.top_level = true
	_cam.process_mode = Node.PROCESS_MODE_ALWAYS

	# Copy orientation from camera pivot + spring arm
	_yaw = local_player.rotation.y
	_pitch = local_player.camera_pivot.rotation.x
	_cam.rotation = Vector3(_pitch, _yaw, 0.0)

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_cam)
	_cam.make_current()

	# Ensure mouse is captured for camera control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Show HUD label
	_label = Label.new()
	_label.text = "FREECAM (F3 to exit) — WASD fly, Space up, Ctrl down, Shift fast"
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	_label.position = Vector2(20, 20)
	# Add to a CanvasLayer so it's always on top
	var canvas := CanvasLayer.new()
	canvas.layer = 99
	canvas.name = "FreecamHUD"
	canvas.process_mode = Node.PROCESS_MODE_ALWAYS
	if scene_root:
		scene_root.add_child(canvas)
	canvas.add_child(_label)

	print("[DebugFreecam] Activated — player frozen")


func _deactivate() -> void:
	is_active = false
	GameManager.debug_freecam_active = false

	# Restore player camera
	var local_player := _find_local_player()
	if local_player and local_player.camera:
		local_player.camera.make_current()

	# Clean up freecam
	if _cam and is_instance_valid(_cam):
		_cam.queue_free()
		_cam = null

	# Clean up HUD
	var scene_root := get_tree().current_scene
	if scene_root:
		var hud := scene_root.get_node_or_null("FreecamHUD")
		if hud:
			hud.queue_free()
	_label = null

	# Re-capture mouse for gameplay
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	print("[DebugFreecam] Deactivated — player resumed")


func _find_local_player() -> CharacterBody3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var players := scene.get_node_or_null("Players")
	if players == null:
		return null
	var local_id := multiplayer.get_unique_id()
	var player_node := players.get_node_or_null(str(local_id))
	if player_node and player_node is CharacterBody3D:
		return player_node
	return null
