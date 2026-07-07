extends SceneTree

## Headless test harness for the bond-graph connectivity check.
## Covers calc_bond_connectivity_components(): given a flat occupancy grid,
## a ground mask, and a per-bond broken array, returns connected components
## of blocks that are no longer reachable from any ground anchor.
##
## Bond canonical layout: bond_idx = block_idx * 3 + axis,
## where axis ∈ {0=+X, 1=+Y, 2=+Z}. The bond is owned by the lower-indexed
## block of the pair. -X/-Y/-Z bonds are looked up on the lower neighbor.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_bond_connectivity.gd


func _init() -> void:
	print("=== Bond connectivity tests ===")
	print("")

	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: BlockMeshBuilder class not found. Engine build is missing the module.")
		quit(2)
		return

	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if not bmb.has_method("calc_bond_connectivity_components"):
		print("FATAL: calc_bond_connectivity_components is missing — engine needs rebuild.")
		quit(2)
		return

	var pass_count := 0
	var fail_count := 0

	pass_count += 1 if _test_solid_no_breaks(bmb) else 0
	pass_count += 1 if _test_one_block_isolated(bmb) else 0
	pass_count += 1 if _test_tower_severed_at_base(bmb) else 0
	pass_count += 1 if _test_wall_severed_horizontal(bmb) else 0
	pass_count += 1 if _test_two_disconnected_islands(bmb) else 0
	pass_count += 1 if _test_destroyed_block_cascades(bmb) else 0
	pass_count += 1 if _test_broken_bond_to_missing_block(bmb) else 0

	fail_count = 7 - pass_count
	print("")
	print("=== Summary: %d/%d passed ===" % [pass_count, pass_count + fail_count])
	quit(0 if fail_count == 0 else 1)


# ────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────

func _grid_idx(x: int, y: int, z: int, ny: int, nz: int) -> int:
	return x * ny * nz + y * nz + z


func _make_solid(nx: int, ny: int, nz: int) -> Dictionary:
	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	for i in grid.size():
		grid[i] = 1
	var ground := PackedByteArray()
	ground.resize(nx * ny * nz)
	for bx in nx:
		for bz in nz:
			ground[_grid_idx(bx, 0, bz, ny, nz)] = 1
	return {
		"grid": grid, "ground": ground,
		"nx": nx, "ny": ny, "nz": nz,
		"total": nx * ny * nz,
	}


func _init_bonds(grid: PackedByteArray, nx: int, ny: int, nz: int) -> PackedByteArray:
	## Build a `bond_broken` array sized (nx*ny*nz)*3. A bond is intact (0) iff
	## both this block and its +axis neighbor are occupied; otherwise broken (1).
	var bonds := PackedByteArray()
	bonds.resize(nx * ny * nz * 3)
	for bx in nx:
		for by in ny:
			for bz in nz:
				var here := _grid_idx(bx, by, bz, ny, nz)
				var here_occ := grid[here] == 1
				# +X
				var bi_x := here * 3 + 0
				if here_occ and bx + 1 < nx and grid[_grid_idx(bx + 1, by, bz, ny, nz)] == 1:
					bonds[bi_x] = 0
				else:
					bonds[bi_x] = 1
				# +Y
				var bi_y := here * 3 + 1
				if here_occ and by + 1 < ny and grid[_grid_idx(bx, by + 1, bz, ny, nz)] == 1:
					bonds[bi_y] = 0
				else:
					bonds[bi_y] = 1
				# +Z
				var bi_z := here * 3 + 2
				if here_occ and bz + 1 < nz and grid[_grid_idx(bx, by, bz + 1, ny, nz)] == 1:
					bonds[bi_z] = 0
				else:
					bonds[bi_z] = 1
	return bonds


func _component_sizes(components: Array) -> Array[int]:
	var sizes: Array[int] = []
	for c in components:
		sizes.append(c.size())
	sizes.sort()
	return sizes


func _sizes_equal(actual: Array[int], expected: Array) -> bool:
	## GDScript can't cast `[1] as Array[int]` directly, so compare element-wise.
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		if actual[i] != int(expected[i]):
			return false
	return true


func _verdict(name: String, ok: bool, detail: String) -> bool:
	var label := "PASS" if ok else "FAIL"
	print("[%s] %s — %s" % [label, name, detail])
	return ok


# ────────────────────────────────────────────────────────────────────────────
# Cases
# ────────────────────────────────────────────────────────────────────────────

func _test_solid_no_breaks(bmb: Object) -> bool:
	## Fully connected solid: no bonds broken → no components detached.
	var s := _make_solid(4, 4, 4)
	var bonds := _init_bonds(s["grid"], s["nx"], s["ny"], s["nz"])
	var components: Array = bmb.calc_bond_connectivity_components(
		s["grid"], s["ground"], bonds,
		s["nx"], s["ny"], s["nz"], s["total"])
	return _verdict("solid_no_breaks",
		components.is_empty(),
		"components=%d" % components.size())


func _test_one_block_isolated(bmb: Object) -> bool:
	## 3x3x3 solid; sever every bond of the top-center block. That single block
	## should detach.
	var nx := 3; var ny := 3; var nz := 3
	var s := _make_solid(nx, ny, nz)
	var bonds := _init_bonds(s["grid"], nx, ny, nz)
	var key := Vector3i(1, 2, 1)
	# All 6 bonds touching this block: 3 it owns + 3 its lower neighbors own.
	var here := _grid_idx(key.x, key.y, key.z, ny, nz)
	for axis in 3:
		bonds[here * 3 + axis] = 1
	if key.x > 0:
		bonds[_grid_idx(key.x - 1, key.y, key.z, ny, nz) * 3 + 0] = 1
	if key.y > 0:
		bonds[_grid_idx(key.x, key.y - 1, key.z, ny, nz) * 3 + 1] = 1
	if key.z > 0:
		bonds[_grid_idx(key.x, key.y, key.z - 1, ny, nz) * 3 + 2] = 1
	var components: Array = bmb.calc_bond_connectivity_components(
		s["grid"], s["ground"], bonds,
		nx, ny, nz, s["total"])
	var sizes := _component_sizes(components)
	var ok: bool = _sizes_equal(sizes, [1])
	# Confirm it's the right block.
	if ok and components.size() == 1:
		var comp: Array = components[0]
		ok = comp.size() == 1 and comp[0] == key
	return _verdict("one_block_isolated", ok, "sizes=%s" % str(sizes))


func _test_tower_severed_at_base(bmb: Object) -> bool:
	## Single-column tower 1x6x1; sever the +Y bond between y=0 and y=1.
	## Blocks y=1..5 (5 blocks) should detach as one component.
	var nx := 1; var ny := 6; var nz := 1
	var grid := PackedByteArray(); grid.resize(nx * ny * nz)
	for i in grid.size(): grid[i] = 1
	var ground := PackedByteArray(); ground.resize(nx * ny * nz)
	ground[_grid_idx(0, 0, 0, ny, nz)] = 1
	var s := { "grid": grid, "ground": ground, "nx": nx, "ny": ny, "nz": nz, "total": nx*ny*nz }
	var bonds := _init_bonds(grid, nx, ny, nz)
	# Sever +Y bond owned by (0, 0, 0).
	bonds[_grid_idx(0, 0, 0, ny, nz) * 3 + 1] = 1
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds, nx, ny, nz, s["total"])
	var sizes := _component_sizes(components)
	var ok: bool = _sizes_equal(sizes, [5])
	return _verdict("tower_severed_at_base", ok, "sizes=%s" % str(sizes))


func _test_wall_severed_horizontal(bmb: Object) -> bool:
	## 5x4x1 wall (single layer in Z). Sever every +Y bond between y=1 and y=2.
	## Top half (y=2,3 → 5*2 = 10 blocks) should detach as one component.
	var nx := 5; var ny := 4; var nz := 1
	var grid := PackedByteArray(); grid.resize(nx * ny * nz)
	for i in grid.size(): grid[i] = 1
	var ground := PackedByteArray(); ground.resize(nx * ny * nz)
	for bx in nx:
		ground[_grid_idx(bx, 0, 0, ny, nz)] = 1
	var bonds := _init_bonds(grid, nx, ny, nz)
	for bx in nx:
		# +Y bond owned by (bx, 1, 0) — connects y=1 to y=2.
		bonds[_grid_idx(bx, 1, 0, ny, nz) * 3 + 1] = 1
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds, nx, ny, nz, nx * ny * nz)
	var sizes := _component_sizes(components)
	var ok: bool = _sizes_equal(sizes, [10])
	return _verdict("wall_severed_horizontal", ok, "sizes=%s" % str(sizes))


func _test_two_disconnected_islands(bmb: Object) -> bool:
	## Two separate towers in a 3x4x1 grid: column at x=0 and column at x=2.
	## Sever the +Y bond at base of the x=2 tower. Only x=2 tower detaches.
	var nx := 3; var ny := 4; var nz := 1
	var grid := PackedByteArray(); grid.resize(nx * ny * nz)
	for by in ny:
		grid[_grid_idx(0, by, 0, ny, nz)] = 1
		grid[_grid_idx(2, by, 0, ny, nz)] = 1
	var ground := PackedByteArray(); ground.resize(nx * ny * nz)
	ground[_grid_idx(0, 0, 0, ny, nz)] = 1
	ground[_grid_idx(2, 0, 0, ny, nz)] = 1
	var total := 2 * ny
	var bonds := _init_bonds(grid, nx, ny, nz)
	# Sever (2, 0, 0)'s +Y bond.
	bonds[_grid_idx(2, 0, 0, ny, nz) * 3 + 1] = 1
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds, nx, ny, nz, total)
	var sizes := _component_sizes(components)
	# 3 blocks above the severed bond on the x=2 tower (y=1,2,3).
	var ok: bool = _sizes_equal(sizes, [3])
	return _verdict("two_disconnected_islands", ok, "sizes=%s" % str(sizes))


func _test_destroyed_block_cascades(bmb: Object) -> bool:
	## Tower 1x5x1: destroy block at y=2 (set grid=0, mark 6 touching bonds
	## broken). Blocks y=3,4 should detach (2 blocks).
	var nx := 1; var ny := 5; var nz := 1
	var grid := PackedByteArray(); grid.resize(nx * ny * nz)
	for i in grid.size(): grid[i] = 1
	# Destroy y=2.
	grid[_grid_idx(0, 2, 0, ny, nz)] = 0
	var ground := PackedByteArray(); ground.resize(nx * ny * nz)
	ground[_grid_idx(0, 0, 0, ny, nz)] = 1
	var bonds := _init_bonds(grid, nx, ny, nz)
	# _init_bonds already marks bonds touching the missing block as broken
	# because the +axis check requires both endpoints be occupied. We also
	# need the -Y bond from the block above (y=3) — that's owned by y=2 and
	# was already marked broken because y=2 is empty. So _init_bonds is enough.
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds, nx, ny, nz, ny - 1)
	var sizes := _component_sizes(components)
	var ok: bool = _sizes_equal(sizes, [2])
	return _verdict("destroyed_block_cascades", ok, "sizes=%s" % str(sizes))


func _test_broken_bond_to_missing_block(bmb: Object) -> bool:
	## Sanity: bonds whose neighbor isn't in the grid should never act as
	## connectivity paths. Single 1x1x1 block with no neighbors should remain
	## ground-supported and produce no components.
	var nx := 1; var ny := 1; var nz := 1
	var grid := PackedByteArray(); grid.resize(1)
	grid[0] = 1
	var ground := PackedByteArray(); ground.resize(1)
	ground[0] = 1
	var bonds := PackedByteArray(); bonds.resize(3)
	# All 3 bond slots have no neighbor; mark all broken.
	bonds[0] = 1; bonds[1] = 1; bonds[2] = 1
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds, nx, ny, nz, 1)
	return _verdict("broken_bond_to_missing_block",
		components.is_empty(),
		"components=%d" % components.size())
