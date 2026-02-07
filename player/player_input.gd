extends Node

## Captures local player input and exposes it as synced properties.
## The InputSync MultiplayerSynchronizer reads these properties and
## sends them to the server. Only the owning client writes to these.

## Movement direction (WASD mapped to Vector2).
var input_direction := Vector2.ZERO
## Camera yaw (horizontal look).
var look_yaw := 0.0
## Camera pitch (vertical look).
var look_pitch := 0.0
## Action flags — true on the frame the action is pressed.
var action_jump := false
var action_shoot := false
var action_pickup := false
var action_slide := false
## Weapon slot selection (1-6, 0 = no change this frame).
var action_slot := 0

const MOUSE_SENSITIVITY := 0.002

## Accumulated mouse delta this frame (reset each physics tick).
var _mouse_delta := Vector2.ZERO


func _ready() -> void:
	# Capture mouse immediately once we know we're the authority.
	# Use call_deferred so multiplayer authority is set first (player.gd _ready runs first).
	_try_capture_mouse.call_deferred()


func _try_capture_mouse() -> void:
	if is_multiplayer_authority():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	# Use _input (not _unhandled_input) so mouse motion is never blocked
	if not is_multiplayer_authority():
		return

	if event is InputEventMouseMotion:
		_mouse_delta += event.relative

	# Escape releases mouse
	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# Any mouse click re-captures if needed (but does NOT consume the event,
	# so the click still registers as shoot/pickup/etc.)
	if event is InputEventMouseButton and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return

	# Movement
	input_direction = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Look — accumulate mouse motion into yaw/pitch
	look_yaw -= _mouse_delta.x * MOUSE_SENSITIVITY
	look_pitch -= _mouse_delta.y * MOUSE_SENSITIVITY
	look_pitch = clampf(look_pitch, -1.48, 1.2)
	_mouse_delta = Vector2.ZERO

	# Actions (pressed this frame)
	action_jump = Input.is_action_just_pressed("jump")
	action_shoot = Input.is_action_pressed("shoot")
	action_pickup = Input.is_action_just_pressed("pickup")
	action_slide = Input.is_action_pressed("slide")

	# Weapon slot keys (1-6)
	action_slot = 0
	for i in range(1, 7):
		if Input.is_action_just_pressed("slot_%d" % i):
			action_slot = i
			break
