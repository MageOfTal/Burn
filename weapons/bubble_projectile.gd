extends RigidBody3D

## Bubble projectile: a near-weightless soap bubble that floats, drifts, and
## blocks shots. Pops on bullet damage or high-energy collisions.
##
## Physics model:
##   - RigidBody3D with mass=0.1 (extremely light — trivially pushed by anything)
##   - Zero gravity (floats in place)
##   - High linear_damp (air resistance bleeds off speed quickly)
##   - Brownian drift: tiny random forces applied every 0.15s
##   - Soft bubble-on-bubble separation via forces (not hard collision)
##   - Players push bubbles by applying impulses from player.gd
##
## Collision layers:
##   Layer 3 (bit 4): bubble body — keeps bubbles off layer 1 so they don't
##     physically collide with players or each other. Only walls (layer 1) stop them.
##   Hitscan raycasts use mask 0xFFFFFFFF, so they hit layer 3 (bubbles get shot).
##
## Pop condition: kinetic energy (½mv²) exceeds threshold.
##   A heavy fast object (rocket, player running) pops easily.
##   Another drifting bubble barely registers. Walls pop on hard impact speed only.

const BUBBLE_MASS := 0.1                 ## kg — nearly weightless
const BUBBLE_RADIUS := 0.6              ## Visual/collision radius
const LIFETIME := 16.0                  ## Seconds before auto-pop
const LAUNCH_SPEED := 8.0               ## Initial launch speed (m/s)
const LINEAR_DAMP := 2.5                ## Air drag — bleeds speed. Higher = stops faster.
const NUDGE_STRENGTH := 0.5             ## Force of each random drift nudge
const NUDGE_INTERVAL := 0.12            ## Seconds between random drift nudges
const WIND_STRENGTH := 0.08            ## Gentle persistent horizontal wind force
const BOUNCE := 0.5                     ## Wall bounce coefficient (0=absorb, 1=perfect bounce)
const FRICTION := 0.0                   ## Surface friction (0=frictionless soap bubble)

## Pop thresholds based on kinetic energy (½mv²).
## Using energy means heavy fast objects pop bubbles easily,
## while lightweight slow drifting bubbles barely register.
const POP_ENERGY_WALL := 0.8            ## KE to pop on wall hit (speed ~4 m/s for bubble mass)
const POP_ENERGY_OBJECT := 2.0          ## KE to pop from another object hitting this bubble
const POP_ENERGY_BUBBLE := 5.0          ## KE to pop from bubble-on-bubble (very hard to pop)

## Soft bubble-on-bubble separation (applied as forces, not hard collision)
const BUBBLE_PUSH_STRENGTH := 4.0       ## Force pushing overlapping bubbles apart
const BUBBLE_SEPARATION := 1.3          ## Desired distance between bubble centers

## Identity flag — used by _is_bubble() so we don't confuse rubber balls for bubbles.
var is_bubble := true

var _shooter_id: int = -1
var _damage: float = 5.0
var _lifetime: float = 0.0
var _has_popped: bool = false
var _nudge_timer: float = 0.0
var _wind_dir: Vector3 = Vector3.ZERO   ## Per-bubble random wind direction


func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	## Called before adding to scene tree.
	_shooter_id = shooter_id
	_damage = damage
	# Set initial velocity — applied in _ready after physics setup
	linear_velocity = direction.normalized() * LAUNCH_SPEED


func _ready() -> void:
	_nudge_timer = randf_range(0.0, NUDGE_INTERVAL)
	# Each bubble gets a persistent random wind direction (horizontal only)
	_wind_dir = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0)).normalized()

	# --- Physics properties ---
	mass = BUBBLE_MASS
	gravity_scale = 0.0           # Floats in place — no gravity
	linear_damp = LINEAR_DAMP     # Air resistance
	angular_damp = 10.0           # Prevent chaotic spinning
	continuous_cd = true           # Prevent tunneling through thin walls
	lock_rotation = true           # Bubbles don't spin (visual wobble is cosmetic)

	# Bouncy frictionless physics material
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = BOUNCE
	phys_mat.friction = FRICTION
	physics_material_override = phys_mat

	# --- Collision layers ---
	# Layer 3 (bit 4): bubbles. NOT on layer 1, so players don't physically collide.
	# Mask layer 1: collide with world/terrain/structures only.
	collision_layer = 4   # Layer 3
	collision_mask = 1    # World only

	# Contact monitoring for pop-on-impact detection
	contact_monitor = true
	max_contacts_reported = 4
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)

	# --- Visual material ---
	var mesh_inst := get_node_or_null("MeshInstance3D")
	if mesh_inst:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.7, 0.85, 1.0, 0.25)
		mat.metallic = 0.6
		mat.roughness = 0.1
		mat.emission_enabled = true
		mat.emission = Color(0.5, 0.7, 1.0)
		mat.emission_energy_multiplier = 0.3
		mat.rim_enabled = true
		mat.rim = 0.8
		mat.rim_tint = 0.3
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_inst.material_override = mat


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	_lifetime += delta
	if _lifetime >= LIFETIME and not _has_popped:
		_pop()
		return

	# --- Gentle persistent wind (horizontal only, no upward drift) ---
	apply_central_force(_wind_dir * WIND_STRENGTH)

	# --- Brownian drift: random forces for organic, wandering motion ---
	_nudge_timer -= delta
	if _nudge_timer <= 0.0:
		var nudge := Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.3, 0.3),
			randf_range(-1.0, 1.0)
		) * NUDGE_STRENGTH
		apply_central_force(nudge)
		# Slowly rotate wind direction for long-lived bubbles
		_wind_dir = _wind_dir.rotated(Vector3.UP, randf_range(-0.2, 0.2))
		_nudge_timer = NUDGE_INTERVAL

	# --- Soft bubble-on-bubble separation ---
	# Bubbles don't physically collide (different layer), so we apply
	# gentle forces to push overlapping bubbles apart.
	_push_apart_from_bubbles()

	# --- Check for player overlap (damage + pop) ---
	# Bubbles don't physically collide with players (different layers),
	# so we check proximity manually and deal damage on overlap.
	_check_player_overlap()


func _on_body_entered(body: Node) -> void:
	## Server-only: something physically touched this bubble.
	## Check kinetic energy to decide if we should pop.
	if not multiplayer.is_server() or _has_popped:
		return

	# Ignore the shooter briefly (prevent self-pop on spawn)
	if _lifetime < 0.15 and body is CharacterBody3D and body.name.to_int() == _shooter_id:
		return

	# Calculate collision kinetic energy.
	# For the bubble itself: KE = ½ * mass * speed²
	# For the other body, we estimate its KE crashing into us.
	var bubble_speed := linear_velocity.length()
	var bubble_ke := 0.5 * mass * bubble_speed * bubble_speed

	if _is_bubble(body):
		# Bubble-on-bubble: use combined relative KE, very high threshold
		# _is_bubble() guarantees body is RigidBody3D, so cast is safe
		var other_body: RigidBody3D = body as RigidBody3D
		# Relative speed approximation
		var rel_speed: float = (linear_velocity - other_body.linear_velocity).length()
		var rel_ke := 0.5 * mass * rel_speed * rel_speed
		if rel_ke > POP_ENERGY_BUBBLE:
			_pop()
		return

	# For non-bubble bodies, estimate the impactor's KE
	var impactor_ke := 0.0
	if body is RigidBody3D:
		impactor_ke = 0.5 * body.mass * body.linear_velocity.length_squared()
	elif body is CharacterBody3D:
		# Players: estimate mass ~80kg
		var player_speed: float = body.velocity.length()
		impactor_ke = 0.5 * 80.0 * player_speed * player_speed

	# Use the larger of: our own KE hitting the object, or the object's KE hitting us
	var collision_ke := maxf(bubble_ke, impactor_ke)

	if body is StaticBody3D:
		# Wall/terrain: pop based on our own impact speed
		if bubble_ke > POP_ENERGY_WALL:
			_pop()
	else:
		# Dynamic object (player, rocket, ball): use combined energy
		if collision_ke > POP_ENERGY_OBJECT:
			_pop()


func _is_bubble(node: Node) -> bool:
	return node is RigidBody3D and node != self and node.get("is_bubble") == true


func _push_apart_from_bubbles() -> void:
	## Soft separation forces between nearby bubbles.
	## Since bubbles are on layer 3 and DON'T have layer 3 in their mask,
	## they pass through each other. This force prevents overlap.
	var container := get_parent()
	if container == null:
		return

	for child in container.get_children():
		if child == self or not _is_bubble(child):
			continue
		if not is_instance_valid(child):
			continue

		var other: RigidBody3D = child as RigidBody3D
		var to_other: Vector3 = other.global_position - global_position
		var dist: float = to_other.length()

		if dist < 0.001:
			to_other = Vector3(randf_range(-1, 1), randf_range(-0.2, 0.2), randf_range(-1, 1)).normalized()
			dist = 0.001

		if dist < BUBBLE_SEPARATION:
			var overlap := 1.0 - (dist / BUBBLE_SEPARATION)
			var push_dir := -to_other.normalized()
			# Apply as a force (not impulse) — smooth continuous push
			apply_central_force(push_dir * BUBBLE_PUSH_STRENGTH * overlap)


func _check_player_overlap() -> void:
	## Check if any player is overlapping the bubble. If so, deal damage and pop.
	## Ignore the shooter briefly after launch to prevent self-damage.
	if _has_popped:
		return

	var players_container := get_tree().current_scene.get_node_or_null("Players")
	if players_container == null:
		return

	var hit_radius: float = BUBBLE_RADIUS + 0.4  # bubble radius + player capsule radius
	for child in players_container.get_children():
		if not child is CharacterBody3D:
			continue
		# Ignore the shooter for 0.15s (prevent self-pop on launch)
		if _lifetime < 0.15 and child.name.to_int() == _shooter_id:
			continue
		var dist: float = global_position.distance_to(child.global_position + Vector3(0, 0.8, 0))
		if dist < hit_radius:
			if child.has_method("take_damage"):
				child.take_damage(_damage, _shooter_id)
			_pop()
			return


func take_damage(_amount: float, _attacker_id: int) -> void:
	## Any bullet damage pops the bubble instantly.
	if not _has_popped:
		_pop()


func apply_push_impulse(impulse: Vector3) -> void:
	## Public API for external systems (player push, explosions) to push this bubble.
	## Uses apply_central_impulse for instant velocity change.
	if not _has_popped:
		apply_central_impulse(impulse)


func _pop() -> void:
	if _has_popped:
		return
	_has_popped = true

	if multiplayer.is_server():
		_show_pop_fx.rpc(global_position)

	queue_free()


@rpc("authority", "call_local", "unreliable")
func _show_pop_fx(pos: Vector3) -> void:
	var scene_root := get_tree().current_scene

	var pop_sphere := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = BUBBLE_RADIUS
	sphere_mesh.height = BUBBLE_RADIUS * 2.0
	pop_sphere.mesh = sphere_mesh
	pop_sphere.top_level = true

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.8, 0.9, 1.0, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.8, 1.0)
	mat.emission_energy_multiplier = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pop_sphere.material_override = mat
	scene_root.add_child(pop_sphere)
	pop_sphere.global_position = pos

	var flash := OmniLight3D.new()
	flash.light_color = Color(0.6, 0.8, 1.0)
	flash.light_energy = 2.0
	flash.omni_range = 3.0
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(pop_sphere, "scale", Vector3.ONE * 2.0, 0.2).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.2)
	tween.tween_property(flash, "light_energy", 0.0, 0.15)
	tween.set_parallel(false)
	tween.tween_callback(pop_sphere.queue_free)
	tween.tween_callback(flash.queue_free)
