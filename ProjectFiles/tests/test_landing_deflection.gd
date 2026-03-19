extends Node3D
## Test: landing on a slope should not deflect the player sideways.
## Reproduces the "every other jump" deflection bug.
##
## A body jumps repeatedly on a 30° slope while walking in +X.
## On landing, the Jolt solver deflects falling velocity along the slope.
## The landing restore in begin_movement should undo this — but if the snap
## grounds the body one frame before begin_movement detects the transition,
## _was_grounded is already true and the restore never fires.
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_landing_deflection.tscn

const _TBody = preload("res://tests/test_floor_press_body.gd")

const GRAVITY: float = 17.5
const WALK_SPEED: float = 9.1
const WALK_ACCEL: float = 100.0
const JUMP_VELOCITY: float = 10.5
const FLOOR_MAX_ANGLE: float = 0.8727

var _frame: int = 0
var _body: _TBody

# State machine
var _is_grounded: bool = false
var _was_grounded: bool = false
var _airborne_hvel: Vector3 = Vector3.ZERO
var _floor_normal: Vector3 = Vector3.UP
var _post_jump_rising: bool = false
var _post_jump_timer: float = 0.0
const POST_JUMP_DURATION: float = 0.25

# Jump cycle tracking
var _jump_count: int = 0
var _want_jump: bool = false
var _settled: bool = false
const MAX_JUMPS: int = 10
const SETTLE_FRAMES: int = 120

# Per-landing measurements
var _z_at_takeoff: float = 0.0
var _z_at_landing: float = 0.0
var _landing_deflections: PackedFloat64Array = PackedFloat64Array()


func _ready() -> void:
	# 30° slope built from small offset segments (simulates voxel terrain seams).
	# Each segment is rotated 30° around Z, so +X goes uphill. Segments tile
	# along the rotated surface with slight Y/Z jitter and angle variation.
	for i in range(30):
		var seg := StaticBody3D.new()
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(3.0, 1, 12)
		col.shape = shape
		seg.add_child(col)
		# Position along the slope surface
		var along_slope: float = (i - 15) * 2.8
		var base_x: float = along_slope * cos(deg_to_rad(30))
		var base_y: float = along_slope * sin(deg_to_rad(30))
		var y_jitter: float = (i % 3 - 1) * 0.03
		var z_jitter: float = (i % 2) * 0.02
		seg.position = Vector3(base_x, base_y + y_jitter, z_jitter)
		seg.rotation.z = deg_to_rad(30)
		seg.rotation.x = deg_to_rad((i % 3 - 1) * 2.0)
		add_child(seg)

	_body = _create_test_body(Vector3(0, 5, 0))
	add_child(_body)
	print("[TEST] Landing deflection test — %d jump cycles on 30° slope" % MAX_JUMPS)


func _physics_process(delta: float) -> void:
	_frame += 1

	# --- Read grounding from Jolt contacts ---
	var prev_grounded := _is_grounded
	_is_grounded = _body.has_floor_contact
	_floor_normal = _body.floor_normal if _body.has_floor_contact else Vector3.UP

	# --- Post-jump rising timer ---
	if _post_jump_rising:
		_post_jump_timer -= delta
		if _post_jump_timer <= 0.0:
			_post_jump_rising = false
		else:
			_is_grounded = false

	# --- Snap (mirrors apply_snap_and_gravity) ---
	var snap_grounded := false
	if not _is_grounded and not _post_jump_rising:
		var snap_dist := -GRAVITY * delta * delta
		snap_grounded = _try_snap(snap_dist)

	# Landing detection
	var landing := _is_grounded and not _was_grounded

	# Landing restore happens inside _TBody._integrate_forces (before position
	# integration). We just feed it the airborne hvel and measure the result.
	if landing and _settled and _jump_count > 0:
		_z_at_landing = _body.global_position.z
		var deflection := absf(_z_at_landing - _z_at_takeoff)
		_landing_deflections.append(deflection)
		print("[TEST] Jump %d: takeoff_z=%.4f land_z=%.4f deflection=%.4f" % [
			_jump_count, _z_at_takeoff, _z_at_landing, deflection])

	# --- Movement ---
	if _is_grounded:
		var hvel := Vector3(_body.linear_velocity.x, 0.0, _body.linear_velocity.z)
		var hdir := Vector3(1, 0, 0)  # Always walk +X (uphill)
		var vel_toward := hvel.dot(hdir)
		if vel_toward < WALK_SPEED:
			var speed_add := WALK_ACCEL * delta
			hvel += hdir * minf(speed_add, WALK_SPEED - vel_toward)
		_body.linear_velocity.x = hvel.x
		_body.linear_velocity.z = hvel.z
		# Slope projection
		if _floor_normal.y > 0.01:
			_body.linear_velocity.y = -(_floor_normal.x * hvel.x + _floor_normal.z * hvel.z) / _floor_normal.y
	else:
		# Airborne: gravity (only if snap didn't fire)
		if not snap_grounded:
			_body.linear_velocity.y -= GRAVITY * delta

	# --- Jump logic ---
	if not _settled and _frame >= SETTLE_FRAMES:
		_settled = true
		_want_jump = true
		print("[TEST] Settled at %s" % _body.global_position)

	if _settled and _is_grounded and _want_jump and _jump_count < MAX_JUMPS:
		_z_at_takeoff = _body.global_position.z
		_body.linear_velocity.y = JUMP_VELOCITY
		_is_grounded = false
		_post_jump_rising = true
		_post_jump_timer = POST_JUMP_DURATION
		_jump_count += 1
		_want_jump = false

	# Queue next jump shortly after landing
	if _settled and _is_grounded and not _want_jump and _jump_count < MAX_JUMPS and not _post_jump_rising:
		_want_jump = true

	# --- Save airborne hvel (matches apply_snap_and_gravity saving before snap) ---
	if not _is_grounded:
		_airborne_hvel = Vector3(_body.linear_velocity.x, 0.0, _body.linear_velocity.z)

	# --- Save _was_grounded at END of frame ---
	_was_grounded = _is_grounded

	# --- End ---
	if _jump_count >= MAX_JUMPS and _is_grounded and _landing_deflections.size() >= MAX_JUMPS:
		_report()
		get_tree().quit()
	if _frame > 3000:
		print("[TEST] TIMEOUT")
		_report()
		get_tree().quit()


func _try_snap(snap_dist: float) -> bool:
	var space := _body.get_world_3d().direct_space_state
	var col_shape: CollisionShape3D = _body.get_child(0)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = col_shape.shape
	params.transform = col_shape.global_transform
	params.motion = Vector3(0, snap_dist, 0)
	params.collision_mask = _body.collision_mask
	params.exclude = [_body.get_rid()]
	var result := space.cast_motion(params)
	if result[1] < 1.0:
		var collision_params := PhysicsShapeQueryParameters3D.new()
		collision_params.shape = params.shape
		collision_params.transform = params.transform
		collision_params.transform.origin += params.motion * result[1]
		collision_params.collision_mask = params.collision_mask
		collision_params.exclude = params.exclude
		var rest := space.get_rest_info(collision_params)
		if rest and rest.normal.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			var collider := instance_from_id(rest.collider_id)
			if collider is StaticBody3D:
				_body.global_position.y += snap_dist * result[1]
				_is_grounded = true
				_floor_normal = rest.normal
				# Landing: restore airborne hvel + slope-project vel.y
				_body.linear_velocity.x = _airborne_hvel.x
				_body.linear_velocity.z = _airborne_hvel.z
				var n: Vector3 = rest.normal
				_body.linear_velocity.y = -(n.x * _body.linear_velocity.x + n.z * _body.linear_velocity.z) / n.y
				return true
	return false


func _report() -> void:
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  LANDING DEFLECTION RESULTS")
	print("[TEST] ══════════════════════════════════════════")
	var max_d: float = 0.0
	var deflected_count: int = 0
	for d in _landing_deflections:
		max_d = maxf(max_d, d)
		if d > 0.01:
			deflected_count += 1
	var t_pass: bool = max_d < 0.01
	print("[TEST]  Jumps: %d" % _landing_deflections.size())
	print("[TEST]  Max deflection: %.4f m" % max_d)
	print("[TEST]  Deflected landings (>1cm): %d / %d" % [deflected_count, _landing_deflections.size()])
	print("[TEST]  %s (threshold: 0.01 m)" % ("PASS" if t_pass else "FAIL"))
	print("[TEST] ══════════════════════════════════════════")


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
