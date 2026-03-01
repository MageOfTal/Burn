extends Node

## Object pool for cosmetic debris RigidBody3D nodes.
## Pre-allocates POOL_SIZE nodes across frames; spawn_batch() pops from pool,
## configures, and unfreezes. Expired debris is frozen and returned to pool.
## No active cap — debris count is naturally bounded by lifetime expiry.

const POOL_SIZE := 2500
const DebrisBodyScript: GDScript = preload("res://world/debris_body.gd")

var _pool: Array[RigidBody3D] = []

# Expiry queue — naturally sorted (burst spawns have similar lifetimes).
# Entries: [expire_time_sec: float, debris: RigidBody3D]
var _expire_queue: Array = []
var _expire_head: int = 0

# Shared resources (one each, referenced by all pool nodes).
var _shared_shape: BoxShape3D
var _shared_mesh: BoxMesh
var _shared_phys_mat: PhysicsMaterial

# ---- Debug stats (reset every summary interval) ----
var _dbg_spawned := 0
var _dbg_expired := 0
var _dbg_below_world := 0       ## Lowest Y < -50 (tunneled through everything)
var _dbg_below_spawn := 0       ## Lowest Y < spawn Y - 5 (fell significantly below spawn)
var _dbg_had_floor := 0         ## Had floor contact at some point
var _dbg_had_any_contact := 0   ## Had any contact at all
var _dbg_no_contact := 0        ## Never contacted anything
var _dbg_timer := 0.0
const DBG_INTERVAL := 5.0


var _alloc_remaining := 0
const _ALLOC_BATCH := 100  ## Nodes to create per frame during warmup.

func _ready() -> void:
	_shared_shape = BoxShape3D.new()
	_shared_shape.size = Vector3.ONE * 0.15
	_shared_mesh = BoxMesh.new()
	_shared_mesh.size = Vector3.ONE * 0.15
	_shared_phys_mat = PhysicsMaterial.new()
	_shared_phys_mat.friction = 0.0
	_shared_phys_mat.bounce = 0.0
	_alloc_remaining = POOL_SIZE
	set_process(true)


func _create_node() -> RigidBody3D:
	var d := RigidBody3D.new()
	d.set_script(DebrisBodyScript)
	d.name = "PoolDebris"
	d.mass = 0.5
	d.contact_monitor = true
	d.max_contacts_reported = 3
	d.can_sleep = false
	d.physics_material_override = _shared_phys_mat
	d.collision_layer = CollisionLayers.DEBRIS
	d.collision_mask = CollisionLayers.SURFACE
	d.freeze = true

	var col := CollisionShape3D.new()
	col.shape = _shared_shape
	d.add_child(col)

	var mesh := MeshInstance3D.new()
	mesh.mesh = _shared_mesh
	d.add_child(mesh)

	return d


## Batch-spawn debris. Direction computation + pool acquisition in one tight
## loop — avoids 680 cross-object function calls from DebrisHelper.
func spawn_batch(block_pos: Vector3, blast_center: Vector3, count: int,
		material: StandardMaterial3D, debris_speed: float,
		mass_val: float, lifetime: float) -> void:
	var toward := (blast_center - block_pos)
	if toward.length() < 0.1:
		toward = Vector3(randf_range(-1, 1), 1, randf_range(-1, 1))
	toward = toward.normalized()
	var cone_cos := cos(deg_to_rad(35.0))
	var scatter_scale := 1.0 - cone_cos
	var now_sec := Time.get_ticks_msec() * 0.001
	var set_mass := mass_val != 0.5  # Skip if default (set in _create_node).

	for i in count:
		var debris: RigidBody3D
		if _pool.is_empty():
			debris = _create_node()
			add_child(debris)
		else:
			debris = _pool.pop_back()

		# Direction: scattered within 35-degree cone, biased upward.
		var scatter := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
		var impulse_dir := (toward + scatter * scatter_scale).normalized()
		impulse_dir.y = maxf(impulse_dir.y, 0.15)

		var spawn_pos := block_pos + Vector3(
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
		)

		# Configure while frozen (before Jolt picks up dynamic state).
		debris.position = spawn_pos
		debris.linear_velocity = impulse_dir * debris_speed
		debris.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))
		if set_mass:
			debris.mass = mass_val
		debris.get_child(1).material_override = material

		# Reset debug tracking for this spawn cycle.
		debris.dbg_had_floor_contact = false
		debris.dbg_had_any_contact = false
		debris.dbg_spawn_y = spawn_pos.y
		debris.dbg_lowest_y = spawn_pos.y
		debris.dbg_spawn_speed = debris_speed
		debris.dbg_contact_speed = 0.0
		debris.dbg_frame_count = 0

		# Activate.
		debris.visible = true
		debris.freeze = false

		_dbg_spawned += 1
		_expire_queue.append([now_sec + lifetime + randf_range(0.0, 1.0), debris])


func release(debris: RigidBody3D) -> void:
	if not is_instance_valid(debris) or debris.freeze:
		return
	# Gather debug stats before deactivating.
	_dbg_expired += 1
	if debris.dbg_lowest_y < -50.0:
		_dbg_below_world += 1
	if debris.dbg_lowest_y < debris.dbg_spawn_y - 5.0:
		_dbg_below_spawn += 1
	if debris.dbg_had_floor_contact:
		_dbg_had_floor += 1
	if debris.dbg_had_any_contact:
		_dbg_had_any_contact += 1
	else:
		_dbg_no_contact += 1
	_deactivate(debris)
	_pool.append(debris)


func _deactivate(debris: RigidBody3D) -> void:
	debris.freeze = true
	debris.visible = false
	# Layers left as DEBRIS/SURFACE — nothing queries layer 6, so frozen
	# pool bodies are harmless. Saves 2 property sets per release.
	debris.linear_velocity = Vector3.ZERO
	debris.angular_velocity = Vector3.ZERO


func _process(delta: float) -> void:
	# Incremental pool warmup — allocate _ALLOC_BATCH nodes per frame.
	if _alloc_remaining > 0:
		var batch := mini(_alloc_remaining, _ALLOC_BATCH)
		for i in batch:
			var d := _create_node()
			_deactivate(d)
			add_child(d)
			_pool.append(d)
		_alloc_remaining -= batch

	var now := Time.get_ticks_msec() * 0.001
	while _expire_head < _expire_queue.size():
		var entry: Array = _expire_queue[_expire_head]
		if entry[0] > now:
			break
		release(entry[1])
		_expire_head += 1
	# Compact queue when head pointer gets large.
	if _expire_head > 500:
		_expire_queue = _expire_queue.slice(_expire_head)
		_expire_head = 0

	# Debug summary print.
	_dbg_timer += delta
	if _dbg_timer >= DBG_INTERVAL and _dbg_expired > 0:
		var active := _dbg_spawned - _dbg_expired
		print("[Debris] spawned=%d expired=%d active=%d | floor_contact=%d any_contact=%d no_contact=%d | below_world=%d below_spawn=%d | pool=%d" % [
			_dbg_spawned, _dbg_expired, active,
			_dbg_had_floor, _dbg_had_any_contact, _dbg_no_contact,
			_dbg_below_world, _dbg_below_spawn, _pool.size(),
		])
		_dbg_spawned = 0
		_dbg_expired = 0
		_dbg_below_world = 0
		_dbg_below_spawn = 0
		_dbg_had_floor = 0
		_dbg_had_any_contact = 0
		_dbg_no_contact = 0
		_dbg_timer = 0.0


# Legacy API stubs (kept for any external callers).
func register(_d: RigidBody3D) -> void:
	pass

func unregister(_d: RigidBody3D) -> void:
	pass

func is_at_cap() -> bool:
	return _pool.is_empty()
