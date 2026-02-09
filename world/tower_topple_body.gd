extends RigidBody3D
class_name TowerToppleBody

## The rigid body representing the toppling upper section of a spiral tower.
## Server-authoritative: detects ground impact, triggers chunk breakup and
## explosion damage at the impact point.
##
## Created by spiral_tower.gd when structural integrity fails.

const TowerChunkScript := preload("res://world/tower_chunk.gd")

# ======================================================================
#  Constants
# ======================================================================

const IMPACT_MIN_SPEED := 2.0          ## Minimum total speed to count as impact
const MAX_TOPPLE_TIME := 10.0          ## Safety timeout — force breakup
const IMMUNITY_TIME := 1.5             ## Ignore everything for this long after spawn
const SETTLE_TIME := 4.0              ## After this long, break up even if slow (it settled)
const CHUNK_COUNT_MIN := 4
const CHUNK_COUNT_MAX := 8
const EXPLOSION_DAMAGE_MULT := 50.0    ## base_damage = speed * (section/40) * this
const MAX_BLAST_RADIUS := 15.0

# ======================================================================
#  Properties (set by spiral_tower.gd before adding to scene)
# ======================================================================

var section_height: float = 20.0
var attacker_id: int = -1
var tower_position: Vector3 = Vector3.ZERO

# ======================================================================
#  Internal state
# ======================================================================

var _topple_timer: float = 0.0
var _has_impacted: bool = false
## Track the tower VoxelTerrain node so we can ignore collisions with it
var _tower_terrain: Node = null
## Track spawn height to detect when the body has fallen significantly
var _spawn_y: float = 0.0
## Track if the body has been touching something (non-tower) recently
var _contact_frames: int = 0


func _ready() -> void:
	if not multiplayer.is_server():
		return
	body_entered.connect(_on_body_entered)
	_spawn_y = global_position.y

	# Find the tower's VoxelTerrain so we can ignore collisions with it
	var tower := _find_tower()
	if tower:
		for child in tower.get_children():
			if child is VoxelTerrain:
				_tower_terrain = child
				break


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or _has_impacted:
		return

	_topple_timer += delta

	# Safety timeout — force breakup no matter what
	if _topple_timer >= MAX_TOPPLE_TIME:
		print("[TowerToppleBody] Safety timeout — forcing breakup")
		_do_impact(_find_impact_pos(), linear_velocity)
		return

	# Skip all checks during immunity
	if _topple_timer < IMMUNITY_TIME:
		return

	# Active impact detection: check if any part of the body is in contact
	# with the ground terrain by raycasting from the body in multiple directions.
	# A tipping tower hits ground at an angle, so we check downward from the
	# centroid AND from the edges.
	var speed := linear_velocity.length()
	var angular_speed := angular_velocity.length()

	# Method 1: If the body has contacts and decent speed, it's impacting.
	# get_contact_count() works when contact_monitor is enabled.
	var contact_count := get_contact_count()
	if contact_count > 0 and (speed > IMPACT_MIN_SPEED or angular_speed > 1.0):
		# Check if any contact is NOT the tower terrain
		var has_ground_contact := false
		for i in contact_count:
			var collider := get_colliding_bodies()
			for c in collider:
				if c != _tower_terrain:
					has_ground_contact = true
					break
			if has_ground_contact:
				break
		if has_ground_contact:
			_contact_frames += 1
			# Require a few frames of contact to avoid false positives
			if _contact_frames >= 3:
				print("[TowerToppleBody] Ground contact impact! speed=%.1f angular=%.1f contacts=%d timer=%.1f" % [
					speed, angular_speed, contact_count, _topple_timer])
				_do_impact(_find_impact_pos(), linear_velocity)
				return
	else:
		_contact_frames = 0

	# Method 2: If the body has been around a while and slowed down, it settled.
	# This catches the case where it gently lands and stops moving.
	if _topple_timer >= SETTLE_TIME and speed < 1.0 and angular_speed < 0.5:
		print("[TowerToppleBody] Settled (speed=%.2f angular=%.2f) — breaking up" % [speed, angular_speed])
		_do_impact(_find_impact_pos(), linear_velocity)
		return

	# Method 3: Raycast-based ground detection.
	# Cast rays from the body downward and along its tilt direction to detect
	# when the tower tip has reached ground level.
	if _topple_timer > IMMUNITY_TIME + 0.5:
		var hit_pos := _raycast_ground_check()
		if hit_pos != Vector3.ZERO and (speed > IMPACT_MIN_SPEED or angular_speed > 1.0):
			print("[TowerToppleBody] Raycast ground hit! speed=%.1f timer=%.1f" % [speed, _topple_timer])
			_do_impact(hit_pos, linear_velocity)
			return


func _on_body_entered(body: Node) -> void:
	## Backup: body_entered signal for immediate collision detection.
	if _has_impacted or not multiplayer.is_server():
		return
	if _topple_timer < IMMUNITY_TIME:
		return
	if body == _tower_terrain:
		return

	var speed := linear_velocity.length()
	var angular_speed := angular_velocity.length()
	if speed < IMPACT_MIN_SPEED and angular_speed < 1.0:
		return

	print("[TowerToppleBody] body_entered impact! speed=%.1f body=%s timer=%.1f" % [
		speed, body.name, _topple_timer])
	_do_impact(_find_impact_pos(), linear_velocity)


func _find_impact_pos() -> Vector3:
	## Find the best impact position — raycast down and along the tilt to find ground.
	var space_state := get_world_3d().direct_space_state

	# Try several ray directions from the body to find where it's hitting ground
	var ray_origins: Array[Vector3] = [
		global_position,
		global_position + global_transform.basis.y * section_height * 0.4,
		global_position - global_transform.basis.y * section_height * 0.4,
	]

	for origin in ray_origins:
		var ray := PhysicsRayQueryParameters3D.create(
			origin,
			origin + Vector3(0, -section_height * 1.5, 0),
			0xFFFFFFFF,
			[get_rid()]
		)
		var result := space_state.intersect_ray(ray)
		if result.size() > 0:
			return result["position"]

	# Fallback: estimate from current position
	return global_position - Vector3(0, section_height * 0.3, 0)


func _raycast_ground_check() -> Vector3:
	## Cast rays from the body's extremities to detect ground contact.
	## Returns the hit position, or Vector3.ZERO if no ground found nearby.
	var space_state := get_world_3d().direct_space_state

	# The body is a tipping cylinder — check from the top and bottom ends
	# along their current orientations. The local Y axis is the cylinder's
	# long axis, so the ends are at +/- section_height/2 along basis.y.
	var half_h := section_height * 0.45
	var tip_top := global_position + global_transform.basis.y * half_h
	var tip_bottom := global_position - global_transform.basis.y * half_h

	# Check if either tip is near the ground (within 2m)
	for tip in [tip_top, tip_bottom]:
		var ray := PhysicsRayQueryParameters3D.create(
			tip,
			tip + Vector3(0, -2.5, 0),
			0xFFFFFFFF,
			[get_rid()]
		)
		var result := space_state.intersect_ray(ray)
		if result.size() > 0:
			# Make sure it's not the tower terrain
			var collider = result.get("collider")
			if collider != _tower_terrain:
				return result["position"]

	return Vector3.ZERO


func _do_impact(impact_pos: Vector3, impact_velocity: Vector3) -> void:
	if _has_impacted:
		return
	_has_impacted = true

	var impact_speed := impact_velocity.length()
	var mass_factor: float = section_height / 40.0

	print("[TowerToppleBody] Impact at %s (speed: %.1f, section: %.1fm)" % [
		str(impact_pos), impact_speed, section_height])

	# --- 1. Main impact explosion damage ---
	var base_damage: float = impact_speed * mass_factor * EXPLOSION_DAMAGE_MULT
	var blast_radius: float = minf(3.0 + section_height * 0.3, MAX_BLAST_RADIUS)

	_do_explosion_damage(impact_pos, base_damage, blast_radius)

	# --- 2. Terrain crater ---
	var seed_world := _find_seed_world()
	if seed_world and seed_world.has_method("create_crater"):
		seed_world.create_crater(impact_pos, blast_radius * 0.5, 2.0, attacker_id)

	# --- 3. Generate chunk data ---
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var chunk_count := rng.randi_range(CHUNK_COUNT_MIN, CHUNK_COUNT_MAX)
	chunk_count = mini(chunk_count + int(section_height / 10.0), 10)

	var chunk_sizes: Array = []
	var chunk_impulses: Array = []

	for i in chunk_count:
		var size: float = rng.randf_range(1.0, 1.5 + section_height * 0.05)
		chunk_sizes.append(size)

		var scatter := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(0.2, 0.8),
			rng.randf_range(-1.0, 1.0)
		).normalized()
		var impulse: Vector3 = impact_velocity * 0.3 + scatter * 8.0 + Vector3(0, 3.0, 0)
		chunk_impulses.append(impulse)

	# --- 4. Tell tower to spawn chunks on all clients ---
	var tower := _find_tower()
	if tower and tower.has_method("_sync_collapse_impact"):
		tower._sync_collapse_impact.rpc(
			impact_pos, impact_velocity, chunk_count, chunk_sizes, chunk_impulses
		)

	# --- 5. Remove self ---
	queue_free()


func _do_explosion_damage(pos: Vector3, damage: float, radius: float) -> void:
	var space_state := get_world_3d().direct_space_state
	var already_damaged: Array = []

	var sphere_params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	sphere_params.shape = sphere
	sphere_params.transform = Transform3D(Basis.IDENTITY, pos)
	sphere_params.collision_mask = 0xFFFFFFFF

	var results := space_state.intersect_shape(sphere_params, 32)
	for result in results:
		var collider: Node = result["collider"]
		if collider == self:
			continue
		var target := _find_damageable(collider)
		if target and target not in already_damaged:
			if target.has_method("take_damage_at"):
				target.take_damage_at(pos, damage, radius, attacker_id)
				already_damaged.append(target)
			else:
				var dist := pos.distance_to(target.global_position)
				var falloff := clampf(1.0 - (dist / radius), 0.0, 1.0)
				var dmg := damage * falloff
				if dmg > 0.5:
					target.take_damage(dmg, attacker_id)
					already_damaged.append(target)

	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		for child in structures.get_children():
			if child in already_damaged:
				continue
			if child.has_method("take_damage_at"):
				var dist := pos.distance_to(child.global_position)
				var wall_reach: float = 0.0
				if "wall_size" in child:
					wall_reach = child.wall_size.length() * 0.5
				if dist <= radius + wall_reach:
					child.take_damage_at(pos, damage, radius, attacker_id)
					already_damaged.append(child)


func _find_damageable(node: Node) -> Node:
	var current := node
	var first_damageable: Node = null
	for _i in 4:
		if current == null:
			break
		if current.has_method("take_damage_at"):
			return current
		if first_damageable == null and current.has_method("take_damage"):
			first_damageable = current
		current = current.get_parent()
	return first_damageable


func _find_seed_world() -> Node:
	var sw := get_tree().current_scene.get_node_or_null("SeedWorld")
	if sw == null:
		sw = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	return sw


func _find_tower() -> Node:
	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		return structures.get_node_or_null("SpiralTower")
	return null
