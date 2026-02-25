extends Node

## Debug free camera — toggled with F3.
##
## When active:
##   - Freezes game via Engine.time_scale = 0.0 (NOT tree pause)
##   - Spawns a Camera3D at the player camera's position
##   - WASD + mouse to fly, Space = up, Ctrl = down, Shift = fast
##   - Right Arrow = advance simulation by one full frame with normal timing
##
## Uses Engine.time_scale instead of get_tree().paused so that frame advance
## gets correct deltas (~16ms). Tree pause accumulates wall-clock time during
## the pause, giving tweens/timers a multi-second delta on resume — causing
## them to complete instantly instead of advancing frame-by-frame.
## With time_scale = 0.0, delta is always 0 while paused. Setting
## time_scale = 1.0 for one frame gives everything a natural ~16ms delta.

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

## Frame advance: true while waiting for the advance frame to execute.
## Set in _input (frame N). Godot reads time_scale before _input, so the
## actual advance runs on frame N+1 when time_scale=1.0 takes effect.
var _advance_pending := false
var _saved_max_physics_steps := 8

## Manual real-time delta for camera movement.
## Engine.time_scale = 0.0 zeroes all deltas, so the camera computes its own.
var _last_cam_us: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	# F3 toggles freecam (F5-F12 are reserved by Godot editor debugger)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F3:
			_toggle()
			get_viewport().set_input_as_handled()
			return
		# Right Arrow = advance one full frame while paused
		if is_active and event.physical_keycode == KEY_RIGHT and not _advance_pending:
			_begin_tick_step()
			get_viewport().set_input_as_handled()
			return

	# While active, capture mouse motion
	if is_active and event is InputEventMouseMotion:
		_mouse_delta += event.relative
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	# With time_scale = 0.0, _physics_process never fires (no accumulated time).
	# It only fires during frame advance (time_scale = 1.0).
	# Record the start time here for accurate frame-time measurement.
	if _advance_pending:
		GameManager.frame_advance_start_us = Time.get_ticks_usec()


func _process(delta: float) -> void:
	if not is_active or _cam == null:
		return

	# Real-time delta for camera movement (unaffected by Engine.time_scale).
	var now_us := Time.get_ticks_usec()
	var cam_delta: float
	if _last_cam_us > 0:
		cam_delta = clampf(float(now_us - _last_cam_us) / 1000000.0, 0.0, 0.1)
	else:
		cam_delta = 0.016
	_last_cam_us = now_us

	# Frame advance: detect the advance frame.
	# On frame N (when _begin_tick_step was called), delta is still 0 because
	# Godot computed it with the old time_scale before _input ran.
	# On frame N+1, time_scale = 1.0 is in effect so delta > 0.
	if _advance_pending and delta > 0.001:
		_advance_pending = false
		_do_repause.call_deferred()

	# Mouse look
	_yaw -= _mouse_delta.x * MOUSE_SENSITIVITY
	_pitch -= _mouse_delta.y * MOUSE_SENSITIVITY
	_pitch = clampf(_pitch, -PI / 2.0, PI / 2.0)
	_mouse_delta = Vector2.ZERO

	_cam.rotation = Vector3(_pitch, _yaw, 0.0)

	# WASD + Space/Ctrl movement (uses real delta, not engine-scaled delta)
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
	_cam.global_position += move * speed * cam_delta


func _do_repause() -> void:
	Engine.time_scale = 0.0
	GameManager.debug_freecam_active = true
	GameManager.frame_advance_start_us = 0
	Engine.max_physics_steps_per_frame = _saved_max_physics_steps


func _begin_tick_step() -> void:
	# Set time_scale = 1.0 so the next frame gets a real delta (~16ms).
	# max_physics_steps = 1 prevents catch-up ticks from residual accumulator time.
	#
	# Timeline:
	#   Frame N (_input runs here):
	#     Delta was already computed with time_scale=0 → delta=0.
	#     We set time_scale=1.0, but this frame still uses delta=0.
	#     No physics ticks fire. _process(0.0) runs; _advance_pending true
	#     but delta ≤ 0.001 so no repause yet.
	#   Frame N+1:
	#     Delta computed with time_scale=1.0 → delta≈16ms.
	#     Physics: 1 tick fires (max_steps=1). Game nodes process. ✓
	#     _process: autoload detects delta>0.001, defers repause.
	#              Game nodes' _process runs normally. Tweens advance. ✓
	#     Deferred: _do_repause() → time_scale=0. ✓
	#     Render. ✓
	_advance_pending = true
	Engine.max_physics_steps_per_frame = 1
	GameManager.debug_freecam_active = false
	Engine.time_scale = 1.0


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
	_saved_max_physics_steps = Engine.max_physics_steps_per_frame
	_last_cam_us = Time.get_ticks_usec()

	# Spawn camera at player camera position/rotation
	var player_cam: Camera3D = local_player.camera
	_cam = Camera3D.new()
	_cam.fov = player_cam.fov
	_cam.cull_mask = player_cam.cull_mask
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

	# Freeze game time. Uses time_scale instead of tree pause so frame advance
	# gets correct deltas (tweens/particles advance naturally per step).
	Engine.time_scale = 0.0

	# Show HUD label
	_label = Label.new()
	_label.text = "FREECAM [PAUSED] (F3 to exit) — WASD fly, Space up, Ctrl down, Shift fast, Right Arrow = step 1 frame"
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
	_advance_pending = false
	GameManager.debug_freecam_active = false
	GameManager.frame_advance_start_us = 0

	# Restore normal time
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = _saved_max_physics_steps

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


func _find_local_player() -> Player:
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim and toad_dim.has_method("find_player_anywhere"):
		var p: Player = toad_dim.find_player_anywhere(multiplayer.get_unique_id())
		if p:
			return p
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var players := scene.get_node_or_null("Players")
	if players == null:
		return null
	var local_id := multiplayer.get_unique_id()
	var player_node := players.get_node_or_null(str(local_id))
	if player_node and player_node is Player:
		return player_node
	return null
