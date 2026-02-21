extends Control

## Main menu: Host or Join a game.

@onready var address_input: LineEdit = $CenterContainer/VBoxContainer/AddressInput
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var username_input: LineEdit = $CenterContainer/VBoxContainer/UsernameInput
@onready var _burn_timers_check: CheckBox = $CenterContainer/VBoxContainer/DisableBurnTimers
@onready var _demon_check: CheckBox = $CenterContainer/VBoxContainer/DisableDemon
@onready var _zone_damage_check: CheckBox = $CenterContainer/VBoxContainer/DisableZoneDamage

var _connect_timer: float = 0.0
var _is_connecting := false
const CONNECT_TIMEOUT := 30.0  # Match ENet's internal timeout (~30s)


func _ready() -> void:
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)


func _process(delta: float) -> void:
	if _is_connecting:
		_connect_timer += delta
		var dots := ".".repeat(int(_connect_timer * 2) % 4)
		var peer_status := NetworkManager.get_peer_status_string()
		status_label.text = "Connecting%s (%.0fs)\nENet status: %s" % [dots, _connect_timer, peer_status]
		if _connect_timer >= CONNECT_TIMEOUT:
			_is_connecting = false
			status_label.text = "Connection timed out!\n- Is the server running?\n- Correct IP? (check host's Output panel)\n- Windows Firewall: allow Godot.exe for UDP\n- Both machines on same network?"
			NetworkManager.disconnect_game()


func _store_username() -> void:
	var username := username_input.text.strip_edges()
	if username.is_empty():
		username = "Player"
	GameManager.local_username = username


func _on_host_pressed() -> void:
	_store_username()
	print("[MainMenu] Host button pressed (username: %s)" % GameManager.local_username)
	var local_ip := NetworkManager.get_local_ip()
	var err := NetworkManager.host_game()
	if err != OK:
		print("[MainMenu] host_game() FAILED: %s" % error_string(err))
		status_label.text = "Failed to start server!"
	else:
		print("[MainMenu] host_game() OK — server on port %d, LAN IP: %s" % [NetConstants.DEFAULT_PORT, local_ip])
		status_label.text = "Server running on UDP port %d\nTell others to connect to: %s" % [NetConstants.DEFAULT_PORT, local_ip]


func _on_join_pressed() -> void:
	_store_username()
	var address := address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	print("[MainMenu] Join button pressed — connecting to %s:%d" % [address, NetConstants.DEFAULT_PORT])
	status_label.text = "Connecting to %s:%d..." % [address, NetConstants.DEFAULT_PORT]
	var err := NetworkManager.join_game(address)
	if err != OK:
		print("[MainMenu] join_game() FAILED: %s" % error_string(err))
		status_label.text = "Failed to connect!"
	else:
		print("[MainMenu] join_game() OK — waiting for connection...")
		_is_connecting = true
		_connect_timer = 0.0


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_connection_succeeded() -> void:
	_is_connecting = false
	status_label.text = "Connected!"


func _on_connection_failed() -> void:
	_is_connecting = false
	status_label.text = "Connection failed!\n- Is the server running?\n- Correct IP? (check host's Output panel)\n- Windows Firewall: allow Godot.exe for UDP"


# ---- Debug toggles ----

var _god_mode_updating := false  ## Prevents recursive toggling

func _on_god_mode_toggled(enabled: bool) -> void:
	_god_mode_updating = true
	GameManager.set_god_mode(enabled)
	_burn_timers_check.set_pressed_no_signal(enabled)
	_demon_check.set_pressed_no_signal(enabled)
	_zone_damage_check.set_pressed_no_signal(enabled)
	_god_mode_updating = false

func _on_burn_timers_toggled(enabled: bool) -> void:
	GameManager.debug_disable_burn_timers = enabled
	_sync_god_mode_check()

func _on_demon_toggled(enabled: bool) -> void:
	GameManager.debug_disable_demon = enabled
	_sync_god_mode_check()

func _on_zone_damage_toggled(enabled: bool) -> void:
	GameManager.debug_disable_zone_damage = enabled
	_sync_god_mode_check()

func _sync_god_mode_check() -> void:
	if _god_mode_updating:
		return
	var all_on := GameManager.debug_disable_burn_timers and GameManager.debug_disable_demon and GameManager.debug_disable_zone_damage
	GameManager.debug_god_mode = all_on
	var god_check: CheckBox = $CenterContainer/VBoxContainer/GodMode
	god_check.set_pressed_no_signal(all_on)

func _on_skip_structures_toggled(enabled: bool) -> void:
	GameManager.debug_skip_structures = enabled

func _on_disable_bots_toggled(enabled: bool) -> void:
	GameManager.debug_disable_bots = enabled

func _on_free_firing_toggled(enabled: bool) -> void:
	GameManager.debug_free_firing = enabled

func _on_shotgun_boost_toggled(enabled: bool) -> void:
	GameManager.debug_shotgun_boost = enabled
