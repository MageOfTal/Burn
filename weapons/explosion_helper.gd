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

## Max raycasts per shielding check to prevent infinite loops
const MAX_RAY_ITERATIONS := 8


# ======================================================================
#  Main entry point — replaces inline explosion code in rocket + kamikaze
# ======================================================================

static func do_explosion(
	world: World3D,
	scene_root: Node,
	explosion_pos: Vector3,
	base_damage: float,
	radius: float,
	attacker_id: int,
	exclude_body: Node = null
) -> void:
	## Deal shielded explosion damage to all players and walls in radius.
	## exclude_body: the rocket RigidBody3D or kamikaze player to skip.
	var space_state := world.direct_space_state
	if space_state == null:
		return

	var already_damaged: Array[Node] = []
	var exclude_rid: RID = exclude_body.get_rid() if exclude_body else RID()

	# ------------------------------------------------------------------
	#  Pass 1: Physics sphere query (catches players + rigid bodies)
	# ------------------------------------------------------------------
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	query.shape = sphere
	query.transform = Transform3D(Basis(), explosion_pos)
	query.collision_mask = 0xFFFFFFFF
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
			target.take_damage_at(explosion_pos, base_damage, radius, attacker_id)
			already_damaged.append(target)
		elif target is CharacterBody3D and target.has_method("take_damage"):
			# Player: multi-point raycast with flat shielding
			var dmg := _calc_player_explosion_damage(
				space_state, explosion_pos, base_damage, radius, target, exclude_rid
			)
			if dmg > 0.5:
				target.take_damage(dmg, attacker_id)
			already_damaged.append(target)

	# ------------------------------------------------------------------
	#  Pass 2: Scene-tree scan for walls the sphere query may have missed
	# ------------------------------------------------------------------
	var structures: Node = null
	if scene_root:
		structures = scene_root.get_node_or_null("SeedWorld/Structures")
		if structures == null:
			structures = scene_root.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		for child in structures.get_children():
			if child in already_damaged:
				continue
			if child.has_method("take_damage_at"):
				var dist := explosion_pos.distance_to(child.global_position)
				var wall_reach: float = 0.0
				if "wall_size" in child:
					wall_reach = child.wall_size.length() * 0.5
				if dist <= radius + wall_reach:
					child.take_damage_at(explosion_pos, base_damage, radius, attacker_id)
					already_damaged.append(child)


# ======================================================================
#  Multi-point player damage with shielding
# ======================================================================

static func _calc_player_explosion_damage(
	space_state: PhysicsDirectSpaceState3D,
	explosion_pos: Vector3,
	base_damage: float,
	radius: float,
	player: CharacterBody3D,
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

	for sample_pos in sample_points:
		# Distance falloff from explosion to this sample point
		var dist := explosion_pos.distance_to(sample_pos)
		if dist > radius:
			continue  # This sample point is out of blast radius
		var falloff := clampf(1.0 - (dist / radius), 0.0, 1.0)
		var raw_dmg := base_damage * falloff

		# Sum flat shielding along this ray
		var absorbed := calc_ray_shielding(
			space_state, explosion_pos, sample_pos, exclude_rids_base.duplicate(), null
		)

		total_damage += maxf(raw_dmg - absorbed, 0.0)

	# Average across all 5 sample points
	return total_damage / 5.0


# ======================================================================
#  Ray shielding: iterative raycast summing flat HP absorption
# ======================================================================

static func calc_ray_shielding(
	space_state: PhysicsDirectSpaceState3D,
	from: Vector3,
	to: Vector3,
	exclude_rids: Array[RID],
	target_body: Node
) -> float:
	## Cast iterative rays from→to, summing flat HP absorption of everything
	## in the path. Returns total damage absorbed.
	##
	## - Wall blocks contribute their current block HP
	## - Players contribute their current health
	## - Terrain blocks the ray completely (infinite absorption)
	var absorbed := 0.0
	var current_from := from
	var dir := (to - from).normalized()
	var max_dist := from.distance_to(to)

	for _i in MAX_RAY_ITERATIONS:
		var query := PhysicsRayQueryParameters3D.create(current_from, to)
		query.collision_mask = 1  # Layer 1: terrain, wall blocks, players
		query.exclude = exclude_rids
		var result := space_state.intersect_ray(query)
		if result.is_empty():
			break  # Clear path to target

		var hit_node: Node = result["collider"]
		if hit_node == target_body:
			break  # Reached the target itself

		# Identify what we hit and add its HP as absorption
		if hit_node is CharacterBody3D and hit_node.has_method("take_damage"):
			# Player in the way: absorbs up to their current health
			absorbed += hit_node.health
		elif _is_wall_block(hit_node):
			# Wall block: absorbs up to its current HP
			var wall = hit_node.parent_wall
			var key: Vector3i = hit_node.grid_key
			if wall and is_instance_valid(wall) and wall._blocks.has(key):
				absorbed += wall._blocks[key]["hp"]
		else:
			# Terrain or unknown solid — fully blocks (infinite absorption)
			absorbed += 99999.0
			break

		# Skip past this hit and continue
		exclude_rids.append(hit_node.get_rid())
		current_from = result["position"] + dir * 0.05
		if current_from.distance_to(from) >= max_dist:
			break

	return absorbed


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


static func _is_wall_block(node: Node) -> bool:
	## Check if a node is a wall block (has grid_key and parent_wall).
	return node is StaticBody3D and "grid_key" in node and "parent_wall" in node
