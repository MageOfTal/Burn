extends Node3D

## Debug toad bowl — a concave hemisphere near the host player filled with 60
## persistent toads that bounce around forever, never despawning.
## Used to test player push physics without needing the toad dimension.
##
## The bowl is an actual semi-sphere built from rings of angled collision panels
## that approximate a smooth concave interior. Toads bounce off the curved walls
## and stay contained. A ramp leads up to the rim so the player can walk in.

const BOWL_RADIUS: float = 8.0      ## Radius of the hemisphere
const RING_COUNT: int = 6           ## Latitude rings from bottom pole to equator (rim)
const SEGMENTS_PER_RING: int = 24   ## Panels around each ring
const PANEL_THICKNESS: float = 0.4  ## Collision panel thickness
const TOAD_COUNT: int = 60          ## Number of persistent toads
const TOAD_SCALE: float = 0.35      ## Collision radius
const _ToadBody := preload("res://world/toad_body.gd")
const SPAWN_HEIGHT: float = 4.0     ## How high above the bowl bottom to spawn toads

var _toad_body_scene: PackedScene = null
var _toads_container: Node3D = null


func _ready() -> void:
	_toad_body_scene = load("res://world/toad_body.tscn")


func build(center: Vector3) -> void:
	## Build the bowl geometry and spawn toads. Call after adding to the tree.
	## The bowl center is at the bottom of the hemisphere (the pole).
	## The rim (equator) is at local Y = BOWL_RADIUS.
	global_position = center

	_build_hemisphere()
	_build_ramp()

	# Container for the toads
	_toads_container = Node3D.new()
	_toads_container.name = "BowlToads"
	add_child(_toads_container)

	# Label above the rim
	var label := Label3D.new()
	label.text = "TOAD BOWL"
	label.font_size = 48
	label.modulate = Color(0.2, 0.8, 0.2)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, BOWL_RADIUS + 2.0, 0)
	add_child(label)

	# Spawn toads (server only)
	if multiplayer.is_server():
		_spawn_toads()

	print("[ToadBowl] Built hemisphere at %s with %d toads (radius=%.0f)" % [
		center, TOAD_COUNT, BOWL_RADIUS])


func _build_hemisphere() -> void:
	## Build a concave hemisphere from rings of box collision panels (invisible)
	## with a single smooth SphereMesh visual on top.
	##
	## Each ring is at a latitude angle from 0 (bottom pole) to PI/2 (equator/rim).
	## Panels are positioned on the sphere surface and angled to face inward.
	## The collision panels approximate the smooth concave interior.
	##
	## Coordinate system: bowl center (bottom pole) is at local origin (0,0,0).
	## The hemisphere opens upward. A point on the sphere at latitude phi and
	## longitude theta is:
	##   x = R * sin(phi) * cos(theta)
	##   z = R * sin(phi) * sin(theta)
	##   y = R * (1 - cos(phi))     [shifted so bottom pole is at Y=0]

	# --- Smooth visual mesh: procedural hemisphere (inside faces only) ---
	var bowl_mat := StandardMaterial3D.new()
	bowl_mat.albedo_color = Color(0.2, 0.5, 0.15)  # Earthy green

	var visual := MeshInstance3D.new()
	visual.name = "BowlVisual"
	visual.mesh = _create_hemisphere_mesh(BOWL_RADIUS, 48, 16)
	visual.material_override = bowl_mat
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)

	# --- Invisible collision panels (same as before, but no visual meshes) ---
	for ring_i in RING_COUNT:
		var phi: float = (float(ring_i) + 1.0) / float(RING_COUNT) * (PI / 2.0)
		var phi_next: float = (float(ring_i) + 2.0) / float(RING_COUNT) * (PI / 2.0)
		if ring_i == RING_COUNT - 1:
			phi_next = PI / 2.0  # Stop exactly at the equator — no overshoot, open top

		var ring_r: float = BOWL_RADIUS * sin(phi)
		var ring_y: float = BOWL_RADIUS * (1.0 - cos(phi))
		var arc_len: float = BOWL_RADIUS * (phi_next - phi)
		var tilt_angle: float = phi

		var segs: int = maxi(8, SEGMENTS_PER_RING)
		var panel_width: float = 2.0 * ring_r * sin(PI / segs)

		for seg_i in segs:
			var mid_theta: float = TAU * (seg_i + 0.5) / segs

			var px: float = cos(mid_theta) * ring_r
			var pz: float = sin(mid_theta) * ring_r
			var py: float = ring_y

			var body := StaticBody3D.new()
			body.collision_layer = CollisionLayers.WORLD
			body.collision_mask = 0

			var col := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(panel_width, arc_len, PANEL_THICKNESS)
			col.shape = shape
			body.add_child(col)

			body.position = Vector3(px, py, pz)
			body.rotation.y = -mid_theta
			body.rotation.x = -(PI / 2.0 - tilt_angle)

			add_child(body)


func _build_ramp() -> void:
	## Ramp from the ground up to the bowl rim so the player can walk in.
	## The bowl bottom pole is at local (0,0,0). The rim is at Y = BOWL_RADIUS.
	## The bowl is placed 8m above terrain, so ground is at local Y = -8.
	## The ramp approaches from outside in the +Z direction, sloping up to the rim.
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.4, 0.3, 0.2)

	var rim_y: float = BOWL_RADIUS
	var ground_y: float = -8.0  # Bowl is placed 8m above terrain
	var rise: float = rim_y - ground_y  # 16m total rise
	var run: float = 24.0  # Gentle slope
	var ramp_len: float = sqrt(rise * rise + run * run)
	var ramp_angle: float = atan2(rise, run)
	var ramp_width: float = 3.5
	var ramp_thickness: float = 0.3

	var body := StaticBody3D.new()
	body.collision_layer = CollisionLayers.WORLD
	body.collision_mask = 0
	body.name = "Ramp"

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(ramp_width, ramp_thickness, ramp_len + 2.0)
	col.shape = shape
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = shape.size
	mesh.mesh = box
	mesh.material_override = ramp_mat
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mesh)

	# rotation.x = +ramp_angle tilts local +Z toward -Y (downhill away from bowl).
	# Local -Z end = top (rim), local +Z end = bottom (ground).
	# Top end (-Z side) = center + half_len * (0, +sin(angle), -cos(angle)).
	# We want the top end at (0, rim_y, BOWL_RADIUS) — outer edge of the rim.
	var half_len: float = ramp_len / 2.0
	var dy: float = sin(ramp_angle) * half_len
	var dz: float = cos(ramp_angle) * half_len

	var center_y: float = rim_y - dy   # top at rim_y, bottom at ground_y
	var center_z: float = BOWL_RADIUS + dz  # top at +BOWL_RADIUS, bottom extends outward to +Z

	body.position = Vector3(0, center_y, center_z)
	body.rotation.x = ramp_angle  # +Z end tilts down (away from bowl), -Z end is the top

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
		phys_mat.bounce = 0.7
		phys_mat.friction = 0.3
		toad.physics_material_override = phys_mat

		# Spread toads inside the bowl above the bottom
		var angle: float = TAU * i / TOAD_COUNT
		var dist: float = rng.randf_range(0.5, BOWL_RADIUS * 0.5)
		var spawn_pos := Vector3(
			cos(angle) * dist,
			SPAWN_HEIGHT,
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


func _create_hemisphere_mesh(radius: float, lon_segments: int, lat_segments: int) -> ArrayMesh:
	## Build an ArrayMesh for the bottom hemisphere of a sphere (phi from 0 at the
	## bottom pole up to PI/2 at the equator/rim). Normals point INWARD so only the
	## concave interior renders (like looking into a bowl).
	##
	## Bowl coordinate system: bottom pole at local Y=0, rim at Y=radius.
	## Sphere center at Y=radius (standard sphere shifted up by radius).
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	# Generate vertices ring by ring from bottom pole (phi=PI, sphere bottom)
	# up to equator (phi=PI/2). In standard spherical coords where phi=0 is the
	# top pole, the bottom hemisphere is phi in [PI/2, PI].
	# But our bowl Y = radius * (1 - cos(bowl_phi)) where bowl_phi goes 0..PI/2.
	# Converting: sphere_phi = PI - bowl_phi, so bowl_phi=0 → sphere_phi=PI (bottom),
	# bowl_phi=PI/2 → sphere_phi=PI/2 (equator).
	for lat_i in range(lat_segments + 1):
		var bowl_phi: float = (float(lat_i) / float(lat_segments)) * (PI / 2.0)
		var ring_r: float = radius * sin(bowl_phi)
		var ring_y: float = radius * (1.0 - cos(bowl_phi))
		var v: float = float(lat_i) / float(lat_segments)

		for lon_i in range(lon_segments + 1):
			var theta: float = TAU * float(lon_i) / float(lon_segments)
			var u: float = float(lon_i) / float(lon_segments)

			var pos := Vector3(
				cos(theta) * ring_r,
				ring_y,
				sin(theta) * ring_r
			)
			# Normal pointing toward sphere center (inward) for concave rendering.
			# Sphere center is at (0, radius, 0). Inward normal = center - pos.
			var normal: Vector3 = (Vector3(0, radius, 0) - pos).normalized()

			verts.append(pos)
			normals.append(normal)
			uvs.append(Vector2(u, v))

	# Generate triangle indices — winding order reversed for inward-facing normals.
	# Standard winding is (a, b, c) for outward; we use (a, c, b) for inward.
	for lat_i in range(lat_segments):
		for lon_i in range(lon_segments):
			var a: int = lat_i * (lon_segments + 1) + lon_i
			var b: int = a + lon_segments + 1
			var c: int = a + 1
			var d: int = b + 1

			# Two triangles per quad, reversed winding
			indices.append(a)
			indices.append(d)
			indices.append(b)

			indices.append(a)
			indices.append(c)
			indices.append(d)

	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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
