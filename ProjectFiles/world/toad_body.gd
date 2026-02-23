extends PhysicsBodyBase

## A single toad rain body — a physics-simulated frog that falls from the sky,
## bounces once off the floor, then phases through the ground and despawns.
##
## Mass: 2.0 kg (1/40th of the player's 80 kg).
##
## Collision layer 7 (toad bodies), masks layer 1 (world) + layer 10 (player
## RigidBody3D). The player is an 80 kg RigidBody3D on layers 128|512.
## Jolt handles the collision natively — correct contact normals, edge
## deflections, mass-weighted impulse exchange via the solver delta pattern.
##
## No intersect_shape polling, no manual impulse math in toad code. Toads just
## collide with things and Jolt does the rest. O(collisions) not O(toads).
##
## NOTE: The player is a RigidBody3D, NOT a StaticBody3D. So the
## `body is StaticBody3D` check for floor bounce correctly excludes it.
##
## After the first bounce the toad is fully removed from Jolt's physics
## simulation (frozen + collision shape disabled) and its fall + tumble is
## animated manually. This keeps post-bounce toads out of Jolt's broadphase
## BVH entirely, preventing thousands of dead bodies from bloating physics
## queries during heavy toad rain.

const TOAD_MASS: float = 4.0          ## 1/20th of player mass (80 kg)
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

## Debug: previous frame velocity for delta tracking
var _debug_prev_vel: Vector3 = Vector3.ZERO

## Y squish factor for the toad ellipsoid (visual mesh height / radius).
## SphereMesh(radius=1.0, height=1.3) has built-in 0.65 Y ratio;
## body_mesh.scale.y = body_scale * 0.65 → total Y extent = radius * 0.65 * 0.65 = radius * 0.4225.
const ELLIPSOID_Y_RATIO: float = 0.4225

## Create a ConvexPolygonShape3D approximating an oblate ellipsoid.
## Jolt cannot non-uniformly scale SphereShape3D, so we bake the squish into vertices.
static func create_ellipsoid_shape(radius_xz: float, radius_y: float, num_rings: int = 6, num_segments: int = 8) -> ConvexPolygonShape3D:
	var points := PackedVector3Array()
	# Poles
	points.append(Vector3(0.0, radius_y, 0.0))
	points.append(Vector3(0.0, -radius_y, 0.0))
	# Intermediate rings
	for ring in range(1, num_rings):
		var phi: float = PI * float(ring) / float(num_rings)
		var y: float = radius_y * cos(phi)
		var r: float = radius_xz * sin(phi)
		for seg in range(num_segments):
			var theta: float = TAU * float(seg) / float(num_segments)
			points.append(Vector3(r * cos(theta), y, r * sin(theta)))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	return shape


## Debug: frame counter for rate-limiting persistent toad ground logs
var _debug_ground_frame: int = 0

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var contact_count := state.get_contact_count()

	# --- Persistent toad ground-contact diagnostics ---
	if persistent and contact_count > 0 and GameManager.debug_toad_show_hitboxes:
		_debug_ground_frame += 1
		var spd := state.get_linear_velocity().length()
		# Only log when nearly at rest, once per second (~60 physics frames)
		if spd < 0.5 and _debug_ground_frame % 60 == 0:
			var col_shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
			var y_half_extent: float = 0.0
			if col_shape_node and col_shape_node.shape:
				# ConvexPolygonShape3D — get Y extent from AABB
				var aabb := col_shape_node.shape.get_debug_mesh().get_aabb()
				y_half_extent = aabb.size.y * 0.5

			print("[TOAD_GROUND %s] center_y=%.4f y_half=%.4f rot=(%.2f,%.2f,%.2f) spd=%.3f" % [
				name, global_position.y, y_half_extent,
				rotation_degrees.x, rotation_degrees.y, rotation_degrees.z, spd])

			for i in contact_count:
				var collider := state.get_contact_collider_object(i)
				if collider is StaticBody3D or collider is AnimatableBody3D:
					var c_pos: Vector3 = state.get_contact_collider_position(i)
					var c_local: Vector3 = state.get_contact_local_position(i)
					var c_normal: Vector3 = state.get_contact_local_normal(i)
					print("  [GROUND_CONTACT %d] world_pos=(%.4f,%.4f,%.4f) local_pos=(%.4f,%.4f,%.4f) normal=(%.3f,%.3f,%.3f) n.y=%.3f" % [
						i, c_pos.x, c_pos.y, c_pos.z,
						c_local.x, c_local.y, c_local.z,
						c_normal.x, c_normal.y, c_normal.z, c_normal.y])

	if not GameManager.debug_toad_contacts:
		return

	if contact_count == 0:
		return

	# Only log if a player is among our contacts (avoid spamming for every toad)
	var has_player_contact := false
	for i in contact_count:
		var collider := state.get_contact_collider_object(i)
		if collider is Player:
			has_player_contact = true
			break
	if not has_player_contact:
		return

	var my_vel := state.get_linear_velocity()
	var vel_delta := my_vel - _debug_prev_vel
	_debug_prev_vel = my_vel

	# Classify each contact
	var player_contacts := 0
	var static_contacts := 0
	var other_contacts := 0
	var total_impulse := Vector3.ZERO
	var ground_impulse := Vector3.ZERO
	var player_impulse := Vector3.ZERO

	print("[TOAD_SELF %s] %d contacts | vel=(%.3f,%.3f,%.3f) vel_delta=(%.4f,%.4f,%.4f) |vel|=%.3f pos=(%.2f,%.2f,%.2f) frozen=%s" % [
		name, contact_count,
		my_vel.x, my_vel.y, my_vel.z,
		vel_delta.x, vel_delta.y, vel_delta.z,
		my_vel.length(),
		global_position.x, global_position.y, global_position.z,
		str(freeze)])

	for i in contact_count:
		var normal: Vector3 = state.get_contact_local_normal(i)
		var impulse: Vector3 = state.get_contact_impulse(i)
		var collider := state.get_contact_collider_object(i)
		var contact_pos: Vector3 = state.get_contact_collider_position(i)
		total_impulse += impulse

		var collider_type: String
		var collider_name: String = collider.name if collider else "null"
		var collider_vel: Vector3 = Vector3.ZERO
		var collider_mass: float = 0.0

		if collider is Player:
			collider_vel = collider.linear_velocity
			collider_mass = collider.mass
			collider_type = "PLAYER"
			player_contacts += 1
			player_impulse += impulse
		elif collider is RigidBody3D:
			collider_vel = collider.linear_velocity
			collider_mass = collider.mass
			collider_type = "DYNAMIC"
			other_contacts += 1
		elif collider is StaticBody3D:
			collider_type = "STATIC"
			static_contacts += 1
			ground_impulse += impulse
		elif collider is AnimatableBody3D:
			collider_type = "ANIMATABLE"
			static_contacts += 1
			ground_impulse += impulse
		else:
			collider_type = "UNKNOWN"
			other_contacts += 1

		# Contact normal dot with Y tells us if this is a floor-like or side-like contact
		var angle_deg := rad_to_deg(normal.angle_to(Vector3.UP))

		# Compute closing velocity along contact normal (positive = approaching)
		var my_vel_along_n := my_vel.dot(normal)
		var col_vel_along_n := collider_vel.dot(normal)
		var closing_speed := my_vel_along_n - col_vel_along_n

		print("  [%d] %s %s n=(%.3f,%.3f,%.3f) n.y=%.3f angle=%.1f° impulse=(%.4f,%.4f,%.4f) |imp|=%.4f closing_v=%.3f col_vel=(%.3f,%.3f,%.3f) col_mass=%.1f pos=(%.2f,%.2f,%.2f)" % [
			i, collider_type, collider_name,
			normal.x, normal.y, normal.z, normal.y, angle_deg,
			impulse.x, impulse.y, impulse.z, impulse.length(),
			closing_speed,
			collider_vel.x, collider_vel.y, collider_vel.z,
			collider_mass,
			contact_pos.x, contact_pos.y, contact_pos.z])

	# Summary line showing the balance of forces
	var net_impulse := total_impulse
	print("  [TOAD_FORCES] player_imp=(%.4f,%.4f,%.4f) ground_imp=(%.4f,%.4f,%.4f) net=(%.4f,%.4f,%.4f) |net|=%.4f  contacts: %d player, %d static, %d other" % [
		player_impulse.x, player_impulse.y, player_impulse.z,
		ground_impulse.x, ground_impulse.y, ground_impulse.z,
		net_impulse.x, net_impulse.y, net_impulse.z, net_impulse.length(),
		player_contacts, static_contacts, other_contacts])

	# If player pushing but ground absorbing, flag it
	if player_contacts > 0 and static_contacts > 0 and my_vel.length() < 0.5:
		var player_push_mag := player_impulse.length()
		var ground_resist_mag := ground_impulse.length()
		print("  [TOAD_STUCK!] Player impulse %.4f absorbed by ground impulse %.4f — toad vel %.3f" % [
			player_push_mag, ground_resist_mag, my_vel.length()])


func _ready() -> void:
	add_to_group("toad_bodies")
	if GameManager.debug_toad_show_hitboxes:
		_create_hitbox_mesh()
	mass = GameManager.debug_toad_mass
	gravity_scale = 2.0  ## 2x gravity (matches original TOAD_GRAVITY = 19.6)
	lock_rotation = false
	continuous_cd = true  ## Prevent tunneling through ground when hit by heavy shadow body
	# PhysicsMaterial (bounce=0.3, friction=0.5) is set in toad_body.tscn

	# Wire collision signal for bounce detection (server only)
	if multiplayer.is_server() and not _physics_disabled:
		contact_monitor = true
		max_contacts_reported = 8  # Need enough for ground + player + other contacts simultaneously
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
	# The player is a RigidBody3D, so this check correctly excludes it —
	# toads bounce off the player without triggering the post-bounce freeze.
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
	## Add a transparent mesh matching the actual CollisionShape3D.
	var col_shape_node := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col_shape_node == null or col_shape_node.shape == null:
		return

	# Lazy-init shared material (one allocation for all toads)
	if _hitbox_mat == null:
		_hitbox_mat = StandardMaterial3D.new()
		_hitbox_mat.albedo_color = Color(0.2, 0.4, 1.0, 0.35)
		_hitbox_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_hitbox_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hitbox_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_hitbox_mat.no_depth_test = true

	_hitbox_mesh = MeshInstance3D.new()
	_hitbox_mesh.name = "HitboxDebug"

	var shape := col_shape_node.shape
	if shape is SphereShape3D:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = shape.radius
		sphere_mesh.height = shape.radius * 2.0
		_hitbox_mesh.mesh = sphere_mesh
	elif shape is BoxShape3D:
		var box_mesh := BoxMesh.new()
		box_mesh.size = shape.size
		_hitbox_mesh.mesh = box_mesh
	elif shape is CapsuleShape3D:
		var capsule_mesh := CapsuleMesh.new()
		capsule_mesh.radius = shape.radius
		capsule_mesh.height = shape.height
		_hitbox_mesh.mesh = capsule_mesh
	elif shape is CylinderShape3D:
		var cyl_mesh := CylinderMesh.new()
		cyl_mesh.top_radius = shape.radius
		cyl_mesh.bottom_radius = shape.radius
		cyl_mesh.height = shape.height
		_hitbox_mesh.mesh = cyl_mesh
	else:
		_hitbox_mesh.mesh = shape.get_debug_mesh()

	_hitbox_mesh.material_override = _hitbox_mat
	_hitbox_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Add as child of CollisionShape3D so it inherits runtime scale changes
	# (e.g. permatoad spawners set col_shape.scale after _ready)
	col_shape_node.add_child(_hitbox_mesh)


func set_hitbox_visible(visible: bool) -> void:
	## Show or hide the debug hitbox visualization.
	if visible and _hitbox_mesh == null:
		_create_hitbox_mesh()
	elif not visible and _hitbox_mesh != null:
		_hitbox_mesh.queue_free()
		_hitbox_mesh = null
