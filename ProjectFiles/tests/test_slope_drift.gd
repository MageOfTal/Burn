extends Node3D
## Tests for slope movement drift.
##
## Test 4: Walk uphill on 30° slope — perpendicular drift should be near zero.
## Test 5: Walk downhill on 30° slope — perpendicular drift should be near zero.
## Test 6: Stand still on 30° slope — total horizontal drift should be near zero.
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_slope_drift.tscn

const _TBody = preload("res://tests/test_floor_press_body.gd")

const GRAVITY: float = 17.5
const WALK_SPEED: float = 9.1
const WALK_ACCEL: float = 100.0
const FLOOR_MAX_ANGLE: float = 0.8727  # 50 degrees
const SETTLE_FRAMES: int = 120
const TEST_FRAMES: int = 420

var _frame: int = 0

# ── Test 4: Walk uphill — perpendicular drift ─────────────────────
var _body_uphill: _TBody
var _uphill_settled_pos: Vector3
var _uphill_max_perp_drift: float = 0.0
var _uphill_input_dir: Vector3 = Vector3(1, 0, 0)  # Walking in +X (uphill)

# ── Test 5: Walk downhill — perpendicular drift ───────────────────
var _body_downhill: _TBody
var _downhill_settled_pos: Vector3
var _downhill_max_perp_drift: float = 0.0
var _downhill_input_dir: Vector3 = Vector3(-1, 0, 0)  # Walking in -X (downhill)

# ── Test 6: Stand still on slope — total drift ────────────────────
var _body_still: _TBody
var _still_settled_pos: Vector3
var _still_max_drift: float = 0.0


func _ready() -> void:
	_setup_test4()
	_setup_test5()
	_setup_test6()
	_setup_test7()
	_setup_test8()
	_setup_test9()
	print("[TEST] Slope drift tests — 6 scenarios")
	print("[TEST] Settle: %d frames, Test: %d frames" % [SETTLE_FRAMES, TEST_FRAMES - SETTLE_FRAMES])


# ════════════════════════════════════════════════════════════════════
#  Setup — 30° slope going uphill in +X
# ════════════════════════════════════════════════════════════════════

func _create_slope(pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(30, 1, 12)
	col.shape = shape
	body.add_child(col)
	body.position = pos
	body.rotation.z = deg_to_rad(30)  # 30° slope, uphill in +X
	return body


func _setup_test4() -> void:
	var slope := _create_slope(Vector3(0, 0, 0))
	add_child(slope)
	_body_uphill = _create_test_body(Vector3(-5, 5, 0))
	add_child(_body_uphill)


func _setup_test5() -> void:
	var slope := _create_slope(Vector3(0, 0, 20))
	add_child(slope)
	_body_downhill = _create_test_body(Vector3(5, 8, 20))
	add_child(_body_downhill)


func _setup_test6() -> void:
	var slope := _create_slope(Vector3(0, 0, -20))
	add_child(slope)
	_body_still = _create_test_body(Vector3(0, 5, -20))
	add_child(_body_still)


# ── Test 7: Walk uphill on ROUGH slope (seamed terrain) ───────────
var _body_rough: _TBody
var _rough_settled_pos: Vector3
var _rough_max_perp_drift: float = 0.0
var _rough_input_dir: Vector3 = Vector3(1, 0, 0)

# ── Test 8: Walk uphill with simulated solver noise ───────────────
# Simulates what happens on voxel terrain where the solver adds small
# perpendicular velocity each frame due to contact normal imprecision.
var _body_noisy: _TBody
var _noisy_settled_pos: Vector3
var _noisy_max_perp_drift: float = 0.0
var _noisy_input_dir: Vector3 = Vector3(1, 0, 0)

# ── Test 9: Land on slope — horizontal position should not shift ───
var _body_land: _TBody
var _land_start_xz: Vector2
var _land_settled: bool = false
var _land_max_xz_shift: float = 0.0
var _land_was_grounded: bool = false
var _land_is_grounded: bool = false
var _land_airborne_hvel: Vector3 = Vector3.ZERO

func _setup_test9() -> void:
	## Jump forward (+X, uphill) and land on a 30° slope.
	## The solver deflects falling velocity along the slope surface,
	## shifting horizontal direction. Landing restore should correct this.
	var slope := _create_slope(Vector3(0, 0, -40))
	add_child(slope)
	_body_land = _create_test_body(Vector3(-3, 6, -40))
	# Give initial horizontal velocity (walking speed in +X) + upward jump
	_body_land.linear_velocity = Vector3(WALK_SPEED, 5.0, 0)
	add_child(_body_land)
	_land_start_xz = Vector2(-3, -40)


func _setup_test8() -> void:
	var slope := _create_slope(Vector3(0, 0, 40))
	add_child(slope)
	_body_noisy = _create_test_body(Vector3(-5, 5, 40))
	add_child(_body_noisy)


func _setup_test7() -> void:
	## Multiple offset slope segments simulating voxel terrain seams.
	## Each segment is a thin box, slightly offset in Y to create bumps.
	for i in range(10):
		var x_offset: float = i * 3.0 + 40.0
		var y_jitter: float = (i % 3) * 0.02 - 0.02  # -0.02, 0, +0.02 pattern
		var slope := StaticBody3D.new()
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(3.2, 1, 12)  # Slight overlap to avoid gaps
		col.shape = shape
		slope.add_child(col)
		slope.position = Vector3(x_offset, y_jitter, 0)
		slope.rotation.z = deg_to_rad(30)
		add_child(slope)
	_body_rough = _create_test_body(Vector3(40, 5, 0))
	add_child(_body_rough)


# ════════════════════════════════════════════════════════════════════
#  Movement pipeline (mirrors player_movement.gd exactly)
# ════════════════════════════════════════════════════════════════════

func _apply_movement(body: _TBody, input_dir: Vector3, delta: float) -> void:
	## Full pipeline: read hvel from Jolt → ground movement → slope projection → gravity
	var is_grounded: bool = body.has_floor_contact

	if is_grounded:
		# Step 1: Read horizontal velocity from Jolt (includes solver drift)
		var hvel := Vector3(body.linear_velocity.x, 0.0, body.linear_velocity.z)
		var hspeed := hvel.length()

		# Step 2: Ground movement (same as _process_ground_movement)
		if input_dir == Vector3.ZERO:
			if hspeed <= 55.0:  # SKID_THRESHOLD
				hvel = Vector3.ZERO
		else:
			var hdir := input_dir.normalized()
			var vel_toward := hvel.dot(hdir)
			if vel_toward < WALK_SPEED:
				var speed_add := WALK_ACCEL * delta
				var new_toward := minf(vel_toward + speed_add, WALK_SPEED)
				hvel += hdir * (new_toward - vel_toward)
			# Speed clamp
			var new_speed := hvel.length()
			if new_speed > WALK_SPEED and new_speed > hspeed:
				hvel = hvel.normalized() * WALK_SPEED

		# Step 3: Set horizontal velocity
		body.linear_velocity.x = hvel.x
		body.linear_velocity.z = hvel.z

		# Step 4: Slope projection (y-axis only)
		var n: Vector3 = body.floor_normal
		if n != Vector3.ZERO and n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			var surface_y: float = -(n.x * hvel.x + n.z * hvel.z) / n.y
			body.linear_velocity.y = surface_y
	else:
		# Airborne: gravity
		body.linear_velocity.y -= GRAVITY * delta


# ════════════════════════════════════════════════════════════════════
#  Physics tick
# ════════════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	_frame += 1

	_apply_movement(_body_uphill, _uphill_input_dir, delta)
	_apply_movement(_body_downhill, _downhill_input_dir, delta)
	_apply_movement(_body_still, Vector3.ZERO, delta)
	_apply_movement(_body_rough, _rough_input_dir, delta)
	# Test 8: inject solver noise BEFORE movement
	if _frame > SETTLE_FRAMES and _body_noisy.has_floor_contact:
		_body_noisy.linear_velocity.z += 0.05
	_apply_movement(_body_noisy, _noisy_input_dir, delta)
	# Test 9: landing — apply gravity, track grounding, apply landing logic
	_tick_landing(delta)

	if _frame == SETTLE_FRAMES:
		_uphill_settled_pos = _body_uphill.global_position
		_downhill_settled_pos = _body_downhill.global_position
		_still_settled_pos = _body_still.global_position
		_rough_settled_pos = _body_rough.global_position
		_noisy_settled_pos = _body_noisy.global_position
		print("[TEST] Settled.")
		print("[TEST]   Uphill at %s (floor=%s)" % [_body_uphill.global_position, _body_uphill.has_floor_contact])
		print("[TEST]   Downhill at %s (floor=%s)" % [_body_downhill.global_position, _body_downhill.has_floor_contact])
		print("[TEST]   Still at %s (floor=%s)" % [_body_still.global_position, _body_still.has_floor_contact])
		print("[TEST]   Rough at %s (floor=%s)" % [_body_rough.global_position, _body_rough.has_floor_contact])
		print("[TEST]   Noisy at %s (floor=%s)" % [_body_noisy.global_position, _body_noisy.has_floor_contact])

	if _frame > SETTLE_FRAMES:
		_measure_test4()
		_measure_test5()
		_measure_test6()
		_measure_test7()
		_measure_test8()
		_measure_test9()

	if _frame > SETTLE_FRAMES and _frame % 60 == 0:
		print("[TEST] f=%d | uphill_perp=%.4f | downhill_perp=%.4f | still=%.4f | rough=%.4f | noisy=%.4f" % [
			_frame, _uphill_max_perp_drift, _downhill_max_perp_drift, _still_max_drift, _rough_max_perp_drift, _noisy_max_perp_drift])

	if _frame >= TEST_FRAMES:
		_report_results()
		get_tree().quit()


# ════════════════════════════════════════════════════════════════════
#  Measurements
# ════════════════════════════════════════════════════════════════════

func _measure_test4() -> void:
	# Perpendicular drift = Z displacement (input is purely X)
	var z_drift: float = absf(_body_uphill.global_position.z - _uphill_settled_pos.z)
	_uphill_max_perp_drift = maxf(_uphill_max_perp_drift, z_drift)


func _measure_test5() -> void:
	var z_drift: float = absf(_body_downhill.global_position.z - _downhill_settled_pos.z)
	_downhill_max_perp_drift = maxf(_downhill_max_perp_drift, z_drift)


func _measure_test6() -> void:
	var drift: float = Vector2(
		_body_still.global_position.x - _still_settled_pos.x,
		_body_still.global_position.z - _still_settled_pos.z
	).length()
	_still_max_drift = maxf(_still_max_drift, drift)


func _tick_landing(delta: float) -> void:
	var body := _body_land
	_land_was_grounded = _land_is_grounded
	_land_is_grounded = body.has_floor_contact

	# Simulate solver deflection on landing: the solver decomposed falling
	# velocity along the slope, adding perpendicular horizontal velocity.
	# Jolt then integrated that deflected velocity into position.
	if _land_is_grounded and not _land_was_grounded:
		body.linear_velocity.z += 2.0  # Solver deflected velocity
		body.global_position.z += 2.0 * delta  # Jolt integrated it

	# Landing detection — mirrors begin_movement
	if _land_is_grounded and not _land_was_grounded:
		# Correct position: undo solver's one-frame perpendicular deflection
		var solver_hvel := Vector3(body.linear_velocity.x, 0, body.linear_velocity.z)
		var pos_correction := _land_airborne_hvel - solver_hvel
		body.global_position += pos_correction * delta
		# Restore velocity
		body.linear_velocity.x = _land_airborne_hvel.x
		body.linear_velocity.z = _land_airborne_hvel.z
		body.linear_velocity.y = 0.0

	if _land_is_grounded:
		# Grounded: zero horizontal, slope project
		body.linear_velocity.x = 0
		body.linear_velocity.z = 0
		var n: Vector3 = body.floor_normal
		if n != Vector3.ZERO and n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			body.linear_velocity.y = -(n.x * body.linear_velocity.x + n.z * body.linear_velocity.z) / n.y
	else:
		# Airborne: gravity, save hvel
		body.linear_velocity.y -= GRAVITY * delta
		_land_airborne_hvel = Vector3(body.linear_velocity.x, 0, body.linear_velocity.z)


func _measure_test9() -> void:
	if not _land_is_grounded:
		return
	if not _land_settled:
		_land_settled = true
		return  # skip the exact landing frame
	# Perpendicular drift: Z displacement (input is purely X)
	var z_shift: float = absf(_body_land.global_position.z - _land_start_xz.y)
	_land_max_xz_shift = maxf(_land_max_xz_shift, z_shift)


func _measure_test7() -> void:
	var z_drift: float = absf(_body_rough.global_position.z - _rough_settled_pos.z)
	_rough_max_perp_drift = maxf(_rough_max_perp_drift, z_drift)


func _measure_test8() -> void:
	var z_drift: float = absf(_body_noisy.global_position.z - _noisy_settled_pos.z)
	_noisy_max_perp_drift = maxf(_noisy_max_perp_drift, z_drift)


# ════════════════════════════════════════════════════════════════════
#  Results
# ════════════════════════════════════════════════════════════════════

func _report_results() -> void:
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  SLOPE DRIFT RESULTS")
	print("[TEST] ══════════════════════════════════════════")

	var t4_pass: bool = _uphill_max_perp_drift < 0.01
	print("[TEST]")
	print("[TEST]  4) Walk uphill (30 deg) — perpendicular drift")
	print("[TEST]     Max Z drift: %.4f m" % _uphill_max_perp_drift)
	print("[TEST]     %s (threshold: 0.01 m)" % ("PASS" if t4_pass else "FAIL"))

	var t5_pass: bool = _downhill_max_perp_drift < 0.01
	print("[TEST]")
	print("[TEST]  5) Walk downhill (30 deg) — perpendicular drift")
	print("[TEST]     Max Z drift: %.4f m" % _downhill_max_perp_drift)
	print("[TEST]     %s (threshold: 0.01 m)" % ("PASS" if t5_pass else "FAIL"))

	var t6_pass: bool = _still_max_drift < 0.01
	print("[TEST]")
	print("[TEST]  6) Stand still on slope (30 deg) — total drift")
	print("[TEST]     Max drift: %.4f m" % _still_max_drift)
	print("[TEST]     %s (threshold: 0.01 m)" % ("PASS" if t6_pass else "FAIL"))

	var t7_pass: bool = _rough_max_perp_drift < 0.01
	print("[TEST]")
	print("[TEST]  7) Walk uphill on rough slope (seams) — perpendicular drift")
	print("[TEST]     Max Z drift: %.4f m" % _rough_max_perp_drift)
	print("[TEST]     %s (threshold: 0.01 m)" % ("PASS" if t7_pass else "FAIL"))

	var t8_pass: bool = _noisy_max_perp_drift < 0.05
	print("[TEST]")
	print("[TEST]  8) Walk uphill with solver noise — perpendicular drift")
	print("[TEST]     Max Z drift: %.4f m" % _noisy_max_perp_drift)
	print("[TEST]     %s (threshold: 0.05 m)" % ("PASS" if t8_pass else "FAIL"))

	var t9_pass: bool = _land_max_xz_shift < 0.01
	print("[TEST]")
	print("[TEST]  9) Land on slope — horizontal position shift")
	print("[TEST]     Max XZ shift: %.4f m" % _land_max_xz_shift)
	print("[TEST]     %s (threshold: 0.01 m)" % ("PASS" if t9_pass else "FAIL"))

	print("[TEST]")
	var all_pass: bool = t4_pass and t5_pass and t6_pass and t7_pass and t8_pass and t9_pass
	print("[TEST]  OVERALL: %s" % ("ALL PASS" if all_pass else "SOME FAILED"))
	print("[TEST] ══════════════════════════════════════════")


# ════════════════════════════════════════════════════════════════════
#  Helpers
# ════════════════════════════════════════════════════════════════════

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
