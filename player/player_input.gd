extends Node

## Captures local player input and exposes it as synced properties.
## The InputSync MultiplayerSynchronizer reads these properties and
## sends them to the server. Only the owning client writes to these.
##
## ONE-SHOT ACTIONS use monotonic counters (jump_count, pickup_count, etc.)
## instead of booleans. Each press increments the counter by 1. The server
## compares against its last-consumed count to detect new presses. This
## prevents lost inputs over the network — booleans that flip true→false
## in a single frame are unreliable with ON_CHANGE replication.
##
## HELD ACTIONS (shoot, slide, aim, ctrl) remain booleans because they
## stay true across multiple frames while the key is held.

## Movement direction (WASD mapped to Vector2).
var input_direction := Vector2.ZERO
## Camera yaw (horizontal look).
var look_yaw := 0.0
## Camera pitch (vertical look).
var look_pitch := 0.0

## --- One-shot action counters (monotonically increasing) ---
## Server compares these against its _last_* trackers to detect presses.
var jump_count := 0       ## Space: jump
var pickup_count := 0     ## E: pickup item / open chest
var extend_count := 0     ## F: extend equipped item lifespan
var scrap_count := 0      ## X: scrap item into fuel
var marker_count := 0     ## MMB: place/remove compass marker (client-only)
var slot_count := 0       ## Weapon slot change event count
var slot_select := 0      ## Which slot (1-6) was last selected

## --- Held action booleans (true while key is held) ---
var action_shoot := false  ## Left-click: fire weapon
var action_slide := false  ## Shift: slide/crouch
var action_aim := false    ## Right-click: ADS
var action_ctrl := false   ## Ctrl: suppress grapple release boost
var action_forfeit := false  ## P: hold to forfeit (self-kill after 3s)

## Inventory UI state — when open, gameplay inputs are suppressed and mouse is freed.
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

	# Skip mouse capture when debug freecam is active
	if has_node("/root/GameManager") and get_node("/root/GameManager").debug_freecam_active:
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
	# Don't poll keyboard while debug freecam is active
	if has_node("/root/GameManager") and get_node("/root/GameManager").debug_freecam_active:
		_mouse_delta = Vector2.ZERO
		return
	# Don't poll keyboard while pause menu is open — zero held inputs only
	if has_node("/root/PauseMenu") and get_node("/root/PauseMenu").is_open:
		input_direction = Vector2.ZERO
		action_shoot = false
		action_forfeit = false
		_mouse_delta = Vector2.ZERO
		return

	# When inventory is open, zero held gameplay inputs (counters just don't increment)
	if inventory_open:
		input_direction = Vector2.ZERO
		action_shoot = false
		action_slide = false
		action_aim = false
		action_forfeit = false
		_mouse_delta = Vector2.ZERO
		return

	# Look — accumulate mouse motion into yaw/pitch (always active)
	look_yaw -= _mouse_delta.x * MOUSE_SENSITIVITY
	look_pitch -= _mouse_delta.y * MOUSE_SENSITIVITY
	look_pitch = clampf(look_pitch, -PI / 2.0, PI / 2.0)
	_mouse_delta = Vector2.ZERO

	# During kamikaze flight: only mouse look is active, all other inputs are ignored.
	# This prevents arrow keys, WASD, slot switches, etc. from doing anything mid-flight.
	var player_node := get_parent()
	if player_node and "kamikaze_system" in player_node and player_node.kamikaze_system.is_active():
		input_direction = Vector2.ZERO
		action_shoot = false
		action_slide = false
		action_aim = false
		action_forfeit = false
		return

	# Movement
	input_direction = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	# Held actions
	action_shoot = Input.is_action_pressed("shoot")
	action_slide = Input.is_action_pressed("slide")
	action_aim = Input.is_action_pressed("aim")
	action_ctrl = Input.is_key_pressed(KEY_CTRL)
	action_forfeit = Input.is_action_pressed("forfeit")

	# One-shot actions — increment counter on press (never reset to 0)
	if Input.is_action_just_pressed("jump"):
		jump_count += 1
	if Input.is_action_just_pressed("pickup"):
		pickup_count += 1
	if Input.is_action_just_pressed("extend_item"):
		extend_count += 1
	if Input.is_action_just_pressed("scrap_item"):
		scrap_count += 1
	if Input.is_action_just_pressed("place_marker"):
		marker_count += 1

	# Weapon slot keys (1-6) — increment counter + record which slot
	for i in range(1, 7):
		if Input.is_action_just_pressed("slot_%d" % i):
			slot_select = i
			slot_count += 1
			break
