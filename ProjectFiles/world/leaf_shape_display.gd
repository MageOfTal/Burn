extends Node3D
## DEBUG diorama: shows the grapple leaf go-around shell at true proportions.
##
## A platform with a horizontal "rope" strung between two posts, an obstacle
## marker at the bend point, and the full leaf shell built from the SAME
## constants and fan-tile math as GrappleSystem's obstruction check:
##   - Solid tiles = exactly what physics queries (safe-margin trim included).
##   - White wireframe = the ideal untrimmed leaf, so the pointy tips show.
##   - Green = left side fan, yellow = right side fan; dimmer = narrower
##     width iterations.
## Two copies: true scale, and one with widths exaggerated for readability.

const ROPE_LEN := 8.0            ## Display rope length (m)
const BEND_T := 0.5              ## Obstacle position along the rope (0-1)
const ROPE_HEIGHT := 2.2         ## Rope height above the platform
const WIDTH_EXAGGERATION := 6.0  ## Width multiplier for the second display

const PLATFORM_SIZE := Vector3(12.0, 0.5, 10.0)
const PEDESTAL_DEPTH := 6.0      ## Pedestal extends down into terrain slopes


func _ready() -> void:
	_build_platform()
	_build_display(Vector3(0.0, PLATFORM_SIZE.y + ROPE_HEIGHT, 2.5), 1.0,
		"LEAF SHELL — TRUE SCALE")
	_build_display(Vector3(0.0, PLATFORM_SIZE.y + ROPE_HEIGHT, -2.5), WIDTH_EXAGGERATION,
		"LEAF SHELL — WIDTH x%.0f" % WIDTH_EXAGGERATION)


func _build_platform() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(PLATFORM_SIZE.x, PLATFORM_SIZE.y + PEDESTAL_DEPTH, PLATFORM_SIZE.z)
	shape.shape = box
	shape.position = Vector3(0.0, PLATFORM_SIZE.y - box.size.y * 0.5, 0.0)
	body.add_child(shape)

	var mesh := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = box.size
	mesh.mesh = box_mesh
	mesh.position = shape.position
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.35, 0.4)
	mesh.material_override = mat
	body.add_child(mesh)


func _build_display(origin: Vector3, width_scale: float, title: String) -> void:
	## Build one leaf-shell diorama.  Rope runs along local X through origin.
	var chest: Vector3 = origin + Vector3(-ROPE_LEN * 0.5, 0.0, 0.0)
	var anchor: Vector3 = origin + Vector3(ROPE_LEN * 0.5, 0.0, 0.0)
	var rope_dir := Vector3(1.0, 0.0, 0.0)
	var swing_normal := Vector3(0.0, 0.0, 1.0)
	var z_axis: Vector3 = rope_dir.cross(swing_normal).normalized()
	var bend_base: Vector3 = chest + rope_dir * (ROPE_LEN * BEND_T)

	# --- Posts under the rope ends ---
	for end_pos: Vector3 in [chest, anchor]:
		var post := MeshInstance3D.new()
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.2, ROPE_HEIGHT, 0.2)
		post.mesh = post_mesh
		post.position = Vector3(end_pos.x, PLATFORM_SIZE.y + ROPE_HEIGHT * 0.5, end_pos.z)
		var post_mat := StandardMaterial3D.new()
		post_mat.albedo_color = Color(0.5, 0.45, 0.35)
		post.material_override = post_mat
		add_child(post)

	# --- Obstacle marker at the bend point ---
	var obstacle := MeshInstance3D.new()
	var obs_mesh := BoxMesh.new()
	obs_mesh.size = Vector3(0.15, 0.15, 0.15)
	obstacle.mesh = obs_mesh
	obstacle.position = bend_base
	var obs_mat := StandardMaterial3D.new()
	obs_mat.albedo_color = Color(1.0, 0.2, 0.15)
	obs_mat.emission_enabled = true
	obs_mat.emission = Color(1.0, 0.2, 0.15)
	obstacle.material_override = obs_mat
	add_child(obstacle)

	# --- Title label ---
	var label := Label3D.new()
	label.text = title
	label.font_size = 48
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = origin + Vector3(0.0, 1.2, 0.0)
	add_child(label)

	# --- Leaf shell mesh ---
	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = im
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)

	var rope_mat := _make_mat(Color(0.3, 0.6, 1.0, 1.0))
	var ghost_mat := _make_mat(Color(1.0, 1.0, 1.0, 0.25))
	var side_mats: Array[StandardMaterial3D] = [
		_make_mat(Color(0.1, 1.0, 0.2, 0.3)),   # left, full width
		_make_mat(Color(1.0, 1.0, 0.1, 0.3)),   # right, full width
		_make_mat(Color(0.1, 1.0, 0.2, 0.1)),   # left, narrower
		_make_mat(Color(1.0, 1.0, 0.1, 0.1)),   # right, narrower
	]

	# Straight rope line
	im.surface_begin(Mesh.PRIMITIVE_LINES, rope_mat)
	im.surface_add_vertex(chest)
	im.surface_add_vertex(anchor)
	im.surface_end()

	# Both sides, all width iterations — same math as GrappleSystem
	for side_idx in 2:
		var side_dir: Vector3 = swing_normal if side_idx == 0 else -swing_normal
		for frac: float in GrappleSystem.LEAF_WIDTH_FRACTIONS:
			var w: float = GrappleSystem.LEAF_MAX_WIDTH * frac * width_scale
			var arc := PackedVector3Array()
			for k in GrappleSystem.LEAF_ARC_POINTS:
				var theta: float = -PI * 0.5 + PI * float(k) / float(GrappleSystem.LEAF_ARC_POINTS - 1)
				var dir: Vector3 = side_dir * cos(theta) + z_axis * sin(theta)
				arc.append(bend_base + dir * w)

			var narrow: bool = frac < 1.0
			var mat: StandardMaterial3D = side_mats[side_idx + (2 if narrow else 0)]

			# Solid tiles — exactly the trimmed prisms physics queries
			for apex_idx in 2:
				var apex: Vector3 = chest if apex_idx == 0 else anchor
				for k in arc.size() - 1:
					var corners := _fan_tile_corners(apex, arc[k], arc[k + 1])
					if corners.is_empty():
						continue
					im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, mat)
					im.surface_add_vertex(corners[0])
					im.surface_add_vertex(corners[1])
					im.surface_add_vertex(corners[3])
					im.surface_add_vertex(corners[2])
					im.surface_end()

			# Ghost wireframe — untrimmed ideal leaf (full width only)
			if not narrow:
				for k in arc.size():
					im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, ghost_mat)
					im.surface_add_vertex(chest)
					im.surface_add_vertex(arc[k])
					im.surface_add_vertex(anchor)
					im.surface_end()
				im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, ghost_mat)
				for k in arc.size():
					im.surface_add_vertex(arc[k])
				im.surface_end()


func _fan_tile_corners(apex: Vector3, p0: Vector3, p1: Vector3) -> PackedVector3Array:
	## Mirror of GrappleSystem._fan_tile_corners — kept in sync so the
	## diorama shows exactly what physics queries.
	var len0: float = apex.distance_to(p0)
	var len1: float = apex.distance_to(p1)
	if len0 < 0.05 or len1 < 0.05:
		return PackedVector3Array()
	var trim: float = minf(GrappleSystem.ROPE_LOS_MARGIN, minf(len0, len1) * 0.45)
	var q0: Vector3 = apex.lerp(p0, trim / len0)
	var q1: Vector3 = apex.lerp(p1, trim / len1)
	return PackedVector3Array([q0, q1, p1, p0])


func _make_mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
