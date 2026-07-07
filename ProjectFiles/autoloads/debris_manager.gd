extends Node

## Spawns cosmetic debris as raw PhysicsServer3D/RenderingServer RIDs.
## No Godot nodes, no pool, no limit. One C++ call creates all bodies + visuals.
## Expiry queue frees RIDs after lifetime expires.

# Shared resources (created once, RIDs passed to C++).
var _shared_shape: BoxShape3D
var _shared_mesh: BoxMesh

# Expiry queue — entries: [expire_time_sec: float, body_rid: RID, instance_rid: RID]
var _expire_queue: Array = []
var _expire_head: int = 0

# Cached world RIDs (set on first spawn).
var _space_rid: RID
var _scenario_rid: RID

# Material ref-hold: keep materials alive while debris uses their RID.
# Dictionary[RID -> Material] — cleared when last debris using it expires.
var _material_refs: Dictionary = {}

# ---- Debug stats (reset every summary interval) ----
var _dbg_spawned := 0
var _dbg_expired := 0
var _dbg_active := 0
var _dbg_timer := 0.0
const DBG_INTERVAL := 5.0


func _ready() -> void:
	_shared_shape = BoxShape3D.new()
	_shared_shape.size = Vector3.ONE * 0.15
	_shared_mesh = BoxMesh.new()
	_shared_mesh.size = Vector3.ONE * 0.15
	set_process(true)


func _ensure_world_rids() -> bool:
	if _space_rid.is_valid() and _scenario_rid.is_valid():
		return true
	var w3d := get_viewport().find_world_3d()
	if w3d == null:
		return false
	_space_rid = w3d.space
	_scenario_rid = w3d.scenario
	return _space_rid.is_valid() and _scenario_rid.is_valid()


## Legacy per-block spawn — now delegates to spawn_multi_batch.
func spawn_batch(block_pos: Vector3, blast_center: Vector3, count: int,
		material: StandardMaterial3D, debris_speed: float,
		mass_val: float, lifetime: float) -> void:
	var positions := PackedVector3Array([block_pos])
	var centers := PackedVector3Array([blast_center])
	var counts := PackedInt32Array([count])
	var speeds := PackedFloat32Array([debris_speed])
	spawn_multi_batch(positions, centers, counts, speeds, material, mass_val, lifetime)


## Batch-spawn debris for multiple blocks in a single C++ call.
## Creates raw server bodies + visuals — no Godot nodes.
func spawn_multi_batch(block_positions: PackedVector3Array,
		blast_centers: PackedVector3Array, counts: PackedInt32Array,
		speeds: PackedFloat32Array, material: Material,
		mass_val: float, lifetime: float) -> void:
	Profiler.begin("debris_spawn")
	var _t_total := Time.get_ticks_usec()

	var total := 0
	for c in counts:
		total += c
	if total <= 0:
		Profiler.end("debris_spawn")
		return
	if not _ensure_world_rids():
		Profiler.end("debris_spawn")
		return

	# One C++ call creates all physics bodies + visual instances.
	var result: Dictionary = BlockMeshBuilder.bulk_spawn_debris(
		block_positions, blast_centers, counts, speeds,
		mass_val, material,
		_shared_shape.get_rid(), _shared_mesh.get_rid(),
		_space_rid, _scenario_rid,
		CollisionLayers.DEBRIS, CollisionLayers.SURFACE)

	var body_rids: Array = result["body_rids"]
	var instance_rids: Array = result["instance_rids"]

	# Hold material ref so its RID stays valid for debris lifetime.
	if material:
		_material_refs[material.get_rid()] = material

	# Append to expiry queue.
	var now_sec := Time.get_ticks_msec() * 0.001
	for i in body_rids.size():
		var expire := now_sec + lifetime + randf_range(0.0, 1.0)
		_expire_queue.append([expire, body_rids[i], instance_rids[i]])
	_dbg_spawned += body_rids.size()
	_dbg_active += body_rids.size()

	var _t_us := Time.get_ticks_usec() - _t_total
	if _t_us > 100:
		print("[PERF] debris.spawn_multi_batch: %d blocks, %d debris, time=%dus" % [
			block_positions.size(), body_rids.size(), _t_us])
	GameManager.tick_add("debris_spawn", _t_us)
	Profiler.end("debris_spawn")


func _free_debris(body_rid: RID, instance_rid: RID) -> void:
	if body_rid.is_valid():
		PhysicsServer3D.free_rid(body_rid)
	if instance_rid.is_valid():
		RenderingServer.free_rid(instance_rid)
	_dbg_expired += 1
	_dbg_active -= 1


func _process(delta: float) -> void:
	Profiler.begin("debris_manager")

	var now := Time.get_ticks_msec() * 0.001
	while _expire_head < _expire_queue.size():
		var entry: Array = _expire_queue[_expire_head]
		if entry[0] > now:
			break
		_free_debris(entry[1], entry[2])
		_expire_head += 1
	# Compact queue when head pointer gets large.
	if _expire_head > 500:
		_expire_queue = _expire_queue.slice(_expire_head)
		_expire_head = 0

	# Periodically release material refs that are no longer needed.
	# (Simple approach: clear all refs when no active debris.)
	if _dbg_active <= 0 and not _material_refs.is_empty():
		_material_refs.clear()

	# Debug summary print.
	_dbg_timer += delta
	if _dbg_timer >= DBG_INTERVAL and _dbg_expired > 0:
		print("[Debris] spawned=%d expired=%d active=%d" % [
			_dbg_spawned, _dbg_expired, _dbg_active])
		_dbg_spawned = 0
		_dbg_expired = 0
		_dbg_timer = 0.0
	Profiler.end("debris_manager")


# Legacy API stubs (kept for any external callers).
func register(_d: RigidBody3D) -> void:
	pass

func unregister(_d: RigidBody3D) -> void:
	pass

func is_at_cap() -> bool:
	return false
