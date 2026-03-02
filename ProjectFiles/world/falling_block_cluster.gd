extends PhysicsBodyBase
class_name FallingBlockCluster

## Falling cluster of blocks detached from a DestructibleBlockStructure when
## structural integrity fails.  Uses BlockGridManager for block data, mesh
## building, and collision shape computation — the same shared logic that
## structures use.
##
## Per-block StaticBody3D hit bodies (layer 11 / WALL_BLOCKS) let hitscans
## target individual blocks via wall_block.gd, identical to static structures.
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
#  Per-block hit detection — StaticBody3D children on layer 11 (WALL_BLOCKS)
#  Hitscans target individual blocks via wall_block.gd → _damage_block()
# ======================================================================

var _hit_bodies: Dictionary = {}       ## Vector3i → StaticBody3D
var _shared_block_shape: BoxShape3D = null
var _block_script: GDScript = preload("res://world/wall_block.gd")

# ======================================================================
#  Internal state
# ======================================================================

var _settle_timer: float = 0.0
var _mesh_dirty: bool = false
## Cached child node ref for mesh rebuild (set in init_cluster_blocks)
var _mesh_instance: MeshInstance3D = null

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
	## mesh, collision shapes, and per-block hit bodies.
	_mass_per_block = mass_per_blk

	# Create and populate the shared grid manager
	grid = BlockGridManager.new()
	grid.init_grid(num_x, num_y, num_z)
	for key: Vector3i in block_hp_dict:
		grid.set_block(key, block_hp_dict[key])
	grid.compute_centroid()

	# Create shared block shape for hit bodies
	_shared_block_shape = BoxShape3D.new()
	_shared_block_shape.size = Vector3.ONE * BlockGridManager.BLOCK_SIZE

	# Use existing mesh instance if already added by the spawner, otherwise create one
	_mesh_instance = get_node_or_null("ClusterMesh")
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "ClusterMesh"
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(_mesh_instance)

	# Build mesh, collision shapes, and per-block hit bodies
	_rebuild_visuals()


func set_material(mat: StandardMaterial3D) -> void:
	## Set the material for the cluster mesh.
	if _mesh_instance:
		_mesh_instance.material_override = mat


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
	else:
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	set_process(false)


# ======================================================================
#  Frame processing
# ======================================================================

func _process(_delta: float) -> void:
	## Deferred mesh/shape rebuild after block destruction.
	if _mesh_dirty:
		_mesh_dirty = false
		var _t0 := Time.get_ticks_usec()
		_rebuild_visuals()
		GameManager.frame_add("cluster_mesh", Time.get_ticks_usec() - _t0)
		set_process(false)


func _physics_process(delta: float) -> void:
	var _t0 := Time.get_ticks_usec()
	super._physics_process(delta)

	if not multiplayer.is_server():
		GameManager.tick_add("cluster_tick", Time.get_ticks_usec() - _t0)
		return

	# Freeze on settle: if moving slowly for long enough, stop simulating
	if linear_velocity.length() < SETTLE_SPEED:
		_settle_timer += delta
		if _settle_timer >= SETTLE_TIME:
			freeze = true
	else:
		_settle_timer = 0.0

	GameManager.tick_add("cluster_tick", Time.get_ticks_usec() - _t0)


# ======================================================================
#  Damage — per-block, just like a normal structure
# ======================================================================

func _damage_block(key: Vector3i, amount: float, _attacker_id: int) -> void:
	## Called by wall_block.gd when a hitscan bullet hits a specific block.
	## Targets one block with full damage — no falloff, no shielding.
	if not multiplayer.is_server():
		return
	if not grid.has_block(key):
		return

	grid.block_hp[key] -= amount

	# Update shielding HP on the per-block hit body
	if _hit_bodies.has(key):
		var body: StaticBody3D = _hit_bodies[key]
		if is_instance_valid(body):
			PhysicsServer3D.body_set_shielding_hp(body.get_rid(), maxf(grid.block_hp[key], 0.0))

	if grid.block_hp[key] <= 0.0:
		grid.erase_block(key)
		_free_hit_body(key)
		_after_blocks_destroyed([key])


func take_damage(amount: float, _from_attacker_id: int = -1) -> void:
	## Distribute damage evenly across all remaining blocks.
	## Fallback for non-positional damage sources.
	if not multiplayer.is_server():
		return
	if grid == null or grid.is_empty():
		return

	var per_block: float = amount / float(grid.block_count())
	var destroyed_keys: Array[Vector3i] = []

	for key: Vector3i in grid.block_hp:
		grid.block_hp[key] -= per_block
		if grid.block_hp[key] <= 0.0:
			destroyed_keys.append(key)

	if not destroyed_keys.is_empty():
		for key in destroyed_keys:
			grid.erase_block(key)
			_free_hit_body(key)
		_after_blocks_destroyed(destroyed_keys)


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

		# Keep per-block hit body shielding HP in sync
		if _hit_bodies.has(key):
			var body: StaticBody3D = _hit_bodies[key]
			if is_instance_valid(body):
				PhysicsServer3D.body_set_shielding_hp(body.get_rid(), maxf(grid.block_hp[key], 0.0))

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

	if not destroyed_keys.is_empty():
		for key in destroyed_keys:
			grid.erase_block(key)
			_free_hit_body(key)
		var _t_abd := Time.get_ticks_usec()
		_after_blocks_destroyed(destroyed_keys)
		var _t_abd_us := Time.get_ticks_usec() - _t_abd
		var total_us := Time.get_ticks_usec() - _t_take_damage_at
		print("[ClusterPerf] take_damage_at %s: %d blocks hit, %d destroyed, raycasts=%dus after_destroyed=%dus total=%dus" % [
			name, dbg_blocks_hit, destroyed_keys.size(), _t_raycast_total, _t_abd_us, total_us])
	else:
		var total_us := Time.get_ticks_usec() - _t_take_damage_at
		if total_us > 500:
			print("[ClusterPerf] take_damage_at %s (no destroys): %d blocks hit, raycasts=%dus total=%dus" % [
				name, dbg_blocks_hit, _t_raycast_total, total_us])


func take_momentum_damage_at(hit_world_pos: Vector3, damage: float,
		_attckr_id: int, _impact_speed: float = INF) -> Dictionary:
	## Targeted single-block damage from momentum carving.
	## Finds nearest block, damages it. Breakthrough explosions are handled by
	## the caller using per-block momentum at remaining speed.
	## Returns { "absorbed": float, "block_destroyed": bool, "block_key": Vector3i,
	##           "block_pos": Vector3 }
	var empty_result := { "absorbed": 0.0, "block_destroyed": false,
		"block_key": Vector3i.ZERO, "block_pos": Vector3.ZERO }
	if not multiplayer.is_server():
		return empty_result
	if grid == null or grid.is_empty():
		return empty_result

	# Find nearest block to hit position
	var best_key := Vector3i(-1, -1, -1)
	var best_dist_sq := 999999.0
	for key: Vector3i in grid.block_hp:
		var block_world := global_transform * grid.block_local_pos(key)
		var d := hit_world_pos.distance_squared_to(block_world)
		if d < best_dist_sq:
			best_dist_sq = d
			best_key = key

	if best_dist_sq > 999998.0:
		return empty_result

	var block_world := global_transform * grid.block_local_pos(best_key)
	var hp_before: float = grid.block_hp[best_key]
	var absorbed: float = minf(damage, hp_before)

	grid.block_hp[best_key] -= damage
	if grid.block_hp[best_key] > 0.0:
		# Update per-block hit body shielding HP
		if _hit_bodies.has(best_key):
			var body: StaticBody3D = _hit_bodies[best_key]
			if is_instance_valid(body):
				PhysicsServer3D.body_set_shielding_hp(body.get_rid(), grid.block_hp[best_key])
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": best_key, "block_pos": block_world }

	# Block destroyed
	grid.erase_block(best_key)
	_free_hit_body(best_key)
	_after_blocks_destroyed([best_key])

	return { "absorbed": absorbed, "block_destroyed": true,
		"block_key": best_key, "block_pos": block_world }


# ======================================================================
#  Post-destruction cleanup
# ======================================================================

func _after_blocks_destroyed(destroyed_keys: Array[Vector3i]) -> void:
	## Shared cleanup after blocks are destroyed. Updates mass, syncs to
	## clients, spawns debris, and schedules visual rebuild.
	var _t_abd_start := Time.get_ticks_usec()

	# Wake up frozen/settled clusters so they (and any fragments) fall properly.
	# Without this, a settled cluster that gets split stays frozen in mid-air.
	if multiplayer.is_server() and freeze:
		freeze = false
		_settle_timer = 0.0

	_update_mass()
	_mesh_dirty = true
	set_process(true)

	# Compute world positions for debris spawning before syncing
	var block_positions: Array[Vector3] = []
	var debris_speeds: Array[float] = []
	for key in destroyed_keys:
		var local_pos := grid.block_local_pos(key)
		var world_pos := global_transform * local_pos
		block_positions.append(world_pos)
		# Hitscan-style speed (no blast radius context on clusters)
		debris_speeds.append(DebrisHelper.calc_hitscan_speed(0.0))

	# Sync to clients (call_remote — server rebuilds via _process)
	var keys_variant: Array = []
	var positions_variant: Array = []
	var speeds_variant: Array = []
	for i in destroyed_keys.size():
		keys_variant.append(destroyed_keys[i])
		positions_variant.append(block_positions[i])
		speeds_variant.append(debris_speeds[i])
	_sync_blocks_destroyed.rpc(keys_variant, positions_variant, speeds_variant)

	# Host also spawns debris locally (RPC is call_remote)
	_spawn_debris_for_blocks(block_positions, debris_speeds)

	if grid.is_empty():
		queue_free()
		return

	# Check if remaining blocks split into disconnected groups
	var _t_integrity := Time.get_ticks_usec()
	_check_cluster_integrity()
	var _t_integrity_us := Time.get_ticks_usec() - _t_integrity
	var total_us := Time.get_ticks_usec() - _t_abd_start
	if total_us > 500:
		print("[ClusterPerf] _after_blocks_destroyed %s: %d keys destroyed, %d remaining, integrity=%dus total=%dus" % [
			name, destroyed_keys.size(), grid.block_count(), _t_integrity_us, total_us])


func _update_mass() -> void:
	cluster_mass = grid.block_count() * _mass_per_block
	mass = maxf(cluster_mass, 0.1)
	# Keep C++ shielding HP in sync with remaining block HP
	PhysicsServer3D.body_set_shielding_hp(get_rid(), grid.get_total_hp())


@rpc("authority", "call_remote", "reliable")
func _sync_blocks_destroyed(keys: Array, positions: Array = [],
		speeds: Array = []) -> void:
	## Client-side: remove destroyed blocks, spawn debris, and schedule visual rebuild.
	for key_variant in keys:
		var key: Vector3i = key_variant
		grid.erase_block(key)
		_free_hit_body(key)
	_mesh_dirty = true
	set_process(true)

	# Spawn cosmetic debris on the client
	if not positions.is_empty():
		var typed_positions: Array[Vector3] = []
		var typed_speeds: Array[float] = []
		for i in positions.size():
			typed_positions.append(positions[i] as Vector3)
			typed_speeds.append(float(speeds[i]) if i < speeds.size() else 8.0)
		_spawn_debris_for_blocks(typed_positions, typed_speeds)

	if grid.is_empty():
		queue_free()


func _spawn_debris_for_blocks(block_positions: Array[Vector3],
		debris_speeds: Array[float]) -> void:
	## Spawn cosmetic debris for destroyed blocks (both server host and clients).
	var mat: StandardMaterial3D = null
	if _mesh_instance and _mesh_instance.material_override:
		mat = _mesh_instance.material_override
	if mat == null:
		return
	var config := { "size": _debris_size, "lifetime": _debris_lifetime,
		"mass": _debris_mass, "name": _debris_name }
	for i in block_positions.size():
		var pos: Vector3 = block_positions[i]
		var spd: float = debris_speeds[i] if i < debris_speeds.size() else 8.0
		var count := randi_range(1, 2)
		# Use a random nearby point as blast origin for scattered debris direction
		var blast_origin := pos + Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized() * 0.5
		DebrisHelper.spawn_debris(get_parent(), pos, blast_origin, count, mat, spd, config)


# ======================================================================
#  Cluster fragmentation — split disconnected groups into child clusters
# ======================================================================

func _check_cluster_integrity() -> void:
	## Server-only: if remaining blocks form multiple disconnected groups,
	## split smaller groups into new child FallingBlockCluster instances.
	if not multiplayer.is_server():
		return
	if grid.block_count() < 2:
		return

	var _t_integrity_start := Time.get_ticks_usec()
	var components := grid.find_all_components()

	var _t_bfs_us := Time.get_ticks_usec() - _t_integrity_start

	if components.size() <= 1:
		return

	# Keep the largest component in self, split off the rest
	var largest_idx := 0
	for i in components.size():
		if components[i].size() > components[largest_idx].size():
			largest_idx = i

	var _t_splits := Time.get_ticks_usec()
	var split_count := 0
	for i in components.size():
		if i == largest_idx:
			continue
		var keys_variant: Array = []
		for key in components[i]:
			keys_variant.append(key)
		_sync_fragment_split.rpc(keys_variant)
		split_count += 1
	var _t_splits_us := Time.get_ticks_usec() - _t_splits
	print("[ClusterPerf] _check_cluster_integrity %s: %d blocks, %d components, %d splits, bfs=%dus splits=%dus" % [
		name, grid.block_count(), components.size(), split_count, _t_bfs_us, _t_splits_us])


@rpc("authority", "call_local", "reliable")
func _sync_fragment_split(block_keys_variant: Array) -> void:
	## All peers: split specified blocks off into a new child FallingBlockCluster.
	## Blocks are still in grid so we can read their HPs.
	var block_hp_dict: Dictionary = {}
	for key_variant in block_keys_variant:
		var key: Vector3i = key_variant
		if grid.has_block(key):
			block_hp_dict[key] = grid.block_hp[key]
			grid.erase_block(key)
			_free_hit_body(key)

	if block_hp_dict.is_empty():
		return

	# Update self: mass, visuals, shapes
	_update_mass()
	_mesh_dirty = true
	set_process(true)

	if grid.is_empty():
		queue_free()
		return

	# Spawn child cluster from the split-off blocks
	_spawn_child_cluster(block_hp_dict)


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

	# Initialize block tracking (creates mesh, collision shapes, hit bodies)
	child.init_cluster_blocks(block_hp_dict, grid.num_x, grid.num_y, grid.num_z,
		_mass_per_block)
	if _mesh_instance and _mesh_instance.material_override:
		child.set_material(_mesh_instance.material_override.duplicate())
	child.set_debris_config(_debris_size, _debris_lifetime, _debris_mass,
		_debris_name, _block_hp_max)

	# Add to scene
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
	print("[ClusterPerf] _spawn_child_cluster %s->%s: %d blocks, add_child=%dus total=%dus" % [
		name, child.name, block_keys.size(), _t_addchild_us, total_us])


# ======================================================================
#  Contact damage — momentum-based carving
# ======================================================================

func _on_body_entered(body: Node) -> void:
	if not multiplayer.is_server():
		return

	var _t_contact := Time.get_ticks_usec()

	# --- Cluster-vs-cluster: only higher instance_id processes to avoid double ---
	if body is FallingBlockCluster:
		if get_instance_id() < body.get_instance_id():
			return
		_handle_cluster_vs_cluster(body)
		var us := Time.get_ticks_usec() - _t_contact
		GameManager.tick_add("cluster_contact", us)
		if us > 500:
			print("[ClusterPerf] _on_body_entered cluster_vs_cluster %s->%s took %dus" % [name, body.name, us])
		return

	# --- Structure damage (momentum carving) ---
	var target_structure := _find_structure(body)
	if target_structure:
		_handle_structure_hit(body, target_structure)
		var us := Time.get_ticks_usec() - _t_contact
		GameManager.tick_add("cluster_contact", us)
		if us > 500:
			print("[ClusterPerf] _on_body_entered structure_hit %s->%s took %dus" % [name, target_structure.name, us])
		return

	# --- Generic damageable body (player, etc.) — momentum-based structure damage ---
	_handle_generic_hit(body)
	var us := Time.get_ticks_usec() - _t_contact
	GameManager.tick_add("cluster_contact", us)
	if us > 500:
		print("[ClusterPerf] _on_body_entered generic_hit %s->%s took %dus" % [name, body.name, us])


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
	if total_us > 500:
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
	if total_us > 500:
		print("[ClusterPerf] _handle_cluster_vs_cluster %s vs %s: other_dmg=%dus self_dmg=%dus other_expl=%dus self_expl=%dus total=%dus" % [
			name, other.name, _t_other_dmg, _t_self_dmg, _t_other_expl, _t_self_expl, total_us])


# ======================================================================
#  Visual, collision, and hit body rebuild
# ======================================================================

func _rebuild_visuals() -> void:
	## Rebuild mesh, per-column collision shapes, and per-block hit bodies
	## from the current block grid.
	if grid == null or grid.is_empty():
		return
	var _t0 := Time.get_ticks_usec()
	# Rebuild mesh
	if _mesh_instance:
		_mesh_instance.mesh = grid.build_mesh()
	var _t_mesh_us := Time.get_ticks_usec() - _t0
	var _t1 := Time.get_ticks_usec()
	# Rebuild collision shapes (remove old, create new)
	_rebuild_collision_shapes()
	var _t_col_us := Time.get_ticks_usec() - _t1
	var total_us := _t_mesh_us + _t_col_us
	if total_us > 500:
		print("[ClusterPerf] _rebuild_visuals %s: %d blocks, mesh=%dus collision=%dus total=%dus" % [
			name, grid.block_count(), _t_mesh_us, _t_col_us, total_us])

	# Rebuild per-block hit bodies (remove stale, add missing)
	_rebuild_hit_bodies()


func _rebuild_collision_shapes() -> void:
	## Remove all existing collision shapes and rebuild from grid.
	for child in get_children():
		if child is CollisionShape3D:
			child.disabled = true
			child.queue_free()

	if grid.is_empty():
		return

	var shapes := grid.compute_column_shapes()
	for shape_data: Dictionary in shapes:
		var box := BoxShape3D.new()
		box.size = shape_data["size"]
		var col := CollisionShape3D.new()
		col.shape = box
		col.position = shape_data["position"]
		add_child(col)


# ======================================================================
#  Per-block hit detection bodies
# ======================================================================

func _rebuild_hit_bodies() -> void:
	## Sync per-block StaticBody3D hit bodies with the grid.
	## Removes stale bodies and creates missing ones.
	# Remove stale
	var stale_keys: Array[Vector3i] = []
	for key: Vector3i in _hit_bodies:
		if not grid.has_block(key):
			stale_keys.append(key)
	for key in stale_keys:
		_free_hit_body(key)

	# Add missing
	for key: Vector3i in grid.block_hp:
		if not _hit_bodies.has(key):
			_spawn_hit_body(key)


func _spawn_hit_body(key: Vector3i) -> void:
	## Create a lightweight StaticBody3D for hitscan hit detection on one block.
	## Layer 11 (WALL_BLOCKS) only, mask 0 — for weapon raycasts, not physics push.
	var body := StaticBody3D.new()
	body.set_script(_block_script)
	body.grid_key = key
	body.parent_wall = self
	body.collision_layer = CollisionLayers.WALL_BLOCKS
	body.collision_mask = 0
	body.position = grid.block_local_pos(key)

	var col := CollisionShape3D.new()
	col.shape = _shared_block_shape.duplicate()
	body.add_child(col)

	add_child(body)

	# Tag for C++ shielding classification (same as structure's per-block bodies)
	PhysicsServer3D.body_set_shielding_tag(body.get_rid(), 1)  # WALL_BLOCK
	PhysicsServer3D.body_set_shielding_hp(body.get_rid(), grid.block_hp.get(key, 0.0))

	_hit_bodies[key] = body


func _free_hit_body(key: Vector3i) -> void:
	if _hit_bodies.has(key):
		var body: StaticBody3D = _hit_bodies[key]
		if is_instance_valid(body):
			body.queue_free()
		_hit_bodies.erase(key)


# ======================================================================
#  Utility
# ======================================================================

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
