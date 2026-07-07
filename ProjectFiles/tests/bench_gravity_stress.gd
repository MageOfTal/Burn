extends SceneTree

## Benchmark solve_gravity_stress on realistic structure sizes.
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/bench_gravity_stress.gd


func _grid_idx(x: int, y: int, z: int, ny: int, nz: int) -> int:
	return x * ny * nz + y * nz + z


func _bench(label: String, bmb: Object, nx: int, ny: int, nz: int,
		blocks: Array, anchors: Array, params: Dictionary) -> void:
	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	var mask := PackedByteArray()
	mask.resize(nx * ny * nz)
	for b: Vector3i in blocks:
		grid[_grid_idx(b.x, b.y, b.z, ny, nz)] = 1
	for a: Vector3i in anchors:
		mask[_grid_idx(a.x, a.y, a.z, ny, nz)] = 1
	var bonds: Dictionary = bmb.compute_bond_graph(grid, nx, ny, nz, 100.0)

	# Warm once, then take the best of 3 (steady-state cost).
	var best_us := 1 << 60
	var last: Dictionary = {}
	for i in 4:
		var res: Dictionary = bmb.solve_gravity_stress(grid, mask,
			bonds["bond_strength"], bonds["bond_damage"], bonds["bond_broken"],
			PackedFloat32Array(), PackedFloat32Array(), PackedByteArray(),
			nx, ny, nz, Vector3(0, -1, 0), params)
		if i > 0:
			best_us = mini(best_us, int(res["solve_us"]))
		last = res
	print("%s: blocks=%d  solve=%.2fms  cg_iters=%d  passes=%d  converged=%s  maxU=%.3f  broke=%d/%d" % [
		label, blocks.size(), best_us / 1000.0, int(last["cg_iters"]),
		int(last["passes"]), str(last["converged"]),
		float(last["max_utilization"]),
		int(last["broke_bonds"]), int(last["broke_anchors"])])


func _init() -> void:
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	var params := { "tension": 50.0, "compression": 500.0, "shear": 37.5 }

	# Standard wall: 10m × 4m × 1m at 0.5 blocks = 20×8×2.
	var wall: Array = []
	var wall_anchors: Array = []
	for x in 20:
		for y in 8:
			for z in 2:
				wall.append(Vector3i(x, y, z))
				if y == 0:
					wall_anchors.append(Vector3i(x, 0, z))
	_bench("wall 20x8x2      ", bmb, 20, 8, 2, wall, wall_anchors, params)

	# Hollow tower: 10×10 footprint, 40 tall, 1-thick walls (~1500 blocks).
	var tower: Array = []
	var tower_anchors: Array = []
	for x in 10:
		for z in 10:
			var shell: bool = x == 0 or x == 9 or z == 0 or z == 9
			if not shell:
				continue
			for y in 40:
				tower.append(Vector3i(x, y, z))
			tower_anchors.append(Vector3i(x, 0, z))
	_bench("hollow tower 40h ", bmb, 10, 40, 10, tower, tower_anchors, params)

	# Solid cube: worst case, 4096 blocks.
	var cube: Array = []
	var cube_anchors: Array = []
	for x in 16:
		for y in 16:
			for z in 16:
				cube.append(Vector3i(x, y, z))
				if y == 0:
					cube_anchors.append(Vector3i(x, 0, z))
	_bench("solid cube 16^3  ", bmb, 16, 16, 16, cube, cube_anchors, params)

	# Cascade cost: wall with a long unstable rooftop overhang (breaks + re-solves).
	var owall: Array = []
	var owall_anchors: Array = []
	for x in 12:
		for y in 6:
			owall.append(Vector3i(x, y, 0))
			if y == 0:
				owall_anchors.append(Vector3i(x, 0, 0))
	for x in range(12, 24):
		owall.append(Vector3i(x, 5, 0))  # 12-block overhang off the top
	_bench("wall + overhang  ", bmb, 24, 6, 1, owall, owall_anchors, params)

	quit(0)
