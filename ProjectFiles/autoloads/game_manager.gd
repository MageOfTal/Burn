extends Node

## Manages high-level game state transitions and player identity.

enum GameState { MENU, LOBBY, PLAYING, GAME_OVER }

var current_state: GameState = GameState.MENU
var match_time_elapsed: float = 0.0

# Username system
var local_username: String = "Player"           ## Set from main menu before host/join
var player_usernames: Dictionary = {}           ## peer_id -> username (server-authoritative)

# Debug toggles (set from main menu, checked by subsystems)
var debug_god_mode: bool = true            # Disables burn timers, demon, and zone damage
var debug_disable_burn_timers: bool = true
var debug_disable_demon: bool = true
var debug_disable_zone_damage: bool = true
var debug_skip_structures: bool = false
var debug_disable_bots: bool = true          # Don't spawn bots on host
var debug_free_firing: bool = false          # No burn fuel cost when firing weapons
var debug_shotgun_boost: bool = false        # Double barrel: halved fire rate, doubled pellets
var debug_grapple_ground_pump: bool = false
var debug_grapple_reel_speed: float = 1.2  # Default reel speed (m/s)
var debug_grapple_visuals: bool = false     # Show pill, angle display, spheres, raycasts
var debug_grapple_horiz_nudge: bool = true # Launch nudge includes horizontal component toward anchor
var show_fps_hud: bool = true                # Show FPS counter on gameplay HUD
var debug_freecam_active: bool = false      # Set by DebugFreecam autoload

# Bubble / physics debug toggles (set from pause menu)
var debug_hide_bubbles: bool = false
var debug_bubble_no_ccd: bool = false
var debug_bubble_no_push_query: bool = false
var debug_bubble_one_contact: bool = false
var debug_bubble_freeze_settled: bool = false
var debug_bubble_no_contact_monitor: bool = false
var debug_bubble_no_collision: bool = false
var debug_bubble_no_separation: bool = false  # Disable bubble overlap repulsion
var debug_bubble_no_processing: bool = false  # Skip ALL bubble GDScript (wind, drift, overlap, damage)
var debug_velocity_iterations: int = 10
var debug_show_explosion_spheres: bool = false  # Show tower rubble explosion radii
var debug_show_explosion_rays: bool = false     # Show explosion raycast lines to wall blocks
var disable_debris: bool = false                 # Skip spawning cosmetic wall debris

# Toad dimension debug toggles (set from pause menu)
var debug_toad_no_physics: bool = false   # Disable all physics for toad rain bodies
var debug_toad_no_shadows: bool = false   # Disable shadow casting on toad rain bodies
var debug_toad_show_hitboxes: bool = false  # Show collision shape wireframe on toad bodies
var debug_toad_contacts: bool = false      # Log toad-side contact details (F10 toggles player-side, F11 toggles toad-side)
var debug_toad_mass: float = 4.0           # Runtime-adjustable toad mass (kg), default matches TOAD_MASS

signal game_state_changed(new_state: GameState)
signal match_started
signal match_ended
signal player_usernames_changed
signal god_mode_changed(enabled: bool)


func set_god_mode(enabled: bool) -> void:
	debug_god_mode = enabled
	debug_disable_burn_timers = enabled
	debug_disable_demon = enabled
	debug_disable_zone_damage = enabled
	god_mode_changed.emit(enabled)


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
