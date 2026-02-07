extends Node

## Manages ENet server/client connections and player spawning.

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal connection_succeeded
signal connection_failed

var is_server := false

## Map of peer_id -> player node for quick lookups.
var players: Dictionary = {}

## The scene tree node where players are spawned (set after map loads).
var player_container: Node = null
## The MultiplayerSpawner that replicates player scenes.
var player_spawner: MultiplayerSpawner = null

const PLAYER_SCENE := preload("res://player/player.tscn")


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)


func host_game(port: int = NetConstants.DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetConstants.MAX_PLAYERS)
	if err != OK:
		push_error("Failed to create server: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = peer
	is_server = true
	print("Server started on port %d" % port)

	# Kick off map load (async, not awaited here so host_game stays non-coroutine)
	_start_host.call_deferred()
	return OK


func _start_host() -> void:
	## Deferred: load map then spawn the host player.
	await _load_game_map()
	_spawn_player(1)


func join_game(address: String, port: int = NetConstants.DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("Failed to create client: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = peer
	is_server = false
	print("Connecting to %s:%d..." % [address, port])
	return OK


func disconnect_game() -> void:
	multiplayer.multiplayer_peer = null
	is_server = false
	players.clear()
	get_tree().change_scene_to_file("res://ui/main_menu.tscn")


func _load_game_map() -> void:
	get_tree().change_scene_to_file("res://world/blockout_map.tscn")
	# change_scene_to_file is deferred — poll until the new scene is actually ready
	while get_tree().current_scene == null or get_tree().current_scene.scene_file_path != "res://world/blockout_map.tscn":
		await get_tree().process_frame
	# Extra frame to ensure _ready() has run on the new scene
	await get_tree().process_frame
	# Get references to the spawner and container from the map
	var map := get_tree().current_scene
	player_spawner = map.get_node("PlayerSpawner")
	player_container = map.get_node("Players")
	print("Map loaded. Spawner and container ready.")


func _spawn_player(peer_id: int) -> void:
	if player_container == null:
		push_error("Player container not set — map not loaded?")
		return

	var player_node := PLAYER_SCENE.instantiate()
	player_node.name = str(peer_id)
	# Set spawn position based on available spawn points
	var map := get_tree().current_scene
	var spawn_points := map.get_node("PlayerSpawnPoints").get_children()
	var spawn_idx := players.size() % spawn_points.size()
	player_node.position = spawn_points[spawn_idx].position

	player_container.add_child(player_node, true)
	players[peer_id] = player_node
	player_connected.emit(peer_id)
	print("Spawned player for peer %d" % peer_id)


func _despawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		var player_node: Node = players[peer_id]
		player_node.queue_free()
		players.erase(peer_id)
		player_disconnected.emit(peer_id)
		print("Despawned player for peer %d" % peer_id)


func _on_peer_connected(peer_id: int) -> void:
	print("Peer connected: %d" % peer_id)
	if is_server:
		_spawn_player(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("Peer disconnected: %d" % peer_id)
	if is_server:
		_despawn_player(peer_id)


func _on_connected_to_server() -> void:
	print("Connected to server! My peer ID: %d" % multiplayer.get_unique_id())
	await _load_game_map()
	connection_succeeded.emit()


func _on_connection_failed() -> void:
	print("Connection failed!")
	multiplayer.multiplayer_peer = null
	connection_failed.emit()
