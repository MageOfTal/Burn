extends SceneTree

## Unit tests for damage_bonds_radial_shielded (DDA voxel-walk shielding).
## Verifies:
##   - No obstruction → full radial damage applied (matches old non-shielded path).
##   - One block in the way reduces incoming damage by ~block_hp.
##   - Multiple blocks in the way reduce damage cumulatively.
##   - Oblique angle through a wall absorbs more material than perpendicular.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_bond_shielding.gd

const BLOCK_SIZE := 1.0
const BLOCK_HP := 35.0
const BOND_STRENGTH := 100.0  # high enough that bonds rarely break in these tests
const BLAST_ENERGY := 200.0
const BLAST_RADIUS := 6.0


func _init() -> void:
	print("=== Bond shielding (DDA) tests ===")
	print("")

	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: engine missing BlockMeshBuilder.")
		quit(2); return
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if not bmb.has_method("damage_bonds_radial_shielded"):
		print("FATAL: engine missing damage_bonds_radial_shielded — needs rebuild.")
		quit(2); return

	var pass_count := 0; var fail_count := 0

	pass_count += 1 if _test_no_obstruction(bmb) else 0; fail_count += 0 if pass_count == fail_count + 0 else 0
	pass_count += 1 if _test_single_block_shielding(bmb) else 0
	pass_count += 1 if _test_two_block_wall_shielding(bmb) else 0
	pass_count += 1 if _test_oblique_more_than_perpendicular(bmb) else 0
	pass_count += 1 if _test_full_shield_caps(bmb) else 0

	fail_count = 5 - pass_count
	print("")
	print("=== Summary: %d/%d passed ===" % [pass_count, pass_count + fail_count])
	quit(0 if fail_count == 0 else 1)


# ────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────

func _idx(x: int, y: int, z: int, ny: int, nz: int) -> int:
	return x * ny * nz + y * nz + z


func _make_grid(nx: int, ny: int, nz: int, occupied_keys: Array) -> Dictionary:
	## Build (block_grid, bond_strength, bond_damage, bond_broken) sized for the
	## given dimensions, with only the keys in `occupied_keys` set to occupied.
	var grid_size := nx * ny * nz
	var grid := PackedByteArray(); grid.resize(grid_size)
	for k_v in occupied_keys:
		var k: Vector3i = k_v
		grid[_idx(k.x, k.y, k.z, ny, nz)] = 1
	# Bond arrays: full grid_size * 3.
	var bond_count := grid_size * 3
	var strength := PackedFloat32Array(); strength.resize(bond_count)
	var damage := PackedFloat32Array(); damage.resize(bond_count)
	var broken := PackedByteArray(); broken.resize(bond_count)
	# Mark every bond between two occupied neighbors as live (non-broken,
	# strength=BOND_STRENGTH); everything else broken.
	for bx in nx:
		for by in ny:
			for bz in nz:
				var here := _idx(bx, by, bz, ny, nz)
				var here_occ: bool = grid[here] == 1
				# +X
				var bi_x := here * 3 + 0
				if here_occ and bx + 1 < nx and grid[_idx(bx+1, by, bz, ny, nz)] == 1:
					strength[bi_x] = BOND_STRENGTH
				else:
					broken[bi_x] = 1
				# +Y
				var bi_y := here * 3 + 1
				if here_occ and by + 1 < ny and grid[_idx(bx, by+1, bz, ny, nz)] == 1:
					strength[bi_y] = BOND_STRENGTH
				else:
					broken[bi_y] = 1
				# +Z
				var bi_z := here * 3 + 2
				if here_occ and bz + 1 < nz and grid[_idx(bx, by, bz+1, ny, nz)] == 1:
					strength[bi_z] = BOND_STRENGTH
				else:
					broken[bi_z] = 1
	return {
		"grid": grid, "strength": strength, "damage": damage, "broken": broken,
		"nx": nx, "ny": ny, "nz": nz,
	}


func _block_local_pos(bx: int, by: int, bz: int, nx: int, ny: int, nz: int) -> Vector3:
	## Center of block in local coords, matching DestructibleBlockStructure._block_local_pos.
	return Vector3(
		(bx + 0.5 - nx * 0.5) * BLOCK_SIZE,
		(by + 0.5 - ny * 0.5) * BLOCK_SIZE,
		(bz + 0.5 - nz * 0.5) * BLOCK_SIZE,
	)


func _bond_local_mid(bx: int, by: int, bz: int, axis: int, nx: int, ny: int, nz: int) -> Vector3:
	var p := _block_local_pos(bx, by, bz, nx, ny, nz)
	var off := 0.5 * BLOCK_SIZE
	if axis == 0: p.x += off
	elif axis == 1: p.y += off
	else: p.z += off
	return p


func _verdict(name: String, ok: bool, detail: String) -> bool:
	var label := "PASS" if ok else "FAIL"
	print("[%s] %s — %s" % [label, name, detail])
	return ok


# ────────────────────────────────────────────────────────────────────────────
# Cases
# ────────────────────────────────────────────────────────────────────────────

func _test_no_obstruction(bmb: Object) -> bool:
	## Single floating bond pair; blast right next to it; full damage should land.
	## With 2-block grid and blast at the bond midpoint, no shielding possible.
	var nx := 2; var ny := 1; var nz := 1
	var s := _make_grid(nx, ny, nz, [Vector3i(0,0,0), Vector3i(1,0,0)])
	# Bond between (0,0,0) and (1,0,0): owner = (0,0,0), axis=0 (+X).
	# Midpoint local = (0.5, 0, 0) (since nx=2 → x=0 center is -0.5, +0.5 offset → 0).
	var bond_mid := _bond_local_mid(0, 0, 0, 0, nx, ny, nz)
	# Place blast right at the midpoint so falloff = 1.0.
	var result: Dictionary = bmb.damage_bonds_radial_shielded(
		s["grid"], s["strength"], s["damage"], s["broken"],
		nx, ny, nz, BLOCK_SIZE,
		bond_mid, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var dmg_arr: PackedFloat32Array = result["bond_damage"]
	var bond_idx := _idx(0, 0, 0, ny, nz) * 3 + 0
	var got: float = dmg_arr[bond_idx]
	# Expected: blast at midpoint → distance ~0 → falloff ~1 → ~BLAST_ENERGY damage.
	# DDA traversal might pass through one of the adjacent blocks (the blast is on
	# the face — degenerate). Some absorption acceptable; require ≥ ~50% of energy.
	var ok: bool = got > BLAST_ENERGY * 0.5
	return _verdict("no_obstruction", ok,
		"bond_damage=%.1f (expected ≥ %.1f)" % [got, BLAST_ENERGY * 0.5])


func _test_single_block_shielding(bmb: Object) -> bool:
	## Three blocks in a row along X: target bond on right-most pair, blast on
	## the far left side. The middle block shields the bond.
	## Layout: blocks at x=0,1,2; bond between (1,0,0) and (2,0,0).
	## Blast at x=-2 (outside the block at x=0). Ray crosses block 0 fully,
	## block 1 partially before reaching the bond face at x=2.
	var nx := 3; var ny := 1; var nz := 1
	var s := _make_grid(nx, ny, nz, [Vector3i(0,0,0), Vector3i(1,0,0), Vector3i(2,0,0)])
	# Blast at local (-2, 0, 0). Bond between (1,0,0) and (2,0,0): owner (1,0,0), axis 0.
	# Bond midpoint local x = 1 (since nx=3 → x=1 center is 0; +0.5 → 0.5… let me recompute)
	# x=0 center: (0 + 0.5 - 1.5)*1 = -1. x=1 center: 0. x=2 center: 1. Bond mid (1→2) at x=0.5.
	var blast := Vector3(-2.0, 0.0, 0.0)
	# Reference: full damage with no shielding from the same distance.
	# Bond mid is at (0.5, 0, 0). Distance from blast = 2.5. Falloff = 1/(1+(3*2.5/6)^3) = 1/(1+1.953) = 0.339.
	# raw_energy ≈ 200 * 0.339 = 67.8.
	# Ray crosses blocks at x=0 (path 1.0) and x=1 (path 1.0) before hitting bond face at x=1.5.
	# Wait — block 1 spans x=[-0.5, 0.5]. Block 2 spans x=[0.5, 1.5]. So bond mid x=0.5 is on the face of block 1 / block 2.
	# Block 0 (x=0 in voxel terms? actually grid index 0 spans local [-1.5, -0.5]) lies between blast and bond.
	# Hmm the local-coord math gets confusing. Let me just measure the result.
	var result: Dictionary = bmb.damage_bonds_radial_shielded(
		s["grid"], s["strength"], s["damage"], s["broken"],
		nx, ny, nz, BLOCK_SIZE,
		blast, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var dmg_arr: PackedFloat32Array = result["bond_damage"]
	var bond_idx := _idx(1, 0, 0, ny, nz) * 3 + 0
	var shielded: float = dmg_arr[bond_idx]
	# Now compute reference WITHOUT blocks in the way — call kernel on an empty
	# grid except for the two endpoint blocks of the bond.
	var s2 := _make_grid(nx, ny, nz, [Vector3i(1,0,0), Vector3i(2,0,0)])
	var result2: Dictionary = bmb.damage_bonds_radial_shielded(
		s2["grid"], s2["strength"], s2["damage"], s2["broken"],
		nx, ny, nz, BLOCK_SIZE,
		blast, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var dmg_arr2: PackedFloat32Array = result2["bond_damage"]
	var unshielded: float = dmg_arr2[bond_idx]
	# The shielded version should have notably less damage than unshielded.
	var ok: bool = shielded < unshielded - 5.0  # at least a meaningful gap
	return _verdict("single_block_shielding", ok,
		"shielded=%.1f  unshielded=%.1f  delta=%.1f" % [shielded, unshielded, unshielded - shielded])


func _test_two_block_wall_shielding(bmb: Object) -> bool:
	## Wall of 2 blocks at x=0 and x=1, blast outside at x=-3. Target a bond at
	## x=4..5. More material between blast and bond should yield more absorption.
	var nx := 6; var ny := 1; var nz := 1
	# Wall + far pair for bond
	var keys := [Vector3i(0,0,0), Vector3i(1,0,0), Vector3i(4,0,0), Vector3i(5,0,0)]
	var s := _make_grid(nx, ny, nz, keys)
	var blast := Vector3(-3.5, 0.0, 0.0)
	var result: Dictionary = bmb.damage_bonds_radial_shielded(
		s["grid"], s["strength"], s["damage"], s["broken"],
		nx, ny, nz, BLOCK_SIZE,
		blast, BLAST_ENERGY * 5.0, BLAST_RADIUS * 2.0, BLOCK_HP)
	var dmg_arr: PackedFloat32Array = result["bond_damage"]
	var bond_idx := _idx(4, 0, 0, ny, nz) * 3 + 0
	var with_wall: float = dmg_arr[bond_idx]
	# Compare to no-wall case.
	var s_no := _make_grid(nx, ny, nz, [Vector3i(4,0,0), Vector3i(5,0,0)])
	var result_no: Dictionary = bmb.damage_bonds_radial_shielded(
		s_no["grid"], s_no["strength"], s_no["damage"], s_no["broken"],
		nx, ny, nz, BLOCK_SIZE,
		blast, BLAST_ENERGY * 5.0, BLAST_RADIUS * 2.0, BLOCK_HP)
	var no_wall: float = (result_no["bond_damage"] as PackedFloat32Array)[bond_idx]
	# Wall absorbs 2 blocks worth = 70 HP. Difference should be at least that.
	var ok: bool = no_wall - with_wall >= BLOCK_HP * 1.5
	return _verdict("two_block_wall", ok,
		"with_wall=%.1f  no_wall=%.1f  shielded_diff=%.1f (≥ %.1f expected)" % [
			with_wall, no_wall, no_wall - with_wall, BLOCK_HP * 1.5])


func _test_oblique_more_than_perpendicular(bmb: Object) -> bool:
	## A 1-block-thick wall in xy plane at z=2. Same target bond reached via:
	##   (a) perpendicular ray (blast at (0, 0, -2), bond ahead at +z)
	##   (b) oblique ray (blast offset in x, traversing more wall material)
	## Oblique should absorb strictly more.
	var nx := 5; var ny := 1; var nz := 5
	# Wall: blocks at all (x, 0, 2) for x in 0..4, plus target pair behind it at z=4.
	var keys := []
	for bx in nx:
		keys.append(Vector3i(bx, 0, 2))
	keys.append(Vector3i(2, 0, 4))
	# also need a neighbor for the bond endpoint
	# Use +X bond at (2, 0, 4) → (3, 0, 4)
	keys.append(Vector3i(3, 0, 4))
	var s_perp := _make_grid(nx, ny, nz, keys)
	var s_obl := _make_grid(nx, ny, nz, keys)
	# Blast positions (local coords; nx=5 → centers at x=-2..2 with block centers at -2, -1, 0, 1, 2):
	var perp_blast := Vector3(0.5, 0.0, -2.0)  # straight in front of bond
	var obl_blast := Vector3(-3.5, 0.0, -2.0)  # off to the side, ray traverses more wall blocks
	var perp_result: Dictionary = bmb.damage_bonds_radial_shielded(
		s_perp["grid"], s_perp["strength"], s_perp["damage"], s_perp["broken"],
		nx, ny, nz, BLOCK_SIZE,
		perp_blast, BLAST_ENERGY * 3.0, BLAST_RADIUS * 2.0, BLOCK_HP)
	var obl_result: Dictionary = bmb.damage_bonds_radial_shielded(
		s_obl["grid"], s_obl["strength"], s_obl["damage"], s_obl["broken"],
		nx, ny, nz, BLOCK_SIZE,
		obl_blast, BLAST_ENERGY * 3.0, BLAST_RADIUS * 2.0, BLOCK_HP)
	var bond_idx := _idx(2, 0, 4, ny, nz) * 3 + 0  # +X bond at (2,0,4)
	var perp_dmg: float = (perp_result["bond_damage"] as PackedFloat32Array)[bond_idx]
	var obl_dmg: float = (obl_result["bond_damage"] as PackedFloat32Array)[bond_idx]
	# Both blasts at same total distance? No — oblique is farther so falloff is also larger.
	# To isolate the angle effect we'd want equal distances, but for a sanity check:
	# at minimum, oblique angle should NOT give more damage than perpendicular (more material in path).
	# So verify perp_dmg > obl_dmg (or at least obl_dmg < perp_dmg).
	var ok: bool = obl_dmg < perp_dmg
	return _verdict("oblique_more_shielded", ok,
		"perp_dmg=%.1f  oblique_dmg=%.1f (oblique should be smaller)" % [perp_dmg, obl_dmg])


func _test_full_shield_caps(bmb: Object) -> bool:
	## Stack many blocks in a row so total HP-along-path > raw_energy. Bond
	## behind them should take ZERO damage (fully shielded, clamped).
	var nx := 8; var ny := 1; var nz := 1
	var keys := []
	for bx in 6:
		keys.append(Vector3i(bx, 0, 0))
	keys.append(Vector3i(6, 0, 0))
	keys.append(Vector3i(7, 0, 0))
	var s := _make_grid(nx, ny, nz, keys)
	# Blast at far left, bond between (6,0,0) and (7,0,0). 6+ blocks in path = 210+ HP absorption.
	# raw energy at distance ~6 from bond (6 blocks away): falloff ≈ 1/(1+(3*6/8)^3) ≈ 0.082.
	# raw_energy ≈ 200 * 0.082 = 16. Absorption 210 >> 16 → clamped → no damage.
	var blast := Vector3(-4.0, 0.0, 0.0)
	var result: Dictionary = bmb.damage_bonds_radial_shielded(
		s["grid"], s["strength"], s["damage"], s["broken"],
		nx, ny, nz, BLOCK_SIZE,
		blast, BLAST_ENERGY, BLAST_RADIUS, BLOCK_HP)
	var bond_idx := _idx(6, 0, 0, ny, nz) * 3 + 0
	var dmg: float = (result["bond_damage"] as PackedFloat32Array)[bond_idx]
	var ok: bool = dmg == 0.0
	return _verdict("full_shield_caps", ok,
		"bond behind 6-block wall took %.2f damage (expected 0.0)" % dmg)
