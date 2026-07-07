extends StaticBody3D

## Non-destructible smooth ramp — a single mesh + collision shape with no
## block grid.  Used for testing ramp physics without block-edge artifacts.

var ramp_size := Vector3(5, 0.5, 12)  ## width, thickness, length


func _ready() -> void:
	_build_mesh()
	_build_collision()


func _build_mesh() -> void:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box := BoxMesh.new()
	box.size = ramp_size
	mesh_instance.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.4, 0.7)  # Pink
	mat.roughness = 0.8
	mesh_instance.material_override = mat

	add_child(mesh_instance)


func _build_collision() -> void:
	var col := CollisionShape3D.new()
	col.name = "Collision"
	var shape := BoxShape3D.new()
	shape.size = ramp_size
	col.shape = shape
	add_child(col)
