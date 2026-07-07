extends Node3D

## Permtoad Rain — continuously rains persistent toad-bowl-style toads above
## ground for testing physics interactions (mass-ratio stabilization, etc.).
##
## Toads match the toad bowl exactly: CylinderShape3D collision, squished body,
## eyes, toad-to-toad collision, high bounce. They never despawn or freeze.

const TOAD_SCENE: PackedScene = preload("res://world/toad_body.tscn")
const _ToadBody := preload("res://world/toad_body.gd")
const TOAD_SCALE: float = 0.35         ## Collision radius (matches toad bowl)

## Offset from host player position to place the rain center.
## Toad bowl is at (+0, +8, +15). This places rain beside it.
@export var host_offset: Vector3 = Vector3(12.0, 0.0, 15.0)

## Height above ground to spawn toads.
@export var spawn_height: float = 50.0

## Radius of the circular rain area.
@export var spawn_radius: float = 4.0

## Toads spawned per tick.
@export var toads_per_tick: int = 2

## Seconds between spawn ticks.
@export var spawn_interval: float = 0.2

## Maximum live toads before stopping spawning.
@export var max_toads: int = 150

var _timer: float = 0.0
var _container: Node3D = null
var _spawn_center: Vector3 = Vector3.ZERO
var _started: bool = false


func _ready() -> void:
	if not multiplayer.is_server():
		return
	_container = Node3D.new()
	_container.name = "PermtoadContainer"
	add_child(_container)


func _find_host_and_start() -> void:
	## Find host player position and lock in the spawn center.
	var players_node := get_parent().get_node_or_null("Players")
	if players_node == null:
		return
	var host_player: Node3D = players_node.get_node_or_null("1")
	if host_player == null:
		return
	_spawn_center = host_player.global_position + host_offset
	_started = true
	print("[PermtoadRain] Started — center=%s radius=%.1f height=%.1f max=%d" % [
		str(_spawn_center), spawn_radius, spawn_height, max_toads])
	_spawn_test_discs(host_player.global_position)


func _physics_process(delta: float) -> void:
	Profiler.begin("toad_rain")
	if not multiplayer.is_server():
		Profiler.end("toad_rain")
		return
	if _container == null:
		Profiler.end("toad_rain")
		return

	if not _started:
		_find_host_and_start()
		Profiler.end("toad_rain")
		return

	_timer -= delta
	if _timer > 0.0:
		Profiler.end("toad_rain")
		return
	_timer = spawn_interval

	if _container.get_child_count() >= max_toads:
		Profiler.end("toad_rain")
		return

	for _i in range(toads_per_tick):
		if _container.get_child_count() >= max_toads:
			break
		_spawn_permtoad()
	Profiler.end("toad_rain")


func _spawn_permtoad() -> void:
	var toad: RigidBody3D = TOAD_SCENE.instantiate()

	# --- Match toad bowl collision setup exactly ---

	# Replace default sphere collision with sphere matching visual radius
	var col_shape: CollisionShape3D = toad.get_node("CollisionShape3D")
	if col_shape:
		col_shape.shape = _ToadBody.create_ellipsoid_shape(TOAD_SCALE, TOAD_SCALE * _ToadBody.ELLIPSOID_Y_RATIO)

	# Scale body mesh to squished toad shape
	var body_mesh: MeshInstance3D = toad.get_node_or_null("Body")
	if body_mesh:
		body_mesh.scale = Vector3(TOAD_SCALE, TOAD_SCALE * 0.65, TOAD_SCALE)

	# Position eyes to match toad bowl
	_setup_toad_eyes(toad, TOAD_SCALE)

	# Persistent: never disable physics after bounce, never despawn
	toad.persistent = true
	toad._floor_y = -9999.0

	# Toad-to-toad collision (add layer 7 to mask)
	toad.collision_mask = CollisionLayers.WORLD | CollisionLayers.PLAYERS_PUSH | CollisionLayers.TOAD_RAIN  # world (1) + player push (512) + toad bodies (64)

	# Higher bounce to stay lively (matches toad bowl)
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.3
	phys_mat.friction = 0.3
	toad.physics_material_override = phys_mat

	# Random position in tight circle
	var angle := randf() * TAU
	var dist := spawn_radius * sqrt(randf())
	var pos := _spawn_center + Vector3(
		cos(angle) * dist,
		spawn_height + randf_range(-1.0, 1.0),
		sin(angle) * dist
	)
	toad.position = pos

	# Small random tumble
	toad.angular_velocity = Vector3(
		randf_range(-4.0, 4.0),
		randf_range(-4.0, 4.0),
		randf_range(-4.0, 4.0)
	)

	_container.add_child(toad)


func _setup_toad_eyes(toad: RigidBody3D, radius: float) -> void:
	## Position and scale eye + pupil meshes relative to body size.
	## Copied from toad_bowl.gd for exact match.
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


func _spawn_test_discs(host_pos: Vector3) -> void:
	## Spawn a row of frozen toads on the ground with the OLD cylinder hitbox
	## so the user can compare cylinder vs squished-sphere collision feel.
	const DISC_COUNT := 5
	const SPACING := 2.0
	var start_pos := host_pos + Vector3(6.0, 0.5, 0.0)  # Offset from host

	for i in DISC_COUNT:
		var toad: RigidBody3D = TOAD_SCENE.instantiate()

		# Old cylinder collision (the one we're replacing)
		var col_shape: CollisionShape3D = toad.get_node("CollisionShape3D")
		if col_shape:
			var disc := CylinderShape3D.new()
			disc.radius = TOAD_SCALE
			disc.height = TOAD_SCALE * 0.65 * 1.3
			col_shape.shape = disc

		# Same visual as permatoads
		var body_mesh: MeshInstance3D = toad.get_node_or_null("Body")
		if body_mesh:
			body_mesh.scale = Vector3(TOAD_SCALE, TOAD_SCALE * 0.65, TOAD_SCALE)

		_setup_toad_eyes(toad, TOAD_SCALE)

		toad.persistent = true
		toad._floor_y = -9999.0
		toad.collision_mask = CollisionLayers.WORLD | CollisionLayers.PLAYERS_PUSH | CollisionLayers.TOAD_RAIN  # world + player push + toad bodies

		var phys_mat := PhysicsMaterial.new()
		phys_mat.bounce = 0.3
		phys_mat.friction = 0.3
		toad.physics_material_override = phys_mat

		var pos := start_pos + Vector3(i * SPACING, 0.0, 0.0)
		_container.add_child(toad)
		toad.global_position = pos

	print("[PermtoadRain] Spawned %d test CYLINDER discs at %s" % [DISC_COUNT, str(start_pos)])
