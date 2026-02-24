class_name ExplosionHelper

## Centralized explosion damage system with flat-HP shielding and multi-point
## raycast cover checks.
##
## Objects between the explosion and a target absorb damage as a flat amount
## equal to their HP:
##   - Wall blocks absorb up to their current block HP
##   - Players absorb up to their current health
##
## Player targets use 5 sample rays (center + 4 edges) for partial cover.
## Wall block targets use the shielding built into destructible_wall.gd.

## Player capsule geometry for multi-point sampling
const PLAYER_CENTER_Y := 0.9
const PLAYER_TOP_Y := 1.7
const PLAYER_BOTTOM_Y := 0.1
const PLAYER_SIDE_OFFSET := 0.35  ## Half-width at capsule center height

## Max hits per shielding raycast (controls intersect_ray_all max_results)
const MAX_RAY_ITERATIONS := 8

## Debug ray auto-delete time (seconds)
const DEBUG_RAY_LIFETIME := 4.0

## Persistent sphere shape for physics queries. With threaded physics,
## PhysicsServer3D.shape_set_data() is deferred — a shape created + configured
## in the same frame reads radius=0. By reusing a persistent shape, the radius
## from the previous frame's set_data has already been flushed by Jolt.
static var _query_sphere := SphereShape3D.new()


# ======================================================================
#  Main entry point — replaces inline explosion code in rocket + kamikaze
# ======================================================================

static func do_explosion(
	world: World3D,
	explosion_pos: Vector3,
	player_damage: float,
	structure_damage: float,
	radius: float,
	attacker_id: int,
	exclude_body: Node = null,
) -> void:
	## Deal shielded explosion damage to all players and walls in radius.
	## player_damage: base damage dealt to players (before falloff/shielding).
	## structure_damage: base damage dealt to structures/blocks/physics objects.
	## exclude_body: the rocket RigidBody3D or kamikaze player to skip.
	var space_state := world.direct_space_state
	if space_state == null:
		return

	var already_damaged: Array[Node] = []
	var exclude_rid: RID = exclude_body.get_rid() if exclude_body else RID()
	var exclude_rids: Array[RID] = []
	if exclude_rid.is_valid():
		exclude_rids.append(exclude_rid)

	# ------------------------------------------------------------------
	#  Pass 1: Physics sphere query (catches players + rigid bodies)
	# ------------------------------------------------------------------
	var query := PhysicsShapeQueryParameters3D.new()
	# Reuse persistent sphere shape — see _query_sphere comment above.
	# The radius set here is deferred (threaded physics), so on the FIRST
	# explosion call the shape uses its default radius (0.5m). Pass 2's
	# scene scan catches anything missed. All subsequent calls use the
	# correct radius from the previous frame's flush.
	_query_sphere.radius = radius
	query.shape = _query_sphere
	query.transform = Transform3D(Basis(), explosion_pos)
	query.collision_mask = 1 | 2 | 4 | 128 | 256 | 1024  # World(1) + items(2) + bubbles(4) + players(128/256) + blocks(1024)
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var results := space_state.intersect_shape(query, 64)

	for result in results:
		var collider: Node = result["collider"]
		if collider == exclude_body:
			continue
		var target := _find_damageable(collider)
		if target == null or target in already_damaged:
			continue

		if target.has_method("take_damage_at"):
			# Wall: let take_damage_at handle per-block shielding internally
			target.take_damage_at(explosion_pos, structure_damage, radius, attacker_id, exclude_rids)
			already_damaged.append(target)
		elif target is Player and target.has_method("take_damage"):
			# Player: multi-point raycast with flat shielding
			var dmg := _calc_player_explosion_damage(
				space_state, explosion_pos, player_damage, radius, target, exclude_rid
			)
			if dmg > 0.5:
				target.take_damage(dmg, attacker_id)
			already_damaged.append(target)
		elif target is RigidBody3D and target.has_method("take_damage"):
			# Destructible physics object (tower chunks, etc.) — cubic falloff
			var dist := explosion_pos.distance_to(target.global_position)
			if dist <= radius:
				var norm_dist := dist / radius
				var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
				var dmg := structure_damage * falloff
				if dmg > 0.5:
					target.take_damage(dmg, attacker_id)
			already_damaged.append(target)

	# --- Pass 2: Direct scene scan (safety net if sphere query misses targets) ---
	# Jolt's intersect_shape with server-created sphere shapes can silently
	# return empty results. Iterate Players and Structures directly by distance.
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.current_scene:
		# -- Players --
		var players_node := tree.current_scene.get_node_or_null("Players")
		if players_node:
			for p in players_node.get_children():
				if not (p is Player) or p == exclude_body or p in already_damaged:
					continue
				if not p.is_alive:
					continue
				var dist := explosion_pos.distance_to(p.global_position)
				if dist > radius:
					continue
				var dmg := _calc_player_explosion_damage(
					space_state, explosion_pos, player_damage, radius, p, exclude_rid
				)
				if dmg > 0.5:
					p.take_damage(dmg, attacker_id)
				already_damaged.append(p)

		# -- Destructible structures (walls, ramps, OBJ structures) --
		var seed_world := tree.current_scene.get_node_or_null("SeedWorld")
		if seed_world == null:
			seed_world = tree.current_scene.get_node_or_null("BlockoutMap/SeedWorld")
		if seed_world:
			var structures := seed_world.get_node_or_null("Structures")
			if structures:
				for s in structures.get_children():
					if s in already_damaged:
						continue
					if not s.has_method("take_damage_at"):
						continue
					# Rough pre-filter: structure origin within radius + 10m
					# (structures can be up to ~5m from their origin).
					var dist := explosion_pos.distance_to(s.global_position)
					if dist > radius + 10.0:
						continue
					s.take_damage_at(explosion_pos, structure_damage, radius, attacker_id, exclude_rids)
					already_damaged.append(s)


# ======================================================================
#  Multi-point player damage with shielding
# ======================================================================

static func _calc_player_explosion_damage(
	space_state: PhysicsDirectSpaceState3D,
	explosion_pos: Vector3,
	base_damage: float,
	radius: float,
	player: Player,
	exclude_rid: RID
) -> float:
	## Cast 5 rays from explosion to player sample points. For each ray,
	## sum the flat HP absorption of everything in the path, then average
	## the 5 resulting damage values.

	var player_pos := player.global_position
	# Get player facing direction for left/right offsets
	var player_rid := player.get_rid()
	var yaw: float = 0.0
	var player_input = player.get_node_or_null("PlayerInput")
	if player_input and "look_yaw" in player_input:
		yaw = player_input.look_yaw

	var right_dir := Vector3(cos(yaw), 0.0, -sin(yaw))  # perpendicular to facing

	# 5 sample points on the player capsule
	var sample_points: Array[Vector3] = [
		player_pos + Vector3(0, PLAYER_CENTER_Y, 0),         # center
		player_pos + Vector3(0, PLAYER_TOP_Y, 0),            # top
		player_pos + Vector3(0, PLAYER_BOTTOM_Y, 0),         # bottom
		player_pos + right_dir * PLAYER_SIDE_OFFSET + Vector3(0, PLAYER_CENTER_Y, 0),   # right
		player_pos - right_dir * PLAYER_SIDE_OFFSET + Vector3(0, PLAYER_CENTER_Y, 0),   # left
	]

	var total_damage := 0.0
	var exclude_rids_base: Array[RID] = [player_rid]
	if exclude_rid.is_valid():
		exclude_rids_base.append(exclude_rid)

	var debug_rays := GameManager.debug_show_explosion_rays
	var debug_ray_data: Array = []

	# Reuse a single query object across all 5 sample rays (non-debug path).
	var query: PhysicsRayQueryParameters3D = null
	if not debug_rays:
		query = PhysicsRayQueryParameters3D.new()
		query.collision_mask = 1 | 128 | 256 | 1024
		query.exclude = exclude_rids_base

	for sample_pos in sample_points:
		# Distance falloff from explosion to this sample point (cubic)
		var dist := explosion_pos.distance_to(sample_pos)
		if dist > radius:
			continue  # This sample point is out of blast radius
		var norm_dist := dist / radius
		var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
		var raw_dmg := base_damage * falloff

		# Sum flat shielding along this ray
		var final_dmg: float
		var shield_hits: Array[Vector3] = []
		if debug_rays:
			var result: Array = calc_ray_shielding_debug(
				space_state, explosion_pos, sample_pos, exclude_rids_base.duplicate(), null
			)
			final_dmg = maxf(raw_dmg - result[0], 0.0)
			shield_hits = result[1]
		else:
			query.from = explosion_pos
			query.to = sample_pos
			var absorbed := space_state.calc_ray_shielding(query, RID(), raw_dmg)
			final_dmg = maxf(raw_dmg - absorbed, 0.0)

		total_damage += final_dmg

		if debug_rays:
			debug_ray_data.append({
				"from": explosion_pos, "to": sample_pos,
				"raw_dmg": raw_dmg, "final_dmg": final_dmg,
				"hits": shield_hits,
			})

	if debug_rays and not debug_ray_data.is_empty():
		draw_debug_rays(debug_ray_data)

	# Average across all 5 sample points
	return total_damage / 5.0


# ======================================================================
#  Ray shielding: single multi-hit raycast summing flat HP absorption
# ======================================================================

static func calc_ray_shielding(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	exclude_rids: Array[RID],
	target_body: Node,
	max_absorption: float = 99999.0
) -> float:
	## Single multi-hit raycast from→to, summing flat HP absorption of
	## everything in the path. Returns total damage absorbed.
	##
	## Delegates to C++ calc_ray_shielding (Jolt AllHitCollector + inline
	## classification + early-out). No Dictionary allocations, no GDScript
	## iteration — returns one float.
	var target_rid: RID = target_body.get_rid() if target_body else RID()
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1 | 128 | 256 | 1024  # Terrain(1) + players(128/256) + wall blocks(1024)
	query.exclude = exclude_rids
	return space_state.calc_ray_shielding(query, target_rid, max_absorption)


# ======================================================================
#  Batch ray shielding: N rays from a shared origin, parallelized in C++
# ======================================================================

static func calc_ray_shielding_batch(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to_points: PackedVector3Array,
	target_rids: Array[RID],
	max_absorptions: PackedFloat32Array,
	exclude_rids: Array[RID],
) -> PackedFloat32Array:
	## Batch N independent shielding raycasts from a shared origin.
	## Uses WorkerThreadPool parallelization in C++ (Jolt CastRay is thread-safe).
	## Returns PackedFloat32Array where result[i] = total absorption for ray i.
	var query := PhysicsRayQueryParameters3D.new()
	query.from = from
	query.collision_mask = 1 | 128 | 256 | 1024  # Terrain(1) + players(128/256) + wall blocks(1024)
	query.exclude = exclude_rids
	return space_state.calc_ray_shielding_batch(query, to_points, target_rids, max_absorptions)


# ======================================================================
#  Debug ray visualization
# ======================================================================

## Draw debug rays for an explosion. Each entry in ray_data is:
##   { "from": Vector3, "to": Vector3, "raw_dmg": float, "final_dmg": float,
##     "hits": Array of Vector3 positions where shielding occurred }
## Green = full damage, yellow = partial shielding, red = fully blocked.
static func draw_debug_rays(ray_data: Array) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	if ray_data.is_empty():
		return

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "DebugExplosionRays"

	var im := ImmediateMesh.new()
	mesh_node.mesh = im

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_node.material_override = mat

	# Draw lines
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for entry in ray_data:
		var from: Vector3 = entry["from"]
		var to: Vector3 = entry["to"]
		var raw: float = entry["raw_dmg"]
		var final: float = entry["final_dmg"]
		var absorbed: float = raw - final

		# Color based on shielding, not absolute damage level:
		#   Green  = no shielding encountered (full damage reaches target)
		#   Yellow = partial shielding (some damage still gets through)
		#   Red    = fully blocked by shielding (all damage absorbed)
		#   Gray   = out of blast range
		var color: Color
		if raw <= 0.01:
			color = Color(0.5, 0.5, 0.5, 0.4)  # Out of range — gray
		elif absorbed <= 0.01:
			color = Color(0.2, 1.0, 0.2, 0.6)  # No shielding — green
		elif final >= 0.5:
			color = Color(1.0, 1.0, 0.0, 0.6)  # Partial shielding — yellow
		else:
			color = Color(1.0, 0.2, 0.2, 0.6)  # Fully blocked — red

		im.surface_set_color(color)
		im.surface_add_vertex(from)
		im.surface_set_color(color)
		im.surface_add_vertex(to)

		# Draw small cross markers at each shielding hit point
		var hits: Array = entry.get("hits", [])
		var hit_color := Color(1.0, 0.5, 0.0, 0.8)  # Orange hit markers
		for hit_pos: Vector3 in hits:
			var s := 0.08
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(-s, 0, 0))
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(s, 0, 0))
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(0, -s, 0))
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(0, s, 0))
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(0, 0, -s))
			im.surface_set_color(hit_color)
			im.surface_add_vertex(hit_pos + Vector3(0, 0, s))
	im.surface_end()

	tree.current_scene.add_child(mesh_node)

	# Auto-delete after DEBUG_RAY_LIFETIME seconds
	tree.create_timer(DEBUG_RAY_LIFETIME, false).timeout.connect(
		func():
			if is_instance_valid(mesh_node):
				mesh_node.queue_free()
	)


## Variant of calc_ray_shielding that also collects hit positions for debug drawing.
## Returns [absorbed: float, hit_positions: Array[Vector3]].
static func calc_ray_shielding_debug(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	exclude_rids: Array[RID],
	target_body: Node
) -> Array:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1 | 128 | 256 | 1024  # Terrain(1) + players(128/256) + wall blocks(1024)
	query.exclude = exclude_rids
	var results := space_state.intersect_ray_all(query, MAX_RAY_ITERATIONS)

	var absorbed := 0.0
	var hit_positions: Array[Vector3] = []
	for result in results:
		var hit_node: Node = result["collider"]
		if hit_node == target_body:
			break

		var hit_pos: Vector3 = result["position"]

		if hit_node is Player and hit_node.has_method("take_damage"):
			absorbed += hit_node.health
			hit_positions.append(hit_pos)
		elif _is_wall_block(hit_node):
			var wall = hit_node.parent_wall
			var key: Vector3i = hit_node.grid_key
			if wall and is_instance_valid(wall) and wall._blocks.has(key):
				absorbed += wall._blocks[key]["hp"]
				hit_positions.append(hit_pos)
		elif hit_node is StaticBody3D:
			# Terrain (static world geometry) — fully blocks
			absorbed += 99999.0
			hit_positions.append(hit_pos)
			break
		elif "_hp" in hit_node:
			# Damageable dynamic body (rocket, etc.) — shields by its HP
			absorbed += hit_node._hp
			hit_positions.append(hit_pos)
		# else: unknown body without HP — skip, no absorption

	return [absorbed, hit_positions]


# ======================================================================
#  Utility
# ======================================================================

static func _find_damageable(node: Node) -> Node:
	## Walk up the tree from a collider to find the best damageable ancestor.
	## Prefers take_damage_at (spatial/wall damage) over plain take_damage.
	var current := node
	var first_damageable: Node = null
	for _i in 4:  # Max 4 levels up
		if current == null:
			break
		if current.has_method("take_damage_at"):
			return current
		if first_damageable == null and current.has_method("take_damage"):
			first_damageable = current
		current = current.get_parent()
	return first_damageable


static func _make_shielding_query(from: Vector3, exclude_rids: Array[RID]) -> PhysicsRayQueryParameters3D:
	## Create a configured PhysicsRayQueryParameters3D for shielding raycasts.
	## Used by both single-ray and batch-ray shielding paths.
	var query := PhysicsRayQueryParameters3D.new()
	query.from = from
	query.collision_mask = 1 | 128 | 256 | 1024  # Terrain(1) + players(128/256) + wall blocks(1024)
	query.exclude = exclude_rids
	return query


static func _is_wall_block(node: Node) -> bool:
	## Check if a node is a wall block (has grid_key and parent_wall).
	return node is StaticBody3D and "grid_key" in node and "parent_wall" in node
