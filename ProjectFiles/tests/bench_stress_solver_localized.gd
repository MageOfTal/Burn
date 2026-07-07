extends SceneTree

## Performance benchmark: localized stress solver vs full solver.
## Measures wall time for both paths on a representative damage sequence.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/bench_stress_solver_localized.gd

const STRESS_MAX_LOAD: float = 15.0
const STRESS_HORIZONTAL_TRANSFER: float = 0.6
const SAMPLES: int = 10  # iterations per scenario for averaging


func _init() -> void:
	# Silence the C++ stress solver's per-call prints — they dominate per-call
	# wall time and obscure the actual solver cost. (~1ms per print on Windows.)
	var bmb_setup: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if bmb_setup.has_method("set_stress_debug_print"):
		bmb_setup.set_stress_debug_print(false)

	print("=== Localized stress solver benchmark ===")
	print("(%d samples per scenario, microseconds)" % SAMPLES)
	print("")
	print("%-32s %12s %12s %12s" % ["Scenario", "full(us)", "local(us)", "speedup"])
	print(String("-").repeat(72))

	# Warmup the JIT / hot paths.
	_run_scenario("warmup_5x5x5", 5, 5, 5, 5)

	# Scenarios: nx, ny, nz, num_destruction_events
	# Larger structures benefit more from localization.
	_run_scenario("small_5x5x5", 5, 5, 5, 5)
	_run_scenario("medium_10x10x10", 10, 10, 10, 10)
	_run_scenario("tall_5x20x5", 5, 20, 5, 10)
	_run_scenario("wide_15x5x15", 15, 5, 15, 15)
	_run_scenario("large_20x15x20", 20, 15, 20, 20)
	_run_scenario("huge_30x10x30", 30, 10, 30, 30)
	_run_scenario("massive_40x20x40", 40, 20, 40, 50)

	quit(0)


func _run_scenario(name: String, nx: int, ny: int, nz: int, events: int) -> void:
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")

	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	for i in grid.size():
		grid[i] = 1
	var ground := PackedByteArray()
	ground.resize(nx * ny * nz)
	for bx in nx:
		for bz in nz:
			ground[bx * ny * nz + 0 * nz + bz] = 1

	# Generate `events` destruction events, each removing a single random non-ground block.
	# Same seed sequence used for both full and local paths to keep work identical.
	var rng := RandomNumberGenerator.new()
	var event_keys: Array[Vector3i] = []
	rng.seed = 42
	while event_keys.size() < events:
		var bx := rng.randi_range(0, nx - 1)
		var by := rng.randi_range(1, ny - 1)
		var bz := rng.randi_range(0, nz - 1)
		var k := Vector3i(bx, by, bz)
		if k not in event_keys:
			event_keys.append(k)

	# --- Path A: full solver after each event ---
	var full_total_us := 0
	for sample in SAMPLES:
		var grid_full: PackedByteArray = grid.duplicate()
		var total: int = nx * ny * nz
		for k in event_keys:
			grid_full[_flat_idx(k, nx, ny, nz)] = 0
			total -= 1
			var t0 := Time.get_ticks_usec()
			var components: Array = bmb.calc_stress_integrity_components(
				grid_full, ground, PackedFloat32Array(),
				nx, ny, nz, total,
				STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER)
			full_total_us += int(Time.get_ticks_usec() - t0)
			# Apply detached components.
			for c in components:
				for k_v in c:
					var k2: Vector3i = k_v
					grid_full[_flat_idx(k2, nx, ny, nz)] = 0
					total -= 1

	# --- Path B: localized solver after each event ---
	var local_total_us := 0
	for sample in SAMPLES:
		var grid_local: PackedByteArray = grid.duplicate()
		var total: int = nx * ny * nz
		# Initial full solve to seed persistent state.
		var initial: Dictionary = bmb.calc_stress_integrity_localized(
			grid_local, ground, PackedFloat32Array(),
			nx, ny, nz, total,
			STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
			PackedInt32Array(), {})
		var persistent: Dictionary = initial.get("persistent_state", {})
		# Apply initial-detected detachments to grid (defensive; unlikely with all-supported solid).
		for c in (initial.get("components", []) as Array):
			for k_v in c:
				var k2: Vector3i = k_v
				grid_local[_flat_idx(k2, nx, ny, nz)] = 0
				total -= 1
		for k in event_keys:
			var idx := _flat_idx(k, nx, ny, nz)
			grid_local[idx] = 0
			total -= 1
			var seeds := PackedInt32Array([idx])
			var t0 := Time.get_ticks_usec()
			var result: Dictionary = bmb.calc_stress_integrity_localized(
				grid_local, ground, PackedFloat32Array(),
				nx, ny, nz, total,
				STRESS_MAX_LOAD, STRESS_HORIZONTAL_TRANSFER,
				seeds, persistent)
			local_total_us += int(Time.get_ticks_usec() - t0)
			persistent = result.get("persistent_state", {})
			# Apply detached components.
			for c in (result.get("components", []) as Array):
				for k_v in c:
					var k2: Vector3i = k_v
					grid_local[_flat_idx(k2, nx, ny, nz)] = 0
					total -= 1

	var full_avg := float(full_total_us) / float(SAMPLES * events)
	var local_avg := float(local_total_us) / float(SAMPLES * events)
	var speedup := full_avg / maxf(local_avg, 0.01)

	print("%-32s %12.2f %12.2f %11.2fx" % [name, full_avg, local_avg, speedup])


func _flat_idx(key: Vector3i, nx: int, ny: int, nz: int) -> int:
	return key.x * ny * nz + key.y * nz + key.z
