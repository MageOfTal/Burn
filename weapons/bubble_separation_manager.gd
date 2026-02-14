extends Node
class_name BubbleSeparationManager

## Centralized spatial-hash-grid manager for bubble-on-bubble separation forces.
## Replaces the old O(n^2) per-bubble neighbor scan with an O(n*k) approach
## where k is the average number of actual neighbors per bubble.
##
## Added as a child of BlockoutMap. Bubbles register/unregister themselves
## on _ready() / _exit_tree().
##
## Server-only: clients don't run bubble physics.

# ======================================================================
#  Constants
# ======================================================================

const SEPARATION_RADIUS := 1.3         ## Max distance for push-apart force
const PUSH_STRENGTH := 4.0             ## Force magnitude at zero distance
const CELL_SIZE := 1.3                 ## Grid cell size = separation radius

# Pre-computed
const SEP_RADIUS_SQ := SEPARATION_RADIUS * SEPARATION_RADIUS

# Spatial hash primes (standard technique to minimize collisions)
const HASH_P1 := 73856093
const HASH_P2 := 19349663
const HASH_P3 := 83492791

# ======================================================================
#  State
# ======================================================================

var _bubbles: Array[RigidBody3D] = []
var _grid: Dictionary = {}  ## hash -> Array[RigidBody3D]


func register(bubble: RigidBody3D) -> void:
	_bubbles.append(bubble)


func unregister(bubble: RigidBody3D) -> void:
	_bubbles.erase(bubble)


func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server():
		return
	if _bubbles.size() < 2:
		return

	# Purge any freed bubbles (safety net if _exit_tree unregister was missed)
	var i := _bubbles.size() - 1
	while i >= 0:
		if not is_instance_valid(_bubbles[i]):
			_bubbles.remove_at(i)
		i -= 1

	if _bubbles.size() < 2:
		return

	_rebuild_grid()
	_apply_separation_forces()


# ======================================================================
#  Spatial hash grid
# ======================================================================

func _cell_coords(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / CELL_SIZE),
		floori(pos.y / CELL_SIZE),
		floori(pos.z / CELL_SIZE)
	)


func _hash_cell(cx: int, cy: int, cz: int) -> int:
	return cx * HASH_P1 ^ cy * HASH_P2 ^ cz * HASH_P3


func _rebuild_grid() -> void:
	_grid.clear()
	for bubble in _bubbles:
		var cell := _cell_coords(bubble.global_position)
		var h := _hash_cell(cell.x, cell.y, cell.z)
		if _grid.has(h):
			_grid[h].append(bubble)
		else:
			_grid[h] = [bubble]


func _apply_separation_forces() -> void:
	# Process each pair exactly once using instance ID ordering.
	# For each bubble, check its 3x3x3 cell neighborhood. Only process
	# the pair if this bubble's ID is smaller (avoids double-counting).
	for bubble in _bubbles:
		var pos := bubble.global_position
		var center := _cell_coords(pos)
		var my_id := bubble.get_instance_id()

		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var h := _hash_cell(center.x + dx, center.y + dy, center.z + dz)
					if not _grid.has(h):
						continue
					for raw_other in _grid[h]:
						var other: RigidBody3D = raw_other as RigidBody3D
						# Only process each pair once: lower ID pushes both
						if other.get_instance_id() <= my_id:
							continue

						var other_pos: Vector3 = other.global_position
						var diff: Vector3 = pos - other_pos
						var dist_sq: float = diff.length_squared()

						if dist_sq >= SEP_RADIUS_SQ or dist_sq < 0.0001:
							continue

						var dist: float = sqrt(dist_sq)
						var direction: Vector3 = diff / dist
						# Linear falloff: full force at overlap, zero at separation edge
						var overlap: float = 1.0 - (dist / SEPARATION_RADIUS)
						var force: Vector3 = direction * PUSH_STRENGTH * overlap

						bubble.apply_central_force(force)
						other.apply_central_force(-force)
