extends Node3D
## Integration tests for contact flicker on convex terrain.
##
## Uses ConcavePolygonShape3D (trimesh) with micro-convex bumps to simulate
## TransVoxel terrain roughness. Boxes don't reproduce the issue because Jolt
## handles clean box-edge transitions smoothly.
##
##   Test 4: 20° slope with ±3° bumps every 1m. Walk at 9 m/s.
##   Test 5: 26° slope with ±3° bumps every 1m. Walk at 9 m/s.
##   Test 6: 30°→14° abrupt normal change. Edge launch should NOT fire.
##   Test 7: 45° ramp launch. vel.y should not be pulled down by press.
##   Test 8: 45°→15° redirect launch. vel.y should match 15° tangent.
##
## Run: Engine/Godot_v4.6-stable_win64.exe --headless --path ProjectFiles res://tests/test_convex_terrain_flicker.tscn

const _TBody = preload("res://tests/test_floor_press_body.gd")

const GRAVITY: float = 17.5
const WALK_SPEED: float = 9.1
const FLOOR_MAX_ANGLE: float = 0.8727  # 50 degrees
const SETTLE_FRAMES: int = 120
const TEST_FRAMES: int = 420


var _frame: int = 0

# ── Test 4: ~20° bumpy slope ──────────────────────────────────────
var _body_t4: _TBody
var _t4_settled: bool = false
var _t4_floor_lost: int = 0
var _t4_measuring: int = 0

# ── Test 5: ~26° bumpy slope ──────────────────────────────────────
var _body_t5: _TBody
var _t5_settled: bool = false
var _t5_floor_lost: int = 0
var _t5_measuring: int = 0

# ── Test 6: Normal-jump edge launch ──────────────────────────────
var _body_t6: _TBody
var _t6_settled: bool = false
var _t6_false_launches: int = 0
var _t6_contact_frames: int = 0
var _t6_prev_normal: Vector3 = Vector3.UP
var _t6_prev_velocity: Vector3 = Vector3.ZERO

# ── Test 7: 45° ramp launch ─────────────────────────────────────
var _body_t7: _TBody
var _t7_settled: bool = false
var _t7_was_grounded: bool = false
var _t7_launch_vel_y: float = NAN
var _t7_last_slope_y: float = 0.0  ## Tangent y on last grounded frame
var _t7_last_press_vel: Vector3 = Vector3.ZERO

# ── Test 8: 15° ramp launch ─────────────────────────────────────
var _body_t8: _TBody
var _t8_settled: bool = false
var _t8_was_grounded: bool = false
var _t8_launch_vel_y: float = NAN
var _t8_last_slope_y: float = 0.0
var _t8_last_press_vel: Vector3 = Vector3.ZERO


func _ready() -> void:
	_setup_test4()
	_setup_test5()
	_setup_test6()
	_setup_test7()
	_setup_test8()
	print("[TEST] Convex terrain flicker tests — 5 scenarios")
	print("[TEST] Settle: %d frames, Test: %d frames" % [SETTLE_FRAMES, TEST_FRAMES - SETTLE_FRAMES])


# ════════════════════════════════════════════════════════════════════
#  Setup
# ════════════════════════════════════════════════════════════════════

func _setup_test4() -> void:
	## 20° slope with random vertex perturbation (±0.06m) on 1m grid.
	## Simulates TransVoxel terrain roughness at walking speed.
	var terrain := _create_rough_terrain(
		Vector3(-30, 25, -15),
		20.0,                    # Base slope angle
		0.15,                    # Vertex height perturbation (meters)
		1.0,                     # Grid cell size
		60.0, 10.0,              # Length, width
		42)                      # RNG seed
	terrain.name = "T4_terrain"
	add_child(terrain)

	_body_t4 = _create_test_body(Vector3(-30, 25.0 + 3.0, -13.0))
	add_child(_body_t4)


func _setup_test5() -> void:
	## 26° slope with same roughness. Steeper = more contact loss.
	var terrain := _create_rough_terrain(
		Vector3(0, 30, -15),
		26.0, 0.15, 1.0, 60.0, 10.0, 137)
	terrain.name = "T5_terrain"
	add_child(terrain)

	_body_t5 = _create_test_body(Vector3(0, 30.0 + 3.0, -13.0))
	add_child(_body_t5)


func _setup_test6() -> void:
	## 30° slope → 14° slope, abrupt transition. Built as trimesh.
	## Edge launch should NOT fire when walking over the transition.
	var terrain := _create_two_slope_terrain(
		Vector3(30, 25, -15),
		30.0, 14.0,  # steep → gentle
		30.0, 30.0,  # 30m each
		10.0)
	terrain.name = "T6_terrain"
	add_child(terrain)

	_body_t6 = _create_test_body(Vector3(30, 25.0 + 3.0, -13.0))
	add_child(_body_t6)


func _setup_test7() -> void:
	## 45° ramp going up in +z, then drops off (no terrain after ramp end).
	## Body starts on the ramp, walks up at 9.1 m/s, launches off the top.
	## Verify: launch vel.y is not pulled down by the surface press.
	var ramp_start := Vector3(-60, 0, 0)
	var terrain := _create_ramp_terrain(
		ramp_start,
		45.0,       # ramp angle
		-1.0,       # no redirect (single slope)
		20.0, 10.0) # 20m slope length, 10m wide
	terrain.name = "T7_terrain"
	add_child(terrain)
	# Start 3m up the ramp surface (dist=3 along slope → y=3*sin45, z=3*cos45)
	var start_y := ramp_start.y + 3.0 * sin(deg_to_rad(45)) + 1.5
	var start_z := ramp_start.z + 3.0 * cos(deg_to_rad(45))
	_body_t7 = _create_test_body(Vector3(-60, start_y, start_z))
	add_child(_body_t7)


func _setup_test8() -> void:
	## 15° ramp — body walks up at 9.1 m/s, launches off the end.
	## Verifies that vel.y at launch matches the 15° tangent (not pulled down).
	var ramp_start := Vector3(-90, 0, 0)
	var terrain := _create_ramp_terrain(
		ramp_start,
		15.0,       # ramp angle
		-1.0,       # no redirect
		20.0, 10.0) # 20m slope length, 10m wide
	terrain.name = "T8_terrain"
	add_child(terrain)
	var start_y := ramp_start.y + 3.0 * sin(deg_to_rad(15)) + 1.5
	var start_z := ramp_start.z + 3.0 * cos(deg_to_rad(15))
	_body_t8 = _create_test_body(Vector3(-90, start_y, start_z))
	add_child(_body_t8)


# ════════════════════════════════════════════════════════════════════
#  Terrain builders
# ════════════════════════════════════════════════════════════════════

func _create_rough_terrain(start: Vector3, base_angle_deg: float, perturb_m: float,
		cell_size: float, total_length: float, width: float, seed_val: int) -> StaticBody3D:
	## Build a ConcavePolygonShape3D slope with random vertex height perturbation.
	## Each vertex gets a random y-offset of ±perturb_m. This creates the kind of
	## micro-convexity found in TransVoxel terrain where adjacent triangles have
	## slightly different normals due to voxel grid discretization.
	var base_rad := deg_to_rad(base_angle_deg)
	var n_z := int(total_length / cell_size)
	var n_x := int(width / cell_size)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# Generate height grid with perturbation
	# heights[iz][ix] = base_slope_height + random_perturbation
	var heights: Array[PackedFloat64Array] = []
	for iz in n_z + 1:
		var row := PackedFloat64Array()
		row.resize(n_x + 1)
		for ix in n_x + 1:
			var dist := float(iz) * cell_size
			var base_y := -dist * sin(base_rad)
			# First 5 rows: no perturbation (settle zone)
			var noise := 0.0 if iz < 5 else rng.randf_range(-perturb_m, perturb_m)
			row[ix] = base_y + noise
		heights.append(row)

	# Build triangle faces from the grid
	var verts := PackedVector3Array()
	var x_start := -width * 0.5

	for iz in n_z:
		for ix in n_x:
			var x0 := x_start + float(ix) * cell_size
			var x1 := x0 + cell_size
			var z0 := float(iz) * cell_size * cos(base_rad)
			var z1 := float(iz + 1) * cell_size * cos(base_rad)

			var v00 := start + Vector3(x0, heights[iz][ix], z0)
			var v10 := start + Vector3(x1, heights[iz][ix + 1], z0)
			var v01 := start + Vector3(x0, heights[iz + 1][ix], z1)
			var v11 := start + Vector3(x1, heights[iz + 1][ix + 1], z1)

			# Two triangles per cell
			verts.append(v00)
			verts.append(v10)
			verts.append(v01)
			verts.append(v10)
			verts.append(v11)
			verts.append(v01)

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	col.shape = shape
	body.add_child(col)

	var n_tris := n_z * n_x * 2
	print("[TEST] Rough terrain: base=%.0f° perturb=±%.0fcm grid=%dx%d tris=%d" % [
		base_angle_deg, perturb_m * 100, n_z, n_x, n_tris])
	return body


func _create_two_slope_terrain(start: Vector3, angle1_deg: float, angle2_deg: float,
		len1: float, len2: float, width: float) -> StaticBody3D:
	## Build a trimesh with two slope sections meeting at a sharp transition.
	var half_w := width * 0.5
	var rad1 := deg_to_rad(angle1_deg)
	var rad2 := deg_to_rad(angle2_deg)
	var strip_len := 1.0  # 1m strips
	var verts := PackedVector3Array()

	# Section 1: steep slope
	var n1 := int(len1 / strip_len)
	for i in n1:
		var z0 := float(i) * strip_len
		var z1 := float(i + 1) * strip_len
		var y0 := -z0 * sin(rad1)
		var y1 := -z1 * sin(rad1)
		var wz0 := z0 * cos(rad1)
		var wz1 := z1 * cos(rad1)
		_add_quad_tris(verts, start, half_w, y0, wz0, y1, wz1)

	# Junction point
	var junc_y := -len1 * sin(rad1)
	var junc_z := len1 * cos(rad1)

	# Section 2: gentle slope (continues from junction)
	var n2 := int(len2 / strip_len)
	for i in n2:
		var z0 := float(i) * strip_len
		var z1 := float(i + 1) * strip_len
		var y0 := junc_y - z0 * sin(rad2)
		var y1 := junc_y - z1 * sin(rad2)
		var wz0 := junc_z + z0 * cos(rad2)
		var wz1 := junc_z + z1 * cos(rad2)
		_add_quad_tris(verts, start, half_w, y0, wz0, y1, wz1)

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	col.shape = shape
	body.add_child(col)

	print("[TEST] Two-slope terrain: %.0f°→%.0f° strips=%d tris=%d" % [
		angle1_deg, angle2_deg, n1 + n2, (n1 + n2) * 2])
	return body


func _create_ramp_terrain(start: Vector3, angle_deg: float, redirect_angle_deg: float,
		ramp_length: float, width: float) -> StaticBody3D:
	## Build an uphill ramp (no flat section — body starts on the ramp).
	## If redirect_angle_deg > 0, the last 2m use that shallower angle.
	var half_w := width * 0.5
	var strip_len := 1.0
	var verts := PackedVector3Array()
	var rad := deg_to_rad(angle_deg)
	var redirect_rad := deg_to_rad(redirect_angle_deg) if redirect_angle_deg > 0 else -1.0

	var redirect_start := ramp_length - 2.0 if redirect_rad > 0 else ramp_length + 1.0
	var n_ramp := int(ramp_length / strip_len)

	var junc_y := 0.0
	var junc_wz := 0.0

	for i in n_ramp:
		var dist0 := float(i) * strip_len
		var dist1 := dist0 + strip_len
		var y0: float
		var y1: float
		var wz0: float
		var wz1: float

		if dist0 >= redirect_start and redirect_rad > 0:
			var rd0 := dist0 - redirect_start
			var rd1 := dist1 - redirect_start
			y0 = junc_y + rd0 * sin(redirect_rad)
			y1 = junc_y + rd1 * sin(redirect_rad)
			wz0 = junc_wz + rd0 * cos(redirect_rad)
			wz1 = junc_wz + rd1 * cos(redirect_rad)
		else:
			y0 = dist0 * sin(rad)
			y1 = dist1 * sin(rad)
			wz0 = dist0 * cos(rad)
			wz1 = dist1 * cos(rad)
			if dist1 >= redirect_start and redirect_rad > 0:
				junc_y = y1
				junc_wz = wz1

		_add_quad_tris(verts, start, half_w, y0, wz0, y1, wz1)

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(verts)
	col.shape = shape
	body.add_child(col)

	var desc := "%.0f°" % angle_deg
	if redirect_angle_deg > 0:
		desc += "→%.0f°" % redirect_angle_deg
	print("[TEST] Ramp terrain: %s len=%.0fm strips=%d" % [desc, ramp_length, n_ramp])
	return body


func _add_quad_tris(verts: PackedVector3Array, start: Vector3, half_w: float,
		y0: float, z0: float, y1: float, z1: float) -> void:
	var v00 := start + Vector3(-half_w, y0, z0)
	var v10 := start + Vector3(half_w, y0, z0)
	var v01 := start + Vector3(-half_w, y1, z1)
	var v11 := start + Vector3(half_w, y1, z1)
	verts.append(v00)
	verts.append(v10)
	verts.append(v01)
	verts.append(v10)
	verts.append(v11)
	verts.append(v01)


# ════════════════════════════════════════════════════════════════════
#  Physics tick
# ════════════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	_frame += 1

	_tick_walking_body(_body_t4, delta, Vector3(0, 0, 1))
	_tick_walking_body(_body_t5, delta, Vector3(0, 0, 1))
	_tick_walking_body(_body_t6, delta, Vector3(0, 0, 1))
	_t7_last_press_vel = _tick_ramp_body(_body_t7, delta, _t7_last_press_vel)
	_t8_last_press_vel = _tick_ramp_body(_body_t8, delta, _t8_last_press_vel)

	if _frame == SETTLE_FRAMES:
		_t4_settled = _body_t4.has_floor_contact
		_t5_settled = _body_t5.has_floor_contact
		_t6_settled = _body_t6.has_floor_contact
		_t7_settled = _body_t7.has_floor_contact
		_t8_settled = _body_t8.has_floor_contact
		print("[TEST] Settled.")
		print("[TEST]   T4 (20° bumpy): pos=%s floor=%s" % [_body_t4.global_position, _t4_settled])
		print("[TEST]   T5 (26° bumpy): pos=%s floor=%s" % [_body_t5.global_position, _t5_settled])
		print("[TEST]   T6 (30°→14°): pos=%s floor=%s" % [_body_t6.global_position, _t6_settled])
		print("[TEST]   T7 (45° ramp): pos=%s floor=%s" % [_body_t7.global_position, _t7_settled])
		print("[TEST]   T8 (15° ramp): pos=%s floor=%s" % [_body_t8.global_position, _t8_settled])

	if _frame > SETTLE_FRAMES:
		_measure_test4()
		_measure_test5()
		_measure_test6()
		_measure_test7()
		_measure_test8()

	if _frame > SETTLE_FRAMES and _frame % 60 == 0:
		print("[TEST] f=%d | T4: lost=%d/%d | T5: lost=%d/%d | T6: launches=%d/%d" % [
			_frame,
			_t4_floor_lost, _t4_measuring,
			_t5_floor_lost, _t5_measuring,
			_t6_false_launches, _t6_contact_frames])
		print("[TEST]   T7: pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) floor=%s launched=%s" % [
			_body_t7.global_position.x, _body_t7.global_position.y, _body_t7.global_position.z,
			_body_t7.linear_velocity.x, _body_t7.linear_velocity.y, _body_t7.linear_velocity.z,
			_body_t7.has_floor_contact, not is_nan(_t7_launch_vel_y)])
		print("[TEST]   T8: pos=(%.1f,%.1f,%.1f) vel=(%.1f,%.1f,%.1f) floor=%s launched=%s" % [
			_body_t8.global_position.x, _body_t8.global_position.y, _body_t8.global_position.z,
			_body_t8.linear_velocity.x, _body_t8.linear_velocity.y, _body_t8.linear_velocity.z,
			_body_t8.has_floor_contact, not is_nan(_t8_launch_vel_y)])

	if _frame >= TEST_FRAMES:
		_report_results()
		get_tree().quit()


func _tick_walking_body(body: _TBody, delta: float, walk_dir_3d: Vector3) -> void:
	body.linear_velocity.y -= GRAVITY * delta

	if _frame < SETTLE_FRAMES:
		if body.has_floor_contact:
			body.linear_velocity.x = 0
			body.linear_velocity.z = 0
			_apply_slope_projection(body, delta)
		return

	var walk_2d := Vector2(walk_dir_3d.x, walk_dir_3d.z).normalized() * WALK_SPEED

	if body.has_floor_contact:
		if body.wall_normal != Vector3.ZERO:
			var wn2 := Vector2(body.wall_normal.x, body.wall_normal.z).normalized()
			var into_wall: float = walk_2d.dot(wn2)
			if into_wall < 0.0:
				walk_2d -= wn2 * into_wall
		body.linear_velocity.x = walk_2d.x
		body.linear_velocity.z = walk_2d.y
		_apply_slope_projection(body, delta)
	else:
		body.linear_velocity.x = walk_2d.x
		body.linear_velocity.z = walk_2d.y


func _tick_ramp_body(body: _TBody, delta: float, last_press: Vector3) -> Vector3:
	## Ramp test body: walks in +z uphill. Press undo on launch.
	## Returns the new press vector for tracking.
	# Undo press from previous frame if we launched (no contacts = solver
	# didn't absorb the press, so we restore the clean velocity).
	if body.contact_count == 0 and last_press != Vector3.ZERO:
		body.linear_velocity += last_press

	body.linear_velocity.y -= GRAVITY * delta

	if _frame < SETTLE_FRAMES:
		if body.has_floor_contact:
			body.linear_velocity.x = 0
			body.linear_velocity.z = 0
			return _apply_slope_projection_tracked(body, delta)
		return Vector3.ZERO

	if body.has_floor_contact:
		body.linear_velocity.x = 0
		body.linear_velocity.z = WALK_SPEED
		return _apply_slope_projection_tracked(body, delta)
	# Airborne: just gravity (already applied above)
	return Vector3.ZERO


func _apply_slope_projection(body: _TBody, delta: float) -> void:
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
		if perp < 0.0:
			body.linear_velocity -= n * perp


func _apply_slope_projection_tracked(body: _TBody, delta: float) -> Vector3:
	## Same as _apply_slope_projection but returns the press vector for undo tracking.
	var n: Vector3 = body.floor_normal
	if n == Vector3.ZERO:
		return Vector3.ZERO
	if n.angle_to(Vector3.UP) <= FLOOR_MAX_ANGLE:
		var slope_y: float = -(n.x * body.linear_velocity.x + n.z * body.linear_velocity.z) / n.y
		if slope_y < 0.0 or body.linear_velocity.y <= slope_y:
			body.linear_velocity.y = slope_y
		var press_speed: float = 0.06 / delta
		var press_vel := press_speed * n
		body.linear_velocity -= press_vel
		return press_vel
	else:
		var perp: float = body.linear_velocity.dot(n)
		if perp < 0.0:
			body.linear_velocity -= n * perp
		return Vector3.ZERO


# ════════════════════════════════════════════════════════════════════
#  Measurements
# ════════════════════════════════════════════════════════════════════

func _measure_test4() -> void:
	_t4_measuring += 1
	if not _body_t4.has_floor_contact:
		_t4_floor_lost += 1
		if _t4_floor_lost <= 5:
			print("[TEST]   T4 LOST f=%d pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) contacts=%d" % [
				_frame,
				_body_t4.global_position.x, _body_t4.global_position.y, _body_t4.global_position.z,
				_body_t4.linear_velocity.x, _body_t4.linear_velocity.y, _body_t4.linear_velocity.z,
				_body_t4.contact_count])


func _measure_test5() -> void:
	_t5_measuring += 1
	if not _body_t5.has_floor_contact:
		_t5_floor_lost += 1
		if _t5_floor_lost <= 5:
			print("[TEST]   T5 LOST f=%d pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) contacts=%d" % [
				_frame,
				_body_t5.global_position.x, _body_t5.global_position.y, _body_t5.global_position.z,
				_body_t5.linear_velocity.x, _body_t5.linear_velocity.y, _body_t5.linear_velocity.z,
				_body_t5.contact_count])


func _measure_test6() -> void:
	if not _body_t6.has_floor_contact:
		return
	_t6_contact_frames += 1
	var current_normal: Vector3 = _body_t6.floor_normal

	if _t6_prev_normal != Vector3.UP and _t6_prev_velocity != Vector3.ZERO:
		var edge_momentum: float = _t6_prev_velocity.dot(current_normal)

		if edge_momentum > 0.0:
			_t6_false_launches += 1
			print("[TEST]   T6 EDGE: mom=%.3f prev=%.1f° cur=%.1f°" % [
				edge_momentum,
				rad_to_deg(_t6_prev_normal.angle_to(Vector3.UP)),
				rad_to_deg(current_normal.angle_to(Vector3.UP))])

	_t6_prev_normal = current_normal
	_t6_prev_velocity = _body_t6.linear_velocity


func _measure_test7() -> void:
	## Track last grounded tangent y, detect launch, verify launch vel_y is clean.
	if not is_nan(_t7_launch_vel_y):
		return
	var grounded := _body_t7.has_floor_contact
	if grounded:
		# Record the tangent y on each grounded frame
		var n := _body_t7.floor_normal
		if n.y > 0.01:
			_t7_last_slope_y = -(n.x * _body_t7.linear_velocity.x + n.z * WALK_SPEED) / n.y
	if _t7_was_grounded and not grounded:
		_t7_launch_vel_y = _body_t7.linear_velocity.y
		print("[TEST]   T7 LAUNCH: vel_y=%.3f last_slope_y=%.3f pos=%s" % [
			_t7_launch_vel_y, _t7_last_slope_y, _body_t7.global_position])
	_t7_was_grounded = grounded


func _measure_test8() -> void:
	if not is_nan(_t8_launch_vel_y):
		return
	var grounded := _body_t8.has_floor_contact
	if grounded:
		var n := _body_t8.floor_normal
		if n.y > 0.01:
			_t8_last_slope_y = -(n.x * _body_t8.linear_velocity.x + n.z * WALK_SPEED) / n.y
	if _t8_was_grounded and not grounded:
		_t8_launch_vel_y = _body_t8.linear_velocity.y
		print("[TEST]   T8 LAUNCH: vel_y=%.3f last_slope_y=%.3f pos=%s" % [
			_t8_launch_vel_y, _t8_last_slope_y, _body_t8.global_position])
	_t8_was_grounded = grounded


# ════════════════════════════════════════════════════════════════════
#  Results
# ════════════════════════════════════════════════════════════════════

func _report_results() -> void:
	print("")
	print("[TEST] ══════════════════════════════════════════")
	print("[TEST]  CONVEX TERRAIN FLICKER RESULTS")
	print("[TEST] ══════════════════════════════════════════")

	var t4_pass: bool = _t4_floor_lost == 0 and _t4_settled
	print("[TEST]")
	print("[TEST]  4) Bumpy 20° slope (walk at 9 m/s downhill)")
	print("[TEST]     Settled: %s" % _t4_settled)
	print("[TEST]     Floor lost: %d / %d frames" % [_t4_floor_lost, _t4_measuring])
	print("[TEST]     %s (need: 0 floor loss)" % ("PASS" if t4_pass else "FAIL"))

	var t5_pass: bool = _t5_floor_lost == 0 and _t5_settled
	print("[TEST]")
	print("[TEST]  5) Bumpy 26° slope (walk at 9 m/s downhill)")
	print("[TEST]     Settled: %s" % _t5_settled)
	print("[TEST]     Floor lost: %d / %d frames" % [_t5_floor_lost, _t5_measuring])
	print("[TEST]     %s (need: 0 floor loss)" % ("PASS" if t5_pass else "FAIL"))

	var t6_pass: bool = _t6_false_launches == 0 and _t6_settled
	print("[TEST]")
	print("[TEST]  6) Normal-jump 30°→14° (edge launch false positive)")
	print("[TEST]     Settled: %s" % _t6_settled)
	print("[TEST]     Contact frames: %d" % _t6_contact_frames)
	print("[TEST]     False launches: %d" % _t6_false_launches)
	print("[TEST]     %s (need: 0 false launches)" % ("PASS" if t6_pass else "FAIL"))

	# Test 7: Launch vel.y should be close to the last grounded tangent y
	# (within 2 frames of gravity + 0.5 m/s tolerance for solver effects)
	var t7_captured: bool = not is_nan(_t7_launch_vel_y)
	var t7_min_y: float = _t7_last_slope_y - GRAVITY * (2.0 / 60.0) - 0.5 if t7_captured else 0.0
	var t7_pass: bool = t7_captured and _t7_launch_vel_y >= t7_min_y
	print("[TEST]")
	print("[TEST]  7) 45° ramp launch (vel.y not pulled down by press)")
	if t7_captured:
		print("[TEST]     Launch vel.y: %.3f m/s" % _t7_launch_vel_y)
		print("[TEST]     Last grounded tangent y: %.3f m/s" % _t7_last_slope_y)
		print("[TEST]     Min acceptable: %.3f m/s" % t7_min_y)
	else:
		print("[TEST]     NO LAUNCH DETECTED")
	print("[TEST]     %s" % ("PASS" if t7_pass else "FAIL"))

	# Test 8: Same check for 15° ramp
	var t8_captured: bool = not is_nan(_t8_launch_vel_y)
	var t8_min_y: float = _t8_last_slope_y - GRAVITY * (2.0 / 60.0) - 0.5 if t8_captured else 0.0
	var t8_pass: bool = t8_captured and _t8_launch_vel_y >= t8_min_y
	print("[TEST]")
	print("[TEST]  8) 15° ramp launch (vel.y not pulled down by press)")
	if t8_captured:
		print("[TEST]     Launch vel.y: %.3f m/s" % _t8_launch_vel_y)
		print("[TEST]     Last grounded tangent y: %.3f m/s" % _t8_last_slope_y)
		print("[TEST]     Min acceptable: %.3f m/s" % t8_min_y)
	else:
		print("[TEST]     NO LAUNCH DETECTED")
	print("[TEST]     %s" % ("PASS" if t8_pass else "FAIL"))

	print("[TEST]")
	var all_pass: bool = t4_pass and t5_pass and t6_pass and t7_pass and t8_pass
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
