extends Node
class_name KamikazeSystem

## Kamikaze Missile subsystem.
## Owns all kamikaze flight logic, explosion damage, VFX, and flashbang.
## Attached as a child of Player in player.tscn.

## --- Launch ---
const LAUNCH_SPEED := 45.0       ## Upward speed during launch phase (m/s)
const LAUNCH_DURATION := 2.5     ## Seconds of straight-up launch
## --- Flight ---
const REF_SPEED := 100.0          ## Reference speed for scaling damage/visuals (1.0 ratio)
const MIN_SPEED := 10.0          ## Minimum flight speed (can't stall)
const GRAVITY := 17.5            ## Gravity contribution to flight
const AIR_FRICTION := 0.12       ## Low drag — lets speed build up on long dives
const STEER_SPEED := 2.5         ## How fast the player can redirect flight direction
## --- Explosion ---
const MIN_DAMAGE := 40.0         ## Explosion damage at minimum speed
const MAX_DAMAGE := 300.0        ## Explosion damage at ref speed (scales beyond)
const MIN_RADIUS := 5.0          ## Explosion radius at minimum speed
const MAX_RADIUS := 24.0         ## Explosion radius at ref speed (scales beyond)
const MIN_FLASH_ENERGY := 12.0   ## Light energy at minimum speed
const MAX_FLASH_ENERGY := 80.0   ## Light energy at ref speed (scales beyond)
## --- Flashbang ---
const FLASH_MAX_RANGE := 40.0    ## Max distance for flashbang to affect players
const FLASH_MAX_DURATION := 4.0  ## Max flashbang duration in seconds
const FLASH_DOT_THRESHOLD := 0.3 ## Min dot product (looking toward explosion)
## --- Self damage ---
const SELF_DAMAGE_MULT := 0.1    ## 90% resistance — only take 10% of explosion damage

## --- Synced state ---
var is_kamikaze: bool = false     ## Replicated via ServerSync

## --- Internal state ---
var _phase: int = 0               ## 0=off, 1=launch, 2=fly
var _direction: Vector3 = Vector3.UP
var _speed: float = 0.0
var _launch_timer: float = 0.0
var _trail: GPUParticles3D = null  ## Flight trail particles (client-side)
var _flashbang_overlay: FlashbangOverlay = null

## Player reference
var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p


func is_active() -> bool:
	return _phase > 0


## ======================================================================
##  Server-only: activation and state machine
## ======================================================================

func activate() -> void:
	## Enter kamikaze missile mode: Phase 1 (launch straight up).
	if _phase > 0:
		return
	is_kamikaze = true
	_phase = 1
	_direction = Vector3.UP
	_speed = LAUNCH_SPEED
	_launch_timer = LAUNCH_DURATION
	# End slide/crouch if active
	var sc: SlideCrouchSystem = player.slide_crouch
	if sc.is_sliding:
		sc.end_slide()
	if sc.is_crouching:
		sc.end_crouch()
	# Disable normal collision during flight
	player.get_node("CollisionShape3D").set_deferred("disabled", true)
	# Show launch VFX
	_show_kamikaze_launch.rpc(player.global_position)
	print("Player %d activated Kamikaze Missile!" % player.peer_id)


func process(delta: float) -> void:
	## Server-only: main kamikaze state machine tick.
	if _phase == 1:
		_process_launch(delta)
	elif _phase == 2:
		_process_flight(delta)


func reset_state() -> void:
	## Reset all kamikaze state variables back to defaults.
	is_kamikaze = false
	_phase = 0
	_direction = Vector3.UP
	_speed = 0.0
	_launch_timer = 0.0
	# Clean up flight trail particles
	if _trail and is_instance_valid(_trail):
		_trail.emitting = false
		get_tree().create_timer(1.0).timeout.connect(_trail.queue_free)
		_trail = null
	# Re-enable collision
	player.get_node("CollisionShape3D").set_deferred("disabled", false)


## ======================================================================
##  Server-only: flight phases
## ======================================================================

func _process_launch(delta: float) -> void:
	## Phase 1: Fly straight up, no steering.
	_launch_timer -= delta
	player.velocity = Vector3.UP * LAUNCH_SPEED
	# Update rotation to look yaw (so camera tracks mouse horizontally)
	player.rotation.y = player.player_input.look_yaw
	player.camera_pivot.rotation.x = player.player_input.look_pitch

	player.move_and_slide()

	if _launch_timer <= 0.0:
		# Transition to Phase 2: flight
		_phase = 2
		_speed = LAUNCH_SPEED * 0.5
		var cam_forward: Vector3 = -player.camera.global_transform.basis.z
		_direction = cam_forward.normalized()


func _process_flight(delta: float) -> void:
	## Phase 2: Mouse-steered flight with gravity-based acceleration.
	player.rotation.y = player.player_input.look_yaw
	player.camera_pivot.rotation.x = player.player_input.look_pitch
	var desired_direction: Vector3 = -player.camera.global_transform.basis.z
	desired_direction = desired_direction.normalized()

	# Smoothly steer toward desired direction
	_direction = _direction.lerp(desired_direction, STEER_SPEED * delta).normalized()

	# Gravity component: diving = accelerate, climbing = decelerate
	var gravity_accel: float = GRAVITY * _direction.dot(Vector3.DOWN)
	_speed += gravity_accel * delta

	# Air friction (linear drag)
	_speed *= (1.0 - AIR_FRICTION * delta)

	# No upper cap — pure physics
	_speed = maxf(_speed, MIN_SPEED)

	# Set velocity and move
	player.velocity = _direction * _speed

	# Collision detection: pre-frame raycast to catch tunneling
	var ray_dist: float = _speed * delta * 1.5
	var space_state := player.get_world_3d().direct_space_state
	if space_state:
		var query := PhysicsRayQueryParameters3D.create(
			player.global_position,
			player.global_position + _direction * ray_dist
		)
		query.exclude = [player.get_rid()]
		query.collision_mask = 0xFFFFFFFF
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			player.global_position = result.position
			_explode()
			return

	player.move_and_slide()

	# Post-move collision check
	if player.get_slide_collision_count() > 0:
		_explode()
		return


## ======================================================================
##  Server-only: explosion
## ======================================================================

func _explode() -> void:
	## Server-only: explode at current position. Damage, crater, VFX, then die.
	var explosion_pos := player.global_position
	var speed_ratio := maxf((_speed - MIN_SPEED) / (REF_SPEED - MIN_SPEED), 0.0)

	var damage: float = lerpf(MIN_DAMAGE, MAX_DAMAGE, speed_ratio)
	var radius: float = lerpf(MIN_RADIUS, MAX_RADIUS, speed_ratio)
	var flash_energy: float = lerpf(MIN_FLASH_ENERGY, MAX_FLASH_ENERGY, speed_ratio)

	# --- Pass 1: Physics sphere query for nearby bodies ---
	var already_damaged: Array[Node] = []
	var space_state := player.get_world_3d().direct_space_state
	if space_state:
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
			if collider == player:
				continue
			var target := _find_damageable(collider)
			if target and target not in already_damaged:
				if target.has_method("take_damage_at"):
					target.take_damage_at(explosion_pos, damage, radius, player.peer_id)
					already_damaged.append(target)
				elif target.has_method("take_damage"):
					var dist := explosion_pos.distance_to(target.global_position)
					var falloff := clampf(1.0 - (dist / radius), 0.0, 1.0)
					var dmg := damage * falloff
					if dmg > 0.5:
						target.take_damage(dmg, player.peer_id)
						already_damaged.append(target)

	# --- Pass 2: Scene-tree scan for destructible walls ---
	var structures := get_tree().current_scene.get_node_or_null("SeedWorld/Structures")
	if structures == null:
		structures = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld/Structures")
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
					child.take_damage_at(explosion_pos, damage, radius, player.peer_id)
					already_damaged.append(child)

	# --- Create terrain crater (scaled with speed) ---
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world == null:
		seed_world = get_tree().current_scene.get_node_or_null("BlockoutMap/SeedWorld")
	if seed_world and seed_world.has_method("create_crater"):
		seed_world.create_crater(explosion_pos, radius * 0.4, 1.5)

	# --- Broadcast explosion VFX to all clients ---
	_show_kamikaze_explosion.rpc(explosion_pos, radius, flash_energy, speed_ratio)

	# --- Self-damage with 90% resistance ---
	var self_damage: float = damage * SELF_DAMAGE_MULT
	var final_speed := _speed
	reset_state()
	player.health -= self_damage
	if player.health <= 0.0:
		player.health = 0.0
		player.die(player.peer_id)
	else:
		player.slide_crouch.apply_standing_pose()
	print("Player %d Kamikaze explosion! Speed: %.1f, Damage: %.1f, Radius: %.1f, Self-dmg: %.1f, HP left: %.1f" % [
		player.peer_id, final_speed, damage, radius, self_damage, player.health])


func _find_damageable(node: Node) -> Node:
	## Walk up the tree to find the best damageable ancestor.
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


## ======================================================================
##  RPCs: visual effects (run on all clients)
## ======================================================================

@rpc("authority", "call_local", "reliable")
func _show_kamikaze_launch(pos: Vector3) -> void:
	## Visual: orange glow at feet when launching + attach flight trail.
	var scene_root := get_tree().current_scene

	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.5, 0.1)
	flash.light_energy = 15.0
	flash.omni_range = 5.0
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	# Launch burst particles
	var launch_burst := GPUParticles3D.new()
	launch_burst.emitting = true
	launch_burst.one_shot = true
	launch_burst.amount = 40
	launch_burst.lifetime = 0.8
	launch_burst.explosiveness = 1.0
	launch_burst.top_level = true

	var burst_mat := ParticleProcessMaterial.new()
	burst_mat.direction = Vector3(0, 1, 0)
	burst_mat.spread = 60.0
	burst_mat.initial_velocity_min = 8.0
	burst_mat.initial_velocity_max = 16.0
	burst_mat.gravity = Vector3(0, -15, 0)
	burst_mat.scale_min = 0.1
	burst_mat.scale_max = 0.3
	burst_mat.damping_min = 3.0
	burst_mat.damping_max = 6.0
	var burst_gradient := Gradient.new()
	burst_gradient.set_color(0, Color(1.0, 0.6, 0.1, 1.0))
	burst_gradient.set_color(1, Color(1.0, 0.2, 0.0, 0.0))
	var burst_grad_tex := GradientTexture1D.new()
	burst_grad_tex.gradient = burst_gradient
	burst_mat.color_ramp = burst_grad_tex
	launch_burst.process_material = burst_mat

	var burst_quad := QuadMesh.new()
	burst_quad.size = Vector2(0.3, 0.3)
	var burst_draw_mat := StandardMaterial3D.new()
	burst_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	burst_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	burst_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	burst_draw_mat.vertex_color_use_as_albedo = true
	burst_quad.material = burst_draw_mat
	launch_burst.draw_pass_1 = burst_quad

	scene_root.add_child(launch_burst)
	launch_burst.global_position = pos

	# --- Attach persistent flight trail particles to the player ---
	if _trail:
		_trail.queue_free()
	_trail = GPUParticles3D.new()
	_trail.emitting = true
	_trail.amount = 60
	_trail.lifetime = 0.6
	_trail.explosiveness = 0.0

	var trail_mat := ParticleProcessMaterial.new()
	trail_mat.direction = Vector3(0, 0, 1)
	trail_mat.spread = 20.0
	trail_mat.initial_velocity_min = 2.0
	trail_mat.initial_velocity_max = 5.0
	trail_mat.gravity = Vector3(0, 3.0, 0)
	trail_mat.scale_min = 0.2
	trail_mat.scale_max = 0.6
	trail_mat.damping_min = 2.0
	trail_mat.damping_max = 4.0
	var trail_gradient := Gradient.new()
	trail_gradient.set_color(0, Color(1.0, 0.6, 0.1, 0.9))
	trail_gradient.set_color(1, Color(0.4, 0.4, 0.4, 0.0))
	var trail_grad_tex := GradientTexture1D.new()
	trail_grad_tex.gradient = trail_gradient
	trail_mat.color_ramp = trail_grad_tex
	_trail.process_material = trail_mat

	var trail_quad := QuadMesh.new()
	trail_quad.size = Vector2(0.4, 0.4)
	var trail_draw_mat := StandardMaterial3D.new()
	trail_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	trail_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	trail_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	trail_draw_mat.vertex_color_use_as_albedo = true
	trail_quad.material = trail_draw_mat
	_trail.draw_pass_1 = trail_quad

	# Trail light
	var trail_light := OmniLight3D.new()
	trail_light.light_color = Color(1.0, 0.5, 0.1)
	trail_light.light_energy = 4.0
	trail_light.omni_range = 6.0
	_trail.add_child(trail_light)

	player.add_child(_trail)

	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.8)
	tween.tween_callback(flash.queue_free)
	get_tree().create_timer(1.5).timeout.connect(launch_burst.queue_free)


@rpc("authority", "call_local", "reliable")
func _show_kamikaze_explosion(pos: Vector3, radius: float, flash_energy: float, speed_ratio: float) -> void:
	## Visual: speed-scaled explosion with particles, fireball mesh, shockwave, and flash.
	var scene_root := get_tree().current_scene
	var vfx_ratio := clampf(speed_ratio, 0.0, 2.5)

	# --- Bright flash light ---
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.7, 0.2)
	flash.light_energy = flash_energy
	flash.omni_range = radius * 2.5
	flash.top_level = true
	scene_root.add_child(flash)
	flash.global_position = pos

	# Secondary fill light for big explosions
	if vfx_ratio > 0.5:
		var fill_light := OmniLight3D.new()
		fill_light.light_color = Color(1.0, 0.4, 0.1)
		fill_light.light_energy = flash_energy * 0.4
		fill_light.omni_range = radius * 4.0
		fill_light.top_level = true
		scene_root.add_child(fill_light)
		fill_light.global_position = pos + Vector3(0, 3, 0)
		var fill_tween := get_tree().create_tween()
		fill_tween.tween_property(fill_light, "light_energy", 0.0, lerpf(0.6, 1.5, vfx_ratio))
		fill_tween.tween_callback(fill_light.queue_free)

	# --- Expanding fireball mesh (inner hot core) ---
	var fireball := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.5
	sphere_mesh.height = 1.0
	fireball.mesh = sphere_mesh
	fireball.top_level = true

	var mat := StandardMaterial3D.new()
	var r := clampf(lerpf(1.0, 1.0, vfx_ratio), 0.0, 1.0)
	var g := clampf(lerpf(0.4, 0.95, vfx_ratio), 0.0, 1.0)
	var b := clampf(lerpf(0.0, 0.8, vfx_ratio), 0.0, 1.0)
	mat.albedo_color = Color(r, g, b, 0.95)
	mat.emission_enabled = true
	mat.emission = Color(r, g, b)
	mat.emission_energy_multiplier = lerpf(8.0, 30.0, vfx_ratio)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fireball.material_override = mat
	scene_root.add_child(fireball)
	fireball.global_position = pos

	# --- Secondary outer fireball (dimmer, expands bigger, orange glow) ---
	var outer_ball := MeshInstance3D.new()
	var outer_mesh := SphereMesh.new()
	outer_mesh.radius = 0.8
	outer_mesh.height = 1.6
	outer_ball.mesh = outer_mesh
	outer_ball.top_level = true
	var outer_mat := StandardMaterial3D.new()
	outer_mat.albedo_color = Color(1.0, 0.35, 0.05, 0.6)
	outer_mat.emission_enabled = true
	outer_mat.emission = Color(1.0, 0.3, 0.0)
	outer_mat.emission_energy_multiplier = lerpf(4.0, 12.0, vfx_ratio)
	outer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outer_ball.material_override = outer_mat
	scene_root.add_child(outer_ball)
	outer_ball.global_position = pos

	# --- Shockwave ring (expands outward from impact) ---
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.8
	torus.outer_radius = 1.0
	ring.mesh = torus
	ring.top_level = true
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(1.0, 0.8, 0.4, 0.7)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(1.0, 0.6, 0.2)
	ring_mat.emission_energy_multiplier = lerpf(5.0, 15.0, vfx_ratio)
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = ring_mat
	scene_root.add_child(ring)
	ring.global_position = pos

	# --- Explosion spark/fire particles ---
	var sparks := GPUParticles3D.new()
	sparks.emitting = true
	sparks.one_shot = true
	sparks.amount = int(lerpf(40.0, 200.0, vfx_ratio))
	sparks.lifetime = lerpf(0.8, 2.5, vfx_ratio)
	sparks.explosiveness = 1.0
	sparks.top_level = true

	var spark_mat := ParticleProcessMaterial.new()
	spark_mat.direction = Vector3(0, 1, 0)
	spark_mat.spread = 180.0
	spark_mat.initial_velocity_min = lerpf(8.0, 30.0, vfx_ratio)
	spark_mat.initial_velocity_max = lerpf(16.0, 55.0, vfx_ratio)
	spark_mat.gravity = Vector3(0, -12, 0)
	spark_mat.scale_min = 0.1
	spark_mat.scale_max = lerpf(0.3, 1.0, vfx_ratio)
	spark_mat.damping_min = 2.0
	spark_mat.damping_max = 5.0
	var spark_gradient := Gradient.new()
	spark_gradient.set_color(0, Color(1.0, 0.95, 0.7, 1.0))
	spark_gradient.set_color(1, Color(1.0, 0.15, 0.0, 0.0))
	var spark_grad_tex := GradientTexture1D.new()
	spark_grad_tex.gradient = spark_gradient
	spark_mat.color_ramp = spark_grad_tex
	sparks.process_material = spark_mat

	var spark_quad := QuadMesh.new()
	spark_quad.size = Vector2(0.4, 0.4)
	var spark_draw_mat := StandardMaterial3D.new()
	spark_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	spark_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	spark_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	spark_draw_mat.vertex_color_use_as_albedo = true
	spark_quad.material = spark_draw_mat
	sparks.draw_pass_1 = spark_quad

	scene_root.add_child(sparks)
	sparks.global_position = pos

	# --- Rising smoke column ---
	var smoke := GPUParticles3D.new()
	smoke.emitting = true
	smoke.one_shot = true
	smoke.amount = int(lerpf(20.0, 100.0, vfx_ratio))
	smoke.lifetime = lerpf(1.5, 5.0, vfx_ratio)
	smoke.explosiveness = 0.8
	smoke.top_level = true

	var smoke_mat := ParticleProcessMaterial.new()
	smoke_mat.direction = Vector3(0, 1, 0)
	smoke_mat.spread = 120.0
	smoke_mat.initial_velocity_min = lerpf(3.0, 10.0, vfx_ratio)
	smoke_mat.initial_velocity_max = lerpf(7.0, 20.0, vfx_ratio)
	smoke_mat.gravity = Vector3(0, 3.0, 0)
	smoke_mat.scale_min = lerpf(0.8, 2.0, vfx_ratio)
	smoke_mat.scale_max = lerpf(2.0, 8.0, vfx_ratio)
	smoke_mat.damping_min = 3.0
	smoke_mat.damping_max = 6.0
	var smoke_gradient := Gradient.new()
	smoke_gradient.add_point(0.0, Color(0.6, 0.5, 0.3, 0.7))
	smoke_gradient.add_point(0.4, Color(0.35, 0.3, 0.25, 0.5))
	smoke_gradient.add_point(1.0, Color(0.2, 0.2, 0.2, 0.0))
	var smoke_grad_tex := GradientTexture1D.new()
	smoke_grad_tex.gradient = smoke_gradient
	smoke_mat.color_ramp = smoke_grad_tex
	smoke.process_material = smoke_mat

	var smoke_quad := QuadMesh.new()
	smoke_quad.size = Vector2(1.5, 1.5)
	var smoke_draw_mat := StandardMaterial3D.new()
	smoke_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smoke_draw_mat.vertex_color_use_as_albedo = true
	smoke_quad.material = smoke_draw_mat
	smoke.draw_pass_1 = smoke_quad

	scene_root.add_child(smoke)
	smoke.global_position = pos

	# --- Ground fire embers ---
	if vfx_ratio > 0.3:
		var embers := GPUParticles3D.new()
		embers.emitting = true
		embers.one_shot = true
		embers.amount = int(lerpf(10.0, 60.0, vfx_ratio))
		embers.lifetime = lerpf(1.5, 4.0, vfx_ratio)
		embers.explosiveness = 0.5
		embers.top_level = true

		var ember_mat := ParticleProcessMaterial.new()
		ember_mat.direction = Vector3(0, 1, 0)
		ember_mat.spread = 180.0
		ember_mat.initial_velocity_min = lerpf(1.0, 4.0, vfx_ratio)
		ember_mat.initial_velocity_max = lerpf(3.0, 8.0, vfx_ratio)
		ember_mat.gravity = Vector3(0, -2.0, 0)
		ember_mat.scale_min = 0.05
		ember_mat.scale_max = lerpf(0.15, 0.4, vfx_ratio)
		ember_mat.damping_min = 4.0
		ember_mat.damping_max = 8.0
		var ember_gradient := Gradient.new()
		ember_gradient.set_color(0, Color(1.0, 0.7, 0.1, 0.9))
		ember_gradient.set_color(1, Color(0.8, 0.15, 0.0, 0.0))
		var ember_grad_tex := GradientTexture1D.new()
		ember_grad_tex.gradient = ember_gradient
		ember_mat.color_ramp = ember_grad_tex
		embers.process_material = ember_mat

		var ember_quad := QuadMesh.new()
		ember_quad.size = Vector2(0.2, 0.2)
		var ember_draw_mat := StandardMaterial3D.new()
		ember_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ember_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ember_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		ember_draw_mat.vertex_color_use_as_albedo = true
		ember_quad.material = ember_draw_mat
		embers.draw_pass_1 = ember_quad

		scene_root.add_child(embers)
		embers.global_position = pos
		get_tree().create_timer(lerpf(2.0, 5.0, vfx_ratio)).timeout.connect(embers.queue_free)

	# --- Animate fireball: expand + fade ---
	var final_scale: float = lerpf(5.0, 20.0, vfx_ratio)
	var outer_scale: float = final_scale * 1.6
	var ring_scale: float = lerpf(3.0, 14.0, vfx_ratio)
	var expand_time: float = lerpf(0.3, 0.6, vfx_ratio)
	var fade_time: float = lerpf(0.4, 0.8, vfx_ratio)

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(fireball, "scale", Vector3.ONE * final_scale, expand_time).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, fade_time)
	tween.tween_property(outer_ball, "scale", Vector3.ONE * outer_scale, expand_time * 1.3).set_ease(Tween.EASE_OUT)
	tween.tween_property(outer_mat, "albedo_color:a", 0.0, fade_time * 1.5)
	tween.tween_property(ring, "scale", Vector3(ring_scale, 0.3, ring_scale), expand_time * 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(ring_mat, "albedo_color:a", 0.0, expand_time * 1.2)
	tween.tween_property(flash, "light_energy", 0.0, fade_time)
	tween.set_parallel(false)
	tween.tween_callback(fireball.queue_free)
	tween.tween_callback(outer_ball.queue_free)
	tween.tween_callback(ring.queue_free)
	tween.tween_callback(flash.queue_free)

	# Clean up particles after they finish
	var max_lifetime: float = lerpf(2.0, 6.0, vfx_ratio)
	get_tree().create_timer(max_lifetime).timeout.connect(sparks.queue_free)
	get_tree().create_timer(max_lifetime + 1.5).timeout.connect(smoke.queue_free)

	# --- Flashbang check for the local player ---
	_check_flashbang(pos, radius, flash_energy, clampf(speed_ratio, 0.0, 1.0))


## ======================================================================
##  Client-side: flashbang and visuals
## ======================================================================

func _check_flashbang(explosion_pos: Vector3, _radius: float, _flash_energy: float, speed_ratio: float) -> void:
	## Client-side: check if the local player should be flashbanged by this explosion.
	var local_id := multiplayer.get_unique_id()
	if player.peer_id != local_id:
		return
	if not player.is_alive:
		return
	if player.camera == null:
		return

	var cam_pos: Vector3 = player.camera.global_position
	var dist: float = cam_pos.distance_to(explosion_pos)
	if dist > FLASH_MAX_RANGE:
		return

	var cam_forward: Vector3 = -player.camera.global_transform.basis.z
	var dir_to_explosion: Vector3 = (explosion_pos - cam_pos).normalized()
	var dot: float = cam_forward.dot(dir_to_explosion)
	if dot < FLASH_DOT_THRESHOLD:
		return

	# Line of sight check
	var space_state := player.get_world_3d().direct_space_state
	if space_state:
		var query := PhysicsRayQueryParameters3D.create(cam_pos, explosion_pos)
		query.collision_mask = 1
		query.exclude = [player.get_rid()]
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			var hit_dist: float = cam_pos.distance_to(result.position)
			if hit_dist < dist - 1.0:
				return

	var dist_factor: float = 1.0 - (dist / FLASH_MAX_RANGE)
	var angle_factor: float = (dot - FLASH_DOT_THRESHOLD) / (1.0 - FLASH_DOT_THRESHOLD)
	var intensity := clampf(dist_factor * angle_factor * (0.3 + 0.7 * speed_ratio), 0.0, 1.0)
	var duration := FLASH_MAX_DURATION * intensity

	if intensity < 0.05:
		return

	if _flashbang_overlay == null:
		_flashbang_overlay = FlashbangOverlay.new()
		var hud_layer := player.get_node_or_null("HUDLayer")
		if hud_layer:
			hud_layer.add_child(_flashbang_overlay)
	if _flashbang_overlay:
		_flashbang_overlay.apply_flash(intensity, duration)


func client_process_visuals(delta: float) -> void:
	## Client-side: kamikaze mesh squish, head-first orientation, FOV widen.
	## Called from player._client_process when is_kamikaze is true.
	var is_local: bool = (player.peer_id == multiplayer.get_unique_id())
	var body_mesh: MeshInstance3D = player.body_mesh
	var original_mesh_scale_y: float = player.slide_crouch._original_mesh_scale_y
	var original_mesh_y: float = player.slide_crouch._original_mesh_y

	# Keep normal body scale — just orient head-first (no missile squish)
	body_mesh.scale.y = lerpf(body_mesh.scale.y, original_mesh_scale_y, 10.0 * delta)
	body_mesh.scale.x = lerpf(body_mesh.scale.x, 1.0, 10.0 * delta)
	body_mesh.scale.z = lerpf(body_mesh.scale.z, 1.0, 10.0 * delta)
	body_mesh.position.y = original_mesh_y

	# Orient body mesh head-first along flight direction
	var fly_dir := player.velocity.normalized() if player.velocity.length() > 1.0 else Vector3.DOWN
	var fly_pitch := asin(clampf(-fly_dir.y, -1.0, 1.0))
	body_mesh.rotation.x = lerpf(body_mesh.rotation.x, fly_pitch, 8.0 * delta)
	var fly_flat := Vector3(fly_dir.x, 0.0, fly_dir.z)
	if fly_flat.length() > 0.01:
		var target_yaw := atan2(fly_flat.x, fly_flat.z)
		var relative_yaw := target_yaw - player.rotation.y
		body_mesh.rotation.y = lerpf(body_mesh.rotation.y, relative_yaw, 8.0 * delta)

	# Local player: camera FOV widens with speed, spring arm pulls close
	if is_local:
		var base_fov := 70.0
		if player.has_node("/root/PauseMenu"):
			base_fov = player.get_node("/root/PauseMenu")._settings.get("fov", 70.0)
		var vel_speed := player.velocity.length()
		var speed_t := clampf(vel_speed / REF_SPEED, 0.0, 1.0)
		var target_fov := lerpf(base_fov, 110.0, speed_t)
		player.camera.fov = lerpf(player.camera.fov, target_fov, 8.0 * delta)
		player.spring_arm.spring_length = lerpf(player.spring_arm.spring_length, 0.5, 8.0 * delta)

	# Weapon mount hidden during kamikaze
	player.weapon_mount.visible = false
