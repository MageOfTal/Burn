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
var action_aim := false  ## Right-click ADS (held)
var action_extend := false  ## F key: spend fuel to extend equipped item's lifespan
var action_scrap := false  ## X key: scrap nearby ground item or equipped item into fuel
var action_marker := false  ## MMB: place/remove compass marker
## Weapon slot selection (1-6, 0 = no change this frame).
var action_slot := 0
## Inventory UI state — when open, gameplay inputs are zeroed and mouse is freed.
var inventory_open := false

## When true, this PlayerInput is driven by BotBrain — skip all keyboard/mouse handling.
var is_bot := false

const MOUSE_SENSITIVITY := 0.002

## Accumulated mouse delta this frame (reset each physics tick).
var _mouse_delta := Vector2.ZERO


func _ready() -> void:
	# Capture mouse immediately once we know we're the authority.
	# Use call_deferred so multiplayer authority is set first (player.gd _ready runs first).
	_try_capture_mouse.call_deferred()


func _try_capture_mouse() -> void:
	if is_bot:
		return  # Bots don't capture the mouse
	if is_multiplayer_authority():
		# Skip capture if loading screen is still up — _on_loading_screen_hidden()
		# will capture the mouse once the loading screen is removed.
		if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
			return
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event: InputEvent) -> void:
	if is_bot:
		return  # Bot input is set by BotBrain, not keyboard
	# Use _input (not _unhandled_input) so mouse motion is never blocked
	if not is_multiplayer_authority():
		return
	# Don't process input while pause menu is open
	if has_node("/root/PauseMenu") and get_node("/root/PauseMenu").is_open:
		return

	# Toggle inventory with Tab key
	if event.is_action_pressed("inventory_toggle"):
		inventory_open = not inventory_open
		if inventory_open:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		return  # Don't process anything else on the toggle frame

	# When inventory is open, ignore mouse motion for camera control
	if inventory_open:
		return

	if event is InputEventMouseMotion:
		_mouse_delta += event.relative

	# Escape is handled by PauseMenu autoload — no longer release mouse here.

	# Any mouse click re-captures if needed (but does NOT consume the event,
	# so the click still registers as shoot/pickup/etc.)
	# Skip re-capture when inventory is open so UI buttons remain clickable.
	if event is InputEventMouseButton and event.pressed and not inventory_open:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _physics_process(_delta: float) -> void:
	if is_bot:
		return  # BotBrain writes inputs directly; skip keyboard polling
	if not is_multiplayer_authority():
		return
	# Don't poll keyboard while pause menu is open
	if has_node("/root/PauseMenu") and get_node("/root/PauseMenu").is_open:
		input_direction = Vector2.ZERO
		action_jump = false
		action_shoot = false
		action_slot = 0
		_mouse_delta = Vector2.ZERO
		return

	# When inventory is open, zero all gameplay inputs
	if inventory_open:
		input_direction = Vector2.ZERO
		action_jump = false
		action_shoot = false
		action_pickup = false
		action_slide = false
		action_aim = false
		action_extend = false
		action_scrap = false
		action_marker = false
		action_slot = 0
		_mouse_delta = Vector2.ZERO
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
	action_aim = Input.is_action_pressed("aim")
	action_extend = Input.is_action_just_pressed("extend_item")
	action_scrap = Input.is_action_just_pressed("scrap_item")
	action_marker = Input.is_action_just_pressed("place_marker")

	# Weapon slot keys (1-6)
	action_slot = 0
	for i in range(1, 7):
		if Input.is_action_just_pressed("slot_%d" % i):
			action_slot = i
			break
