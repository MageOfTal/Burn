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
	sweep_shape.radius = 0.15  # Generous margin — camera stays ~15cm from walls
	shape = sweep_shape

	# Increase margin for additional safety (pushes the camera inward
	# by this much on top of the shape radius)
	margin = 0.1
