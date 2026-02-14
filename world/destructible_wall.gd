extends Node3D

## Destructible wall built from a grid of individual blocks.
## Damage destroys only the blocks within the blast radius, leaving the rest
## standing. Each block that breaks spawns small debris cubes.
## For thick walls (multiple Z layers), front blocks absorb damage and
## shield the blocks behind them.
## Server-authoritative: only server tracks block health and spawns debris.
##
## GREEDY MESHING: blocks keep individual StaticBody3D for collision/damage,
## but the visual mesh is a single greedy-meshed surface. When blocks are
## destroyed the mesh rebuilds. This reduces draw calls from N_blocks to 1
## per wall (200 walls × ~100 blocks → 200 draw calls instead of 20,000).

## Wall durability tiers — assigned by seed_world when spawning.
enum WallTier { WOOD, STONE, METAL, REINFORCED }

const BLOCK_SIZE := 0.5            ## Each block is 0.5m — smaller = more dynamic holes
const DEBRIS_SIZE := 0.15          ## Tiny debris cubes
const DEBRIS_PER_BLOCK := 2        ## Debris cubes per destroyed block
const DEBRIS_IMPULSE := 3.5        ## Outward impulse on debris
const DEBRIS_LIFETIME := 5.0       ## Seconds before debris auto-deletes
const MAX_DEBRIS_TOTAL := 40       ## Cap total debris per explosion

## Tier data: { color, health_per_block }
const TIER_DATA := {
	WallTier.WOOD:       { "color": Color(0.55, 0.35, 0.15), "block_hp": 15.0 },
	WallTier.STONE:      { "color": Color(0.55, 0.55, 0.50), "block_hp": 35.0 },
	WallTier.METAL:      { "color": Color(0.45, 0.50, 0.55), "block_hp": 70.0 },
	WallTier.REINFORCED: { "color": Color(0.30, 0.30, 0.35), "block_hp": 140.0 },
}

@export var wall_tier: WallTier = WallTier.STONE
var wall_size: Vector3 = Vector3(10, 4, 1)

## Block grid: Dictionary[Vector3i -> { "body": StaticBody3D, "hp": float }]
## Grid coords (bx, by, bz) map to block positions within the wall.
var _blocks: Dictionary = {}
var _num_x: int = 0
var _num_y: int = 0
var _num_z: int = 0
var _block_hp: float = 35.0
var _wall_material: StandardMaterial3D = null

## Shared resources (created once, reused by all blocks)
var _block_shape: BoxShape3D = null
var _block_script: GDScript = preload("res://world/wall_block.gd")

## Greedy mesh — single MeshInstance3D for the entire wall
var _mesh_instance: MeshInstance3D = null
var _mesh_dirty: bool = false

func _ready() -> void:
	var tier_info: Dictionary = TIER_DATA[wall_tier]
	_block_hp = tier_info["block_hp"]

	# Create shared resources
	_block_shape = BoxShape3D.new()
	_block_shape.size = Vector3.ONE * BLOCK_SIZE

	_wall_material = StandardMaterial3D.new()
	_wall_material.albedo_color = tier_info["color"]

	# Calculate grid dimensions
	_num_x = maxi(int(wall_size.x / BLOCK_SIZE), 1)
	_num_y = maxi(int(wall_size.y / BLOCK_SIZE), 1)
	_num_z = maxi(int(wall_size.z / BLOCK_SIZE), 1)

	# Build block grid (collision only — no per-block meshes)
	for bx in _num_x:
		for by in _num_y:
			for bz in _num_z:
				_spawn_block(bx, by, bz)

	# Build single greedy-meshed visual
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _wall_material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(_mesh_instance)
	_rebuild_greedy_mesh()

	# Disable per-frame processing — only needed when _mesh_dirty is set
	set_process(false)


func _process(_delta: float) -> void:
	# Deferred mesh rebuild: blocks were destroyed, rebuild once then sleep
	if _mesh_dirty:
		_mesh_dirty = false
		_rebuild_greedy_mesh()
		set_process(false)


func _spawn_block(bx: int, by: int, bz: int) -> void:
	## Create a single block at grid position (bx, by, bz).
	## Block has collision only — no individual mesh (greedy mesh handles visuals).
	var block_body := StaticBody3D.new()
	block_body.set_script(_block_script)
	block_body.name = "Block_%d_%d_%d" % [bx, by, bz]
	block_body.grid_key = Vector3i(bx, by, bz)
	block_body.parent_wall = self

	# Position relative to wall center (local space)
	var local_offset := Vector3(
		(bx + 0.5 - _num_x * 0.5) * BLOCK_SIZE,
		(by + 0.5 - _num_y * 0.5) * BLOCK_SIZE,
		(bz + 0.5 - _num_z * 0.5) * BLOCK_SIZE
	)
	block_body.position = local_offset

	var col := CollisionShape3D.new()
	col.shape = _block_shape.duplicate()
	block_body.add_child(col)

	# No MeshInstance3D — greedy mesh handles all rendering
	add_child(block_body)

	_blocks[Vector3i(bx, by, bz)] = {
		"body": block_body,
		"hp": _block_hp,
	}


func take_damage(_amount: float, _attacker_id: int) -> void:
	## No-op: wall-level take_damage exists so explosion scans find us.
	## Actual damage goes through take_damage_at() (explosions) or
	## _damage_block() (hitscan bullets hitting individual blocks).
	pass


func _damage_block(key: Vector3i, amount: float, _attacker_id: int) -> void:
	## Called by wall_block.gd when a bullet hits a specific block.
	if not multiplayer.is_server():
		return
	if not _blocks.has(key):
		return

	var block_data: Dictionary = _blocks[key]
	var block_body: StaticBody3D = block_data["body"]
	if not is_instance_valid(block_body):
		_blocks.erase(key)
		return

	block_data["hp"] -= amount
	if block_data["hp"] <= 0.0:
		var block_pos: Vector3 = block_body.global_position
		_spawn_debris(block_pos, block_pos + Vector3(0, 0, 0.5), 1)
		block_body.queue_free()
		_blocks.erase(key)
		_mesh_dirty = true
		set_process(true)  # Wake up _process to rebuild mesh next frame
		_sync_block_destroyed.rpc(key)

		if _blocks.is_empty():
			queue_free()


@rpc("authority", "call_remote", "reliable")
func _sync_block_destroyed(key: Vector3i) -> void:
	## Client-side: remove a destroyed block and rebuild the mesh.
	if _blocks.has(key):
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if is_instance_valid(block_body):
			block_body.queue_free()
		_blocks.erase(key)
		_mesh_dirty = true
		set_process(true)


func take_damage_at(hit_pos: Vector3, amount: float, blast_radius: float, _attacker_id: int) -> void:
	## Damage blocks within blast_radius of hit_pos. Only blocks in range take damage.
	## Shielding uses flat HP absorption: each wall block or player between the
	## explosion and a target block absorbs damage equal to its current HP.
	if not multiplayer.is_server():
		return

	var space_state := get_world_3d().direct_space_state

	var debris_spawned := 0
	var destroyed_keys: Array[Vector3i] = []

	for key: Vector3i in _blocks:
		var block_data: Dictionary = _blocks[key]
		var block_body: StaticBody3D = block_data["body"]
		if not is_instance_valid(block_body):
			continue

		var block_world_pos: Vector3 = block_body.global_position
		var dist: float = hit_pos.distance_to(block_world_pos)

		if dist > blast_radius:
			continue

		# Base damage with distance falloff
		var falloff: float = clampf(1.0 - (dist / blast_radius), 0.0, 1.0)
		var dmg: float = amount * falloff

		# --- Flat HP shielding: raycast from explosion to this block ---
		# Sum the HP of everything between the explosion and this block
		if space_state and dist > 0.3:
			var absorbed: float = ExplosionHelper.calc_ray_shielding(
				space_state, hit_pos, block_world_pos, [block_body.get_rid()], block_body
			)
			dmg = maxf(dmg - absorbed, 0.0)

		if dmg < 0.5:
			continue

		block_data["hp"] -= dmg
		if block_data["hp"] <= 0.0:
			destroyed_keys.append(key)
			if debris_spawned < MAX_DEBRIS_TOTAL:
				var to_spawn := mini(DEBRIS_PER_BLOCK, MAX_DEBRIS_TOTAL - debris_spawned)
				_spawn_debris(block_world_pos, hit_pos, to_spawn)
				debris_spawned += to_spawn
			block_body.queue_free()

	# Clean up destroyed entries and sync to clients
	for key in destroyed_keys:
		_blocks.erase(key)
		_sync_block_destroyed.rpc(key)

	if destroyed_keys.size() > 0:
		_mesh_dirty = true
		set_process(true)

	# If all blocks gone, remove the wall node entirely
	if _blocks.is_empty():
		queue_free()


func _spawn_debris(block_pos: Vector3, blast_center: Vector3, count: int) -> void:
	## Spawn small debris cubes flying outward from a destroyed block.
	var debris_mesh := BoxMesh.new()
	debris_mesh.size = Vector3.ONE * DEBRIS_SIZE
	var debris_shape := BoxShape3D.new()
	debris_shape.size = Vector3.ONE * DEBRIS_SIZE

	var parent_node := get_parent()
	var outward := (block_pos - blast_center)
	if outward.length() < 0.1:
		outward = Vector3(randf_range(-1, 1), 1, randf_range(-1, 1))
	outward = outward.normalized()

	for i in count:
		var debris := RigidBody3D.new()
		debris.name = "WallDebris"
		debris.mass = 0.5  # Small stone/wood cube
		debris.collision_layer = 32  # Layer 6: wall debris (no self-collision)
		debris.collision_mask = 1    # World geometry only

		var col := CollisionShape3D.new()
		col.shape = debris_shape.duplicate()
		debris.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = debris_mesh
		mesh_inst.material_override = _wall_material
		debris.add_child(mesh_inst)

		parent_node.add_child(debris, true)
		debris.global_position = block_pos + Vector3(
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
			randf_range(-0.2, 0.2),
		)

		var scatter := Vector3(randf_range(-1, 1), randf_range(0, 1), randf_range(-1, 1)).normalized()
		var impulse_dir := (outward * 0.6 + scatter * 0.4).normalized()
		impulse_dir.y = maxf(impulse_dir.y, 0.2)
		debris.apply_central_impulse(impulse_dir * DEBRIS_IMPULSE + Vector3(0, 1.5, 0))
		debris.apply_torque_impulse(Vector3(
			randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)
		))

		# Auto-cleanup
		var timer := Timer.new()
		timer.wait_time = DEBRIS_LIFETIME + randf_range(0, 1.0)
		timer.one_shot = true
		timer.autostart = true
		timer.timeout.connect(debris.queue_free)
		debris.add_child(timer)


# ======================================================================
#  GREEDY MESHING — single draw call per wall
# ======================================================================
#
# For each of the 6 face directions, we iterate every block. If the block
# exists and has no neighbor in that direction, we emit a quad. For now we
# skip the greedy merge step (merging adjacent faces into larger quads) in
# favor of correctness — each exposed block face = 1 quad = 2 triangles.
# This is still a HUGE improvement: 1 MeshInstance per wall instead of
# 1 MeshInstance PER BLOCK. Draw calls go from ~20,000 to ~200.
#
# The greedy merge can be layered on top later once the basics are solid.

func _rebuild_greedy_mesh() -> void:
	if _mesh_instance == null:
		return

	if _blocks.is_empty():
		_mesh_instance.mesh = null
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var half_x := _num_x * BLOCK_SIZE * 0.5
	var half_y := _num_y * BLOCK_SIZE * 0.5
	var half_z := _num_z * BLOCK_SIZE * 0.5
	var bs := BLOCK_SIZE

	for key: Vector3i in _blocks:
		var bx: int = key.x
		var by: int = key.y
		var bz: int = key.z

		# Block center in local space (relative to wall origin)
		var cx: float = (bx + 0.5) * bs - half_x
		var cy: float = (by + 0.5) * bs - half_y
		var cz: float = (bz + 0.5) * bs - half_z
		var hs := bs * 0.5  # half-size

		# +X face
		if not _blocks.has(Vector3i(bx + 1, by, bz)):
			var n := Vector3(1, 0, 0)
			var x := cx + hs
			_add_quad(st, n,
				Vector3(x, cy - hs, cz - hs),
				Vector3(x, cy - hs, cz + hs),
				Vector3(x, cy + hs, cz + hs),
				Vector3(x, cy + hs, cz - hs))

		# -X face
		if not _blocks.has(Vector3i(bx - 1, by, bz)):
			var n := Vector3(-1, 0, 0)
			var x := cx - hs
			_add_quad(st, n,
				Vector3(x, cy - hs, cz + hs),
				Vector3(x, cy - hs, cz - hs),
				Vector3(x, cy + hs, cz - hs),
				Vector3(x, cy + hs, cz + hs))

		# +Y face (top)
		if not _blocks.has(Vector3i(bx, by + 1, bz)):
			var n := Vector3(0, 1, 0)
			var y := cy + hs
			_add_quad(st, n,
				Vector3(cx - hs, y, cz - hs),
				Vector3(cx + hs, y, cz - hs),
				Vector3(cx + hs, y, cz + hs),
				Vector3(cx - hs, y, cz + hs))

		# -Y face (bottom)
		if not _blocks.has(Vector3i(bx, by - 1, bz)):
			var n := Vector3(0, -1, 0)
			var y := cy - hs
			_add_quad(st, n,
				Vector3(cx - hs, y, cz + hs),
				Vector3(cx + hs, y, cz + hs),
				Vector3(cx + hs, y, cz - hs),
				Vector3(cx - hs, y, cz - hs))

		# +Z face
		if not _blocks.has(Vector3i(bx, by, bz + 1)):
			var n := Vector3(0, 0, 1)
			var z := cz + hs
			_add_quad(st, n,
				Vector3(cx + hs, cy - hs, z),
				Vector3(cx - hs, cy - hs, z),
				Vector3(cx - hs, cy + hs, z),
				Vector3(cx + hs, cy + hs, z))

		# -Z face
		if not _blocks.has(Vector3i(bx, by, bz - 1)):
			var n := Vector3(0, 0, -1)
			var z := cz - hs
			_add_quad(st, n,
				Vector3(cx - hs, cy - hs, z),
				Vector3(cx + hs, cy - hs, z),
				Vector3(cx + hs, cy + hs, z),
				Vector3(cx - hs, cy + hs, z))

	_mesh_instance.mesh = st.commit()


func _add_quad(st: SurfaceTool, normal: Vector3,
		p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	## Emit a quad as 2 triangles. Winding is CCW: p0→p1→p2, p0→p2→p3.
	## The caller is responsible for vertex order matching the outward normal.
	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 0))
	st.add_vertex(p1)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)

	st.set_normal(normal)
	st.set_uv(Vector2(0, 0))
	st.add_vertex(p0)
	st.set_normal(normal)
	st.set_uv(Vector2(1, 1))
	st.add_vertex(p2)
	st.set_normal(normal)
	st.set_uv(Vector2(0, 1))
	st.add_vertex(p3)
