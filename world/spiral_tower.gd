extends Node3D
class_name SpiralTower

## Massive spiral tower built from a dedicated VoxelTerrain.
## Explosions carve it smoothly (same SDF deformation as terrain).
## When the base is sufficiently carved away, the upper section detaches,
## topples as a rigid body, and shatters into damaging chunks on impact.
##
## Spawned by seed_world.gd as part of world generation.
## Server-authoritative: server runs integrity checks and collapse physics.

const TowerToppleBodyScript := preload("res://world/tower_topple_body.gd")
const TowerChunkScript := preload("res://world/tower_chunk.gd")

# ======================================================================
#  Tower geometry constants
# ======================================================================

const CORE_RADIUS := 3.0           ## Solid cylindrical core radius (meters)
const RAMP_WIDTH := 2.5            ## Ramp extends this far beyond core
const OUTER_RADIUS := 5.5          ## CORE_RADIUS + RAMP_WIDTH
const TOWER_HEIGHT := 40.0         ## Total tower height (meters)
const SPIRAL_ROTATIONS := 4.5     ## Full rotations over the height
const RAMP_ARC := PI * 0.5        ## Ramp spans 90 degrees of arc
const RAMP_THICKNESS := 1.5       ## Vertical thickness of ramp surface

## SDF writing resolution — smaller = more detail but slower generation
const SDF_STEP := 0.8              ## Step size for voxel writing (meters)
const SDF_FILL_VALUE := -1.0       ## Negative SDF = solid
const SDF_EMPTY_VALUE := 1.0       ## Positive SDF = air

## Sphere-painting radius for do_sphere approach (blobby but fast)
const CORE_PAINT_RADIUS := 2.0    ## Sphere radius for painting the core column
const RAMP_PAINT_RADIUS := 1.2    ## Sphere radius for painting the ramp path

# ======================================================================
#  Structural integrity constants (Local Boundary BFS)
# ======================================================================

## Sampling resolution for the SDF grid used in connectivity checks.
## 1.0m is a good balance: ~5700 cells for the tower bounding box,
## but local BFS only processes hundreds near the explosion.
const INTEGRITY_SAMPLE_STEP := 1.0
## Minimum time between integrity checks (prevents spam from rapid explosions)
const INTEGRITY_CHECK_COOLDOWN := 0.5
## Ground level tolerance — voxels within this Y offset from tower base count as "grounded"
const GROUND_Y_TOLERANCE := 2.0
## BFS iteration limit per check to prevent frame stalls in GDScript.
## Tower cross-section is ~95 cells/layer * 40 layers ≈ 3800 cells total,
## so we need at least 5000 to fully traverse an intact tower.
const BFS_MAX_ITERATIONS := 6000

# ======================================================================
#  State
# ======================================================================

var _voxel_terrain: VoxelTerrain = null
var _voxel_tool: VoxelTool = null
var _tower_material: StandardMaterial3D = null

## Whether the tower has been fully built
var _is_built: bool = false
## Cooldown timer for integrity checks
var _integrity_cooldown: float = 0.0
## The player who last damaged the tower (for kill attribution)
var _last_attacker_id: int = -1
## Whether a collapse is currently in progress
var _collapse_in_progress: bool = false
## Tracks the current effective tower top (lowered after each collapse)
var _effective_tower_top: float = TOWER_HEIGHT
## Pre-baked chunk fragment meshes (extracted from voxel data before erase)
var _cached_chunk_meshes: Array[Mesh] = []
## Pre-baked chunk mesh offsets (local offset from chunk center to mesh origin)
var _cached_chunk_offsets: Array[Vector3] = []

## Signal emitted when tower generation is complete (awaited by seed_world)
signal generation_complete


func _ready() -> void:
	_build_tower()


func _physics_process(delta: float) -> void:
	if _integrity_cooldown > 0.0:
		_integrity_cooldown -= delta


# ======================================================================
#  Tower VoxelTerrain creation
# ======================================================================

func _build_tower() -> void:
	## Create the tower's VoxelTerrain and paint the spiral shape into it.

	# --- Material ---
	_tower_material = StandardMaterial3D.new()
	_tower_material.albedo_color = Color(0.45, 0.42, 0.40)  # Stone gray

	# --- VoxelTerrain ---
	_voxel_terrain = VoxelTerrain.new()
	_voxel_terrain.name = "TowerVoxelTerrain"

	# Mesher: same Transvoxel as terrain for smooth surfaces
	var mesher := VoxelMesherTransvoxel.new()
	_voxel_terrain.mesher = mesher

	# Generator: flat plane far below the tower so all data blocks load as air.
	# Without a generator, blocks never load into memory and VoxelTool.do_sphere()
	# fails with "Area not editable". The flat surface at Y=-100 means every block
	# within our bounds is pure air (positive SDF), ready for us to paint into.
	var generator := VoxelGeneratorFlat.new()
	generator.channel = VoxelBuffer.CHANNEL_SDF
	generator.height = -100.0
	_voxel_terrain.generator = generator

	# Keep carved voxel data in memory so the tower survives chunk unloading
	# (e.g. toad dimension teleport to Y=-500 and back).
	var stream := VoxelStreamMemory.new()
	_voxel_terrain.stream = stream

	# Settings matching the terrain
	_voxel_terrain.mesh_block_size = 16
	_voxel_terrain.max_view_distance = 128
	_voxel_terrain.generate_collisions = true
	_voxel_terrain.collision_layer = 1   # World geometry
	_voxel_terrain.collision_mask = 0    # Static — doesn't collide with anything itself

	# Bounds: VoxelTerrain bounds are in voxel coordinates (1:1 with world units).
	# Since this VoxelTerrain is a child of the SpiralTower node, and do_sphere()
	# uses global_position, the bounds must cover the world-space area around the
	# tower. We use large bounds to be safe — the generator is cheap (flat plane)
	# and only a few blocks will actually get loaded near the tower.
	_voxel_terrain.bounds = AABB(
		Vector3(-256, -64, -256),
		Vector3(512, 256, 512)
	)

	_voxel_terrain.material_override = _tower_material
	add_child(_voxel_terrain)

	# Let the streaming system process a few frames so blocks around the tower
	# position get loaded. Without this, do_sphere() may hit unloaded blocks.
	for i in 5:
		await get_tree().process_frame

	# Get VoxelTool for writing
	_voxel_tool = _voxel_terrain.get_voxel_tool()

	print("[SpiralTower] Painting tower at global_position=%s" % str(global_position))

	# Paint the spiral shape using spheres along the core and ramp paths
	await _paint_tower_shape()

	_is_built = true
	generation_complete.emit()
	print("[SpiralTower] Tower built at %s (height: %.0fm)" % [str(global_position), TOWER_HEIGHT])


func _paint_tower_shape() -> void:
	## Paint the tower shape into the VoxelTerrain using do_sphere(MODE_ADD).
	## This creates a blobby but solid spiral structure.
	##
	## COORDINATE NOTE: VoxelToolTerrain.do_sphere() operates in the VoxelTerrain's
	## own voxel grid space. Since the VoxelTerrain is a child of SpiralTower,
	## its world transform is offset by the tower's position. We must pass
	## global_position + offset so the voxel data aligns with where the tower
	## actually is in the world. The mesh renderer then applies the inverse of the
	## VoxelTerrain's transform automatically.
	##
	## HOWEVER — Zylann's VoxelToolTerrain interprets positions in voxel-data space
	## which does NOT include the node's transform. The rendered mesh IS transformed
	## by the node's global transform. So to paint at world (0,16,0) we must pass
	## the position in voxel-data space — which is just the local offset from origin.
	## Since the VoxelTerrain child is at local (0,0,0) relative to SpiralTower,
	## painting at local (0, y, 0) ends up at world = SpiralTower.global_pos + (0, y, 0).
	if _voxel_tool == null:
		return

	_voxel_tool.mode = VoxelTool.MODE_ADD
	var frames_since_yield := 0
	var yield_interval := 20  # Yield every N sphere operations

	# --- Paint core column ---
	# Place overlapping spheres along the Y axis to form a solid cylinder
	var core_step := CORE_PAINT_RADIUS * 0.6  # Overlap for solid fill
	var y := 0.0
	while y <= TOWER_HEIGHT:
		# Paint a ring of spheres to form a filled cylinder cross-section
		var num_ring_points := 8
		for i in num_ring_points:
			var angle := float(i) / float(num_ring_points) * TAU
			var ring_r := CORE_RADIUS * 0.5  # Inner ring for solid fill
			var pos := Vector3(
				cos(angle) * ring_r,
				y,
				sin(angle) * ring_r
			)
			_voxel_tool.do_sphere(pos, CORE_PAINT_RADIUS)
			frames_since_yield += 1

		# Center sphere for solid core
		_voxel_tool.do_sphere(Vector3(0, y, 0), CORE_PAINT_RADIUS)
		frames_since_yield += 1

		if frames_since_yield >= yield_interval:
			frames_since_yield = 0
			await get_tree().process_frame

		y += core_step

	# --- Paint spiral ramp ---
	# Trace the spiral path and place spheres along it
	var ramp_step := RAMP_PAINT_RADIUS * 0.5  # Dense placement for solid ramp
	y = 0.0
	while y <= TOWER_HEIGHT:
		var progress := y / TOWER_HEIGHT  # 0 to 1
		var center_angle := progress * SPIRAL_ROTATIONS * TAU

		# Paint multiple spheres across the ramp width and arc
		var arc_steps := 8  # Steps across the 90-degree arc
		var width_steps := 3  # Steps across the ramp width

		for arc_i in arc_steps:
			var arc_frac := float(arc_i) / float(arc_steps - 1)
			var angle := center_angle - RAMP_ARC * 0.5 + arc_frac * RAMP_ARC

			for w_i in width_steps:
				var width_frac := float(w_i) / float(width_steps - 1)
				var r := CORE_RADIUS + width_frac * RAMP_WIDTH
				var pos := Vector3(
					cos(angle) * r,
					y,
					sin(angle) * r
				)
				_voxel_tool.do_sphere(pos, RAMP_PAINT_RADIUS)
				frames_since_yield += 1

		if frames_since_yield >= yield_interval:
			frames_since_yield = 0
			await get_tree().process_frame

		y += ramp_step

	# Final yield to let mesh generation catch up
	await get_tree().process_frame
	await get_tree().process_frame


# ======================================================================
#  Carving (called by seed_world.create_crater)
# ======================================================================

func carve(world_pos: Vector3, radius: float) -> void:
	## Carve a sphere out of the tower's voxel data.
	## Called by seed_world when any explosion creates a crater.
	if _voxel_tool == null or not _is_built:
		return

	# Quick distance check — skip if explosion is far from tower
	var dist_to_tower := Vector2(
		world_pos.x - global_position.x,
		world_pos.z - global_position.z
	).length()
	if dist_to_tower > OUTER_RADIUS + radius + 2.0:
		return
	if world_pos.y < global_position.y - radius or world_pos.y > global_position.y + TOWER_HEIGHT + radius:
		return

	# Convert world position to voxel-data space (local to VoxelTerrain)
	var local_pos := world_pos - global_position
	print("[SpiralTower] Carving at local=%s radius=%.1f (world=%s)" % [
		str(local_pos), radius, str(world_pos)])
	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	_voxel_tool.do_sphere(local_pos, radius)

	# Check structural integrity (server only)
	if multiplayer.is_server() and _integrity_cooldown <= 0.0:
		_integrity_cooldown = INTEGRITY_CHECK_COOLDOWN
		_check_structural_integrity()


func carve_no_check(world_pos: Vector3, radius: float) -> void:
	## Carve without integrity check (used by clients receiving synced craters).
	if _voxel_tool == null:
		return
	var dist_to_tower := Vector2(
		world_pos.x - global_position.x,
		world_pos.z - global_position.z
	).length()
	if dist_to_tower > OUTER_RADIUS + radius + 2.0:
		return
	if world_pos.y < global_position.y - radius or world_pos.y > global_position.y + TOWER_HEIGHT + radius:
		return
	# Convert world position to voxel-data space (local to VoxelTerrain)
	var local_pos := world_pos - global_position
	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	_voxel_tool.do_sphere(local_pos, radius)


func set_last_attacker(attacker_id: int) -> void:
	_last_attacker_id = attacker_id


# ======================================================================
#  Structural integrity — Local Boundary BFS
# ======================================================================
#
# After an explosion carves voxels, we find solid voxels on the boundary
# of the carved region, then BFS through solid SDF data to check if those
# boundary voxels can still reach ground level. If any group of boundary
# voxels is disconnected from ground, we find the sever height and trigger
# collapse of everything above.
#
# This works for any cut shape: slanted, tunneled, or uneven.

func _check_structural_integrity() -> void:
	## Run ground-flood BFS to detect if the tower has been severed.
	## Called after each carve() on the server.
	##
	## Algorithm:
	##   1. Find a solid ground voxel (anchor).
	##   2. BFS flood from anchor through all connected solid voxels,
	##      tracking the max Y reached and building a visited set.
	##   3. Scan from the top of the tower downward for any solid voxel
	##      NOT in the visited set — if found, the tower is severed.
	##   4. Collapse at sever_y = max Y reached by ground BFS.
	if _collapse_in_progress or _voxel_tool == null:
		return

	# Step 1: Find ground anchor
	var ground_anchor := _find_ground_anchor()
	if ground_anchor == Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF):
		print("[SpiralTower] Integrity: NO ground anchor — base destroyed")
		var any_solid := _find_any_solid_above(GROUND_Y_TOLERANCE)
		if any_solid != Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF):
			_trigger_collapse_at_height(0.0)
		return

	# Step 2: BFS flood from ground — find everything connected to ground
	var flood_result := _bfs_flood_from_ground(ground_anchor)
	var visited: Dictionary = flood_result[0]
	var max_y_reached: int = flood_result[1]

	# Step 3: Scan from top downward for any solid voxel NOT in visited set
	var disconnected := _find_disconnected_above(visited, max_y_reached)

	if disconnected:
		var sever_y: float = (float(max_y_reached) + 1.5) * INTEGRITY_SAMPLE_STEP
		print("[SpiralTower] Integrity: SEVERED! sever_y=%.1f max_grid_y=%d effective_top=%.1f" % [
			sever_y, max_y_reached, _effective_tower_top])
		if sever_y > 0.0 and sever_y < _effective_tower_top:
			_trigger_collapse_at_height(sever_y)
	else:
		print("[SpiralTower] Integrity: connected (max_y_grid=%d)" % max_y_reached)


func _local_to_grid(local_pos: Vector3) -> Vector3i:
	## Convert local tower position to grid cell coordinates for BFS.
	## Local = relative to tower origin (0,0,0 = base center of tower).
	return Vector3i(
		int(floor(local_pos.x / INTEGRITY_SAMPLE_STEP)),
		int(floor(local_pos.y / INTEGRITY_SAMPLE_STEP)),
		int(floor(local_pos.z / INTEGRITY_SAMPLE_STEP))
	)


func _grid_to_local(grid_pos: Vector3i) -> Vector3:
	## Convert grid cell back to local tower position (cell center).
	return Vector3(
		(float(grid_pos.x) + 0.5) * INTEGRITY_SAMPLE_STEP,
		(float(grid_pos.y) + 0.5) * INTEGRITY_SAMPLE_STEP,
		(float(grid_pos.z) + 0.5) * INTEGRITY_SAMPLE_STEP
	)


func _is_solid_at_grid(grid_pos: Vector3i) -> bool:
	## Check if the voxel at the given grid position is solid (SDF < 0).
	var local_pos := _grid_to_local(grid_pos)
	# Quick bounds check — skip if outside tower bounding box
	if local_pos.y < -1.0 or local_pos.y > _effective_tower_top + 2.0:
		return false
	var horiz_dist_sq := local_pos.x * local_pos.x + local_pos.z * local_pos.z
	if horiz_dist_sq > (OUTER_RADIUS + 2.0) * (OUTER_RADIUS + 2.0):
		return false
	# get_voxel_f operates in voxel-data space (local to VoxelTerrain)
	var sdf: float = _voxel_tool.get_voxel_f(local_pos)
	return sdf < 0.0


func _grid_key(pos: Vector3i) -> int:
	## Flatten a Vector3i to a single int for fast Dictionary lookups.
	## Offset by 100 to handle negative coordinates.
	return (pos.x + 100) + (pos.y + 100) * 300 + (pos.z + 100) * 90000


## 6-connected neighbors (face-sharing only)
const _NEIGHBORS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


func _find_ground_anchor() -> Vector3i:
	## Find a solid voxel at ground level (within GROUND_Y_TOLERANCE of base).
	## Scans a grid at Y=0 within the core radius.
	## All positions are in local tower space (0,0,0 = base center).
	var step := INTEGRITY_SAMPLE_STEP
	var scan_radius := CORE_RADIUS
	var x := -scan_radius
	while x <= scan_radius:
		var z := -scan_radius
		while z <= scan_radius:
			if x * x + z * z <= scan_radius * scan_radius:
				var local_pos := Vector3(x, step * 0.5, z)
				var sdf: float = _voxel_tool.get_voxel_f(local_pos)
				if sdf < 0.0:
					return _local_to_grid(local_pos)
			z += step
		x += step
	return Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF)  # Not found sentinel


func _find_any_solid_above(min_height: float) -> Vector3i:
	## Find any solid voxel above min_height. Scans sparsely for speed.
	## All positions are in local tower space (0,0,0 = base center).
	var step := INTEGRITY_SAMPLE_STEP * 2.0  # Coarse scan
	var y := min_height
	while y <= _effective_tower_top:
		var x := -CORE_RADIUS
		while x <= CORE_RADIUS:
			var z := -CORE_RADIUS
			while z <= CORE_RADIUS:
				if x * x + z * z <= OUTER_RADIUS * OUTER_RADIUS:
					var local_pos := Vector3(x, y, z)
					var sdf: float = _voxel_tool.get_voxel_f(local_pos)
					if sdf < 0.0:
						return _local_to_grid(local_pos)
				z += step
			x += step
		y += step
	return Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF)


func _bfs_flood_from_ground(ground_anchor: Vector3i) -> Array:
	## BFS flood from ground anchor through all solid voxels reachable from ground.
	## Returns [visited_dict, max_y_grid_reached].
	var visited := {}
	var queue: Array[Vector3i] = [ground_anchor]
	visited[_grid_key(ground_anchor)] = true
	var max_y_reached: int = ground_anchor.y
	var iterations := 0

	while queue.size() > 0 and iterations < BFS_MAX_ITERATIONS:
		var current: Vector3i = queue.pop_front()
		iterations += 1
		if current.y > max_y_reached:
			max_y_reached = current.y

		for offset in _NEIGHBORS:
			var neighbor: Vector3i = current + offset
			var key := _grid_key(neighbor)
			if visited.has(key):
				continue
			if not _is_solid_at_grid(neighbor):
				continue
			visited[key] = true
			queue.push_back(neighbor)

	return [visited, max_y_reached]


func _find_disconnected_above(visited: Dictionary, max_y_reached: int) -> bool:
	## Scan from top of tower downward for any solid voxel NOT in the visited set.
	## If found, the tower is severed — that voxel is disconnected from ground.
	var step := INTEGRITY_SAMPLE_STEP
	var scan_y := _effective_tower_top
	# Start scanning from top, stop just above the max Y the ground BFS reached
	var min_scan_y: float = (float(max_y_reached) + 2.0) * step
	while scan_y >= min_scan_y:
		var x := -OUTER_RADIUS
		while x <= OUTER_RADIUS:
			var z := -OUTER_RADIUS
			while z <= OUTER_RADIUS:
				if x * x + z * z <= OUTER_RADIUS * OUTER_RADIUS:
					var local_pos := Vector3(x, scan_y, z)
					var sdf: float = _voxel_tool.get_voxel_f(local_pos)
					if sdf < 0.0:
						# Found a solid voxel — check if it was reached by ground BFS
						var grid := _local_to_grid(local_pos)
						var key := _grid_key(grid)
						if not visited.has(key):
							return true  # Disconnected!
				z += step
			x += step
		scan_y -= step
	return false  # Everything solid is connected to ground


func _trigger_collapse_at_height(sever_y: float) -> void:
	## Trigger collapse at the given local height above tower base.
	_trigger_collapse_internal(sever_y)


# ======================================================================
#  Collapse orchestration
# ======================================================================

func _trigger_collapse_internal(sever_y: float) -> void:
	## Begin the collapse sequence at the given local sever height.
	_collapse_in_progress = true

	var section_height: float = _effective_tower_top - sever_y
	if section_height < 2.0:
		_collapse_in_progress = false
		return  # Too small a section to bother collapsing

	print("[SpiralTower] Collapse triggered at height %.1fm (section: %.1fm)" % [
		sever_y, section_height])

	# Generate a random torque direction for the topple
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var torque_dir := Vector3(
		rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)
	).normalized()

	# Bake the upper section mesh BEFORE erasing it from the voxel terrain.
	# This extracts the actual voxel mesh so the topple body looks like the real tower.
	var baked_mesh := _bake_upper_section_mesh(sever_y)

	# Compute the mesh offset: the baked mesh vertices are in buffer-local space,
	# where (0,0,0) = the region_min corner we used for VoxelTool.copy().
	# region_min was: (-extent - pad, sever_y - pad, -extent - pad)
	# We need to offset the MeshInstance3D so the mesh aligns with the topple body center.
	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var extent := OUTER_RADIUS + 2.0
	var region_min_local := Vector3(
		float(int(floor(-extent)) - min_pad),
		float(int(floor(sever_y)) - min_pad),
		float(int(floor(-extent)) - min_pad)
	)

	# The topple body will be positioned at the centroid of the severed section
	# in world space. The mesh needs to be offset from the body center so it
	# renders in the correct position.
	# Body centroid in local tower space = (0, sever_y + section_height/2, 0)
	# Mesh vertex world_local = vertex_buffer_pos + region_min_local
	# Mesh offset from body center = region_min_local - (0, sever_y + section_height/2, 0)
	var body_center_local := Vector3(0.0, sever_y + section_height * 0.5, 0.0)
	var mesh_offset := region_min_local - body_center_local

	# Pre-bake chunk fragment meshes BEFORE erasing (so we have real voxel data)
	var chunk_count := clampi(4 + int(section_height / 10.0), 4, 10)
	_bake_chunk_meshes(sever_y, section_height, chunk_count)

	# Erase the upper section from the voxel terrain
	_erase_above(sever_y)
	_effective_tower_top = sever_y  # Tower is now shorter

	# Spawn the topple body at the section centroid in world space
	var centroid := global_position + body_center_local
	_spawn_topple_body(centroid, baked_mesh, mesh_offset, section_height, torque_dir)

	# Sync to clients — send chunk_count so clients bake matching fragments
	_sync_collapse_start.rpc(sever_y, torque_dir, chunk_count)

	_collapse_in_progress = false


func _bake_upper_section_mesh(sever_y: float) -> Mesh:
	## Extract the actual voxel mesh of the upper tower section using the mesher.
	## This copies the SDF data into a VoxelBuffer, then uses VoxelMesherTransvoxel
	## to build the real mesh — so the topple body looks exactly like the tower.
	##
	## Returns the mesh with vertices centered around (0, section_height/2, 0)
	## relative to the sever point.
	if _voxel_tool == null:
		return _bake_fallback_cylinder_mesh(sever_y)

	var section_height: float = _effective_tower_top - sever_y

	# The mesher needs padding around the data to produce correct surface normals
	# at the edges. Get the padding requirements from the mesher.
	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var max_pad: int = mesher.get_maximum_padding()

	# Define the region to copy in voxel-data space (local to VoxelTerrain).
	# The tower spans from roughly (-OUTER_RADIUS, 0, -OUTER_RADIUS) to
	# (OUTER_RADIUS, TOWER_HEIGHT, OUTER_RADIUS) in local coords.
	var extent := OUTER_RADIUS + 2.0  # Slight margin beyond tower radius
	var region_min := Vector3i(
		int(floor(-extent)) - min_pad,
		int(floor(sever_y)) - min_pad,
		int(floor(-extent)) - min_pad
	)
	var region_max := Vector3i(
		int(ceil(extent)) + max_pad,
		int(ceil(sever_y + section_height)) + max_pad,
		int(ceil(extent)) + max_pad
	)

	var buf_size: Vector3i = region_max - region_min
	if buf_size.x <= 0 or buf_size.y <= 0 or buf_size.z <= 0:
		return _bake_fallback_cylinder_mesh(sever_y)

	# Create buffer and copy SDF data from the tower VoxelTerrain
	var buffer := VoxelBuffer.new()
	buffer.create(buf_size.x, buf_size.y, buf_size.z)

	# Copy the SDF channel from the terrain into our buffer.
	# VoxelTool.copy(src_pos, dst_buffer, channels_mask) copies a box of voxels
	# starting at src_pos with the size of dst_buffer.
	var sdf_channel_mask: int = 1 << VoxelBuffer.CHANNEL_SDF
	_voxel_tool.copy(region_min, buffer, sdf_channel_mask)

	# Build the mesh using the same mesher type as the terrain
	var materials: Array[Material] = [_tower_material]
	var built_mesh: Mesh = mesher.build_mesh(buffer, materials)
	if built_mesh == null or built_mesh.get_surface_count() == 0:
		print("[SpiralTower] Mesh extraction failed — using fallback cylinder")
		return _bake_fallback_cylinder_mesh(sever_y)

	# The mesh vertices are in buffer-local space (0,0,0 = region_min corner).
	# We need to offset them so the mesh is centered around (0, section_height/2, 0)
	# for the topple body. The offset from buffer origin to tower local center is:
	#   buffer_origin_in_local = region_min
	#   tower_center_at_sever = (0, sever_y + section_height/2, 0)
	# So vertex_world_local = vertex_buffer + region_min
	# We want vertex_mesh = vertex_world_local - tower_center_at_sever
	# = vertex_buffer + region_min - (0, sever_y + section_height/2, 0)
	# We'll store this offset and apply it via MeshInstance3D position instead.
	# (Stored as _mesh_offset on the topple body via metadata or as a child offset)
	print("[SpiralTower] Baked real voxel mesh (surfaces: %d, buf_size: %s)" % [
		built_mesh.get_surface_count(), str(buf_size)])
	return built_mesh


func _bake_fallback_cylinder_mesh(sever_y: float) -> ArrayMesh:
	## Fallback: create a simple cylindrical mesh if voxel mesh extraction fails.
	var section_height: float = _effective_tower_top - sever_y
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 16
	var radius := CORE_RADIUS + RAMP_WIDTH * 0.5
	var half_h := section_height * 0.5

	for i in segments:
		var angle0 := float(i) / float(segments) * TAU
		var angle1 := float(i + 1) / float(segments) * TAU

		var x0 := cos(angle0) * radius
		var z0 := sin(angle0) * radius
		var x1 := cos(angle1) * radius
		var z1 := sin(angle1) * radius

		var bl := Vector3(x0, -half_h, z0)
		var br := Vector3(x1, -half_h, z1)
		var tl := Vector3(x0, half_h, z0)
		var top_r := Vector3(x1, half_h, z1)

		var normal := Vector3(cos((angle0 + angle1) * 0.5), 0, sin((angle0 + angle1) * 0.5))
		st.set_normal(normal)

		st.add_vertex(bl)
		st.add_vertex(br)
		st.add_vertex(top_r)

		st.add_vertex(bl)
		st.add_vertex(top_r)
		st.add_vertex(tl)

		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(0, half_h, 0))
		st.add_vertex(tl)
		st.add_vertex(top_r)

		st.set_normal(Vector3.DOWN)
		st.add_vertex(Vector3(0, -half_h, 0))
		st.add_vertex(br)
		st.add_vertex(bl)

	st.commit(mesh)
	return mesh


func _bake_chunk_meshes(sever_y: float, section_height: float, chunk_count: int) -> void:
	## Pre-bake fragment meshes by subdividing the upper tower section into
	## vertical slices (like pie slices) and extracting each as a real voxel mesh.
	## Must be called BEFORE _erase_above() so the voxel data is still present.
	_cached_chunk_meshes.clear()
	_cached_chunk_offsets.clear()

	if _voxel_tool == null:
		return

	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var max_pad: int = mesher.get_maximum_padding()

	# Divide the section into vertical slices (angular pie slices).
	# Each chunk covers a portion of the tower's angular range and a vertical band.
	@warning_ignore("integer_division")
	var vertical_splits := maxi(1, chunk_count / 3)  # 1-3 vertical bands
	@warning_ignore("integer_division")
	var angular_splits := maxi(2, chunk_count / vertical_splits)  # 2-4 angular slices per band

	var band_height := section_height / float(vertical_splits)
	var slice_angle := TAU / float(angular_splits)
	var extent := OUTER_RADIUS + 1.0  # Capture full tower width

	for v_i in vertical_splits:
		var band_bottom := sever_y + float(v_i) * band_height
		var band_top := band_bottom + band_height

		for a_i in angular_splits:
			var angle_start := float(a_i) * slice_angle
			var angle_end := angle_start + slice_angle
			var angle_center := (angle_start + angle_end) * 0.5

			# For each chunk, we copy a box region from voxel data and blank out
			# the voxels outside this chunk's angular slice to isolate it.
			# The box covers the full XZ extent but only this vertical band.
			var region_min := Vector3i(
				int(floor(-extent)) - min_pad,
				int(floor(band_bottom)) - min_pad,
				int(floor(-extent)) - min_pad
			)
			var region_max := Vector3i(
				int(ceil(extent)) + max_pad,
				int(ceil(band_top)) + max_pad,
				int(ceil(extent)) + max_pad
			)

			var buf_size: Vector3i = region_max - region_min
			if buf_size.x <= 0 or buf_size.y <= 0 or buf_size.z <= 0:
				continue

			# Copy SDF data from the tower
			var buffer := VoxelBuffer.new()
			buffer.create(buf_size.x, buf_size.y, buf_size.z)
			var sdf_mask: int = 1 << VoxelBuffer.CHANNEL_SDF
			_voxel_tool.copy(region_min, buffer, sdf_mask)

			# Blank out voxels outside our angular slice by setting SDF to positive (air).
			# We iterate through the buffer and check each voxel's angle.
			for bx in buf_size.x:
				for bz in buf_size.z:
					# Convert buffer coords to local tower coords
					var local_x: float = float(region_min.x + bx) + 0.5
					var local_z: float = float(region_min.z + bz) + 0.5
					var voxel_angle := atan2(local_z, local_x)  # -PI to PI
					if voxel_angle < 0.0:
						voxel_angle += TAU  # 0 to TAU

					# Check if this voxel's angle falls within our slice
					var in_slice := false
					# Handle angle wrapping
					if angle_end <= TAU:
						in_slice = voxel_angle >= angle_start and voxel_angle < angle_end
					else:
						# Slice wraps around TAU
						in_slice = voxel_angle >= angle_start or voxel_angle < fmod(angle_end, TAU)

					if not in_slice:
						# Blank this entire column in Y
						for by in buf_size.y:
							buffer.set_voxel_f(1.0, bx, by, bz, VoxelBuffer.CHANNEL_SDF)

			# Build mesh from the isolated chunk data
			var materials: Array[Material] = [_tower_material]
			var chunk_mesh: Mesh = mesher.build_mesh(buffer, materials)
			if chunk_mesh != null and chunk_mesh.get_surface_count() > 0:
				_cached_chunk_meshes.append(chunk_mesh)
				# Offset: mesh vertices are in buffer-local space (0,0,0 = region_min)
				# Chunk center in local tower space:
				var chunk_center_local := Vector3(
					cos(angle_center) * CORE_RADIUS * 0.5,
					(band_bottom + band_top) * 0.5,
					sin(angle_center) * CORE_RADIUS * 0.5
				)
				var mesh_offset := Vector3(float(region_min.x), float(region_min.y), float(region_min.z)) - chunk_center_local
				_cached_chunk_offsets.append(mesh_offset)

	# If we got fewer meshes than expected (some slices had no solid data), fill with fallback
	if _cached_chunk_meshes.size() == 0:
		print("[SpiralTower] Chunk bake: no fragments extracted, will use rock fallback")
	else:
		print("[SpiralTower] Chunk bake: %d fragment meshes extracted" % _cached_chunk_meshes.size())


func _erase_above(sever_y: float) -> void:
	## Remove all voxel data above the sever height from the tower terrain.
	## All positions in local voxel-data space (0,0,0 = tower base center).
	if _voxel_tool == null:
		return

	_voxel_tool.mode = VoxelTool.MODE_REMOVE
	var erase_radius := OUTER_RADIUS + 2.0
	var y := sever_y
	var top := TOWER_HEIGHT + 4.0

	# Paint overlapping removal spheres from sever point to top
	while y <= top:
		_voxel_tool.do_sphere(Vector3(0.0, y, 0.0), erase_radius)
		y += erase_radius * 0.8  # Overlap for clean removal


func _spawn_topple_body(centroid: Vector3, baked_mesh: Mesh, mesh_offset: Vector3,
		section_height: float, torque_dir: Vector3) -> void:
	## Create the RigidBody3D that represents the toppling upper section.
	## baked_mesh: the actual voxel mesh extracted from the tower
	## mesh_offset: offset from body center to mesh origin (for correct visual alignment)
	var topple := RigidBody3D.new()
	topple.name = "TowerToppleBody"
	topple.set_script(TowerToppleBodyScript)

	# Collision shape: simplified convex hull (cylinder approximation)
	var col_shape := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = OUTER_RADIUS * 0.8
	shape.height = section_height
	col_shape.shape = shape
	topple.add_child(col_shape)

	# Visual mesh — positioned with offset so the real voxel mesh aligns properly
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = baked_mesh
	mesh_inst.position = mesh_offset  # Offset from body center to align mesh
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Material is already baked into the mesh from build_mesh(), but set override as fallback
	mesh_inst.material_override = _tower_material
	topple.add_child(mesh_inst)

	# Physics properties
	topple.mass = section_height * 200.0
	topple.continuous_cd = true
	topple.contact_monitor = true
	topple.max_contacts_reported = 4
	topple.gravity_scale = 1.0
	topple.collision_layer = 1
	topple.collision_mask = 1

	# Set custom properties BEFORE adding to tree (these are simple vars, not transforms)
	topple.section_height = section_height
	topple.attacker_id = _last_attacker_id
	topple.tower_position = global_position

	# FIX: Add to scene tree FIRST, then set global_position.
	# Setting global_position requires is_inside_tree() == true.
	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(topple)
		topple.global_position = centroid
	else:
		topple.position = centroid  # Fallback (shouldn't happen)

	# Apply strong torque for dramatic tipping — needs to overcome the mass
	# (mass = section_height * 200, so torque must scale with mass)
	var torque_strength := topple.mass * section_height * 2.0
	topple.apply_torque_impulse(torque_dir * torque_strength)
	# Lateral push to get it moving sideways
	var push_strength := topple.mass * 1.5
	topple.apply_central_impulse(torque_dir * push_strength)

	print("[SpiralTower] Topple body spawned (mass: %.0f, height: %.1fm, torque: %.0f)" % [
		topple.mass, section_height, torque_strength])


# ======================================================================
#  Rock mesh generation for chunks
# ======================================================================

func _generate_rock_mesh(size: float, seed_val: int) -> ArrayMesh:
	## Generate an irregular rock-shaped mesh by deforming a sphere.
	## Each rock looks unique based on the seed value.
	var mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val * 7919 + 12345  # Deterministic per chunk

	# Generate a deformed icosphere-like shape using lat/lon subdivision
	var lat_steps := 6
	var lon_steps := 8
	var half_size := size * 0.5

	# Pre-compute deformed vertices on the sphere surface
	var verts: Array[Vector3] = []
	for lat_i in lat_steps + 1:
		var lat_frac := float(lat_i) / float(lat_steps)
		var phi := lat_frac * PI  # 0 to PI (top to bottom)

		for lon_i in lon_steps:
			var lon_frac := float(lon_i) / float(lon_steps)
			var theta := lon_frac * TAU  # 0 to TAU

			# Base sphere point
			var nx := sin(phi) * cos(theta)
			var ny := cos(phi)
			var nz := sin(phi) * sin(theta)

			# Deform: random radius variation for rocky look
			# More variation near the equator, less at poles
			var equator_factor := sin(phi)  # 0 at poles, 1 at equator
			var deform := rng.randf_range(0.7, 1.3) * (0.6 + 0.4 * equator_factor)
			var r := half_size * deform

			verts.append(Vector3(nx * r, ny * r, nz * r))

	# Build triangles from the vertex grid
	for lat_i in lat_steps:
		for lon_i in lon_steps:
			var next_lon := (lon_i + 1) % lon_steps

			var i0 := lat_i * lon_steps + lon_i
			var i1 := lat_i * lon_steps + next_lon
			var i2 := (lat_i + 1) * lon_steps + lon_i
			var i3 := (lat_i + 1) * lon_steps + next_lon

			if i0 < verts.size() and i1 < verts.size() and i2 < verts.size() and i3 < verts.size():
				# Compute face normal for flat shading
				var edge1 := verts[i1] - verts[i0]
				var edge2 := verts[i2] - verts[i0]
				var normal := edge1.cross(edge2).normalized()
				if normal.length() < 0.001:
					normal = Vector3.UP
				st.set_normal(normal)

				# Triangle 1
				st.add_vertex(verts[i0])
				st.add_vertex(verts[i2])
				st.add_vertex(verts[i1])

				# Triangle 2
				edge1 = verts[i3] - verts[i1]
				edge2 = verts[i2] - verts[i1]
				normal = edge1.cross(edge2).normalized()
				if normal.length() < 0.001:
					normal = Vector3.UP
				st.set_normal(normal)

				st.add_vertex(verts[i1])
				st.add_vertex(verts[i2])
				st.add_vertex(verts[i3])

	st.commit(mesh)
	return mesh


# ======================================================================
#  RPCs
# ======================================================================

@rpc("authority", "call_remote", "reliable")
func _sync_collapse_start(sever_y: float, torque_dir: Vector3, chunk_count: int = 6) -> void:
	## Client-side: extract real mesh, erase upper section, spawn visual-only topple body.
	var section_height: float = _effective_tower_top - sever_y
	if section_height < 2.0:
		section_height = TOWER_HEIGHT - sever_y  # Fallback for client

	# Bake visual mesh BEFORE erasing (so we capture the actual tower shape)
	var baked_mesh := _bake_upper_section_mesh(sever_y)

	# Pre-bake chunk fragment meshes BEFORE erasing (clients need them too)
	_bake_chunk_meshes(sever_y, section_height, chunk_count)

	# Compute mesh offset (same logic as server)
	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var extent := OUTER_RADIUS + 2.0
	var region_min_local := Vector3(
		float(int(floor(-extent)) - min_pad),
		float(int(floor(sever_y)) - min_pad),
		float(int(floor(-extent)) - min_pad)
	)
	var body_center_local := Vector3(0.0, sever_y + section_height * 0.5, 0.0)
	var mesh_offset := region_min_local - body_center_local

	# Now erase the upper section visually
	_erase_above(sever_y)
	_effective_tower_top = sever_y

	# Spawn visual-only topple body (no contact monitoring / damage)
	var centroid := global_position + body_center_local

	var topple := RigidBody3D.new()
	topple.name = "TowerToppleBody_Visual"

	var col_shape := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = OUTER_RADIUS * 0.8
	shape.height = section_height
	col_shape.shape = shape
	topple.add_child(col_shape)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = baked_mesh
	mesh_inst.position = mesh_offset
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mesh_inst.material_override = _tower_material
	topple.add_child(mesh_inst)

	topple.mass = section_height * 200.0
	topple.continuous_cd = true
	topple.gravity_scale = 1.0
	topple.collision_layer = 1
	topple.collision_mask = 1

	# FIX: Add to tree FIRST, then set global_position
	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(topple)
		topple.global_position = centroid

	# Match server-side forces for consistent visual
	var torque_strength := topple.mass * section_height * 2.0
	topple.apply_torque_impulse(torque_dir * torque_strength)
	var push_strength := topple.mass * 1.5
	topple.apply_central_impulse(torque_dir * push_strength)

	# Auto-cleanup after 15 seconds (client visual only)
	var timer := Timer.new()
	timer.wait_time = 15.0
	timer.one_shot = true
	timer.timeout.connect(topple.queue_free)
	topple.add_child(timer)
	timer.start()


@rpc("authority", "call_local", "reliable")
func _sync_collapse_impact(impact_pos: Vector3, _impact_velocity: Vector3,
		chunk_count: int, chunk_sizes: Array, chunk_impulses: Array) -> void:
	## All clients + server: spawn chunk debris at impact point.
	## Uses pre-baked voxel fragment meshes when available, falls back to rock shapes.
	## Server chunks have damage logic (via tower_chunk.gd).
	## Client chunks are cosmetic RigidBody3Ds.
	var is_server := multiplayer.is_server()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.42, 0.40)

	var has_real_fragments := _cached_chunk_meshes.size() > 0

	for i in chunk_count:
		var chunk_size: float = chunk_sizes[i] if i < chunk_sizes.size() else 1.5
		var chunk_impulse: Vector3 = chunk_impulses[i] if i < chunk_impulses.size() else Vector3.UP * 5.0

		var chunk := RigidBody3D.new()
		chunk.name = "TowerChunk_%d" % i

		if is_server:
			chunk.set_script(TowerChunkScript)

		# Collision — use a convex hull approximation (sphere is cheapest)
		var col := CollisionShape3D.new()
		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = chunk_size * 0.5
		col.shape = sphere_shape
		chunk.add_child(col)

		# Visual — use real voxel fragment if available, else fallback to rock shape
		var mesh_inst := MeshInstance3D.new()
		if has_real_fragments:
			# Cycle through cached fragments (wrap index if more chunks than fragments)
			var frag_idx := i % _cached_chunk_meshes.size()
			mesh_inst.mesh = _cached_chunk_meshes[frag_idx]
			mesh_inst.position = _cached_chunk_offsets[frag_idx]
		else:
			mesh_inst.mesh = _generate_rock_mesh(chunk_size, i)
		mesh_inst.material_override = mat
		chunk.add_child(mesh_inst)

		# Physics
		chunk.mass = chunk_size * chunk_size * chunk_size * 50.0  # Volume-based mass
		chunk.continuous_cd = true
		chunk.gravity_scale = 1.0
		chunk.collision_layer = 1
		chunk.collision_mask = 1

		if is_server:
			chunk.contact_monitor = true
			chunk.max_contacts_reported = 4
			chunk.chunk_mass = chunk.mass / 200.0  # Normalized mass for damage calc
			chunk.attacker_id = _last_attacker_id

		# FIX: Add to tree FIRST, then set global_position (requires is_inside_tree)
		scene_root.add_child(chunk)
		chunk.global_position = impact_pos + Vector3(
			randf_range(-2.0, 2.0), chunk_size * 0.5, randf_range(-2.0, 2.0)
		)

		chunk.apply_central_impulse(chunk_impulse)
		chunk.apply_torque_impulse(Vector3(
			randf_range(-5.0, 5.0),
			randf_range(-5.0, 5.0),
			randf_range(-5.0, 5.0)
		))

		# Auto-cleanup
		var timer := Timer.new()
		timer.wait_time = 12.0
		timer.one_shot = true
		timer.timeout.connect(chunk.queue_free)
		chunk.add_child(timer)
		timer.start()

	# Clear cached meshes after use (free memory)
	_cached_chunk_meshes.clear()
	_cached_chunk_offsets.clear()
