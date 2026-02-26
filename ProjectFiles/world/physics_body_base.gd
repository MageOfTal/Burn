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
## clusters, slabs, etc.). See CollisionLayers.DEFAULT_PHYSICS.
const DEFAULT_PHYSICS_MASK := CollisionLayers.DEFAULT_PHYSICS

## Collision mask for projectiles and projectile-like objects (rockets, rubber
## balls, bubbles, toads). See CollisionLayers.PROJECTILE_PHYSICS.
const PROJECTILE_PHYSICS_MASK := CollisionLayers.PROJECTILE_PHYSICS

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
#  Impact damage (opt-in)
# ======================================================================

## Set true on subclasses to enable base-class impact damage processing.
## Subclasses with specialized impact logic (falling_block_cluster, tower_chunk)
## should keep this false and handle their own _on_body_entered() callbacks.
@export var impact_damage_enabled := false

## Minimum speed (m/s) to trigger impact damage.
@export var impact_min_speed := 5.0

## Damage = impact_speed * sqrt(mass) * impact_damage_mult
@export var impact_damage_mult := 1.5

## Maximum impact damage events before this body stops dealing impact damage.
@export var impact_max_events := 3

## Seconds between impacts (prevents rapid repeated damage from the same contact).
const IMPACT_COOLDOWN := 0.2

var _impact_cooldown_timer: float = 0.0
var _impact_events_used: int = 0

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

	# Tick impact cooldown
	if _impact_cooldown_timer > 0.0:
		_impact_cooldown_timer -= delta

	# If this body masks layer 10 (player physics push layer), Jolt handles push
	# transfer natively via its contact solver. Skip manual polling to avoid
	# double-pushing the player.
	if collision_mask & CollisionLayers.PLAYERS_PUSH:
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
	query.collision_mask = CollisionLayers.ALL_PLAYERS
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


# ======================================================================
#  Impact damage — opt-in body_entered handler
# ======================================================================

func _on_impact_body_entered(body: Node) -> void:
	## Generic impact damage callback. Connect to body_entered signal on subclasses
	## that set impact_damage_enabled = true. Requires contact_monitor = true.
	##
	## Damage formula: impact_speed * sqrt(mass) * impact_damage_mult
	## Same formula used by tower_chunk.gd for consistency.
	if not impact_damage_enabled or not multiplayer.is_server():
		return
	if _impact_cooldown_timer > 0.0:
		return
	if _impact_events_used >= impact_max_events:
		return

	var impact_speed := linear_velocity.length()
	if body is RigidBody3D:
		impact_speed = (linear_velocity - body.linear_velocity).length()

	if impact_speed < impact_min_speed:
		return

	var base_damage: float = impact_speed * sqrt(mass) * impact_damage_mult
	_impact_cooldown_timer = IMPACT_COOLDOWN
	_impact_events_used += 1

	# Deal damage to the target
	if body.has_method("take_damage_at"):
		body.take_damage_at(global_position, base_damage, 0.5, -1)
	elif body.has_method("take_damage"):
		body.take_damage(base_damage, -1)
