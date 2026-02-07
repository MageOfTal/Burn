extends SpringArm3D

## Third-person camera using SpringArm3D for collision handling.
## The SpringArm3D pulls the camera in when it would clip through walls.

func _ready() -> void:
	# Exclude the CharacterBody3D from spring arm collision.
	# SpringArm3D is under CameraPivot, which is under the CharacterBody3D.
	var player := get_parent().get_parent()
	if player is CollisionObject3D:
		add_excluded_object(player.get_rid())
