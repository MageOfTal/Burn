extends Node3D

## Debug toad bowl — a circular arena near the host spawn filled with
## persistent toads, for physics playtesting ("swimming in toads").
##
## v2 (2026-07-02): the old bowl was a zero-thickness inward-facing trimesh
## hemisphere with backface_collision, floating 8 m in the air — thin-shell
## geometry that tunnels and has no exterior. This version is built ONLY from
## solid convex pieces (cylinder floor + box wall panels), so collision is
## bulletproof and exactly matches the visuals. It sits ON the terrain
## (sampled at build time, never buried), and a walkable ramp leads from the
## ground through a doorway in the wall ring: walk up, step over a low
## threshold, drop into the toads. Jump back out the same way.
##
## Local frame: node origin at the base center (terrain height). Floor slab
## occupies local Y 0..1; the arena floor you stand on is local Y = 1.

const BOWL_RADIUS: float = 8.0      ## Wall ring radius
const WALL_PANELS: int = 20         ## Panels in the ring (one skipped = doorway)
const WALL_HEIGHT: float = 3.5      ## Panel height above the arena floor
const WALL_THICKNESS: float = 0.6
const FLOOR_THICKNESS: float = 1.0
const THRESHOLD_HEIGHT: float = 1.2 ## Doorway lip above the arena floor (jumpable)
const RAMP_ANGLE_DEG: float = 24.0  ## Walkable (< 50° max slope, gentle)
const RAMP_WIDTH: float = 3.2

const TOAD_COUNT: int = 60
const TOAD_SCALE: float = 0.35
const SPAWN_HEIGHT: float = 3.0     ## Local Y for toad spawn (above floor at Y=1)
const _ToadBody := preload("res://world/toad_body.gd")

var _toad_body_scene: PackedScene = null
var _toads_container: Node3D = null


func _ready() -> void:
	_toad_body_scene = load("res://world/toad_body.tscn")


func build(base_center: Vector3, height_sampler: Node = null) -> void:
	## Build the arena and spawn toads. base_center.y should be the terrain
	## height at the center; if height_sampler (SeedWorld) is provided, the
	## base is raised to the highest terrain point under the footprint so no
	## piece is buried, and the ramp foot is seated on the actual ground.
	var base_y: float = base_center.y
	var ramp_foot_ground_y: float = base_center.y
	if height_sampler != null and height_sampler.has_method("get_height_from_noise"):
		# Highest terrain under the bowl footprint → nothing sinks into a bump.
		for i in 8:
			var a: float = TAU * i / 8.0
			var h: float = height_sampler.get_height_from_noise(
				base_center.x + cos(a) * BOWL_RADIUS, base_center.z + sin(a) * BOWL_RADIUS)
			base_y = maxf(base_y, h)
		base_y = maxf(base_y, height_sampler.get_height_from_noise(base_center.x, base_center.z))
		base_y += 0.05

	global_position = Vector3(base_center.x, base_y, base_center.z)

	var floor_top: float = FLOOR_THICKNESS  # local Y of the arena floor

	# ── Floor: one solid cylinder slab ──────────────────────────────────
	var bowl_mat := StandardMaterial3D.new()
	bowl_mat.albedo_color = Color(0.2, 0.5, 0.15)
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.25, 0.42, 0.2)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.4, 0.3, 0.2)

	var floor_shape := CylinderShape3D.new()
	floor_shape.radius = BOWL_RADIUS + WALL_THICKNESS
	floor_shape.height = FLOOR_THICKNESS
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = floor_shape.radius
	floor_mesh.bottom_radius = floor_shape.radius
	floor_mesh.height = FLOOR_THICKNESS
	_add_static_piece("Floor", floor_shape, floor_mesh, Vector3(0, FLOOR_THICKNESS * 0.5, 0), Vector3.ZERO, bowl_mat)

	# ── Wall ring: solid box panels, one gap as the doorway (+Z side) ───
	# Panel width slightly over the arc length so neighbors overlap (no slits).
	var arc: float = TAU / WALL_PANELS
	var panel_w: float = BOWL_RADIUS * arc * 1.18
	var doorway_index: int = WALL_PANELS / 4  # angle ≈ +90° → +Z direction
	for i in WALL_PANELS:
		if i == doorway_index:
			continue
		var a: float = arc * i  # panel WALL_PANELS/4 centers exactly at +Z
		var pos := Vector3(cos(a) * BOWL_RADIUS, floor_top + WALL_HEIGHT * 0.5, sin(a) * BOWL_RADIUS)
		var shape := BoxShape3D.new()
		shape.size = Vector3(panel_w, WALL_HEIGHT, WALL_THICKNESS)
		var mesh := BoxMesh.new()
		mesh.size = shape.size
		# Rotate so the panel's thickness axis (Z) points at the ring center.
		var yaw: float = -a + PI * 0.5
		_add_static_piece("Wall%d" % i, shape, mesh, pos, Vector3(0, yaw, 0), wall_mat)

	# ── Doorway threshold: low lip the player steps over, toads mostly not ─
	var door_a: float = arc * doorway_index
	var door_dir := Vector3(cos(door_a), 0, sin(door_a))  # ≈ +Z
	var thr_shape := BoxShape3D.new()
	thr_shape.size = Vector3(panel_w, THRESHOLD_HEIGHT, WALL_THICKNESS)
	var thr_mesh := BoxMesh.new()
	thr_mesh.size = thr_shape.size
	_add_static_piece("Threshold", thr_shape, thr_mesh,
			door_dir * BOWL_RADIUS + Vector3(0, floor_top + THRESHOLD_HEIGHT * 0.5, 0),
			Vector3(0, -door_a + PI * 0.5, 0), wall_mat)

	# ── Landing: flat platform at threshold-top height, straddling the wall ─
	var lip_y: float = floor_top + THRESHOLD_HEIGHT  # local Y of the walk-over surface
	var landing_shape := BoxShape3D.new()
	landing_shape.size = Vector3(RAMP_WIDTH, 0.4, 2.6)
	var landing_mesh := BoxMesh.new()
	landing_mesh.size = landing_shape.size
	var landing_center := door_dir * (BOWL_RADIUS + 0.7) + Vector3(0, lip_y - 0.2, 0)
	_add_static_piece("Landing", landing_shape, landing_mesh, landing_center,
			Vector3(0, -door_a + PI * 0.5, 0), ramp_mat)

	# ── Ramp: ground → landing outer edge, at a gentle walkable angle ───
	var ramp_angle: float = deg_to_rad(RAMP_ANGLE_DEG)
	var landing_outer := door_dir * (BOWL_RADIUS + 2.0) + Vector3(0, lip_y, 0)
	# Seat the ramp foot on the real terrain out along the door direction.
	var ground_foot_y: float = global_position.y
	if height_sampler != null and height_sampler.has_method("get_height_from_noise"):
		var est_run: float = (lip_y + 2.0) / tan(ramp_angle)
		var foot_probe: Vector3 = global_position + door_dir * (BOWL_RADIUS + 2.0 + est_run)
		ground_foot_y = height_sampler.get_height_from_noise(foot_probe.x, foot_probe.z)
	var rise: float = (global_position.y + lip_y) - ground_foot_y
	rise = maxf(rise, 1.0)
	var ramp_len: float = rise / sin(ramp_angle) + 1.0
	var ramp_thickness: float = 0.6
	var half := ramp_len * 0.5
	var ramp_center := landing_outer + door_dir * (cos(ramp_angle) * half) \
			+ Vector3(0, -sin(ramp_angle) * half - ramp_thickness * 0.4, 0)
	var ramp_shape := BoxShape3D.new()
	ramp_shape.size = Vector3(RAMP_WIDTH, ramp_thickness, ramp_len)
	var ramp_mesh := BoxMesh.new()
	ramp_mesh.size = ramp_shape.size
	# Tilt about the axis perpendicular to door_dir: local +Z (pointing away
	# from the bowl, along door_dir after yaw) drops toward the ground.
	_add_static_piece("Ramp", ramp_shape, ramp_mesh, ramp_center,
			Vector3(ramp_angle, -door_a + PI * 0.5, 0), ramp_mat)

	# ── Label ────────────────────────────────────────────────────────────
	var label := Label3D.new()
	label.text = "TOAD BOWL"
	label.font_size = 48
	label.modulate = Color(0.2, 0.8, 0.2)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, floor_top + WALL_HEIGHT + 2.0, 0)
	add_child(label)

	# ── Toads ────────────────────────────────────────────────────────────
	_toads_container = Node3D.new()
	_toads_container.name = "BowlToads"
	add_child(_toads_container)
	if multiplayer.is_server():
		_spawn_toads()

	print("[ToadBowl] Built solid arena at %s (base_y=%.2f, %d toads, doorway toward %s)" % [
		global_position, base_y, TOAD_COUNT, door_dir])


func _add_static_piece(piece_name: String, shape: Shape3D, mesh: Mesh, pos: Vector3, rot: Vector3, mat: Material) -> void:
	## One solid StaticBody3D whose collision and visual are the same primitive.
	var body := StaticBody3D.new()
	body.name = piece_name
	body.collision_layer = CollisionLayers.WORLD
	body.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	body.position = pos
	body.rotation = rot
	add_child(body)


func _spawn_toads() -> void:
	## Spawn persistent toads that never leave Jolt physics.
	if _toad_body_scene == null:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345  # Deterministic for consistency

	for i in TOAD_COUNT:
		var toad: RigidBody3D = _toad_body_scene.instantiate()

		# Replace collision with sphere matching the visual radius
		var col_shape: CollisionShape3D = toad.get_node("CollisionShape3D")
		if col_shape:
			col_shape.shape = _ToadBody.create_ellipsoid_shape(TOAD_SCALE, TOAD_SCALE * _ToadBody.ELLIPSOID_Y_RATIO)

		# Scale body mesh
		var body_mesh: MeshInstance3D = toad.get_node("Body")
		if body_mesh:
			body_mesh.scale = Vector3(TOAD_SCALE, TOAD_SCALE * 0.65, TOAD_SCALE)

		# Position eyes
		_setup_toad_eyes(toad, TOAD_SCALE)

		# Make persistent: never disable physics after bounce, never despawn.
		toad.persistent = true
		toad._floor_y = -9999.0

		# Persistent toads collide with each other (add layer 7 to mask)
		toad.collision_mask = CollisionLayers.PHYSICS_PUSH | CollisionLayers.TOAD_RAIN

		# Higher bounce so they stay lively in the bowl
		var phys_mat := PhysicsMaterial.new()
		phys_mat.bounce = 0.3
		phys_mat.friction = 0.3
		toad.physics_material_override = phys_mat

		# Spread toads inside the bowl above the floor
		var angle: float = TAU * i / TOAD_COUNT
		var dist: float = rng.randf_range(0.5, BOWL_RADIUS * 0.6)
		var spawn_pos := Vector3(
			cos(angle) * dist,
			SPAWN_HEIGHT + rng.randf_range(0.0, 1.5),
			sin(angle) * dist
		)

		# Add to container first, then set position
		_toads_container.add_child(toad)
		toad.position = spawn_pos

		# Give each toad a random initial velocity so they bounce around
		toad.linear_velocity = Vector3(
			rng.randf_range(-3, 3),
			rng.randf_range(-1, 2),
			rng.randf_range(-3, 3)
		)
		toad.angular_velocity = Vector3(
			rng.randf_range(-4, 4),
			rng.randf_range(-4, 4),
			rng.randf_range(-4, 4)
		)


func _setup_toad_eyes(toad: RigidBody3D, radius: float) -> void:
	## Position and scale eye + pupil meshes relative to body size.
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
