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
	## AoE per-block damage from explosions. Same cubic falloff as structures.
	## No shielding raycasts (clusters are small, shielding is negligible).
	if not multiplayer.is_server():
		return
	if _cluster_blocks.is_empty():
		return

	var destroyed_keys: Array[Vector3i] = []

	for key: Vector3i in _cluster_blocks:
		var block_world: Vector3 = _block_world_pos(key)
		var dist: float = hit_pos.distance_to(block_world)
		if dist > blast_radius:
			continue
		var norm_dist: float = dist / blast_radius
		var falloff: float = 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
		var dmg: float = amount * falloff

		_cluster_blocks[key] -= dmg
		if _cluster_blocks[key] <= 0.0:
			destroyed_keys.append(key)

	if not destroyed_keys.is_empty():
		for key in destroyed_keys:
			_cluster_blocks.erase(key)
		_after_blocks_destroyed(destroyed_keys)


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


func _update_mass() -> void:
	cluster_mass = _cluster_blocks.size() * _mass_per_block
	mass = maxf(cluster_mass, 0.1)


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
		GameManager.tick_add("cluster_contact", Time.get_ticks_usec() - _t_contact)
		return

	# --- Structure damage (momentum carving) ---
	var target_structure := _find_structure(body)
	if target_structure:
		_handle_structure_hit(body, target_structure)
		GameManager.tick_add("cluster_contact", Time.get_ticks_usec() - _t_contact)
		return

	# --- Generic damageable body (player, etc.) — momentum-based structure damage ---
	_handle_generic_hit(body)
	GameManager.tick_add("cluster_contact", Time.get_ticks_usec() - _t_contact)


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
	var target_result: Dictionary = target_structure.take_momentum_damage_at(
		contact_point, base_damage, attacker_id, impact_speed
	)
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
	if target_result.get("block_destroyed", false) and remaining_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * remaining_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = target_result.get("block_pos", contact_point)
		if expl_damage > 0.5 and expl_radius > 0.1:
			target_structure.take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], remaining_speed)

	# Mutual damage — same collision, same damage to this cluster
	var self_result: Dictionary = take_momentum_damage_at(contact_point, base_damage, -1, impact_speed)

	# Breakthrough explosion on SELF — per-block momentum at remaining speed
	if self_result.get("block_destroyed", false) and remaining_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * remaining_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = self_result.get("block_pos", contact_point)
		if expl_damage > 0.5 and not _cluster_blocks.is_empty():
			take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], remaining_speed)

	print("[FallingCluster] Carve into %s: dmg=%.1f absorbed=%.1f remaining_speed=%.1f" % [
		target_structure.name, base_damage, target_absorbed, remaining_speed])


func _handle_cluster_vs_cluster(other: FallingBlockCluster) -> void:
	## Two falling clusters collide. Both take per-block momentum damage at the
	## contact point. Only called on the cluster with the higher instance_id.

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
	var other_result: Dictionary = other.take_momentum_damage_at(
		contact_midpoint, my_damage, attacker_id, impact_speed)

	# Other cluster damages this one
	var self_result: Dictionary = take_momentum_damage_at(
		contact_midpoint, other_damage, other.attacker_id, impact_speed)

	# Breakthrough on the other cluster (from this cluster's remaining momentum)
	if other_result.get("block_destroyed", false) and impact_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = _mass_per_block * impact_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = other_result.get("block_pos", contact_midpoint)
		if expl_damage > 0.5 and not other._cluster_blocks.is_empty():
			other.take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], impact_speed)

	# Breakthrough on this cluster (from other cluster's remaining momentum)
	if self_result.get("block_destroyed", false) and impact_speed > MIN_DAMAGE_SPEED:
		var per_block_momentum: float = other._mass_per_block * impact_speed
		var expl_damage: float = per_block_momentum * BREAKTHROUGH_DAMAGE_SCALE * GameManager.structure_explosion_damage_scale
		var expl_radius: float = BREAKTHROUGH_BASE_RADIUS + per_block_momentum * BREAKTHROUGH_RADIUS_SCALE * GameManager.structure_explosion_radius_scale
		var block_pos: Vector3 = self_result.get("block_pos", contact_midpoint)
		if expl_damage > 0.5 and not _cluster_blocks.is_empty():
			take_damage_at(block_pos, expl_damage, expl_radius, attacker_id, [], impact_speed)

	print("[FallingCluster] Cluster vs cluster: %s(%.1fkg) vs %s(%.1fkg) speed=%.1f" % [
		name, cluster_mass, other.name, other.cluster_mass, impact_speed])


# ======================================================================
#  Visual and collision rebuild
# ======================================================================

func _rebuild_visuals() -> void:
	## Rebuild mesh and per-column collision shapes from current block set.
	if _cluster_blocks.is_empty():
		return
	if _mesh_instance:
		_mesh_instance.mesh = _build_mesh()
	_rebuild_collision_shapes()


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
	# Remove old shapes
	for child in get_children():
		if child is CollisionShape3D:
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
