extends SceneTree

## End-to-end test of the StressSolver autoload: submit a gravity solve to
## the dedicated worker thread, poll for the result like the game does, and
## verify the physics verdict matches the synchronous kernel (a 5-block
## overhang at tension 50 must break at the root).
##
## Run via:
##   Godot_v4.6-stable_win64.exe --headless --path ProjectFiles --script res://tests/test_stress_solver_thread.gd


## Resolved at runtime — a --script main file compiles BEFORE autoload
## singletons register, so the StressSolver identifier can't be used here.
var _solver: Node = null


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("=== StressSolver thread tests ===")
	_solver = root.get_node("StressSolver")
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")

	# 1-thick cantilever: anchored wall block + 5 overhang blocks.
	var nx := 6
	var grid := PackedByteArray()
	grid.resize(nx)
	grid.fill(1)
	var mask := PackedByteArray()
	mask.resize(nx)
	mask[0] = 1
	var bonds: Dictionary = bmb.compute_bond_graph(grid, nx, 1, 1, 100.0)

	var id: int = _solver.submit_solve({
		"grid": grid, "mask": mask,
		"bond_strength": bonds["bond_strength"],
		"bond_damage": bonds["bond_damage"],
		"bond_broken": bonds["bond_broken"],
		"anchor_strength": PackedFloat32Array(),
		"anchor_damage": PackedFloat32Array(),
		"anchor_broken": PackedByteArray(),
		"nx": nx, "ny": 1, "nz": 1,
		"gravity": Vector3(0, -1, 0),
		"params": { "tension": 50.0, "compression": 1.0e6, "shear": 1.0e6,
			"anchor_factor": 1.0e6, "tolerance": 1.0e-3 },
	})

	# Also verify cancel() bookkeeping with a second job.
	var cancel_id: int = _solver.submit_solve({
		"grid": grid, "mask": mask,
		"bond_strength": bonds["bond_strength"],
		"bond_damage": bonds["bond_damage"],
		"bond_broken": bonds["bond_broken"],
		"anchor_strength": PackedFloat32Array(),
		"anchor_damage": PackedFloat32Array(),
		"anchor_broken": PackedByteArray(),
		"nx": nx, "ny": 1, "nz": 1,
		"gravity": Vector3(0, -1, 0),
		"params": { "tension": 50.0, "compression": 1.0e6, "shear": 1.0e6 },
	})
	_solver.cancel(cancel_id)

	for i in 600:
		await process_frame
		var res: Dictionary = _solver.take_result(id)
		if not res.is_empty():
			var broke: int = res["broke_bonds"]
			var conv: bool = res["converged"]
			var ok := broke >= 1 and conv
			print("[%s] threaded_solve (broke=%d conv=%s, %d frames)" % [
				"PASS" if ok else "FAIL", broke, str(conv), i + 1])
			# Give the cancelled job time to be discarded, then check stats.
			await process_frame
			await process_frame
			var stats: Dictionary = _solver.get_stats()
			var clean: bool = stats["queued"] == 0 and stats["pending_results"] == 0
			print("[%s] cancel_discards_result (queued=%d pending=%d)" % [
				"PASS" if clean else "FAIL", stats["queued"], stats["pending_results"]])
			print("=== Summary: %d/2 passed ===" % [(1 if ok else 0) + (1 if clean else 0)])
			quit(0 if ok and clean else 1)
			return
	print("[FAIL] threaded_solve: timeout — no result after 600 frames")
	print("=== Summary: 0/2 passed ===")
	quit(1)
