extends Node3D

## Map logic: spawns loot chests, demo items, zone visual, and starts the zone.
## The SeedWorld child generates terrain, structures, and spawn points.

## Item definitions split by type for chest loot pools.
var weapon_definitions: Array[ItemData] = []
var shoe_definitions: Array[ItemData] = []
var fuel_definitions: Array[ItemData] = []

## Number of loot chests to spawn (uses a subset of LootSpawnPoints)
const CHEST_COUNT := 80

## DEBUG: items to spawn near the host player at game start (permanent, no burn timer).
## These are "demo" pickups — the player can grab them at leisure.
const DEMO_SPAWN_TABLE: Array[Dictionary] = [
	{ "path": "res://items/definitions/gun_jeg_rocket_launcher.tres",     "offset": Vector3(2, 0, 2) },
	{ "path": "res://items/definitions/gun_rubber_ball_launcher.tres",    "offset": Vector3(-2, 0, 2) },
	{ "path": "res://items/definitions/gun_bubble_blower.tres",           "offset": Vector3(0, 0, 3) },
	{ "path": "res://items/definitions/gun_bubble_blower.tres",           "offset": Vector3(3, 0, -2) },
	{ "path": "res://items/definitions/gun_rubber_ball_launcher.tres",    "offset": Vector3(-3, 0, -2) },
	{ "path": "res://items/definitions/weapon_toad_staff.tres",           "offset": Vector3(0, 0, -3) },
	{ "path": "res://items/definitions/consumable_kamikaze_missile.tres", "offset": Vector3(4, 0, 0) },
	{ "path": "res://items/definitions/gadget_grappling_hook.tres",       "offset": Vector3(-4, 0, 0) },
]

## Zone visual
var _zone_mesh: MeshInstance3D = null
var _zone_material: StandardMaterial3D = null
## Fire particles along zone edge
var _zone_fire_ring: Node3D = null
const ZONE_FIRE_EMITTER_COUNT := 192  ## Number of fire particle emitters around the ring
var _fire_ring_update_timer: float = 0.0  ## Throttle fire position updates
var _fire_ring_last_radius: float = -1.0  ## Track radius changes


func _ready() -> void:
	# Zone visual is cosmetic — create on ALL peers so everyone sees the ring + fire
	_create_zone_visual()

	# Item definitions and loot chests run on ALL peers so clients can see chests.
	# Chest gameplay logic (loot generation, opening) is server-only via is_server() guards.
	_load_item_definitions()
	_spawn_loot_chests()

	if not multiplayer.is_server():
		return

	if has_node("/root/BurnClock"):
		get_node("/root/BurnClock").start()

	# NOTE: _spawn_demo_items() is called from network_manager._start_host()
	# after the host player is spawned (it needs Players/1 to exist).
	_start_zone()


func _load_item_definitions() -> void:
	## Load item definitions and split into categories for chest loot pools.
	var dir := DirAccess.open("res://items/definitions/")
	if dir == null:
		push_warning("Could not open items/definitions/ directory")
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.ends_with(".tres"):
			var res := load("res://items/definitions/" + file_name)
			if res is ItemData:
				match res.item_type:
					ItemData.ItemType.SHOE:
						shoe_definitions.append(res)
					ItemData.ItemType.FUEL:
						fuel_definitions.append(res)
					_:
						weapon_definitions.append(res)
		file_name = dir.get_next()
	dir.list_dir_end()
	print("Loaded %d weapons, %d shoes, %d fuel" % [
		weapon_definitions.size(), shoe_definitions.size(),
		fuel_definitions.size()])


# ======================================================================
#  Loot Chests (replace old scattered loot system)
# ======================================================================

func _spawn_loot_chests() -> void:
	## Spawn loot chests at a subset of LootSpawnPoints.
	var loot_spawn_points := get_node_or_null("LootSpawnPoints")
	if loot_spawn_points == null:
		push_warning("No LootSpawnPoints node found — terrain may not have generated yet")
		return

	var points: Array[Node] = []
	for child in loot_spawn_points.get_children():
		if child is Marker3D:
			points.append(child)

	# Shuffle deterministically so all peers pick the same CHEST_COUNT points.
	# Godot's Array.shuffle() uses the global RNG which differs per peer.
	var rng := RandomNumberGenerator.new()
	rng.seed = 55555
	for i in range(points.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Node = points[i]
		points[i] = points[j]
		points[j] = tmp
	var count := mini(CHEST_COUNT, points.size())

	var chest_scene := preload("res://world/loot_chest.tscn")
	var container := get_node_or_null("WorldItems")
	if container == null:
		container = self

	for i in count:
		var chest: LootChest = chest_scene.instantiate()
		# Pass loot pools to chest so it can generate its own loot
		chest.weapon_pool = weapon_definitions
		chest.shoe_pool = shoe_definitions
		chest.fuel_pool = fuel_definitions
		chest.position = points[i].global_position
		container.add_child(chest, true)

	print("Spawned %d loot chests" % count)


# ======================================================================
#  Demo Items (permanent pickups near host player)
# ======================================================================

func _spawn_demo_items() -> void:
	## Spawn demo items in front of the host player. These never expire.
	if DEMO_SPAWN_TABLE.is_empty():
		return

	var players_node := get_node_or_null("Players")
	if players_node == null:
		return

	# Find host player (peer_id 1)
	var host_player := players_node.get_node_or_null("1")
	if host_player == null:
		push_warning("Host player not found for demo item spawning")
		return

	var host_pos: Vector3 = host_player.global_position
	var container := get_node_or_null("WorldItems")
	if container == null:
		container = self

	var count := 0
	for entry: Dictionary in DEMO_SPAWN_TABLE:
		var item_data := load(entry["path"]) as ItemData
		if item_data == null:
			push_warning("DEMO: Could not load %s" % entry["path"])
			continue
		var offset: Vector3 = entry["offset"]

		var world_item_scene := preload("res://items/world_item.tscn")
		var world_item: WorldItem = world_item_scene.instantiate()
		world_item.setup(item_data)
		# Make permanent — burn_time_remaining >= PERMANENT_THRESHOLD means never expires
		world_item.burn_time_remaining = 999999.0
		world_item.position = host_pos + offset
		container.add_child(world_item, true)
		count += 1

	if count > 0:
		print("DEMO: Spawned %d permanent test items near host player" % count)


func spawn_lemon_shapes() -> void:
	## Spawn lemon (pill) shape visualizations on a walkable platform so the
	## player can walk along it and have their midsection enter the narrow end
	## of each shape — simulating what it looks like to swing into the lemon.
	## All variants are near W=1.0m (the user's preferred width).
	var players_node := get_node_or_null("Players")
	if players_node == null:
		return
	var host_player := players_node.get_node_or_null("1")
	if host_player == null:
		return

	var host_pos: Vector3 = host_player.global_position
	# Raise the platform well above terrain so nothing phases through the ground.
	# +8m Y guarantees clearance over any terrain feature (max height scale = 16m,
	# but player spawns are on the surface).
	var platform_y: float = host_pos.y + 8.0
	var platform_start: Vector3 = host_pos + Vector3(8.0, 8.0, 0.0)

	# Each entry: [name, max_width, rope_length, straightness, color]
	# straightness = fraction of length that is a straight cylinder (0.0 = pure
	# lemon, 1.0 = cylinder with flat ends).  The remaining length is split
	# between two hemisphere caps at the tips.
	# All L=10m, varying width and straightness to find the right feel:
	# mostly straight sides with nearly round tips.
	var variants: Array[Array] = [
		["W=0.8 S=0.6", 0.8, 10.0, 0.6, Color(0.4, 0.8, 1.0, 0.4)],   # Light blue
		["W=0.9 S=0.6", 0.9, 10.0, 0.6, Color(0.3, 1.0, 0.5, 0.4)],   # Green
		["W=1.0 S=0.6", 1.0, 10.0, 0.6, Color(1.0, 0.7, 0.1, 0.4)],   # Orange
		["W=1.1 S=0.6", 1.1, 10.0, 0.6, Color(1.0, 1.0, 0.2, 0.4)],   # Yellow
		["W=1.2 S=0.6", 1.2, 10.0, 0.6, Color(1.0, 0.3, 0.3, 0.4)],   # Red
	]

	# Spacing between shapes along the platform (Z axis = walk direction)
	var spacing := 6.0
	var platform_length: float = (variants.size() - 1) * spacing + 8.0  # 4m padding each end
	var platform_width := 3.0  # Wide enough to walk comfortably

	# --- Build the platform ---
	# A simple box the player walks along.  Shapes are arranged along Z.
	var platform_mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(platform_width, 0.5, platform_length)
	platform_mesh.mesh = box
	var plat_mat := StandardMaterial3D.new()
	plat_mat.albedo_color = Color(0.35, 0.35, 0.4, 1.0)
	platform_mesh.material_override = plat_mat
	platform_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Surface is at platform_y, so the box center is 0.25m below
	platform_mesh.position = platform_start + Vector3(0.0, -0.25, platform_length * 0.5 - 4.0)
	add_child(platform_mesh)

	# Collision so the player can walk on it
	var platform_body := StaticBody3D.new()
	platform_body.position = platform_mesh.position
	var col_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	col_shape.shape = box_shape
	platform_body.add_child(col_shape)
	add_child(platform_body)

	# --- Ramp from ground to platform ---
	# So the player can walk up to the platform without jumping.
	var ramp_length := 12.0
	var ramp_thickness := 0.3
	var ramp_angle := atan2(8.0, ramp_length)  # Rise 8m over ramp_length
	var ramp_actual_len := sqrt(8.0 * 8.0 + ramp_length * ramp_length)

	var ramp_mesh := MeshInstance3D.new()
	var ramp_box := BoxMesh.new()
	ramp_box.size = Vector3(platform_width, ramp_thickness, ramp_actual_len)
	ramp_mesh.mesh = ramp_box
	ramp_mesh.material_override = plat_mat
	ramp_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Position ramp: starts at ground level, ends at platform edge
	var ramp_center := Vector3(
		platform_start.x,
		host_pos.y + 4.0,  # Midpoint height
		platform_start.z - 4.0 - ramp_actual_len * 0.5 * cos(ramp_angle)
	)
	ramp_mesh.position = ramp_center
	ramp_mesh.rotation.x = ramp_angle
	add_child(ramp_mesh)

	var ramp_body := StaticBody3D.new()
	ramp_body.position = ramp_center
	ramp_body.rotation.x = ramp_angle
	var ramp_col := CollisionShape3D.new()
	var ramp_shape := BoxShape3D.new()
	ramp_shape.size = ramp_box.size
	ramp_col.shape = ramp_shape
	ramp_body.add_child(ramp_col)
	add_child(ramp_body)

	# --- Spawn lemon shapes ---
	# Each lemon stands upright (like the original visualization that looked right).
	# The lemon is built along local Z, so rotation.x = -PI/2 points local Z
	# upward (world +Y).  The bottom tip of the lemon sits at the player's
	# chest height (platform_y + 1.0m) right beside the platform edge,
	# so walking along the platform means the player's midsection passes
	# through the narrow bottom point of each shape.
	var chest_height: float = 1.0  # Player capsule center offset from feet

	for i in variants.size():
		var v_name: String = variants[i][0]
		var max_width: float = variants[i][1]
		var rope_len: float = variants[i][2]
		var straightness: float = variants[i][3]
		var color: Color = variants[i][4]

		var z_pos: float = i * spacing  # Offset along platform walk direction

		# The capsule mesh spans from local Z = -half_length to +half_length.
		# After rotation.x = -PI/2, local Z becomes world +Y.
		# Bottom tip at chest height → position.y = platform_y + chest_height + half_length
		var half_length: float = rope_len / 2.0
		var lemon_pos := Vector3(
			platform_start.x,
			platform_y + chest_height + half_length,
			platform_start.z + z_pos
		)

		var mesh_instance := _build_lemon_mesh(rope_len, max_width, color, straightness)
		mesh_instance.position = lemon_pos
		# Point local Z upward so the shape stands vertically
		mesh_instance.rotation.x = -PI / 2.0
		add_child(mesh_instance)

		# Label above each shape
		var label_3d := Label3D.new()
		label_3d.text = v_name
		label_3d.font_size = 36
		label_3d.modulate = Color(1, 1, 1, 1)
		label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label_3d.position = Vector3(
			lemon_pos.x,
			platform_y + chest_height + rope_len + 1.5,
			platform_start.z + z_pos
		)
		add_child(label_3d)

	print("DEMO: Spawned %d lemon shape variants on walkable platform" % variants.size())


func _build_lemon_mesh(rope_len: float, max_width: float, color: Color, straightness: float = 0.0) -> MeshInstance3D:
	## Build a capsule-style mesh: straight cylinder middle + hemisphere caps.
	## straightness = fraction of total length that is the straight cylinder
	## (0.0 = pure lemon/sphere, 1.0 = cylinder with flat ends).
	## The shape is oriented along local Z axis, centered at origin.
	var half_length: float = rope_len / 2.0
	var radius: float = max_width / 2.0

	# Split the total length into cylinder + two caps
	var cyl_length: float = rope_len * clampf(straightness, 0.0, 0.95)
	var half_cyl: float = cyl_length / 2.0
	# Each hemisphere cap has height = (total - cylinder) / 2
	# The cap radius sphere is sized so the cap smoothly meets the cylinder
	# at the join.  Cap height = half_length - half_cyl.
	var cap_height: float = half_length - half_cyl
	# If cap_height < radius, the cap is a partial sphere (oblate).
	# If cap_height >= radius, the cap is a full hemisphere or taller.
	# We'll use an ellipsoidal cap: radial extent = radius, axial extent = cap_height.

	var N_CAP := 12     # samples along each cap
	var N_CYL := 6      # samples along the cylinder portion
	var N_AROUND := 16  # samples around the circumference

	var im := ImmediateMesh.new()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = im
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_inst.material_override = mat

	# Helper: compute (z_pos, radius_at_z) for a given sample index across
	# the full shape.  The shape has 3 sections:
	#   Bottom cap: z from -half_length to -half_cyl  (N_CAP samples)
	#   Cylinder:   z from -half_cyl to +half_cyl     (N_CYL samples)
	#   Top cap:    z from +half_cyl to +half_length   (N_CAP samples)
	var profile: Array[Vector2] = []  # [z, r] pairs

	# Bottom cap (ellipsoidal from tip to cylinder join)
	for i in N_CAP:
		var t: float = float(i) / float(N_CAP)  # 0 = tip, 1 = join
		var z: float = -half_length + t * cap_height
		# Ellipse: (z_local/cap_height)^2 + (r/radius)^2 = 1
		var z_local: float = cap_height - t * cap_height  # distance from join
		var r: float = radius * sqrt(maxf(1.0 - (z_local * z_local) / maxf(cap_height * cap_height, 0.001), 0.0))
		profile.append(Vector2(z, r))

	# Cylinder section
	for i in N_CYL + 1:
		var t: float = float(i) / float(N_CYL)
		var z: float = -half_cyl + t * cyl_length
		profile.append(Vector2(z, radius))

	# Top cap (ellipsoidal from cylinder join to tip)
	for i in range(1, N_CAP + 1):
		var t: float = float(i) / float(N_CAP)  # 0 = join, 1 = tip
		var z: float = half_cyl + t * cap_height
		var z_local: float = t * cap_height  # distance from join
		var r: float = radius * sqrt(maxf(1.0 - (z_local * z_local) / maxf(cap_height * cap_height, 0.001), 0.0))
		profile.append(Vector2(z, r))

	# Build triangle strips from the profile
	for j in N_AROUND:
		var theta0: float = TAU * j / N_AROUND
		var theta1: float = TAU * (j + 1) / N_AROUND

		im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for k in profile.size():
			var z: float = profile[k].x
			var r: float = profile[k].y
			im.surface_add_vertex(Vector3(cos(theta0) * r, sin(theta0) * r, z))
			im.surface_add_vertex(Vector3(cos(theta1) * r, sin(theta1) * r, z))
		im.surface_end()

	# Wireframe overlay
	var wire_mat := StandardMaterial3D.new()
	wire_mat.albedo_color = Color(color.r, color.g, color.b, 0.9)
	wire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Longitudinal lines
	for j in N_AROUND:
		var theta: float = TAU * j / N_AROUND
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, wire_mat)
		for k in profile.size():
			var z: float = profile[k].x
			var r: float = profile[k].y
			im.surface_add_vertex(Vector3(cos(theta) * r, sin(theta) * r, z))
		im.surface_end()

	# Latitude rings (every few samples)
	for k in profile.size():
		if k % 3 != 0 and k != profile.size() - 1:
			continue
		var z: float = profile[k].x
		var r: float = profile[k].y
		if r < 0.01:
			continue
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, wire_mat)
		for j in N_AROUND + 1:
			var theta: float = TAU * j / N_AROUND
			im.surface_add_vertex(Vector3(cos(theta) * r, sin(theta) * r, z))
		im.surface_end()

	return mesh_inst


# ======================================================================
#  Zone visual (shrinking circle wall)
# ======================================================================

func _create_zone_visual() -> void:
	## Create the zone boundary visual: a red semi-transparent cylinder wall
	## visible only from OUTSIDE the safe zone, plus a ring of fire particles
	## along the base of the circle.
	## Updated each frame in _process() to match ZoneManager.zone_radius.

	# --- Red wall cylinder — tall enough that you can never fly above it ---
	# 300m tall, bottom at y=-10 (below terrain), top at y=290 (well above kamikaze peak).
	# Open top = looking up you see clear sky framed by the red haze ring.
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0  # We'll scale via node.scale
	cylinder.bottom_radius = 1.0
	cylinder.height = 300.0
	cylinder.radial_segments = 64

	_zone_material = StandardMaterial3D.new()
	_zone_material.albedo_color = Color(0.8, 0.1, 0.0, 0.15)  # Red-orange, semi-transparent
	_zone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_zone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_material.cull_mode = BaseMaterial3D.CULL_BACK  # Render front faces only — visible from OUTSIDE the zone looking in, invisible from inside the safe zone
	_zone_material.no_depth_test = false  # Respect depth buffer so terrain occludes the wall

	_zone_mesh = MeshInstance3D.new()
	_zone_mesh.mesh = cylinder
	_zone_mesh.material_override = _zone_material
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.position.y = 140.0  # Centered: bottom at -10, top at 290
	add_child(_zone_mesh)

	# --- Fire particle ring along the base of the zone boundary ---
	_zone_fire_ring = Node3D.new()
	_zone_fire_ring.name = "ZoneFireRing"
	add_child(_zone_fire_ring)

	for i in ZONE_FIRE_EMITTER_COUNT:
		var fire := _create_fire_emitter()
		_zone_fire_ring.add_child(fire)


func _create_fire_emitter() -> GPUParticles3D:
	## Create a single fire/ember emitter for the zone boundary ring.
	## Each emitter produces a thick column of fire; many placed close together
	## form a continuous wall of flame around the entire circumference.
	var particles := GPUParticles3D.new()
	particles.emitting = true
	particles.amount = 40
	particles.lifetime = 1.6
	particles.explosiveness = 0.0
	particles.visibility_aabb = AABB(Vector3(-5, -2, -5), Vector3(10, 14, 10))

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 30.0  # Wide spread so flames overlap with neighbours
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 5.5
	mat.gravity = Vector3(0, 2.0, 0)  # Fire rises
	mat.scale_min = 0.8
	mat.scale_max = 2.0
	mat.damping_min = 0.8
	mat.damping_max = 1.5
	# Lateral scatter so particles fill the gap between emitters
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(1.5, 0.3, 1.5)

	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(1.0, 0.7, 0.15, 0.95))  # Bright yellow-orange core
	gradient.add_point(0.2, Color(1.0, 0.45, 0.05, 0.85))  # Intense orange
	gradient.add_point(0.5, Color(0.9, 0.2, 0.0, 0.6))     # Deep orange-red
	gradient.add_point(0.75, Color(0.5, 0.08, 0.0, 0.3))   # Dark red embers
	gradient.add_point(1.0, Color(0.15, 0.03, 0.0, 0.0))   # Fades to nothing
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = gradient
	mat.color_ramp = grad_tex
	particles.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(1.8, 1.8)
	var draw_mat := StandardMaterial3D.new()
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw_mat.vertex_color_use_as_albedo = true
	quad.material = draw_mat
	particles.draw_pass_1 = quad

	return particles


func _start_zone() -> void:
	## Start the shrinking zone system.
	if has_node("/root/ZoneManager"):
		var seed_world := get_node_or_null("SeedWorld")
		var map_size: float = 400.0
		if seed_world and "map_size" in seed_world:
			map_size = seed_world.map_size
		get_node("/root/ZoneManager").start_zone(map_size * 0.5, Vector2.ZERO)


func _process(delta: float) -> void:
	# Update zone visual to match current zone radius
	if _zone_mesh and has_node("/root/ZoneManager"):
		var zm := get_node("/root/ZoneManager")
		var r: float = zm.zone_radius
		_zone_mesh.scale.x = r
		_zone_mesh.scale.z = r
		# Position at zone center
		_zone_mesh.position.x = zm.zone_center.x
		_zone_mesh.position.z = zm.zone_center.y

		# Position fire emitters evenly around the zone circumference.
		# Throttled: only recalculate positions every 0.5s or when radius changes significantly.
		if _zone_fire_ring:
			_fire_ring_update_timer -= delta
			var radius_changed := absf(r - _fire_ring_last_radius) > 1.0
			if _fire_ring_update_timer <= 0.0 or radius_changed:
				_fire_ring_update_timer = 0.5
				_fire_ring_last_radius = r
				var seed_world := get_node_or_null("SeedWorld")
				var emitters := _zone_fire_ring.get_children()
				var emitter_count := emitters.size()
				for i in emitter_count:
					var angle := float(i) / float(emitter_count) * TAU
					var emitter: GPUParticles3D = emitters[i]
					var ex: float = zm.zone_center.x + cos(angle) * r
					var ez: float = zm.zone_center.y + sin(angle) * r
					# Get terrain height at emitter position
					var ey := 0.0
					if seed_world and seed_world.has_method("get_height_at"):
						ey = seed_world.get_height_at(ex, ez)
					emitter.global_position = Vector3(ex, ey, ez)
					# Only emit if radius is reasonable
					emitter.emitting = r > 5.0


# ======================================================================
#  Shared helper (kept for compatibility)
# ======================================================================

func _place_world_item(item_data: ItemData, pos: Vector3) -> void:
	## Instantiate a WorldItem, set it up, and add it to the WorldItems container.
	var world_item_scene := preload("res://items/world_item.tscn")
	var world_item: WorldItem = world_item_scene.instantiate()
	world_item.setup(item_data)
	world_item.position = pos

	var container := get_node_or_null("WorldItems")
	if container:
		container.add_child(world_item, true)
	else:
		add_child(world_item, true)
