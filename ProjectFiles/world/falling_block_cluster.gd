extends PhysicsBodyBase
class_name FallingBlockCluster

## Falling cluster of blocks detached from a DestructibleBlockStructure when
## structural integrity fails. Tracks individual block HP — virtually identical
## to a normal structure, but as a RigidBody3D with physics simulation.
##
## Explosions deal per-block AoE damage via take_damage_at().
## Momentum impacts carve through blocks via take_momentum_damage_at().
## Blocks are destroyed individually with mesh/shape updates.
##
## Server-authoritative: only the server runs damage logic.
## Clients freeze the body as kinematic.
##
## Created by DestructibleBlockStructure._sync_cluster_detach() RPC on all peers.

# ======================================================================
#  Constants
# ======================================================================

const BLOCK_SIZE := 0.5
const NEIGHBOR_OFFSETS: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
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
#  Per-block tracking — mirrors DestructibleBlockStructure._blocks but
#  without StaticBody3D refs. Key = grid Vector3i, value = float HP.
# ======================================================================

var _cluster_blocks: Dictionary = {}

## Grid info for block position computation (set during init, never changes)
var _centroid_local: Vector3 = Vector3.ZERO
var _grid_num_x: int = 1
var _grid_num_y: int = 1
var _grid_num_z: int = 1
var _mass_per_block: float = 5.0

# ======================================================================
#  Internal state
# ======================================================================

var _settle_timer: float = 0.0
var _mesh_dirty: bool = false
## Cached child node ref for mesh rebuild (set in init_cluster_blocks)
var _mesh_instance: MeshInstance3D = null


# ======================================================================
#  Initialization
# ======================================================================

func init_cluster_blocks(block_hp_dict: Dictionary, num_x: int, num_y: int,
		num_z: int, mass_per_blk: float) -> void:
	## Called by _spawn_falling_cluster BEFORE adding to the scene tree.
	## Initializes per-block HP tracking and caches child refs.
	_cluster_blocks = block_hp_dict
	_grid_num_x = num_x
	_grid_num_y = num_y
	_grid_num_z = num_z
	_mass_per_block = mass_per_blk

	# Compute centroid from initial block positions (must match structure's formula)
	_centroid_local = Vector3.ZERO
	for key: Vector3i in _cluster_blocks:
		_centroid_local += Vector3(
			(key.x + 0.5 - _grid_num_x * 0.5) * BLOCK_SIZE,
			(key.y + 0.5 - _grid_num_y * 0.5) * BLOCK_SIZE,
			(key.z + 0.5 - _grid_num_z * 0.5) * BLOCK_SIZE
		)
	if _cluster_blocks.size() > 0:
		_centroid_local /= float(_cluster_blocks.size())

	# Cache mesh node reference for rebuilds
	_mesh_instance = get_node_or_null("ClusterMesh")


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

func take_damage(amount: float, _from_attacker_id: int = -1) -> void:
	## Distribute damage evenly across all remaining blocks.
	## Fallback for non-positional damage sources.
	if not multiplayer.is_server():
		return
	if _cluster_blocks.is_empty():
		return

	var per_block: float = amount / float(_cluster_blocks.size())
	var destroyed_keys: Array[Vector3i] = []

	for key: Vector3i in _cluster_blocks:
		_cluster_blocks[key] -= per_block
		if _cluster_blocks[key] <= 0.0:
			destroyed_keys.append(key)

	if not destroyed_keys.is_empty():
		for key in destroyed_keys:
			_cluster_blocks.erase(key)
		_after_blocks_destroyed(destroyed_keys)


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float,
		_attacker_id: int, _exclude_rids: Array[RID] = [], _impact_speed: float = INF) -> void:
	## AoE per-block damage from explosions. Cubic falloff + flat-HP shielding.
	## Each block gets a shielding ray from the explosion origin — objects between
	## the explosion and the block absorb damage equal to their HP (same as structures).
	## Excludes own RID so this cluster's shapes don't self-shield.
	if not multiplayer.is_server():
		return
	if _cluster_blocks.is_empty():
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

	for key: Vector3i in _cluster_blocks:
		var block_world: Vector3 = _block_world_pos(key)
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
		_cluster_blocks[key] -= dmg
		if _cluster_blocks[key] <= 0.0:
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
		var total_hp := 0.0
		for hp: float in _cluster_blocks.values():
			total_hp += hp
		PhysicsServer3D.body_set_shielding_hp(get_rid(), total_hp)

	if not destroyed_keys.is_empty():
		for key in destroyed_keys:
			_cluster_blocks.erase(key)
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
	if _cluster_blocks.is_empty():
		return empty_result

	# Find nearest block to hit position
	var best_key := Vector3i(-1, -1, -1)
	var best_dist_sq := 999999.0
	for key: Vector3i in _cluster_blocks:
		var d := hit_world_pos.distance_squared_to(_block_world_pos(key))
		if d < best_dist_sq:
			best_dist_sq = d
			best_key = key

	if best_dist_sq > 999998.0:
		return empty_result

	var block_world := _block_world_pos(best_key)
	var hp_before: float = _cluster_blocks[best_key]
	var absorbed: float = minf(damage, hp_before)

	_cluster_blocks[best_key] -= damage
	if _cluster_blocks[best_key] > 0.0:
		return { "absorbed": absorbed, "block_destroyed": false,
			"block_key": best_key, "block_pos": block_world }

	# Block destroyed
	_cluster_blocks.erase(best_key)
	_after_blocks_destroyed([best_key])

	return { "absorbed": absorbed, "block_destroyed": true,
		"block_key": best_key, "block_pos": block_world }


# ======================================================================
#  Post-destruction cleanup
# ======================================================================

func _after_blocks_destroyed(destroyed_keys: Array[Vector3i]) -> void:
	## Shared cleanup after blocks are destroyed. Updates mass, syncs to
	## clients, and schedules visual rebuild.
	var _t_abd_start := Time.get_ticks_usec()

	# Wake up frozen/settled clusters so they (and any fragments) fall properly.
	# Without this, a settled cluster that gets split stays frozen in mid-air.
	if multiplayer.is_server() and freeze:
		freeze = false
		_settle_timer = 0.0

	_update_mass()
	_mesh_dirty = true
	set_process(true)

	# Sync to clients (call_remote — server rebuilds via _process)
	var keys_variant: Array = []
	for key in destroyed_keys:
		keys_variant.append(key)
	_sync_blocks_destroyed.rpc(keys_variant)

	if _cluster_blocks.is_empty():
		queue_free()
		return

	# Check if remaining blocks split into disconnected groups
	var _t_integrity := Time.get_ticks_usec()
	_check_cluster_integrity()
	var _t_integrity_us := Time.get_ticks_usec() - _t_integrity
	var total_us := Time.get_ticks_usec() - _t_abd_start
	if total_us > 500:
		print("[ClusterPerf] _after_blocks_destroyed %s: %d keys destroyed, %d remaining, integrity=%dus total=%dus" % [
			name, destroyed_keys.size(), _cluster_blocks.size(), _t_integrity_us, total_us])


func _update_mass() -> void:
	cluster_mass = _cluster_blocks.size() * _mass_per_block
	mass = maxf(cluster_mass, 0.1)
	# Keep C++ shielding HP in sync with remaining block HP
	var total_hp := 0.0
	for hp: float in _cluster_blocks.values():
		total_hp += hp
	PhysicsServer3D.body_set_shielding_hp(get_rid(), total_hp)


@rpc("authority", "call_remote", "reliable")
func _sync_blocks_destroyed(keys: Array) -> void:
	## Client-side: remove destroyed blocks and schedule visual rebuild.
	for key_variant in keys:
		var key: Vector3i = key_variant
		_cluster_blocks.erase(key)
	_mesh_dirty = true
	set_process(true)
	if _cluster_blocks.is_empty():
		queue_free()


# ======================================================================
#  Cluster fragmentation — split disconnected groups into child clusters
# ======================================================================

func _check_cluster_integrity() -> void:
	## Server-only: if remaining blocks form multiple disconnected groups,
	## split smaller groups into new child FallingBlockCluster instances.
	if not multiplayer.is_server():
		return
	if _cluster_blocks.size() < 2:
		return

	var _t_integrity_start := Time.get_ticks_usec()

	# BFS to find connected components
	var visited: Dictionary = {}
	var components: Array = []

	for start_key: Vector3i in _cluster_blocks:
		if visited.has(start_key):
			continue
		var component: Array[Vector3i] = []
		var queue: Array[Vector3i] = [start_key]
		visited[start_key] = true
		var head := 0
		while head < queue.size():
			var current: Vector3i = queue[head]
			head += 1
			component.append(current)
			for offset in NEIGHBOR_OFFSETS:
				var neighbor: Vector3i = current + offset
				if _cluster_blocks.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		components.append(component)

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
		name, _cluster_blocks.size(), components.size(), split_count, _t_bfs_us, _t_splits_us])


@rpc("authority", "call_local", "reliable")
func _sync_fragment_split(block_keys_variant: Array) -> void:
	## All peers: split specified blocks off into a new child FallingBlockCluster.
	## Blocks are still in _cluster_blocks so we can read their HPs.
	var block_hp_dict: Dictionary = {}
	for key_variant in block_keys_variant:
		var key: Vector3i = key_variant
		if _cluster_blocks.has(key):
			block_hp_dict[key] = _cluster_blocks[key]
			_cluster_blocks.erase(key)

	if block_hp_dict.is_empty():
		return

	# Update self: mass, visuals, shapes
	_update_mass()
	_mesh_dirty = true
	set_process(true)

	if _cluster_blocks.is_empty():
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

	# Compute child centroid in grid space (same formula as init_cluster_blocks)
	var child_centroid_grid := Vector3.ZERO
	for key: Vector3i in block_keys:
		child_centroid_grid += Vector3(
			(key.x + 0.5 - _grid_num_x * 0.5) * BLOCK_SIZE,
			(key.y + 0.5 - _grid_num_y * 0.5) * BLOCK_SIZE,
			(key.z + 0.5 - _grid_num_z * 0.5) * BLOCK_SIZE
		)
	child_centroid_grid /= float(block_keys.size())

	# World position: parent origin + basis * (child centroid offset from parent centroid)
	var spawn_pos := global_position + global_transform.basis * (child_centroid_grid - _centroid_local)

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

	# Create MeshInstance3D (filled by _rebuild_visuals below)
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ClusterMesh"
	if _mesh_instance and _mesh_instance.material_override:
		mesh_inst.material_override = _mesh_instance.material_override.duplicate()
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	child.add_child(mesh_inst)

	# Initialize block tracking (sets _centroid_local, caches mesh ref)
	child.init_cluster_blocks(block_hp_dict, _grid_num_x, _grid_num_y, _grid_num_z,
		_mass_per_block)
	# Build mesh + collision shapes before entering tree
	var _t_rebuild := Time.get_ticks_usec()
	child._rebuild_visuals()
	var _t_rebuild_us := Time.get_ticks_usec() - _t_rebuild

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
		var total_hp := 0.0
		for hp: float in block_hp_dict.values():
			total_hp += hp
		PhysicsServer3D.body_set_shielding_hp(child_rid, total_hp)

	var total_us := Time.get_ticks_usec() - _t_spawn
	print("[ClusterPerf] _spawn_child_cluster %s->%s: %d blocks, rebuild=%dus add_child=%dus total=%dus" % [
		name, child.name, block_keys.size(), _t_rebuild_us, _t_addchild_us, total_us])


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
		if expl_damage > 0.5 and not _cluster_blocks.is_empty():
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
		if expl_damage > 0.5 and not other._cluster_blocks.is_empty():
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
		if expl_damage > 0.5 and not _cluster_blocks.is_empty():
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
#  Visual and collision rebuild
# ======================================================================

func _rebuild_visuals() -> void:
	## Rebuild mesh and per-column collision shapes from current block set.
	if _cluster_blocks.is_empty():
		return
	var _t0 := Time.get_ticks_usec()
	if _mesh_instance:
		_mesh_instance.mesh = _build_mesh()
	var _t_mesh_us := Time.get_ticks_usec() - _t0
	var _t1 := Time.get_ticks_usec()
	_rebuild_collision_shapes()
	var _t_col_us := Time.get_ticks_usec() - _t1
	var total_us := _t_mesh_us + _t_col_us
	if total_us > 500:
		print("[ClusterPerf] _rebuild_visuals %s: %d blocks, mesh=%dus collision=%dus total=%dus" % [
			name, _cluster_blocks.size(), _t_mesh_us, _t_col_us, total_us])


func _build_mesh() -> Mesh:
	## Build a greedy mesh from current blocks, relative to the original centroid.
	var key_set: Dictionary = {}
	for key: Vector3i in _cluster_blocks:
		key_set[key] = true

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bs := BLOCK_SIZE
	var hs := bs * 0.5

	for key: Vector3i in _cluster_blocks:
		var cx: float = (key.x + 0.5 - _grid_num_x * 0.5) * bs - _centroid_local.x
		var cy: float = (key.y + 0.5 - _grid_num_y * 0.5) * bs - _centroid_local.y
		var cz: float = (key.z + 0.5 - _grid_num_z * 0.5) * bs - _centroid_local.z

		# +X face
		if not key_set.has(Vector3i(key.x + 1, key.y, key.z)):
			_add_quad(st, Vector3(1, 0, 0),
				Vector3(cx + hs, cy - hs, cz - hs), Vector3(cx + hs, cy - hs, cz + hs),
				Vector3(cx + hs, cy + hs, cz + hs), Vector3(cx + hs, cy + hs, cz - hs))
		# -X face
		if not key_set.has(Vector3i(key.x - 1, key.y, key.z)):
			_add_quad(st, Vector3(-1, 0, 0),
				Vector3(cx - hs, cy - hs, cz + hs), Vector3(cx - hs, cy - hs, cz - hs),
				Vector3(cx - hs, cy + hs, cz - hs), Vector3(cx - hs, cy + hs, cz + hs))
		# +Y face
		if not key_set.has(Vector3i(key.x, key.y + 1, key.z)):
			_add_quad(st, Vector3(0, 1, 0),
				Vector3(cx - hs, cy + hs, cz - hs), Vector3(cx + hs, cy + hs, cz - hs),
				Vector3(cx + hs, cy + hs, cz + hs), Vector3(cx - hs, cy + hs, cz + hs))
		# -Y face
		if not key_set.has(Vector3i(key.x, key.y - 1, key.z)):
			_add_quad(st, Vector3(0, -1, 0),
				Vector3(cx - hs, cy - hs, cz + hs), Vector3(cx + hs, cy - hs, cz + hs),
				Vector3(cx + hs, cy - hs, cz - hs), Vector3(cx - hs, cy - hs, cz - hs))
		# +Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z + 1)):
			_add_quad(st, Vector3(0, 0, 1),
				Vector3(cx + hs, cy - hs, cz + hs), Vector3(cx - hs, cy - hs, cz + hs),
				Vector3(cx - hs, cy + hs, cz + hs), Vector3(cx + hs, cy + hs, cz + hs))
		# -Z face
		if not key_set.has(Vector3i(key.x, key.y, key.z - 1)):
			_add_quad(st, Vector3(0, 0, -1),
				Vector3(cx - hs, cy - hs, cz - hs), Vector3(cx + hs, cy - hs, cz - hs),
				Vector3(cx + hs, cy + hs, cz - hs), Vector3(cx - hs, cy + hs, cz - hs))

	return st.commit()


func _rebuild_collision_shapes() -> void:
	## Remove all existing collision shapes and rebuild per-column box shapes
	## from current blocks. Same approach as structure's smooth collision.
	# Remove old shapes — disable immediately so they leave the physics world
	# before new shapes (or child cluster shapes) are added this frame.
	for child in get_children():
		if child is CollisionShape3D:
			child.disabled = true
			child.queue_free()

	if _cluster_blocks.is_empty():
		return

	var bs := BLOCK_SIZE

	# Group blocks by (x, z) column
	var columns: Dictionary = {}
	for key: Vector3i in _cluster_blocks:
		var col_key := Vector2i(key.x, key.z)
		if not columns.has(col_key):
			columns[col_key] = []
		columns[col_key].append(key.y)

	for col_key: Vector2i in columns:
		var y_list: Array = columns[col_key]
		y_list.sort()

		# Find contiguous Y runs
		var run_start: int = y_list[0]
		var run_end: int = y_list[0]

		for i in range(1, y_list.size()):
			if y_list[i] == run_end + 1:
				run_end = y_list[i]
			else:
				_add_column_shape(col_key.x, col_key.y, run_start, run_end)
				run_start = y_list[i]
				run_end = y_list[i]

		_add_column_shape(col_key.x, col_key.y, run_start, run_end)


func _add_column_shape(bx: int, bz: int, by_start: int, by_end: int) -> void:
	## Add a BoxShape3D for one contiguous vertical run.
	var bs := BLOCK_SIZE
	var run_count: int = by_end - by_start + 1

	var box := BoxShape3D.new()
	box.size = Vector3(bs, run_count * bs, bs)

	var col := CollisionShape3D.new()
	col.shape = box
	col.position = Vector3(
		(bx + 0.5 - _grid_num_x * 0.5) * bs - _centroid_local.x,
		((by_start + by_end) * 0.5 + 0.5 - _grid_num_y * 0.5) * bs - _centroid_local.y,
		(bz + 0.5 - _grid_num_z * 0.5) * bs - _centroid_local.z
	)
	add_child(col)


static func _add_quad(st: SurfaceTool, normal: Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	## Emit a quad as 2 triangles with simple UVs.
	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(p1)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)

	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)
	st.set_normal(normal)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(p3)


# ======================================================================
#  Utility
# ======================================================================

func _block_local_pos(key: Vector3i) -> Vector3:
	## Block position in cluster-local space (relative to centroid).
	return Vector3(
		(key.x + 0.5 - _grid_num_x * 0.5) * BLOCK_SIZE - _centroid_local.x,
		(key.y + 0.5 - _grid_num_y * 0.5) * BLOCK_SIZE - _centroid_local.y,
		(key.z + 0.5 - _grid_num_z * 0.5) * BLOCK_SIZE - _centroid_local.z
	)


func _block_world_pos(key: Vector3i) -> Vector3:
	## Block position in world space (cluster transform applied).
	return global_transform * _block_local_pos(key)


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
