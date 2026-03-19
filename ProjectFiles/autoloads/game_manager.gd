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
var debug_disable_detached_structures: bool = false
var debug_disable_bots: bool = true          # Don't spawn bots on host
var debug_free_firing: bool = false          # No burn fuel cost when firing weapons
var debug_shotgun_boost: bool = false        # Double barrel: halved fire rate, doubled pellets
var debug_grapple_ground_pump: bool = false
var debug_grapple_reel_speed: float = 1.2  # Default reel speed (m/s)
var debug_grapple_visuals: bool = false     # Show pill, angle display, spheres, raycasts
var debug_grapple_horiz_nudge: bool = true # Launch nudge includes horizontal component toward anchor
var show_fps_hud: bool = true                # Show FPS counter on gameplay HUD
var debug_freecam_active: bool = false      # Set by DebugFreecam autoload
var frame_advance_start_us: int = 0        # Timestamp when frame advance unpaused (0 = not advancing)

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
var debug_lagger_delay_ms: float = 2.0           # Lagger weapon: ms to stall per tick/shot
var debug_lagger_overhead_mode: bool = true      # true = stall every tick, false = stall on fire only
var debug_explosion_repeat: bool = false         # Run C++ shielding calc 4x for perf testing

# Toad dimension debug toggles (set from pause menu)
var debug_toad_no_physics: bool = false   # Disable all physics for toad rain bodies
var debug_toad_no_shadows: bool = false   # Disable shadow casting on toad rain bodies
var debug_toad_show_hitboxes: bool = false  # Show collision shape wireframe on toad bodies
var debug_toad_contacts: bool = false      # Log toad-side contact details (F10 toggles player-side, F11 toggles toad-side)
var debug_toad_mass: float = 4.0           # Runtime-adjustable toad mass (kg), default matches TOAD_MASS
var debug_disable_surface_press: bool = false  # Disable floor surface press in player movement
var debug_speed_50: bool = false               # Override player speed to 50
var debug_no_gravity_sweep: bool = false       # Use normal gravity instead of shape sweep
var debug_sweep_1m: bool = false               # Extend sweep distance to 1 meter
var debug_no_slope_projection: bool = false    # Disable slope projection entirely
var debug_sweep_sets_grounded: bool = false    # Sweep result overrides _is_grounded
var debug_no_landing_restore: bool = false     # Disable airborne hvel restore on landing
var debug_sweep_before_move: bool = false      # Run gravity sweep before air/ground decision
var debug_always_ground_move: bool = false     # Force ground movement even when airborne
var debug_sweep_in_prephys: bool = false       # Run sweep in pre_physics_step right after contact check
var debug_show_collision: bool = false         # Show terrain collision meshes as transparent red
var debug_no_contact_unground: bool = false    # Don't unground when Jolt contacts are lost
var debug_no_jump_unground: bool = false       # Don't unground on jump
var debug_no_force_airborne: bool = false      # Don't force airborne

# ── Grounding flicker diagnostics ──────────────────────────────────────
var debug_grounding_surface_press: bool = false     # Add small downward vel.y after slope projection to maintain contact
var debug_grounding_press_strength: float = 1.0     # Surface press strength (m/s downward)
var debug_grounding_no_snap_ground: bool = false     # Disable snap-to-ground setting _is_grounded
var debug_grounding_no_perp_strip: bool = false      # Disable perpendicular velocity stripping
var debug_grounding_extend_snap: bool = false        # Extend snap range to 0.5m (vs normal vel-based)
var debug_grounding_no_pos_correction: bool = false  # Disable landing position correction
var debug_grounding_log: bool = false                # Print grounding state transitions every frame

# Structure collision tuning (set from pause menu, all default to 1.0 base ratio)
var structure_momentum_damage_scale: float = 1.0    # Multiplier on momentum → structure damage
var structure_explosion_radius_scale: float = 1.0    # Multiplier on breakthrough explosion radius
var structure_explosion_damage_scale: float = 1.0    # Multiplier on breakthrough explosion damage
var structure_resistance_scale: float = 1.0          # Multiplier on HP-based slowdown (how much blocks resist)

signal game_state_changed(new_state: GameState)
signal match_started
signal match_ended
signal player_usernames_changed
signal god_mode_changed(enabled: bool)

# ── Physics tick profiler ────────────────────────────────────────────────
# Always-on: tick_add() accumulates a fast running total (_tick_total_us)
# every tick. At the start of each tick, the previous total is published
# to last_tick_gdscript_us (read by HUDPerfGraph for the pink line).
#
# Per-subsystem Dictionary breakdown only records when _tick_profile_remaining > 0
# (triggered by start_tick_profile). This keeps always-on overhead minimal.
var _tick_profile_remaining: int = 0
var _tick_timing_us: Dictionary = {}     # subsystem -> total us this tick
var _tick_timing_count: Dictionary = {}  # subsystem -> call count this tick
var _frame_timing_us: Dictionary = {}    # subsystem -> total us (from _process)
var _frame_timing_count: Dictionary = {} # subsystem -> call count (from _process)
var _tick_number: int = 0

# Always-on fast accumulator for the graph (no Dictionary overhead)
var _tick_total_us: int = 0              # Running total for current tick
var last_tick_gdscript_us: int = 0       # Total from previous tick (read by HUD)


func _ready() -> void:
	process_physics_priority = -100  # Run before all game nodes


func start_tick_profile(num_ticks: int) -> void:
	_tick_profile_remaining = num_ticks
	_tick_number = 0
	_tick_timing_us.clear()
	_tick_timing_count.clear()
	_frame_timing_us.clear()
	_frame_timing_count.clear()
	print("[TickProfile] Started: profiling next %d ticks" % num_ticks)


func tick_add(subsystem: String, us: int) -> void:
	## Call from _physics_process or body_entered handlers to record subsystem time.
	## Always accumulates the fast total; per-subsystem breakdown only when profiling.
	_tick_total_us += us
	if _tick_profile_remaining > 0:
		_tick_timing_us[subsystem] = _tick_timing_us.get(subsystem, 0) + us
		_tick_timing_count[subsystem] = _tick_timing_count.get(subsystem, 0) + 1


func frame_add(subsystem: String, us: int) -> void:
	## Call from _process to record per-frame subsystem time (e.g. greedy mesh).
	if _tick_profile_remaining <= 0:
		return
	_frame_timing_us[subsystem] = _frame_timing_us.get(subsystem, 0) + us
	_frame_timing_count[subsystem] = _frame_timing_count.get(subsystem, 0) + 1


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


func _physics_process(_delta: float) -> void:
	# Always publish previous tick's total for the HUD graph (pink line)
	last_tick_gdscript_us = _tick_total_us
	_tick_total_us = 0

	# Per-subsystem console profiling (only when explicitly triggered)
	if _tick_profile_remaining <= 0:
		return

	# Print PREVIOUS tick's data (collected during that tick's callbacks)
	if _tick_number > 0 and (not _tick_timing_us.is_empty() or not _frame_timing_us.is_empty()):
		var parts: PackedStringArray = []
		var total_us := 0

		# Sort physics-tick timings by time descending
		var sorted_keys := _tick_timing_us.keys()
		sorted_keys.sort_custom(func(a, b): return _tick_timing_us[a] > _tick_timing_us[b])
		for key in sorted_keys:
			var us: int = _tick_timing_us[key]
			var count: int = _tick_timing_count.get(key, 1)
			total_us += us
			if count > 1:
				parts.append("%s=%dus(x%d)" % [key, us, count])
			else:
				parts.append("%s=%dus" % [key, us])

		# Frame timings (from _process, marked with pipes)
		for key in _frame_timing_us:
			var us: int = _frame_timing_us[key]
			var count: int = _frame_timing_count.get(key, 1)
			if count > 1:
				parts.append("|%s=%dus(x%d)|" % [key, us, count])
			else:
				parts.append("|%s=%dus|" % [key, us])

		print("[TickProfile #%d] gdscript=%dus  %s" % [_tick_number, total_us, "  ".join(parts)])

	_tick_timing_us.clear()
	_tick_timing_count.clear()
	_frame_timing_us.clear()
	_frame_timing_count.clear()
	_tick_number += 1
	_tick_profile_remaining -= 1


func _process(delta: float) -> void:
	if current_state == GameState.PLAYING:
		match_time_elapsed += delta
