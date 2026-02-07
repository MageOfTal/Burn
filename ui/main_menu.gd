extends Control

## Main menu: Host or Join a game.

@onready var address_input: LineEdit = $CenterContainer/VBoxContainer/AddressInput
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel

var _connect_timer: float = 0.0
var _is_connecting := false
const CONNECT_TIMEOUT := 10.0  # seconds


func _ready() -> void:
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)


func _process(delta: float) -> void:
	if _is_connecting:
		_connect_timer += delta
		var dots := ".".repeat(int(_connect_timer * 2) % 4)
		status_label.text = "Connecting%s (%.0fs)" % [dots, _connect_timer]
		if _connect_timer >= CONNECT_TIMEOUT:
			_is_connecting = false
			status_label.text = "Connection timed out! Check:\n- Server is running\n- Using correct local IP (e.g. 192.168.x.x)\n- UDP port 7777 is open in firewall"
			NetworkManager.disconnect_game()


func _on_host_pressed() -> void:
	status_label.text = "Starting server on UDP port %d..." % NetConstants.DEFAULT_PORT
	var err := NetworkManager.host_game()
	if err != OK:
		status_label.text = "Failed to start server!"


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
	status_label.text = "Connection failed!\nCheck: server running? correct IP? UDP port 7777 open?"
