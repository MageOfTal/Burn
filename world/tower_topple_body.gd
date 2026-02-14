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

const IMPACT_MIN_SPEED := 6.0          ## Base minimum speed to count as impact (when upright)
const IMPACT_MIN_SPEED_TILTED := 1.5   ## Minimum speed when fully horizontal (heavily tilted)
const MAX_TOPPLE_TIME := 20.0          ## Safety timeout — force breakup
const IMMUNITY_TIME := 3.0             ## Ignore everything for this long after spawn
const SETTLE_TIME := 10.0              ## After this long, break up even if slow (it settled)
const SHATTER_MIN_SPEED := 2.0         ## Below this speed at impact, no chunk breakup — just damage + stay whole
const CHUNK_COUNT_MIN := 4
const CHUNK_COUNT_MAX := 8

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
	var speed := linear_velocity.length()
	var angular_speed := angular_velocity.length()

	# Tilt factor: 0.0 = upright, 1.0 = fully horizontal/inverted.
	# The more tilted the tower is, the easier it should shatter on contact.
	var tilt := _get_tilt_factor()
	# Effective speed threshold decreases as the tower tilts further.
	# Upright: need full IMPACT_MIN_SPEED. Horizontal: only need IMPACT_MIN_SPEED_TILTED.
	var effective_min_speed := lerpf(IMPACT_MIN_SPEED, IMPACT_MIN_SPEED_TILTED, tilt)
	# Angular threshold also scales — a heavily tilted tower rotating slowly is still impacting.
	var effective_min_angular := lerpf(2.0, 0.5, tilt)

	# Method 1: If the body has contacts and sufficient speed/rotation, it's impacting.
	var contact_count := get_contact_count()
	if contact_count > 0 and (speed > effective_min_speed or angular_speed > effective_min_angular):
		# Check if any contact is NOT the tower terrain
		var has_ground_contact := false
		var colliders := get_colliding_bodies()
		for c in colliders:
			if c != _tower_terrain:
				has_ground_contact = true
				break
		if has_ground_contact:
			_contact_frames += 1
			# Less frames needed when heavily tilted (impact is more obvious)
			var frames_needed := int(lerpf(8.0, 3.0, tilt))
			if _contact_frames >= frames_needed:
				print("[TowerToppleBody] Ground contact impact! speed=%.1f angular=%.1f tilt=%.2f timer=%.1f" % [
					speed, angular_speed, tilt, _topple_timer])
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
	if _topple_timer > IMMUNITY_TIME + 0.5:
		var hit_pos := _raycast_ground_check()
		if hit_pos != Vector3.ZERO and (speed > effective_min_speed or angular_speed > effective_min_angular):
			print("[TowerToppleBody] Raycast ground hit! speed=%.1f tilt=%.2f timer=%.1f" % [speed, tilt, _topple_timer])
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
	var tilt := _get_tilt_factor()
	var effective_min_speed := lerpf(IMPACT_MIN_SPEED, IMPACT_MIN_SPEED_TILTED, tilt)
	var effective_min_angular := lerpf(2.0, 0.5, tilt)
	if speed < effective_min_speed and angular_speed < effective_min_angular:
		return

	print("[TowerToppleBody] body_entered impact! speed=%.1f tilt=%.2f body=%s timer=%.1f" % [
		speed, tilt, body.name, _topple_timer])
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

	print("[TowerToppleBody] Impact at %s (speed: %.1f, mass: %.0f, section: %.1fm)" % [
		str(impact_pos), impact_speed, mass, section_height])

	# --- 1. Check if impact is forceful enough to shatter ---
	# A gentle/slow fall should NOT break the tower into chunks. The topple body
	# just stays as-is (a big piece of rubble). No explosion here — individual
	# fragments create their own explosions when they hit the ground.
	if impact_speed < SHATTER_MIN_SPEED:
		print("[TowerToppleBody] Gentle impact (speed %.1f < %.1f) — no shatter, staying whole" % [
			impact_speed, SHATTER_MIN_SPEED])
		freeze = true
		return

	# --- 2. Generate chunk data (for legacy rock fallback only) ---
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
			rng.randf_range(-0.1, 0.3),
			rng.randf_range(-1.0, 1.0)
		).normalized()
		var impulse: Vector3 = scatter * rng.randf_range(3.0, 6.0)
		chunk_impulses.append(impulse)

	# --- 3. Tell tower to spawn chunks on all clients ---
	# Pass global_transform and current velocities so fragments inherit the
	# topple body's inertia and continue falling naturally. Each fragment
	# handles its own ground impact, explosion damage, and crater creation.
	var body_xform: Transform3D = global_transform
	var tower := _find_tower()
	if tower and tower.has_method("_sync_collapse_impact"):
		tower._sync_collapse_impact.rpc(
			impact_pos, impact_velocity, chunk_count, chunk_sizes, chunk_impulses,
			body_xform, linear_velocity, angular_velocity, mass
		)

	# --- 4. Remove self ---
	queue_free()


func _find_tower() -> Node:
	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
	if structures:
		return structures.get_node_or_null("SpiralTower")
	return null


func _get_tilt_factor() -> float:
	## Returns 0.0 when the tower is upright, 1.0 when fully horizontal or inverted.
	## The local Y axis is the cylinder's long axis. When upright, basis.y ≈ Vector3.UP.
	## dot(basis.y, UP) = 1.0 upright, 0.0 horizontal, -1.0 inverted.
	var uprightness := global_transform.basis.y.dot(Vector3.UP)
	# Remap: 1.0 (upright) → 0.0, 0.0 (horizontal) → 1.0, -1.0 (inverted) → 1.0
	return clampf(1.0 - uprightness, 0.0, 1.0)
