extends SceneTree

## Physics validation for the gravity stress solver (solve_gravity_stress).
## Every assertion here has an ANALYTIC target from statics / beam theory —
## see GRAVITY_STRESS_PLAN.md. Highlights:
##   - A cut through a cantilever root must carry exactly M = n²/2 (W·h):
##     static equilibrium of the free body, not a model choice. The solver's
##     recovered utilization must match to CG tolerance.
##   - Critical overhang length follows n_crit = √(T/3) — the L² bending law.
##   - A 2-thick beam stands where a 1-thick fails (section depth² strength).
##   - Bond damage scales capacity: κ = 1 − damage/strength, so a blast-
##     weakened root drops and gravity finishes the job.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_gravity_stress.gd

const HUGE_LIMIT := 1.0e6


func _init() -> void:
	print("=== Gravity stress solver tests ===")
	print("")

	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: BlockMeshBuilder class not found. Engine build is missing the module.")
		quit(2)
		return
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if not bmb.has_method("solve_gravity_stress"):
		print("FATAL: solve_gravity_stress is missing — engine needs rebuild.")
		quit(2)
		return

	var pass_count := 0
	var total := 0

	var tests: Array = [
		["matvec_symmetry", func() -> bool: return _test_symmetry(bmb)],
		["cantilever_root_moment_exact", func() -> bool: return _test_root_moment(bmb)],
		["cantilever_critical_length", func() -> bool: return _test_critical_length(bmb)],
		["cantilever_breaks_at_root_only", func() -> bool: return _test_breaks_at_root(bmb)],
		["two_thick_beam_stronger", func() -> bool: return _test_two_thick(bmb)],
		["pillar_compression_crush", func() -> bool: return _test_pillar(bmb)],
		["table_shares_load_evenly", func() -> bool: return _test_table(bmb)],
		["undamaged_bad_support_collapses", func() -> bool: return _test_undamaged_spawn(bmb)],
		["damage_weakens_capacity", func() -> bool: return _test_damage_coupling(bmb)],
		["stable_solve_idempotent", func() -> bool: return _test_idempotent(bmb)],
	]
	for t: Array in tests:
		total += 1
		var ok: bool = t[1].call()
		print("[%s] %s" % ["PASS" if ok else "FAIL", t[0]])
		pass_count += 1 if ok else 0

	print("")
	print("=== Summary: %d/%d passed ===" % [pass_count, total])
	quit(0 if pass_count == total else 1)


# ────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────

func _grid_idx(x: int, y: int, z: int, ny: int, nz: int) -> int:
	return x * ny * nz + y * nz + z


## Build grid/mask/bond arrays for a block list. Anchors = blocks whose
## bottom face glues to terrain. Bond strength 100 (damage units) so damage
## fractions are easy to express.
func _make(nx: int, ny: int, nz: int, blocks: Array, anchors: Array,
		bmb: Object) -> Dictionary:
	var grid := PackedByteArray()
	grid.resize(nx * ny * nz)
	var mask := PackedByteArray()
	mask.resize(nx * ny * nz)
	for b: Vector3i in blocks:
		grid[_grid_idx(b.x, b.y, b.z, ny, nz)] = 1
	for a: Vector3i in anchors:
		mask[_grid_idx(a.x, a.y, a.z, ny, nz)] = 1
	var bonds: Dictionary = bmb.compute_bond_graph(grid, nx, ny, nz, 100.0)
	return {
		"grid": grid, "mask": mask,
		"strength": bonds["bond_strength"],
		"damage": bonds["bond_damage"],
		"broken": bonds["bond_broken"],
		"nx": nx, "ny": ny, "nz": nz,
	}


func _solve(bmb: Object, s: Dictionary, params: Dictionary) -> Dictionary:
	return bmb.solve_gravity_stress(
		s["grid"], s["mask"],
		s["strength"], s["damage"], s["broken"],
		PackedFloat32Array(), PackedFloat32Array(), PackedByteArray(),
		s["nx"], s["ny"], s["nz"],
		Vector3(0, -1, 0), params)


## Wall block at x=0 (anchored), n overhang blocks along +X. 1×1 beam.
func _cantilever(n: int, bmb: Object) -> Dictionary:
	var blocks: Array = []
	for x in n + 1:
		blocks.append(Vector3i(x, 0, 0))
	return _make(n + 1, 1, 1, blocks, [Vector3i(0, 0, 0)], bmb)


# ────────────────────────────────────────────────────────────────────────────
# Tests
# ────────────────────────────────────────────────────────────────────────────

func _test_symmetry(bmb: Object) -> bool:
	## L-shaped structure exercises all 3 bond axes + anchors. A sign error
	## in the matvec breaks K-symmetry, which silently wrecks CG.
	var blocks: Array = []
	for x in 4: blocks.append(Vector3i(x, 0, 0))
	for y in range(1, 4): blocks.append(Vector3i(0, y, 0))
	for z in range(1, 3): blocks.append(Vector3i(0, 3, z))
	var s := _make(4, 4, 3, blocks, [Vector3i(0, 0, 0), Vector3i(1, 0, 0)], bmb)
	var res := _solve(bmb, s, {
		"tension": HUGE_LIMIT, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"check_symmetry": true,
	})
	var err: float = res.get("symmetry_error", 1.0)
	if err > 1e-9:
		print("    symmetry_error=%s (want < 1e-9)" % str(err))
		return false
	if not res["converged"]:
		print("    CG did not converge")
		return false
	return true


func _test_root_moment(bmb: Object) -> bool:
	## Static equilibrium: the root bond of an n=4 overhang carries EXACTLY
	## m_b = n²/2 = 8 W·h (free-body cut). With shear/compression/anchors
	## suppressed, max utilization = 6·m_b/T → recover m_b and compare.
	var n := 4
	var s := _cantilever(n, bmb)
	var T := 1000.0
	var res := _solve(bmb, s, {
		"tension": T, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	})
	if not res["converged"]:
		print("    CG did not converge")
		return false
	if int(res["broke_bonds"]) != 0:
		print("    unexpected breaks: %d" % int(res["broke_bonds"]))
		return false
	var m_b: float = float(res["max_utilization"]) * T / 6.0
	var expected := n * n / 2.0
	var rel := absf(m_b - expected) / expected
	print("    root moment: solver=%.4f analytic=%.1f rel_err=%.4f" % [m_b, expected, rel])
	return rel < 0.02


func _test_critical_length(bmb: Object) -> bool:
	## Bending failure follows 3n² > T → n_crit = √(T/3). T=50 → n_crit=4.08:
	## n=4 stands (U=0.96), n=5 falls (U=1.5). The L² law is the signature of
	## correct cantilever physics — force-only models scale linearly and get
	## this wrong.
	var params := {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	}
	var res4 := _solve(bmb, _cantilever(4, bmb), params)
	var res5 := _solve(bmb, _cantilever(5, bmb), params)
	var u4 := float(res4["max_utilization"])
	var u5 := float(res5["max_utilization"])
	print("    n=4: U=%.3f broke=%d | n=5: U=%.3f broke=%d" % [
		u4, int(res4["broke_bonds"]), u5, int(res5["broke_bonds"])])
	if int(res4["broke_bonds"]) != 0 or absf(u4 - 0.96) > 0.03:
		return false
	if int(res5["broke_bonds"]) < 1:
		return false
	return true


func _test_breaks_at_root(bmb: Object) -> bool:
	## The n=5 failure must crack exactly the ROOT bond (moment n²/2=12.5,
	## U=1.5); the bond one block out carries 4²/2=8 (U=0.96) and survives.
	## After the root breaks, the overhang is unanchored and detaches as one
	## 5-block component via the existing connectivity check — full pipeline.
	var s := _cantilever(5, bmb)
	var res := _solve(bmb, s, {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	})
	if int(res["broke_bonds"]) != 1:
		print("    broke %d bonds (want exactly 1: the root)" % int(res["broke_bonds"]))
		return false
	var new_broken: PackedByteArray = res["bond_broken"]
	var root_bi := _grid_idx(0, 0, 0, 1, 1) * 3 + 0  # wall block's +X bond
	if new_broken[root_bi] != 1:
		print("    root bond not broken")
		return false
	var comps: Array = bmb.calc_bond_connectivity_components(
		s["grid"], s["mask"], new_broken, s["nx"], s["ny"], s["nz"], 6)
	if comps.size() != 1 or comps[0].size() != 5:
		print("    connectivity: %d components (want 1 with 5 blocks)" % comps.size())
		return false
	return true


func _clamped_beam(n: int, thick: int, bmb: Object) -> Dictionary:
	## Wall column at x=0 with EVERY wall block anchored (rigid clamp — beam
	## theory's fixed end), beam x=1..n, `thick` blocks tall.
	var blocks: Array = []
	var anchors: Array = []
	for y in thick:
		blocks.append(Vector3i(0, y, 0))
		anchors.append(Vector3i(0, y, 0))
		for x in range(1, n + 1):
			blocks.append(Vector3i(x, y, 0))
	return _make(n + 1, thick, 1, blocks, anchors, bmb)


func _test_two_thick(bmb: Object) -> bool:
	## Section strength scales with depth² (composite Z = t³·h/6). Measured:
	## 2-thick n=5 max stress ratio vs 1-thick = 0.455 ≈ theory 0.5 despite
	## carrying 2× the weight. At T=50 with a rigid clamp: 1-thick n=5 falls
	## (U=1.5), 2-thick n=5 stands (U≈0.68). An earlier variant with a single-
	## anchor wall failed through the WALL bond instead — also real physics
	## (weakest cross-section governs), but it wasn't isolating section depth.
	var params := {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	}
	var probe := {
		"tension": 1000.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	}
	var u_thin := float(_solve(bmb, _clamped_beam(5, 1, bmb), probe)["max_utilization"])
	var u_thick := float(_solve(bmb, _clamped_beam(5, 2, bmb), probe)["max_utilization"])
	var res_thin := _solve(bmb, _clamped_beam(5, 1, bmb), params)
	var res_thick := _solve(bmb, _clamped_beam(5, 2, bmb), params)
	print("    n=5 T=50: 1-thick broke=%d | 2-thick broke=%d | stress ratio=%.3f (theory 0.5)" % [
		int(res_thin["broke_bonds"]), int(res_thick["broke_bonds"]),
		u_thick / u_thin])
	if int(res_thin["broke_bonds"]) < 1 or int(res_thick["broke_bonds"]) != 0:
		return false
	return u_thick < 0.6 * u_thin


func _test_pillar(bmb: Object) -> bool:
	## Pure compression: the anchor under an n-tall pillar carries n block-
	## weights. C=10: n=9 stands (U=0.9), n=12 rips the anchor and the whole
	## pillar detaches (topples as a rigid body).
	var params := {
		"tension": HUGE_LIMIT, "compression": 10.0, "shear": HUGE_LIMIT,
	}
	var blocks9: Array = []
	for y in 9: blocks9.append(Vector3i(0, y, 0))
	var s9 := _make(1, 9, 1, blocks9, [Vector3i(0, 0, 0)], bmb)
	var res9 := _solve(bmb, s9, params)

	var blocks12: Array = []
	for y in 12: blocks12.append(Vector3i(0, y, 0))
	var s12 := _make(1, 12, 1, blocks12, [Vector3i(0, 0, 0)], bmb)
	var res12 := _solve(bmb, s12, params)

	print("    n=9: U=%.3f anchors_broke=%d | n=12: anchors_broke=%d" % [
		float(res9["max_utilization"]), int(res9["broke_anchors"]),
		int(res12["broke_anchors"])])
	if int(res9["broke_anchors"]) != 0 or absf(float(res9["max_utilization"]) - 0.9) > 0.03:
		return false
	if int(res12["broke_anchors"]) != 1:
		return false
	# With the anchor gone every block must detach. The bottom BOND (carrying
	# 11 in compression, U=1.1) legitimately breaks in the same pass as the
	# anchor (U=1.2) — break-all-violators policy — so the pillar may leave in
	# 1 or 2 pieces; what matters is that all 12 blocks come down.
	var comps: Array = bmb.calc_bond_connectivity_components(
		s12["grid"], _mask_minus_broken_anchors(s12, res12), res12["bond_broken"],
		s12["nx"], s12["ny"], s12["nz"], 12)
	var detached := 0
	for c in comps:
		detached += (c as Array).size()
	return detached == 12


func _mask_minus_broken_anchors(s: Dictionary, res: Dictionary) -> PackedByteArray:
	## Mirror of the game's effective-ground-mask logic.
	var eff: PackedByteArray = (s["mask"] as PackedByteArray).duplicate()
	var ab: PackedByteArray = res["anchor_broken"]
	for i in eff.size():
		if ab[i] != 0:
			eff[i] = 0
	return eff


func _test_table(bmb: Object) -> bool:
	## 7-wide slab (weight 7) on two 2-tall end legs. By symmetry each
	## leg-top joint must carry EXACTLY half the slab: f_n = −3.5. Read the
	## worst element's recovered force directly via debug_pass_stats.
	## (The joint also carries a real frame moment — the slab's fixed-end
	## moment partially transfers down the legs — so utilization exceeds the
	## pure-compression estimate; the force check is the exact part.)
	var blocks: Array = []
	for x in 7: blocks.append(Vector3i(x, 2, 0))
	for y in 2:
		blocks.append(Vector3i(0, y, 0))
		blocks.append(Vector3i(6, y, 0))
	var anchors: Array = [Vector3i(0, 0, 0), Vector3i(6, 0, 0)]
	var res := _solve(bmb, _make(7, 3, 1, blocks, anchors, bmb), {
		"tension": HUGE_LIMIT, "compression": 20.0, "shear": HUGE_LIMIT,
		"debug_pass_stats": true,
	})
	if int(res["broke_anchors"]) != 0 or int(res["broke_bonds"]) != 0:
		print("    unexpected breaks")
		return false
	var stats: Array = res.get("pass_stats", [])
	if stats.is_empty():
		return false
	var ps: Dictionary = stats[0]
	var fn := float(ps["worst_fn"])
	print("    worst element fn=%.4f (analytic −3.5: half the slab weight)" % fn)
	return absf(fn + 3.5) < 0.05


func _test_undamaged_spawn(bmb: Object) -> bool:
	## The user requirement: a structure built with bad support collapses with
	## ZERO damage anywhere. Pristine bonds, pristine anchors — the solver
	## alone must find the instability. (Same physics as critical_length; this
	## asserts the no-damage-required property explicitly.)
	var s := _cantilever(6, bmb)
	for i in (s["damage"] as PackedFloat32Array).size():
		if s["damage"][i] != 0.0:
			return false  # sanity: truly undamaged
	var res := _solve(bmb, s, {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	})
	print("    pristine 6-overhang: broke=%d maxU=%.2f" % [
		int(res["broke_bonds"]), float(res["max_utilization"])])
	return int(res["broke_bonds"]) >= 1


func _test_damage_coupling(bmb: Object) -> bool:
	## κ coupling: a 3-overhang at T=50 is comfortable (U=0.54). 80% damage
	## on the root bond (κ=0.2) drops capacity 5× → U=2.7 → gravity finishes
	## what the blast started. No damage event "destroyed" anything directly.
	var params := {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	}
	var s := _cantilever(3, bmb)
	var pristine := _solve(bmb, s, params)
	if int(pristine["broke_bonds"]) != 0:
		print("    pristine 3-overhang broke (should stand, U=%.2f)" % float(pristine["max_utilization"]))
		return false
	var root_bi := _grid_idx(0, 0, 0, 1, 1) * 3 + 0
	var dmg: PackedFloat32Array = (s["damage"] as PackedFloat32Array).duplicate()
	dmg[root_bi] = 80.0  # 80% of strength(100) → κ = 0.2
	s["damage"] = dmg
	var damaged := _solve(bmb, s, params)
	print("    pristine U=%.3f | 80%%-damaged root: broke=%d" % [
		float(pristine["max_utilization"]), int(damaged["broke_bonds"])])
	return int(damaged["broke_bonds"]) >= 1


func _test_idempotent(bmb: Object) -> bool:
	## A stable structure must produce zero breaks on every solve, with an
	## identical utilization — no decay, no drift, no false positives.
	var params := {
		"tension": 50.0, "compression": HUGE_LIMIT, "shear": HUGE_LIMIT,
		"anchor_factor": HUGE_LIMIT,
	}
	var s := _cantilever(4, bmb)
	var r1 := _solve(bmb, s, params)
	var r2 := _solve(bmb, s, params)
	if int(r1["broke_bonds"]) != 0 or int(r2["broke_bonds"]) != 0:
		return false
	var du := absf(float(r1["max_utilization"]) - float(r2["max_utilization"]))
	return du < 1e-6 and bool(r1["converged"]) and bool(r2["converged"])
