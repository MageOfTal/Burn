extends SceneTree

## Headless test harness for the localized stress solver. Compares
## calc_stress_integrity_localized against calc_stress_integrity_components
## across a battery of synthetic destruction scenarios.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_stress_solver_localized.gd
##
## Each case reports PASS or FAIL by comparing the sorted sizes of detached
## components from both solvers. Identical sizes mean identical detachment
## behavior (the only player-visible output of the stress check).

const STRESS_MAX_LOAD: float = 15.0
const STRESS_HORIZONTAL_TRANSFER: float = 0.6


func _init() -> void:
	print("=== Localized stress solver tests ===")
	print("")

	var pass_count := 0
	var fail_count := 0

	# Ensure BlockMeshBuilder singleton exists.
	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: BlockMeshBuilder class not found. Engine build is missing the module.")
		quit(2)
		return

	# Smoke test: 5×5×5 solid block, no damage. Should produce 0 components
	# from both solvers (everything supported).
	pass_count += 1 if _run_case("baseline_5x5x5_no_damage",
			_make_solid(5, 5, 5), [], [], 0) else 0

	# Single block damage in a 5×5×5 — top-center block destroyed, no cascade.
	# 0 components expected.
	pass_count += 1 if _run_case("single_top_block",
			_make_solid(5, 5, 5),
			[Vector3i(2, 4, 2)],
			[Vector3i(2, 4, 2)],
			0) else 0

	# Foundation hit — destroy y=0 column, expect upper column to detach.
	pass_count += 1 if _run_case("foundation_hit_5x10x5_column",
			_make_column(5, 10, 5, 2, 2),
			[Vector3i(2, 0, 2)],
			[Vector3i(2, 0, 2)],
			-1) else 0  # -1 = "any non-zero", not specific count

	# Wide structure: knock out a chunk in the middle, see which blocks
	# become unsupported.
	pass_count += 1 if _run_case("middle_chunk_5x5x5",
			_make_solid(5, 5, 5),
			[Vector3i(2, 2, 2), Vector3i(2, 1, 2), Vector3i(2, 0, 2)],
			[Vector3i(2, 0, 2), Vector3i(2, 1, 2), Vector3i(2, 2, 2)],
			-1) else 0

	# Sequential damage — apply two damage events in sequence, verify
	# cumulative state matches full solve from scratch.
	pass_count += 1 if _run_sequential_case("sequential_two_blasts",
			_make_solid(5, 8, 5),
			[
				[Vector3i(2, 0, 2)],  # first event
				[Vector3i(0, 0, 0), Vector3i(4, 0, 4)],  # second event
			]) else 0

	# Tall thin tower — single-column foundation hit cascades the entire tower.
	pass_count += 1 if _run_case("tall_tower_2x20x2",
			_make_solid(2, 20, 2),
			[Vector3i(0, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(1, 0, 1)],
			[Vector3i(0, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(1, 0, 1)],
			-1) else 0

	# Total pass/fail count.
	fail_count = 6 - pass_count
	print("")
	print("=== Summary: %d passed, %d failed ===" % [pass_count, fail_count])
	quit(0 if fail_count == 0 else 1)


func _make_solid(nx: int, ny: int, nz: int) -> Dictionary:
	## Build a fully-solid block_grid.
	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	for i in grid.size():
		grid[i] = 1
	var ground := PackedByteArray()
	ground.resize(nx * ny * nz)
	for bx in nx:
		for bz in nz:
			var idx := bx * ny * nz + 0 * nz + bz  # y=0
			ground[idx] = 1
	return {
		"grid": grid, "ground": ground,
		"nx": nx, "ny": ny, "nz": nz,
		"total": nx * ny * nz,
	}


func _make_column(nx: int, ny: int, nz: int, cx: int, cz: int) -> Dictionary:
	## Single column at (cx, *, cz) in an nx*ny*nz volume.
	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	var count := 0
	for by in ny:
		var idx := cx * ny * nz + by * nz + cz
		grid[idx] = 1
		count += 1
	var ground := PackedByteArray()
	ground.resize(nx * ny * nz)
	ground[cx * ny * nz + 0 * nz + cz] = 1  # bottom of column
	return {
		"grid": grid, "ground": ground,
		"nx": nx, "ny": ny, "nz": nz,
		"total": count,
	}


func _flat_idx(key: Vector3i, nx: int, ny: int, nz: int) -> int:
	return key.x * ny * nz + key.y * nz + key.z


func _run_case(name: String, struct: Dictionary,
		full_destroy_keys: Array, dirty_seed_keys: Array,
		expected_components: int) -> bool:
	## Apply destruction to two separate copies, run full solver on one and
	## localized on the other. Compare component sizes.
	var nx: int = struct["nx"]
	var ny: int = struct["ny"]
	var nz: int = struct["nz"]
	var ground: PackedByteArray = struct["ground"]
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")

	# --- Path A: full solve from scratch on a grid with all destruction applied ---
	var grid_full: PackedByteArray = (struct["grid"] as PackedByteArray).duplicate()
	for k_v in full_destroy_keys:
		var k: Vector3i = k_v
		grid_full[_flat_idx(k, nx, ny, nz)] = 0
	var total_full: int = int(struct["total"]) - full_destroy_keys.size()
	var full_components: Array = bmb.calc_stress_integrity_components(
		grid_full, ground, PackedFloat32Array(),
		nx, ny, nz, total_full,
		STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER)

	# --- Path B: full solve on undamaged grid (initial), then localized solve
	#     after applying dirty seeds. ---
	var grid_initial: PackedByteArray = (struct["grid"] as PackedByteArray).duplicate()
	# First call: full solve on undamaged grid to seed persistent state.
	var initial_result: Dictionary = bmb.calc_stress_integrity_localized(
		grid_initial, ground, PackedFloat32Array(),
		nx, ny, nz, struct["total"],
		STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
		PackedInt32Array(), {})
	var persistent: Dictionary = initial_result.get("persistent_state", {})

	# Apply dirty seed destruction to the localized grid.
	var grid_local: PackedByteArray = grid_initial.duplicate()
	var seed_indices := PackedInt32Array()
	for k_v in dirty_seed_keys:
		var k: Vector3i = k_v
		var idx := _flat_idx(k, nx, ny, nz)
		grid_local[idx] = 0
		seed_indices.append(idx)
	var total_local: int = int(struct["total"]) - dirty_seed_keys.size()
	var local_result: Dictionary = bmb.calc_stress_integrity_localized(
		grid_local, ground, PackedFloat32Array(),
		nx, ny, nz, total_local,
		STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
		seed_indices, persistent)

	var local_components: Array = local_result.get("components", [])
	var used_full: bool = local_result.get("used_full_resolve", false)

	var full_sizes := _component_sizes(full_components)
	var local_sizes := _component_sizes(local_components)

	var ok: bool = full_sizes == local_sizes
	if expected_components >= 0:
		ok = ok and (local_components.size() == expected_components)

	var verdict := "PASS" if ok else "FAIL"
	print("[%s] %s  full=%s  local=%s  used_full=%s  expected=%s" % [
		verdict, name, str(full_sizes), str(local_sizes), str(used_full),
		str(expected_components) if expected_components >= 0 else "any"])

	return ok


func _run_sequential_case(name: String, struct: Dictionary,
		event_seq: Array) -> bool:
	## Apply destruction events one at a time via the localized solver, then
	## compare to a full solve on the grid with all events combined.
	var nx: int = struct["nx"]
	var ny: int = struct["ny"]
	var nz: int = struct["nz"]
	var ground: PackedByteArray = struct["ground"]
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")

	# --- Path A: full solve on a grid with ALL events combined ---
	var grid_full: PackedByteArray = (struct["grid"] as PackedByteArray).duplicate()
	var total_destroyed := 0
	for event in event_seq:
		for k_v in event:
			var k: Vector3i = k_v
			grid_full[_flat_idx(k, nx, ny, nz)] = 0
			total_destroyed += 1
	var total_full: int = int(struct["total"]) - total_destroyed
	var full_components: Array = bmb.calc_stress_integrity_components(
		grid_full, ground, PackedFloat32Array(),
		nx, ny, nz, total_full,
		STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER)

	# --- Path B: localized solver applied event-by-event ---
	var grid_local: PackedByteArray = (struct["grid"] as PackedByteArray).duplicate()
	# Initial full solve to seed persistent state.
	var prev_result: Dictionary = bmb.calc_stress_integrity_localized(
		grid_local, ground, PackedFloat32Array(),
		nx, ny, nz, struct["total"],
		STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
		PackedInt32Array(), {})
	var persistent: Dictionary = prev_result.get("persistent_state", {})
	var current_total: int = struct["total"]

	for event in event_seq:
		var seed_indices := PackedInt32Array()
		for k_v in event:
			var k: Vector3i = k_v
			var idx := _flat_idx(k, nx, ny, nz)
			grid_local[idx] = 0
			seed_indices.append(idx)
			current_total -= 1
		var event_result: Dictionary = bmb.calc_stress_integrity_localized(
			grid_local, ground, PackedFloat32Array(),
			nx, ny, nz, current_total,
			STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
			seed_indices, persistent)
		# Apply detached components to the grid (caller's responsibility).
		var detached_components: Array = event_result.get("components", [])
		for c in detached_components:
			for k_v in c:
				var k: Vector3i = k_v
				grid_local[_flat_idx(k, nx, ny, nz)] = 0
				current_total -= 1
		persistent = event_result.get("persistent_state", {})

	# Final solve on the grid as it stands now (after all event-driven detach).
	# Compare with full's notion of "all destruction applied at once."
	# Note: full's components are blocks that would detach; in the local path,
	# they were already detached via the loop above. So at this point grid_local
	# should match grid_full (same set of present blocks).
	var local_present := _count_present(grid_local)
	var full_present := _count_present(grid_full)

	var ok := local_present == full_present
	# Stricter check: identical block sets.
	if ok:
		for i in grid_local.size():
			if grid_local[i] != grid_full[i]:
				ok = false
				break

	var verdict := "PASS" if ok else "FAIL"
	print("[%s] %s  local_present=%d  full_present=%d  events=%d" % [
		verdict, name, local_present, full_present, event_seq.size()])
	return ok


func _component_sizes(components: Array) -> Array[int]:
	var sizes: Array[int] = []
	for c in components:
		sizes.append(c.size())
	sizes.sort()
	return sizes


func _count_present(grid: PackedByteArray) -> int:
	var n := 0
	for i in grid.size():
		if grid[i] == 1:
			n += 1
	return n
