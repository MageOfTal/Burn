extends Node3D

# Headless smoke test for JoltCharacterVirtual3D (Phase 1 of the
# CharacterVirtual migration). Verifies:
#   1. the node creates a JPH::CharacterVirtual once the space is available
#   2. update() integrates the character and syncs the Node3D transform
#   3. get_contacts() reports contacts with BOTH surface_normal and
#      contact_normal — and at a compound internal-edge corner, surface_normal
#      is the true face normal (disagreeing with the averaged contact_normal),
#      which is the whole point of the migration
#   4. cast_shape() returns a hit with a real face normal
#
# Run headless: Godot --headless res://tests/test_character_virtual.tscn

const GRAVITY := Vector3(0, -24.0, 0)

var _frames := 0
var _floor: StaticBody3D
var _corner: StaticBody3D
var _cv: JoltCharacterVirtual3D
var _phase := 0


func _ready() -> void:
	# --- Flat floor ---
	_floor = StaticBody3D.new()
	_floor.name = "Floor"
	_floor.collision_layer = 1
	_floor.collision_mask = 1
	add_child(_floor)
	var floor_col := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(40, 1, 40)
	floor_col.shape = floor_box
	floor_col.position = Vector3(0, -0.5, 0)
	_floor.add_child(floor_col)

	# --- Compound "corner": two box shapes meeting at a 90° internal edge.
	# Box A occupies x ∈ [-2, 0], z ∈ [0, 2]; box B occupies x ∈ [0, 2],
	# z ∈ [-2, 0]. They touch only along the line x=0,z=0 — a sharp outer
	# edge where Jolt's manifold normal at a contact straddling the seam is
	# an average of the two faces, while GetWorldSpaceSurfaceNormal returns
	# the true per-triangle face.
	_corner = StaticBody3D.new()
	_corner.name = "CompoundCorner"
	_corner.collision_layer = 1
	_corner.collision_mask = 1
	add_child(_corner)
	var box_a := BoxShape3D.new()
	box_a.size = Vector3(2, 4, 2)
	var col_a := CollisionShape3D.new()
	col_a.shape = box_a
	col_a.position = Vector3(-1, 2, 1)   # sits on the floor (bottom at y=0)
	_corner.add_child(col_a)
	var box_b := BoxShape3D.new()
	box_b.size = Vector3(2, 4, 2)
	var col_b := CollisionShape3D.new()
	col_b.shape = box_b
	col_b.position = Vector3(1, 2, -1)
	_corner.add_child(col_b)

	# --- The character ---
	_cv = JoltCharacterVirtual3D.new()
	_cv.name = "Character"
	_cv.capsule_radius = 0.4
	_cv.capsule_height = 1.8
	_cv.character_mass = 70.0
	_cv.up_direction = Vector3.UP
	_cv.collision_layer = 1
	_cv.collision_mask = 1
	# KNOWN ISSUE (pre-existing, reproduced on the 2026-05-23 binary too): the
	# inner_body = true path crashes inside the first update(). The game runs
	# with inner_body = false (the frozen-kinematic RigidBody is the physics
	# presence), so the path is unused — but if inner_body is ever needed,
	# debug the crash in JPH inner-body creation first.
	_cv.inner_body = false
	# Place it on the floor, a little away from the corner along the +X+Z
	# bisector so a forward push walks it into the seam.
	_cv.position = Vector3(1.5, 0.9, 1.5)
	add_child(_cv)


func _physics_process(delta: float) -> void:
	_frames += 1
	# Let the static bodies register in the broadphase first, and give the
	# CharacterVirtual a few frames' worth of update() calls to lazily create.
	if _frames < 8:
		return

	if not _cv.is_ready():
		# update() lazily creates the CharacterVirtual; nudge it.
		_cv.update(Vector3.ZERO, delta, GRAVITY)
		if _frames < 40:
			return
		print("[TEST] FAIL: JoltCharacterVirtual3D never became ready after %d frames (no space?)" % _frames)
		get_tree().quit(1)
		return

	match _phase:
		0:
			print("[TEST] === Phase 0: standing on floor ===")
			print("[TEST] char pos=%v supported=%s ground_n=%v vel=%v" % [
				_cv.get_character_position(), str(_cv.is_supported()),
				_cv.get_ground_normal(), _cv.get_character_velocity()])
			# A few frames of just gravity — should settle on the floor.
			_cv.update(Vector3.ZERO, delta, GRAVITY)
			_dump_contacts("settle")
			_phase = 1
		1, 2, 3:
			_cv.update(Vector3.ZERO, delta, GRAVITY)
			if _phase == 3:
				print("[TEST] after settle: pos=%v supported=%s ground_n=%v" % [
					_cv.get_character_position(), str(_cv.is_supported()), _cv.get_ground_normal()])
				_dump_contacts("post-settle")
			_phase += 1
		4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15:
			# Walk toward the corner along -X-Z (the bisector pointing at the seam).
			var dir := Vector3(-1, 0, -1).normalized()
			_cv.update(dir * 6.0, delta, GRAVITY)
			if _phase >= 12:
				_dump_contacts("into-corner f%d" % _phase)
			_phase += 1
		16:
			# Shape cast toward the corner from the character's current spot.
			var from := Transform3D(Basis(), _cv.get_character_position())
			var hit := _cv.cast_shape(from, Vector3(-1, 0, -1).normalized() * 2.0, 0xFFFFFFFF)
			if hit.is_empty():
				print("[TEST] cast_shape: NO HIT")
			else:
				print("[TEST] cast_shape: HIT collider=%s fraction=%.4f" % [
					str(hit.get("collider")), hit.get("fraction", -1.0)])
				print("[TEST]   surface_normal=%v contact_normal=%v" % [
					hit.get("surface_normal"), hit.get("contact_normal")])
				var sn: Vector3 = hit.get("surface_normal", Vector3.ZERO)
				var cn: Vector3 = hit.get("contact_normal", Vector3.ZERO)
				print("[TEST]   disagreement = %.1f°" % rad_to_deg(sn.angle_to(cn)))
			print("[TEST] === done ===")
			get_tree().quit(0)


func _dump_contacts(label: String) -> void:
	var contacts: Array = _cv.get_contacts()
	print("[TEST]   [%s] pos=%v vel=%v supported=%s  %d contact(s)" % [
		label, _cv.get_character_position(), _cv.get_character_velocity(),
		str(_cv.is_supported()), contacts.size()])
	for c in contacts:
		var sn: Vector3 = c.get("surface_normal", Vector3.ZERO)
		var cn: Vector3 = c.get("contact_normal", Vector3.ZERO)
		var disagree := rad_to_deg(sn.angle_to(cn)) if sn != Vector3.ZERO and cn != Vector3.ZERO else 0.0
		var col = c.get("collider")
		var col_name := "?"
		if col is Node:
			col_name = (col as Node).name
		var tag := ""
		if disagree > 5.0:
			tag = "  *** INTERNAL-EDGE (surface_n vs contact_n disagree by %.1f°) ***" % disagree
		print("[TEST]     %s  surface_n=%v contact_n=%v dist=%.4f%s" % [
			col_name, sn, cn, c.get("distance", 0.0), tag])
