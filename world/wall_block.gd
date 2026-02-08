extends StaticBody3D

## Single block within a destructible wall.
## Receives hitscan damage and forwards it to the parent wall for HP tracking.

var grid_key: Vector3i = Vector3i.ZERO
var parent_wall: Node = null  ## Reference to the DestructibleWall node


func take_damage(amount: float, attacker_id: int) -> void:
	## Called by hitscan weapons when a bullet hits this block.
	if not multiplayer.is_server():
		return
	if parent_wall and is_instance_valid(parent_wall):
		parent_wall._damage_block(grid_key, amount, attacker_id)
