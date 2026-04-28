extends PhysicsBodyBase
class_name FallingBlockCluster

## Falling cluster of blocks detached from a DestructibleBlockStructure when
## structural integrity fails.  Uses BlockGridManager for block data, mesh
## building, and collision shape computation — the same shared logic that
## structures use.
##
## A compound StaticBody3D (one body, N shapes) on layer 11 (WALL_BLOCKS)
## provides per-block hitscan targeting via shape_index → grid_key mapping.
##
## Explosions deal per-block AoE damage via take_damage_at().
## Momentum impacts carve through blocks via take_momentum_damage_at().
##
## Server-authoritative: only the server runs damage logic.
## Clients freeze the body as kinematic.
##
## Created by DestructibleBlockStructure._sync_cluster_detach() RPC on all peers.

# ======================================================================
#  Constants
# ======================================================================

const MIN_DAMAGE_SPEED := 3.0          ## Speed threshold for ANY damage (m/s)
const MOMENTUM_DAMAGE_SCALE := 0.15    ## Base: damage = momentum * this * GameManager scale
const MASS_PER_HP := 0.5               ## Matching DestructibleBlockStructure.MASS_PER_HP
const SETTLE_SPEED := 0.5             ## Speed below which we start the settle timer
const SETTLE_TIME := 3.0              ## Seconds at low speed before freezing
## Breakthrough explosion scales with PER-BLOCK momentum at remaining speed,
## not total cluster momentum. This keeps the explosion localized.
const BREAKTHROUGH_DAMAGE_SCALE := 0.5  ## expl_damage = per_block_momentum * this
const BREAKTHROUGH_RADIUS_SCALE := 0.005 ## expl_radius = base + per_block_momentum * this
const BREAKTHROUGH_BASE_RADIUS := 1.0   ## Minimum explosion radius (2 blocks)

# ======================================================================
#  Properties (set by the spawner before adding to scene)
# ======================================================================

var cluster_mass: float = 25.0         ## Total mass in kg
var attacker_id: int = -1              ## Player who caused the structural failure

# ======================================================================
#  Block grid — shared data manager (position math, mesh, shapes, BFS)
# ======================================================================

var grid: BlockGridManager = null

## Mass per block in kg (set during init, used for momentum calculations)
var _mass_per_block: float = 5.0

# ======================================================================
#  Compound hit body — one StaticBody3D with N shapes on layer 11 (WALL_BLOCKS)
#  Each shape corresponds to one block; shape_index → grid_key mapping
#  for hitscan targeting via compound_hit_body.gd → _damage_block()
# ======================================================================

var _compound_hit_body: StaticBody3D = null  ## Single body with N shapes
var _shape_to_key: Array[Vector3i] = []      ## shape_index → grid_key
var _key_to_shape: Dictionary = {}            ## Vector3i → shape_index
var _shared_hit_shape: BoxShape3D = null      ## Shared shape RID for all blocks
var _compound_body_script: GDScript = preload("res://world/compound_hit_body.gd")

# ======================================================================
#  Direct collision shapes — added via PhysicsServer3D.body_add_shape()
#  on this RigidBody3D's own RID (layer 12, smooth wall collision).
#  No CollisionShape3D nodes — eliminates add_child overhead.
# ======================================================================

var _col_shapes: Array = []            ## BoxShape3D refs (prevent GC, keep RIDs alive)
var _col_shape_count: int = 0          ## Number of shapes added to this body

# ======================================================================
#  Internal state
# ======================================================================

var _settle_timer: float = 0.0
var _mesh_dirty: bool = false
## Visual: either a MeshInstance3D node (old path) or a RenderingServer RID (fast path).
var _mesh_instance: MeshInstance3D = null
var _visual_rid: RID = RID()  ## RenderingServer instance (fast path, no node)
var _visual_mesh_ref: Mesh = null  ## Mesh resource ref (prevents GC — keeps RID valid)
## Per-tick contact counter — tracks how many body_entered signals fire per physics frame
var _contacts_this_tick: int = 0

## Stress solver: periodic structural integrity check with external forces.
var _stress_check_timer: float = 0.0
const STRESS_CHECK_INTERVAL := 0.5  ## seconds between stress checks while contacts exist
const CLUSTER_MAX_LOAD := 12.0      ## max compression per face in block-weights
const CLUSTER_H_TRANSFER := 0.6     ## lateral load distribution
var _has_ground_contact: bool = false
var _active_body_contacts: Dictionary = {}  ## body_rid -> mass (for external load)
var _active_body_nodes: Dictionary = {}     ## body_rid -> Node (parallel to _active_body_contacts; needed because RID->Node isn't recoverable)

# ======================================================================
#  Debris config — set by structure before add_child via set_debris_config()
# ======================================================================

var _debris_size: float = 0.15
var _debris_lifetime: float = 5.0
var _debris_mass: float = 0.5
var _debris_name: String = "Debris"
var _block_hp_max: float = 35.0  ## Original full HP per block, for overkill fraction


# ======================================================================
#  Initialization
# ======================================================================

func init_cluster_blocks(block_hp_dict: Dictionary, num_x: int, num_y: int,
		num_z: int, mass_per_blk: float) -> void:
	## Called by _spawn_falling_cluster BEFORE adding to the scene tree.
	## Initializes the BlockGridManager, creates mesh instance, and builds
	## mesh, collision shapes, and compound hit body — all via a single C++ call.
	var _t_init_total := Time.get_ticks_usec()
	_mass_per_block = mass_per_blk

	# Create grid manager and set dimensions (needed for ongoing damage tracking)
	grid = BlockGridManager.new()
	grid.num_x = num_x
	grid.num_y = num_y
	grid.num_z = num_z
	grid.block_hp = block_hp_dict

	# Create mesh instance
	_mesh_instance = get_node_or_null("ClusterMesh")
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "ClusterMesh"
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance)

	# Create shared hit shape and compound hit body (need RIDs for build_cluster)
	if _shared_hit_shape == null:
		_shared_hit_shape = BoxShape3D.new()
		_shared_hit_shape.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE

	_clear_compound_hit_body()
	_compound_hit_body = StaticBody3D.new()
	_compound_hit_body.set_script(_compound_body_script)
	_compound_hit_body.parent_wall = self
	_compound_hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
	_compound_hit_body.collision_mask = 0
	_compound_hit_body.name = "CompoundHitBody"

	# All-in-one C++ call: grid + mesh + collision shapes + hit body shapes
	var result: Dictionary = BlockMeshBuilder.build_cluster(
		block_hp_dict, num_x, num_y, num_z, BlockGridManager.BLOCK_SIZE,
		get_rid(), _compound_hit_body.get_rid(), _shared_hit_shape.get_rid())

	# Unpack grid data
	grid.block_grid = result["block_grid"]
	grid.centroid = result["centroid"]

	# Set mesh
	if _mesh_instance:
		_mesh_instance.mesh = result["mesh"]

	# Store collision shape refs (prevent GC, keep RIDs alive)
	_col_shapes = result["col_shapes"]
	_col_shape_count = result["col_count"]

	# Unpack hit body shape→key mappings
	var shape_keys: Array = result["shape_to_key"]
	_shape_to_key.clear()
	_key_to_shape.clear()
	for i in shape_keys.size():
		var key: Vector3i = shape_keys[i]
		_shape_to_key.append(key)
		_key_to_shape[key] = i
	_compound_hit_body._shape_to_key = _shape_to_key

	# Add compound hit body to scene tree
	add_child(_compound_hit_body)

	# Set shielding on compound hit body
	PhysicsServer3D.body_set_shielding_tag(_compound_hit_body.get_rid(), 1)
	_update_compound_shielding_hp()

	var _t_init_us := Time.get_ticks_usec() - _t_init_total
	print("[ClusterPerf] init_cluster_blocks %s: %d blocks, total=%dus (single C++ call)" % [
		name, block_hp_dict.size(), _t_init_us])


var _cached_material: StandardMaterial3D = null

func set_material(mat: StandardMaterial3D) -> void:
	## Set the material for the cluster mesh.
	_cached_material = mat
	if _mesh_instance:
		_mesh_instance.material_override = mat
	elif _visual_rid.is_valid() and mat:
		RenderingServer.instance_geometry_set_material_override(_visual_rid, mat.get_rid())


func get_cluster_material() -> StandardMaterial3D:
	if _cached_material:
		return _cached_material
	if _mesh_instance and _mesh_instance.material_override:
		return _mesh_instance.material_override
	return null


func set_visual_mesh(mesh: Mesh) -> void:
	## Set the mesh on the RenderingServer visual instance (fast path).
	if not _visual_rid.is_valid():
		return
	_visual_mesh_ref = mesh  # prevent GC — mesh RID must stay valid
	if mesh:
		RenderingServer.instance_set_base(_visual_rid, mesh.get_rid())


func init_visual_rid(scenario: RID) -> void:
	## Create a RenderingServer visual instance instead of a MeshInstance3D node.
	_visual_rid = RenderingServer.instance_create()
	RenderingServer.instance_set_scenario(_visual_rid, scenario)
	RenderingServer.instance_geometry_set_cast_shadows_setting(
		_visual_rid, RenderingServer.SHADOW_CASTING_SETTING_ON)


func set_debris_config(size: float, lifetime: float, dmass: float,
		dname: String, block_hp_max: float) -> void:
	## Set debris parameters (called by structure before add_child).
	_debris_size = size
	_debris_lifetime = lifetime
	_debris_mass = dmass
	_debris_name = dname
	_block_hp_max = block_hp_max


func _ready() -> void:
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)
		body_exited.connect(_on_body_exited)
	else:
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	set_process(false)


func _exit_tree() -> void:
	_col_shapes.clear()
	_col_shape_count = 0


# ======================================================================
#  Frame processing
# ======================================================================

func _process(_delta: float) -> void:
	Profiler.begin("cluster_mesh_rebuild")
	## Deferred mesh/shape rebuild after block destruction.
	if _mesh_dirty:
		_mesh_dirty = false
		var _t0 := Time.get_ticks_usec()
		_rebuild_visuals()
		var _t_us := Time.get_ticks_usec() - _t0
		GameManager.frame_add("cluster_mesh", _t_us)
		set_process(false)
	Profiler.end("cluster_mesh_rebuild")


func _physics_process(delta: float) -> void:
	Profiler.begin("falling_cluster")
	var _t0 := Time.get_ticks_usec()
	super._physics_process(delta)

	# Sync compound hit body transform so hitscan raycasts hit the correct
	# position.  Jolt threaded physics can desync child StaticBody3D from
	# parent RigidBody3D by at least one frame.
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_state(
			_compound_hit_body.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM,
			global_transform)

	# Sync visual RID transform (fast path — no MeshInstance3D node)
	if _visual_rid.is_valid():
		RenderingServer.instance_set_transform(_visual_rid, global_transform)

	if not multiplayer.is_server():
		GameManager.tick_add("cluster_tick", Time.get_ticks_usec() - _t0)
		Profiler.end("falling_cluster")
		return

	_contacts_this_tick = 0

	# Freeze on settle: if moving slowly for long enough, stop simulating
	if linear_velocity.length() < SETTLE_SPEED:
		_settle_timer += delta
		if _settle_timer >= SETTLE_TIME:
			sleeping = true
			set_physics_process(false)
	else:
		_settle_timer = 0.0

	# Periodic stress check while contacts exist
	if not _active_body_contacts.is_empty() or _has_ground_contact:
		_stress_check_timer += delta
		if _stress_check_timer >= STRESS_CHECK_INTERVAL:
			_stress_check_timer = 0.0
			_check_cluster_stress()

	GameManager.tick_add("cluster_tick", Time.get_ticks_usec() - _t0)
	Profiler.end("falling_cluster")


# ======================================================================
#  Damage — per-block, just like a normal structure
# ======================================================================

func _damage_block(key: Vector3i, amount: float, _attacker_id: int) -> void:
	## Called by compound_hit_body.gd when a hitscan bullet hits a specific block.
	## Targets one block with full damage — no falloff, no shielding.
	if not multiplayer.is_server():
		return
	if not grid.has_block(key):
		return

	Profiler.begin("cluster_damage_block")
	var _t_dmg_total := Time.get_ticks_usec()
	grid.block_hp[key] -= amount
	_update_compound_shielding_hp()

	if grid.block_hp[key] <= 0.0:
		var ok_frac := clampf(-grid.block_hp[key] / _block_hp_max, 0.0, 1.0)
		var spd := DebrisHelper.calc_hitscan_speed(ok_frac)
		# Use attacker position as blast origin so debris flies away from shooter
		var blast_pos := Vector3.INF
		var players_node := get_tree().current_scene.get_node_or_null("Players")
		if players_node and _attacker_id >= 0:
			var attacker := players_node.get_node_or_null(str(_attacker_id))
			if attacker and is_instance_valid(attacker):
				blast_pos = attacker.global_position
		var _t_erase := Time.get_ticks_usec()
		grid.erase_block(key)
		_disable_hit_shape(key)
		var _t_erase_us := Time.get_ticks_usec() - _t_erase
		var _t_abd := Time.get_ticks_usec()
		_after_blocks_destroyed([key], blast_pos, [spd])
		var _t_abd_us := Time.get_ticks_usec() - _t_abd
		var _t_dmg_us := Time.get_ticks_usec() - _t_dmg_total
		print("[PERF] cluster._damage_block %s key=%s: erase=%dus after_destroyed=%dus total=%dus blocks=%d" % [
			name, str(key), _t_erase_us, _t_abd_us, _t_dmg_us, grid.block_count()])
		GameManager.tick_add("cluster_damage_block", _t_dmg_us)
	Profiler.end("cluster_damage_block")


func take_damage(amount: float, _from_attacker_id: int = -1) -> void:
	## Distribute damage evenly across all remaining blocks.
	## Fallback for non-positional damage sources.
	if not multiplayer.is_server():
		return
	if grid == null or grid.is_empty():
		return

	Profiler.begin("cluster_take_damage")
	var _t_td_total := Time.get_ticks_usec()
	var per_block: float = amount / float(grid.block_count())
	var destroyed_keys: Array[Vector3i] = []

	for key: Vector3i in grid.block_hp:
		grid.block_hp[key] -= per_block
		if grid.block_hp[key] <= 0.0:
			destroyed_keys.append(key)

	if not destroyed_keys.is_empty():
		# Bulk mode: disable all shapes in one commit instead of N rebuilds.
		var _t_erase := Time.get_ticks_usec()
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
		for key in destroyed_keys:
			grid.erase_block(key)
			_disable_hit_shape(key)
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
		var _t_erase_us := Time.get_ticks_usec() - _t_erase
		var _t_abd := Time.get_ticks_usec()
		_after_blocks_destroyed(destroyed_keys)
		var _t_abd_us := Time.get_ticks_usec() - _t_abd
		var _t_td_us := Time.get_ticks_usec() - _t_td_total
		print("[PERF] cluster.take_damage %s: %d destroyed, erase=%dus after_destroyed=%dus total=%dus" % [
			name, destroyed_keys.size(), _t_erase_us, _t_abd_us, _t_td_us])
	Profiler.end("cluster_take_damage")


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float,
		_attacker_id: int, _exclude_rids: Array[RID] = [], _impact_speed: float = INF) -> void:
	## AoE per-block damage from explosions. Cubic falloff + flat-HP shielding.
	## Each block gets a shielding ray from the explosion origin — objects between
	## the explosion and the block absorb damage equal to their HP (same as structures).
	## Excludes own RID so this cluster's shapes don't self-shield.
	if not multiplayer.is_server():
		return
	if grid == null or grid.is_empty():
		return

	Profiler.begin("cluster_take_damage_at")
	var _t_take_damage_at := Time.get_ticks_usec()

	var space_state: PhysicsDirectSpaceState3D = null
	var w3d := get_world_3d()
	if w3d:
		space_state = w3d.direct_space_state

	var debug_rays := GameManager.debug_show_explosion_rays
	var debug_ray_data: Array = []

	# Build exclude list: rocket body + this cluster (prevent self-shielding).
	var my_rid := get_rid()
	var exclude: Array[RID] = _exclude_rids.duplicate()
	if my_rid.is_valid():
		exclude.append(my_rid)

	# Reuse one query object across all block rays.
	var query: PhysicsRayQueryParameters3D = null
	if space_state:
		query = ExplosionHelper._make_shielding_query(hit_pos, exclude)

	var destroyed_keys: Array[Vector3i] = []
	var dbg_blocks_hit := 0
	var dbg_total_raw := 0.0
	var dbg_total_absorbed := 0.0
	var _t_raycast_total := 0

	for key: Vector3i in grid.block_hp:
		var block_world: Vector3 = global_transform * grid.block_local_pos(key)
		var dist: float = hit_pos.distance_to(block_world)
		if dist > blast_radius:
			continue
		var norm_dist: float = dist / blast_radius
		var falloff: float = 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
		var raw_dmg: float = amount * falloff

		# Shielding: cast ray from explosion to block, sum flat HP absorption.
		var absorbed := 0.0
		if query:
			query.to = block_world
			var _t_ray := Time.get_ticks_usec()
			absorbed = space_state.calc_ray_shielding(query, RID(), raw_dmg)
			_t_raycast_total += Time.get_ticks_usec() - _t_ray
		var dmg := maxf(raw_dmg - absorbed, 0.0)

		dbg_blocks_hit += 1
		dbg_total_raw += raw_dmg
		dbg_total_absorbed += absorbed

		if debug_rays:
			debug_ray_data.append({
				"from": hit_pos, "to": block_world,
				"raw_dmg": raw_dmg, "final_dmg": dmg,
				"hits": [],
			})

		if dmg < 0.5:
			continue
		grid.block_hp[key] -= dmg

		if grid.block_hp[key] <= 0.0:
			destroyed_keys.append(key)

	if dbg_blocks_hit > 0:
		print("[FallingCluster] take_damage_at %s: %d blocks hit, raw=%.1f, absorbed=%.1f, applied=%.1f" % [
			name, dbg_blocks_hit, dbg_total_raw, dbg_total_absorbed,
			dbg_total_raw - dbg_total_absorbed])

	if debug_rays and not debug_ray_data.is_empty():
		ExplosionHelper.draw_debug_rays(debug_ray_data)

	# Update cached shielding HP so other targets' rays see correct absorption.
	# _after_blocks_destroyed also calls _update_mass, but partial damage to
	# surviving blocks still changes total HP without destroying any block.
	if dbg_blocks_hit > 0 and destroyed_keys.is_empty():
		PhysicsServer3D.body_set_shielding_hp(get_rid(), grid.get_total_hp())
		_update_compound_shielding_hp()

	if not destroyed_keys.is_empty():
		# Compute per-block debris speeds BEFORE erasing (need block_hp for overkill).
		var per_block_speeds: Array[float] = []
		for key in destroyed_keys:
			var block_world: Vector3 = global_transform * grid.block_local_pos(key)
			var norm_d: float = hit_pos.distance_to(block_world) / blast_radius
			var ok_frac: float = clampf(-grid.block_hp[key] / _block_hp_max, 0.0, 1.0)
			per_block_speeds.append(DebrisHelper.calc_explosion_speed(norm_d, ok_frac))

		# Bulk mode: disable all shapes in one commit instead of N rebuilds.
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
		for key in destroyed_keys:
			grid.erase_block(key)
			_disable_hit_shape(key)
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
		var _t_abd := Time.get_ticks_usec()
		_after_blocks_destroyed(destroyed_keys, hit_pos, per_block_speeds, true)
		var _t_abd_us := Time.get_ticks_usec() - _t_abd
		var total_us := Time.get_ticks_usec() - _t_take_damage_at
		print("[ClusterPerf] take_damage_at %s: %d blocks hit, %d destroyed, raycasts=%dus after_destroyed=%dus total=%dus" % [
			name, dbg_blocks_hit, destroyed_keys.size(), _t_raycast_total, _t_abd_us, total_us])
		GameManager.tick_add("cluster_take_damage_at", total_us)
	else:
		var total_us := Time.get_ticks_usec() - _t_take_damage_at
		if total_us > 200:
			print("[ClusterPerf] take_damage_at %s (no destroys): %d blocks hit, raycasts=%dus total=%dus" % [
				name, dbg_blocks_hit, _t_raycast_total, total_us])
		GameManager.tick_add("cluster_take_damage_at", total_us)
	Profiler.end("cluster_take_damage_at")


func take_momentum_damage_at(hit_world_pos: Vector3, damage: float,
		_attckr_id: int, _impact_speed: float = INF) -> Dictionary:
	## Targeted single-block damage from momentum carving.
	## Finds nearest block, damages it. Breakthrough explosions are handled by
	## the caller using per-block momentum at remaining speed.
	## Returns { "absorbed": float, "block_destroyed": bool, "block_key": Vector3i,
	##           "block_pos": Vector3 }
	Profiler.begin("cluster_momentum_dmg")
	var _t_momentum_total := Time.get_ticks_usec()
	var empty_result := { "absorbed": 0.0, "block_destroyed": false,
		"block_key": Vector3i.ZERO, "block_pos": Vector3.ZERO }
	if not multiplayer.is_server():
		Profiler.end("cluster_momentum_dmg")
		return empty_result
	if grid == null or grid.is_empty():
		Profiler.end("cluster_momentum_dmg")
		return empty_result

	# Find nearest block to hit position
	var _t_search := Time.get_ticks_usec()
	var best_key := Vector3i(-1, -1, -1)
	var best_dist_sq := 999999.0
	for key: Vector3i in grid.block_hp:
		var block_world := global_transform * grid.block_local_pos(key)
		var d := hit_world_pos.distance_squared_to(block_world)
		if d < best_dist_sq:
			best_dist_sq = d
			best_key = key
	var _t_search_us := Time.get_ticks_usec() - _t_search

	if best_dist_sq > 999998.0:
		Profiler.end("cluster_momentum_dmg")
		return empty_result

	var block_world := global_transform * grid.block_local_pos(best_key)
	var hp_before: float = grid.block_hp[best_key]
	var absorbed: float = minf(damage, hp_before)

	grid.block_hp[best_key] -= damage
	if grid.block_hp[best_key] > 0.0:
		_update_compound_shielding_hp()
		Profiler.end("cluster_momentum_dmg")
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": best_key, "block_pos": block_world }

	# Block destroyed — compute momentum speed before erasing
	var momentum_spd := DebrisHelper.calc_momentum_speed(_impact_speed)
	var _t_erase := Time.get_ticks_usec()
	grid.erase_block(best_key)
	_disable_hit_shape(best_key)
	var _t_erase_us := Time.get_ticks_usec() - _t_erase
	var _t_abd := Time.get_ticks_usec()
	_after_blocks_destroyed([best_key], hit_world_pos, [momentum_spd])
	var _t_abd_us := Time.get_ticks_usec() - _t_abd

	var _t_momentum_us := Time.get_ticks_usec() - _t_momentum_total
	print("[PERF] cluster.take_momentum_damage_at %s: search=%dus erase=%dus after_destroyed=%dus total=%dus blocks=%d" % [
		name, _t_search_us, _t_erase_us, _t_abd_us, _t_momentum_us, grid.block_count()])
	GameManager.tick_add("cluster_momentum_damage", _t_momentum_us)
	Profiler.end("cluster_momentum_dmg")
	return { "absorbed": absorbed, "block_destroyed": true,
		"block_key": best_key, "block_pos": block_world }


# ======================================================================
#  Post-destruction cleanup
# ======================================================================

func _after_blocks_destroyed(destroyed_keys: Array[Vector3i],
		blast_origin: Vector3 = Vector3.INF,
		precomputed_speeds: Array[float] = [],
		is_explosion: bool = false) -> void:
	## Shared cleanup after blocks are destroyed. Updates mass, syncs to
	## clients, spawns debris, and schedules visual rebuild.
	## blast_origin: explosion/attacker/impact position for debris direction (INF = random).
	## precomputed_speeds: per-block speeds from caller (empty = fallback to hitscan).
	## is_explosion: true = mirror debris away from blast; false = direct toward origin.
	Profiler.begin("cluster_after_destroyed")
	var _t_abd_start := Time.get_ticks_usec()

	# Wake up frozen/settled clusters so they (and any fragments) fall properly.
	# Wake sleeping clusters so they (and any fragments) fall properly.
	if multiplayer.is_server() and sleeping:
		sleeping = false
		_settle_timer = 0.0

	var _t_mass := Time.get_ticks_usec()
	_update_mass()
	var _t_mass_us := Time.get_ticks_usec() - _t_mass
	_mesh_dirty = true
	set_process(true)

	# Compute world positions and use precomputed speeds (or fallback)
	var _t_prep := Time.get_ticks_usec()
	var block_positions: Array[Vector3] = []
	var debris_speeds: Array[float] = []
	var has_speeds := precomputed_speeds.size() == destroyed_keys.size()
	for i in destroyed_keys.size():
		var local_pos := grid.block_local_pos(destroyed_keys[i])
		var world_pos := global_transform * local_pos
		block_positions.append(world_pos)
		if has_speeds:
			debris_speeds.append(precomputed_speeds[i])
		else:
			debris_speeds.append(DebrisHelper.calc_hitscan_speed(0.0))
	var _t_prep_us := Time.get_ticks_usec() - _t_prep

	# Sync to clients (call_remote — server rebuilds via _process)
	var _t_rpc := Time.get_ticks_usec()
	var keys_variant: Array = []
	var positions_variant: Array = []
	var speeds_variant: Array = []
	for i in destroyed_keys.size():
		keys_variant.append(destroyed_keys[i])
		positions_variant.append(block_positions[i])
		speeds_variant.append(debris_speeds[i])
	_sync_blocks_destroyed.rpc(keys_variant, positions_variant, speeds_variant,
		blast_origin, is_explosion)
	var _t_rpc_us := Time.get_ticks_usec() - _t_rpc

	# Host also spawns debris locally (RPC is call_remote)
	var _t_debris := Time.get_ticks_usec()
	_spawn_debris_for_blocks(block_positions, debris_speeds, blast_origin, is_explosion)
	var _t_debris_us := Time.get_ticks_usec() - _t_debris

	if grid.is_empty():
		var total_us := Time.get_ticks_usec() - _t_abd_start
		print("[ClusterPerf] _after_blocks_destroyed %s (empty): mass=%dus prep=%dus rpc=%dus debris=%dus total=%dus" % [
			name, _t_mass_us, _t_prep_us, _t_rpc_us, _t_debris_us, total_us])
		Profiler.end("cluster_after_destroyed")
		_clear_physics_before_free()
		queue_free()
		return

	# Check if remaining blocks split into disconnected groups
	var _t_integrity := Time.get_ticks_usec()
	_check_cluster_integrity()
	var _t_integrity_us := Time.get_ticks_usec() - _t_integrity
	var total_us := Time.get_ticks_usec() - _t_abd_start
	print("[ClusterPerf] _after_blocks_destroyed %s: %d destroyed, %d remaining, mass=%dus prep=%dus rpc=%dus debris=%dus integrity=%dus total=%dus" % [
		name, destroyed_keys.size(), grid.block_count(), _t_mass_us, _t_prep_us, _t_rpc_us, _t_debris_us, _t_integrity_us, total_us])
	GameManager.tick_add("cluster_after_destroyed", total_us)
	Profiler.end("cluster_after_destroyed")


func _update_mass() -> void:
	cluster_mass = grid.block_count() * _mass_per_block
	mass = maxf(cluster_mass, 0.1)
	# Keep C++ shielding HP in sync with remaining block HP
	PhysicsServer3D.body_set_shielding_hp(get_rid(), grid.get_total_hp())


@rpc("authority", "call_remote", "reliable")
func _sync_blocks_destroyed(keys: Array, positions: Array = [],
		speeds: Array = [], p_blast_origin: Vector3 = Vector3.INF,
		p_is_explosion: bool = false) -> void:
	## Client-side: remove destroyed blocks, spawn debris, and schedule visual rebuild.
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
	for key_variant in keys:
		var key: Vector3i = key_variant
		grid.erase_block(key)
		_disable_hit_shape(key)
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
	_mesh_dirty = true
	set_process(true)

	# Spawn cosmetic debris on the client
	if not positions.is_empty():
		var typed_positions: Array[Vector3] = []
		var typed_speeds: Array[float] = []
		for i in positions.size():
			typed_positions.append(positions[i] as Vector3)
			typed_speeds.append(float(speeds[i]) if i < speeds.size() else 8.0)
		_spawn_debris_for_blocks(typed_positions, typed_speeds, p_blast_origin, p_is_explosion)

	if grid.is_empty():
		_clear_physics_before_free()
		queue_free()


func _spawn_debris_for_blocks(block_positions: Array[Vector3],
		debris_speeds: Array[float], blast_origin: Vector3 = Vector3.INF,
		is_explosion: bool = false) -> void:
	## Spawn cosmetic debris for destroyed blocks (both server host and clients).
	## blast_origin: hit/attacker position (INF = random scatter).
	## is_explosion: if true, mirrors per-block away from blast (like structures).
	##   If false, passes blast_origin directly as blast_center (hitscan/momentum).
	var _t_spawn_debris := Time.get_ticks_usec()
	var mat := get_cluster_material()
	if mat == null:
		return
	var has_blast := blast_origin != Vector3.INF
	var n_blocks := block_positions.size()
	var batch_positions := PackedVector3Array()
	var batch_centers := PackedVector3Array()
	var batch_counts := PackedInt32Array()
	var batch_speeds := PackedFloat32Array()
	batch_positions.resize(n_blocks)
	batch_centers.resize(n_blocks)
	batch_counts.resize(n_blocks)
	batch_speeds.resize(n_blocks)
	var total_debris := 0
	for i in n_blocks:
		var pos: Vector3 = block_positions[i]
		batch_positions[i] = pos
		batch_speeds[i] = debris_speeds[i] if i < debris_speeds.size() else 8.0
		batch_counts[i] = randi_range(1, 2)
		total_debris += batch_counts[i]
		if has_blast:
			if is_explosion:
				batch_centers[i] = pos + (pos - blast_origin)
			else:
				batch_centers[i] = blast_origin
		else:
			batch_centers[i] = pos + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized() * 0.5
	var _t_batch := Time.get_ticks_usec()
	DebrisHelper.spawn_debris_batch(
		batch_positions, batch_centers, batch_counts, batch_speeds,
		mat, {"lifetime": _debris_lifetime, "mass": _debris_mass})
	var _t_batch_us := Time.get_ticks_usec() - _t_batch
	var _t_spawn_us := Time.get_ticks_usec() - _t_spawn_debris
	if _t_spawn_us > 100:
		print("[PERF] cluster._spawn_debris_for_blocks %s: %d blocks, %d debris, batch=%dus total=%dus" % [
			name, n_blocks, total_debris, _t_batch_us, _t_spawn_us])


# ======================================================================
#  Cluster fragmentation — split disconnected groups into child clusters
# ======================================================================

func _check_cluster_stress() -> void:
	## Run force-equilibrium stress solver on this cluster.
	## Builds ground mask from bottom blocks touching terrain,
	## external load from active body contacts, and splits overloaded sections.
	if not multiplayer.is_server():
		return
	if grid == null or grid.block_count() < 2:
		return

	var t0 := Time.get_ticks_usec()
	var block_grid: PackedByteArray = grid.block_grid
	var num_x: int = grid.num_x
	var num_y: int = grid.num_y
	var num_z: int = grid.num_z
	var ny_nz := num_y * num_z

	# Build ground mask: raycast down from bottom blocks to find terrain.
	var ground_mask := PackedByteArray()
	ground_mask.resize(block_grid.size())
	ground_mask.fill(0)
	_has_ground_contact = false

	var space_state := get_world_3d().direct_space_state
	if space_state:
		var query := PhysicsRayQueryParameters3D.new()
		query.collision_mask = CollisionLayers.WORLD
		query.exclude = [get_rid()]
		for bx in num_x:
			for bz in num_z:
				for by in num_y:
					var idx := bx * ny_nz + by * num_z + bz
					if not block_grid[idx]:
						continue
					var local_pos := grid.block_local_pos(Vector3i(bx, by, bz))
					var bottom := global_transform * (local_pos - Vector3(0, BlockGridManager.BLOCK_SIZE * 0.5, 0))
					query.from = bottom + Vector3(0, 0.01, 0)
					query.to = bottom - Vector3(0, BlockGridManager.BLOCK_SIZE * 0.5, 0)
					var result := space_state.intersect_ray(query)
					if result:
						ground_mask[idx] = 1
						_has_ground_contact = true
					break  # only check lowest per column

	if not _has_ground_contact:
		return  # floating — no stress, just connectivity

	# Build external load: distribute contact body masses to nearest blocks.
	var external_load := PackedFloat32Array()
	external_load.resize(block_grid.size())
	external_load.fill(0.0)
	var block_mass := _mass_per_block

	for body_rid in _active_body_contacts:
		var body_mass: float = _active_body_contacts[body_rid]
		# Find nearest block to the contact body's position.
		# RID->Node isn't recoverable from RID alone, so we look up via the parallel _active_body_nodes map.
		var body_node: Node = _active_body_nodes.get(body_rid)
		if body_node == null or not is_instance_valid(body_node):
			continue
		var body_pos: Vector3 = body_node.global_position if body_node is Node3D else global_position
		var local_pos: Vector3 = global_transform.affine_inverse() * body_pos
		var best_idx := -1
		var best_dist := 999999.0
		for bx in num_x:
			for by in num_y:
				for bz in num_z:
					var idx := bx * ny_nz + by * num_z + bz
					if not block_grid[idx]:
						continue
					var bp := grid.block_local_pos(Vector3i(bx, by, bz))
					var d := local_pos.distance_squared_to(bp)
					if d < best_dist:
						best_dist = d
						best_idx = idx
		if best_idx >= 0:
			external_load[best_idx] += body_mass / block_mass

	# Run stress solver
	var components: Array = BlockMeshBuilder.calc_stress_integrity_components(
		block_grid, ground_mask, external_load,
		num_x, num_y, num_z, grid.block_count(),
		CLUSTER_MAX_LOAD, CLUSTER_H_TRANSFER)

	var us := Time.get_ticks_usec() - t0
	if not components.is_empty():
		print("[ClusterStress] %s  %d components failed  %dus" % [name, components.size(), us])
		# Convert stress-failed blocks to destroyed blocks
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
		var destroyed_keys: Array[Vector3i] = []
		for component in components:
			for key in component:
				if grid.has_block(key):
					destroyed_keys.append(key)
					grid.erase_block(key)
					_disable_hit_shape(key)
		if _compound_hit_body and is_instance_valid(_compound_hit_body):
			PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
		if not destroyed_keys.is_empty():
			_after_blocks_destroyed(destroyed_keys)


func _check_cluster_integrity() -> void:
	## Server-only: if remaining blocks form multiple disconnected groups,
	## split smaller groups into new child FallingBlockCluster instances.
	## Uses a single batched RPC so all fragments are built in one C++ call.
	if not multiplayer.is_server():
		return
	if grid.block_count() < 2:
		return

	Profiler.begin("cluster_integrity")
	var _t_integrity_start := Time.get_ticks_usec()
	var _t_bfs_start := Time.get_ticks_usec()
	var components := grid.find_all_components()

	var _t_bfs_us := Time.get_ticks_usec() - _t_bfs_start

	if components.size() <= 1:
		Profiler.end("cluster_integrity")
		return

	# Keep the largest component in self, split off the rest
	var largest_idx := 0
	for i in components.size():
		if components[i].size() > components[largest_idx].size():
			largest_idx = i

	# Collect all fragment key lists into one batched RPC
	var _t_splits := Time.get_ticks_usec()
	var all_fragment_keys: Array = []
	for i in components.size():
		if i == largest_idx:
			continue
		var keys_variant: Array = []
		for key in components[i]:
			keys_variant.append(key)
		all_fragment_keys.append(keys_variant)

	if not all_fragment_keys.is_empty():
		_sync_fragment_split_batch.rpc(all_fragment_keys)
	var _t_splits_us := Time.get_ticks_usec() - _t_splits
	var _t_integrity_us := Time.get_ticks_usec() - _t_integrity_start
	print("[ClusterPerf] _check_cluster_integrity %s: %d blocks, %d components, %d splits, bfs=%dus splits=%dus total=%dus" % [
		name, grid.block_count(), components.size(), all_fragment_keys.size(), _t_bfs_us, _t_splits_us, _t_integrity_us])
	GameManager.tick_add("cluster_integrity", _t_integrity_us)
	Profiler.end("cluster_integrity")


@rpc("authority", "call_local", "reliable")
func _sync_fragment_split_batch(all_fragment_keys: Array) -> void:
	## All peers: split ALL specified fragment groups off into child clusters
	## in one batched C++ call. Bulk mode wraps ALL bodies at once.
	var _t_total := Time.get_ticks_usec()

	# Phase 1: Extract block HPs and erase from grid for all fragments.
	var _t_extract := Time.get_ticks_usec()
	var fragment_dicts: Array = []
	# Bulk mode: disable all fragment shapes in one commit instead of N rebuilds.
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), true)
	for keys_variant: Array in all_fragment_keys:
		var block_hp_dict: Dictionary = {}
		for key_variant in keys_variant:
			var key: Vector3i = key_variant
			if grid.has_block(key):
				block_hp_dict[key] = grid.block_hp[key]
				_disable_hit_shape(key)
				grid.erase_block(key)
		if not block_hp_dict.is_empty():
			fragment_dicts.append(block_hp_dict)
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shapes_bulk_mode(_compound_hit_body.get_rid(), false)
	var _t_extract_us := Time.get_ticks_usec() - _t_extract

	if fragment_dicts.is_empty():
		return

	# Update self: mass, visuals, shapes
	_update_mass()
	_mesh_dirty = true
	set_process(true)

	if grid.is_empty():
		_clear_physics_before_free()
		queue_free()
		return

	# Phase 2: Create all child bodies and hit bodies (need RIDs for batch call).
	var _t_create := Time.get_ticks_usec()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var children: Array = []
	var spawn_positions: Array = []
	var cluster_body_rids: Array = []
	var hit_body_rids: Array = []

	# Shared hit shape for all children
	if _shared_hit_shape == null:
		_shared_hit_shape = BoxShape3D.new()
		_shared_hit_shape.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE

	for block_hp_dict: Dictionary in fragment_dicts:
		var block_keys: Array[Vector3i] = []
		for key: Vector3i in block_hp_dict:
			block_keys.append(key)

		var child_mass := float(block_keys.size()) * _mass_per_block

		# Compute child centroid in grid space for spawn position
		var child_centroid_grid := Vector3.ZERO
		for key: Vector3i in block_keys:
			child_centroid_grid += grid.block_local_pos_raw(key)
		child_centroid_grid /= float(block_keys.size())
		var spawn_pos := global_position + global_transform.basis * (child_centroid_grid - grid.centroid)

		# Build child RigidBody3D
		var child := RigidBody3D.new()
		child.set_script(get_script())
		child.name = "FallingCluster_frag_%d" % (randi() % 10000)
		child.mass = child_mass
		child.cluster_mass = child_mass
		child.attacker_id = attacker_id
		child.collision_layer = collision_layer
		child.collision_mask = collision_mask
		child.contact_monitor = true
		child.max_contacts_reported = 4
		child.gravity_scale = 1.0
		child.continuous_cd = true

		# Create grid manager (needed for ongoing damage tracking)
		child.grid = BlockGridManager.new()
		child.grid.num_x = grid.num_x
		child.grid.num_y = grid.num_y
		child.grid.num_z = grid.num_z
		child.grid.block_hp = block_hp_dict

		# Create mesh instance
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.name = "ClusterMesh"
		mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		child.add_child(mesh_inst)
		child._mesh_instance = mesh_inst

		# Create compound hit body (need RID for batch call)
		child._shared_hit_shape = _shared_hit_shape
		var hit_body := StaticBody3D.new()
		hit_body.set_script(_compound_body_script)
		hit_body.parent_wall = child
		hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
		hit_body.collision_mask = 0
		hit_body.name = "CompoundHitBody"
		child._compound_hit_body = hit_body

		children.append(child)
		spawn_positions.append(spawn_pos)
		cluster_body_rids.append(child.get_rid())
		hit_body_rids.append(hit_body.get_rid())
	var _t_create_us := Time.get_ticks_usec() - _t_create

	# Phase 3: One batched C++ call — all grids, meshes, and shapes at once.
	var _t_build := Time.get_ticks_usec()
	var results: Array = BlockMeshBuilder.build_clusters_batch(
		fragment_dicts, grid.num_x, grid.num_y, grid.num_z,
		BlockGridManager.BLOCK_SIZE, cluster_body_rids, hit_body_rids,
		_shared_hit_shape.get_rid())
	var _t_build_us := Time.get_ticks_usec() - _t_build

	# Phase 4: Unpack results and add children to scene tree.
	var _t_finish := Time.get_ticks_usec()
	var parent_node := get_parent()
	for i in children.size():
		var child: FallingBlockCluster = children[i]
		var result: Dictionary = results[i]

		# Unpack grid data
		child.grid.block_grid = result["block_grid"]
		child.grid.centroid = result["centroid"]

		# Set mesh
		child._mesh_instance.mesh = result["mesh"]

		# Store collision shape refs
		child._col_shapes = result["col_shapes"]
		child._col_shape_count = result["col_count"]

		# Unpack hit body shape→key mappings
		var shape_keys: Array = result["shape_to_key"]
		child._shape_to_key.clear()
		child._key_to_shape.clear()
		for si in shape_keys.size():
			var key: Vector3i = shape_keys[si]
			child._shape_to_key.append(key)
			child._key_to_shape[key] = si
		child._compound_hit_body._shape_to_key = child._shape_to_key

		# Add compound hit body to child
		child.add_child(child._compound_hit_body)
		PhysicsServer3D.body_set_shielding_tag(child._compound_hit_body.get_rid(), 1)
		child._update_compound_shielding_hp()

		# Material and debris config
		var mat := get_cluster_material()
		if mat:
			child.set_material(mat)
		child.set_debris_config(_debris_size, _debris_lifetime, _debris_mass,
			_debris_name, _block_hp_max)

		# Add to scene tree
		if parent_node:
			parent_node.add_child(child)
		else:
			scene_root.add_child(child)
		child.global_transform = Transform3D(global_transform.basis, spawn_positions[i])

		# Server: inherit velocity and register shielding
		if multiplayer.is_server():
			var offset: Vector3 = spawn_positions[i] - global_position
			child.linear_velocity = linear_velocity + angular_velocity.cross(offset)
			child.angular_velocity = angular_velocity

			var child_rid := child.get_rid()
			PhysicsServer3D.body_set_shielding_tag(child_rid, 4)
			PhysicsServer3D.body_set_shielding_hp(child_rid, child.grid.get_total_hp())
	var _t_finish_us := Time.get_ticks_usec() - _t_finish

	var total_us := Time.get_ticks_usec() - _t_total
	print("[ClusterPerf] _sync_fragment_split_batch %s: %d fragments, extract=%dus create=%dus build=%dus finish=%dus total=%dus" % [
		name, fragment_dicts.size(), _t_extract_us, _t_create_us, _t_build_us, _t_finish_us, total_us])


func _spawn_child_cluster(block_hp_dict: Dictionary) -> void:
	## Create a new FallingBlockCluster from split-off blocks on all peers.
	var _t_spawn := Time.get_ticks_usec()
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var block_keys: Array[Vector3i] = []
	for key: Vector3i in block_hp_dict:
		block_keys.append(key)

	var child_mass := float(block_keys.size()) * _mass_per_block

	# Compute child centroid in grid space
	var child_centroid_grid := Vector3.ZERO
	for key: Vector3i in block_keys:
		child_centroid_grid += grid.block_local_pos_raw(key)
	child_centroid_grid /= float(block_keys.size())

	# World position: parent origin + basis * (child centroid offset from parent centroid)
	var spawn_pos := global_position + global_transform.basis * (child_centroid_grid - grid.centroid)

	# Build child RigidBody3D
	var child := RigidBody3D.new()
	child.set_script(get_script())
	child.name = "FallingCluster_frag_%d" % (randi() % 10000)
	child.mass = child_mass
	child.cluster_mass = child_mass
	child.attacker_id = attacker_id
	child.collision_layer = collision_layer
	child.collision_mask = collision_mask
	child.contact_monitor = true
	child.max_contacts_reported = 4
	child.gravity_scale = 1.0
	child.continuous_cd = true

	# Initialize block tracking — builds compound hit body
	var _t_init := Time.get_ticks_usec()
	child.init_cluster_blocks(block_hp_dict, grid.num_x, grid.num_y, grid.num_z,
		_mass_per_block)
	var mat := get_cluster_material()
	if mat:
		child.set_material(mat)
	child.set_debris_config(_debris_size, _debris_lifetime, _debris_mass,
		_debris_name, _block_hp_max)
	var _t_init_us := Time.get_ticks_usec() - _t_init

	# Add to scene (triggers _ready, Jolt body registration, all child shapes added to physics)
	var _t_addchild := Time.get_ticks_usec()
	var parent_node := get_parent()
	if parent_node:
		parent_node.add_child(child)
	else:
		scene_root.add_child(child)
	child.global_transform = Transform3D(global_transform.basis, spawn_pos)
	var _t_addchild_us := Time.get_ticks_usec() - _t_addchild

	# Server: inherit velocity and register shielding
	if multiplayer.is_server():
		var offset := spawn_pos - global_position
		child.linear_velocity = linear_velocity + angular_velocity.cross(offset)
		child.angular_velocity = angular_velocity

		var child_rid := child.get_rid()
		PhysicsServer3D.body_set_shielding_tag(child_rid, 4)
		PhysicsServer3D.body_set_shielding_hp(child_rid, child.grid.get_total_hp())

	var total_us := Time.get_ticks_usec() - _t_spawn
	print("[ClusterPerf] _spawn_child_cluster %s->%s: %d blocks, children=%d, init=%dus add_child=%dus total=%dus" % [
		name, child.name, block_keys.size(), child.get_child_count(), _t_init_us, _t_addchild_us, total_us])


# ======================================================================
#  Contact damage — momentum-based carving
# ======================================================================

func _on_body_exited(body: Node) -> void:
	if body is PhysicsBody3D:
		var rid: RID = body.get_rid()
		_active_body_contacts.erase(rid)
		_active_body_nodes.erase(rid)


func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return

	# Track contact for stress solver (mass of contacting body)
	if body is RigidBody3D:
		var rid: RID = body.get_rid()
		_active_body_contacts[rid] = body.mass
		_active_body_nodes[rid] = body
	elif body is Player:
		var rid: RID = body.get_rid()
		_active_body_contacts[rid] = 80.0  # player mass
		_active_body_nodes[rid] = body

	# Wake up settled clusters so physics + stress checks resume
	if sleeping:
		sleeping = false
		_settle_timer = 0.0
		set_physics_process(true)


func _compute_impact(body: Node, other_velocity: Vector3 = Vector3.ZERO) -> Dictionary:
	## Compute contact velocity (including angular velocity at contact point)
	## and momentum-based structure damage. Returns empty dict if below threshold.
	var contact_offset: Vector3 = body.global_position - global_position
	var contact_velocity: Vector3 = linear_velocity + angular_velocity.cross(contact_offset)
	var relative_vel: Vector3 = contact_velocity - other_velocity
	var impact_speed: float = relative_vel.length()

	if impact_speed < MIN_DAMAGE_SPEED:
		return {}

	var momentum: float = cluster_mass * impact_speed
	var base_damage: float = momentum * MOMENTUM_DAMAGE_SCALE * GameManager.structure_momentum_damage_scale
	var contact_point: Vector3 = (global_position + body.global_position) * 0.5

	return {
		"impact_speed": impact_speed,
		"momentum": momentum,
		"base_damage": base_damage,
		"contact_point": contact_point,
	}


func _handle_generic_hit(body: Node) -> void:
	## Momentum-based structure damage to any damageable body (player, etc.).
	## Uses the same momentum formula as structure carving.
	if not body.has_method("take_damage"):
		return

	var impact := _compute_impact(body)
	if impact.is_empty():
		return

	body.take_damage(impact["base_damage"], attacker_id)

	# Mutual damage — the collision damages this cluster too
	var contact_point: Vector3 = impact["contact_point"]
	take_momentum_damage_at(contact_point, impact["base_damage"], -1, impact["impact_speed"])

	print("[FallingCluster] Hit %s for %.1f structure damage (speed=%.1f mass=%.1f)" % [
		body.name, impact["base_damage"], impact["impact_speed"], cluster_mass])


func _handle_structure_hit(body: Node, target_structure: DestructibleBlockStructure) -> void:
	## Momentum-based carving: compute contact velocity including angular velocity,
	## damage the nearest block in both the target structure and this cluster.
	var impact := _compute_impact(body)
	if impact.is_empty():
		return

	var base_damage: float = impact["base_damage"]
	var impact_speed: float = impact["impact_speed"]
	var contact_point: Vector3 = impact["contact_point"]

	# Damage target structure at the contact point
	var _t0 := Time.get_ticks_usec()
	var target_result: Dictionary = target_structure.take_momentum_damage_at(
		contact_point, base_damage, attacker_id, impact_speed
	)
	var _t_target_dmg := Time.get_ticks_usec() - _t0
	var target_absorbed: float = target_result.get("absorbed", 0.0)

	# Resistance force — absorbed HP slows the impactor
	var remaining_speed := impact_speed
	if target_absorbed > 0.0 and linear_velocity.length_squared() > 0.01:
		var resistance_mass: float = target_absorbed * MASS_PER_HP
		var speed_reduction: float = resistance_mass / cluster_mass * impact_speed * 0.5 * GameManager.structure_resistance_scale
		remaining_speed = maxf(impact_speed - speed_reduction, 0.0)
		var brake_impulse: Vector3 = -linear_velocity.normalized() * speed_reduction * cluster_mass
		apply_central_impulse(brake_impulse)

	# Breakthrough explosion on TARGET structure — per-block momentum at remaining speed
	var _t_target_expl := 0
	if target_result.get("block_destroyed", false) and remaining_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * remaining_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = target_result.get("block_pos", contact_point)
		if expl_damage > 0.5 and expl_radius > 0.1:
			_t0 = Time.get_ticks_usec()
			target_structure.take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], remaining_speed)
			_t_target_expl = Time.get_ticks_usec() - _t0

	# Mutual damage — same collision, same damage to this cluster
	_t0 = Time.get_ticks_usec()
	var self_result: Dictionary = take_momentum_damage_at(contact_point, base_damage, -1, impact_speed)
	var _t_self_dmg := Time.get_ticks_usec() - _t0

	# Breakthrough explosion on SELF — per-block momentum at remaining speed
	var _t_self_expl := 0
	if self_result.get("block_destroyed", false) and remaining_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * remaining_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = self_result.get("block_pos", contact_point)
		if expl_damage > 0.5 and not grid.is_empty():
			_t0 = Time.get_ticks_usec()
			take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], remaining_speed)
			_t_self_expl = Time.get_ticks_usec() - _t0

	print("[FallingCluster] Carve into %s: dmg=%.1f absorbed=%.1f remaining_speed=%.1f" % [
		target_structure.name, base_damage, target_absorbed, remaining_speed])
	var total_us := _t_target_dmg + _t_target_expl + _t_self_dmg + _t_self_expl
	if total_us > 100:
		print("[ClusterPerf] _handle_structure_hit %s->%s: target_dmg=%dus target_expl=%dus self_dmg=%dus self_expl=%dus total=%dus" % [
			name, target_structure.name, _t_target_dmg, _t_target_expl, _t_self_dmg, _t_self_expl, total_us])


func _handle_cluster_vs_cluster(other: FallingBlockCluster) -> void:
	## Two falling clusters collide. Both take per-block momentum damage at the
	## contact point. Only called on the cluster with the higher instance_id.
	var _t_cvc := Time.get_ticks_usec()

	# Compute relative contact velocity (both may have angular velocity)
	var contact_offset_self: Vector3 = other.global_position - global_position
	var my_contact_vel: Vector3 = linear_velocity + angular_velocity.cross(contact_offset_self)

	var contact_offset_other: Vector3 = global_position - other.global_position
	var other_contact_vel: Vector3 = other.linear_velocity + other.angular_velocity.cross(contact_offset_other)

	var relative_vel: Vector3 = my_contact_vel - other_contact_vel
	var impact_speed: float = relative_vel.length()

	if impact_speed < MIN_DAMAGE_SPEED:
		return

	# Each cluster damages the other proportional to its own momentum
	var my_momentum: float = cluster_mass * impact_speed
	var other_momentum: float = other.cluster_mass * impact_speed

	var my_damage: float = my_momentum * MOMENTUM_DAMAGE_SCALE * GameManager.structure_momentum_damage_scale
	var other_damage: float = other_momentum * MOMENTUM_DAMAGE_SCALE * GameManager.structure_momentum_damage_scale

	var contact_midpoint: Vector3 = (global_position + other.global_position) * 0.5

	# This cluster damages the other
	var _t0 := Time.get_ticks_usec()
	var other_result: Dictionary = other.take_momentum_damage_at(
		contact_midpoint, my_damage, attacker_id, impact_speed)
	var _t_other_dmg := Time.get_ticks_usec() - _t0

	# Other cluster damages this one
	_t0 = Time.get_ticks_usec()
	var self_result: Dictionary = take_momentum_damage_at(
		contact_midpoint, other_damage, other.attacker_id, impact_speed)
	var _t_self_dmg := Time.get_ticks_usec() - _t0

	# Breakthrough on the other cluster (from this cluster's remaining momentum)
	var _t_other_expl := 0
	if other_result.get("block_destroyed", false) and impact_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * impact_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = other_result.get("block_pos", contact_midpoint)
		if expl_damage > 0.5 and not other.grid.is_empty():
			_t0 = Time.get_ticks_usec()
			other.take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], impact_speed)
			_t_other_expl = Time.get_ticks_usec() - _t0

	# Breakthrough on this cluster (from other cluster's remaining momentum)
	var _t_self_expl := 0
	if self_result.get("block_destroyed", false) and impact_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = other._mass_per_block * impact_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = self_result.get("block_pos", contact_midpoint)
		if expl_damage > 0.5 and not grid.is_empty():
			_t0 = Time.get_ticks_usec()
			take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], impact_speed)
			_t_self_expl = Time.get_ticks_usec() - _t0

	var total_us := Time.get_ticks_usec() - _t_cvc
	print("[FallingCluster] Cluster vs cluster: %s(%.1fkg) vs %s(%.1fkg) speed=%.1f" % [
		name, cluster_mass, other.name, other.cluster_mass, impact_speed])
	if total_us > 100:
		print("[ClusterPerf] _handle_cluster_vs_cluster %s vs %s: other_dmg=%dus self_dmg=%dus other_expl=%dus self_expl=%dus total=%dus" % [
			name, other.name, _t_other_dmg, _t_self_dmg, _t_other_expl, _t_self_expl, total_us])


# ======================================================================
#  Visual, collision, and hit body rebuild
# ======================================================================

func _rebuild_visuals() -> void:
	## Rebuild mesh and per-column collision shapes from the current block grid.
	## Compound hit body shapes are disabled individually — no rebuild needed.
	if grid == null or grid.is_empty():
		return
	var _t0 := Time.get_ticks_usec()
	# Rebuild mesh
	var new_mesh: Mesh = grid.build_mesh()
	if _mesh_instance:
		_mesh_instance.mesh = new_mesh
	elif _visual_rid.is_valid():
		_visual_mesh_ref = new_mesh
		if new_mesh:
			RenderingServer.instance_set_base(_visual_rid, new_mesh.get_rid())
	var _t_mesh_us := Time.get_ticks_usec() - _t0

	# Rebuild collision shapes (remove old, create new)
	var _t1 := Time.get_ticks_usec()
	_rebuild_collision_shapes()
	var _t_col_us := Time.get_ticks_usec() - _t1

	# Update compound body shielding HP (shapes already disabled individually)
	_update_compound_shielding_hp()

	var total_us := _t_mesh_us + _t_col_us
	print("[ClusterPerf] _rebuild_visuals %s: %d blocks, mesh=%dus collision=%dus total=%dus" % [
		name, grid.block_count(), _t_mesh_us, _t_col_us, total_us])


func _rebuild_collision_shapes() -> void:
	## Remove old shapes and rebuild from grid using direct PhysicsServer3D calls.
	## No CollisionShape3D nodes — shapes are added to this body's RID directly.
	var body_rid := get_rid()

	var _t_free := Time.get_ticks_usec()
	# Remove old shapes from body (remove from end to avoid index shifting)
	while _col_shape_count > 0:
		_col_shape_count -= 1
		PhysicsServer3D.body_remove_shape(body_rid, _col_shape_count)
	_col_shapes.clear()
	var _t_free_us := Time.get_ticks_usec() - _t_free

	if grid.is_empty():
		return

	var _t_create := Time.get_ticks_usec()
	var shapes := grid.compute_column_shapes()
	var _t_compute_us := Time.get_ticks_usec() - _t_create

	var _t_add := Time.get_ticks_usec()
	# Build flat position/size arrays for bulk C++ call
	var positions := PackedVector3Array()
	var sizes := PackedVector3Array()
	positions.resize(shapes.size())
	sizes.resize(shapes.size())
	for i in shapes.size():
		positions[i] = shapes[i]["position"]
		sizes[i] = shapes[i]["size"]
	_col_shapes = BlockMeshBuilder.bulk_add_box_shapes(body_rid, positions, sizes)
	_col_shape_count = shapes.size()
	var _t_add_us := Time.get_ticks_usec() - _t_add

	var total_us := _t_free_us + _t_compute_us + _t_add_us
	if total_us > 200:
		print("[ClusterPerf] _rebuild_collision_shapes %s: compute=%dus add=%d(%dus) total=%dus" % [
			name, _t_compute_us, shapes.size(), _t_add_us, total_us])


# ======================================================================
#  Compound hit body — one StaticBody3D with N shapes
# ======================================================================

func _build_compound_hit_body() -> void:
	## Build a single compound StaticBody3D with one BoxShape3D per block.
	## All shapes share the same RID, positioned via local transforms.
	## Shapes are added before the body enters the physics space (before
	## add_child on the cluster), so all N shapes register in one broadphase
	## insert — much faster than N individual StaticBody3D nodes.
	_clear_compound_hit_body()

	if grid == null or grid.is_empty():
		return

	# Shared box shape (kept alive as member)
	if _shared_hit_shape == null:
		_shared_hit_shape = BoxShape3D.new()
		_shared_hit_shape.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE
	var shape_rid := _shared_hit_shape.get_rid()

	# Create the compound body node
	_compound_hit_body = StaticBody3D.new()
	_compound_hit_body.set_script(_compound_body_script)
	_compound_hit_body.parent_wall = self
	_compound_hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
	_compound_hit_body.collision_mask = 0
	_compound_hit_body.name = "CompoundHitBody"

	# Build position array and key mappings
	var body_rid := _compound_hit_body.get_rid()
	_shape_to_key.clear()
	_key_to_shape.clear()

	var positions := PackedVector3Array()
	positions.resize(grid.block_hp.size())
	var shape_idx := 0
	for key: Vector3i in grid.block_hp:
		positions[shape_idx] = grid.block_local_pos(key)
		_shape_to_key.append(key)
		_key_to_shape[key] = shape_idx
		shape_idx += 1

	# Bulk add all shapes in one C++ call
	BlockMeshBuilder.bulk_add_shapes(body_rid, shape_rid, positions)

	# Push mapping to the compound body script
	_compound_hit_body._shape_to_key = _shape_to_key

	# Add to scene tree
	add_child(_compound_hit_body)

	# Shielding: tag as wall_block with average HP
	PhysicsServer3D.body_set_shielding_tag(body_rid, 1)
	_update_compound_shielding_hp()


func _clear_compound_hit_body() -> void:
	## Remove the compound hit body and clear mappings.
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		_compound_hit_body.collision_layer = 0
		_compound_hit_body.queue_free()
		_compound_hit_body = null
	_shape_to_key.clear()
	_key_to_shape.clear()


func _disable_hit_shape(key: Vector3i) -> void:
	## Disable the compound body shape for a destroyed/removed block.
	if not _key_to_shape.has(key):
		return
	var shape_idx: int = _key_to_shape[key]
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		PhysicsServer3D.body_set_shape_disabled(_compound_hit_body.get_rid(), shape_idx, true)
	_key_to_shape.erase(key)


func _update_compound_shielding_hp() -> void:
	## Update compound body shielding HP to average block HP.
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		var count := grid.block_count()
		var avg_hp := grid.get_total_hp() / maxf(float(count), 1.0) if count > 0 else 0.0
		PhysicsServer3D.body_set_shielding_hp(_compound_hit_body.get_rid(), avg_hp)


# ======================================================================
#  Utility
# ======================================================================

func _clear_physics_before_free() -> void:
	## Zero collision layers so Jolt drops this body from broadphase immediately.
	## Prevents phantom collisions during the queue_free() deferral window.
	collision_layer = 0
	collision_mask = 0
	if _compound_hit_body and is_instance_valid(_compound_hit_body):
		_compound_hit_body.collision_layer = 0
	if _visual_rid.is_valid():
		RenderingServer.instance_set_visible(_visual_rid, false)


func _find_structure(node: Node) -> DestructibleBlockStructure:
	## Walk up the tree to find a DestructibleBlockStructure ancestor.
	## The smooth collision StaticBody3D is a child of the structure.
	var current := node
	for _i in 4:
		if current == null:
			break
		if current is DestructibleBlockStructure:
			return current
		current = current.get_parent()
	return null
