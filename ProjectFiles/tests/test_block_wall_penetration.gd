extends Node3D

# Isolated body-solver measurement: how deep does a pushed block sink into a
# static wall? A 40 kg box is pressed against a wall with a constant 1000 N
# (the character's max push force) for 3 seconds; we report the equilibrium
# overlap between the box face and the wall face. This is pure Jolt
# body-vs-static — no character involved — to answer whether "block phasing
# into the wall" has a real body-solver component or was entirely the (now
# fixed) block-into-player interpenetration.
#
# Run headless: Godot --headless res://tests/test_block_wall_penetration.tscn

const PUSH_FORCE := 1000.0
const BOX_SIZE := 1.0
const WALL_FACE_X := 5.0  # wall's near face plane

var _box: RigidBody3D
var _frames := 0

func _ready() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	var gcol := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(40, 1, 40)
	gcol.shape = gbox
	gcol.position = Vector3(0, -0.5, 0)
	ground.add_child(gcol)
	add_child(ground)

	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var wcol := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(1, 6, 8)
	wcol.shape = wbox
	wcol.position = Vector3(WALL_FACE_X + 0.5, 3, 0)
	wall.add_child(wcol)
	add_child(wall)

	_box = RigidBody3D.new()
	_box.mass = 40.0
	_box.collision_layer = 1
	_box.collision_mask = 1
	var bcol := CollisionShape3D.new()
	var bshape := BoxShape3D.new()
	bshape.size = Vector3(BOX_SIZE, BOX_SIZE, BOX_SIZE)
	bcol.shape = bshape
	_box.add_child(bcol)
	_box.position = Vector3(WALL_FACE_X - BOX_SIZE, BOX_SIZE * 0.5, 0)
	add_child(_box)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames < 10:
		return
	_box.apply_central_force(Vector3(PUSH_FORCE, 0, 0))
	if _frames % 60 == 0 or _frames == 190:
		var face_x: float = _box.global_position.x + BOX_SIZE * 0.5
		var pen: float = face_x - WALL_FACE_X
		print("[TEST] t=%.1fs box face x=%.4f wall face x=%.1f overlap=%+.4f m (v=%.3f)" % [
			_frames / 60.0, face_x, WALL_FACE_X, pen, _box.linear_velocity.length()])
	if _frames >= 190:
		var pen: float = (_box.global_position.x + BOX_SIZE * 0.5) - WALL_FACE_X
		if pen > 0.05:
			print("[TEST] === FAIL: block sinks %.3f m into the wall under sustained 1000 N ===" % pen)
			get_tree().quit(1)
		else:
			print("[TEST] === PASS: equilibrium overlap %+.4f m (slop-scale) ===" % pen)
			get_tree().quit(0)
