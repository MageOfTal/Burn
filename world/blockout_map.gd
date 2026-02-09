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
const ZONE_FIRE_EMITTER_COUNT := 48  ## Number of fire particle emitters around the ring
var _fire_ring_update_timer: float = 0.0  ## Throttle fire position updates
var _fire_ring_last_radius: float = -1.0  ## Track radius changes


func _ready() -> void:
	# Zone visual is cosmetic — create on ALL peers so everyone sees the ring + fire
	_create_zone_visual()

	if not multiplayer.is_server():
		return

	_load_item_definitions()

	if has_node("/root/BurnClock"):
		get_node("/root/BurnClock").start()

	# SeedWorld._ready() already ran (child _ready before parent) and spawned
	# lightweight markers (PlayerSpawnPoints, LootSpawnPoints) synchronously.
	# Heavy structures (walls, ramps) are batched across frames in the background.
	_spawn_loot_chests()
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

	# Shuffle and take first CHEST_COUNT points
	points.shuffle()
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


# ======================================================================
#  Zone visual (shrinking circle wall)
# ======================================================================

func _create_zone_visual() -> void:
	## Create the zone boundary visual: a red semi-transparent cylinder wall
	## visible only from OUTSIDE the safe zone, plus a ring of fire particles
	## along the base of the circle.
	## Updated each frame in _process() to match ZoneManager.zone_radius.

	# --- Red wall cylinder (visible from outside only) ---
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0  # We'll scale via node.scale
	cylinder.bottom_radius = 1.0
	cylinder.height = 50.0
	cylinder.radial_segments = 64

	_zone_material = StandardMaterial3D.new()
	_zone_material.albedo_color = Color(0.8, 0.1, 0.0, 0.15)  # Red-orange, semi-transparent
	_zone_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_zone_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_zone_material.cull_mode = BaseMaterial3D.CULL_BACK  # Render outside face only — visible when OUTSIDE the zone
	_zone_material.no_depth_test = true

	_zone_mesh = MeshInstance3D.new()
	_zone_mesh.mesh = cylinder
	_zone_mesh.material_override = _zone_material
	_zone_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_zone_mesh.position.y = 25.0  # Center vertically
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
	var particles := GPUParticles3D.new()
	particles.emitting = true
	particles.amount = 12
	particles.lifetime = 1.2
	particles.explosiveness = 0.0
	particles.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 8, 6))

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 15.0
	mat.initial_velocity_min = 1.5
	mat.initial_velocity_max = 4.0
	mat.gravity = Vector3(0, 1.5, 0)  # Fire rises
	mat.scale_min = 0.3
	mat.scale_max = 0.8
	mat.damping_min = 1.0
	mat.damping_max = 2.0

	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(1.0, 0.6, 0.1, 0.9))   # Bright orange-yellow
	gradient.add_point(0.3, Color(1.0, 0.25, 0.0, 0.7))   # Deep orange
	gradient.add_point(0.7, Color(0.6, 0.08, 0.0, 0.4))   # Dark red
	gradient.add_point(1.0, Color(0.2, 0.05, 0.0, 0.0))   # Fades to nothing
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = gradient
	mat.color_ramp = grad_tex
	particles.process_material = mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)
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
