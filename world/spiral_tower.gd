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
## SDF threshold for structural solidity. Values just below 0.0 (e.g. -0.05)
## represent the very edge of the surface — too thin/weak to hold up a tower.
## Only voxels with SDF well below zero are structurally load-bearing.
const STRUCTURAL_SDF_THRESHOLD := -0.3

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
## Cached slab meshes baked at collapse time (before voxel erasure).
## Each is a real voxel mesh of a horizontal slice of the collapsing section.
var _cached_slab_meshes: Array[Mesh] = []
## Offset of each slab's buffer origin relative to the topple body center (local space).
var _cached_slab_offsets: Array[Vector3] = []
## Pre-built collision shapes for each slab (centered BoxShape3D).
var _cached_slab_shapes: Array[Shape3D] = []
## AABB center of each slab mesh in buffer-local space. Used to offset
## MeshInstance3D and CollisionShape3D so they're centered on the RigidBody3D.
var _cached_slab_mesh_centers: Array[Vector3] = []
## The body_center_local used when spawning the topple body.
var _cached_body_center_local: Vector3 = Vector3.ZERO

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
	_tower_material.roughness = 0.85
	_tower_material.metallic = 0.0
	# Cull disabled = render both sides of every triangle. This prevents
	# see-through holes at mesh boundaries where Transvoxel may not generate
	# back-faces (e.g. top/bottom of slabs, carved surfaces, buffer edges).
	_tower_material.cull_mode = BaseMaterial3D.CULL_DISABLED

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
	# Since do_sphere() uses local coords (relative to the VoxelTerrain), bounds
	# must cover the local tower volume. The tower is ~11m radius, 40m tall.
	# Using tight bounds so fewer blocks need to be loaded by the streaming system.
	# Block size is 16, so we need blocks covering roughly -16 to +16 in XZ
	# and -16 to +48 in Y. Round to block boundaries with some margin.
	_voxel_terrain.bounds = AABB(
		Vector3(-32, -16, -32),
		Vector3(64, 80, 64)
	)

	_voxel_terrain.material_override = _tower_material
	add_child(_voxel_terrain)

	# VoxelTerrain requires a VoxelViewer to know which blocks to stream/load.
	# In the lobby flow, no players (and therefore no cameras/viewers) exist yet,
	# so the streaming system has nothing to target and loads zero blocks.
	# We add a temporary VoxelViewer at the tower position during construction,
	# then remove it after painting is complete.
	#
	# Position the viewer at the center of the tower bounds so it covers the
	# full volume, and set view_distance large enough to reach every corner.
	var _temp_viewer: Node3D = null
	if ClassDB.class_exists(&"VoxelViewer"):
		_temp_viewer = ClassDB.instantiate(&"VoxelViewer")
		_temp_viewer.name = "TempBuildViewer"
		# Center of tower volume: (0, TOWER_HEIGHT/2, 0) in local space
		_temp_viewer.position = Vector3(0.0, TOWER_HEIGHT * 0.5, 0.0)
		# View distance must cover from viewer to the farthest corner of the bounds.
		# Bounds: -32 to +32 in XZ, -16 to +64 in Y. Viewer at (0, 20, 0).
		# Farthest corner: (32, 64, 32) → distance ≈ 58. Use 80 for margin.
		if _temp_viewer.has_method("set_view_distance"):
			_temp_viewer.set_view_distance(80)
		elif "view_distance" in _temp_viewer:
			_temp_viewer.view_distance = 80
		_voxel_terrain.add_child(_temp_viewer)
		print("[SpiralTower] Added temporary VoxelViewer at center for block streaming")

	# Wait for the streaming system to load all blocks the tower needs.
	# We use is_area_editable() which checks the exact same code path that
	# do_sphere() uses internally. This is reliable — unlike get_voxel_f()
	# which has a generator fallback and returns valid data for unloaded blocks.
	_voxel_tool = _voxel_terrain.get_voxel_tool()
	var max_wait := 300  # Up to 5 seconds at 60fps
	var blocks_ready := false
	# Build the AABB that covers the entire tower painting volume.
	# do_sphere() at the farthest ramp point + radius must be within this box.
	var paint_extent := OUTER_RADIUS + RAMP_PAINT_RADIUS + 1.0  # ~7.7m
	var tower_aabb := AABB(
		Vector3(-paint_extent, -CORE_PAINT_RADIUS - 1.0, -paint_extent),
		Vector3(paint_extent * 2.0, TOWER_HEIGHT + CORE_PAINT_RADIUS + 2.0, paint_extent * 2.0)
	)
	for i in max_wait:
		await get_tree().process_frame
		_voxel_tool = _voxel_terrain.get_voxel_tool()
		if _voxel_tool != null:
			if _voxel_tool.is_area_editable(tower_aabb):
				blocks_ready = true
				print("[SpiralTower] All blocks editable after %d frames (AABB: %s)" % [
					i, str(tower_aabb)])
				break
		if i > 0 and i % 60 == 0:
			print("[SpiralTower] Still waiting for blocks to load... (frame %d)" % i)

	if _voxel_tool == null:
		push_error("[SpiralTower] Failed to get VoxelTool — tower won't generate!")
		if _temp_viewer:
			_temp_viewer.queue_free()
		generation_complete.emit()
		return

	if not blocks_ready:
		push_warning("[SpiralTower] Blocks may not be fully loaded after %d frames — attempting paint anyway" % max_wait)

	print("[SpiralTower] Painting tower at global_position=%s" % str(global_position))

	# Paint the spiral shape using spheres along the core and ramp paths
	await _paint_tower_shape()

	# Remove the temporary viewer — once painted, the tower data is stored
	# by VoxelStreamMemory and no longer needs active streaming.
	if _temp_viewer and is_instance_valid(_temp_viewer):
		_temp_viewer.queue_free()
		print("[SpiralTower] Removed temporary VoxelViewer")

	_is_built = true
	generation_complete.emit()
	print("[SpiralTower] Tower built at %s (height: %.0fm)" % [str(global_position), TOWER_HEIGHT])


func _paint_tower_shape() -> void:
	## Paint the tower shape into the VoxelTerrain using do_sphere(MODE_ADD).
	## This creates a blobby but solid spiral structure.
	##
	## COORDINATE NOTE: VoxelToolTerrain interprets positions in voxel-data space
	## which does NOT include the node's transform. The rendered mesh IS transformed
	## by the node's global transform. So painting at local (0, y, 0) ends up at
	## world = SpiralTower.global_pos + (0, y, 0).
	##
	## If a do_sphere() call hits an unloaded block, it silently fails. We collect
	## failed positions and retry them once at the end after yielding to let
	## the streaming system catch up.
	if _voxel_tool == null:
		return

	_voxel_tool.mode = VoxelTool.MODE_ADD
	var frames_since_yield := 0
	var yield_interval := 20  # Yield every N sphere operations
	var _failed_spheres: Array[Vector2] = []  # [x=radius, encoded pos index] — see retry below
	var _failed_positions: Array[Vector3] = []
	var _failed_radii: Array[float] = []

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
			# Check editability before painting — queue for retry if not editable
			var sphere_aabb := AABB(pos - Vector3.ONE * CORE_PAINT_RADIUS, Vector3.ONE * CORE_PAINT_RADIUS * 2.0)
			if _voxel_tool.is_area_editable(sphere_aabb):
				_voxel_tool.do_sphere(pos, CORE_PAINT_RADIUS)
			else:
				_failed_positions.append(pos)
				_failed_radii.append(CORE_PAINT_RADIUS)
			frames_since_yield += 1

		# Center sphere for solid core
		var center_pos := Vector3(0, y, 0)
		var center_aabb := AABB(center_pos - Vector3.ONE * CORE_PAINT_RADIUS, Vector3.ONE * CORE_PAINT_RADIUS * 2.0)
		if _voxel_tool.is_area_editable(center_aabb):
			_voxel_tool.do_sphere(center_pos, CORE_PAINT_RADIUS)
		else:
			_failed_positions.append(center_pos)
			_failed_radii.append(CORE_PAINT_RADIUS)
		frames_since_yield += 1

		if frames_since_yield >= yield_interval:
			frames_since_yield = 0
			await get_tree().process_frame
			# Re-acquire VoxelTool after yield — streaming may have loaded new blocks
			_voxel_tool = _voxel_terrain.get_voxel_tool()
			_voxel_tool.mode = VoxelTool.MODE_ADD

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
				var sphere_aabb := AABB(pos - Vector3.ONE * RAMP_PAINT_RADIUS, Vector3.ONE * RAMP_PAINT_RADIUS * 2.0)
				if _voxel_tool.is_area_editable(sphere_aabb):
					_voxel_tool.do_sphere(pos, RAMP_PAINT_RADIUS)
				else:
					_failed_positions.append(pos)
					_failed_radii.append(RAMP_PAINT_RADIUS)
				frames_since_yield += 1

		if frames_since_yield >= yield_interval:
			frames_since_yield = 0
			await get_tree().process_frame
			# Re-acquire VoxelTool after yield — streaming may have loaded new blocks
			_voxel_tool = _voxel_terrain.get_voxel_tool()
			_voxel_tool.mode = VoxelTool.MODE_ADD

		y += ramp_step

	# --- Retry failed spheres ---
	# Some blocks may not have been loaded during the main pass. After yielding
	# a few frames the streaming system has had time to load them.
	if _failed_positions.size() > 0:
		print("[SpiralTower] Retrying %d failed sphere operations..." % _failed_positions.size())
		# Yield several frames to give streaming time to catch up
		for _retry_wait in 10:
			await get_tree().process_frame
		_voxel_tool = _voxel_terrain.get_voxel_tool()
		_voxel_tool.mode = VoxelTool.MODE_ADD

		var still_failed := 0
		frames_since_yield = 0
		for idx in _failed_positions.size():
			var pos: Vector3 = _failed_positions[idx]
			var radius: float = _failed_radii[idx]
			var sphere_aabb := AABB(pos - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
			if _voxel_tool.is_area_editable(sphere_aabb):
				_voxel_tool.do_sphere(pos, radius)
			else:
				still_failed += 1
			frames_since_yield += 1
			if frames_since_yield >= yield_interval:
				frames_since_yield = 0
				await get_tree().process_frame
				_voxel_tool = _voxel_terrain.get_voxel_tool()
				_voxel_tool.mode = VoxelTool.MODE_ADD

		if still_failed > 0:
			push_warning("[SpiralTower] %d spheres still not editable after retry" % still_failed)
		else:
			print("[SpiralTower] All retried spheres painted successfully")

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
		return

	# Step 4: Cross-section area check — even if BFS finds a path from ground
	# to top, an angular/diagonal cut can leave a thin pillar that should not
	# support the tower. Scan each Y layer and count solid cells. If any layer
	# has too few solid cells, the tower is too weak at that height.
	var weak_y := _find_weak_cross_section(visited, max_y_reached)
	if weak_y >= 0.0:
		print("[SpiralTower] Integrity: WEAK cross-section at y=%.1f — collapsing" % weak_y)
		if weak_y > 0.0 and weak_y < _effective_tower_top:
			_trigger_collapse_at_height(weak_y)
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
	## Check if the voxel at the given grid position is structurally solid.
	## Uses STRUCTURAL_SDF_THRESHOLD (-0.3) rather than the surface boundary (0.0)
	## so that thin bridges of barely-solid SDF data (common after diagonal cuts
	## or overlapping explosions) are NOT treated as load-bearing structure.
	## A voxel right at the surface edge (-0.05) should not hold up the tower.
	var local_pos := _grid_to_local(grid_pos)
	# Quick bounds check — skip if outside tower bounding box
	if local_pos.y < -1.0 or local_pos.y > _effective_tower_top + 2.0:
		return false
	var horiz_dist_sq := local_pos.x * local_pos.x + local_pos.z * local_pos.z
	if horiz_dist_sq > (OUTER_RADIUS + 2.0) * (OUTER_RADIUS + 2.0):
		return false
	# get_voxel_f operates in voxel-data space (local to VoxelTerrain)
	var sdf: float = _voxel_tool.get_voxel_f(local_pos)
	return sdf < STRUCTURAL_SDF_THRESHOLD


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
	## Find a structurally solid voxel at ground level (within GROUND_Y_TOLERANCE of base).
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
				if sdf < STRUCTURAL_SDF_THRESHOLD:
					return _local_to_grid(local_pos)
			z += step
		x += step
	return Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF)  # Not found sentinel


func _find_any_solid_above(min_height: float) -> Vector3i:
	## Find any structurally solid voxel above min_height. Scans sparsely for speed.
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
					if sdf < STRUCTURAL_SDF_THRESHOLD:
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
	## Uses the same structural SDF threshold as the BFS so both agree on what's solid.
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
					if sdf < STRUCTURAL_SDF_THRESHOLD:
						# Found a structurally solid voxel — check if ground BFS reached it
						var grid := _local_to_grid(local_pos)
						var key := _grid_key(grid)
						if not visited.has(key):
							return true  # Disconnected!
				z += step
			x += step
		scan_y -= step
	return false  # Everything solid is connected to ground


func _find_weak_cross_section(visited: Dictionary, max_y_reached: int) -> float:
	## Scan each Y layer of the tower and count solid cells connected to ground.
	## If any layer has fewer solid cells than the minimum required, the tower
	## is structurally compromised — it can't support the weight above.
	##
	## Returns the Y height where the tower is weakest, or -1.0 if no weak point.
	##
	## The tower core is ~3.0m radius. At INTEGRITY_SAMPLE_STEP = 1.0m, a full
	## cross-section of the core is roughly PI * 3^2 = ~28 cells. The ramp adds
	## more, but it spirals so it's not present at all angles at a given height.
	## A minimum of 4 cells (~14% of core area) means the tower is nearly cut through.
	const MIN_SOLID_CELLS_PER_LAYER := 4
	var step := INTEGRITY_SAMPLE_STEP
	var weakest_y := -1.0
	var weakest_count := 999

	# Only check layers above ground level, up to the max Y the BFS reached.
	# Below ground is the base — above max_y_reached is already handled by
	# _find_disconnected_above.
	var min_y := int(ceil(GROUND_Y_TOLERANCE / step)) + 1
	var max_y := max_y_reached

	for grid_y in range(min_y, max_y + 1):
		var solid_count := 0
		# Scan the XZ cross-section at this Y level
		var x_grid := int(floor(-OUTER_RADIUS / step))
		var x_max := int(ceil(OUTER_RADIUS / step))
		var z_grid := int(floor(-OUTER_RADIUS / step))
		var z_max := int(ceil(OUTER_RADIUS / step))

		for gx in range(x_grid, x_max + 1):
			for gz in range(z_grid, z_max + 1):
				var key := _grid_key(Vector3i(gx, grid_y, gz))
				if visited.has(key):
					solid_count += 1

		if solid_count < weakest_count:
			weakest_count = solid_count
			weakest_y = (float(grid_y) + 0.5) * step

	if weakest_count < MIN_SOLID_CELLS_PER_LAYER:
		print("[SpiralTower] Weak cross-section: %d cells at y=%.1f (min required: %d)" % [
			weakest_count, weakest_y, MIN_SOLID_CELLS_PER_LAYER])
		return weakest_y

	return -1.0


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

	# Bake slab fragment meshes BEFORE erasing (SDF data will be destroyed on erase)
	_bake_slab_meshes(sever_y)

	# Compute the mesh offset: the baked mesh vertices are in buffer-local space,
	# where (0,0,0) = the region_min corner we used for VoxelTool.copy().
	# region_min was: (-extent - total_pad, sever_y - total_pad, -extent - total_pad)
	# We need to offset the MeshInstance3D so the mesh aligns with the topple body center.
	# Must match the total_min_pad used in _bake_upper_section_mesh (min_pad + EXTRA_PAD).
	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var total_pad: int = min_pad + 2  # Must match EXTRA_PAD in _bake_upper_section_mesh
	var extent := OUTER_RADIUS + 2.0
	var region_min_local := Vector3(
		float(int(floor(-extent)) - total_pad),
		float(int(floor(sever_y)) - total_pad),
		float(int(floor(-extent)) - total_pad)
	)

	# The topple body will be positioned at the centroid of the severed section
	# in world space. The mesh needs to be offset from the body center so it
	# renders in the correct position.
	# Body centroid in local tower space = (0, sever_y + section_height/2, 0)
	# Mesh vertex world_local = vertex_buffer_pos + region_min_local
	# Mesh offset from body center = region_min_local - (0, sever_y + section_height/2, 0)
	var body_center_local := Vector3(0.0, sever_y + section_height * 0.5, 0.0)
	var mesh_offset := region_min_local - body_center_local

	# Erase the upper section from the voxel terrain
	_erase_above(sever_y)
	_effective_tower_top = sever_y  # Tower is now shorter

	# Spawn the topple body at the section centroid in world space
	var centroid := global_position + body_center_local
	_spawn_topple_body(centroid, baked_mesh, mesh_offset, section_height, torque_dir)

	# Sync to clients
	_sync_collapse_start.rpc(sever_y, torque_dir)

	_collapse_in_progress = false


func _bake_upper_section_mesh(sever_y: float) -> Mesh:
	## Extract the actual voxel mesh of the upper tower section using the mesher.
	## This copies the SDF data into a VoxelBuffer, then uses VoxelMesherTransvoxel
	## to build the real mesh — so the topple body looks exactly like the tower.
	##
	## Key: after copying terrain data, we overwrite the padding border voxels
	## with air (SDF = 1.0). VoxelTool.copy() fills the ENTIRE buffer from the
	## terrain, overwriting any pre-filled values. The mesher treats the outer
	## min_pad/max_pad layers as neighbor data — if those contain 0.0 instead of
	## air, Transvoxel won't generate closing faces (the "see-through holes" bug).
	if _voxel_tool == null:
		return _bake_fallback_cylinder_mesh(sever_y)

	var section_height: float = _effective_tower_top - sever_y

	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var max_pad: int = mesher.get_maximum_padding()
	# Extra air padding beyond the mesher's minimum so Transvoxel has a clean
	# multi-voxel gradient at every boundary. Prevents see-through faces.
	const EXTRA_PAD := 2
	var total_min_pad: int = min_pad + EXTRA_PAD
	var total_max_pad: int = max_pad + EXTRA_PAD

	# Include padding in the copy region so the buffer is correctly sized for the mesher.
	var extent := OUTER_RADIUS + 2.0
	var region_min := Vector3i(
		int(floor(-extent)) - total_min_pad,
		int(floor(sever_y)) - total_min_pad,
		int(floor(-extent)) - total_min_pad
	)
	var region_max := Vector3i(
		int(ceil(extent)) + total_max_pad,
		int(ceil(sever_y + section_height)) + total_max_pad,
		int(ceil(extent)) + total_max_pad
	)

	var buf_size: Vector3i = region_max - region_min
	if buf_size.x <= 0 or buf_size.y <= 0 or buf_size.z <= 0:
		return _bake_fallback_cylinder_mesh(sever_y)

	# Copy terrain SDF data into the buffer (this fills the ENTIRE buffer).
	var buffer := VoxelBuffer.new()
	buffer.create(buf_size.x, buf_size.y, buf_size.z)
	var sdf_channel_mask: int = 1 << VoxelBuffer.CHANNEL_SDF
	_voxel_tool.copy(region_min, buffer, sdf_channel_mask)

	# Overwrite the enlarged padding border with air AFTER the copy.
	# The extra rows beyond the mesher's minimum ensure a multi-voxel gradient
	# ramp from solid→air, so Transvoxel reliably generates closing faces.
	_fill_buffer_padding_with_air(buffer, buf_size, total_min_pad, total_max_pad)

	# Build the mesh using the same mesher type as the terrain
	var materials: Array[Material] = [_tower_material]
	var built_mesh: Mesh = mesher.build_mesh(buffer, materials)
	if built_mesh == null or built_mesh.get_surface_count() == 0:
		print("[SpiralTower] Mesh extraction failed — using fallback cylinder")
		return _bake_fallback_cylinder_mesh(sever_y)

	print("[SpiralTower] Baked real voxel mesh (surfaces: %d, buf_size: %s)" % [
		built_mesh.get_surface_count(), str(buf_size)])
	return built_mesh


func _bake_slab_meshes(sever_y: float) -> void:
	## Bake the upper tower section into horizontal slab meshes for impact fragments.
	## Must be called BEFORE _erase_above() since it reads live SDF data.
	## Populates _cached_slab_meshes, _cached_slab_offsets, _cached_slab_shapes,
	## _cached_slab_mesh_centers.
	##
	## Same padding strategy as _bake_upper_section_mesh: copy terrain data first,
	## then overwrite the padding border voxels with air so Transvoxel generates
	## closed surfaces at all boundaries.
	_cached_slab_meshes.clear()
	_cached_slab_offsets.clear()
	_cached_slab_shapes.clear()
	_cached_slab_mesh_centers.clear()

	if _voxel_tool == null:
		return

	var section_height: float = _effective_tower_top - sever_y
	if section_height < 2.0:
		return

	var body_center_local := Vector3(0.0, sever_y + section_height * 0.5, 0.0)
	_cached_body_center_local = body_center_local

	# Aim for slabs ~6m tall. Minimum 2, maximum 6.
	var slab_count := clampi(int(ceil(section_height / 6.0)), 2, 6)
	var slab_height := section_height / float(slab_count)

	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var max_pad: int = mesher.get_maximum_padding()
	# Extra voxels of air beyond the mesher's required padding. Transvoxel
	# uses the padding rows for gradient computation; with only min_pad (typically 1)
	# rows of air, the solid→air transition is right at the buffer edge and the
	# mesher often fails to generate closing triangles there (the "see-through
	# bottom face" bug). Adding 2 extra rows gives a clean gradient ramp so
	# Transvoxel reliably produces closed geometry on all slab faces.
	const EXTRA_PAD := 2
	var total_min_pad: int = min_pad + EXTRA_PAD
	var total_max_pad: int = max_pad + EXTRA_PAD
	var extent := OUTER_RADIUS + 2.0
	var sdf_channel_mask: int = 1 << VoxelBuffer.CHANNEL_SDF
	var materials: Array[Material] = [_tower_material]

	for slab_i in slab_count:
		var slab_bottom: float = sever_y + slab_i * slab_height
		var slab_top: float = slab_bottom + slab_height

		# Include padding in the copy region — extra padding ensures clean
		# solid→air transitions on all faces so Transvoxel generates closed geometry.
		var region_min := Vector3i(
			int(floor(-extent)) - total_min_pad,
			int(floor(slab_bottom)) - total_min_pad,
			int(floor(-extent)) - total_min_pad
		)
		var region_max := Vector3i(
			int(ceil(extent)) + total_max_pad,
			int(ceil(slab_top)) + total_max_pad,
			int(ceil(extent)) + total_max_pad
		)

		var buf_size: Vector3i = region_max - region_min
		if buf_size.x <= 0 or buf_size.y <= 0 or buf_size.z <= 0:
			continue

		# Copy terrain SDF, then overwrite the enlarged padding borders with air.
		# We pass total_min_pad/total_max_pad so the full border (mesher padding +
		# extra rows) is filled with air, creating a multi-voxel gradient ramp.
		var buffer := VoxelBuffer.new()
		buffer.create(buf_size.x, buf_size.y, buf_size.z)
		_voxel_tool.copy(region_min, buffer, sdf_channel_mask)
		_fill_buffer_padding_with_air(buffer, buf_size, total_min_pad, total_max_pad)

		# Build mesh — Transvoxel sees air padding → closed surfaces
		var slab_mesh: Mesh = mesher.build_mesh(buffer, materials)
		if slab_mesh == null or slab_mesh.get_surface_count() == 0:
			continue  # Skip empty slabs (can happen near the top)

		# Offset of this slab's mesh origin relative to the topple body center.
		# Mesh vertices are in buffer-local space (0,0,0 = region_min corner).
		# At impact time: slab_world_pos = topple_body.global_transform * slab_offset
		var slab_offset := Vector3(region_min) - body_center_local

		_cached_slab_meshes.append(slab_mesh)
		_cached_slab_offsets.append(slab_offset)

		# Cache the mesh AABB center so _spawn_slab_fragments can re-center
		# the MeshInstance3D and CollisionShape3D on the RigidBody3D origin.
		var mesh_aabb := slab_mesh.get_aabb()
		_cached_slab_mesh_centers.append(mesh_aabb.get_center())

		# Collision shape: centered BoxShape3D matching the mesh AABB.
		# Convex hulls from buffer-space vertices are offset from (0,0,0) and
		# cause violent physics (player launched when walking on fragments).
		# A centered box is stable and predictable.
		var box := BoxShape3D.new()
		box.size = mesh_aabb.size
		_cached_slab_shapes.append(box)

	print("[SpiralTower] Baked %d slab meshes (section: %.1fm, slab_h: %.1fm)" % [
		_cached_slab_meshes.size(), section_height, slab_height])


func _fill_buffer_padding_with_air(buffer: VoxelBuffer, buf_size: Vector3i,
		min_pad: int, max_pad: int) -> void:
	## Overwrite the padding border voxels of a VoxelBuffer with air (SDF = 1.0).
	## VoxelMesherTransvoxel treats the outer min_pad layers (low side) and max_pad
	## layers (high side) as neighbor data for gradient computation. If these contain
	## 0.0 (from terrain data outside the tower), the mesher won't generate closing
	## faces at boundaries. By writing air here AFTER VoxelTool.copy(), we ensure
	## clean solid→air transitions that produce fully closed meshes.
	##
	## Uses fill_area_f for efficiency (single C++ call per slab instead of
	## thousands of GDScript set_voxel_f calls).
	var ch := VoxelBuffer.CHANNEL_SDF
	var air := SDF_EMPTY_VALUE
	var s := buf_size  # Alias for readability

	# X axis: low side (0..min_pad) and high side (s.x-max_pad..s.x)
	buffer.fill_area_f(air, Vector3i(0, 0, 0), Vector3i(min_pad, s.y, s.z), ch)
	buffer.fill_area_f(air, Vector3i(s.x - max_pad, 0, 0), Vector3i(s.x, s.y, s.z), ch)

	# Y axis: low side (0..min_pad) and high side (s.y-max_pad..s.y)
	buffer.fill_area_f(air, Vector3i(0, 0, 0), Vector3i(s.x, min_pad, s.z), ch)
	buffer.fill_area_f(air, Vector3i(0, s.y - max_pad, 0), Vector3i(s.x, s.y, s.z), ch)

	# Z axis: low side (0..min_pad) and high side (s.z-max_pad..s.z)
	buffer.fill_area_f(air, Vector3i(0, 0, 0), Vector3i(s.x, s.y, min_pad), ch)
	buffer.fill_area_f(air, Vector3i(0, 0, s.z - max_pad), Vector3i(s.x, s.y, s.z), ch)


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

	# Physics properties — mass proportional to volume (cross-section area * height).
	# Core cylinder area = PI * CORE_RADIUS^2 ≈ 28.3 m^2, plus spiral ramp adds ~30%.
	# Density ~5.5 kg/m^3 gives reasonable feel for a stone tower.
	var cross_section_area: float = PI * CORE_RADIUS * CORE_RADIUS * 1.3  # Core + ramp estimate
	topple.mass = cross_section_area * section_height * 5.5
	topple.continuous_cd = true
	topple.contact_monitor = true
	topple.max_contacts_reported = 4
	topple.gravity_scale = 1.0
	# Use dedicated collision layer 2 for tower debris so topple body and chunks
	# don't collide with each other. Mask layer 1 (world/players) for ground impact.
	topple.collision_layer = 2
	topple.collision_mask = 1

	# Set custom properties BEFORE adding to tree (these are simple vars, not transforms)
	topple.section_height = section_height
	topple.attacker_id = _last_attacker_id
	topple.tower_position = global_position

	# Set position BEFORE adding to tree so there's no 1-frame flash at (0,0,0).
	# For a child of the scene root, position == global_position.
	topple.position = centroid
	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(topple)

	# Apply torque for dramatic tipping — needs to overcome the mass
	var torque_strength := topple.mass * section_height * 2.0
	topple.apply_torque_impulse(torque_dir * torque_strength)
	# Gentle lateral nudge — just enough to start the tip, not a visible jump
	var push_strength := topple.mass * 0.3
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
func _sync_collapse_start(sever_y: float, torque_dir: Vector3) -> void:
	## Client-side: extract real mesh, erase upper section, spawn visual-only topple body.
	var section_height: float = _effective_tower_top - sever_y
	if section_height < 2.0:
		section_height = TOWER_HEIGHT - sever_y  # Fallback for client

	# Bake visual mesh BEFORE erasing (so we capture the actual tower shape)
	var baked_mesh := _bake_upper_section_mesh(sever_y)

	# Bake slab fragment meshes BEFORE erasing (SDF data will be destroyed on erase)
	_bake_slab_meshes(sever_y)

	var body_center_local := Vector3(0.0, sever_y + section_height * 0.5, 0.0)

	# Compute mesh offset (same logic as server — must match EXTRA_PAD in _bake_upper_section_mesh)
	var mesher := VoxelMesherTransvoxel.new()
	var min_pad: int = mesher.get_minimum_padding()
	var total_pad: int = min_pad + 2  # Must match EXTRA_PAD
	var extent := OUTER_RADIUS + 2.0
	var region_min_local := Vector3(
		float(int(floor(-extent)) - total_pad),
		float(int(floor(sever_y)) - total_pad),
		float(int(floor(-extent)) - total_pad)
	)
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

	var cross_section_area: float = PI * CORE_RADIUS * CORE_RADIUS * 1.3
	topple.mass = cross_section_area * section_height * 5.5
	topple.continuous_cd = true
	topple.gravity_scale = 1.0
	# Use dedicated collision layer 2 for tower debris (matches server topple body)
	topple.collision_layer = 2
	topple.collision_mask = 1

	# Set position BEFORE adding to tree so there's no 1-frame flash at (0,0,0)
	topple.position = centroid
	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(topple)

	# Match server-side forces for consistent visual
	var torque_strength := topple.mass * section_height * 2.0
	topple.apply_torque_impulse(torque_dir * torque_strength)
	var push_strength := topple.mass * 0.3
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
		chunk_count: int, chunk_sizes: Array, chunk_impulses: Array,
		body_transform: Transform3D = Transform3D.IDENTITY,
		body_linear_vel: Vector3 = Vector3.ZERO,
		body_angular_vel: Vector3 = Vector3.ZERO,
		body_mass: float = 0.0) -> void:
	## All clients + server: spawn slab fragments at the topple body's final pose.
	## Fragments inherit the topple body's velocity so they continue falling
	## naturally and each creates its own impact explosion when hitting the ground.
	var is_server := multiplayer.is_server()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Remove the topple body — it's being replaced by fragments.
	# On server it's already queue_free'd by tower_topple_body, but on clients
	# the visual copy (TowerToppleBody_Visual) is still around.
	for child in scene_root.get_children():
		if child is RigidBody3D and child.name.begins_with("TowerToppleBody"):
			child.queue_free()

	if _cached_slab_meshes.size() > 0:
		_spawn_slab_fragments(body_transform, is_server, scene_root,
			body_linear_vel, body_angular_vel, body_mass)
	else:
		# Fallback: spawn random rock chunks if slab baking failed
		print("[SpiralTower] No cached slab meshes — falling back to rock chunks")
		_spawn_rock_chunks_legacy(impact_pos, chunk_count, chunk_sizes,
			chunk_impulses, is_server, scene_root)



func _spawn_slab_fragments(body_transform: Transform3D, is_server: bool,
		scene_root: Node, body_linear_vel: Vector3 = Vector3.ZERO,
		body_angular_vel: Vector3 = Vector3.ZERO,
		body_mass: float = 0.0) -> void:
	## Spawn cached slab meshes as RigidBody3D fragments at the topple body's
	## final world-space position and rotation. Each slab is a real horizontal
	## slice of the tower's voxel mesh, so it looks like an actual piece.
	##
	## Fragments inherit the topple body's velocity so they continue falling
	## naturally. Mass is distributed equally (each slab is roughly the same
	## height slice of the tower). Each fragment handles its own ground impact.
	var spawned_slabs: Array[RigidBody3D] = []

	# Deterministic RNG for slight scatter (seeded from body position so all peers match)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(body_transform.origin.x * 1000.0) ^ int(body_transform.origin.z * 7919.0)

	var slab_count := _cached_slab_meshes.size()

	# Distribute the topple body's total mass equally across all slabs.
	# Each slab is roughly the same height slice so equal split is fair.
	var mass_per_slab: float = body_mass / maxf(float(slab_count), 1.0) if body_mass > 0.0 else 200.0

	for i in slab_count:
		var slab_mesh: Mesh = _cached_slab_meshes[i]
		var slab_offset: Vector3 = _cached_slab_offsets[i]
		var slab_shape: Shape3D = _cached_slab_shapes[i]
		var mesh_center: Vector3 = _cached_slab_mesh_centers[i] if i < _cached_slab_mesh_centers.size() else Vector3.ZERO

		var slab := RigidBody3D.new()
		slab.name = "TowerSlab_%d" % i

		if is_server:
			slab.set_script(TowerChunkScript)

		# Collision shape — centered BoxShape3D matching the mesh AABB.
		var col := CollisionShape3D.new()
		col.shape = slab_shape
		slab.add_child(col)

		# Visual mesh — offset by -mesh_center so it's centered on the body origin.
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = slab_mesh
		mesh_inst.position = -mesh_center
		if _tower_material:
			mesh_inst.material_override = _tower_material
		else:
			var fallback := StandardMaterial3D.new()
			fallback.albedo_color = Color(0.45, 0.42, 0.40)
			fallback.roughness = 0.85
			fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
			mesh_inst.material_override = fallback
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		slab.add_child(mesh_inst)

		# Physics — mass is the topple body's total mass split across fragments.
		slab.mass = maxf(mass_per_slab, 50.0)
		slab.gravity_scale = 1.0
		slab.angular_damp = 1.5
		slab.collision_layer = 2  # Tower debris layer
		slab.collision_mask = 3   # Collide with world (1) AND other tower debris (2)

		if is_server:
			slab.contact_monitor = true
			slab.max_contacts_reported = 4
			slab.chunk_mass = slab.mass
			slab.attacker_id = _last_attacker_id

		# Position: place the body at the mesh center's world position,
		# accounting for the topple body's rotation at breakup time.
		var centered_offset: Vector3 = slab_offset + mesh_center
		var slab_world_pos: Vector3 = body_transform * centered_offset

		scene_root.add_child(slab)
		var slab_xform := Transform3D(body_transform.basis, slab_world_pos)
		slab.global_transform = slab_xform

		spawned_slabs.append(slab)

		# Inherit the topple body's velocity so fragments continue the fall
		# naturally. For a rotating body, each point's velocity is:
		#   v_point = v_center + angular_vel × (point - center)
		# This gives outer/top fragments more speed than center ones.
		var offset_from_center: Vector3 = slab_world_pos - body_transform.origin
		var inherited_vel: Vector3 = body_linear_vel + body_angular_vel.cross(offset_from_center)
		slab.linear_velocity = inherited_vel
		slab.angular_velocity = body_angular_vel

		# Small outward scatter so slabs separate slightly instead of stacking
		var outward := offset_from_center
		if outward.length_squared() < 0.01:
			outward = Vector3(rng.randf_range(-1.0, 1.0), 0.2,
				rng.randf_range(-1.0, 1.0))
		outward.y = maxf(outward.y, 0.0)
		outward = outward.normalized()
		slab.apply_central_impulse(outward * rng.randf_range(1.0, 3.0))

		# Small random spin so slabs tumble slightly differently
		slab.apply_torque_impulse(Vector3(
			rng.randf_range(-2.0, 2.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-2.0, 2.0)
		))

	# Clear the cache
	_cached_slab_meshes.clear()
	_cached_slab_offsets.clear()
	_cached_slab_shapes.clear()
	_cached_slab_mesh_centers.clear()

	print("[SpiralTower] Spawned %d slab fragments at topple body position" % spawned_slabs.size())


func _spawn_rock_chunks_legacy(impact_pos: Vector3, chunk_count: int,
		chunk_sizes: Array, chunk_impulses: Array,
		is_server: bool, scene_root: Node) -> void:
	## Fallback: spawn random rock-shaped chunks if slab baking failed.
	var spawned_chunks: Array[RigidBody3D] = []

	var rng := RandomNumberGenerator.new()
	rng.seed = int(impact_pos.x * 1000.0) ^ int(impact_pos.z * 7919.0) ^ (chunk_count * 4391)

	for i in chunk_count:
		var chunk_size: float = chunk_sizes[i] if i < chunk_sizes.size() else 1.5
		var chunk_impulse: Vector3 = chunk_impulses[i] if i < chunk_impulses.size() else Vector3.ZERO

		var chunk := RigidBody3D.new()
		chunk.name = "TowerChunk_%d" % i

		if is_server:
			chunk.set_script(TowerChunkScript)

		var col := CollisionShape3D.new()
		var rock_mesh: ArrayMesh = _generate_rock_mesh(chunk_size, i)
		var convex := rock_mesh.create_convex_shape(true, false)
		if convex and convex is ConvexPolygonShape3D and convex.points.size() >= 4:
			col.shape = convex
		else:
			var box_shape := BoxShape3D.new()
			var half := chunk_size * 0.45
			box_shape.size = Vector3(half, half * 0.7, half)
			col.shape = box_shape
		chunk.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = rock_mesh
		mesh_inst.material_override = _tower_material
		chunk.add_child(mesh_inst)

		chunk.mass = chunk_size * chunk_size * chunk_size * 50.0
		chunk.gravity_scale = 1.0
		chunk.angular_damp = 2.0
		chunk.collision_layer = 2  # Tower debris layer
		chunk.collision_mask = 3   # Collide with world (1) AND other tower debris (2)

		if is_server:
			chunk.contact_monitor = true
			chunk.max_contacts_reported = 4
			chunk.chunk_mass = chunk.mass / 200.0
			chunk.attacker_id = _last_attacker_id

		var spawn_pos: Vector3 = impact_pos + Vector3(
			rng.randf_range(-2.0, 2.0), rng.randf_range(0.5, 2.0), rng.randf_range(-2.0, 2.0)
		)

		scene_root.add_child(chunk)
		chunk.global_position = spawn_pos

		spawned_chunks.append(chunk)

		chunk.apply_central_impulse(chunk_impulse)
		chunk.apply_torque_impulse(Vector3(
			rng.randf_range(-3.0, 3.0),
			rng.randf_range(-2.0, 2.0),
			rng.randf_range(-3.0, 3.0)
		))
