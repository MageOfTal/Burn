extends Node3D

var _setup_done := false
var _frames := 0
var _body: StaticBody3D
var _col_a: CollisionShape3D
var _col_b: CollisionShape3D
var _box_a: BoxShape3D
var _box_b: BoxShape3D


func _ready() -> void:
	_body = StaticBody3D.new()
	_body.name = "CompoundCorner"
	_body.collision_layer = 1
	_body.collision_mask = 1
	add_child(_body)

	_box_a = BoxShape3D.new()
	_box_a.size = Vector3(2, 4, 2)
	_col_a = CollisionShape3D.new()
	_col_a.shape = _box_a
	_col_a.position = Vector3(-1, 0, 1)
	_body.add_child(_col_a)

	_box_b = BoxShape3D.new()
	_box_b.size = Vector3(2, 4, 2)
	_col_b = CollisionShape3D.new()
	_col_b.shape = _box_b
	_col_b.position = Vector3(1, 0, -1)
	_body.add_child(_col_b)


func _physics_process(_delta: float) -> void:
	_frames += 1
	# Wait 10 physics frames for everything to register, then run.
	if _frames != 10:
		return

	var space := get_world_3d().direct_space_state
	if space == null:
		print("[TEST] no space state")
		get_tree().quit()
		return

	print("[TEST] === Setup ===")
	print("[TEST] body global_position=%v" % _body.global_position)
	print("[TEST] body layer=%d mask=%d" % [_body.collision_layer, _body.collision_mask])
	print("[TEST] box A center=%v size=%v" % [_col_a.global_position, _box_a.size])
	print("[TEST] box B center=%v size=%v" % [_col_b.global_position, _box_b.size])
	print("[TEST] flag (queries/use_enhanced_internal_edge_removal) = %s" % str(
		ProjectSettings.get_setting("physics/jolt_physics_3d/queries/use_enhanced_internal_edge_removal", false)))

	# Sanity: intersect_ray straight down through Box A.
	var ray := PhysicsRayQueryParameters3D.new()
	ray.from = Vector3(-0.5, 5, 0.5)
	ray.to = Vector3(-0.5, -5, 0.5)
	ray.collision_mask = 0xFFFFFFFF
	var ray_hit := space.intersect_ray(ray)
	print("[TEST] ray sanity: %s" % ("HIT body" if not ray_hit.is_empty() else "NO HIT"))

	# Sanity: intersect_point inside Box A.
	var pt_query := PhysicsPointQueryParameters3D.new()
	pt_query.position = Vector3(-0.5, 0, 0.5)  # well inside Box A
	pt_query.collision_mask = 0xFFFFFFFF
	pt_query.collide_with_bodies = true
	var pt_hits := space.intersect_point(pt_query, 8)
	print("[TEST] point sanity at (-0.5, 0, 0.5): %d hit(s)" % pt_hits.size())

	# --- Scenario 1: sphere deep inside box A. Baseline — must detect. ---
	_run_scenario("Scenario 1: sphere deep inside Box A (baseline)",
		Vector3(-0.5, 0, 0.5), 0.4, space)

	# --- Scenario 2: sphere overlapping the outer 90° corner. ---
	# Corner at origin. Sphere positioned along bisector +X+Z deep enough
	# to overlap both boxes' volumes substantially.
	var bisector := Vector3(1, 0, 1).normalized()
	_run_scenario("Scenario 2: probe on outer 90° corner edge (small overlap)",
		bisector * 0.30, 0.4, space)
	_run_scenario("Scenario 2b: probe deep at corner (big overlap)",
		Vector3.ZERO, 0.4, space)
	_run_scenario("Scenario 2c: probe straddling corner from outside",
		bisector * 0.20, 0.5, space)
	_run_scenario("Scenario 2d: probe just inside Box A near corner",
		Vector3(-0.1, 0, 0.1), 0.4, space)
	_run_scenario("Scenario 2e: probe at corner with big size",
		Vector3.ZERO, 1.5, space)

	# --- Scenario 4: single (non-compound) box, probe at its corner.
	# Isolates compound-shape effects.
	var single_body := StaticBody3D.new()
	single_body.name = "SingleBox"
	single_body.position = Vector3(100, 0, 0)  # far away
	add_child(single_body)
	var single_col := CollisionShape3D.new()
	var single_box := BoxShape3D.new()
	single_box.size = Vector3(2, 4, 2)
	single_col.shape = single_box
	single_col.position = Vector3(-1, 0, 1)
	single_body.add_child(single_col)
	# Probe relative to single_body's origin: same corner geometry as compound.
	await get_tree().physics_frame
	await get_tree().physics_frame
	_run_scenario("Scenario 4: single-box body, probe outside corner",
		Vector3(100 + 0.212, 0, 0.212), 0.4, space)
	_run_scenario("Scenario 4b: single-box body, probe inside",
		Vector3(100 - 0.5, 0, 0.5), 0.4, space)

	# --- Scenario 3: sphere fully outside both boxes (sanity). ---
	_run_scenario("Scenario 3: sphere far away (sanity, expect zero)",
		Vector3(5, 0, 5), 0.4, space)

	# --- Raycast scenarios: these are what grapple LOS actually uses. ---
	# Compound body lives at origin. Outer corner where Box A's +X face
	# (at x=0, z∈[0,2]) meets Box B's +Z face (at z=0, x∈[0,2]) — a 90°
	# outer edge along the line x=0, z=0, y∈[-2,2].
	_run_ray("Ray 1: from outside +X+Z heading toward corner (head-on)",
		Vector3(2, 0, 2), Vector3(0, 0, 0), space)
	_run_ray("Ray 2: skim past corner along +X (just misses A's +X face)",
		Vector3(2, 0, -0.01), Vector3(-2, 0, -0.01), space)
	_run_ray("Ray 3: graze corner exactly on edge line",
		Vector3(3, 0, 3), Vector3(-0.001, 0, -0.001), space)
	_run_ray("Ray 4: fire FROM corner outward (LOS from a point on edge)",
		Vector3(0.001, 0, 0.001), Vector3(5, 0, 5), space)
	_run_ray("Ray 5: diagonal across into Box A's +X face",
		Vector3(1, 0, 1), Vector3(-1, 0, 1), space)
	_run_ray("Ray 6: same as 5 but on the edge plane (y=0)",
		Vector3(1, 0, 0.001), Vector3(-1, 0, 0.001), space)

	# --- Scenario 4: sphere overlapping the inner seam between A and B. ---
	# A occupies x ∈ [-2, 0], z ∈ [0, 2]. B occupies x ∈ [0, 2], z ∈ [-2, 0].
	# They share only the single point at (0, *, 0). There IS no inner seam
	# between coplanar faces — the boxes don't share a face. Skipping.

	get_tree().quit()


func _run_ray(label: String, from: Vector3, to: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var ray := PhysicsRayQueryParameters3D.new()
	ray.from = from
	ray.to = to
	ray.collision_mask = 0xFFFFFFFF
	var hit := space.intersect_ray(ray)
	print("[TEST] --- %s ---" % label)
	print("[TEST]   from=%v to=%v" % [from, to])
	if hit.is_empty():
		print("[TEST]   intersect_ray: NO HIT")
	else:
		var col = hit.get("collider", null)
		var n: Vector3 = hit.get("normal", Vector3.ZERO)
		var p: Vector3 = hit.get("position", Vector3.ZERO)
		var s = hit.get("shape", -1)
		print("[TEST]   intersect_ray: HIT collider=%s shape=%d" % [
			col.name if col else "null", s])
		print("[TEST]     point=%v normal=%v" % [p, n])


func _run_scenario(label: String, sphere_pos: Vector3, radius: float, space: PhysicsDirectSpaceState3D) -> void:
	# Use a small box as the probe shape (sphere shape query was returning
	# zero hits in this Godot/Jolt build for some reason — likely a shape
	# init quirk).
	var box := BoxShape3D.new()
	box.size = Vector3(radius * 2, radius * 2, radius * 2)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis(), sphere_pos)
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_bodies = true

	var hits: Array = space.intersect_shape(query, 16)
	var contacts: Array = space.collide_shape(query, 32)
	var rest: Dictionary = space.get_rest_info(query)

	print("[TEST] --- %s ---" % label)
	print("[TEST]   sphere pos=%v r=%.2f" % [sphere_pos, radius])
	print("[TEST]   intersect_shape: %d hit(s)" % hits.size())
	for h in hits:
		var col = h.get("collider", null)
		var shape_idx = h.get("shape", -1)
		print("[TEST]     collider=%s shape_idx=%d" % [
			col.name if col else "null", shape_idx])
	print("[TEST]   collide_shape: %d contact pair(s)" % (contacts.size() / 2))
	for i in range(0, contacts.size(), 2):
		var p_query: Vector3 = contacts[i]
		var p_hit: Vector3 = contacts[i + 1]
		print("[TEST]     [%d] qry=%v  hit=%v" % [i / 2, p_query, p_hit])
	if rest.is_empty():
		print("[TEST]   get_rest_info: NO HIT")
	else:
		var n: Vector3 = rest.get("normal", Vector3.ZERO)
		var p: Vector3 = rest.get("point", Vector3.ZERO)
		print("[TEST]   get_rest_info: normal=%v point=%v" % [n, p])
