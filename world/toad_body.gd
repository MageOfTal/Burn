extends PhysicsBodyBase

## A single toad rain body — a physics-simulated frog that falls from the sky,
## bounces once off the floor, then phases through the ground and despawns.
##
## Mass: 2.0 kg (1/40th of the player's 80 kg).
##
## Collision layer 7 (toad bodies), masks layer 1 (world) + layer 10 (player
## shadow body). The shadow body is a dynamic 80 kg RigidBody3D that follows
## the player. Jolt handles the collision natively — correct contact normals,
## edge deflections, mass-weighted impulse exchange. The shadow body extracts
## the solver's impulse delta and transfers it to the player's CharacterBody3D.
##
## No intersect_shape polling, no manual impulse math in toad code. Toads just
## collide with things and Jolt does the rest. O(collisions) not O(toads).
##
## NOTE: The shadow body is a RigidBody3D, NOT a StaticBody3D. So the
## `body is StaticBody3D` check for floor bounce correctly excludes it.
##
## After the first bounce the toad is fully removed from Jolt's physics
## simulation (frozen + collision shape disabled) and its fall + tumble is
## animated manually. This keeps post-bounce toads out of Jolt's broadphase
## BVH entirely, preventing thousands of dead bodies from bloating physics
## queries during heavy toad rain.

const TOAD_MASS: float = 2.0          ## 1/40th of player mass (80 kg)
const DESPAWN_Y_OFFSET: float = -3.0  ## How far below the floor before queue_free()
const MAX_LIFETIME: float = 15.0      ## Safety net — despawn if stuck somehow
const POST_BOUNCE_GRAVITY: float = 19.6  ## 2x normal gravity (9.8 * 2), applied manually

var _has_bounced: bool = false
var _floor_y: float = -500.0   ## Set by ToadDimension on spawn
var _age: float = 0.0
var _physics_disabled: bool = false  ## When true, skip all Jolt physics — visual-only fall

## When true, the toad stays in Jolt physics forever — never disables collision
## after bouncing, never despawns from age or falling below floor. Used by the
## debug toad bowl so toads bounce around persistently.
var persistent: bool = false

## Post-bounce manual animation state (set when transitioning out of Jolt)
var _manual_velocity: Vector3 = Vector3.ZERO
var _manual_angular_vel: Vector3 = Vector3.ZERO

## Debug hitbox visualization
var _hitbox_mesh: MeshInstance3D = null
static var _hitbox_mat: StandardMaterial3D = null  ## Shared across all toads


func _ready() -> void:
	add_to_group("toad_bodies")
	if GameManager.debug_toad_show_hitboxes:
		_create_hitbox_mesh()
	mass = TOAD_MASS
	gravity_scale = 2.0  ## 2x gravity (matches original TOAD_GRAVITY = 19.6)
	lock_rotation = false
	continuous_cd = true  ## Prevent tunneling through ground when hit by heavy shadow body
	# PhysicsMaterial (bounce=0.3, friction=0.5) is set in toad_body.tscn

	# Wire collision signal for bounce detection (server only)
	if multiplayer.is_server() and not _physics_disabled:
		contact_monitor = true
		max_contacts_reported = 4
		body_entered.connect(_on_body_entered_toad)


func _physics_process(delta: float) -> void:
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

	# NOTE: We intentionally do NOT call super._physics_process(delta) here.
	# Toad → player push is handled entirely by Jolt's native solver via the
	# shadow body. No intersect_shape polling needed.

	if not multiplayer.is_server():
		return

	_age += delta

	# Persistent toads (toad bowl) never despawn or leave Jolt — skip all of this
	if persistent:
		return

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

	# Only count floor/wall collisions as a bounce (StaticBody3D = world geometry).
	# The shadow body is a RigidBody3D, so this check correctly excludes it —
	# toads bounce off the shadow body without freezing.
	if not (body is StaticBody3D):
		return

	# Persistent toads (toad bowl) stay in Jolt forever — don't freeze on bounce
	if persistent:
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


# ======================================================================
#  Debug hitbox visualization
# ======================================================================

func _create_hitbox_mesh() -> void:
	## Add a transparent wireframe sphere matching the collision shape radius.
	var col_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape == null or not (col_shape.shape is SphereShape3D):
		return
	var radius: float = (col_shape.shape as SphereShape3D).radius

	# Lazy-init shared material (one allocation for all toads)
	if _hitbox_mat == null:
		_hitbox_mat = StandardMaterial3D.new()
		_hitbox_mat.albedo_color = Color(1.0, 0.2, 0.2, 0.35)
		_hitbox_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hitbox_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hitbox_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_hitbox_mesh = MeshInstance3D.new()
	_hitbox_mesh.name = "HitboxDebug"
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	_hitbox_mesh.mesh = sphere
	_hitbox_mesh.material_override = _hitbox_mat
	_hitbox_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hitbox_mesh)


func set_hitbox_visible(visible: bool) -> void:
	## Show or hide the debug hitbox sphere.
	if visible and _hitbox_mesh == null:
		_create_hitbox_mesh()
	elif not visible and _hitbox_mesh != null:
		_hitbox_mesh.queue_free()
		_hitbox_mesh = null
