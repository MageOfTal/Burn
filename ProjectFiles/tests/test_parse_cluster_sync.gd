extends SceneTree

## Parse/compile smoke test for the cluster destruction + ClusterSync scripts:
## force-load each one and fail loudly on compile errors. Deferred to the
## first frame — game scripts reference autoload singletons (Profiler,
## GameManager, ...) which don't exist yet during SceneTree._init, so loading
## there reports false compile failures.
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_parse_cluster_sync.gd


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var paths := [
		"res://autoloads/cluster_sync.gd",
		"res://autoloads/cluster_pool.gd",
		"res://world/falling_block_cluster.gd",
		"res://world/destructible_block_structure.gd",
		"res://weapons/explosion_helper.gd",
		"res://weapons/rocket_projectile.gd",
	]
	var failed := 0
	for p: String in paths:
		var s: Script = load(p)
		if s == null or not s.can_instantiate():
			print("PARSE FAIL: %s" % p)
			failed += 1
		else:
			print("OK: %s" % p)
	print("=== parse check: %d failed ===" % failed)
	quit(1 if failed > 0 else 0)
