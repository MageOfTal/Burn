extends RigidBody3D
## Minimal RigidBody3D that tracks contact data for physics tests.

var has_floor_contact: bool = false
var floor_normal: Vector3 = Vector3.UP
var contact_count: int = 0
var wall_normal: Vector3 = Vector3.ZERO
var on_dynamic_body: bool = false
var contact_normals: Array[Vector3] = []

# Landing restore — set these from the test script to trigger
# velocity override inside _integrate_forces (before position integration).
var landing_restore_hvel: Vector3 = Vector3.ZERO
var landing_restore_pending: bool = false
var was_grounded_last_frame: bool = false


func get_contact_normal(i: int) -> Vector3:
	if i < contact_normals.size():
		return contact_normals[i]
	return Vector3.ZERO


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	has_floor_contact = false
	on_dynamic_body = false
	contact_count = state.get_contact_count()
	wall_normal = Vector3.ZERO
	floor_normal = Vector3.UP
	contact_normals.clear()
	var best_floor_y := -1.0
	var best_wall_horiz := -1.0

	for i in contact_count:
		var normal := state.get_contact_local_normal(i)
		contact_normals.append(normal)
		var collider := state.get_contact_collider_object(i)
		if collider is RigidBody3D:
			if normal.y > 0.7:
				on_dynamic_body = true
		if normal.angle_to(Vector3.UP) <= deg_to_rad(50):
			has_floor_contact = true
			if normal.y > best_floor_y:
				best_floor_y = normal.y
				floor_normal = normal
		elif Vector2(normal.x, normal.z).length() > best_wall_horiz:
			best_wall_horiz = Vector2(normal.x, normal.z).length()
			wall_normal = normal

	# Landing velocity override: restore intended hvel before position integration
	if has_floor_contact and not was_grounded_last_frame and landing_restore_pending:
		landing_restore_pending = false
		var vel := state.linear_velocity
		vel.x = landing_restore_hvel.x
		vel.z = landing_restore_hvel.z
		if best_floor_y > 0.0:
			vel.y = -(floor_normal.x * vel.x + floor_normal.z * vel.z) / floor_normal.y
		state.linear_velocity = vel
	was_grounded_last_frame = has_floor_contact
