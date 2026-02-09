extends SpringArm3D

## Third-person camera using SpringArm3D for collision handling.
## The SpringArm3D pulls the camera in when it would clip through walls.
## A SphereShape3D makes the sweep wider than a thin ray, preventing
## the camera from clipping through wall edges and corners.

func _ready() -> void:
	# Exclude the CharacterBody3D from spring arm collision.
	# SpringArm3D is under CameraPivot, which is under the CharacterBody3D.
	var player := get_parent().get_parent()
	if player is CollisionObject3D:
		add_excluded_object(player.get_rid())

	# Use a sphere shape instead of a thin ray — prevents the camera from
	# slipping through cracks between wall blocks and around edges.
	var sweep_shape := SphereShape3D.new()
	sweep_shape.radius = 0.3  # Wide margin — camera stays 30cm from walls
	shape = sweep_shape

	# Margin pushes the camera inward on top of the shape radius.
	# Combined with the 0.3 sphere this keeps the camera ~40cm from surfaces.
	margin = 0.15

	# Ensure the spring arm checks all world geometry layers
	collision_mask = 1
