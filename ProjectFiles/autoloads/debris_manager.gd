extends Node

## Object pool for cosmetic debris RigidBody3D nodes.
## Pre-allocates POOL_SIZE nodes across frames; spawn_multi_batch() pops from
## pool and configures via a single C++ call.  Expired debris returns to pool.
##
## Never-freeze architecture: pool bodies are always DYNAMIC with can_sleep=true
## and gravity_scale=0.  They sleep at (0, -10000, 0) with zero Jolt cost.
## Spawn uses direct PhysicsServer3D/RenderingServer API (bypasses Node3D
## notification chain ~1.5μs/body + freeze/unfreeze ~0.8μs/body).

const POOL_SIZE := 2500
const DebrisBodyScript: GDScript = preload("res://world/debris_body.gd")

const _POOL_POS := Vector3(0, -10000, 0)
const _POOL_XFORM := Transform3D(Basis(), _POOL_POS)

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
	d.gravity_scale = 0.0  # Zero gravity in pool — prevents free-fall at pool pos.
	d.contact_monitor = true
	d.max_contacts_reported = 3
	d.can_sleep = true  # Allow sleeping — pool bodies sleep at pool position.
	d.continuous_cd = true
	d.physics_material_override = _shared_phys_mat
	d.collision_layer = CollisionLayers.DEBRIS
	d.collision_mask = CollisionLayers.SURFACE
	# freeze stays false (default) — bodies are always DYNAMIC.
	# No freeze/unfreeze cycle eliminates ~0.8μs Jolt SetMotionType per spawn.

	var col := CollisionShape3D.new()
	col.shape = _shared_shape
	d.add_child(col)

	var mesh := MeshInstance3D.new()
	mesh.mesh = _shared_mesh
	d.add_child(mesh)

	return d


## Legacy per-block spawn (used by client-side RPCs for individual blocks).
func spawn_batch(block_pos: Vector3, blast_center: Vector3, count: int,
		material: StandardMaterial3D, debris_speed: float,
		mass_val: float, lifetime: float) -> void:
	print("[DebrisSpawn] spawn_batch block_pos=%s count=%d speed=%.2f pool=%d" % [
		str(block_pos), count, debris_speed, _pool.size()])
	var toward := (blast_center - block_pos)
	if toward.length() < 0.1:
		toward = Vector3(randf_range(-1, 1), 1, randf_range(-1, 1))
	toward = toward.normalized()
	var cone_cos := cos(deg_to_rad(35.0))
	var scatter_scale := 1.0 - cone_cos
	var now_sec := Time.get_ticks_msec() * 0.001
	var set_mass := mass_val != 0.5
	var mat_rid := material.get_rid() if material else RID()
	var has_mat := mat_rid.is_valid()

	for i in count:
		var debris: RigidBody3D
		var from_pool := false
		if _pool.is_empty():
			debris = _create_node()
			add_child(debris)
		else:
			debris = _pool.pop_back()
			from_pool = true

		var scatter := Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized()
		var impulse_dir := (toward + scatter * scatter_scale).normalized()
		impulse_dir.y = maxf(impulse_dir.y, 0.15)

		var spawn_pos := block_pos + Vector3(
			randf_range(-0.2, 0.2), randf_range(-0.2, 0.2), randf_range(-0.2, 0.2))
		var vel := impulse_dir * debris_speed
		var body_rid := debris.get_rid()
		var xform := Transform3D(Basis(), spawn_pos)

		# Snapshot PRE state
		var pre_grav := float(PhysicsServer3D.body_get_param(body_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE))
		var pre_vel := Vector3(PhysicsServer3D.body_get_state(body_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY))
		var pre_pos := Transform3D(PhysicsServer3D.body_get_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM)).origin
		var pre_sleep := debris.sleeping if debris.is_inside_tree() else false

		# Sync Node3D state so the visual transform chain follows physics.
		debris.visible = true
		debris.global_position = spawn_pos
		debris.can_sleep = false  # Stay awake — detect ground destruction.

		# Direct PhysicsServer3D API
		PhysicsServer3D.body_set_param(body_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 1.0)
		if set_mass:
			PhysicsServer3D.body_set_param(body_rid, PhysicsServer3D.BODY_PARAM_MASS, mass_val)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, vel)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY,
			Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4)))

		# Snapshot POST state
		var post_grav := float(PhysicsServer3D.body_get_param(body_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE))
		var post_vel := Vector3(PhysicsServer3D.body_get_state(body_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY))
		var post_pos := Transform3D(PhysicsServer3D.body_get_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM)).origin
		var post_sleep := debris.sleeping if debris.is_inside_tree() else false

		print("[DebrisSpawn]   #%d pool=%s freeze=%s tree=%s sleep=%s→%s" % [
			i, str(from_pool), str(debris.freeze), str(debris.is_inside_tree()),
			str(pre_sleep), str(post_sleep)])
		print("[DebrisSpawn]   PRE  grav=%.1f vel=%s pos=%s" % [pre_grav, str(pre_vel), str(pre_pos)])
		print("[DebrisSpawn]   SET  vel=%s (spd=%.1f) pos=%s" % [str(vel), debris_speed, str(spawn_pos)])
		print("[DebrisSpawn]   POST grav=%.1f vel=%s pos=%s" % [post_grav, str(post_vel), str(post_pos)])

		var vi := debris.get_child(1) as VisualInstance3D
		if vi:
			var vi_rid := vi.get_instance()
			RenderingServer.instance_set_transform(vi_rid, xform)
			RenderingServer.instance_set_visible(vi_rid, true)
			if has_mat:
				RenderingServer.instance_geometry_set_material_override(vi_rid, mat_rid)

		debris.material_ref = material
		_dbg_spawned += 1
		_expire_queue.append([now_sec + lifetime + randf_range(0.0, 1.0), debris])


## Batch-spawn debris for multiple blocks in a single C++ call.
## Uses direct PhysicsServer3D/RenderingServer API — bypasses Node3D
## notification chain and freeze/unfreeze entirely.
func spawn_multi_batch(block_positions: PackedVector3Array,
		blast_centers: PackedVector3Array, counts: PackedInt32Array,
		speeds: PackedFloat32Array, material: Material,
		mass_val: float, lifetime: float) -> void:
	var total := 0
	for c in counts:
		total += c
	if total <= 0:
		return
	print("[DebrisSpawn] spawn_multi_batch: %d blocks, %d total debris, speeds=%s pool=%d" % [
		block_positions.size(), total, str(speeds), _pool.size()])

	# Pop nodes from pool (or create if exhausted).
	var nodes: Array = []
	nodes.resize(total)
	var from_pool_count := 0
	for i in total:
		if _pool.is_empty():
			var d := _create_node()
			add_child(d)
			nodes[i] = d
		else:
			nodes[i] = _pool.pop_back()
			from_pool_count += 1

	# Snapshot first node BEFORE C++ configure
	var first_rb: RigidBody3D = nodes[0] as RigidBody3D
	var first_rid := first_rb.get_rid()
	var pre_grav := float(PhysicsServer3D.body_get_param(first_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE))
	var pre_vel := Vector3(PhysicsServer3D.body_get_state(first_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY))
	var pre_pos := Transform3D(PhysicsServer3D.body_get_state(first_rid, PhysicsServer3D.BODY_STATE_TRANSFORM)).origin
	var pre_sleep := first_rb.sleeping if first_rb.is_inside_tree() else false
	print("[DebrisSpawn]   pool=%d/%d freeze=%s sleep=%s tree=%s" % [
		from_pool_count, total, str(first_rb.freeze), str(pre_sleep), str(first_rb.is_inside_tree())])
	print("[DebrisSpawn]   PRE  grav=%.1f vel=%s pos=%s" % [pre_grav, str(pre_vel), str(pre_pos)])

	# One C++ call configures all debris via direct server API.
	BlockMeshBuilder.bulk_configure_debris(
		nodes, block_positions, blast_centers, counts, speeds, mass_val, material)

	# Sync Node3D visible so Godot's transform notification chain can
	# propagate physics→node→MeshInstance3D.  C++ only sets direct server
	# API — the Node3D visible=false from warmup must be cleared.
	for d_node in nodes:
		var rb: RigidBody3D = d_node as RigidBody3D
		if rb:
			rb.visible = true
			rb.can_sleep = false  # Stay awake — detect ground destruction.
			rb.material_ref = material  # Keep material alive via refcount

	# Snapshot first node AFTER C++ configure
	var post_grav := float(PhysicsServer3D.body_get_param(first_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE))
	var post_vel := Vector3(PhysicsServer3D.body_get_state(first_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY))
	var post_pos := Transform3D(PhysicsServer3D.body_get_state(first_rid, PhysicsServer3D.BODY_STATE_TRANSFORM)).origin
	var post_sleep := first_rb.sleeping if first_rb.is_inside_tree() else false
	print("[DebrisSpawn]   POST grav=%.1f vel=%s pos=%s sleep=%s" % [
		post_grav, str(post_vel), str(post_pos), str(post_sleep)])

	# Append all to expire queue.
	var now_sec := Time.get_ticks_msec() * 0.001
	for d in nodes:
		_expire_queue.append([now_sec + lifetime + randf_range(0.0, 1.0), d])
	_dbg_spawned += total


func release(debris: RigidBody3D) -> void:
	if not is_instance_valid(debris):
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
	# Must set Node3D visible=false so spawn can toggle it back to true,
	# which triggers the transform notification chain for child visuals.
	debris.visible = false
	debris.can_sleep = true  # Allow sleeping in pool — zero Jolt cost.
	debris.material_ref = null  # Release material reference
	if debris.is_inside_tree():
		var body_rid := debris.get_rid()
		PhysicsServer3D.body_set_param(body_rid, PhysicsServer3D.BODY_PARAM_GRAVITY_SCALE, 0.0)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
		PhysicsServer3D.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, _POOL_XFORM)
		var vi := debris.get_child(1) as VisualInstance3D
		if vi:
			var vi_rid := vi.get_instance()
			RenderingServer.instance_set_visible(vi_rid, false)
			RenderingServer.instance_set_transform(vi_rid, _POOL_XFORM)
	else:
		# Warmup path — node isn't in tree yet, use properties.
		debris.position = _POOL_POS


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
