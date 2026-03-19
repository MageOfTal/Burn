extends Node3D
## Integration tests for player movement physics using actual Jolt solver.
##
## Test 1: Standing still on a 45° slope — no sliding.
## Test 2: Standing on a dynamic body (toad) — toad gets pushed sideways.
## Test 3: Walking uphill into a chest — stays grounded, no position jitter.
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_movement_physics.tscn

const _TBody = preload("res://tests/test_floor_press_body.gd")

const GRAVITY: float = 17.5
const WALK_SPEED: float = 9.1
const FLOOR_MAX_ANGLE: float = 0.8727  # 50 degrees
const SETTLE_FRAMES: int = 120
const TEST_FRAMES: int = 420  # 7 seconds total

var _frame: int = 0

# ── Test 1: Slope no-slide ──────────────────────────────────────────
var _body_slope: _TBody
var _slope_settled_pos: Vector3
var _slope_max_drift: float = 0.0

# ── Test 2: Dynamic body push ───────────────────────────────────────
var _body_toad_player: _TBody
var _toad: RigidBody3D
var _toad_initial_pos: Vector3
var _toad_grounded_frames: int = 0

# ── Test 3: Chest wall-slide grounded ───────────────────────────────
var _body_chest: _TBody
var _chest_grounded: bool = false  # Mirrors real _update_ground_state logic
var _chest_floor_lost: int = 0
var _chest_contact_frames: int = 0
var _chest_z_positions: PackedFloat64Array = PackedFloat64Array()


func _ready() -> void:
	_setup_test1()
	_setup_test2()
	_setup_test3()
	print("[TEST] Movement physics integration tests — 3 scenarios")
	print("[TEST] Settle: %d frames, Test: %d frames" % [SETTLE_FRAMES, TEST_FRAMES - SETTLE_FRAMES])


# ════════════════════════════════════════════════════════════════════
#  Setup
# ════════════════════════════════════════════════════════════════════

func _setup_test1() -> void:
	## 45° slope — capsule stands still, should not slide.
	var floor_body: StaticBody3D = _create_static_box(
		Vector3(-20, 0, 0), Vector3(12, 1, 12), deg_to_rad(45))
	add_child(floor_body)
	# Start above the slope — will fall and settle during settle phase
	_body_slope = _create_test_body(Vector3(-20, 5, 0))
	add_child(_body_slope)


func _setup_test2() -> void:
	## Flat floor + toad sphere — capsule lands on toad edge, toad gets pushed.
	var floor_body: StaticBody3D = _create_static_box(
		Vector3(0, -0.5, 0), Vector3(20, 1, 20), 0)
	add_child(floor_body)
	# Toad: 4 kg sphere on the floor
	_toad = RigidBody3D.new()
	_toad.name = "Toad"
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.35
	col.shape = sphere
	_toad.add_child(col)
	_toad.mass = 4.0
	_toad.can_sleep = false
	_toad.position = Vector3(0, 0.35, 0)  # Resting on floor
	add_child(_toad)
	# Capsule slightly off-center — lands on toad's edge
	_body_toad_player = _create_test_body(Vector3(0.2, 3, 0))
	add_child(_body_toad_player)


func _setup_test3() -> void:
	## 15° uphill slope + chest — walk into chest, stay grounded, no jitter.
	## Floor is split into two segments with a gap at the chest location to
	## simulate rough voxel terrain where floor contact is fragile.
	var slope_angle: float = deg_to_rad(15)
	# Floor segment 1: z = +5 to z = -6 (before the chest)
	var floor1: StaticBody3D = _create_static_box(
		Vector3(20, -0.5, -0.5), Vector3(12, 1, 11), slope_angle)
	add_child(floor1)
	# Floor segment 2: z = -6.1 to z = -12 (after the gap, behind the chest)
	var floor2: StaticBody3D = _create_static_box(
		Vector3(20, -0.5, -9.05), Vector3(12, 1, 5.9), slope_angle)
	# Slight height offset to create roughness at the seam
	floor2.position.y += 0.02
	add_child(floor2)
	# Chest right at the gap between floor segments
	var chest: StaticBody3D = _create_static_box(
		Vector3(20, 2.3, -6.5), Vector3(3, 1.5, 1), 0)
	add_child(chest)
	# Capsule starts near z=0, will walk uphill toward chest
	_body_chest = _create_test_body(Vector3(20, 3, 0))
	add_child(_body_chest)


# ════════════════════════════════════════════════════════════════════
#  Physics tick
# ════════════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	_frame += 1

	# ── Apply movement to each body ──
	_tick_slope(delta)
	_tick_toad_player(delta)
	_tick_chest(delta)

	# ── Settle milestone ──
	if _frame == SETTLE_FRAMES:
		_slope_settled_pos = _body_slope.global_position
		_toad_initial_pos = _toad.global_position
		print("[TEST] Settled.")
		print("[TEST]   Slope body at %s (floor=%s)" % [
			_body_slope.global_position, _body_slope.has_floor_contact])
		print("[TEST]   Toad at %s, player at %s (dyn=%s)" % [
			_toad.global_position, _body_toad_player.global_position,
			_body_toad_player.on_dynamic_body])
		print("[TEST]   Chest body at %s (floor=%s)" % [
			_body_chest.global_position, _body_chest.has_floor_contact])

	# ── Measure (only after settle) ──
	if _frame > SETTLE_FRAMES:
		_measure_test1()
		_measure_test2()
		_measure_test3()

	# ── Periodic status ──
	if _frame > SETTLE_FRAMES and _frame % 60 == 0:
		print("[TEST] f=%d | slope_drift=%.4f | toad_dx=%.3f grounded=%d | chest_lost=%d/%d z_range=%.4f" % [
			_frame,
			_slope_max_drift,
			(_toad.global_position - _toad_initial_pos).length(),
			_toad_grounded_frames,
			_chest_floor_lost, _chest_contact_frames,
			_get_z_range()])

	# ── End ──
	if _frame >= TEST_FRAMES:
		_report_results()
		get_tree().quit()


# ════════════════════════════════════════════════════════════════════
#  Per-body movement logic (replicates player_movement.gd pipeline)
# ════════════════════════════════════════════════════════════════════

func _tick_slope(delta: float) -> void:
	## Test 1: No input on 45° slope. Pipeline: gravity → zero horizontal.
	var body: _TBody = _body_slope

	# Gravity
	body.linear_velocity.y -= GRAVITY * delta

	# No-input on walkable ground: instant stop
	if body.has_floor_contact:
		body.linear_velocity.x = 0
		body.linear_velocity.z = 0
		# Slope projection + perpendicular press
		_apply_slope_projection(body, delta)


func _tick_toad_player(delta: float) -> void:
	## Test 2: Standing on toad. Pipeline: gravity → zero horizontal → slope projection.
	var body: _TBody = _body_toad_player

	# Gravity
	body.linear_velocity.y -= GRAVITY * delta

	# Grounded check: floor contact OR standing on dynamic body
	var grounded: bool = body.has_floor_contact
	if not grounded and body.on_dynamic_body and body.linear_velocity.y <= 0.0:
		grounded = true

	if grounded:
		body.linear_velocity.x = 0
		body.linear_velocity.z = 0
		# On dynamic body: gravity provides weight naturally through Jolt's
		# contact solver. No explicit force or slope projection needed —
		# the downward velocity creates contact impulses on the toad.
		pass


func _tick_chest(delta: float) -> void:
	## Test 3: Walk uphill into chest. Pipeline: gravity → walk → wall-slide → slope projection.
	## Ground state mirrors real _update_ground_state() including wall depenetration override.
	var body: _TBody = _body_chest

	_chest_grounded = body.has_floor_contact

	# Gravity
	body.linear_velocity.y -= GRAVITY * delta

	if _frame < SETTLE_FRAMES:
		# During settle: no input, just find the floor
		if _chest_grounded:
			body.linear_velocity.x = 0
			body.linear_velocity.z = 0
			_apply_slope_projection(body, delta)
		return

	# Walk in -Z (uphill on the 15° slope)
	var walk_dir := Vector2(0, -WALK_SPEED)

	if _chest_grounded:
		# Wall-slide: if wall contact exists, project walk onto wall tangent
		if body.wall_normal != Vector3.ZERO:
			var wn2 := Vector2(body.wall_normal.x, body.wall_normal.z).normalized()
			var into_wall: float = walk_dir.dot(wn2)
			if into_wall < 0.0:
				# Project target onto wall tangent, perp_out = 0
				walk_dir -= wn2 * into_wall

		# Set horizontal velocity (instant on walkable, like real code)
		body.linear_velocity.x = walk_dir.x
		body.linear_velocity.z = walk_dir.y

		# Slope projection (no-op on walkable — gravity provides contact)
		_apply_slope_projection(body, delta)
	else:
		# Airborne: keep horizontal, gravity pulls down
		body.linear_velocity.z = -WALK_SPEED


func _apply_slope_projection(body: _TBody, delta: float) -> void:
	## Slope projection (mirrors player_movement.gd). Sets vel.y to tangent
	## (prevents solver bounce and gravity accumulation) and pushes fixed
	## depth into surface for real contact maintenance.
	var n: Vector3 = body.floor_normal
	if n == Vector3.ZERO:
		return
	if n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
		var slope_y: float = -(n.x * body.linear_velocity.x + n.z * body.linear_velocity.z) / n.y
		if slope_y < 0.0 or body.linear_velocity.y <= slope_y:
			body.linear_velocity.y = slope_y
		var press_speed: float = 0.06 / delta
		body.linear_velocity -= press_speed * n
	else:
		var perp: float = body.linear_velocity.dot(n)
		body.linear_velocity -= n * perp


# ════════════════════════════════════════════════════════════════════
#  Measurements
# ════════════════════════════════════════════════════════════════════

func _measure_test1() -> void:
	var drift: float = Vector2(
		_body_slope.global_position.x - _slope_settled_pos.x,
		_body_slope.global_position.z - _slope_settled_pos.z
	).length()
	_slope_max_drift = maxf(_slope_max_drift, drift)


func _measure_test2() -> void:
	if _body_toad_player.on_dynamic_body or _body_toad_player.has_floor_contact:
		_toad_grounded_frames += 1


func _measure_test3() -> void:
	# Only measure once the body is near the chest (z < -4)
	if _body_chest.global_position.z > -4.0:
		return
	var has_wall: bool = _body_chest.wall_normal != Vector3.ZERO
	if has_wall or _body_chest.contact_count > 1:
		_chest_contact_frames += 1
		_chest_z_positions.append(_body_chest.global_position.z)
		if not _body_chest.has_floor_contact:
			_chest_floor_lost += 1


func _get_z_range() -> float:
	if _chest_z_positions.size() < 2:
		return 0.0
	var min_z: float = _chest_z_positions[0]
	var max_z: float = _chest_z_positions[0]
	for z: float in _chest_z_positions:
		min_z = minf(min_z, z)
		max_z = maxf(max_z, z)
	return max_z - min_z


# ════════════════════════════════════════════════════════════════════
#  Results
# ════════════════════════════════════════════════════════════════════

func _report_results() -> void:
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  RESULTS")
	print("[TEST] ══════════════════════════════════════════")

	# Test 1
	var t1_pass: bool = _slope_max_drift < 0.05
	print("[TEST]")
	print("[TEST]  1) Slope no-slide (45 deg)")
	print("[TEST]     Max horizontal drift: %.4f m" % _slope_max_drift)
	print("[TEST]     %s (threshold: 0.05 m)" % ("PASS" if t1_pass else "FAIL"))

	# Test 2
	var toad_displacement: float = (_toad.global_position - _toad_initial_pos).length()
	var t2_pass: bool = toad_displacement > 0.05
	print("[TEST]")
	print("[TEST]  2) Dynamic body push (toad)")
	print("[TEST]     Toad displacement: %.3f m" % toad_displacement)
	print("[TEST]     Grounded frames on toad: %d" % _toad_grounded_frames)
	print("[TEST]     %s (threshold: 0.05 m movement)" % ("PASS" if t2_pass else "FAIL"))

	# Test 3
	var z_range: float = _get_z_range()
	var t3_grounded: bool = _chest_floor_lost == 0
	var t3_stable: bool = z_range < 0.05
	var t3_pass: bool = t3_grounded and t3_stable
	print("[TEST]")
	print("[TEST]  3) Chest wall-slide grounded (15 deg uphill)")
	print("[TEST]     Contact frames: %d" % _chest_contact_frames)
	print("[TEST]     Floor lost frames: %d" % _chest_floor_lost)
	print("[TEST]     Position Z range: %.4f m" % z_range)
	print("[TEST]     %s (need: 0 effective floor loss, <0.05 m jitter)" % ("PASS" if t3_pass else "FAIL"))

	print("[TEST]")
	var all_pass: bool = t1_pass and t2_pass and t3_pass
	print("[TEST]  OVERALL: %s" % ("ALL PASS" if all_pass else "SOME FAILED"))
	print("[TEST] ══════════════════════════════════════════")


# ════════════════════════════════════════════════════════════════════
#  Helpers
# ════════════════════════════════════════════════════════════════════

func _create_static_box(pos: Vector3, box_size: Vector3, rotation_x: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box_size
	col.shape = shape
	body.add_child(col)
	body.position = pos
	body.rotation.x = rotation_x
	return body


func _create_test_body(pos: Vector3) -> _TBody:
	var body := _TBody.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	body.add_child(col)
	body.mass = 80.0
	body.gravity_scale = 0
	body.custom_integrator = true
	body.can_sleep = false
	body.lock_rotation = true
	body.continuous_cd = true
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.position = pos
	return body
