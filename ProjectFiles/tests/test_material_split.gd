extends SceneTree

## Unit test for DestructibleBlockStructure._split_component_by_material:
## detached components must cleave into connected single-material pieces so
## no cluster ever repaints minority blocks (the color-transmute bug).
## Deferred to first frame so autoload singletons exist before script load.
##
## Run via:
##   "Godot_v4.6-stable_win64 hi dad new.exe" --headless --script res://tests/test_material_split.gd


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _make_structure(nx: int, ny: int, nz: int, blocks: Array,
		foundation: Array) -> Node3D:
	## Bare instance (never enters tree — _ready not called). Populate just
	## the grids the splitter reads.
	var script: GDScript = load("res://world/destructible_block_structure.gd")
	var s: Node3D = script.new()
	s._num_x = nx
	s._num_y = ny
	s._num_z = nz
	s._block_grid.resize(nx * ny * nz)
	s._foundation_grid.resize(nx * ny * nz)
	for b: Vector3i in blocks:
		s._block_grid[s._grid_idx(b.x, b.y, b.z)] = 1
	for f: Vector3i in foundation:
		s._foundation_grid[s._grid_idx(f.x, f.y, f.z)] = 1
	return s


func _keys(arr: Array) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for v: Vector3i in arr:
		out.append(v)
	return out


func _run() -> void:
	print("=== Material split tests ===")
	var passed := 0
	var total := 0

	# 1. Mixed component: stone row y=0 under wall rows y=1..2 → exactly two
	#    parts, each pure, block counts preserved.
	total += 1
	var blocks: Array = []
	var foundation: Array = []
	for x in 4:
		foundation.append(Vector3i(x, 0, 0))
		for y in 3:
			blocks.append(Vector3i(x, y, 0))
	var s := _make_structure(4, 3, 1, blocks, foundation)
	var parts: Array = s._split_component_by_material(_keys(blocks))
	var f_parts := parts.filter(func(p): return p["is_foundation"])
	var w_parts := parts.filter(func(p): return not p["is_foundation"])
	var ok := parts.size() == 2 and f_parts.size() == 1 and w_parts.size() == 1 \
		and (f_parts[0]["keys"] as Array).size() == 4 \
		and (w_parts[0]["keys"] as Array).size() == 8
	print("[%s] mixed_splits_into_two_pure_parts (parts=%d)" % ["PASS" if ok else "FAIL", parts.size()])
	passed += 1 if ok else 0
	s.free()

	# 2. Disconnection through the other material: two stone feet joined only
	#    via the wall slab above → foundation side yields TWO subsets.
	total += 1
	blocks = []
	foundation = [Vector3i(0, 0, 0), Vector3i(2, 0, 0)]
	blocks.append_array(foundation)
	for x in 3:
		blocks.append(Vector3i(x, 1, 0))
	s = _make_structure(3, 2, 1, blocks, foundation)
	parts = s._split_component_by_material(_keys(blocks))
	f_parts = parts.filter(func(p): return p["is_foundation"])
	w_parts = parts.filter(func(p): return not p["is_foundation"])
	ok = f_parts.size() == 2 and w_parts.size() == 1 \
		and (f_parts[0]["keys"] as Array).size() == 1 \
		and (f_parts[1]["keys"] as Array).size() == 1 \
		and (w_parts[0]["keys"] as Array).size() == 3
	print("[%s] disconnected_feet_split (f_parts=%d w_parts=%d)" % ["PASS" if ok else "FAIL", f_parts.size(), w_parts.size()])
	passed += 1 if ok else 0
	s.free()

	# 3. Pure wall component → single part, untouched (fast path).
	total += 1
	blocks = []
	for x in 5:
		blocks.append(Vector3i(x, 1, 0))
	s = _make_structure(5, 2, 1, blocks, [Vector3i(0, 0, 0)])
	parts = s._split_component_by_material(_keys(blocks))
	ok = parts.size() == 1 and not parts[0]["is_foundation"] \
		and (parts[0]["keys"] as Array).size() == 5
	print("[%s] pure_wall_single_part" % ["PASS" if ok else "FAIL"])
	passed += 1 if ok else 0
	s.free()

	# 4. No foundation grid at all (never expanded) → whole component, wall.
	total += 1
	var script: GDScript = load("res://world/destructible_block_structure.gd")
	var bare: Node3D = script.new()
	bare._num_x = 2
	bare._num_y = 1
	bare._num_z = 1
	bare._block_grid.resize(2)
	bare._block_grid.fill(1)
	# _foundation_grid left empty (size mismatch → early return)
	parts = bare._split_component_by_material(_keys([Vector3i(0, 0, 0), Vector3i(1, 0, 0)]))
	ok = parts.size() == 1 and not parts[0]["is_foundation"]
	print("[%s] no_foundation_grid_passthrough" % ["PASS" if ok else "FAIL"])
	passed += 1 if ok else 0
	bare.free()

	print("=== Summary: %d/%d passed ===" % [passed, total])
	quit(0 if passed == total else 1)
