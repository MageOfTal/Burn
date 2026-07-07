extends Node

## Pre-allocated pool of cluster shells (RigidBody3D + StaticBody3D + MeshInstance3D)
## ready to be configured and added to the scene. Avoids the Node3D.new() +
## set_script() cost during high-volume cluster spawns (e.g. a tower toppling
## into 500+ pieces in one tick).
##
## Shells live as ORPHAN nodes (not in the tree) until acquired. They incur no
## physics tick overhead while pooled.
##
## Lifecycle:
##   1. _ready() pre-creates POOL_SIZE shells
##   2. acquire() pops one (or creates fresh if pool empty) — caller add_childs it
##   3. release(shell) returns it to the pool — caller must remove from tree first
##      (typical caller: a settled / freed cluster reuses the shell instead of
##       freeing nodes outright)
##
## When the pool runs dry, acquire() falls back to a fresh _create_shell(), so
## destruction never blocks on the pool.

const POOL_SIZE := 1000  ## tune via inspector / runtime as needed
                         ## Big detach events (e.g., a tower toppling) routinely
                         ## spawn 400+ clusters in one tick; an undersized pool
                         ## forces fresh node creation on the hot path.

const FallingBlockClusterScript: GDScript = preload("res://world/falling_block_cluster.gd")
const CompoundHitBodyScript: GDScript = preload("res://world/compound_hit_body.gd")

var _pool: Array = []  # Array of Dict { rb, hit_body, mesh_inst }

# Stats for diagnostics.
var _pool_hits: int = 0
var _pool_misses: int = 0


func _ready() -> void:
	# Pre-warm: create all shells up front. They're orphan nodes, so no scene
	# tree or physics overhead while pooled.
	for i in POOL_SIZE:
		_pool.append(_create_shell())


func _create_shell() -> Dictionary:
	## Build one cluster shell. The bodies are NEW Godot objects with scripts
	## attached. Caller is responsible for add_child + per-cluster configuration.
	##
	## Constant RigidBody3D / StaticBody3D properties are set HERE so that the
	## per-spawn loop doesn't pay 6+ property-set syscalls per cluster. With
	## hundreds of clusters per detach event, this saves ~3ms of main-thread
	## work that the WorkerThreadPool can't help with.
	var rb := RigidBody3D.new()
	rb.set_script(FallingBlockClusterScript)
	rb.collision_layer = CollisionLayers.ITEMS | CollisionLayers.WALL_SMOOTH
	rb.collision_mask = CollisionLayers.DEFAULT_PHYSICS | CollisionLayers.DEBRIS
	rb.contact_monitor = true
	rb.max_contacts_reported = 4
	rb.gravity_scale = 2.25  ## ~22 m/s² to match player gravity (22.05); world
	                         ## default 9.8 makes detached blocks float relative
	                         ## to the player, who has their own manual gravity.
	rb.continuous_cd = true

	var hit_body := StaticBody3D.new()
	hit_body.set_script(CompoundHitBodyScript)
	hit_body.name = "CompoundHitBody"
	hit_body.collision_layer = CollisionLayers.WALL_BLOCKS
	hit_body.collision_mask = 0

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "ClusterMesh"
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	return { "rb": rb, "hit_body": hit_body, "mesh_inst": mesh_inst }


func acquire() -> Dictionary:
	## Take a shell from the pool, or fall back to fresh allocation if empty.
	## Returned dict has {rb, hit_body, mesh_inst}, all NEW or recycled.
	if _pool.is_empty():
		_pool_misses += 1
		return _create_shell()
	_pool_hits += 1
	return _pool.pop_back()


func release(shell: Dictionary) -> void:
	## Return a shell to the pool. Caller must have already removed it from
	## the scene tree and cleared physics state. Currently unused — clusters
	## live forever per gameplay design — but kept for future recycling logic.
	if shell.is_empty():
		return
	_pool.append(shell)


func get_stats() -> Dictionary:
	return {
		"pool_size": _pool.size(),
		"hits": _pool_hits,
		"misses": _pool_misses,
		"hit_ratio": float(_pool_hits) / maxf(float(_pool_hits + _pool_misses), 1.0),
	}
