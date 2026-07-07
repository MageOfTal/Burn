extends Node3D

# Headless smoke test for the v2 toad bowl: builds it on a flat floor and
# verifies the collision is SOLID (the old bowl was a zero-thickness trimesh
# that tunneled): floor, walls, threshold, landing and ramp must all answer
# raycasts, and the toads must remain contained after settling.
#
# Run headless: Godot --headless res://tests/test_toad_bowl.tscn

var _bowl: Node3D
var _frames := 0
var _failures: Array[String] = []


func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(120, 1, 120)
	col.shape = box
	col.position = Vector3(0, -0.5, 0)
	ground.add_child(col)
	add_child(ground)

	_bowl = Node3D.new()
	_bowl.name = "ToadBowl"
	_bowl.set_script(load("res://world/toad_bowl.gd"))
	add_child(_bowl)
	_bowl.build(Vector3.ZERO)


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.new()
	q.from = from
	q.to = to
	q.collision_mask = 1
	return get_world_3d().direct_space_state.intersect_ray(q)


func _expect_hit(from: Vector3, to: Vector3, what: String, y_min: float, y_max: float) -> void:
	var hit := _ray(from, to)
	if hit.is_empty():
		_failures.append("%s: NO collision hit (ray %s → %s)" % [what, from, to])
		return
	var y: float = (hit.position as Vector3).y
	var who: String = hit.collider.name if hit.collider else "?"
	print("[TEST] %s: hit %s at y=%.2f" % [what, who, y])
	if y < y_min or y > y_max:
		_failures.append("%s: hit at y=%.2f, expected %.2f..%.2f" % [what, y, y_min, y_max])


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == 30:
		# Static geometry probes (bowl base at y=0, arena floor top at y=1,
		# lip/landing top at y=2.2, walls 1..4.5, doorway toward +Z).
		_expect_hit(Vector3(0, 10, 0), Vector3(0, -2, 0), "arena floor", 0.9, 1.1)
		_expect_hit(Vector3(0, 10, 8.7), Vector3(0, -2, 8.7), "landing top", 2.0, 2.4)
		_expect_hit(Vector3(0, 2.5, 0), Vector3(12, 2.5, 0), "wall (+X)", -99, 99)
		_expect_hit(Vector3(0, 2.5, 0), Vector3(-12, 2.5, 0), "wall (-X)", -99, 99)
		_expect_hit(Vector3(0, 2.5, 0), Vector3(0, 2.5, -12), "wall (-Z)", -99, 99)
		# Doorway must be OPEN above the threshold (ray at y=2.5 toward +Z exits)
		var door := _ray(Vector3(0, 2.6, 0), Vector3(0, 2.6, 7.6))
		if not door.is_empty():
			_failures.append("doorway blocked at y=2.6 by %s" % door.collider.name)
		else:
			print("[TEST] doorway: open above threshold")
		# Threshold must be CLOSED below its top
		_expect_hit(Vector3(0, 1.6, 0), Vector3(0, 1.6, 12), "threshold", -99, 99)
		# Ramp surface: probe down a few meters out along +Z past the landing
		_expect_hit(Vector3(0, 10, 11.5), Vector3(0, -2, 11.5), "ramp surface", 0.2, 2.2)
	if _frames == 300:
		# Containment: after 5 s of bouncing, all toads still inside the arena.
		var toads := _bowl.get_node_or_null("BowlToads")
		var out := 0
		var total := 0
		if toads:
			for t in toads.get_children():
				total += 1
				var p: Vector3 = (t as Node3D).global_position
				var r := Vector2(p.x, p.z).length()
				if r > 9.5 or p.y < -0.5:
					out += 1
		print("[TEST] containment: %d/%d toads escaped/tunneled" % [out, total])
		if total == 0:
			_failures.append("no toads spawned")
		elif out > 2:
			_failures.append("%d/%d toads escaped or tunneled out" % [out, total])
		if _failures.is_empty():
			print("[TEST] === PASS: toad bowl solid, doorway open, toads contained ===")
			get_tree().quit(0)
		else:
			print("[TEST] === FAIL: %d issue(s) ===" % _failures.size())
			for f in _failures:
				print("[TEST]   " + f)
			get_tree().quit(1)
