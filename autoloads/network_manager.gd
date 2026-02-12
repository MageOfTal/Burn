extends Node

## Manages ENet server/client connections, lobby, and player spawning.
##
## Connection flow:
##   1. Host starts server, loads map, enters lobby.
##   2. Client connects → loads map → enters lobby → sends client_ready RPC.
##   3. Server adds client to lobby peer list.
##   4. Host clicks "Start Game" → server spawns all players + bots, game begins.
##   5. Host can "Reset Game" from pause menu → despawns all, returns to lobby.

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal connection_succeeded
signal connection_failed
signal victory_declared(winner_peer_id: int)

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

## Lobby state
var _lobby_ready_peers: Array[int] = []  ## Peers who loaded the map and are in the lobby
var _lobby_screen: CanvasLayer = null
var _lobby_player_list_label: Label = null
var _lobby_start_button: Button = null


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
		print("[Client] DEBUG: Peer status changed -> %s" % _status_str(status))
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
## Skips virtual adapter ranges (172.16-31.x.x often used by Docker/WSL/Hyper-V).
## Prints all detected IPs to Output so you can verify.
func get_local_ip() -> String:
	var all_ips := IP.get_local_addresses()
	print("[Net] All local IPs from Godot: %s" % str(all_ips))

	# Pass 1: prefer 192.168.x.x (most common home LAN)
	for ip in all_ips:
		if ip.begins_with("192.168."):
			return ip
	# Pass 2: 10.x.x.x (some LANs use this)
	for ip in all_ips:
		if ip.begins_with("10."):
			return ip
	# Pass 3: any IPv4 that isn't loopback or link-local
	for ip in all_ips:
		if "." in ip and ip != "127.0.0.1" and not ip.begins_with("169.254."):
			return ip
	return "unknown"


# ======================================================================
#  Host / Join / Disconnect
# ======================================================================

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
	print("[Server] Step 1/2: Loading game map...")
	await _load_game_map()
	print("[Server] Step 2/2: Building structures...")
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world:
		_update_loading_status("Building structures...")
		seed_world.world_generation_complete.connect(_on_structures_complete_lobby, CONNECT_ONE_SHOT)
		seed_world._spawn_heavy_structures()
	else:
		_on_structures_complete_lobby()


func _on_structures_complete_lobby() -> void:
	## Callback: heavy structures finished building. Enter lobby.
	_hide_loading_screen()
	# Register host as lobby-ready
	_lobby_ready_peers.clear()
	_lobby_ready_peers.append(1)
	GameManager.register_username(1, GameManager.local_username)
	GameManager.change_state(GameManager.GameState.LOBBY)
	_show_lobby_ui()
	print("[Server] Host setup complete. Entered lobby.")


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
	_hide_lobby_ui()
	multiplayer.multiplayer_peer = null
	is_server = false
	players.clear()
	_lobby_ready_peers.clear()
	GameManager.clear_usernames()

	# Reset autoloads so they stop ticking without a multiplayer peer
	var zone_mgr := get_node_or_null("/root/ZoneManager")
	if zone_mgr and zone_mgr.has_method("reset"):
		zone_mgr.reset()
	var burn_clock := get_node_or_null("/root/BurnClock")
	if burn_clock and burn_clock.has_method("stop"):
		burn_clock.stop()
	GameManager.change_state(GameManager.GameState.MENU)

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


# ======================================================================
#  Player / Bot Spawning (server-only, deferred until game starts)
# ======================================================================

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

	# Kill feed: announce human players joining (not bots)
	if peer_id < BOT_PEER_ID_START:
		var uname := GameManager.get_username(peer_id)
		broadcast_kill_feed("[color=teal]%s joined[/color]" % uname)


func _despawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		# Kill feed: announce human players leaving (not bots)
		if peer_id < BOT_PEER_ID_START:
			var uname := GameManager.get_username(peer_id)
			broadcast_kill_feed("[color=teal]%s disconnected[/color]" % uname)
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
		GameManager.register_username(bot_peer_id, "Bot %d" % (i + 1))
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


# ======================================================================
#  Peer connection / disconnection callbacks
# ======================================================================

func _on_peer_connected(peer_id: int) -> void:
	print("[Net] ======== Peer connected: %d ========" % peer_id)
	print("[Net]   is_server=%s  total_players=%d" % [str(is_server), players.size()])
	print("[Net]   player_container=%s  player_spawner=%s" % [
		str(player_container != null), str(player_spawner != null)])
	if is_server:
		print("[Net]   (Server) Waiting for client_ready RPC from peer %d..." % peer_id)
	else:
		print("[Net]   (Client) Server peer %d appeared in our peer list" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	print("[Net] ======== Peer disconnected: %d ========" % peer_id)
	print("[Net]   was in players dict: %s" % str(players.has(peer_id)))
	if is_server:
		# Remove from lobby or despawn depending on game state
		_lobby_ready_peers.erase(peer_id)
		GameManager.player_usernames.erase(peer_id)
		if GameManager.current_state == GameManager.GameState.LOBBY:
			# In lobby — just update the player list (no player to despawn)
			_sync_all_usernames.rpc(_serialize_usernames())
			_update_lobby_player_list.rpc(_lobby_ready_peers.duplicate())
			_refresh_lobby_player_list()
		else:
			_despawn_player(peer_id)
			check_victory()


func _on_connected_to_server() -> void:
	_is_connecting = false
	print("[Client] ========================================")
	print("[Client] Connected to server! My peer ID: %d" % multiplayer.get_unique_id())
	print("[Client] ========================================")
	print("[Client] Step 1/4: Showing loading screen...")
	_show_loading_screen("Loading game map...")
	print("[Client] Step 2/4: Loading game map (await)...")
	await _load_game_map()
	print("[Client] Step 3/4: Building structures...")
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world:
		_update_loading_status("Building structures...")
		seed_world._spawn_heavy_structures()
		if not seed_world.structures_complete:
			await seed_world.world_generation_complete
		print("[Client] Structures complete.")

	# Send username and ready signal to server
	print("[Client] Step 4/4: Sending username + client_ready to server...")
	_register_username.rpc_id(1, GameManager.local_username)
	_client_ready.rpc_id(1)

	# Wait a few frames for RPCs to process
	for i in 10:
		await get_tree().process_frame

	_hide_loading_screen()
	GameManager.change_state(GameManager.GameState.LOBBY)
	_show_lobby_ui()
	print("[Client] ======== Join complete — entered lobby! ========")
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
	_hide_lobby_ui()
	multiplayer.multiplayer_peer = null
	# Reset autoloads to prevent errors when peer is null
	var zone_mgr := get_node_or_null("/root/ZoneManager")
	if zone_mgr and zone_mgr.has_method("reset"):
		zone_mgr.reset()
	var burn_clock_node := get_node_or_null("/root/BurnClock")
	if burn_clock_node and burn_clock_node.has_method("stop"):
		burn_clock_node.stop()
	connection_failed.emit()


# ======================================================================
#  Username RPCs
# ======================================================================

@rpc("any_peer", "reliable")
func _register_username(username: String) -> void:
	## Server-only: client sends their username to the server.
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	GameManager.register_username(sender_id, username)
	print("[Server] Registered username '%s' for peer %d" % [username, sender_id])
	# Broadcast updated username list to all clients
	_sync_all_usernames.rpc(_serialize_usernames())


@rpc("authority", "call_remote", "reliable")
func _sync_all_usernames(data: Dictionary) -> void:
	## Client receives the full username dictionary from the server.
	GameManager.player_usernames = data
	GameManager.player_usernames_changed.emit()
	_refresh_lobby_player_list()


func _serialize_usernames() -> Dictionary:
	return GameManager.player_usernames.duplicate()


# ======================================================================
#  Client Ready RPC (lobby mode — no immediate spawn)
# ======================================================================

@rpc("any_peer", "reliable")
func _client_ready() -> void:
	## Server-only: called when a client has loaded the map and is ready.
	var sender_id: int = multiplayer.get_remote_sender_id()
	print("[Server] ======== _client_ready RPC received from peer %d ========" % sender_id)
	if not multiplayer.is_server():
		print("[Server] WARN: _client_ready called on non-server (peer %d), ignoring" % multiplayer.get_unique_id())
		return

	if GameManager.current_state == GameManager.GameState.LOBBY:
		# Lobby mode: add to lobby, don't spawn yet
		if sender_id not in _lobby_ready_peers:
			_lobby_ready_peers.append(sender_id)
		print("[Server] Peer %d added to lobby. Total lobby peers: %d" % [sender_id, _lobby_ready_peers.size()])
		# Broadcast updated lists
		_sync_all_usernames.rpc(_serialize_usernames())
		_update_lobby_player_list.rpc(_lobby_ready_peers.duplicate())
		_refresh_lobby_player_list()
	else:
		# Game already running (late join) — spawn immediately
		print("[Server] Game already running — spawning peer %d immediately" % sender_id)
		_spawn_player(sender_id)


# ======================================================================
#  Lobby UI (programmatic overlay, survives as child of autoload)
# ======================================================================

func _show_lobby_ui() -> void:
	_hide_lobby_ui()

	_lobby_screen = CanvasLayer.new()
	_lobby_screen.layer = 99

	# Dark background
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.1, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_lobby_screen.add_child(bg)

	# Center container
	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.offset_left = -200
	center.offset_right = 200
	center.offset_top = -250
	center.offset_bottom = 250
	center.add_theme_constant_override("separation", 14)
	bg.add_child(center)

	# Title
	var title := Label.new()
	title.text = "LOBBY"
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center.add_child(title)

	# Server IP display (host only)
	if is_server:
		var ip_label := Label.new()
		ip_label.text = "IP: %s   Port: %d" % [get_local_ip(), NetConstants.DEFAULT_PORT]
		ip_label.add_theme_font_size_override("font_size", 16)
		ip_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
		ip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		center.add_child(ip_label)

	center.add_child(HSeparator.new())

	# Players heading
	var heading := Label.new()
	heading.text = "Players:"
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
	center.add_child(heading)

	# Player list (updated dynamically)
	_lobby_player_list_label = Label.new()
	_lobby_player_list_label.text = ""
	_lobby_player_list_label.add_theme_font_size_override("font_size", 18)
	_lobby_player_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	center.add_child(_lobby_player_list_label)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	center.add_child(spacer)

	center.add_child(HSeparator.new())

	# Start button (host only) or waiting text (clients)
	if is_server:
		_lobby_start_button = Button.new()
		_lobby_start_button.text = "Start Game"
		_lobby_start_button.custom_minimum_size = Vector2(200, 50)
		_lobby_start_button.add_theme_font_size_override("font_size", 20)
		_lobby_start_button.pressed.connect(_on_lobby_start_pressed)
		center.add_child(_lobby_start_button)
	else:
		var waiting := Label.new()
		waiting.text = "Waiting for host to start..."
		waiting.add_theme_font_size_override("font_size", 18)
		waiting.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
		waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		center.add_child(waiting)

	add_child(_lobby_screen)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_lobby_player_list()
	GameManager.player_usernames_changed.connect(_refresh_lobby_player_list)


func _hide_lobby_ui() -> void:
	if GameManager.player_usernames_changed.is_connected(_refresh_lobby_player_list):
		GameManager.player_usernames_changed.disconnect(_refresh_lobby_player_list)
	if _lobby_screen != null:
		_lobby_screen.queue_free()
		_lobby_screen = null
		_lobby_player_list_label = null
		_lobby_start_button = null


func _refresh_lobby_player_list() -> void:
	if _lobby_player_list_label == null:
		return
	var lines: PackedStringArray = []
	for peer_id in _lobby_ready_peers:
		var username := GameManager.get_username(peer_id)
		var prefix := "[HOST] " if peer_id == 1 else ""
		lines.append("  %s%s" % [prefix, username])
	_lobby_player_list_label.text = "\n".join(lines)


@rpc("authority", "call_remote", "reliable")
func _update_lobby_player_list(peer_list: Array) -> void:
	## Client receives updated lobby peer list from server.
	_lobby_ready_peers.clear()
	for pid in peer_list:
		_lobby_ready_peers.append(int(pid))
	_refresh_lobby_player_list()


# ======================================================================
#  Start Game (from lobby)
# ======================================================================

func _on_lobby_start_pressed() -> void:
	## Host-only: start the game for everyone.
	if not is_server:
		return
	print("[Server] ======== STARTING GAME ========")
	_start_match()
	_rpc_start_match.rpc()


@rpc("authority", "call_remote", "reliable")
func _rpc_start_match() -> void:
	## Client receives: game is starting.
	_start_match()


func _start_match() -> void:
	## Both server and client: hide lobby, begin gameplay.
	_hide_lobby_ui()
	GameManager.change_state(GameManager.GameState.PLAYING)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if multiplayer.is_server():
		# Spawn all lobby players
		for peer_id in _lobby_ready_peers:
			_spawn_player(peer_id)
			_reposition_to_spawn_point(peer_id)

		# Debug: spawn demon near ALL players for testing
		for pid in players:
			players[pid].demon_system.debug_spawn_nearby()

		# Spawn bots
		_spawn_bots()

		# Spawn demo items
		var map := get_tree().current_scene
		if map and map.has_method("_spawn_demo_items"):
			map._spawn_demo_items()
		if map and map.has_method("spawn_lemon_shapes"):
			map.spawn_lemon_shapes()

		# Start zone and burn clock
		if map and map.has_method("_start_zone"):
			map._start_zone()
		var burn_clock := get_node_or_null("/root/BurnClock")
		if burn_clock and burn_clock.has_method("start"):
			burn_clock.start()

		print("[Server] Game started! %d players + %d bots" % [
			_lobby_ready_peers.size(), BOT_COUNT])


# ======================================================================
#  Reset Game (server-only, returns everyone to lobby)
# ======================================================================

func reset_game() -> void:
	## Server-only: reset the game and return everyone to the lobby.
	if not is_server:
		return

	print("[Server] ======== RESETTING GAME ========")

	# 1. Notify clients FIRST so they can clean up before nodes are freed
	_rpc_reset_to_lobby.rpc()

	# 2. Despawn all players and bots
	for peer_id in players.keys():
		var player_node: Node = players[peer_id]
		if is_instance_valid(player_node):
			player_node.queue_free()
	players.clear()

	# 3. Clear world items and projectiles
	var map := get_tree().current_scene
	if map:
		var world_items := map.get_node_or_null("WorldItems")
		if world_items:
			for child in world_items.get_children():
				child.queue_free()
		var projectiles := map.get_node_or_null("Projectiles")
		if projectiles:
			for child in projectiles.get_children():
				child.queue_free()

	# 4. Wait a frame so queue_free'd nodes are fully deallocated.
	# This prevents stale MultiplayerSynchronizer cache errors —
	# the InputSync/ServerSync nodes need to be gone before the
	# multiplayer system tries to reference them again.
	await get_tree().process_frame

	# 5. Reset autoloads
	_victory_declared = false
	var burn_clock := get_node_or_null("/root/BurnClock")
	if burn_clock and burn_clock.has_method("stop"):
		burn_clock.stop()
	var zone_mgr := get_node_or_null("/root/ZoneManager")
	if zone_mgr and zone_mgr.has_method("reset"):
		zone_mgr.reset()
	GameManager.match_time_elapsed = 0.0

	# 6. Reset ToadDimension
	var toad_dim := get_node_or_null("/root/ToadDimension")
	if toad_dim and "_sessions" in toad_dim:
		toad_dim._sessions.clear()

	# 7. Clear bot usernames (keep human usernames)
	for peer_id in GameManager.player_usernames.keys():
		if peer_id >= BOT_PEER_ID_START:
			GameManager.player_usernames.erase(peer_id)

	# 8. Rebuild lobby peer list from currently connected peers
	_lobby_ready_peers.clear()
	_lobby_ready_peers.append(1)  # Host
	for peer_id in multiplayer.get_peers():
		if peer_id not in _lobby_ready_peers:
			_lobby_ready_peers.append(peer_id)

	# 9. Change state to LOBBY
	GameManager.change_state(GameManager.GameState.LOBBY)

	# 10. Show lobby on host
	_show_lobby_ui()
	print("[Server] Reset complete. Back in lobby with %d peers." % _lobby_ready_peers.size())


@rpc("authority", "call_remote", "reliable")
func _rpc_reset_to_lobby() -> void:
	## Client receives: game is being reset, clean up and show lobby.
	# Release mouse so lobby UI is interactive
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	GameManager.change_state(GameManager.GameState.LOBBY)
	_show_lobby_ui()


# ======================================================================
#  Kill Feed Broadcast (server → all clients)
# ======================================================================

func broadcast_kill_feed(bbcode_text: String) -> void:
	## Server-only: send a kill feed entry to all peers.
	if not multiplayer.is_server():
		return
	_rpc_kill_feed.rpc(bbcode_text)


@rpc("authority", "call_local", "reliable")
func _rpc_kill_feed(bbcode_text: String) -> void:
	## All peers: find the local player's HUD and add the entry.
	var players_node := get_tree().current_scene.get_node_or_null("Players")
	if players_node == null:
		return
	var my_id := multiplayer.get_unique_id()
	for child in players_node.get_children():
		if child.name.to_int() == my_id:
			var hud := child.get_node_or_null("HUDLayer/PlayerHUD")
			if hud and hud.has_method("add_kill_feed_entry"):
				hud.add_kill_feed_entry(bbcode_text)
			break


# ======================================================================
#  Victory Detection (server-only, checked after eliminations)
# ======================================================================

var _victory_declared: bool = false

func check_victory() -> void:
	## Server-only: check if only one non-eliminated player (human or bot) remains.
	## Called after demon eliminations and disconnects.
	if not multiplayer.is_server():
		return
	if GameManager.current_state != GameManager.GameState.PLAYING:
		return
	if _victory_declared:
		return

	var alive_players: Array[int] = []
	for peer_id: int in players:
		var p: Node = players[peer_id]
		if not is_instance_valid(p):
			continue
		var demon_sys: Node = p.get_node_or_null("DemonSystem")
		if demon_sys and demon_sys.is_eliminated:
			continue
		alive_players.append(peer_id)

	if alive_players.size() == 1:
		var winner_id: int = alive_players[0]
		_victory_declared = true
		print("[Server] VICTORY! Player %d (%s) is the last one standing!" % [
			winner_id, GameManager.get_username(winner_id)])

		# Stop the winner's demon and make them invincible
		var winner_node: Node = players.get(winner_id)
		if winner_node:
			var demon_sys: Node = winner_node.get_node_or_null("DemonSystem")
			if demon_sys:
				demon_sys.demon_active = false

		# Set game over state (prevents further damage)
		GameManager.change_state(GameManager.GameState.GAME_OVER)

		# Broadcast to all clients
		var winner_name := GameManager.get_username(winner_id)
		_rpc_victory.rpc(winner_id, winner_name)
		broadcast_kill_feed("[color=gold]%s wins! Last one standing![/color]" % winner_name)
		victory_declared.emit(winner_id)

	elif alive_players.size() == 0:
		# Everyone eliminated — draw
		_victory_declared = true
		GameManager.change_state(GameManager.GameState.GAME_OVER)
		_rpc_victory.rpc(-1, "Nobody")
		broadcast_kill_feed("[color=gold]DRAW — everyone was eliminated![/color]")


@rpc("authority", "call_local", "reliable")
func _rpc_victory(winner_id: int, winner_name: String) -> void:
	## All peers: show victory screen overlay on local player's HUD.
	# Set game over state on clients too (prevents local damage processing)
	GameManager.change_state(GameManager.GameState.GAME_OVER)
	var players_node := get_tree().current_scene.get_node_or_null("Players")
	if players_node == null:
		return
	var my_id := multiplayer.get_unique_id()
	for child in players_node.get_children():
		if child.name.to_int() == my_id:
			var hud := child.get_node_or_null("HUDLayer/PlayerHUD")
			if hud and hud.has_method("show_victory_screen"):
				hud.show_victory_screen(winner_id, winner_name, my_id)
			break


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
	print("[Net] Loading screen hidden")
