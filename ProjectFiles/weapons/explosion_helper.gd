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
	var t_explosion_total := Time.get_ticks_usec()
	var space_state := world.direct_space_state
	if space_state == null:
		return

	var already_damaged: Array[Node] = []
	var exclude_rid: RID = exclude_body.get_rid() if exclude_body else RID()
	var exclude_rids: Array[RID] = []
	if exclude_rid.is_valid():
		exclude_rids.append(exclude_rid)

	var _dbg_pass1_structures: Array[String] = []

	# ------------------------------------------------------------------
	#  Pass 1: Physics sphere query (catches players + rigid bodies)
	# ------------------------------------------------------------------
	var t_sphere := Time.get_ticks_usec()
	var query := PhysicsShapeQueryParameters3D.new()
	# Reuse persistent sphere shape — see _query_sphere comment above.
	# The radius set here is deferred (threaded physics), so on the FIRST
	# explosion call the shape uses its default radius (0.5m). Pass 2's
	# scene scan catches anything missed. All subsequent calls use the
	# correct radius from the previous frame's flush.
	if _query_sphere == null:
		_query_sphere = SphereShape3D.new()
	_query_sphere.radius = radius
	query.shape = _query_sphere
	query.transform = Transform3D(Basis(), explosion_pos)
	query.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.BUBBLES | CollisionLayers.ALL_PLAYERS | CollisionLayers.WALL_BLOCKS
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var results := space_state.intersect_shape(query, 64)
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

	# --- Pass 2: Direct scene scan (safety net if sphere query misses targets) ---
	# Jolt's intersect_shape with server-created sphere shapes can silently
	# return empty results. Iterate Players and Structures directly by distance.
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

	# -- Destructible structures (walls, ramps, OBJ structures) --
	var t_pass2_structures := Time.get_ticks_usec()
	var pass2_structures := 0
	var pass2_scanned := 0
	var pass2_skipped := 0
	if tree and tree.current_scene:
		var seed_world := tree.current_scene.get_node_or_null("SeedWorld")
		if seed_world == null:
			seed_world = tree.current_scene.get_node_or_null("BlockoutMap/SeedWorld")
		if seed_world:
			var structures := seed_world.get_node_or_null("Structures")
			if structures:
				var _dbg_pass2_structures: Array[String] = []
				var _dbg_pass2_skipped: Array[String] = []
				for s in structures.get_children():
					pass2_scanned += 1
					if s in already_damaged:
						continue
					if not s.has_method("take_damage_at"):
						continue
					# Pre-filter: check if any block could be within blast radius.
					# Use structure_size half-diagonal as the margin so tall/large
					# OBJ structures aren't skipped when the explosion is near their
					# edge but far from their center.
					var margin := 10.0
					if "structure_size" in s:
						margin = maxf(s.structure_size.length() * 0.5, 10.0)
					var dist := explosion_pos.distance_to(s.global_position)
					if dist > radius + margin:
						pass2_skipped += 1
						continue
					_dbg_pass2_structures.append(s.name)
					s.take_damage_at(explosion_pos, structure_damage, radius, attacker_id, exclude_rids, impact_speed)
					already_damaged.append(s)
					pass2_structures += 1

				if not _dbg_pass2_structures.is_empty() or not _dbg_pass2_skipped.is_empty():
					print("[Explosion] pass1_structures=%s  pass2_structures=%s" % [
						str(_dbg_pass1_structures), str(_dbg_pass2_structures)])
	var t_pass2_structures_end := Time.get_ticks_usec()

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
	print("[DoExplosion] sphere_query=%dus(%d results)  pass1=%dus(players=%d structs=%d objs=%d)  pass2_players=%dus(%d)  pass2_structs=%dus(scanned=%d skipped=%d hit=%d)  impulse=%d  total=%dus" % [
		t_sphere_end - t_sphere, results.size(),
		t_pass1_process_end - t_pass1_process, pass1_players, pass1_structures, pass1_objects,
		t_pass2_players_end - t_pass2_players, pass2_players,
		t_pass2_structures_end - t_pass2_structures, pass2_scanned, pass2_skipped, pass2_structures,
		impulse_count,
		explosion_us,
	])
	GameManager.tick_add("do_explosion", explosion_us)

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
