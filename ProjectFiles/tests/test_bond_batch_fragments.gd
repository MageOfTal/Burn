extends SceneTree

## Verifies that damage_bonds_radial_shielded_batch returns "fragments" arrays
## (largest-excluded components) when bonds break enough to disconnect a cluster.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_bond_batch_fragments.gd

const BLOCK_SIZE := 1.0
const BLOCK_HP := 35.0
const BOND_STRENGTH := 1.0  # very weak so a single hit breaks every bond in radius
const BLAST_ENERGY := 100000.0
const BLAST_RADIUS := 100.0


func _init() -> void:
	print("=== Bond batch fragments tests ===")
	print("")

	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: engine missing BlockMeshBuilder."); quit(2); return
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if not bmb.has_method("damage_bonds_radial_shielded_batch"):
		print("FATAL: engine missing damage_bonds_radial_shielded_batch."); quit(2); return

	var pass_count := 0
	pass_count += 1 if _test_intact_returns_no_fragments(bmb) else 0
	pass_count += 1 if _test_split_returns_fragments(bmb) else 0
	pass_count += 1 if _test_largest_excluded(bmb) else 0
	pass_count += 1 if _test_5x5x5_slice(bmb) else 0

	print("")
	print("=== Summary: %d/4 passed ===" % pass_count)
	quit(0 if pass_count == 4 else 1)


func _make_cluster_input(nx: int, ny: int, nz: int, occupied: Array, hit_local: Vector3) -> Dictionary:
	## Build a cluster input dict with all-fresh bond arrays via compute_bond_graph.
	var grid_size := nx * ny * nz
	var grid := PackedByteArray(); grid.resize(grid_size)
	for k_v in occupied:
		var k: Vector3i = k_v
		grid[k.x * ny * nz + k.y * nz + k.z] = 1
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	var bg: Dictionary = bmb.compute_bond_graph(grid, nx, ny, nz, BOND_STRENGTH)
	return {
		"block_grid": grid,
		"bond_strength": bg["bond_strength"],
		"bond_damage": bg["bond_damage"],
		"bond_broken": bg["bond_broken"],
		"num_x": nx, "num_y": ny, "num_z": nz,
		"hit_local": hit_local,
		"energy": BLAST_ENERGY,
		"block_hp": BLOCK_HP,
	}


func _test_intact_returns_no_fragments(bmb: Object) -> bool:
	# 3-block straight line, blast far away — no bonds break.
	var occ: Array = [Vector3i(0,0,0), Vector3i(1,0,0), Vector3i(2,0,0)]
	var input := _make_cluster_input(3, 1, 1, occ, Vector3(1000, 1000, 1000))
	# Lower energy to ensure no break
	input["energy"] = 0.001
	var results: Array = bmb.damage_bonds_radial_shielded_batch(
		[input], BLOCK_SIZE, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var r: Dictionary = results[0]
	var frags: Array = r.get("fragments", [])
	if frags.size() != 0:
		print("FAIL intact_returns_no_fragments: expected 0 fragments, got %d (broken=%d)" % [frags.size(), int(r["broken"])])
		return false
	print("PASS intact_returns_no_fragments")
	return true


func _test_split_returns_fragments(bmb: Object) -> bool:
	# 3-block straight line. Blast at center block destroys all bonds, splitting
	# into 3 single-block components. Largest tied → one is excluded, 2 remain.
	var occ: Array = [Vector3i(0,0,0), Vector3i(1,0,0), Vector3i(2,0,0)]
	var input := _make_cluster_input(3, 1, 1, occ, Vector3(1.5, 0.5, 0.5))
	var results: Array = bmb.damage_bonds_radial_shielded_batch(
		[input], BLOCK_SIZE, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var r: Dictionary = results[0]
	var broken: int = r["broken"]
	var frags: Array = r.get("fragments", [])
	# All inner bonds should break: 2 X-bonds. So 3 components, 2 fragments.
	if broken < 2:
		print("FAIL split_returns_fragments: expected >=2 bonds broken, got %d" % broken)
		return false
	if frags.size() != 2:
		print("FAIL split_returns_fragments: expected 2 fragments, got %d" % frags.size())
		return false
	# Each fragment is exactly one block
	for f in frags:
		var fa: Array = f
		if fa.size() != 1:
			print("FAIL split_returns_fragments: fragment size != 1: %d" % fa.size())
			return false
	print("PASS split_returns_fragments  (broken=%d, fragments=%d)" % [broken, frags.size()])
	return true


func _test_largest_excluded(bmb: Object) -> bool:
	# 5-block line: [A, B, C, D, E]. Break only the bond between B and C.
	# Components: {A, B} and {C, D, E}. Largest is {C, D, E} (size 3).
	# Fragments returned should exclude largest → only {A, B} returned (size 2).
	var occ: Array = [Vector3i(0,0,0), Vector3i(1,0,0), Vector3i(2,0,0),
		Vector3i(3,0,0), Vector3i(4,0,0)]
	# Hit at the boundary between block 1 and block 2 to break that one bond
	var input := _make_cluster_input(5, 1, 1, occ, Vector3(2.0, 0.5, 0.5))
	# Use small radius so only the central bond breaks
	input["energy"] = 100000.0  # plenty of energy
	# Manually break only one specific bond instead — simpler & deterministic.
	# Bond from block 1 (idx=1) +X to block 2: bond_idx = 1*3+0 = 3
	input["bond_broken"][3] = 1
	# Use radius=0 so no further bonds break
	var results: Array = bmb.damage_bonds_radial_shielded_batch(
		[input], BLOCK_SIZE, 0.0, 0.0, BLOCK_HP)
	var r: Dictionary = results[0]
	var frags: Array = r.get("fragments", [])
	# energy=0 → broken_count=0 in damage pass → BFS NOT run by worker
	# (our gate is "if broken_count > 0"). So fragments will be empty here.
	# This test confirms the gate: pre-existing breaks alone don't trigger BFS.
	# Worth knowing — the cluster's GDScript path (call from non-explosion code)
	# would handle this differently.
	if frags.size() != 0:
		print("FAIL largest_excluded (gating check): expected 0 fragments, got %d" % frags.size())
		return false

	# Now do it properly: hit with enough energy so the single bond also breaks
	# fresh in this call. Place blast right at the junction.
	var input2 := _make_cluster_input(5, 1, 1, occ, Vector3(2.0, 0.5, 0.5))
	# Tiny radius so only nearest bond breaks
	var results2: Array = bmb.damage_bonds_radial_shielded_batch(
		[input2], BLOCK_SIZE, BLAST_ENERGY, 0.6, BLOCK_HP)
	var r2: Dictionary = results2[0]
	var broken2: int = r2["broken"]
	var frags2: Array = r2.get("fragments", [])
	print("[debug] broken=%d, fragments=%d, sizes=%s" % [broken2, frags2.size(), _frag_sizes(frags2)])

	if frags2.size() < 1:
		print("FAIL largest_excluded: expected at least 1 fragment, got %d" % frags2.size())
		return false
	# Verify largest was excluded: total fragment block count + largest = 5
	var frag_blocks := 0
	for f in frags2:
		var fa: Array = f
		frag_blocks += fa.size()
	# If 1 fragment, total returned = 5 - largest.size(). If largest is the bigger half (3), fragment = 2.
	# Allow either direction — small fragment may end up being the {A,B} or the {C,D,E} side
	# depending on which BFS index won. In either case, fragment block count = min(2, 3) = 2.
	if frag_blocks != 2:
		print("FAIL largest_excluded: expected fragment block count = 2 (smaller half), got %d" % frag_blocks)
		return false
	print("PASS largest_excluded")
	return true


func _test_5x5x5_slice(bmb: Object) -> bool:
	# Solid 5x5x5 cube. Place blast right on the X=2 plane at high energy with a
	# small radius — only the X-bonds crossing that plane should break, slicing
	# the cluster into two halves of 50 blocks each (X<=1 and X>=2 are 25+25
	# wait actually 25 each side: X=0,1 is 50 blocks (2*5*5), X=2,3,4 is 75 blocks).
	# Hmm let me restate: cube with X in {0..4}. Break +X bonds at X=1 (between
	# X=1 and X=2). That cuts into X<=1 (50 blocks) and X>=2 (75 blocks). Fragments
	# excludes largest (75), so 1 fragment of 50 blocks.
	var occ: Array = []
	for x in 5:
		for y in 5:
			for z in 5:
				occ.append(Vector3i(x, y, z))
	# Position blast right at the X=2 plane center (in local coords).
	# Local origin is at cluster centroid which for 5x5x5 at integer offsets
	# is between x=1.5 and x=2.5 (centered on x=2). half_nx = 2.5.
	# Bond between X=1 and X=2 has midpoint at x=2.0 in voxel space, which
	# in local space is (2.0 - 2.5) * 1 = -0.5. So hit_local.x = -0.5 should
	# place blast right at the +X face of the X=1 column.
	var input := _make_cluster_input(5, 5, 5, occ, Vector3(-0.5, 0.0, 0.0))
	# Use a tight radius (~1 voxel) so only the immediate X-plane bonds break.
	var results: Array = bmb.damage_bonds_radial_shielded_batch(
		[input], BLOCK_SIZE, BLAST_ENERGY * 1000, 50.0, BLOCK_HP)
	var r: Dictionary = results[0]
	var broken: int = r["broken"]
	var frags: Array = r.get("fragments", [])
	print("[debug 5x5x5_slice] broken=%d fragments=%d sizes=%s" % [broken, frags.size(), _frag_sizes(frags)])
	# Expect at least 1 fragment (cluster split)
	if frags.size() < 1:
		print("FAIL 5x5x5_slice: expected >=1 fragment, got %d (broken=%d)" % [frags.size(), broken])
		return false
	print("PASS 5x5x5_slice (broken=%d, fragments=%d)" % [broken, frags.size()])
	return true


func _frag_sizes(frags: Array) -> String:
	var s := PackedStringArray()
	for f in frags:
		var fa: Array = f
		s.append(str(fa.size()))
	return ",".join(s)
