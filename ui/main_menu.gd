extends Control

## Main menu: Host or Join a game.

@onready var address_input: LineEdit = $CenterContainer/VBoxContainer/AddressInput
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel


func _ready() -> void:
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)


func _on_host_pressed() -> void:
	status_label.text = "Starting server..."
	var err := NetworkManager.host_game()
	if err != OK:
		status_label.text = "Failed to start server!"


func _on_join_pressed() -> void:
	var address := address_input.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	status_label.text = "Connecting to %s..." % address
	var err := NetworkManager.join_game(address)
	if err != OK:
		status_label.text = "Failed to connect!"


func _on_quit_pressed() -> void:
	get_tree().quit()


func _on_connection_succeeded() -> void:
	status_label.text = "Connected!"


func _on_connection_failed() -> void:
	status_label.text = "Connection failed! Is the server running?"
