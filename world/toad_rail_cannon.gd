extends Node3D

## Debug toad rail cannon — fires toad_body.tscn instances at high speed
## across a gap between two platforms. Server-authoritative: only the server
## spawns toad projectiles. Clients see the toads via normal replication
## (add_child on server → MultiplayerSynchronizer replicates transforms).
##
## Placed by blockout_map.gd near the host player for debugging purposes.

const TOAD_SPEED: float = 20.0        ## Toad launch speed (m/s)
const FIRE_INTERVAL: float = 0.4      ## Seconds between shots
const TOAD_SCALE: float = 0.35        ## Collision radius / visual scale

var _toad_body_scene: PackedScene = null
var _fire_timer: float = 0.0
var _fire_direction: Vector3 = Vector3.FORWARD  ## Set by spawner
var _toads_container: Node3D = null


func _ready() -> void:
	_toad_body_scene = load("res://world/toad_body.tscn")

	# Container for fired toads (keeps scene tree tidy)
	_toads_container = Node3D.new()
	_toads_container.name = "FiredToads"
	add_child(_toads_container)


func set_fire_direction(dir: Vector3) -> void:
	_fire_direction = dir.normalized()


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	_fire_timer -= delta
	if _fire_timer > 0.0:
		return
	_fire_timer = FIRE_INTERVAL

	_fire_toad()


func _fire_toad() -> void:
	if _toad_body_scene == null:
		return

	var toad: RigidBody3D = _toad_body_scene.instantiate()

	# Set collision shape radius
	var col_shape: CollisionShape3D = toad.get_node("CollisionShape3D")
	if col_shape and col_shape.shape is SphereShape3D:
		col_shape.shape = col_shape.shape.duplicate()
		col_shape.shape.radius = TOAD_SCALE

	# Scale body mesh
	var body_mesh: MeshInstance3D = toad.get_node("Body")
	if body_mesh:
		body_mesh.scale = Vector3(TOAD_SCALE, TOAD_SCALE * 0.65, TOAD_SCALE)

	# Position eyes
	_setup_toad_eyes(toad, TOAD_SCALE)

	# Set floor_y for despawn detection (generous buffer below cannon)
	toad._floor_y = global_position.y - 50.0

	# Override gravity — we want the toad to fly in a straight line (rail cannon)
	toad.gravity_scale = 0.0

	# Add to scene tree FIRST, then set world-space properties.
	# Setting global_position before add_child would be interpreted as local
	# position relative to the container, causing a double-offset.
	_toads_container.add_child(toad)

	# Now that the toad is in the tree, set its world-space position
	toad.global_position = global_position + Vector3(0, 2.5, 0)

	# Set velocity after entering the tree so Jolt picks it up
	toad.linear_velocity = _fire_direction * TOAD_SPEED

	# Random tumble for visual flair
	toad.angular_velocity = Vector3(
		randf_range(-6, 6), randf_range(-6, 6), randf_range(-6, 6)
	)


func _setup_toad_eyes(toad: RigidBody3D, radius: float) -> void:
	## Position and scale eye + pupil meshes relative to body size.
	## Copied from toad_dimension.gd pattern.
	var eye_offset: float = radius * 0.55
	var eye_size: float = radius * 0.25
	var pupil_size: float = eye_size * 0.45

	var eye_l: MeshInstance3D = toad.get_node_or_null("EyeL")
	var eye_r: MeshInstance3D = toad.get_node_or_null("EyeR")
	var pupil_l: MeshInstance3D = toad.get_node_or_null("PupilL")
	var pupil_r: MeshInstance3D = toad.get_node_or_null("PupilR")

	if eye_l:
		eye_l.scale = Vector3(eye_size, eye_size * 0.75, eye_size)
		eye_l.position = Vector3(eye_offset * 0.7, radius * 0.5, -radius * 0.6)
	if eye_r:
		eye_r.scale = Vector3(eye_size, eye_size * 0.75, eye_size)
		eye_r.position = Vector3(-eye_offset * 0.7, radius * 0.5, -radius * 0.6)

	var pupil_z_offset: float = -eye_size * 0.4
	if pupil_l:
		pupil_l.scale = Vector3(pupil_size, pupil_size * 0.78, pupil_size)
		pupil_l.position = Vector3(eye_offset * 0.7, radius * 0.5, -radius * 0.6 + pupil_z_offset)
	if pupil_r:
		pupil_r.scale = Vector3(pupil_size, pupil_size * 0.78, pupil_size)
		pupil_r.position = Vector3(-eye_offset * 0.7, radius * 0.5, -radius * 0.6 + pupil_z_offset)
