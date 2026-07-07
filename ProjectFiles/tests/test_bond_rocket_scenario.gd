extends SceneTree

## End-to-end simulation of a rocket-launcher impact on a destructible wall.
## Replicates _init_bond_graph + damage_bonds_in_radius + _break_block_bonds in
## plain GDScript, then runs the C++ connectivity kernel — exactly the path
## DestructibleBlockStructure takes during gameplay.
##
## Numbers match the live game:
##   block_hp                      = 35
##   bond_strength_factor          = 1.5  → bond_strength = 52.5
##   bond_damage_explosion_factor  = 1.0
##   rocket structure_damage       = 350
##   EXPLOSION_RADIUS              = 8.0
##   BLOCK_SIZE                    = 1.0  (assumed; falloff is the same shape regardless)
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_bond_rocket_scenario.gd

const BLOCK_HP := 35.0
const BOND_STRENGTH_FACTOR := 4.0
const BOND_DMG_FACTOR := 0.5
const ROCKET_DAMAGE := 350.0
const ROCKET_RADIUS := 8.0
const BLOCK_SIZE := 1.0


func _init() -> void:
	print("=== Rocket scenario: bond graph end-to-end ===")
	print("")

	if not ClassDB.class_exists(&"BlockMeshBuilder"):
		print("FATAL: engine missing BlockMeshBuilder.")
		quit(2); return
	var bmb: Object = ClassDB.instantiate(&"BlockMeshBuilder")
	if not bmb.has_method("calc_bond_connectivity_components"):
		print("FATAL: engine missing calc_bond_connectivity_components.")
		quit(2); return

	# A 12-wide, 8-tall, 1-deep wall (96 blocks). Plenty of mass to see
	# meaningful detachment if it's working.
	_run_scenario(bmb, "wall_center_blast",
		_make_wall(12, 8, 1), Vector3(6, 4, 0))

	# Same wall, blast at the foundation — should clearly detach the upper
	# half (entire wall above the destroyed core in fact).
	_run_scenario(bmb, "wall_foundation_blast",
		_make_wall(12, 8, 1), Vector3(6, 0, 0))

	# Tall narrow tower — foundation hit should detach the rest.
	_run_scenario(bmb, "tower_foundation_blast",
		_make_wall(2, 12, 2), Vector3(1, 0, 1))


# ────────────────────────────────────────────────────────────────────────────

func _make_wall(nx: int, ny: int, nz: int) -> Dictionary:
	var grid := PackedByteArray(); grid.resize(nx * ny * nz)
	for i in grid.size(): grid[i] = 1
	var ground := PackedByteArray(); ground.resize(nx * ny * nz)
	for bx in nx:
		for bz in nz:
			ground[_idx(bx, 0, bz, ny, nz)] = 1
	return { "grid": grid, "ground": ground, "nx": nx, "ny": ny, "nz": nz, "total": nx*ny*nz }


func _idx(x: int, y: int, z: int, ny: int, nz: int) -> int:
	return x * ny * nz + y * nz + z


func _block_world_pos(x: int, y: int, z: int, nx: int, ny: int, nz: int) -> Vector3:
	## Center of block in world coords, mirroring _block_local_pos at identity transform.
	return Vector3(
		(x - nx * 0.5 + 0.5) * BLOCK_SIZE,
		(y - ny * 0.5 + 0.5) * BLOCK_SIZE,
		(z - nz * 0.5 + 0.5) * BLOCK_SIZE,
	)


func _bond_midpoint(x: int, y: int, z: int, axis: int, nx: int, ny: int, nz: int) -> Vector3:
	var p := _block_world_pos(x, y, z, nx, ny, nz)
	var off := 0.5 * BLOCK_SIZE
	if axis == 0: p.x += off
	elif axis == 1: p.y += off
	else: p.z += off
	return p


func _init_bonds(grid: PackedByteArray, nx: int, ny: int, nz: int) -> Dictionary:
	## Returns { strength, damage, broken } sized grid_size * 3.
	var n := nx * ny * nz * 3
	var strength := PackedFloat32Array(); strength.resize(n)
	var damage := PackedFloat32Array(); damage.resize(n)
	var broken := PackedByteArray(); broken.resize(n)
	var s := BLOCK_HP * BOND_STRENGTH_FACTOR
	var live := 0
	for bx in nx:
		for by in ny:
			for bz in nz:
				var here := _idx(bx, by, bz, ny, nz)
				if grid[here] == 0:
					broken[here*3+0] = 1; broken[here*3+1] = 1; broken[here*3+2] = 1
					continue
				# +X
				if bx + 1 < nx and grid[_idx(bx+1, by, bz, ny, nz)] == 1:
					strength[here*3+0] = s; live += 1
				else: broken[here*3+0] = 1
				# +Y
				if by + 1 < ny and grid[_idx(bx, by+1, bz, ny, nz)] == 1:
					strength[here*3+1] = s; live += 1
				else: broken[here*3+1] = 1
				# +Z
				if bz + 1 < nz and grid[_idx(bx, by, bz+1, ny, nz)] == 1:
					strength[here*3+2] = s; live += 1
				else: broken[here*3+2] = 1
	return { "strength": strength, "damage": damage, "broken": broken, "live": live }


func _apply_radial_damage(bonds: Dictionary, grid: PackedByteArray,
		hit: Vector3, energy: float, radius: float,
		nx: int, ny: int, nz: int) -> Dictionary:
	var strength: PackedFloat32Array = bonds["strength"]
	var damage: PackedFloat32Array = bonds["damage"]
	var broken: PackedByteArray = bonds["broken"]
	var inv_r := 1.0 / radius
	var r2 := radius * radius
	var damaged := 0; var newly_broken := 0
	for bx in nx:
		for by in ny:
			for bz in nz:
				var here := _idx(bx, by, bz, ny, nz)
				if grid[here] == 0: continue
				for axis in 3:
					var bi := here * 3 + axis
					if broken[bi] != 0: continue
					var mid := _bond_midpoint(bx, by, bz, axis, nx, ny, nz)
					var d2 := mid.distance_squared_to(hit)
					if d2 >= r2: continue
					var norm_dist: float = sqrt(d2) * inv_r
					var falloff: float = 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
					damage[bi] += energy * falloff
					damaged += 1
					if damage[bi] >= strength[bi]:
						broken[bi] = 1
						newly_broken += 1
	return { "damaged": damaged, "broken": newly_broken }


func _destroy_blocks_near(grid: PackedByteArray, bonds: Dictionary, hit: Vector3,
		nx: int, ny: int, nz: int) -> int:
	## Mimic explosion block-kill: cubic falloff, 35 hp, 350 damage. Block dies
	## if final damage >= block_hp.
	var broken: PackedByteArray = bonds["broken"]
	var killed := 0
	for bx in nx:
		for by in ny:
			for bz in nz:
				var here := _idx(bx, by, bz, ny, nz)
				if grid[here] == 0: continue
				var p := _block_world_pos(bx, by, bz, nx, ny, nz)
				var d := p.distance_to(hit)
				if d > ROCKET_RADIUS: continue
				var nd := d / ROCKET_RADIUS
				var falloff: float = 1.0 / (1.0 + (nd * 3.0) ** 3)
				var final_dmg: float = ROCKET_DAMAGE * falloff
				if final_dmg < BLOCK_HP: continue
				# Destroy block, mark its 6 bonds broken.
				grid[here] = 0
				killed += 1
				broken[here*3+0] = 1; broken[here*3+1] = 1; broken[here*3+2] = 1
				if bx > 0: broken[_idx(bx-1, by, bz, ny, nz) * 3 + 0] = 1
				if by > 0: broken[_idx(bx, by-1, bz, ny, nz) * 3 + 1] = 1
				if bz > 0: broken[_idx(bx, by, bz-1, ny, nz) * 3 + 2] = 1
	return killed


func _run_scenario(bmb: Object, name: String, struct: Dictionary, hit: Vector3) -> void:
	var nx: int = struct["nx"]; var ny: int = struct["ny"]; var nz: int = struct["nz"]
	var grid: PackedByteArray = (struct["grid"] as PackedByteArray).duplicate()
	var ground: PackedByteArray = struct["ground"]
	var bonds := _init_bonds(grid, nx, ny, nz)
	var live_bonds: int = bonds["live"]

	var killed := _destroy_blocks_near(grid, bonds, hit, nx, ny, nz)
	var dmg_summary := _apply_radial_damage(bonds, grid, hit,
		ROCKET_DAMAGE * BOND_DMG_FACTOR, ROCKET_RADIUS, nx, ny, nz)

	var total_after: int = struct["total"] - killed
	var components: Array = bmb.calc_bond_connectivity_components(
		grid, ground, bonds["broken"], nx, ny, nz, total_after)

	var sizes: Array[int] = []
	for c in components: sizes.append(c.size())
	sizes.sort()

	# Count broken bonds (excluding pre-broken boundary slots).
	var broken_arr: PackedByteArray = bonds["broken"]
	var broken_total := 0
	for v in broken_arr:
		if v == 1: broken_total += 1

	print("[%s] grid=%dx%dx%d hit=%s  live_bonds=%d  blocks_killed=%d  bonds_damaged=%d  bonds_broken_total=%d  components=%s" % [
		name, nx, ny, nz, str(hit),
		live_bonds, killed, dmg_summary["damaged"], broken_total, str(sizes),
	])
