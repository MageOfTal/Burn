extends Node

## Manages ENet server/client connections and player spawning.
##
## Connection flow:
##   1. Host starts server, loads map, spawns own player (peer_id 1).
##   2. Client connects → server sees _on_peer_connected but does NOT
##      spawn the client's player yet (the client hasn't loaded the map).
##   3. Client receives _on_connected_to_server, loads the map, then sends
##      an RPC (client_ready) to the server.
##   4. Server receives client_ready and NOW spawns the client's player.
##      The MultiplayerSpawner replicates it to the client (who now has
##      the Players container ready).

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

## Debug: track connection state for polling
var _is_connecting := false
var _last_peer_status: int = -1
var _connect_poll_timer: float = 0.0
const _POLL_INTERVAL := 2.0  # Print status every 2 seconds


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	if not _is_connecting:
		return

	# Poll ENet peer connection status for debug visibility
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		print("[Client] DEBUG: multiplayer_peer became NULL during connection!")
		_is_connecting = false
		return

	var status: int = peer.get_connection_status()

	# Log state transitions immediately
	if status != _last_peer_status:
		print("[Client] DEBUG: Peer status changed → %s" % _status_str(status))
		_last_peer_status = status
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			print("[Client] DEBUG: ENet peer is CONNECTED!")
			_is_connecting = false
		elif status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			print("[Client] DEBUG: ENet peer went DISCONNECTED — server unreachable")
			_is_connecting = false

	# Periodic heartbeat print so we know the polling loop is alive
	_connect_poll_timer += delta
	if _connect_poll_timer >= _POLL_INTERVAL:
		_connect_poll_timer = 0.0
		if _is_connecting:
			print("[Client] DEBUG: Still %s..." % _status_str(status))


func _status_str(status: int) -> String:
	match status:
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			return "DISCONNECTED"
		MultiplayerPeer.CONNECTION_CONNECTING:
			return "CONNECTING"
		MultiplayerPeer.CONNECTION_CONNECTED:
			return "CONNECTED"
		_:
			return "UNKNOWN(%d)" % status


## Returns the current peer connection status as a readable string.
## Used by main_menu to display on screen.
func get_peer_status_string() -> String:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return "NO PEER"
	return _status_str(peer.get_connection_status())


## Returns the best local LAN IP (192.168.x.x or 10.x.x.x).
func get_local_ip() -> String:
	for ip in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10."):
			return ip
	for ip in IP.get_local_addresses():
		if "." in ip and ip != "127.0.0.1":
			return ip
	return "unknown"


func host_game(port: int = NetConstants.DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetConstants.MAX_PLAYERS)
	if err != OK:
		push_error("[Server] create_server() FAILED: %s" % error_string(err))
		return err

	multiplayer.multiplayer_peer = peer
	is_server = true

	var local_ip := get_local_ip()
	print("[Server] ========================================")
	print("[Server] Server started on UDP port %d" % port)
	print("[Server] Other players should connect to: %s" % local_ip)
	print("[Server] All local IPs: %s" % str(IP.get_local_addresses()))
	print("[Server] ========================================")

	# Kick off map load (async, not awaited here so host_game stays non-coroutine)
	_start_host.call_deferred()
	return OK


func _start_host() -> void:
	## Deferred: load map then spawn the host player.
	await _load_game_map()
	_spawn_player(1)


func join_game(address: String, port: int = NetConstants.DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	print("[Client] Creating ENet client peer for %s:%d..." % [address, port])
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("[Client] create_client() FAILED: %s" % error_string(err))
		return err
	print("[Client] create_client() returned OK")

	multiplayer.multiplayer_peer = peer
	is_server = false
	_is_connecting = true
	_last_peer_status = -1
	_connect_poll_timer = 0.0

	var initial_status: int = peer.get_connection_status()
	print("[Client] Connecting to %s:%d (UDP)..." % [address, port])
	print("[Client] Initial peer status: %s" % _status_str(initial_status))
	print("[Client] Waiting for connected_to_server signal...")
	print("[Client] (If this stays CONNECTING, the server is unreachable — check UDP firewall rules)")
	return OK


func disconnect_game() -> void:
	_is_connecting = false
	multiplayer.multiplayer_peer = null
	is_server = false
	players.clear()
	get_tree().change_scene_to_file("res://ui/main_menu.tscn")


func _load_game_map() -> void:
	print("[Net] Loading game map...")
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
	print("[Net] Map loaded. Spawner and container ready.")


func _spawn_player(peer_id: int) -> void:
	if player_container == null:
		push_error("[Server] Player container not set — map not loaded?")
		return

	if players.has(peer_id):
		print("[Server] Player %d already spawned, skipping." % peer_id)
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
	print("[Server] Spawned player for peer %d at %s" % [peer_id, str(player_node.position)])


func _despawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		var player_node: Node = players[peer_id]
		player_node.queue_free()
		players.erase(peer_id)
		player_disconnected.emit(peer_id)
		print("[Server] Despawned player for peer %d" % peer_id)


func _on_peer_connected(peer_id: int) -> void:
	print("[Net] Peer connected: %d" % peer_id)
	# Do NOT spawn immediately — wait for client_ready RPC so the client
	# has loaded the map and the MultiplayerSpawner can replicate correctly.
	# (The host player is spawned directly in _start_host, not here.)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[Net] Peer disconnected: %d" % peer_id)
	if is_server:
		_despawn_player(peer_id)


func _on_connected_to_server() -> void:
	_is_connecting = false
	print("[Client] ========================================")
	print("[Client] Connected to server! My peer ID: %d" % multiplayer.get_unique_id())
	print("[Client] ========================================")
	await _load_game_map()
	# Tell the server we have loaded the map and are ready for our player to spawn
	_client_ready.rpc_id(1)
	print("[Client] Sent client_ready to server.")
	connection_succeeded.emit()


func _on_connection_failed() -> void:
	_is_connecting = false
	print("[Client] ========================================")
	print("[Client] CONNECTION FAILED!")
	print("[Client] The server did not respond. Check:")
	print("[Client]   1. Server is running (Host Game pressed)")
	print("[Client]   2. Correct IP address (check server's Output panel)")
	print("[Client]   3. Windows Firewall allows Godot.exe for UDP")
	print("[Client]   4. Both machines on same network")
	print("[Client] ========================================")
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


func _on_server_disconnected() -> void:
	print("[Client] Server disconnected!")
	_is_connecting = false
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


@rpc("any_peer", "reliable")
func _client_ready() -> void:
	## Server-only: called when a client has loaded the map and is ready.
	if not multiplayer.is_server():
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	print("[Server] Received client_ready from peer %d" % sender_id)
	_spawn_player(sender_id)
