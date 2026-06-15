extends Node3D

# Headless regression test for the CharacterVirtual movement saga. Each phase
# encodes a bug family that has regressed before ("fix player shaking when
# pressing into walls" conversation):
#
#   B: walking across flush box seams (voxel-structure boundaries) — the
#      internal-edge "invisible wall" family. Any frame where we command
#      8 m/s on open walkable ground but barely move is a STUCK frame → FAIL.
#   C: walking across a fan of tilted walkable surfaces (multi-contact frames
#      with disagreeing normals) — the solver ping-pong stall family. Same
#      stuck-frame assertion.
#   D: pressing into a 90° corner of two non-walkable walls — the original
#      corner-shake family. We must pin smoothly: no position oscillation,
#      no riding up the seam.
#   E: walking up a walkable ramp — the uphill-speed-loss family. The
#      once-per-contact-per-frame listener restore must still hold speed.
#      Then stopping — the post-stop-hop family: no upward drift.
#
# The velocity pipeline mimics apply_cv_move: gravity folded in EVERY frame,
# velocity carried forward as position-delta / dt.
#
# Run headless: Godot --headless res://tests/test_cv_stuck_regression.tscn

const GRAVITY_MAG := 24.0
const GRAVITY := Vector3(0, -GRAVITY_MAG, 0)
const STEP_DOWN := 0.45
const WALK_SPEED := 8.0

var _cv: JoltCharacterVirtual3D
var _frames := 0
var _phase := 0
var _phase_frames := 0
var _vel := Vector3.ZERO
var _prev_pos := Vector3.ZERO
var _failures: Array[String] = []

# Phase-local accumulators.
var _stuck_frames := 0
var _corner_start_y := 0.0
var _corner_jitter_peak := 0.0
var _climb_h_speeds: Array[float] = []
var _stop_start_y := 0.0
var _stop_peak_rise := 0.0
var _hill_start := Vector3.ZERO
var _bnf_start := Vector3.ZERO
var _air_frames := 0
var _k_cross_frame := -1
var _k_pre_vy := 0.0
var _k_descended := false


func _ready() -> void:
	_make_floor()
	_make_seam_row()
	_make_tilted_fan()
	_make_corner()
	_make_ramp()
	_make_side_hill()

	_cv = JoltCharacterVirtual3D.new()
	_cv.name = "Character"
	_cv.capsule_radius = 0.4
	_cv.capsule_height = 1.8
	_cv.character_mass = 70.0
	_cv.up_direction = Vector3.UP
	_cv.collision_layer = 1
	_cv.collision_mask = 1
	_cv.inner_body = false
	_cv.max_slope_angle_deg = 50.0
	_cv.predictive_contact_distance = 0.2
	_cv.enhanced_internal_edge_removal = true
	_cv.position = Vector3(-6.0, 1.0, 0.0)
	add_child(_cv)


func _make_static_box(parent_name: String, size: Vector3, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> void:
	var body := StaticBody3D.new()
	body.name = parent_name
	body.collision_layer = 1
	body.collision_mask = 1
	add_child(body)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = pos
	col.rotation_degrees = rot
	body.add_child(col)


func _make_floor() -> void:
	# Big flat floor, top at y = 0.
	_make_static_box("Floor", Vector3(120, 1, 40), Vector3(0, -0.5, 0))


func _make_seam_row() -> void:
	# Phase B track: a row of flush 1 m boxes, tops at y = 0.001 so the seams
	# (not the floor) are what the capsule rides on. x from 0 to 12, z = 0.
	for i in range(12):
		_make_static_box("Seam%d" % i, Vector3(1, 1, 4), Vector3(0.5 + float(i), -0.4985, 0))


func _make_tilted_fan() -> void:
	# Phase C track: overlapping walkable slabs at alternating small tilts —
	# the capsule's bottom touches several at once with normals up to ~20°
	# apart. Slabs are narrow (1.2 m) so the exposed risers at the overlaps
	# stay ≤ ~0.11 m: on a 0.4 m-radius capsule bottom such a riser produces
	# a WALKABLE sphere contact (normal ≈ 41° from up), so any stall here is
	# the solver bug, not a legitimate wall. x from ~16 to ~23, z = 0.
	var tilts := [
		Vector3(0, 0, 10), Vector3(8, 0, -8), Vector3(0, 0, -9),
		Vector3(-7, 0, 5), Vector3(0, 0, 10), Vector3(9, 0, 0),
		Vector3(0, 0, -10), Vector3(-8, 0, 8),
	]
	for i in range(tilts.size()):
		_make_static_box("Fan%d" % i, Vector3(1.2, 0.6, 5), Vector3(16.6 + float(i) * 0.8, -0.25, 0), tilts[i])


func _make_corner() -> void:
	# Phase D: two vertical walls meeting at 90°, seam along x = 34, z = 2.
	_make_static_box("WallA", Vector3(6, 6, 1), Vector3(31.0, 3.0, 2.5))
	_make_static_box("WallB", Vector3(1, 6, 6), Vector3(34.5, 3.0, -0.5))


func _make_ramp() -> void:
	# Phase E: 25° ramp rising along +X (+Z-rotation lifts the +X end), low end
	# buried in the floor — the top surface emerges at x ≈ 40.5, z = -8 lane.
	_make_static_box("Ramp", Vector3(14, 1, 6), Vector3(46.0, 2.0, -8.0), Vector3(0, 0, 25))
	# Phase K: a 56° (non-walkable) continuation roughly tangent to the ramp's
	# crest — together they form a "curved ramp" that steepens past the
	# walkable limit mid-climb.
	_make_static_box("SteepCap", Vector3(10, 1, 6), Vector3(55.3, 9.3, -8.0), Vector3(0, 0, 56))


func _make_side_hill() -> void:
	# Phase F: a wide slab tilted 18° about X — walking along +X is walking
	# along the contour line of a hill that falls away toward +Z. The walk
	# direction is commanded straight +X; any +Z motion is downhill drift
	# (the "redirected on hills" family).
	_make_static_box("SideHill", Vector3(30, 1, 12), Vector3(0, 0.0, -30.0), Vector3(18, 0, 0))
	# Phase I: a vertical wall standing on the hill's uphill side, face toward
	# +Z (downhill) — sloped floor + wall is the logged wall-slide-stall
	# geometry (multi-plane corner clips used to trip the reversal early-out).
	_make_static_box("HillWall", Vector3(20, 4, 1), Vector3(0, 2.5, -33.2))


func _drive(cmd_h: Vector3, delta: float, overwrite_h: bool = true) -> Vector3:
	# Mimic apply_cv_move: write commanded horizontal, friction-couple vy to the
	# horizontal change (the player pipeline's normal-free decay), fold gravity
	# every frame, run the CV, carry velocity forward as position-delta / dt.
	# overwrite_h = false models the game's AIRBORNE/steep-ground state, where
	# momentum is preserved (walk-accel doesn't own the velocity).
	var old_h := Vector2(_vel.x, _vel.z).length()
	if overwrite_h:
		_vel.x = cmd_h.x
		_vel.z = cmd_h.z
	var grounded := _cv.get_ground_state() == 0
	if grounded and old_h > 1.0e-4:
		# Decay-only, like the game pipeline: an unclamped ratio amplifies vy
		# exponentially when walls clip h and input re-grows it each frame.
		_vel.y *= minf(Vector2(_vel.x, _vel.z).length() / old_h, 1.0)
	_vel.y -= GRAVITY_MAG * delta
	_prev_pos = _cv.get_character_position()
	_cv.extended_update(_vel, delta, GRAVITY, 0.0, STEP_DOWN)
	var moved := _cv.get_character_position() - _prev_pos
	_vel = moved / delta
	return moved


func _check_stuck(moved: Vector3, delta: float, label: String) -> void:
	# The stuck signature: commanded WALK_SPEED on open walkable ground but the
	# horizontal displacement collapsed. 30% is generous — real stalls are ~0%.
	var h_moved := Vector2(moved.x, moved.z).length()
	if h_moved < WALK_SPEED * delta * 0.3:
		_stuck_frames += 1
		_failures.append("%s f%d: STUCK frame — commanded %.1f m/s, moved %.4f m (%.1f m/s)" % [
			label, _phase_frames, WALK_SPEED, h_moved, h_moved / delta])


func _physics_process(delta: float) -> void:
	_frames += 1
	if _frames < 8:
		return
	if not _cv.is_ready():
		_cv.update(Vector3.ZERO, delta, GRAVITY)
		if _frames < 60:
			return
		print("[TEST] FAIL: CharacterVirtual never became ready")
		get_tree().quit(1)
		return

	_phase_frames += 1
	match _phase:
		0:
			# Settle onto the floor.
			_drive(Vector3.ZERO, delta)
			if _phase_frames >= 20:
				print("[TEST] === Phase B: seam row (voxel boundary family) ===")
				_cv.teleport(Vector3(-1.5, 1.05, 0.0))
				_vel = Vector3.ZERO
				_next_phase()
		1:
			# Phase B: walk +X across 12 flush box seams at 8 m/s.
			var settle := _phase_frames <= 10
			var moved := _drive(Vector3(WALK_SPEED, 0, 0) if not settle else Vector3.ZERO, delta)
			if not settle and _phase_frames > 13:  # allow 3 frames of spin-up
				_check_stuck(moved, delta, "seam-row")
			if _cv.get_character_position().x > 11.5 or _phase_frames > 240:
				if _cv.get_character_position().x <= 11.5:
					_failures.append("seam-row: never reached the end (x=%.2f after %d frames)" % [
						_cv.get_character_position().x, _phase_frames])
				print("[TEST] seam row done: x=%.2f stuck_frames=%d" % [_cv.get_character_position().x, _stuck_frames])
				print("[TEST] === Phase C: tilted fan (multi-normal family) ===")
				_cv.teleport(Vector3(15.0, 1.2, 0.0))
				_vel = Vector3.ZERO
				_next_phase()
		2:
			# Phase C: walk +X across the tilted slabs at 8 m/s.
			var settle := _phase_frames <= 10
			var moved := _drive(Vector3(WALK_SPEED, 0, 0) if not settle else Vector3.ZERO, delta)
			if not settle and _phase_frames > 13:
				_check_stuck(moved, delta, "tilted-fan")
			if _cv.get_character_position().x > 23.5 or _phase_frames > 240:
				if _cv.get_character_position().x <= 23.5:
					_failures.append("tilted-fan: never reached the end (x=%.2f after %d frames)" % [
						_cv.get_character_position().x, _phase_frames])
				print("[TEST] tilted fan done: x=%.2f stuck_frames=%d" % [_cv.get_character_position().x, _stuck_frames])
				print("[TEST] === Phase D: corner press (corner-shake family) ===")
				_cv.teleport(Vector3(32.0, 1.0, -1.0))
				_vel = Vector3.ZERO
				_next_phase()
		3:
			# Phase D: press diagonally into the 90° corner seam. The first
			# ~40 frames are the legitimate approach + slide-along-wall; the
			# jitter window starts once we're pinned at the seam.
			var moved := _drive(Vector3(1, 0, 1).normalized() * WALK_SPEED, delta)
			if _phase_frames == 45:
				_corner_start_y = _cv.get_character_position().y
			elif _phase_frames > 45:
				# After pinning, every frame's displacement must stay tiny and
				# the capsule must not climb the seam.
				var jitter := moved.length()
				_corner_jitter_peak = max(_corner_jitter_peak, jitter)
				var rise := _cv.get_character_position().y - _corner_start_y
				if jitter > 0.03:
					_failures.append("corner f%d: oscillation — |moved| = %.4f m in one frame" % [_phase_frames, jitter])
				if rise > 0.08:
					_failures.append("corner f%d: riding up the seam — rose %.3f m" % [_phase_frames, rise])
			if _phase_frames >= 90:
				print("[TEST] corner done: jitter_peak=%.4f m rise=%.3f m" % [
					_corner_jitter_peak, _cv.get_character_position().y - _corner_start_y])
				print("[TEST] === Phase E: ramp climb + stop (speed-loss / hop families) ===")
				_cv.teleport(Vector3(40.5, 1.1, -8.0))
				_vel = Vector3.ZERO
				_next_phase()
		4:
			# Phase E1: climb the 25° ramp at 8 m/s commanded for 45 frames.
			# Horizontal speed is preserved verbatim on walkable slopes ("don't
			# slow me down walking up hills") — a 3D speed budget was tried and
			# reverted (read as "suddenly slowed on the ramp" / "invisible glue
			# downhill"). Sanity bound: |v| ≤ h/cos25° + slack.
			var settle := _phase_frames <= 10
			var moved := _drive(Vector3(WALK_SPEED, 0, 0) if not settle else Vector3.ZERO, delta)
			if not settle and _phase_frames > 20:
				_climb_h_speeds.append(Vector2(moved.x, moved.z).length() / delta)
				var speed_3d := moved.length() / delta
				if speed_3d > WALK_SPEED / cos(deg_to_rad(25.0)) + 0.5:
					_failures.append("ramp f%d: speed beyond slope tangent — |v| = %.2f" % [
						_phase_frames, speed_3d])
			if _phase_frames >= 55:
				var avg := 0.0
				for s in _climb_h_speeds:
					avg += s
				avg /= maxf(1.0, float(_climb_h_speeds.size()))
				print("[TEST] ramp climb avg horizontal speed = %.2f m/s (commanded %.1f)" % [avg, WALK_SPEED])
				if avg < WALK_SPEED * 0.93:
					_failures.append("ramp: uphill speed loss — avg %.2f m/s of commanded %.1f" % [avg, WALK_SPEED])
				_stop_start_y = _cv.get_character_position().y
				_next_phase()
		5:
			# Phase E2: release input on the ramp — must not hop upward.
			_drive(Vector3.ZERO, delta)
			_stop_peak_rise = max(_stop_peak_rise, _cv.get_character_position().y - _stop_start_y)
			if _phase_frames >= 40:
				print("[TEST] post-stop peak rise = %.3f m" % _stop_peak_rise)
				if _stop_peak_rise > 0.06:
					_failures.append("ramp stop: post-stop hop — rose %.3f m after input release" % _stop_peak_rise)
				print("[TEST] === Phase F: side hill (downhill-redirect family) ===")
				_cv.teleport(Vector3(-12.0, 2.0, -31.0))
				_vel = Vector3.ZERO
				_next_phase()
		6:
			# Phase F: walk straight +X along the contour of a hill falling away
			# toward +Z. Any accumulated +Z motion is gravity-clip downhill drift.
			var settle := _phase_frames <= 12
			_drive(Vector3(WALK_SPEED, 0, 0) if not settle else Vector3.ZERO, delta)
			if _phase_frames == 13:
				_hill_start = _cv.get_character_position()
			if _phase_frames >= 73:
				var pos := _cv.get_character_position()
				var x_run := pos.x - _hill_start.x
				var z_drift := pos.z - _hill_start.z
				var drift_deg := rad_to_deg(atan2(absf(z_drift), maxf(0.001, x_run)))
				print("[TEST] side hill: ran %.2f m along +X, lateral drift %.3f m (%.2f° off course)" % [
					x_run, z_drift, drift_deg])
				if x_run < 6.0:
					_failures.append("side-hill: stalled — only ran %.2f m" % x_run)
				if absf(z_drift) > 0.08:
					_failures.append("side-hill: downhill redirect — drifted %.3f m (%.2f°) over %.2f m of straight walking" % [
						z_drift, drift_deg, x_run])
				print("[TEST] === Phase G: back-and-forth on hill (creep family) ===")
				_cv.teleport(Vector3(0.0, 2.0, -30.0))
				_vel = Vector3.ZERO
				_next_phase()
		7:
			# Phase G1: perfectly symmetric back-and-forth ACROSS the hill
			# (±X along the contour): 4 cycles of 40 frames each direction with
			# 5-frame idle gaps. Any net displacement is mechanical creep —
			# there is zero input asymmetry here.
			_run_back_and_forth(delta, Vector3(1, 0, 0), "across-hill")
		8:
			# Phase G2: same, UP/DOWN the fall line (±Z): the user-reported
			# "moving back and forth slides me down the hill" geometry.
			_run_back_and_forth(delta, Vector3(0, 0, 1), "up-down-hill")
		9:
			if _phase_frames == 1:
				print("[TEST] === Phase H: sprint into ramp base (transition-launch family) ===")
				_cv.teleport(Vector3(36.0, 1.1, -8.0))
				_vel = Vector3.ZERO
			# Phase H: sprint at full speed across flat ground into the base of
			# the 25° ramp. The re-seat must not convert the transition into a
			# launch: the character must stay grounded through the impact (the
			# bug signature was several consecutive InAir frames right after
			# touching the slope base) and keep climbing.
			var settle := _phase_frames <= 12
			_drive(Vector3(WALK_SPEED, 0, 0) if not settle else Vector3.ZERO, delta)
			if not settle and _cv.get_ground_state() == 3:
				_air_frames += 1
			if _phase_frames >= 62:
				var x_end := _cv.get_character_position().x
				print("[TEST] ramp-base sprint: x=%.2f air_frames=%d" % [x_end, _air_frames])
				if _air_frames > 0:
					_failures.append("ramp-base: launched — %d InAir frame(s) sprinting into the slope base" % _air_frames)
				if x_end < 42.0:
					_failures.append("ramp-base: stalled at the transition (x=%.2f)" % x_end)
				print("[TEST] === Phase I: wall slide on a hill (slide-stall family) ===")
				_cv.teleport(Vector3(-8.0, 2.2, -32.0))
				_vel = Vector3.ZERO
				_next_phase()
		10:
			# Phase I: standing on the 18° hill, press 75° INTO the wall above
			# (only cos75 ≈ 0.26 of the command is along it). The engine must
			# deliver the tangential component every frame — the reversal
			# early-out used to zero whole frames here ("couldn't slide on it
			# unless i turned a lot"). The trig speed cap itself lives in
			# GDScript walk-accel target shaping, not in the engine; what the
			# engine owes us is faithful tangential passthrough with no stalls.
			var settle := _phase_frames <= 12
			var cmd := Vector3(cos(deg_to_rad(75.0)), 0, -sin(deg_to_rad(75.0))) * WALK_SPEED
			var moved := _drive(cmd if not settle else Vector3.ZERO, delta)
			var tangent_per_frame := WALK_SPEED * cos(deg_to_rad(75.0)) * delta
			if not settle and _phase_frames > 20:
				if moved.x < tangent_per_frame * 0.5:
					_stuck_frames += 1
					_failures.append("wall-slide f%d: stalled — moved.x %.4f of expected %.4f" % [
						_phase_frames, moved.x, tangent_per_frame])
			if _phase_frames >= 72:
				var x_run := _cv.get_character_position().x - (-8.0)
				print("[TEST] wall slide: advanced %.2f m along the wall in 60 frames (expect ≈ %.2f)" % [
					x_run, WALK_SPEED * cos(deg_to_rad(75.0)) * 1.0])
				print("[TEST] === Phase J: corner wedge press (vy-amplifier rocket family) ===")
				_cv.teleport(Vector3(32.4, 1.0, 0.4))
				_vel = Vector3.ZERO
				_next_phase()
		11:
			# Phase J: vy-amplifier rocket family. Press 75° into the hill wall
			# (phase I spot) with the game-like pipeline: the wall clips h from
			# 8 down to ~2 every frame and the command re-grows it, so the
			# h-ratio is ~3.9 per frame — an UNCLAMPED vy coupling multiplies
			# vy by that every frame (logged in-game: 12 → 24 → 45 m/s rocket;
			# also drives vy downward into floor penetration + recovery pops).
			# With the decay-only clamp, vy must stay bounded near zero.
			if _phase_frames == 1:
				_cv.teleport(Vector3(-8.0, 2.2, -32.0))
				_vel = Vector3.ZERO
				_corner_start_y = 0.0
			var cmd := Vector3(cos(deg_to_rad(75.0)), 0, -sin(deg_to_rad(75.0))) * WALK_SPEED
			_drive(cmd if _phase_frames > 12 else Vector3.ZERO, delta)
			if _phase_frames == 12:
				_corner_start_y = _cv.get_character_position().y
			elif _phase_frames > 20:
				# Skip the first contact frames (a brief legitimate redirect
				# transient as the capsule meets the wall). The amplifier
				# signature is SUSTAINED |vy| while wedged — it compounds, it
				# doesn't settle.
				var rise := _cv.get_character_position().y - _corner_start_y
				if absf(_vel.y) > 1.5 or absf(rise) > 0.3:
					_failures.append("wall-wedge f%d: vy amplifier — vy=%.2f rise=%.3f" % [_phase_frames, _vel.y, rise])
			if _phase_frames >= 100:
				var vy_end := absf(_vel.y)
				print("[TEST] wall wedge: vy_end=%.3f rise=%.3f" % [
					_vel.y, _cv.get_character_position().y - _corner_start_y])
				if vy_end > 1.0:
					_failures.append("wall-wedge: sustained vy %.2f at end of wedge press (amplifier)" % _vel.y)
				print("[TEST] === Phase K: curved ramp past walkable limit (slide-up family) ===")
				_cv.teleport(Vector3(44.0, 2.9, -8.0))
				_vel = Vector3.ZERO
				_k_cross_frame = -1
				_k_pre_vy = 0.0
				_k_descended = false
				_next_phase()
		12:
			# Phase K: sprint up the 25° ramp into its 56° continuation. Per
			# the design model, crossing the walkable limit must be a TANGENT
			# SLIDE: momentum carries the player up the steep face, gravity
			# drains it progressively. The removed upstream behavior cancelled
			# all horizontal into the steep face in one frame and popped the
			# player vertically off the surface (forward motion ~0 while vy
			# carried) — that signature is the failure condition.
			# After the crossing the game pipeline treats steep ground as
			# airborne: input is trig-capped off the face (no climbing power)
			# and momentum is PRESERVED, so the harness switches _drive to
			# momentum mode (no horizontal overwrite) instead of commanding.
			var settle := _phase_frames <= 12
			var crossed := _k_cross_frame >= 0
			var moved := _drive(Vector3.ZERO if (settle or crossed) else Vector3(WALK_SPEED, 0, 0), delta, settle or not crossed)
			if not settle:
				var on_walkable := _cv.get_ground_state() == 0
				if _k_cross_frame < 0:
					if not on_walkable and _cv.get_character_position().x > 50.0:
						_k_cross_frame = _phase_frames
				elif _phase_frames <= _k_cross_frame + 6:
					# Tangent slide: forward motion must CONTINUE through the
					# transition (the pop killed it to ~0 in one frame)…
					if moved.x < 0.02:
						_failures.append("curved-ramp f%d: forward motion died at the steep transition (moved.x=%.4f) — vertical pop" % [
							_phase_frames, moved.x])
					# …and the redirect may convert h into climb but never
					# exceed the carried 3D speed (8/cos25° ≈ 8.83; no new energy).
					if moved.y / delta > WALK_SPEED / cos(deg_to_rad(25.0)) + 0.7:
						_failures.append("curved-ramp f%d: vy %.2f exceeds carried 3D speed — energy injected at the transition" % [
							_phase_frames, moved.y / delta])
				elif moved.y <= 0.0:
					_k_descended = true
				if _k_cross_frame > 0 and _phase_frames > _k_cross_frame + 60 and not _k_descended:
					_failures.append("curved-ramp: climb not drained 60 frames after crossing")
					_k_descended = true  # bail
			if _phase_frames >= 200 or (_k_descended and _k_cross_frame > 0):
				if _k_cross_frame < 0:
					_failures.append("curved-ramp: never reached the steep section (x=%.2f)" % _cv.get_character_position().x)
				elif not _k_descended:
					_failures.append("curved-ramp: climb never drained — still ascending %d frames after the crossing" % (_phase_frames - _k_cross_frame))
				else:
					print("[TEST] curved ramp: crossed at f%d, slid up on momentum and started descending by f%d" % [
						_k_cross_frame, _phase_frames])
				_finish()


func _run_back_and_forth(delta: float, axis: Vector3, label: String) -> void:
	# 12 settle frames, then 4 cycles of: +axis 40f, idle 5f, -axis 40f, idle 5f.
	# Input is exactly symmetric, so any net displacement after the cycles is
	# mechanical creep. Downhill on the test hill is +Z.
	const CYCLE := 90
	const TOTAL := 12 + 4 * CYCLE
	if _phase_frames <= 12:
		_drive(Vector3.ZERO, delta)
		if _phase_frames == 12:
			_bnf_start = _cv.get_character_position()
		return
	var t := (_phase_frames - 13) % CYCLE
	var cmd := Vector3.ZERO
	if t < 40:
		cmd = axis * WALK_SPEED
	elif t < 45:
		cmd = Vector3.ZERO
	elif t < 85:
		cmd = -axis * WALK_SPEED
	_drive(cmd, delta)
	if _phase_frames >= TOTAL:
		var net := _cv.get_character_position() - _bnf_start
		print("[TEST] %s back-and-forth (4 cycles): net drift = (%.4f, %.4f, %.4f), |h| = %.4f m" % [
			label, net.x, net.y, net.z, Vector2(net.x, net.z).length()])
		if Vector2(net.x, net.z).length() > 0.05:
			_failures.append("%s: creep — net %.3f m horizontal drift after symmetric back-and-forth" % [
				label, Vector2(net.x, net.z).length()])
		_next_phase()


func _next_phase() -> void:
	_phase += 1
	_phase_frames = 0


func _finish() -> void:
	if _failures.is_empty():
		print("[TEST] === PASS: no stuck frames, stable corner pin, uphill speed held, no stop-hop, no hill redirect ===")
		get_tree().quit(0)
	else:
		print("[TEST] === FAIL: %d issue(s) ===" % _failures.size())
		for f in _failures:
			print("[TEST]   " + f)
		get_tree().quit(1)
