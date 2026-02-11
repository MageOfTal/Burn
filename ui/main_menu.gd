extends Control

## Main menu: Host or Join a game.

@onready var address_input: LineEdit = $CenterContainer/VBoxContainer/AddressInput
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel

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


func _on_host_pressed() -> void:
	var local_ip := NetworkManager.get_local_ip()
	var err := NetworkManager.host_game()
	if err != OK:
		status_label.text = "Failed to start server!"
	else:
		status_label.text = "Server running on UDP port %d\nTell others to connect to: %s" % [NetConstants.DEFAULT_PORT, local_ip]


func _on_join_pressed() -> void:
	var address := address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	status_label.text = "Connecting to %s:%d..." % [address, NetConstants.DEFAULT_PORT]
	var err := NetworkManager.join_game(address)
	if err != OK:
		status_label.text = "Failed to connect!"
	else:
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

func _on_burn_timers_toggled(enabled: bool) -> void:
	GameManager.debug_disable_burn_timers = enabled

func _on_demon_toggled(enabled: bool) -> void:
	GameManager.debug_disable_demon = enabled

func _on_zone_damage_toggled(enabled: bool) -> void:
	GameManager.debug_disable_zone_damage = enabled

func _on_skip_structures_toggled(enabled: bool) -> void:
	GameManager.debug_skip_structures = enabled
