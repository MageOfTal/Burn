extends Node3D

## Procedural terrain generator using value noise.
## Generates a heightmap mesh with collision, then scatters walls and ramps
## as structures on the surface. Also places player spawn points, loot spawns,
## and target dummies on the terrain.

@export var width: int = 225
@export var depth: int = 225
@export var slice_y: float = 64.0
@export var base_frequency: float = 1.0 / 16.0
@export var octaves: int = 5
@export var persistence: float = 0.5
@export var lacunarity: float = 2.0
@export var domain_warp_amp: float = 2.0
@export var domain_warp_freq: float = 1.0 / 128.0
@export var seed: int = 1029384756
@export var blend_func: String = "smoothstep"
@export var gain: float = INF
@export var bias: float = INF
@export var height_scale: float = 16.0
@export var cell_size: float = 1.0

## Structure generation
@export_group("Structures")
@export var num_walls: int = 25
@export var num_ramps: int = 15
@export var num_player_spawns: int = 8
@export var num_loot_spawns: int = 30
@export var num_dummies: int = 8
@export var structure_margin: float = 15.0  ## Keep structures this far from map edges

const INV_0X7FFFFFFF := 1.0 / 0x7fffffff

## Cached height field for surface queries
var _heights: PackedFloat32Array
var _terrain_ready := false


func _ready() -> void:
	_heights = _generate_height_field()
	var mesh := _build_heightmap_mesh(_heights)

	# --- Terrain visual ---
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = mesh

	var mat := StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_PER_PIXEL
	mat.albedo_color = Color(0.25, 0.65, 0.35)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)

	# --- Terrain collision ---
	var static_body := StaticBody3D.new()
	static_body.name = "TerrainBody"
	add_child(static_body)

	var col_shape := CollisionShape3D.new()
	var trimesh := ConcavePolygonShape3D.new()
	trimesh.set_faces(mesh.get_faces())
	col_shape.shape = trimesh
	static_body.add_child(col_shape)

	# --- Directional light ---
	if not get_parent().has_node("Sun"):
		var sun := DirectionalLight3D.new()
		sun.name = "Sun"
		sun.light_color = Color(1, 1, 0.95)
		sun.light_energy = 1.5
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = maxf(width, depth) * cell_size * 2.0
		sun.rotation_degrees = Vector3(-50, -45, 0)
		add_child(sun)

	_terrain_ready = true

	# --- Spawn structures and points ---
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var structures_node := Node3D.new()
	structures_node.name = "Structures"
	add_child(structures_node)

	_spawn_walls(rng, structures_node)
	_spawn_ramps(rng, structures_node)
	_spawn_player_spawns(rng)
	_spawn_loot_points(rng)
	_spawn_dummies(rng)


# ======================================================================
#  Height query
# ======================================================================

func get_height_at(world_x: float, world_z: float) -> float:
	## Returns the interpolated terrain height at the given world XZ position.
	var gx: float = world_x / cell_size
	var gz: float = world_z / cell_size
	var x0: int = int(floor(gx))
	var z0: int = int(floor(gz))
	var x1: int = x0 + 1
	var z1: int = z0 + 1

	x0 = clampi(x0, 0, width - 1)
	x1 = clampi(x1, 0, width - 1)
	z0 = clampi(z0, 0, depth - 1)
	z1 = clampi(z1, 0, depth - 1)

	var fx: float = gx - float(x0)
	var fz: float = gz - float(z0)

	var h00: float = _heights[z0 * width + x0]
	var h10: float = _heights[z0 * width + x1]
	var h01: float = _heights[z1 * width + x0]
	var h11: float = _heights[z1 * width + x1]

	var h0: float = h00 + fx * (h10 - h00)
	var h1: float = h01 + fx * (h11 - h01)
	return h0 + fz * (h1 - h0)


func get_normal_at(world_x: float, world_z: float) -> Vector3:
	## Returns the approximate surface normal at the given world XZ position.
	var eps := cell_size
	var hL := get_height_at(world_x - eps, world_z)
	var hR := get_height_at(world_x + eps, world_z)
	var hD := get_height_at(world_x, world_z - eps)
	var hU := get_height_at(world_x, world_z + eps)
	return Vector3(hL - hR, 2.0 * eps, hD - hU).normalized()


func _get_random_surface_pos(rng: RandomNumberGenerator) -> Vector3:
	## Pick a random XZ position within margins, return the surface point.
	var x := rng.randf_range(structure_margin, (width - 1) * cell_size - structure_margin)
	var z := rng.randf_range(structure_margin, (depth - 1) * cell_size - structure_margin)
	var y := get_height_at(x, z)
	return Vector3(x, y, z)


func _get_slope_at(world_x: float, world_z: float) -> float:
	## Returns the slope angle in degrees at the given position.
	var n := get_normal_at(world_x, world_z)
	return rad_to_deg(acos(n.dot(Vector3.UP)))


# ======================================================================
#  Structure spawning
# ======================================================================

func _spawn_walls(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn wall structures on the terrain surface.
	var wall_sizes := [
		Vector3(10, 4, 1),
		Vector3(8, 3, 1),
		Vector3(12, 5, 1),
		Vector3(6, 3, 1.5),
		Vector3(14, 4, 1),
	]
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.6, 0.55, 0.5, 1)

	for i in num_walls:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		# Skip very steep spots for walls
		if slope > 30.0:
			continue

		var wall_size: Vector3 = wall_sizes[rng.randi() % wall_sizes.size()]
		var y_rot := rng.randf_range(0, TAU)

		var wall := StaticBody3D.new()
		wall.name = "Wall_%d" % i
		# Place wall so its bottom sits on the terrain
		wall.position = Vector3(pos.x, pos.y + wall_size.y * 0.5, pos.z)
		wall.rotation.y = y_rot
		parent.add_child(wall)

		var col := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = wall_size
		col.shape = box_shape
		wall.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = wall_size
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = wall_mat
		wall.add_child(mesh_inst)


func _spawn_ramps(rng: RandomNumberGenerator, parent: Node3D) -> void:
	## Spawn ramp structures on the terrain surface.
	var ramp_size := Vector3(4, 0.3, 8)
	var ramp_mat := StandardMaterial3D.new()
	ramp_mat.albedo_color = Color(0.5, 0.6, 0.5, 1)

	var angles_deg := [15.0, 20.0, 25.0, 30.0]

	for i in num_ramps:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		# Ramps work best on gentler terrain
		if slope > 25.0:
			continue

		var ramp_angle: float = angles_deg[rng.randi() % angles_deg.size()]
		var y_rot := rng.randf_range(0, TAU)

		var ramp := StaticBody3D.new()
		ramp.name = "Ramp_%d" % i
		ramp.position = Vector3(pos.x, pos.y + 0.3, pos.z)
		ramp.rotation.y = y_rot
		ramp.rotation.x = deg_to_rad(ramp_angle)
		parent.add_child(ramp)

		var col := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = ramp_size
		col.shape = box_shape
		ramp.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = ramp_size
		mesh_inst.mesh = box_mesh
		mesh_inst.material_override = ramp_mat
		ramp.add_child(mesh_inst)


func _spawn_player_spawns(rng: RandomNumberGenerator) -> void:
	## Create PlayerSpawnPoints node with markers on the terrain.
	var container := get_parent().get_node_or_null("PlayerSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "PlayerSpawnPoints"
		get_parent().add_child(container)

	# Remove any existing static spawn points
	for child in container.get_children():
		child.queue_free()

	for i in num_player_spawns:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		# Players should spawn on flat-ish ground
		if slope > 20.0:
			# Try again with a new position (simple retry)
			pos = _get_random_surface_pos(rng)

		var marker := Marker3D.new()
		marker.name = "Spawn%d" % (i + 1)
		marker.position = Vector3(pos.x, pos.y + 1.0, pos.z)
		container.add_child(marker)


func _spawn_loot_points(rng: RandomNumberGenerator) -> void:
	## Create LootSpawnPoints node with markers on the terrain.
	var container := get_parent().get_node_or_null("LootSpawnPoints")
	if container == null:
		container = Node3D.new()
		container.name = "LootSpawnPoints"
		get_parent().add_child(container)

	# Remove any existing static loot points
	for child in container.get_children():
		child.queue_free()

	for i in num_loot_spawns:
		var pos := _get_random_surface_pos(rng)
		var marker := Marker3D.new()
		marker.name = "Loot%d" % (i + 1)
		marker.position = Vector3(pos.x, pos.y + 0.5, pos.z)
		container.add_child(marker)


func _spawn_dummies(rng: RandomNumberGenerator) -> void:
	## Spawn target dummies on the terrain surface.
	var dummy_scene := load("res://world/target_dummy.tscn")
	if dummy_scene == null:
		return

	var container := get_parent().get_node_or_null("Dummies")
	if container == null:
		container = Node3D.new()
		container.name = "Dummies"
		get_parent().add_child(container)

	# Remove any existing static dummies
	for child in container.get_children():
		child.queue_free()

	for i in num_dummies:
		var pos := _get_random_surface_pos(rng)
		var slope := _get_slope_at(pos.x, pos.z)
		if slope > 25.0:
			pos = _get_random_surface_pos(rng)

		var dummy: Node3D = dummy_scene.instantiate()
		dummy.name = "Dummy%d" % (i + 1)
		dummy.position = pos
		container.add_child(dummy)


# ======================================================================
#  Noise core (ported from Python)
# ======================================================================

func _hash_3d(x: int, y: int, z: int, s: int) -> float:
	var n: int = (x << 17) ^ (y << 9) ^ (z << 3) ^ s
	n = (n ^ (n >> 15)) * 0x85ebca6b
	n = (n ^ (n >> 13)) * 0xc2b2ae35
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) * INV_0X7FFFFFFF


func _value_noise_3d(x: float, y: float, z: float, s: int, blend_mode: String) -> float:
	var x0: int = int(floor(x))
	var y0: int = int(floor(y))
	var z0: int = int(floor(z))
	var xf: float = x - x0
	var yf: float = y - y0
	var zf: float = z - z0
	var u: float
	var v: float
	var w: float

	if blend_mode == "smoothstep":
		var xf2: float = xf * xf
		var xf3: float = xf2 * xf
		var yf2: float = yf * yf
		var yf3: float = yf2 * yf
		var zf2: float = zf * zf
		var zf3: float = zf2 * zf
		u = xf3 * (xf * (xf * 6.0 - 15.0) + 10.0)
		v = yf3 * (yf * (yf * 6.0 - 15.0) + 10.0)
		w = zf3 * (zf * (zf * 6.0 - 15.0) + 10.0)
	else:
		var xf2c: float = xf * xf
		var yf2c: float = yf * yf
		var zf2c: float = zf * zf
		u = xf2c * (3.0 - 2.0 * xf)
		v = yf2c * (3.0 - 2.0 * yf)
		w = zf2c * (3.0 - 2.0 * zf)

	var x1: int = x0 + 1
	var y1: int = y0 + 1
	var z1: int = z0 + 1
	var n000: float = _hash_3d(x0, y0, z0, s)
	var n100: float = _hash_3d(x1, y0, z0, s)
	var n010: float = _hash_3d(x0, y1, z0, s)
	var n110: float = _hash_3d(x1, y1, z0, s)
	var n001: float = _hash_3d(x0, y0, z1, s)
	var n101: float = _hash_3d(x1, y0, z1, s)
	var n011: float = _hash_3d(x0, y1, z1, s)
	var n111: float = _hash_3d(x1, y1, z1, s)
	var nx00: float = n000 + u * (n100 - n000)
	var nx10: float = n010 + u * (n110 - n010)
	var nx01: float = n001 + u * (n101 - n001)
	var nx11: float = n011 + u * (n111 - n011)
	var nxy0: float = nx00 + v * (nx10 - nx00)
	var nxy1: float = nx01 + v * (nx11 - nx01)
	return nxy0 + w * (nxy1 - nxy0)


func _apply_gain_bias(val: float, g: float, b: float) -> float:
	var vv: float = (val + 1.0) * 0.5
	if b != INF and b != 0.0:
		var denom: float = (1.0 / b - 2.0) * (1.0 - vv) + 1.0
		vv = vv / denom if denom != 0.0 else vv
	if g != INF:
		if vv < 0.5:
			var vv2: float = 2.0 * vv
			var denom2: float = (1.0 / g - 2.0) * (1.0 - vv2) + 1.0
			vv = (vv2 / denom2 if denom2 != 0.0 else vv2) * 0.5
		else:
			var vv2: float = 2.0 - 2.0 * vv
			var denom3: float = (1.0 / g - 2.0) * (1.0 - vv2) + 1.0
			vv = 1.0 - (vv2 / denom3 if denom3 != 0.0 else vv2) * 0.5
	return vv * 2.0 - 1.0


func _fractal_value_noise(x: float, y: float, z: float, s: int, blend_mode: String) -> float:
	var fx: float = x
	var fy: float = y
	var fz: float = z
	if domain_warp_amp > 0.0:
		var f: float = domain_warp_freq
		fx += _value_noise_3d(x * f, y * f, z * f, s + 0x123456, blend_mode) * domain_warp_amp
		fy += _value_noise_3d((x + 100.0) * f, (y + 100.0) * f, (z + 100.0) * f, s + 0x654321, blend_mode) * domain_warp_amp
		fz += _value_noise_3d((x + 200.0) * f, (y + 200.0) * f, (z + 200.0) * f, s + 0xABCDEF, blend_mode) * domain_warp_amp
	var amplitude: float = 1.0
	var frequency: float = 1.0
	var total: float = 0.0
	var max_amp: float = 0.0
	for i in octaves:
		var n: float = _value_noise_3d(fx * frequency, fy * frequency, fz * frequency, s + i * 0x9E3779B9, blend_mode)
		total += n * amplitude
		max_amp += amplitude
		amplitude *= persistence
		frequency *= lacunarity
	if max_amp != 0.0:
		total /= max_amp
	if gain != INF or bias != INF:
		total = _apply_gain_bias(total, gain, bias)
	return clampf(total, -1.0, 1.0)


# ======================================================================
#  Mesh generation
# ======================================================================

func _generate_height_field() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(width * depth)
	for z in depth:
		for x in width:
			var n: float = _fractal_value_noise(
				float(x) * base_frequency,
				slice_y,
				float(z) * base_frequency,
				seed,
				blend_func
			)
			out[z * width + x] = n * height_scale
	return out


func _compute_vertex_normals(heights: PackedFloat32Array) -> Array[Vector3]:
	## Pre-compute smooth per-vertex normals from the heightfield.
	## Each normal is derived from the slope to neighboring vertices.
	var normals: Array[Vector3] = []
	normals.resize(width * depth)

	for z in depth:
		for x in width:
			# Sample neighboring heights (clamped at edges)
			var xL: int = maxi(x - 1, 0)
			var xR: int = mini(x + 1, width - 1)
			var zD: int = maxi(z - 1, 0)
			var zU: int = mini(z + 1, depth - 1)

			var hL: float = heights[z * width + xL]
			var hR: float = heights[z * width + xR]
			var hD: float = heights[zD * width + x]
			var hU: float = heights[zU * width + x]

			# Central difference: tangent in X and Z, cross product gives normal
			var dx: float = (xR - xL) * cell_size
			var dz: float = (zU - zD) * cell_size
			var n: Vector3 = Vector3(
				(hL - hR) / dx * 2.0 * cell_size,
				2.0,
				(hD - hU) / dz * 2.0 * cell_size
			).normalized()
			normals[z * width + x] = n

	return normals


func _build_heightmap_mesh(heights: PackedFloat32Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Pre-compute smooth normals so terrain isn't flat-shaded
	var normals: Array[Vector3] = _compute_vertex_normals(heights)

	var max_x: int = width - 1
	var max_z: int = depth - 1
	for z in max_z:
		for x in max_x:
			var i00: int = z * width + x
			var i10: int = i00 + 1
			var i01: int = i00 + width
			var i11: int = i01 + 1
			var p00: Vector3 = Vector3(x * cell_size, heights[i00], z * cell_size)
			var p10: Vector3 = Vector3((x + 1) * cell_size, heights[i10], z * cell_size)
			var p01: Vector3 = Vector3(x * cell_size, heights[i01], (z + 1) * cell_size)
			var p11: Vector3 = Vector3((x + 1) * cell_size, heights[i11], (z + 1) * cell_size)

			# Smooth per-vertex normals
			var nm00: Vector3 = normals[i00]
			var nm10: Vector3 = normals[i10]
			var nm01: Vector3 = normals[i01]
			var nm11: Vector3 = normals[i11]

			# Triangle 1: p00, p10, p01
			st.set_normal(nm00)
			st.set_uv(Vector2(x / float(max_x), z / float(max_z)))
			st.add_vertex(p00)
			st.set_normal(nm10)
			st.set_uv(Vector2((x + 1) / float(max_x), z / float(max_z)))
			st.add_vertex(p10)
			st.set_normal(nm01)
			st.set_uv(Vector2(x / float(max_x), (z + 1) / float(max_z)))
			st.add_vertex(p01)

			# Triangle 2: p10, p11, p01
			st.set_normal(nm10)
			st.set_uv(Vector2((x + 1) / float(max_x), z / float(max_z)))
			st.add_vertex(p10)
			st.set_normal(nm11)
			st.set_uv(Vector2((x + 1) / float(max_x), (z + 1) / float(max_z)))
			st.add_vertex(p11)
			st.set_normal(nm01)
			st.set_uv(Vector2(x / float(max_x), (z + 1) / float(max_z)))
			st.add_vertex(p01)

	return st.commit()
