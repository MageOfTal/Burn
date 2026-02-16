extends PhysicsBodyBase

## A single toad rain body — a physics-simulated frog that falls from the sky,
## bounces once off the floor, then phases through the ground and despawns.
##
## Mass: 4.0 kg (1/20th of the player's 80 kg).
##
## Collision layer 7 (toad bodies), masks layer 1 (world) + layer 10 (player
## shadow body). Player push is handled natively by Jolt — toads collide with
## the player's ToadShadowBody (a dynamic 80kg RigidBody3D on layer 10) with
## proper mass-weighted momentum exchange. No intersect_shape polling needed.
##
## After the first bounce the toad is fully removed from Jolt's physics
## simulation (frozen + collision shape disabled) and its fall + tumble is
## animated manually. This keeps post-bounce toads out of Jolt's broadphase
## BVH entirely, preventing thousands of dead bodies from bloating physics
## queries during heavy toad rain.

const TOAD_MASS: float = 4.0          ## 1/20th of player mass (80 kg)
const DESPAWN_Y_OFFSET: float = -10.0 ## How far below the floor before queue_free()
const MAX_LIFETIME: float = 15.0      ## Safety net — despawn if stuck somehow
const POST_BOUNCE_GRAVITY: float = 19.6  ## 2x normal gravity (9.8 * 2), applied manually

var _has_bounced: bool = false
var _floor_y: float = -500.0   ## Set by ToadDimension on spawn
var _age: float = 0.0
var _physics_disabled: bool = false  ## When true, skip all Jolt physics — visual-only fall

## Pre-collision velocity snapshot — captured each physics frame before Jolt's
## solver runs. The ToadShadowBody reads this in body_entered (which fires
## post-solve, when linear_velocity is already post-bounce and useless for
## closing speed calculations).
var pre_collision_velocity: Vector3 = Vector3.ZERO

## Post-bounce manual animation state (set when transitioning out of Jolt)
var _manual_velocity: Vector3 = Vector3.ZERO
var _manual_angular_vel: Vector3 = Vector3.ZERO


func _ready() -> void:
	mass = TOAD_MASS
	gravity_scale = 2.0  ## 2x gravity (matches original TOAD_GRAVITY = 19.6)
	lock_rotation = false
	# PhysicsMaterial (bounce=0.3, friction=0.5) is set in toad_body.tscn

	# Wire collision signal for bounce detection (server only)
	if multiplayer.is_server() and not _physics_disabled:
		contact_monitor = true
		max_contacts_reported = 4
		body_entered.connect(_on_body_entered_toad)


func _physics_process(delta: float) -> void:
	# Snapshot velocity before Jolt's solver modifies it this frame.
	# ToadShadowBody reads this in body_entered (which fires post-solve).
	if not _has_bounced and not _physics_disabled:
		pre_collision_velocity = linear_velocity

	if _physics_disabled:
		# Visual-only mode: manual fall + tumble, no Jolt, no push queries
		if not multiplayer.is_server():
			return
		_age += delta
		if _age >= MAX_LIFETIME:
			queue_free()
			return
		_manual_velocity.y -= POST_BOUNCE_GRAVITY * delta
		global_position += _manual_velocity * delta
		rotation += _manual_angular_vel * delta
		if global_position.y < _floor_y + DESPAWN_Y_OFFSET:
			queue_free()
		return

	if not _has_bounced:
		# Toad-player collisions are handled natively by Jolt via the player's
		# ToadShadowBody (a dynamic 80kg RigidBody3D on layer 10). Toads bounce
		# off it through Jolt's solver with proper mass-weighted momentum exchange.
		# No intersect_shape needed.
		pass

	if not multiplayer.is_server():
		return

	_age += delta

	# Safety lifetime cap
	if _age >= MAX_LIFETIME:
		queue_free()
		return

	# After bouncing: manually animate fall + tumble (no longer in Jolt)
	if _has_bounced:
		_manual_velocity.y -= POST_BOUNCE_GRAVITY * delta
		global_position += _manual_velocity * delta
		# Simple tumble rotation
		rotation += _manual_angular_vel * delta

		if global_position.y < _floor_y + DESPAWN_Y_OFFSET:
			queue_free()


func _on_body_entered_toad(body: Node) -> void:
	if _has_bounced:
		return

	# Only count floor/wall collisions as a bounce (StaticBody3D = world geometry)
	if not (body is StaticBody3D):
		return

	_has_bounced = true

	# Capture current Jolt velocities before we freeze the body
	_manual_velocity = linear_velocity
	_manual_angular_vel = angular_velocity

	# Defer the actual physics removal — can't modify physics state mid-callback
	call_deferred("_remove_from_physics")


func _remove_from_physics() -> void:
	## Fully remove this toad from Jolt's simulation:
	## 1. Disable the collision shape → removes from broadphase BVH
	## 2. Freeze the body → stops Jolt from integrating velocity/gravity
	## The fall + tumble continues via manual animation in _physics_process.
	collision_layer = 0
	collision_mask = 0
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape:
		col_shape.disabled = true
	contact_monitor = false
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true


# ======================================================================
#  Physics / Shadow toggle support (called from ToadDimension)
# ======================================================================

func start_physics_disabled() -> void:
	## Put this toad into visual-only mode: no Jolt simulation, no collisions,
	## no push queries. The toad still falls and tumbles via manual animation.
	## Can be called before or after _ready().
	_physics_disabled = true

	# Capture current velocity for manual animation if the body was live
	if not _has_bounced and not freeze:
		_manual_velocity = linear_velocity
		_manual_angular_vel = angular_velocity

	# Remove from Jolt entirely
	collision_layer = 0
	collision_mask = 0
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape:
		col_shape.disabled = true
	contact_monitor = false
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	freeze = true


func restore_physics() -> void:
	## Re-enable physics on this toad. Only effective for toads that haven't
	## bounced yet — post-bounce toads are already out of Jolt permanently.
	if not _physics_disabled:
		return
	_physics_disabled = false

	if _has_bounced:
		# Already post-bounce — stay in manual animation mode, nothing to restore
		return

	# Re-enable Jolt simulation
	freeze = false
	collision_layer = 64   # Layer 7 (toad bodies)
	collision_mask = 513   # Layer 1 (world) | Layer 10 (player shadow body)
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape:
		col_shape.disabled = false
	if multiplayer.is_server():
		contact_monitor = true
		max_contacts_reported = 4
		if not body_entered.is_connected(_on_body_entered_toad):
			body_entered.connect(_on_body_entered_toad)

	# Restore velocity from manual animation
	linear_velocity = _manual_velocity
	angular_velocity = _manual_angular_vel


func set_shadows_enabled(enabled: bool) -> void:
	## Enable or disable shadow casting on all MeshInstance3D children.
	var shadow_mode: GeometryInstance3D.ShadowCastingSetting = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	for child in get_children():
		if child is MeshInstance3D:
			child.cast_shadow = shadow_mode
