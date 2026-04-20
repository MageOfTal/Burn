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

## Max hits per shielding raycast (controls intersect_ray_all max_results).
## Must match the C++ JoltQueryCollectorAll<CastRayCollector, 32> capacity
## so that the debug and production paths see the same shielding bodies.
const MAX_RAY_ITERATIONS := 32

## Debug ray auto-delete time (seconds)
const DEBUG_RAY_LIFETIME := 4.0

## Maximum velocity change (m/s) from a single explosion impulse.
## Prevents absurdly fast launches on very light objects (e.g. 0.1 kg bubbles).
const MAX_IMPULSE_VELOCITY := 50.0

## Persistent sphere shape for physics queries. Pre-created in prewarm()
## (called from GameManager._ready) so the Jolt shape is registered before
## the first explosion fires.
static var _query_sphere: SphereShape3D = null


static func prewarm() -> void:
	## Create the query sphere early so Jolt has it ready before any explosion.
	## SphereShape3D.new() builds a Jolt shape with radius 0 which Jolt rejects,
	## so we immediately set a valid radius.
	if _query_sphere == null:
		_query_sphere = SphereShape3D.new()
		_query_sphere.radius = 10.0
		PhysicsServer3D.shape_set_data(_query_sphere.get_rid(), 10.0)


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
	impact_speed: float = INF,
	impulse_strength: float = 400.0,
) -> void:
	## Deal shielded explosion damage to all players and walls in radius.
	## player_damage: base damage dealt to players (before falloff/shielding).
	## structure_damage: base damage dealt to structures/blocks/physics objects.
	## exclude_body: the rocket RigidBody3D or kamikaze player to skip.
	## impact_speed: speed of the projectile at detonation (m/s). Passed to debris.
	## impulse_strength: base impulse (N·s) applied to RigidBody3D objects (before
	##   falloff). Heavier objects receive less velocity change. 0.0 = no impulse.
	Profiler.begin("do_explosion")
	var t_explosion_total := Time.get_ticks_usec()
	var space_state := world.direct_space_state
	if space_state == null:
		Profiler.end("do_explosion")
		return

	var already_damaged: Array[Node] = []
	var exclude_rid: RID = exclude_body.get_rid() if exclude_body else RID()
	var exclude_rids: Array[RID] = []
	if exclude_rid.is_valid():
		exclude_rids.append(exclude_rid)

	var _dbg_pass1_structures: Array[String] = []

	# ------------------------------------------------------------------
	#  Sphere query — finds players, structures, rigid bodies in radius
	# ------------------------------------------------------------------
	var t_sphere := Time.get_ticks_usec()
	var query := PhysicsShapeQueryParameters3D.new()
	if _query_sphere == null:
		prewarm()  # Fallback if prewarm wasn't called
	_query_sphere.radius = radius
	PhysicsServer3D.shape_set_data(_query_sphere.get_rid(), radius)
	query.shape = _query_sphere
	query.transform = Transform3D(Basis(), explosion_pos)
	query.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.BUBBLES | CollisionLayers.ALL_PLAYERS | CollisionLayers.WALL_BLOCKS
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var results := space_state.intersect_shape(query, 2048)
	var t_sphere_end := Time.get_ticks_usec()

	# --- DEBUG: scan for nearby FallingBlockClusters and dump their shielding state ---
	if GameManager.debug_show_explosion_rays:
		var tree_dbg := Engine.get_main_loop() as SceneTree
		if tree_dbg and tree_dbg.current_scene:
			var structures_dbg: Node = null
			var seed_dbg := tree_dbg.current_scene.get_node_or_null("SeedWorld")
			if seed_dbg == null:
				seed_dbg = tree_dbg.current_scene.get_node_or_null("BlockoutMap/SeedWorld")
			if seed_dbg:
				structures_dbg = seed_dbg.get_node_or_null("Structures")
			if structures_dbg:
				for child in structures_dbg.get_children():
					if not (child is FallingBlockCluster):
						continue
					var cdist := explosion_pos.distance_to(child.global_position)
					if cdist > radius + 10.0:
						continue
					var crid: RID = child.get_rid()
					var ctag := PhysicsServer3D.body_get_shielding_tag(crid)
					var chp := PhysicsServer3D.body_get_shielding_hp(crid)
					var clayer: int = child.collision_layer
					var frozen: bool = child.freeze
					print("[ClusterDiag] %s dist=%.1f layer=%d (WALL_BLOCKS=%s) tag=%d hp=%.1f frozen=%s rid=%s" % [
						child.name, cdist, clayer,
						str(bool(clayer & CollisionLayers.WALL_BLOCKS)),
						ctag, chp, str(frozen), str(crid)])
					# Test: cast a single ray from explosion through this cluster center
					var test_q := PhysicsRayQueryParameters3D.new()
					test_q.from = explosion_pos
					test_q.to = child.global_position
					test_q.collision_mask = CollisionLayers.SHIELDING
					test_q.exclude = exclude_rids
					var test_hits := space_state.intersect_ray_all(test_q, 32)
					var found_self := false
					for th in test_hits:
						var tc: Object = th.get("collider")
						if tc == child:
							found_self = true
						var trid: RID = th.get("rid", RID())
						var ttag := PhysicsServer3D.body_get_shielding_tag(trid) if trid.is_valid() else -1
						print("[ClusterDiag]   ray_hit: %s (%s) tag=%d rid=%s" % [
							tc.name if tc else "null",
							tc.get_class() if tc else "null",
							ttag, str(trid)])
					if not found_self:
						print("[ClusterDiag]   >>> CLUSTER NOT HIT BY RAY! mask=%d, cluster_layer=%d, overlap=%d" % [
							CollisionLayers.SHIELDING, clayer,
							CollisionLayers.SHIELDING & clayer])

	var t_pass1_process := Time.get_ticks_usec()
	var pass1_players := 0
	var pass1_structures := 0
	var pass1_objects := 0
	for result in results:
		var collider: Node = result["collider"]
		if collider == exclude_body:
			continue
		var target := _find_damageable(collider)
		if target == null or target in already_damaged:
			continue

		if target.has_method("take_damage_at"):
			# Wall: let take_damage_at handle per-block shielding internally
			_dbg_pass1_structures.append(target.name)
			target.take_damage_at(explosion_pos, structure_damage, radius, attacker_id, exclude_rids, impact_speed)
			already_damaged.append(target)
			pass1_structures += 1
		elif target is Player and target.has_method("take_damage"):
			# Player: multi-point raycast with flat shielding
			var dmg := _calc_player_explosion_damage(
				space_state, explosion_pos, player_damage, radius, target, exclude_rid
			)
			if dmg > 0.5:
				target.take_damage(dmg, attacker_id)
			already_damaged.append(target)
			pass1_players += 1
		elif target.has_method("take_damage"):
			# Any damageable object (physics bodies, target dummies, etc.) — cubic falloff
			var dist := explosion_pos.distance_to(target.global_position)
			if dist <= radius:
				var norm_dist := dist / radius
				var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
				var dmg := structure_damage * falloff
				if dmg > 0.5:
					target.take_damage(dmg, attacker_id)
			already_damaged.append(target)
			pass1_objects += 1
	var t_pass1_process_end := Time.get_ticks_usec()

	# --- Player scene scan (safety net — players move and may be missed by sphere) ---
	var t_pass2_players := Time.get_ticks_usec()
	var pass2_players := 0
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
				pass2_players += 1
	var t_pass2_players_end := Time.get_ticks_usec()

	# --- Full explosion diagnostics: compare sphere results against all scene structures ---
	if GameManager.debug_explosion_diagnostics:
		_dump_explosion_diagnostics(explosion_pos, radius, structure_damage,
			results, already_damaged, exclude_body, space_state, exclude_rids)

	# ------------------------------------------------------------------
	#  Impulse pass: push RigidBody3D objects away from the blast
	# ------------------------------------------------------------------
	var impulse_count := 0
	if impulse_strength > 0.0:
		var impulsed_rids: Dictionary = {}  # RID -> true (fast dedup)

		# Bodies from the sphere query (players, items, clusters, projectiles)
		for result in results:
			var body: Node = result["collider"]
			if not (body is RigidBody3D) or body == exclude_body:
				continue
			var rb := body as RigidBody3D
			if rb.freeze:
				continue
			var rid := rb.get_rid()
			if impulsed_rids.has(rid):
				continue
			_apply_explosion_impulse(rb, explosion_pos, radius, impulse_strength)
			impulsed_rids[rid] = true
			impulse_count += 1

		# Safety net: players missed by the sphere query (mirrors pass 2)
		if tree and tree.current_scene:
			var impulse_players := tree.current_scene.get_node_or_null("Players")
			if impulse_players:
				for p in impulse_players.get_children():
					if not (p is Player) or p == exclude_body:
						continue
					if not p.is_alive:
						continue
					var p_rid: RID = p.get_rid()
					if impulsed_rids.has(p_rid):
						continue
					var dist := explosion_pos.distance_to(p.global_position)
					if dist > radius:
						continue
					_apply_explosion_impulse(p, explosion_pos, radius, impulse_strength)
					impulsed_rids[p_rid] = true
					impulse_count += 1

	var t_explosion_total_end := Time.get_ticks_usec()
	var explosion_us := t_explosion_total_end - t_explosion_total
	if GameManager.debug_explosion_diagnostics:
		print("[DoExplosion] sphere=%dus(%d results)  damage=%dus(players=%d structs=%d objs=%d)  player_scan=%dus(%d)  impulse=%d  total=%dus" % [
			t_sphere_end - t_sphere, results.size(),
			t_pass1_process_end - t_pass1_process, pass1_players, pass1_structures, pass1_objects,
			t_pass2_players_end - t_pass2_players, pass2_players,
			impulse_count,
			explosion_us,
		])
	GameManager.tick_add("do_explosion", explosion_us)
	Profiler.end("do_explosion")

	# Profile the next 60 ticks (~1 second) to see post-explosion aftermath costs
	GameManager.start_tick_profile(60)


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

	# Reuse a single query object across all 5 sample rays.
	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = CollisionLayers.SHIELDING
	query.exclude = exclude_rids_base

	for i_sample in sample_points.size():
		var sample_pos: Vector3 = sample_points[i_sample]
		# Distance falloff from explosion to this sample point (cubic)
		var dist := explosion_pos.distance_to(sample_pos)
		if dist > radius:
			continue  # This sample point is out of blast radius
		var norm_dist := dist / radius
		var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)
		var raw_dmg := base_damage * falloff

		# Always use C++ shielding — debug flag only controls ray visualization.
		query.from = explosion_pos
		query.to = sample_pos
		var absorbed_cpp := space_state.calc_ray_shielding(query, RID(), raw_dmg)
		var final_dmg := maxf(raw_dmg - absorbed_cpp, 0.0)

		total_damage += final_dmg

		# --- DEBUG: enumerate every body the shielding ray hits ---
		if debug_rays:
			var all_hits := space_state.intersect_ray_all(query, MAX_RAY_ITERATIONS)
			var hit_details: Array = []
			for hit in all_hits:
				var collider: Object = hit.get("collider")
				var hit_rid: RID = hit.get("rid", RID())
				var hit_pos: Vector3 = hit.get("position", Vector3.ZERO)
				var tag := PhysicsServer3D.body_get_shielding_tag(hit_rid) if hit_rid.is_valid() else -1
				var shp := PhysicsServer3D.body_get_shielding_hp(hit_rid) if hit_rid.is_valid() else 0.0
				var col_layer := 0
				if collider is CollisionObject3D:
					col_layer = (collider as CollisionObject3D).collision_layer
				var cname: String = str(collider.name) if collider else "null"
				var cclass: String = str(collider.get_class()) if collider else "null"
				var is_cluster := collider is FallingBlockCluster
				hit_details.append(hit_pos)
				print("[ShieldDiag] ray %d hit: %s (%s) layer=%d tag=%d hp=%.1f pos=%s cluster=%s" % [
					i_sample, cname, cclass, col_layer, tag, shp,
					str(hit_pos).substr(0, 30), str(is_cluster)])
			if all_hits.is_empty():
				print("[ShieldDiag] ray %d: NO HITS (mask=%d)" % [i_sample, query.collision_mask])

			debug_ray_data.append({
				"from": explosion_pos, "to": sample_pos,
				"raw_dmg": raw_dmg, "final_dmg": final_dmg,
				"hits": hit_details,
			})

	if debug_rays and not debug_ray_data.is_empty():
		draw_debug_rays(debug_ray_data)

	# Average across all 5 sample points
	return total_damage / 5.0



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

		# Color based on shielding fraction (absorbed / raw), ignoring falloff:
		#   Green  = no shielding (0% absorbed)
		#   Yellow = partial shielding (some absorbed, some gets through)
		#   Red    = fully blocked (100% absorbed by shielding)
		#   Gray   = out of blast range
		var color: Color
		if raw <= 0.01:
			color = Color(0.5, 0.5, 0.5, 0.4)  # Out of range — gray
		elif absorbed <= 0.01:
			color = Color(0.2, 1.0, 0.2, 0.6)  # No shielding — green
		elif absorbed >= raw - 0.01:
			color = Color(1.0, 0.2, 0.2, 0.6)  # Fully blocked — red
		else:
			color = Color(1.0, 1.0, 0.0, 0.6)  # Partial shielding — yellow

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


static func _apply_explosion_impulse(
	body: RigidBody3D,
	explosion_pos: Vector3,
	radius: float,
	impulse_strength: float,
) -> void:
	## Push a RigidBody3D away from the explosion center. Same cubic falloff as
	## damage, with a slight upward bias so objects arc instead of sliding.
	## Impulse is force-based: heavier objects get less velocity change.
	var dist := explosion_pos.distance_to(body.global_position)
	if dist > radius:
		return
	var norm_dist := dist / radius
	var falloff := 1.0 / (1.0 + (norm_dist * 3.0) ** 3)

	# Direction from explosion to body, with upward bias for a satisfying arc
	var dir := body.global_position - explosion_pos
	if dir.length_squared() < 0.01:
		dir = Vector3.UP
	else:
		dir = dir.normalized()
		dir.y = maxf(dir.y, 0.3)
		dir = dir.normalized()

	# Cap impulse so very light objects don't reach absurd velocities
	var impulse_mag := minf(impulse_strength * falloff, MAX_IMPULSE_VELOCITY * body.mass)
	body.apply_central_impulse(dir * impulse_mag)


static func _make_shielding_query(from: Vector3, exclude_rids: Array[RID]) -> PhysicsRayQueryParameters3D:
	## Create a configured PhysicsRayQueryParameters3D for shielding raycasts.
	## Used by both single-ray and batch-ray shielding paths.
	var query := PhysicsRayQueryParameters3D.new()
	query.from = from
	query.collision_mask = CollisionLayers.SHIELDING  # Terrain(1) + players(128/256) + wall blocks(1024)
	query.exclude = exclude_rids
	return query


# ======================================================================
#  Explosion diagnostics — full scene dump
# ======================================================================

static func _dump_explosion_diagnostics(
	explosion_pos: Vector3, radius: float, structure_damage: float,
	sphere_results: Array, already_damaged: Array[Node], exclude_body: Node,
	space_state: PhysicsDirectSpaceState3D, exclude_rids: Array[RID],
) -> void:
	## Comprehensive diagnostic: compares what the explosion found against every
	## block structure in the scene. Flags structures within blast radius that
	## were NOT damaged and suggests likely causes.
	print("[ExplosionDiag] ══════════════════════════════════════════════════════")
	print("[ExplosionDiag] EXPLOSION pos=%s  radius=%.1f  struct_dmg=%.0f" % [
		str(explosion_pos).substr(0, 40), radius, structure_damage])
	print("[ExplosionDiag] Sphere query: %d results  |  query mask=%d (WALL_BLOCKS=%d)" % [
		sphere_results.size(), CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.BUBBLES | CollisionLayers.ALL_PLAYERS | CollisionLayers.WALL_BLOCKS,
		CollisionLayers.WALL_BLOCKS])
	print("[ExplosionDiag] NOTE: Jolt deferred shapes — first-frame sphere query may use default radius (0.5m)")
	print("[ExplosionDiag] Already damaged (%d): %s" % [already_damaged.size(),
		str(already_damaged.map(func(n: Node): return n.name if n else "null"))])

	# Identify which structures the sphere query actually returned colliders for
	var sphere_structure_ids: Dictionary = {}
	for result in sphere_results:
		var collider: Node = result["collider"]
		if collider == null:
			continue
		var cur := collider
		for _i in 4:
			if cur == null:
				break
			if cur is DestructibleBlockStructure or cur is FallingBlockCluster:
				sphere_structure_ids[cur.get_instance_id()] = cur
				break
			cur = cur.get_parent()

	print("[ExplosionDiag] Sphere query resolved to %d unique structures" % sphere_structure_ids.size())

	# Find ALL structures in scene
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.current_scene:
		print("[ExplosionDiag] No scene tree!")
		return

	var structures_node: Node = null
	var seed_world = tree.current_scene.get_node_or_null("SeedWorld")
	if seed_world == null:
		seed_world = tree.current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	if seed_world:
		structures_node = seed_world.get_node_or_null("Structures")

	if not structures_node:
		print("[ExplosionDiag] Structures node NOT FOUND in scene tree!")
		return

	print("[ExplosionDiag] Structures node: %d children total" % structures_node.get_child_count())

	var missed_count := 0
	for child in structures_node.get_children():
		var is_wall := child is DestructibleBlockStructure
		var is_cluster := child is FallingBlockCluster
		if not is_wall and not is_cluster:
			continue

		var dist := explosion_pos.distance_to(child.global_position)
		if dist > radius + 5.0:
			continue

		var type_str := "Wall" if is_wall else "Cluster"
		var in_sphere := sphere_structure_ids.has(child.get_instance_id())
		var was_damaged := child in already_damaged
		var in_radius := dist <= radius

		var status := "DAMAGED" if was_damaged else ("IN_SPHERE" if in_sphere else "MISSED")
		print("[ExplosionDiag] ── %s '%s'  dist=%.1f  %s ──" % [type_str, child.name, dist, status])
		print("[ExplosionDiag]   pos=%s" % str(child.global_position).substr(0, 40))

		# Compound hit body diagnostics
		var hit_body: Node = child.get("_compound_hit_body")
		if hit_body == null:
			print("[ExplosionDiag]   hit_body: NULL — no shapes for sphere query to find!")
		elif not is_instance_valid(hit_body):
			print("[ExplosionDiag]   hit_body: FREED/INVALID")
		else:
			var layer: int = hit_body.collision_layer
			var has_wb := bool(layer & CollisionLayers.WALL_BLOCKS)
			var key_map: Dictionary = child.get("_key_to_shape")
			var shape_arr: Array = child.get("_shape_to_key")
			var n_active: int = key_map.size() if key_map else 0
			var n_total: int = shape_arr.size() if shape_arr else 0
			print("[ExplosionDiag]   hit_body: layer=%d WALL_BLOCKS=%s  active_shapes=%d/%d  rid=%s" % [
				layer, str(has_wb), n_active, n_total, str(hit_body.get_rid())])
			if not has_wb:
				print("[ExplosionDiag]   >>> MISSING WALL_BLOCKS LAYER — explosion query CANNOT find this!")
			if n_active == 0 and n_total > 0:
				print("[ExplosionDiag]   >>> ALL SHAPES DISABLED — nothing to collide with!")

		if is_wall:
			var smooth: Node = child.get("_collision_body")
			if smooth and is_instance_valid(smooth):
				print("[ExplosionDiag]   smooth_body: layer=%d" % smooth.collision_layer)
			else:
				print("[ExplosionDiag]   smooth_body: %s" % ("NULL" if smooth == null else "FREED"))
			var hp_dict: Dictionary = child.get("_block_hp_dict")
			print("[ExplosionDiag]   blocks=%d" % (hp_dict.size() if hp_dict else 0))

		if is_cluster:
			print("[ExplosionDiag]   body_layer=%d  frozen=%s  mass=%.1f" % [
				child.collision_layer, str(child.freeze), child.cluster_mass])
			var grid = child.get("grid")
			print("[ExplosionDiag]   blocks=%d" % (grid.block_hp.size() if grid else 0))

		# ── Critical diagnostic: in radius but not damaged ──
		if in_radius and not was_damaged and child != exclude_body:
			missed_count += 1
			print("[ExplosionDiag]   >>>>>> WITHIN RADIUS (%.1f <= %.1f) BUT NOT DAMAGED! <<<<<<" % [dist, radius])

			if hit_body == null or (hit_body != null and not is_instance_valid(hit_body)):
				print("[ExplosionDiag]   Likely cause: no valid compound_hit_body")
			elif not bool(hit_body.collision_layer & CollisionLayers.WALL_BLOCKS):
				print("[ExplosionDiag]   Likely cause: missing WALL_BLOCKS layer (layer=%d)" % hit_body.collision_layer)
			elif not in_sphere:
				print("[ExplosionDiag]   Likely cause: sphere query missed this (deferred shape? shape positions?)")
				# Test raycast from explosion to structure center
				if space_state:
					var test_q := PhysicsRayQueryParameters3D.new()
					test_q.from = explosion_pos
					test_q.to = child.global_position
					test_q.collision_mask = CollisionLayers.WALL_BLOCKS
					test_q.exclude = exclude_rids
					var test_hit := space_state.intersect_ray(test_q)
					if test_hit:
						var hitter: Node = test_hit.get("collider")
						print("[ExplosionDiag]   Test ray hit: %s (%s) at %s" % [
							hitter.name if hitter else "null",
							hitter.get_class() if hitter else "null",
							str(test_hit.get("position", Vector3.ZERO)).substr(0, 30)])
					else:
						print("[ExplosionDiag]   Test ray from explosion to structure center: NO HIT")
				# Check if any individual blocks are actually within radius
				if is_wall:
					var any_in := false
					var hp_dict: Dictionary = child.get("_block_hp_dict")
					if hp_dict:
						for key: Vector3i in hp_dict:
							var bpos: Vector3 = child.global_transform * child._block_local_pos(key)
							if explosion_pos.distance_to(bpos) <= radius:
								any_in = true
								break
					if not any_in:
						print("[ExplosionDiag]   Note: center in range but NO individual blocks within blast radius")
				if is_cluster:
					var grid = child.get("grid")
					if grid:
						var any_in := false
						for key: Vector3i in grid.block_hp:
							var bpos: Vector3 = child.global_transform * grid.block_local_pos(key)
							if explosion_pos.distance_to(bpos) <= radius:
								any_in = true
								break
						if not any_in:
							print("[ExplosionDiag]   Note: center in range but NO individual blocks within blast radius")
			else:
				print("[ExplosionDiag]   Likely cause: sphere found it, but _find_damageable or take_damage_at skipped it")
				# Check if _find_damageable would resolve this
				if hit_body and is_instance_valid(hit_body):
					var parent_wall = hit_body.get("parent_wall")
					if parent_wall == null:
						print("[ExplosionDiag]   hit_body.parent_wall is NULL — _find_damageable cannot walk to structure")
					elif not is_instance_valid(parent_wall):
						print("[ExplosionDiag]   hit_body.parent_wall is INVALID/FREED")
					elif not parent_wall.has_method("take_damage_at"):
						print("[ExplosionDiag]   parent_wall has NO take_damage_at method!")

	if missed_count == 0:
		print("[ExplosionDiag] All nearby structures accounted for")
	else:
		print("[ExplosionDiag] >>> %d STRUCTURE(S) IN RADIUS BUT NOT DAMAGED <<<" % missed_count)
	print("[ExplosionDiag] ══════════════════════════════════════════════════════")
