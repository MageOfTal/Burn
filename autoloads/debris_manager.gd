extends Node

## Global debris budget manager. Caps the total number of active cosmetic
## debris RigidBody3D nodes to prevent frame drops during intense combat.
## Oldest debris is culled when the cap is exceeded.

const MAX_DEBRIS := 60

var _active: Array[RigidBody3D] = []


func register(debris: RigidBody3D) -> void:
	_active.append(debris)
	_enforce_budget()


func unregister(debris: RigidBody3D) -> void:
	_active.erase(debris)


func is_at_cap() -> bool:
	return _active.size() >= MAX_DEBRIS


func _enforce_budget() -> void:
	while _active.size() > MAX_DEBRIS:
		var oldest: RigidBody3D = _active.pop_front() as RigidBody3D
		if is_instance_valid(oldest):
			oldest.queue_free()
