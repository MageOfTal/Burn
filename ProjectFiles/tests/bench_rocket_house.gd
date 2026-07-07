extends SceneTree

## Per-stage baseline for the rocket-on-big-house lag spike. Loads the REAL
## large_structure.tres voxel data and times every stage the destruction
## pipeline runs in the rocket frame, plus the per-cluster costs that scale
## with detach count. Run before/after optimizations.
##
## Run via:
##   Godot_v4.6-stable_win64.exe --headless --path ProjectFiles --script res://tests/bench_rocket_house.gd

const BLOCK_SIZE := 0.5
const BLOCK_HP := 12.0          # OBJ structure tier
const ROCKET_STRUCT_DMG := 350.0
const BOND_EXPL_FACTOR := 0.5
const ROCKET_RADIUS := 8.0


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _best_of(n: int, f: Callable) -> float:
	var best := 1.0e18
	for i in n:
		var t0 := Time.get_ticks_usec()
		f.call()
		best = minf(best, float(Time.get_ticks_usec() - t0))
	return best


func _run() -> void:
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	var data: Resource = load("res://world/definitions/large_structure.tres")
	var cells: Array = data.occupied_cells
	var dims: Vector3i = data.grid_dimensions
	var nx: int = dims.x
	var ny: int = dims.y
	var nz: int = dims.z
	var grid_size := nx * ny * nz
	print("=== bench_rocket_house: %d blocks in %dx%dx%d grid (%d cells) ===" % [
		cells.size(), nx, ny, nz, grid_size])

	var grid := PackedByteArray()
	grid.resize(grid_size)
	for c: Vector3i in cells:
		grid[c.x * ny * nz + c.y * nz + c.z] = 1

	# Ground mask: lowest occupied block per column (approximates anchors).
	var mask := PackedByteArray()
	mask.resize(grid_size)
	for bx in nx:
		for bz in nz:
			for by in ny:
				var idx := bx * ny * nz + by * nz + bz
				if grid[idx] == 1:
					mask[idx] = 1
					break

	# ── Stage 0: initial bond graph build (structure _ready cost) ──
	# NOTE: GDScript lambdas capture by value — results computed OUTSIDE the
	# timing closures, closures re-run the call for timing only.
	var bonds: Dictionary = bmb.compute_bond_graph(grid, nx, ny, nz, BLOCK_HP * 1.0)
	var us := _best_of(3, func() -> void:
		bmb.compute_bond_graph(grid, nx, ny, nz, BLOCK_HP * 1.0))
	print("[stage] compute_bond_graph (full structure): %.2fms" % (us / 1000.0))

	# Rocket hits the outer wall at mid-height.
	var hit_local := Vector3(
		(2.0 + 0.5 - nx * 0.5) * BLOCK_SIZE,
		(8.0 + 0.5 - ny * 0.5) * BLOCK_SIZE,
		(nz * 0.5 - nz * 0.5) * BLOCK_SIZE)
	var energy := ROCKET_STRUCT_DMG * BOND_EXPL_FACTOR

	# ── Stage 1: radial bond damage kernel (C++) ──
	var dmg_result: Dictionary = bmb.damage_bonds_radial_shielded(
		grid, bonds["bond_strength"], bonds["bond_damage"], bonds["bond_broken"],
		nx, ny, nz, BLOCK_SIZE, hit_local, energy, ROCKET_RADIUS, BLOCK_HP)
	us = _best_of(3, func() -> void:
		bmb.damage_bonds_radial_shielded(
			grid, bonds["bond_strength"], bonds["bond_damage"], bonds["bond_broken"],
			nx, ny, nz, BLOCK_SIZE, hit_local, energy, ROCKET_RADIUS, BLOCK_HP))
	print("[stage] damage_bonds_radial_shielded: %.2fms (damaged=%d broken=%d)" % [
		us / 1000.0, int(dmg_result["damaged"]), int(dmg_result["broken"])])

	# ── Stage 2: anchor damage — current GDScript loop, replicated exactly ──
	var anchor_strength := PackedFloat32Array()
	var anchor_damage := PackedFloat32Array()
	var anchor_broken := PackedByteArray()
	anchor_strength.resize(grid_size)
	anchor_damage.resize(grid_size)
	anchor_broken.resize(grid_size)
	anchor_broken.fill(1)
	for i in grid_size:
		if mask[i] == 1 and grid[i] == 1:
			anchor_strength[i] = BLOCK_HP
			anchor_broken[i] = 0
	us = _best_of(3, func() -> void:
		var inv_radius := 1.0 / ROCKET_RADIUS
		var ny_nz := ny * nz
		var r_blocks := ROCKET_RADIUS / BLOCK_SIZE + 1.0
		var a_dmg := anchor_damage.duplicate()
		var a_brk := anchor_broken.duplicate()
		var min_bx: int = maxi(0, int(hit_local.x / BLOCK_SIZE + nx * 0.5 - r_blocks))
		var max_bx: int = mini(nx, int(hit_local.x / BLOCK_SIZE + nx * 0.5 + r_blocks) + 1)
		var min_by: int = maxi(0, int(hit_local.y / BLOCK_SIZE + ny * 0.5 - r_blocks))
		var max_by: int = mini(ny, int(hit_local.y / BLOCK_SIZE + ny * 0.5 + r_blocks) + 1)
		var min_bz: int = maxi(0, int(hit_local.z / BLOCK_SIZE + nz * 0.5 - r_blocks))
		var max_bz: int = mini(nz, int(hit_local.z / BLOCK_SIZE + nz * 0.5 + r_blocks) + 1)
		for bx in range(min_bx, max_bx):
			for by in range(min_by, max_by):
				for bz in range(min_bz, max_bz):
					var idx := bx * ny_nz + by * nz + bz
					if a_brk[idx] != 0:
						continue
					if mask[idx] != 1 or grid[idx] != 1:
						continue
					var bp := Vector3(
						(bx + 0.5 - nx * 0.5) * BLOCK_SIZE,
						(by + 0.5 - ny * 0.5) * BLOCK_SIZE,
						(bz + 0.5 - nz * 0.5) * BLOCK_SIZE)
					var d := hit_local.distance_to(bp)
					if d > ROCKET_RADIUS:
						continue
					var norm_d := d * inv_radius
					var falloff: float = 1.0 / (1.0 + (norm_d * 3.0) ** 3)
					a_dmg[idx] += energy * falloff
					if a_dmg[idx] >= anchor_strength[idx]:
						a_brk[idx] = 1)
	print("[stage] anchor damage (GDScript loop): %.2fms" % (us / 1000.0))

	# ── Stage 3: gravity stress solve on damaged structure ──
	var gs: Dictionary = bmb.solve_gravity_stress(
		grid, mask,
		bonds["bond_strength"], dmg_result["bond_damage"], dmg_result["bond_broken"],
		anchor_strength, anchor_damage, anchor_broken,
		nx, ny, nz, Vector3(0, -1, 0),
		{ "tension": 90.0, "compression": 900.0, "shear": 67.5 })
	us = _best_of(3, func() -> void:
		bmb.solve_gravity_stress(
			grid, mask,
			bonds["bond_strength"], dmg_result["bond_damage"], dmg_result["bond_broken"],
			anchor_strength, anchor_damage, anchor_broken,
			nx, ny, nz, Vector3(0, -1, 0),
			{ "tension": 90.0, "compression": 900.0, "shear": 67.5 }))
	print("[stage] solve_gravity_stress: %.2fms (cg=%d passes=%d broke=%d/%d conv=%s)" % [
		us / 1000.0, int(gs["cg_iters"]), int(gs["passes"]),
		int(gs["broke_bonds"]), int(gs["broke_anchors"]), str(gs["converged"])])

	# ── Stage 4: connectivity check ──
	var comps: Array = bmb.calc_bond_connectivity_components(
		grid, mask, gs["bond_broken"], nx, ny, nz, cells.size())
	us = _best_of(3, func() -> void:
		bmb.calc_bond_connectivity_components(
			grid, mask, gs["bond_broken"], nx, ny, nz, cells.size()))
	var comp_blocks := 0
	var singles := 0
	for c: Array in comps:
		comp_blocks += c.size()
		if c.size() == 1:
			singles += 1
	print("[stage] connectivity: %.2fms (components=%d blocks=%d singles=%d)" % [
		us / 1000.0, comps.size(), comp_blocks, singles])

	# ── Stage 5: per-cluster bond graph init — full-grid vs tight dims ──
	# Every detached multi-block component pays compute_bond_graph at the
	# PARENT grid dims today. Compare with a tight 6x6x6 chunk grid.
	var n_clusters := maxi(comps.size() - singles, 1)
	us = _best_of(3, func() -> void:
		bmb.compute_bond_graph(grid, nx, ny, nz, BLOCK_HP))
	print("[stage] per-cluster compute_bond_graph @ FULL grid: %.3fms x %d clusters = %.2fms" % [
		us / 1000.0, n_clusters, us * n_clusters / 1000.0])
	var tight := PackedByteArray()
	tight.resize(6 * 6 * 6)
	tight.fill(1)
	us = _best_of(3, func() -> void:
		bmb.compute_bond_graph(tight, 6, 6, 6, BLOCK_HP))
	print("[stage] per-cluster compute_bond_graph @ 6x6x6: %.3fms x %d clusters = %.2fms" % [
		us / 1000.0, n_clusters, us * n_clusters / 1000.0])

	# ── Stage 6: cluster connectivity re-check at full-grid dims (per split) ──
	var empty_ground := PackedByteArray()
	empty_ground.resize(grid_size)
	us = _best_of(3, func() -> void:
		bmb.calc_bond_connectivity_components(
			grid, empty_ground, gs["bond_broken"], nx, ny, nz, cells.size()))
	print("[stage] cluster integrity @ FULL grid: %.2fms per damaged cluster" % (us / 1000.0))

	# ── Stage 7: smooth collision rebuild (box decomposition, no body) ──
	# Approximated via build_collision_faces (same scale of work).
	us = _best_of(3, func() -> void:
		bmb.build_collision_faces(grid, nx, ny, nz, BLOCK_SIZE))
	print("[stage] build_collision_faces (mesh faces): %.2fms" % (us / 1000.0))
	us = _best_of(3, func() -> void:
		bmb.build_block_mesh(grid, nx, ny, nz, BLOCK_SIZE, Vector3.ZERO, true))
	print("[stage] build_block_mesh (greedy remesh): %.2fms" % (us / 1000.0))

	# ── Stage 8: print() flood cost (typical collapse spams 300+ lines) ──
	var t0 := Time.get_ticks_usec()
	for i in 300:
		print("[ClusterPerf] init_cluster_blocks FallingCluster_%d: 24 blocks, total=123us (single C++ call)" % i)
	var print_us := Time.get_ticks_usec() - t0
	print("[stage] 300 print() lines: %.2fms" % (print_us / 1000.0))

	quit(0)
