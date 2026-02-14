extends Node

## Manages high-level game state transitions and player identity.

enum GameState { MENU, LOBBY, PLAYING, GAME_OVER }

var current_state: GameState = GameState.MENU
var match_time_elapsed: float = 0.0

# Username system
var local_username: String = "Player"           ## Set from main menu before host/join
var player_usernames: Dictionary = {}           ## peer_id -> username (server-authoritative)

# Debug toggles (set from main menu, checked by subsystems)
var debug_disable_burn_timers: bool = false
var debug_disable_demon: bool = false
var debug_disable_zone_damage: bool = false
var debug_skip_structures: bool = false
var debug_grapple_ground_pump: bool = false
var debug_grapple_reel_speed: float = 3.0  # Matches GrappleSystem.ROPE_REEL_SPEED default
var debug_grapple_visuals: bool = false     # Show pill, angle display, spheres, raycasts
var debug_freecam_active: bool = false      # Set by DebugFreecam autoload
var debug_velocity_iterations: int = 10    # Jolt solver velocity iterations (default 10)

signal game_state_changed(new_state: GameState)
signal match_started
signal match_ended
signal player_usernames_changed


func change_state(new_state: GameState) -> void:
	current_state = new_state
	game_state_changed.emit(new_state)
	if new_state == GameState.PLAYING:
		match_time_elapsed = 0.0
		match_started.emit()
	elif new_state == GameState.GAME_OVER:
		match_ended.emit()


func register_username(peer_id: int, username: String) -> void:
	player_usernames[peer_id] = username
	player_usernames_changed.emit()


func get_username(peer_id: int) -> String:
	if player_usernames.has(peer_id):
		return player_usernames[peer_id]
	if peer_id >= 9000 and peer_id < 9100:
		return "Bot %d" % (peer_id - 9000 + 1)
	return "Player %d" % peer_id


func clear_usernames() -> void:
	player_usernames.clear()
	player_usernames_changed.emit()


func _process(delta: float) -> void:
	if current_state == GameState.PLAYING:
		match_time_elapsed += delta
