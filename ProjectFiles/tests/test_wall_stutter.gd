extends Node3D
## Test: walking into a wall on sloped terrain should not stutter.
##
## A capsule walks into a vertical wall on a 20° slope.  The wall and slope
## form an obtuse corner (their normals are ~80° apart).  The hdir projection
## against both surfaces leaves a small residual that, without a velocity clip,
## accumulates into wall-perpendicular drift → contact loss → snap-back.
##
## PASS: position oscillation < 2mm AND no contact loss during sustained press.
## FAIL: oscillation >= 2mm OR contact count drops (wall contact lost).
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_wall_stutter.tscn

const _TBody = preload("res://tests/test_floor_press_body.gd")

const GRAVITY: float = 22.05
const WALK_ACCEL: float = 30.33
const MAX_SPEED: float = 9.0
const DIME_STOP_SPEED: float = 6.0
const FLOOR_MAX_ANGLE: float = 0.8727
const SETTLE_FRAMES: int = 120
const TEST_FRAMES: int = 420

var _frame: int = 0
var _body: _TBody
var _input_dir: Vector3

# Measurement
var _settled: bool = false
var _max_oscillation: float = 0.0
var _contact_drops: int = 0
var _wall_contact_frames: int = 0
var _prev_wall_cc: int = 0
var _positions: PackedVector3Array = PackedVector3Array()


func _ready() -> void:
	# 20° slope floor — tilted so downhill is toward the wall (-X).
	# This makes the floor normal have a +X component, so the bias push
	# has wall-perpendicular drift (matching real terrain scenario).
	var floor_body := StaticBody3D.new()
	var floor_col := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(30, 1, 30)
	floor_col.shape = floor_shape
	floor_body.add_child(floor_col)
	floor_body.position = Vector3(0, -0.5, 0)
	floor_body.rotation.z = deg_to_rad(-20)
	add_child(floor_body)

	# Vertical wall — the capsule walks into this on the slope
	var wall := StaticBody3D.new()
	var wall_col := CollisionShape3D.new()
	var wall_shape := BoxShape3D.new()
	wall_shape.size = Vector3(0.5, 6, 20)
	wall_col.shape = wall_shape
	wall.add_child(wall_col)
	wall.position = Vector3(-3, 3, 0)
	add_child(wall)

	# Capsule starts on the slope, will walk toward wall
	_body = _create_test_body(Vector3(2, 3, 0))
	add_child(_body)

	# Walk directly into the wall (-X direction)
	_input_dir = Vector3(-1, 0, 0)

	print("[TEST] Wall stutter test (wall on 20° slope)")
	print("[TEST] Settle: %d frames, Test: %d frames" % [SETTLE_FRAMES, TEST_FRAMES - SETTLE_FRAMES])


func _physics_process(delta: float) -> void:
	_frame += 1

	_body.linear_velocity.y -= GRAVITY * delta

	if _body.has_floor_contact:
		var hvel := Vector3(_body.linear_velocity.x, 0.0, _body.linear_velocity.z)
		var hspeed := hvel.length()

		if _frame >= SETTLE_FRAMES and _settled:
			hvel = _do_ground_movement(hvel, hspeed, _input_dir, delta)
		else:
			hvel = Vector3.ZERO

		_body.linear_velocity.x = hvel.x
		_body.linear_velocity.z = hvel.z

		# Slope projection: bias pushes along floor normal (not just downward)
		var n := _body.floor_normal
		if n.y > 0.01:
			var surface_y := -(n.x * hvel.x + n.z * hvel.z) / n.y
			_body.linear_velocity.y = surface_y
			_body.linear_velocity -= 0.15 * n

	if _frame == SETTLE_FRAMES:
		_settled = true
		print("[TEST] Settled at %s, cc=%d" % [_body.global_position, _body.contact_count])

	if _frame > SETTLE_FRAMES and _settled:
		# Count wall contacts
		var wall_cc := 0
		for i in _body.contact_count:
			var cn: Vector3 = _body.get_contact_normal(i)
			if cn.angle_to(Vector3.UP) > FLOOR_MAX_ANGLE and cn.y >= 0.0:
				wall_cc += 1

		if wall_cc > 0:
			_wall_contact_frames += 1
		if _prev_wall_cc > 0 and wall_cc == 0:
			_contact_drops += 1
		_prev_wall_cc = wall_cc

		_positions.append(_body.global_position)
		if _positions.size() >= 3:
			var i := _positions.size() - 1
			var p0 := Vector2(_positions[i-2].x, _positions[i-2].z)
			var p1 := Vector2(_positions[i-1].x, _positions[i-1].z)
			var p2 := Vector2(_positions[i].x, _positions[i].z)
			var d1 := p1 - p0
			var d2 := p2 - p1
			if d1.length() > 0.0001 and d2.length() > 0.0001:
				if d1.normalized().dot(d2.normalized()) < -0.5:
					_max_oscillation = maxf(_max_oscillation, d1.length() + d2.length())

	if _frame > SETTLE_FRAMES and _frame % 60 == 0:
		print("[TEST] f=%d osc=%.4fmm drops=%d wall_frames=%d cc=%d" % [
			_frame, _max_oscillation * 1000.0, _contact_drops,
			_wall_contact_frames, _body.contact_count])

	if _frame >= TEST_FRAMES:
		_report()
		get_tree().quit()


func _do_ground_movement(hvel: Vector3, hspeed: float, direction: Vector3, delta: float) -> Vector3:
	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	var hdir_original := hdir
	for i in _body.contact_count:
		var n: Vector3 = _body.get_contact_normal(i)
		if n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			continue
		if n.y < 0.0:
			continue
		var nh := Vector3(n.x, 0.0, n.z)
		if nh.length_squared() > 0.001:
			nh = nh.normalized()
			var d := hdir.dot(nh)
			if d < 0.0:
				hdir -= nh * d
	if hdir.dot(hdir_original) < 0.0:
		hdir = Vector3.ZERO

	var wall_factor := hdir.length()
	if wall_factor > 0.001:
		hdir = hdir / wall_factor
	else:
		if hspeed <= DIME_STOP_SPEED:
			return Vector3.ZERO
		return hvel.move_toward(Vector3.ZERO, WALK_ACCEL * delta)

	var max_speed := MAX_SPEED * wall_factor

	if hspeed > 0.01 and hspeed <= DIME_STOP_SPEED:
		var vel_along := hvel.dot(hdir)
		if vel_along < 0.0:
			hvel -= hdir * vel_along
			hspeed = hvel.length()

	var vel_toward := hvel.dot(hdir)
	if vel_toward < max_speed:
		var speed_add := WALK_ACCEL * delta
		var new_toward := minf(vel_toward + speed_add, max_speed)
		hvel += hdir * (new_toward - vel_toward)

	return hvel


func _report() -> void:
	var pass_osc := _max_oscillation < 0.002
	var pass_drops := _contact_drops == 0
	var all_pass := pass_osc and pass_drops
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  WALL STUTTER TEST")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  Max oscillation: %.4f mm" % (_max_oscillation * 1000.0))
	print("[TEST]  Contact drops: %d" % _contact_drops)
	print("[TEST]  %s" % ("PASS" if all_pass else "FAIL"))
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
	body.contact_monitor = true
	body.max_contacts_reported = 16
	body.position = pos
	return body
