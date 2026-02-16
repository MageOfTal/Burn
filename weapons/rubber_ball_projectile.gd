extends ProjectileBase

## Rubber ball projectile: bounces off surfaces, deals velocity-based damage.
## Faster impact = more damage. Bounces up to MAX_BOUNCES times.
## Mass-weighted character push via PhysicsBodyBase (negligible at 0.05kg).
## Server-authoritative: server handles collision, damage, and cleanup.

const LAUNCH_SPEED := 40.0
const MAX_BOUNCES := 8
const MAX_LIFETIME := 8.0
const BALL_RADIUS := 0.05  ## Golf ball size

var _direction: Vector3 = Vector3.FORWARD
var _bounce_count: int = 0
var _dying: bool = false

## Track which bodies were already hit this bounce (reset on each bounce)
var _already_hit: Array[Node] = []

## Track previous speed to detect bounces (speed drops on wall impact)
var _prev_speed: float = 0.0


func get_launch_speed() -> float:
	return LAUNCH_SPEED


func get_max_lifetime() -> float:
	return MAX_LIFETIME


func launch(direction: Vector3, shooter_id: int, damage: float) -> void:
	_direction = direction.normalized()
	super.launch(direction, shooter_id, damage)


func _setup() -> void:
	# Physics setup: gravity + bouncy material
	gravity_scale = 1.0
	lock_rotation = false  ## Let the ball spin naturally
	continuous_cd = true  ## Prevent tunneling through ground/walls at high speed

	# Set up bounce physics material
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.92
	phys_mat.friction = 0.3
	physics_material_override = phys_mat

	# Launch velocity
	linear_velocity = _direction * LAUNCH_SPEED
	_prev_speed = LAUNCH_SPEED

	# Set up the visual material (bright rubber blue)
	var mesh_inst := get_node_or_null("MeshInstance3D")
	if mesh_inst:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.2, 0.4, 0.9)
		mat.roughness = 0.8
		mat.metallic = 0.0
		mesh_inst.material_override = mat


func _server_process(delta: float) -> void:
	# Detect bounces by checking if speed dropped significantly
	# (ball hit a wall/floor and physics material made it bounce)
	var current_speed := linear_velocity.length()
	if current_speed < _prev_speed * 0.95 and _prev_speed > 2.0:
		# Speed dropped = a bounce happened
		_bounce_count += 1
		_already_hit.clear()  # Allow re-hitting on new bounces

		if _bounce_count >= MAX_BOUNCES and not _dying:
			_dying = true
			_is_terminated = true  # Prevent base lifetime kill
			# Let the ball roll for 1 second then delete
			var timer := Timer.new()
			timer.wait_time = 1.0
			timer.one_shot = true
			timer.autostart = true
			timer.timeout.connect(queue_free)
			add_child(timer)

	_prev_speed = current_speed


func _is_shooter_immune(body: Node) -> bool:
	## Rubber ball: shooter immune for 0.5s OR until first bounce.
	if body is CharacterBody3D and body.name.to_int() == _shooter_id:
		return _lifetime < 0.5 and _bounce_count == 0
	return false


func _on_body_hit(body: Node) -> void:
	if _dying:
		return

	# Don't damage the same body twice in one bounce
	if body in _already_hit:
		return

	# Only damage players and dummies (CharacterBody3D), not walls/structures
	if not (body is CharacterBody3D or body is RigidBody3D):
		return
	if not body.has_method("take_damage"):
		return

	# Velocity-based damage: faster = more damage, minimum 20% at low speed
	var speed := linear_velocity.length()
	var speed_ratio := clampf(speed / LAUNCH_SPEED, 0.2, 1.0)
	var dmg := _damage * speed_ratio

	body.take_damage(dmg, _shooter_id)
	_already_hit.append(body)

	# Show hit VFX on all clients
	_show_hit_fx.rpc(global_position)


@rpc("authority", "call_local", "unreliable")
func _show_hit_fx(pos: Vector3) -> void:
	## Small bounce impact flash.
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.3, 0.5, 1.0)
	flash.light_energy = 3.0
	flash.omni_range = 2.0
	flash.top_level = true
	get_tree().current_scene.add_child(flash)
	flash.global_position = pos

	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.15)
	tween.tween_callback(flash.queue_free)
