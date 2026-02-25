extends RigidBody3D
class_name PhysicsBodyBase

## Base class for all game physics objects (tower chunks, bubbles, projectiles, etc.).
##
## Push interactions with players use one of two paths:
##
## 1. **Native Jolt collision (preferred):** If this body's collision_mask includes
##    layer 10 (512, the player's physics push layer), Jolt handles the collision
##    natively — correct contact normals, edge deflections, mass ratios, restitution.
##    The player is an 80 kg RigidBody3D on layer 10; Jolt resolves contact impulses
##    directly. No manual math needed.
##
## 2. **Polling fallback:** If this body does NOT mask layer 10, the base class polls
##    for Player (RigidBody3D) overlaps every 0.1s and applies the reduced-mass formula:
##      reduced_mass = (m_rigid * m_char) / (m_rigid + m_char)
##      impulse = (1 + restitution) * closing_speed * reduced_mass
##    This is a legacy path for objects that can't mask layer 10 for some reason.
##
## Objects that mask layer 10 automatically skip the polling path to avoid double-push.
##
## Usage: extend this class instead of RigidBody3D. Set mass and collision_layer.
## If overriding _physics_process(), call super._physics_process(delta) at the top.

# ======================================================================
#  Constants
# ======================================================================

## Default collision mask for solid physics objects (tower chunks, falling
## clusters, slabs, etc.). Covers: world terrain (1), significant items (2),
## bubbles (4), rubber balls (8), player physics push (512), smooth wall
## collision (2048). Excludes cosmetic layers (debris 32, toad bodies 64)
## and query-only layers (player targeting 128/256, wall block raycasts 1024).
## Spawners can add or remove layers as needed (e.g. | 32 for debris collision).
const DEFAULT_PHYSICS_MASK := 1 | 2 | 4 | 8 | 512 | 2048  # = 2575

## Collision mask for projectiles and projectile-like objects (rockets, rubber
## balls, bubbles, toads). Covers: world terrain (1), bubbles (4), player
## physics push (512), smooth wall collision (2048). Deliberately excludes
## debris (32), significant items (2), rubber balls (8), toad bodies (64),
## and all query-only layers. Individual projectiles add layers as needed
## (e.g. rubber ball adds | 2 for significant items).
const PROJECTILE_PHYSICS_MASK := 1 | 4 | 512 | 2048  # = 2565

## Assumed mass of a Player (80 kg RigidBody3D) for the reduced-mass formula.
const CHAR_EFFECTIVE_MASS := 80.0
## Coefficient of restitution: 0 = perfectly inelastic, 1 = perfectly elastic.
## 0.5 gives a moderate bounce — player is pushed but not launched to orbit.
const PUSH_RESTITUTION := 0.5
## Minimum closing speed to trigger a push. Filters out micro-overlaps from Jolt jitter.
const MIN_CLOSING_SPEED := 0.3
## Maximum velocity change applied to a character per push event.
const MAX_CHAR_PUSH_SPEED := 15.0
## How often to check for character overlaps (seconds). 10Hz is enough for smooth
## depenetration without burning CPU on 100+ bubbles all polling every frame.
const OVERLAP_CHECK_INTERVAL := 0.1
# ======================================================================
#  Internal state
# ======================================================================

var _push_check_timer: float = 0.0
## Cached collision shape for overlap queries (avoids get_children() every check).
var _cached_shape: Shape3D = null


# ======================================================================
#  Physics process — character overlap detection
# ======================================================================

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# If this body masks layer 10 (player physics push layer), Jolt handles push
	# transfer natively via its contact solver. Skip manual polling to avoid
	# double-pushing the player.
	if collision_mask & 512:
		return

	_push_check_timer -= delta
	if _push_check_timer > 0.0:
		return
	_push_check_timer = OVERLAP_CHECK_INTERVAL

	_check_character_overlaps()


func _check_character_overlaps() -> void:
	## Find all Player (RigidBody3D) nodes whose collision shapes overlap this body's
	## shape and apply mass-weighted push forces.
	## Uses Jolt's PhysicsDirectSpaceState3D.intersect_shape() — the actual hitbox
	## geometry determines overlap, not an arbitrary radius.
	## Runs every OVERLAP_CHECK_INTERVAL seconds on the server.

	# Get this body's first collision shape for the overlap query.
	if _cached_shape == null:
		_cached_shape = _get_first_shape()
	if _cached_shape == null:
		return

	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	# Build the shape query: use this body's exact shape at its current position.
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _cached_shape
	query.transform = global_transform
	query.collision_mask = 128 | 256  # Layer 8 (overworld) + layer 9 (toad dimension) players
	query.exclude = [get_rid()]  # Don't detect self
	query.collide_with_bodies = true

	var results := space_state.intersect_shape(query, 8)  # Up to 8 overlapping bodies

	for result in results:
		var collider = result.get("collider")
		if collider == null or not collider is Player:
			continue
		if not is_instance_valid(collider):
			continue

		# Compute contact normal: FROM rigid body TOWARD character center
		var char_center: Vector3 = collider.global_position + Vector3(0, 0.9, 0)
		var to_char: Vector3 = char_center - global_position
		var dist: float = to_char.length()
		if dist < 0.001:
			continue
		var contact_normal: Vector3 = to_char / dist

		# Since intersect_shape confirmed a real shape overlap, we know they're
		# penetrating. Estimate depth from center distance vs expected separation.
		# Player capsule radius ≈ 0.4, so at dist=0 they're fully inside.
		# This is used as a depenetration pseudo-velocity for stationary overlaps.
		var overlap_depth: float = maxf(0.4 - dist * 0.3, 0.0)

		_apply_character_push(collider, contact_normal, overlap_depth)


func _get_first_shape() -> Shape3D:
	## Return the first CollisionShape3D's shape found on this node, or null.
	for child in get_children():
		if child is CollisionShape3D and not child.disabled:
			return child.shape
	return null


func _apply_character_push(char_body: Player, contact_normal: Vector3,
		overlap_depth: float) -> void:
	## Apply mass-weighted impulse between this rigid body and a character.
	##
	## Uses the reduced-mass collision formula from classical mechanics:
	##   reduced_mass = (m_a * m_b) / (m_a + m_b)
	## This naturally handles asymmetry:
	##   - 0.1kg bubble vs 80kg player: reduced_mass ≈ 0.1 → tiny push
	##   - 300kg chunk vs 80kg player: reduced_mass ≈ 63 → massive push
	var relative_vel: Vector3 = linear_velocity - char_body.velocity
	# Closing speed: how fast they're approaching along the contact normal.
	# contact_normal points FROM rigid TOWARD char.
	# If rigid moves toward char, relative_vel aligns with contact_normal → positive dot.
	# Positive = approaching, negative = separating.
	var closing_speed: float = relative_vel.dot(contact_normal)

	# For stationary overlaps (e.g. player walks into a stopped chunk),
	# use overlap depth as pseudo-velocity so depenetration still works.
	if overlap_depth > 0.0:
		closing_speed = maxf(closing_speed, overlap_depth * 5.0)

	if closing_speed < MIN_CLOSING_SPEED:
		return

	var mass_rigid: float = mass
	var reduced_mass: float = (mass_rigid * CHAR_EFFECTIVE_MASS) / (mass_rigid + CHAR_EFFECTIVE_MASS)
	var impulse_magnitude: float = (1.0 + PUSH_RESTITUTION) * closing_speed * reduced_mass

	# Push the rigid body away from the character (Newton's 3rd law)
	# contact_normal points FROM rigid TOWARD char, so negate it for the rigid body.
	apply_central_impulse(-contact_normal * impulse_magnitude)

	# Push the character away from the rigid body (contact_normal already points toward char)
	var char_push: Vector3 = contact_normal * (impulse_magnitude / CHAR_EFFECTIVE_MASS)
	if char_push.length() > MAX_CHAR_PUSH_SPEED:
		char_push = char_push.normalized() * MAX_CHAR_PUSH_SPEED
	char_body.velocity += char_push
