extends Node3D
## Test: walking into an obtuse corner formed by two walls.
##
## Verifies the player doesn't wobble/oscillate when pressing into the corner.
## Two walls meet at ~120° (obtuse). A capsule walks directly into the vertex.
##
## PASS: position oscillation < 5mm over 5 seconds of pressing into corner.
## FAIL: position oscillation >= 5mm (wobble).
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_obtuse_corner.tscn

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
var _input_dir: Vector3  # horizontal input direction (into corner)

# Measurement
var _settled_pos: Vector3
var _positions: PackedVector3Array = PackedVector3Array()
var _max_oscillation: float = 0.0


func _ready() -> void:
	# Floor
	var floor_body := _create_static_box(
		Vector3(0, -0.5, 0), Vector3(30, 1, 30), Vector3.ZERO)
	add_child(floor_body)

	# Two walls forming an obtuse V-shape, vertex near origin, opening toward (+X,+Z).
	# Wall A: thin box at z=-1, rotated 17° around Y → face normal ≈ (0.29, 0, 0.96)
	var wall_a := _create_static_box(
		Vector3(0, 2, -1), Vector3(12, 4, 0.5), Vector3(0, deg_to_rad(17), 0))
	add_child(wall_a)

	# Wall B: thin box at x=-1, rotated -17° around Y → face normal ≈ (0.96, 0, 0.29)
	var wall_b := _create_static_box(
		Vector3(-1, 2, 0), Vector3(0.5, 4, 12), Vector3(0, deg_to_rad(-17), 0))
	add_child(wall_b)

	# Capsule starts in the V-opening, walks toward vertex
	_body = _create_test_body(Vector3(3, 2, 3))
	add_child(_body)

	# Input direction: pointing into the corner vertex
	_input_dir = Vector3(-1, 0, -1).normalized()

	print("[TEST] Obtuse corner wobble test")
	print("[TEST] Two walls at ~120°, pressing into corner vertex")
	print("[TEST] Settle: %d frames, Test: %d frames" % [SETTLE_FRAMES, TEST_FRAMES - SETTLE_FRAMES])


func _physics_process(delta: float) -> void:
	_frame += 1

	# Gravity
	_body.linear_velocity.y -= GRAVITY * delta

	if _body.has_floor_contact:
		# Simulate player movement pipeline
		var hvel := Vector3(_body.linear_velocity.x, 0.0, _body.linear_velocity.z)
		var hspeed := hvel.length()

		if _frame >= SETTLE_FRAMES:
			# Walk into corner
			hvel = _do_ground_movement(hvel, hspeed, _input_dir, delta)
		else:
			# Settle: no input
			hvel = Vector3.ZERO

		_body.linear_velocity.x = hvel.x
		_body.linear_velocity.z = hvel.z

		# Slope projection
		var n := _body.floor_normal
		if n.y > 0.01:
			var surface_y := -(n.x * hvel.x + n.z * hvel.z) / n.y
			_body.linear_velocity.y = surface_y - 0.15

	# Settle milestone
	if _frame == SETTLE_FRAMES:
		_settled_pos = _body.global_position
		print("[TEST] Settled at %s" % _settled_pos)

	# Measure
	if _frame > SETTLE_FRAMES:
		_positions.append(_body.global_position)
		# Track oscillation: measure how much the position bounces around
		if _positions.size() >= 3:
			var i := _positions.size() - 1
			var p0 := Vector2(_positions[i-2].x, _positions[i-2].z)
			var p1 := Vector2(_positions[i-1].x, _positions[i-1].z)
			var p2 := Vector2(_positions[i].x, _positions[i].z)
			# Direction change: if consecutive movements are in opposite directions
			var d1 := p1 - p0
			var d2 := p2 - p1
			if d1.length() > 0.0001 and d2.length() > 0.0001:
				var reversal := d1.normalized().dot(d2.normalized())
				if reversal < -0.5:  # significant direction reversal
					var magnitude := d1.length() + d2.length()
					_max_oscillation = maxf(_max_oscillation, magnitude)

	# Periodic status
	if _frame > SETTLE_FRAMES and _frame % 60 == 0:
		var pos := _body.global_position
		var dist := Vector2(pos.x - _settled_pos.x, pos.z - _settled_pos.z).length()
		print("[TEST] f=%d pos=(%.3f,%.3f,%.3f) dist=%.4f osc=%.4fmm cc=%d" % [
			_frame, pos.x, pos.y, pos.z, dist, _max_oscillation * 1000.0,
			_body.contact_count])

	# End
	if _frame >= TEST_FRAMES:
		_report()
		get_tree().quit()


func _do_ground_movement(hvel: Vector3, hspeed: float, direction: Vector3, delta: float) -> Vector3:
	var hdir := direction
	hdir.y = 0.0
	hdir = hdir.normalized()

	# Project input direction away from walls (same as player_movement.gd)
	var hdir_original := hdir
	for i in _body.contact_count:
		var n: Vector3 = _body.get_contact_normal(i)
		if n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
			continue  # walkable
		if n.y < 0.0:
			continue  # ceiling
		var nh := Vector3(n.x, 0.0, n.z)
		if nh.length_squared() > 0.001:
			nh = nh.normalized()
			var d := hdir.dot(nh)
			if d < 0.0:
				hdir -= nh * d
	# Oscillation guard: slide along best wall instead of stopping
	if hdir.dot(hdir_original) < 0.0:
		var best := Vector3.ZERO
		var best_len := 0.0
		for i2 in _body.contact_count:
			var n2: Vector3 = _body.get_contact_normal(i2)
			if n2.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
				continue
			if n2.y < 0.0:
				continue
			var nh2 := Vector3(n2.x, 0.0, n2.z)
			if nh2.length_squared() > 0.001:
				nh2 = nh2.normalized()
				var d2 := hdir_original.dot(nh2)
				if d2 < 0.0:
					var projected := hdir_original - nh2 * d2
					var plen := projected.length()
					if plen > best_len:
						best_len = plen
						best = projected
		hdir = best

	var wall_factor := hdir.length()
	if wall_factor > 0.001:
		hdir = hdir / wall_factor
	else:
		if hspeed <= DIME_STOP_SPEED:
			return Vector3.ZERO
		return hvel.move_toward(Vector3.ZERO, WALK_ACCEL * delta)

	var max_speed := MAX_SPEED * wall_factor

	# Dime stop
	if hspeed > 0.01 and hspeed <= DIME_STOP_SPEED:
		var vel_along := hvel.dot(hdir)
		if vel_along < 0.0:
			hvel -= hdir * vel_along
			hspeed = hvel.length()

	# Accelerate
	var vel_toward := hvel.dot(hdir)
	if vel_toward < max_speed:
		var speed_add := WALK_ACCEL * delta
		var new_toward := minf(vel_toward + speed_add, max_speed)
		hvel += hdir * (new_toward - vel_toward)

	return hvel


func _report() -> void:
	var pass_osc := _max_oscillation < 0.005  # < 5mm oscillation
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  OBTUSE CORNER WOBBLE TEST")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  Max oscillation: %.4f mm" % (_max_oscillation * 1000.0))
	print("[TEST]  %s (need < 5mm)" % ("PASS" if pass_osc else "FAIL"))
	print("[TEST] ══════════════════════════════════════════")


func _create_static_box(pos: Vector3, box_size: Vector3, rot: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box_size
	col.shape = shape
	body.add_child(col)
	body.position = pos
	body.rotation = rot
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
	body.contact_monitor = true
	body.max_contacts_reported = 16
	body.position = pos
	return body
