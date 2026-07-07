extends Node

## Server→client transform replication for FallingBlockCluster bodies.
##
## Clusters spawn on every peer via call_local RPCs (structure detach batches,
## cluster splits). The server simulates them as rigid bodies; clients freeze
## them kinematic at spawn and rely on this autoload to follow the server's
## motion — without it, client-side chunks hover frozen at their detach
## position forever while the server sees them fall and roll.
##
## Mirrors FragmentPool's sync model: every SYNC_TICK_INTERVAL physics ticks
## the server packs (id, origin, quaternion) for every awake registered
## cluster into one unreliable RPC. A cluster that falls asleep is broadcast
## one final time (exact resting pose), then skipped until it wakes.
##
## IDs are allocated server-side (allocate_id) and travel inside the spawn
## RPCs, so every peer registers the same cluster under the same id. The id
## also names the node ("FallingCluster_<id>"), keeping node paths identical
## across peers — required for the per-cluster RPCs (_sync_fragment_split_batch,
## _sync_blocks_destroyed) to resolve on clients.

const SYNC_TICK_INTERVAL := 2  ## Broadcast every N physics ticks (~30Hz at 60tps)

var _clusters: Dictionary = {}       ## sync_id (int) → FallingBlockCluster
var _asleep_synced: Dictionary = {}  ## sync_id → true once resting pose was sent
var _next_id: int = 1
var _ticks_since_sync := 0


func allocate_id() -> int:
	## Server-only: reserve a sync id for a cluster about to be spawned via RPC.
	var id := _next_id
	_next_id += 1
	return id


func allocate_ids(count: int) -> PackedInt32Array:
	## Server-only: reserve `count` consecutive sync ids (one per cluster in a
	## batched spawn RPC).
	var ids := PackedInt32Array()
	ids.resize(count)
	for i in count:
		ids[i] = _next_id + i
	_next_id += count
	return ids


func register(id: int, cluster: RigidBody3D) -> void:
	## All peers: called from FallingBlockCluster._ready() when sync_id != 0.
	_clusters[id] = cluster


func unregister(id: int) -> void:
	## All peers: called from FallingBlockCluster._exit_tree().
	_clusters.erase(id)
	_asleep_synced.erase(id)


func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server():
		return
	if _clusters.is_empty():
		return
	_ticks_since_sync += 1
	if _ticks_since_sync < SYNC_TICK_INTERVAL:
		return
	_ticks_since_sync = 0
	if multiplayer.get_peers().is_empty():
		return

	var ids := PackedInt32Array()
	var origins := PackedVector3Array()
	var quats := PackedFloat32Array()  # x,y,z,w per cluster
	var stale: Array = []
	for id: int in _clusters:
		var c: RigidBody3D = _clusters[id]
		if c == null or not is_instance_valid(c) or not c.is_inside_tree():
			stale.append(id)
			continue
		if c.sleeping:
			# Send the resting pose exactly once, then stop syncing until the
			# cluster wakes again (settled rubble shouldn't cost bandwidth).
			if _asleep_synced.get(id, false):
				continue
			_asleep_synced[id] = true
		else:
			_asleep_synced.erase(id)
		var xform: Transform3D = c.global_transform
		ids.append(id)
		origins.append(xform.origin)
		var q := xform.basis.get_rotation_quaternion()
		quats.append(q.x)
		quats.append(q.y)
		quats.append(q.z)
		quats.append(q.w)
	for id: int in stale:
		unregister(id)
	if ids.is_empty():
		return
	_sync_transforms.rpc(ids, origins, quats)


@rpc("authority", "call_remote", "unreliable_ordered")
func _sync_transforms(ids: PackedInt32Array, origins: PackedVector3Array,
		quats: PackedFloat32Array) -> void:
	## Clients: apply the server's transforms to local frozen-kinematic clusters.
	for k in ids.size():
		var c: RigidBody3D = _clusters.get(ids[k])
		if c == null or not is_instance_valid(c):
			continue
		var qi := k * 4
		var q := Quaternion(quats[qi], quats[qi + 1], quats[qi + 2], quats[qi + 3])
		c.global_transform = Transform3D(Basis(q), origins[k])


func get_stats() -> Dictionary:
	return {
		"registered": _clusters.size(),
		"asleep_synced": _asleep_synced.size(),
		"next_id": _next_id,
	}
