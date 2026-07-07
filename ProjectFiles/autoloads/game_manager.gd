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
## Gravity stress solver: structures fail under their own weight when support
## is inadequate (undamaged overhangs shear off, top-heavy builds rip their
## anchors). See GRAVITY_STRESS_PLAN.md. Toggle off to fall back to pure
## bond-connectivity destruction.
var gravity_stress_enabled: bool = true

## Perf/diagnostic logging for the destruction pipeline ([PERF], [ClusterPerf],
## [BondGraph], ...). A console print costs ~10ms on Windows; a big collapse
## emits 300+ lines, so leaving this on costs SECONDS of frame time per event.
var debug_perf_logging: bool = false


func plog(msg: String) -> void:
	## Gated print for hot-path perf/diagnostic logging. The string is still
	## formatted at the call site (µs), but the ~10ms console write is skipped
	## unless debug_perf_logging is on.
	if debug_perf_logging:
		print(msg)
var debug_disable_bots: bool = true          # Don't spawn bots on host
var debug_free_firing: bool = false          # No burn fuel cost when firing weapons
var debug_shotgun_boost: bool = false        # Double barrel: halved fire rate, doubled pellets
var debug_grapple_ground_pump: bool = false
var debug_grapple_reel_speed: float = 1.2  # Default reel speed (m/s)
var debug_grapple_visuals: bool = false     # Show pill, angle display, spheres, raycasts
var debug_grapple_safe_zone: bool = false  # Show ROPE_LOS_MARGIN sphere around anchor
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
var debug_explosion_diagnostics: bool = false    # Full scene-wide explosion diagnostic dump
var debug_show_structure_layers: bool = false     # Collision layer overlay on block structures

# Toad dimension debug toggles (set from pause menu)
var debug_toad_no_physics: bool = false   # Disable all physics for toad rain bodies
var debug_toad_no_shadows: bool = false   # Disable shadow casting on toad rain bodies
var debug_toad_show_hitboxes: bool = false  # Show collision shape wireframe on toad bodies
var debug_toad_contacts: bool = false      # Log toad-side contact details (F10 toggles player-side, F11 toggles toad-side)
var debug_toad_mass: float = 4.0           # Runtime-adjustable toad mass (kg), default matches TOAD_MASS
var debug_speed_50: bool = false               # Override player speed to 50
var debug_no_slope_projection: bool = false    # Disable slope projection entirely
var debug_no_landing_restore: bool = false     # Disable airborne hvel restore on landing
var debug_always_ground_move: bool = false     # Force ground movement even when airborne
var debug_show_collision: bool = false         # Show terrain collision meshes as transparent red
var debug_show_block_hits: bool = false       # Show wireframe box at hit/missed block shapes
var debug_dynamic_contact_log: bool = false  # F10: log velocity restore vs dynamic body contacts
var debug_dynamic_speed_scale: bool = true   # Scale speed by approach angle against dynamic bodies

# Render debug toggles (for profiling — toggle in pause menu to measure impact)
var debug_no_shadows: bool = false
var debug_shadow_distance: float = -1.0  # -1 = default, otherwise override
var debug_hide_clusters: bool = false
var debug_no_jump_unground: bool = false       # Don't unground on jump
var debug_no_force_airborne: bool = false      # Don't force airborne

# ── Physics diagnostics ────────────────────────────────────────────────
var debug_grounding_log: bool = false                # Log grounding transitions + snap + deflection + momentum
var debug_grounding_extend_snap: bool = false        # Extend snap range to 0.5m
var debug_dynamic_snap: bool = false                  # Scale snap budget by vel.y × delta to recover from steep-slope launches
var debug_snap_budget: float = 0.05                   # Static snap budget (m) extended when grounded last frame
var debug_grounding_no_snap_ground: bool = false     # Disable snap setting _is_grounded
var debug_no_snap: bool = false                       # Disable snap ENTIRELY (no pos/vel modification, no _is_grounded). For wedge-cause isolation tests.
var debug_no_walk_accel: bool = false                  # Disable walk-acceleration (skip _process_ground_movement / _process_air_movement). hvel passes through unchanged.
var debug_gravity_always: bool = false                 # Apply world-Y gravity unconditionally every frame (skip the grounded conditional that normally skips gravity on static contacts).
var debug_grounding_surface_press: bool = false      # Add downward vel.y after slope projection
var debug_grounding_press_strength: float = 1.0      # Surface press strength (m/s)
var debug_player_zero_friction: bool = false          # Set player friction to 0 (no solver friction drag)
var debug_no_floor_speed_restore: bool = false        # Disable horizontal speed restore on floor contacts
var debug_no_dynamic_speed_restore: bool = false      # Disable dynamic body impulse correction
var debug_no_wall_proj: bool = false                    # Disable wall projection entirely
var debug_wall_proj_dynamic: bool = false               # Enable wall projection on dynamic bodies (default: off)
var debug_no_wall_speed_scale: bool = false            # Disable wall trig speed scaling entirely
var debug_restore_full_speed: bool = false             # Restore full set_speed, ignore all solver changes
var debug_no_dime_stop: bool = false                    # Disable dime stop (instant direction change at low speed)

# ── Wedge stability experiments ───────────────────────────────────────
# When the player pushes a dynamic body that's wedged against a static
# wall, the body shakes because the script re-injects velocity each tick
# that the solver has to repeatedly kill. Each toggle below tries a
# different approach to suppress that shake. Test them individually
# (mostly mutually exclusive — combining gets weird).
var debug_wedge_lerp_direction: bool = false            # Lerp input direction toward wall-tangent by _dynamic_wall_fraction
var debug_wedge_hard_kill: bool = false                  # Above threshold, hard-project input as if wall were static (no lerp)
var debug_wedge_hard_kill_threshold: float = 0.7        # _dynamic_wall_fraction at which hard-kill activates
var debug_wedge_skip_inject: bool = false                # Don't write velocity when fraction > threshold; let solver decide
var debug_wedge_postsolver_base: bool = false            # Use post-solver velocity (Jolt's converged result) as starting point for input each tick
var debug_wedge_log: bool = false                        # Comprehensive box-press diagnostic: player state + box state + what the box is pressing into / phasing through

# ── Wedge fix #5/#6: _dynamic_wall_fraction lifecycle ─────────────────
# The fraction resets to 0 each tick and only updates when intended-into-wall
# velocity > 0.1 (deadband). When the wall projection is working, into-wall
# velocity drops below 0.1, the deadband skips the measurement, fraction
# falls back to 0, projection turns off, into-wall velocity comes back, etc.
# That oscillation IS the box-vs-wall shake. These toggles fix the lifecycle:
var debug_wedge_fraction_decay: bool = false             # Decay fraction instead of reset (slowly drains when no measurement)
var debug_wedge_fraction_decay_rate: float = 0.9         # Per-frame decay multiplier when above is on (1.0 = full hold, 0 = instant reset)
var debug_wedge_fraction_hold: bool = false              # Hold fraction at previous value while dyn wall contact still exists, even when deadband skips measurement

# ── Force-based input (architectural experiment) ──────────────────────
# Instead of overwriting state.linear_velocity each tick (the kinematic-feel
# pattern that prevents physics from reaching equilibrium against a wedged
# box), translate the desired velocity change into a central force and apply
# it via state.apply_central_force(). The cap limits how hard we can push:
#   F_cap = 2 × player.mass × WALK_ACCEL
# Doubling mass doubles cap, doubling walk accel doubles cap, doubling both
# quadruples it. With a finite force cap, a wedged box can actually push back
# harder than we push, and the system reaches static equilibrium.
var debug_restore_with_walls: bool = false              # Run horizontal restore even when touching static walls
var debug_instant_accel: bool = false                   # Set walk acceleration to 9999 (instant recovery)
var debug_floor_diag: bool = false                       # F9: dump full floor/dynamic-contact diagnostic per frame
var debug_floor_flicker: bool = false                    # F7: compact log of grounding transitions and floor-normal jumps
var debug_snap_log: bool = false                         # F5: log every potential-flicker frame's snap inputs/outputs
var debug_wedge_stutter: bool = false                    # F8: per-frame multi-contact wedge diagnostic — pos/vel deltas, contacts, pipeline trace
var debug_combined_capture_active: bool = false          # Press F8 or F9 to toggle. While true, debug_floor_diag and debug_wedge_stutter are forced on AND the C++ [CV-CAP] stream is requested every physics tick — press the same key again to stop. All three diagnostic streams are time-aligned. (F3 dropped because debug_freecam.gd already binds it to toggle the freecam.)
var debug_wedge_stick_to_walls: bool = false             # In compound contact (walkable below + non-walkable above), cancel only the OUTWARD velocity delta that the pipeline (walk_accel + slope_proj) added this frame. Drift is killed; pre-existing impulses are preserved.
var debug_wall_proj_full_normal: bool = false            # After slope-proj, project velocity against the FULL 3D normal of every active non-walkable contact (compound-contact constraint). Catches sloped-ceiling drift that horizontal-only wall-proj misses.
var debug_wedge_joint_proj: bool = false                 # JOINT compound-contact constraint: project velocity onto wedge axis (n_floor × n_other) so vel·n_floor = 0 AND vel·n_other = 0 hold simultaneously. Replaces sequential single-plane projections that fight each other. Restricts motion to wedge axis when geometrically wedged (correct physics).

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
# (triggered by start_tick_profile) OR when auto_profile_slow_ticks is on AND the
# previous tick exceeded slow_tick_threshold_us — that auto path catches lag
# spikes without manual triggering.
var _tick_profile_remaining: int = 0
var _tick_timing_us: Dictionary = {}     # subsystem -> total us this tick
var _tick_timing_count: Dictionary = {}  # subsystem -> call count this tick
var _frame_timing_us: Dictionary = {}    # subsystem -> total us (from _process)
var _frame_timing_count: Dictionary = {} # subsystem -> call count (from _process)
var _tick_number: int = 0

# Always-on fast accumulator for the graph (no Dictionary overhead)
var _tick_total_us: int = 0              # Running total for current tick
var last_tick_gdscript_us: int = 0       # Total from previous tick (read by HUD)

# Auto-profile slow ticks: when on, every tick populates _tick_timing_us and
# any tick whose gdscript total exceeds slow_tick_threshold_us prints a one-line
# breakdown labelled [SlowTick]. Cheap (one Dictionary insert per tick_add call)
# and catches frame spikes without user action.
var auto_profile_slow_ticks: bool = true
var slow_tick_threshold_us: int = 8000   # 8ms — catches anything over half a 60fps budget
var _tick_breakdown_us: Dictionary = {}    # subsystem -> us, current tick
var _tick_breakdown_count: Dictionary = {} # subsystem -> call count, current tick

# ── Continuous frame-time logger ────────────────────────────────────────────
# Periodic wall-clock measurement of physics ticks AND render frames. Lets us
# see if slideshow is physics-bound (ticks slipping behind 60Hz target) or
# render-bound (process_frames per second much lower than physics).
var debug_continuous_frame_log: bool = true
const FRAME_LOG_INTERVAL_S: float = 1.0    # window size in seconds
var _frame_log_window_start_us: int = 0
var _frame_log_tick_count: int = 0
var _frame_log_process_count: int = 0       # incremented from _process (render frames)
var _frame_log_tick_gdscript_us: int = 0    # GDScript-tracked tick time over window
var _frame_log_max_tick_gap_us: int = 0     # worst single-tick gap (real wall clock)
var _frame_log_last_tick_us: int = 0
var _frame_log_max_proc_gap_us: int = 0
var _frame_log_last_proc_us: int = 0


func _ready() -> void:
	process_physics_priority = -100  # Run before all game nodes
	ExplosionHelper.prewarm()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F7:
			debug_floor_flicker = not debug_floor_flicker
			print("[FloorFlicker] %s" % ("ON" if debug_floor_flicker else "OFF"))
		elif event.keycode == KEY_F5:
			debug_snap_log = not debug_snap_log
			print("[SnapLog] %s" % ("ON" if debug_snap_log else "OFF"))
		elif event.keycode == KEY_F8 or event.keycode == KEY_F9:
			# Unified capture toggle: press once to start, press again (F8 or F9) to stop.
			# Turns on debug_floor_diag, debug_wedge_stutter, and the C++ [CV-CAP] stream
			# so all three diagnostic streams are time-aligned. F3 is reserved by
			# debug_freecam.gd so we can't include it.
			debug_combined_capture_active = not debug_combined_capture_active
			debug_floor_diag = debug_combined_capture_active
			debug_wedge_stutter = debug_combined_capture_active
			print("[CV-CAP] Combined capture %s" % ("STARTED — press F8 or F9 again to stop" if debug_combined_capture_active else "STOPPED"))


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
	if auto_profile_slow_ticks:
		_tick_breakdown_us[subsystem] = _tick_breakdown_us.get(subsystem, 0) + us
		_tick_breakdown_count[subsystem] = _tick_breakdown_count.get(subsystem, 0) + 1


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


func _blockpen_monitor() -> void:
	## Measure PushBlock penetration into static geometry (see call site).
	## For each PushBlock within 15 m of the host player: an intersect_shape
	## names the overlapping static bodies, a collide_shape gives contact-pair
	## depths. Prints one [BLOCKPEN] line per penetrating block per tick.
	var cs := get_tree().current_scene
	if cs == null:
		return
	var blocks: Node = cs.get_node_or_null("SeedWorld/PushBlocks")
	if blocks == null:
		blocks = cs.find_child("PushBlocks", true, false)
	if blocks == null:
		return
	var players := cs.get_node_or_null("Players")
	var pl: Node3D = players.get_node_or_null("1") as Node3D if players else null
	var world: World3D = (blocks as Node3D).get_world_3d() if blocks is Node3D else null
	if world == null:
		return
	var dss := world.direct_space_state

	for b in blocks.get_children():
		var rb := b as RigidBody3D
		if rb == null:
			continue
		if pl != null and rb.global_position.distance_to(pl.global_position) > 15.0:
			continue
		var col: CollisionShape3D = null
		for child in rb.get_children():
			if child is CollisionShape3D:
				col = child
				break
		if col == null or col.shape == null:
			continue
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = col.shape
		params.transform = col.global_transform
		# Static world geometry only: terrain/statics + wall hulls + per-block
		# wall bodies. Excludes the block itself (and other dynamics aren't in
		# the mask except fellow WALL_SMOOTH bodies — names disambiguate).
		params.collision_mask = CollisionLayers.WORLD | CollisionLayers.WALL_SMOOTH | CollisionLayers.WALL_BLOCKS
		params.exclude = [rb.get_rid()]
		var hits := dss.intersect_shape(params, 6)
		if hits.is_empty():
			continue
		var pairs := dss.collide_shape(params, 6)
		var max_depth := 0.0
		var j := 0
		while j + 1 < pairs.size():
			max_depth = maxf(max_depth, pairs[j].distance_to(pairs[j + 1]))
			j += 2
		if max_depth < 0.005:
			continue  # sub-slop contact, not worth a line
		var names := ""
		for h in hits:
			var hc: Object = h.get("collider")
			names += ("%s " % (hc.name if hc is Node else "?"))
		print("[BLOCKPEN] %s overlap=%.3f m into: %s@ pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f)" % [
			rb.name, max_depth, names,
			rb.global_position.x, rb.global_position.y, rb.global_position.z,
			rb.linear_velocity.x, rb.linear_velocity.y, rb.linear_velocity.z])


func _physics_process(_delta: float) -> void:
	# Always publish previous tick's total for the HUD graph (pink line)
	last_tick_gdscript_us = _tick_total_us
	_tick_total_us = 0

	# [BLOCKPEN] — while the F8/F9 capture is on, directly measure how deep
	# nearby PushBlocks sit inside STATIC geometry each physics tick (shape
	# overlap pair depths + collider names). Body-vs-wall penetration is
	# invisible to every other diagnostic stream (the CV capture only sees the
	# player's own contacts), so "the block is phasing into the wall" reports
	# get hard numbers: which wall body, how deep, where.
	if debug_combined_capture_active:
		_blockpen_monitor()


	# (see _blockpen_monitor below for the [BLOCKPEN] stream)

	# Continuous frame-time logger using wall-clock time. Tracks how many
	# physics ticks AND render frames actually happened in the window. If
	# tick_rate < 60 → physics is slipping. If proc_rate < tick_rate → render
	# is the bottleneck.
	if debug_continuous_frame_log:
		var now := Time.get_ticks_usec()
		_frame_log_tick_count += 1
		_frame_log_tick_gdscript_us += last_tick_gdscript_us
		if _frame_log_last_tick_us > 0:
			var gap := now - _frame_log_last_tick_us
			if gap > _frame_log_max_tick_gap_us:
				_frame_log_max_tick_gap_us = gap
		_frame_log_last_tick_us = now

		if _frame_log_window_start_us == 0:
			_frame_log_window_start_us = now
		var window_us := now - _frame_log_window_start_us
		if window_us >= int(FRAME_LOG_INTERVAL_S * 1_000_000.0):
			var tick_rate := float(_frame_log_tick_count) * 1_000_000.0 / float(window_us)
			var proc_rate := float(_frame_log_process_count) * 1_000_000.0 / float(window_us)
			var avg_gdscript_per_tick: int = 0
			if _frame_log_tick_count > 0:
				avg_gdscript_per_tick = _frame_log_tick_gdscript_us / _frame_log_tick_count
			print("[FrameLog] %.1f tick/s  %.1f proc/s (render)  avg_gdscript_per_tick=%dus  max_tick_gap=%dus  max_proc_gap=%dus" % [
				tick_rate, proc_rate,
				avg_gdscript_per_tick,
				_frame_log_max_tick_gap_us,
				_frame_log_max_proc_gap_us])
			_frame_log_window_start_us = now
			_frame_log_tick_count = 0
			_frame_log_process_count = 0
			_frame_log_tick_gdscript_us = 0
			_frame_log_max_tick_gap_us = 0
			_frame_log_max_proc_gap_us = 0



	# Auto-print slow-tick breakdown. Runs PREVIOUS tick's accumulated breakdown
	# if its total exceeded the threshold. Then clears for next tick.
	if auto_profile_slow_ticks:
		if last_tick_gdscript_us >= slow_tick_threshold_us and not _tick_breakdown_us.is_empty():
			var sorted_bk := _tick_breakdown_us.keys()
			sorted_bk.sort_custom(func(a, b): return _tick_breakdown_us[a] > _tick_breakdown_us[b])
			var bk_parts: PackedStringArray = []
			for key in sorted_bk:
				var bus: int = _tick_breakdown_us[key]
				var bcount: int = _tick_breakdown_count.get(key, 1)
				if bcount > 1:
					bk_parts.append("%s=%dus(x%d)" % [key, bus, bcount])
				else:
					bk_parts.append("%s=%dus" % [key, bus])
			print("[SlowTick] total=%dus  %s" % [last_tick_gdscript_us, "  ".join(bk_parts)])
		_tick_breakdown_us.clear()
		_tick_breakdown_count.clear()

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

	# Render-frame counter for the FrameLog logger in _physics_process.
	if debug_continuous_frame_log:
		_frame_log_process_count += 1
		var now := Time.get_ticks_usec()
		if _frame_log_last_proc_us > 0:
			var gap := now - _frame_log_last_proc_us
			if gap > _frame_log_max_proc_gap_us:
				_frame_log_max_proc_gap_us = gap
		_frame_log_last_proc_us = now
