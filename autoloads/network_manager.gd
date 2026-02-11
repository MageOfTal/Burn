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

## Bot configuration
const BOT_COUNT := 8               ## Number of bots to spawn on host
const BOT_PEER_ID_START := 9000    ## Fake peer IDs for bots (9000, 9001, ...)

## Debug: track connection state for polling
var _is_connecting := false
var _last_peer_status: int = -1
var _connect_poll_timer: float = 0.0
const _POLL_INTERVAL := 2.0  # Print status every 2 seconds

## Loading screen overlay (child of this autoload so it survives scene changes)
var _loading_screen: CanvasLayer = null
var _loading_status_label: Label = null

## Loading screen auto-hide: counts down frames in _process then hides
var _loading_hide_countdown: int = -1


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	# Auto-hide loading screen after countdown (avoids await in coroutines)
	if _loading_hide_countdown > 0:
		_loading_hide_countdown -= 1
	elif _loading_hide_countdown == 0:
		_loading_hide_countdown = -1
		_hide_loading_screen()

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
	print("[Server] _start_host() — beginning host setup...")
	_show_loading_screen("Loading game map...")
	print("[Server] Step 1/5: Loading game map...")
	await _load_game_map()
	print("[Server] Step 2/5: Spawning host player (peer 1)...")
	_update_loading_status("Spawning players...")
	_spawn_player(1)
	_reposition_to_spawn_point(1)
	# Debug: spawn demon near host for testing
	if players.has(1):
		players[1].demon_system.debug_spawn_nearby()
	print("[Server] Step 3/5: Spawning bots...")
	_spawn_bots()
	print("[Server] Step 4/5: Spawning demo items...")
	var map := get_tree().current_scene
	if map and map.has_method("_spawn_demo_items"):
		map._spawn_demo_items()
	if map and map.has_method("spawn_lemon_shapes"):
		map.spawn_lemon_shapes()
	print("[Server] Step 5/5: Building structures...")
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world:
		_update_loading_status("Building structures...")
		seed_world.world_generation_complete.connect(_on_structures_complete, CONNECT_ONE_SHOT)
		seed_world._spawn_heavy_structures()
	else:
		_update_loading_status("Ready!")
		_loading_hide_countdown = 20
	print("[Server] Host setup complete. Total players: %d" % players.size())


func _on_structures_complete() -> void:
	## Callback: heavy structures finished building. Hide loading screen.
	_update_loading_status("Ready!")
	_loading_hide_countdown = 20


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

	# Reset autoloads so they stop ticking without a multiplayer peer
	var zone_mgr := get_node_or_null("/root/ZoneManager")
	if zone_mgr and zone_mgr.has_method("reset"):
		zone_mgr.reset()
	var burn_clock := get_node_or_null("/root/BurnClock")
	if burn_clock and burn_clock.has_method("stop"):
		burn_clock.stop()
	var game_mgr := get_node_or_null("/root/GameManager")
	if game_mgr:
		game_mgr.current_state = game_mgr.GameState.MENU

	get_tree().change_scene_to_file("res://ui/main_menu.tscn")


func _load_game_map() -> void:
	print("[Net] _load_game_map() — calling change_scene_to_file...")
	get_tree().change_scene_to_file("res://world/blockout_map.tscn")
	var poll_frames := 0
	while get_tree().current_scene == null or get_tree().current_scene.scene_file_path != "res://world/blockout_map.tscn":
		poll_frames += 1
		await get_tree().process_frame
	await get_tree().process_frame
	poll_frames += 1
	print("[Net] Map scene ready after %d poll frames" % poll_frames)
	var map := get_tree().current_scene
	player_spawner = map.get_node_or_null("PlayerSpawner")
	player_container = map.get_node_or_null("Players")
	print("[Net] Map loaded. spawner=%s  container=%s" % [
		str(player_spawner != null), str(player_container != null)])
	if player_spawner == null:
		push_error("[Net] FAIL: PlayerSpawner not found in map scene!")
	if player_container == null:
		push_error("[Net] FAIL: Players container not found in map scene!")


func _spawn_player(peer_id: int) -> void:
	print("[Server] _spawn_player(%d) called" % peer_id)
	if player_container == null:
		push_error("[Server] FAIL: player_container is null — map not loaded?")
		return

	if players.has(peer_id):
		print("[Server] Player %d already in players dict, skipping." % peer_id)
		return

	print("[Server]   Instantiating player scene for peer %d..." % peer_id)
	var player_node := PLAYER_SCENE.instantiate()
	player_node.name = str(peer_id)

	var map := get_tree().current_scene
	var spawn_container := map.get_node_or_null("PlayerSpawnPoints")
	var spawn_points: Array[Node] = spawn_container.get_children() if spawn_container else []
	if spawn_points.size() > 0:
		var spawn_idx := players.size() % spawn_points.size()
		player_node.position = spawn_points[spawn_idx].position
		print("[Server]   Using spawn point %d/%d at %s" % [spawn_idx, spawn_points.size(), str(player_node.position)])
	else:
		player_node.position = Vector3(0, 20, 0)
		push_warning("[Server] No spawn points available — spawning at fallback position")

	print("[Server]   Adding to player_container (current children: %d)..." % player_container.get_child_count())
	player_container.add_child(player_node, true)
	players[peer_id] = player_node
	player_connected.emit(peer_id)
	print("[Server]   SUCCESS: Player %d spawned at %s (container now has %d children)" % [
		peer_id, str(player_node.position), player_container.get_child_count()])
	print("[Server]   player_spawner=%s, spawn_path=%s" % [
		str(player_spawner != null),
		str(player_spawner.spawn_path) if player_spawner else "N/A"])


func _despawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		var player_node: Node = players[peer_id]
		player_node.queue_free()
		players.erase(peer_id)
		player_disconnected.emit(peer_id)
		print("[Server] Despawned player for peer %d" % peer_id)


func _reposition_to_spawn_point(peer_id: int) -> void:
	## Move an already-spawned player to a spawn point.
	if not players.has(peer_id):
		return
	var player_node: CharacterBody3D = players[peer_id]
	var map := get_tree().current_scene
	var spawn_container := map.get_node_or_null("PlayerSpawnPoints") if map else null
	if spawn_container and spawn_container.get_child_count() > 0:
		var sp: Node = spawn_container.get_child(0)
		player_node.global_position = sp.position
		print("[Server] Repositioned player %d to spawn point at %s" % [peer_id, str(sp.position)])


func _spawn_bots() -> void:
	## Spawn BOT_COUNT bot players with fake peer IDs.
	## Bots are full player scenes but with is_bot=true so they use BotBrain AI.
	for i in BOT_COUNT:
		var bot_peer_id := BOT_PEER_ID_START + i
		_spawn_bot(bot_peer_id)
	print("[Server] Spawned %d bots (IDs %d-%d)" % [BOT_COUNT, BOT_PEER_ID_START, BOT_PEER_ID_START + BOT_COUNT - 1])


func _spawn_bot(bot_peer_id: int) -> void:
	if player_container == null:
		push_error("[Server] Player container not set — can't spawn bot")
		return
	if players.has(bot_peer_id):
		return

	var bot_node := PLAYER_SCENE.instantiate()
	bot_node.name = str(bot_peer_id)
	# Mark as bot BEFORE _ready() runs
	bot_node.is_bot = true

	# Pick spawn position (spawn points already at ground level via noise height)
	var map := get_tree().current_scene
	var spawn_container := map.get_node_or_null("PlayerSpawnPoints")
	var spawn_points_arr: Array[Node] = spawn_container.get_children() if spawn_container else []
	if spawn_points_arr.size() > 0:
		var spawn_idx := players.size() % spawn_points_arr.size()
		bot_node.position = spawn_points_arr[spawn_idx].position
	else:
		bot_node.position = Vector3(0, 20, 0)

	player_container.add_child(bot_node, true)
	players[bot_peer_id] = bot_node
	print("[Server] Spawned bot %d at %s" % [bot_peer_id, str(bot_node.position)])


func _on_peer_connected(peer_id: int) -> void:
	print("[Net] ======== Peer connected: %d ========" % peer_id)
	print("[Net]   is_server=%s  total_players=%d" % [str(is_server), players.size()])
	print("[Net]   player_container=%s  player_spawner=%s" % [
		str(player_container != null), str(player_spawner != null)])
	if is_server:
		print("[Net]   (Server) Waiting for client_ready RPC from peer %d before spawning..." % peer_id)
	else:
		print("[Net]   (Client) Server peer %d appeared in our peer list" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[Net] ======== Peer disconnected: %d ========" % peer_id)
	print("[Net]   was in players dict: %s" % str(players.has(peer_id)))
	if is_server:
		_despawn_player(peer_id)


func _on_connected_to_server() -> void:
	_is_connecting = false
	print("[Client] ========================================")
	print("[Client] Connected to server! My peer ID: %d" % multiplayer.get_unique_id())
	print("[Client] ========================================")
	print("[Client] Step 1/5: Showing loading screen...")
	_show_loading_screen("Loading game map...")
	print("[Client] Step 2/5: Loading game map (await)...")
	await _load_game_map()
	print("[Client] Step 3/5: Map loaded. player_container=%s, player_spawner=%s" % [
		str(player_container != null), str(player_spawner != null)])
	if player_container:
		print("[Client]   Players container children: %d" % player_container.get_child_count())
	_update_loading_status("Joining game...")
	print("[Client] Step 4/5: Sending client_ready RPC to server...")
	_client_ready.rpc_id(1)
	print("[Client]   client_ready RPC sent. Waiting 30 frames for server to spawn our player...")
	for i in 30:
		await get_tree().process_frame
	print("[Client] Step 5/5: Hiding loading screen. Players container children: %d" % (
		player_container.get_child_count() if player_container else -1))
	if player_container:
		for child in player_container.get_children():
			print("[Client]   Player node: '%s'" % child.name)
	_hide_loading_screen()
	print("[Client] ======== Join complete! ========")
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
	# Reset autoloads to prevent errors when peer is null
	var zone_mgr := get_node_or_null("/root/ZoneManager")
	if zone_mgr and zone_mgr.has_method("reset"):
		zone_mgr.reset()
	var burn_clock_node := get_node_or_null("/root/BurnClock")
	if burn_clock_node and burn_clock_node.has_method("stop"):
		burn_clock_node.stop()
	connection_failed.emit()


@rpc("any_peer", "reliable")
func _client_ready() -> void:
	## Server-only: called when a client has loaded the map and is ready.
	var sender_id: int = multiplayer.get_remote_sender_id()
	print("[Server] ======== _client_ready RPC received from peer %d ========" % sender_id)
	if not multiplayer.is_server():
		print("[Server] WARN: _client_ready called on non-server (peer %d), ignoring" % multiplayer.get_unique_id())
		return
	print("[Server]   GameState=%d  players_count=%d  is_server=%s" % [
		GameManager.current_state, players.size(), str(is_server)])
	_spawn_player(sender_id)


# ======================================================================
#  Loading Screen (programmatic, survives scene changes as child of autoload)
# ======================================================================

func _show_loading_screen(initial_text: String) -> void:
	## Create and show a full-screen loading overlay.
	if _loading_screen != null:
		_loading_screen.queue_free()

	_loading_screen = CanvasLayer.new()
	_loading_screen.layer = 100  # Always on top

	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.12, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_screen.add_child(bg)

	# Title label
	var title := Label.new()
	title.text = "BURN ROYALE"
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_CENTER)
	title.offset_left = -300
	title.offset_right = 300
	title.offset_top = -80
	title.offset_bottom = -20
	_loading_screen.add_child(title)

	# Status label
	_loading_status_label = Label.new()
	_loading_status_label.text = initial_text
	_loading_status_label.add_theme_font_size_override("font_size", 28)
	_loading_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	_loading_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_status_label.set_anchors_preset(Control.PRESET_CENTER)
	_loading_status_label.offset_left = -300
	_loading_status_label.offset_right = 300
	_loading_status_label.offset_top = 20
	_loading_status_label.offset_bottom = 60
	_loading_screen.add_child(_loading_status_label)

	add_child(_loading_screen)
	# Ensure mouse is visible during loading (not captured spinning behind the overlay)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	print("[Net] Loading screen shown: %s" % initial_text)


func _update_loading_status(text: String) -> void:
	## Update the status text on the loading screen.
	if _loading_status_label:
		_loading_status_label.text = text
	print("[Net] Loading status: %s" % text)


func _hide_loading_screen() -> void:
	## Remove the loading screen overlay.
	if _loading_screen != null:
		_loading_screen.queue_free()
		_loading_screen = null
		_loading_status_label = null
	# Capture mouse now that loading is done (player_input skipped capture during loading)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	print("[Net] Loading screen hidden")
