extends CharacterBody3D

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.

const SPEED := 7.0
const JUMP_VELOCITY := 5.5
const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

## Movement acceleration/deceleration
const ACCELERATION := 45.0         # ~0.16s to full speed — snappy
const DECELERATION := 30.0         # ~0.23s to stop — slight momentum
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 5.0

## Slide constants
const SLIDE_INITIAL_SPEED := 11.0
const SLIDE_FRICTION := 8.0
const SLIDE_MIN_SPEED := 2.0
const SLIDE_MIN_ENTRY_SPEED := 4.0
const SLIDE_COOLDOWN := 0.5
const SLIDE_GRAVITY_ACCEL := 15.0
const SLIDE_UPHILL_PENALTY := 20.0
const SLIDE_CAPSULE_HEIGHT := 1.0
const SLIDE_CAMERA_OFFSET := -0.5

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1

## Combat state (synced via ServerSync)
var health: float = MAX_HEALTH
var is_alive: bool = true

## Current weapon (server-managed)
var current_weapon: WeaponBase = null
var _respawn_timer: float = 0.0

## Slide state (server-managed, is_sliding synced to clients)
var is_sliding: bool = false
var _slide_velocity: Vector3 = Vector3.ZERO
var _slide_cooldown_timer: float = 0.0
var _original_capsule_height: float = 1.8
var _original_camera_y: float = 1.5

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var player_input: Node = $PlayerInput
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var input_sync: MultiplayerSynchronizer = $InputSync
@onready var inventory: Inventory = $Inventory
@onready var heat_system: HeatSystem = $HeatSystem
@onready var player_hud: Control = $HUDLayer/PlayerHUD

signal player_killed(victim_id: int, killer_id: int)


func _ready() -> void:
	peer_id = name.to_int()
	input_sync.set_multiplayer_authority(peer_id)
	player_input.set_multiplayer_authority(peer_id)

	# Duplicate collision shape so runtime resize doesn't affect other players
	var col_shape := $CollisionShape3D
	if col_shape.shape:
		col_shape.shape = col_shape.shape.duplicate()
		_original_capsule_height = col_shape.shape.height
	_original_camera_y = $CameraPivot.position.y

	if peer_id == multiplayer.get_unique_id():
		camera.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Setup HUD for local player
		if player_hud and player_hud.has_method("setup"):
			player_hud.setup(self)
	else:
		camera.current = false
		camera_pivot.visible = false
		# Hide HUD for non-local players
		if player_hud:
			player_hud.visible = false


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_server_process(delta)
	else:
		_client_process(delta)


func _server_process(delta: float) -> void:
	# Handle respawn timer
	if not is_alive:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_do_respawn()
		return

	# Slide cooldown
	if _slide_cooldown_timer > 0.0:
		_slide_cooldown_timer -= delta

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Slide vs normal movement
	if is_sliding:
		_process_slide(delta)
	else:
		# Jump (no jumping while sliding)
		if player_input.action_jump and is_on_floor():
			velocity.y = JUMP_VELOCITY

		# Check if we should start a slide
		if player_input.action_slide and _can_start_slide():
			_start_slide()
			_process_slide(delta)
		else:
			_process_normal_movement(delta)

	move_and_slide()

	# Weapon slot switching (1-6)
	if player_input.action_slot > 0:
		var slot_idx: int = player_input.action_slot - 1  # Convert 1-6 to 0-5
		if inventory and slot_idx < inventory.items.size():
			inventory.equip_slot(slot_idx)
			var stack: ItemStack = inventory.items[slot_idx]
			if stack.item_data is WeaponData:
				equip_weapon(stack.item_data as WeaponData)

	# Combat: shooting (damage scaled by heat)
	if player_input.action_shoot and current_weapon != null:
		# Third-person aiming: cast a ray from the camera through the crosshair
		# (screen center) to find the world-space target, then fire from the
		# character's muzzle position toward that target. This ensures bullets
		# land exactly where the crosshair points.
		var cam_origin := camera.global_position
		var cam_forward := -camera.global_transform.basis.z
		var aim_target := _get_camera_aim_target(cam_origin, cam_forward)

		# Fire from character shoulder height toward the aim target
		var muzzle_pos := camera_pivot.global_position
		var aim_direction := (aim_target - muzzle_pos).normalized()

		var hit_info := current_weapon.try_fire(self, muzzle_pos, aim_direction)
		if hit_info.has("shot_end"):
			# Show tracer FX on all clients
			_show_shot_fx.rpc(muzzle_pos, hit_info["shot_end"])

			var collider = hit_info.get("hit_collider")
			if collider != null and collider.has_method("take_damage"):
				var base_damage: float = current_weapon.weapon_data.damage
				var final_damage: float = base_damage * heat_system.get_damage_multiplier()
				collider.take_damage(final_damage, peer_id)
				# Add heat for dealing damage
				heat_system.on_damage_dealt(base_damage)


func _process_normal_movement(delta: float) -> void:
	## Acceleration-based horizontal movement. Uses different rates on ground vs air.
	var shoe_bonus: float = inventory.get_shoe_speed_bonus() if inventory else 0.0
	var current_speed := SPEED * (heat_system.get_speed_multiplier() + shoe_bonus)
	var input_dir: Vector2 = player_input.input_direction
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var horizontal := Vector2(velocity.x, velocity.z)
	var on_floor := is_on_floor()

	if direction:
		var target := Vector2(direction.x, direction.z) * current_speed
		var accel := ACCELERATION if on_floor else AIR_ACCELERATION
		horizontal = horizontal.move_toward(target, accel * delta)
	else:
		var decel := DECELERATION if on_floor else AIR_DECELERATION
		horizontal = horizontal.move_toward(Vector2.ZERO, decel * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.y


## ---- Slide mechanics (server-only) ----

func _can_start_slide() -> bool:
	if not is_on_floor():
		return false
	if _slide_cooldown_timer > 0.0:
		return false
	var horiz_speed := Vector2(velocity.x, velocity.z).length()
	return horiz_speed >= SLIDE_MIN_ENTRY_SPEED


func _start_slide() -> void:
	is_sliding = true
	# Lock slide direction to current movement direction
	var horiz := Vector2(velocity.x, velocity.z)
	var horiz_speed := horiz.length()
	if horiz_speed > 0.01:
		var dir_2d := horiz.normalized()
		var boost_speed := maxf(horiz_speed, SLIDE_INITIAL_SPEED)
		_slide_velocity = Vector3(dir_2d.x * boost_speed, 0.0, dir_2d.y * boost_speed)
	else:
		# Fallback: slide forward
		var forward := -transform.basis.z
		_slide_velocity = forward * SLIDE_INITIAL_SPEED

	# Shrink capsule for slide
	var col_shape := $CollisionShape3D
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = SLIDE_CAPSULE_HEIGHT
		# Adjust collision shape position so bottom stays on floor
		col_shape.position.y = SLIDE_CAPSULE_HEIGHT * 0.5

	# Lower camera
	camera_pivot.position.y = _original_camera_y + SLIDE_CAMERA_OFFSET


func _process_slide(delta: float) -> void:
	## Server-only: process slide movement with slope awareness.
	# Get floor slope info
	var floor_normal := get_floor_normal() if is_on_floor() else Vector3.UP
	# Downhill direction is the direction gravity would pull along the slope
	var downhill := (Vector3.DOWN - floor_normal * Vector3.DOWN.dot(floor_normal)).normalized()

	# How much our slide direction aligns with downhill
	var slide_dir := _slide_velocity.normalized()
	var downhill_factor := slide_dir.dot(downhill)  # +1 = downhill, -1 = uphill, 0 = flat

	# Apply slope effects
	if downhill_factor > 0.05:
		# Sliding downhill — gain speed
		_slide_velocity += downhill * SLIDE_GRAVITY_ACCEL * downhill_factor * delta
	elif downhill_factor < -0.05:
		# Sliding uphill — lose speed quickly
		var penalty := SLIDE_UPHILL_PENALTY * absf(downhill_factor) * delta
		var speed := _slide_velocity.length()
		speed = maxf(speed - penalty, 0.0)
		if speed > 0.01:
			_slide_velocity = slide_dir * speed
		else:
			_slide_velocity = Vector3.ZERO

	# Apply friction on flat ground
	var flat_friction := SLIDE_FRICTION * (1.0 - absf(downhill_factor)) * delta
	var current_speed := _slide_velocity.length()
	current_speed = maxf(current_speed - flat_friction, 0.0)
	if current_speed > 0.01:
		_slide_velocity = _slide_velocity.normalized() * current_speed
	else:
		_slide_velocity = Vector3.ZERO

	# Set velocity
	velocity.x = _slide_velocity.x
	velocity.z = _slide_velocity.z

	# End slide conditions
	var should_end := false
	if _slide_velocity.length() < SLIDE_MIN_SPEED:
		should_end = true
	if not player_input.action_slide:
		should_end = true
	if not is_on_floor():
		should_end = true

	if should_end:
		_end_slide()


func _end_slide() -> void:
	is_sliding = false
	_slide_cooldown_timer = SLIDE_COOLDOWN

	# Restore capsule
	var col_shape := $CollisionShape3D
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = _original_capsule_height
		col_shape.position.y = _original_capsule_height * 0.5

	# Restore camera (will be lerped on client side)
	camera_pivot.position.y = _original_camera_y

	# Keep horizontal momentum from slide
	velocity.x = _slide_velocity.x
	velocity.z = _slide_velocity.z
	_slide_velocity = Vector3.ZERO


func _get_camera_aim_target(cam_origin: Vector3, cam_forward: Vector3) -> Vector3:
	## Raycast from the camera through screen-center to find what the
	## crosshair is actually pointing at. Returns the hit point, or a
	## far point along the camera forward if nothing is hit.
	var space_state := get_world_3d().direct_space_state
	var far_point := cam_origin + cam_forward * 1000.0
	var query := PhysicsRayQueryParameters3D.create(cam_origin, far_point)
	query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position
	return far_point


func _client_process(delta: float) -> void:
	if peer_id == multiplayer.get_unique_id():
		camera_pivot.rotation.x = player_input.look_pitch
		# Smooth camera height for slide
		var target_y := _original_camera_y + SLIDE_CAMERA_OFFSET if is_sliding else _original_camera_y
		camera_pivot.position.y = lerpf(camera_pivot.position.y, target_y, 10.0 * delta)

	# Update mesh visibility based on alive state
	body_mesh.visible = is_alive


func take_damage(amount: float, attacker_id: int) -> void:
	## Server-only: apply damage to this player.
	if not multiplayer.is_server() or not is_alive:
		return

	health -= amount
	# Add heat for taking damage
	heat_system.on_damage_taken(amount)
	if health <= 0.0:
		health = 0.0
		die(attacker_id)


func die(killer_id: int) -> void:
	## Server-only: handle player death.
	is_alive = false
	_respawn_timer = RESPAWN_DELAY
	body_mesh.visible = false
	# End slide if active
	if is_sliding:
		_end_slide()
	# Disable collision while dead
	$CollisionShape3D.set_deferred("disabled", true)
	# Clear inventory on death (keep time currency)
	if inventory:
		inventory.clear_all()
	# Drop weapon
	if current_weapon:
		current_weapon.queue_free()
		current_weapon = null
	# Reset heat
	heat_system.reset()
	# Give the killer heat for the kill
	var players_container := get_parent()
	if players_container:
		var killer_node := players_container.get_node_or_null(str(killer_id))
		if killer_node and killer_node.has_node("HeatSystem"):
			killer_node.get_node("HeatSystem").on_kill()
	player_killed.emit(peer_id, killer_id)
	print("Player %d killed by Player %d" % [peer_id, killer_id])


func _do_respawn() -> void:
	## Server-only: respawn at a random spawn point.
	is_alive = true
	health = MAX_HEALTH
	body_mesh.visible = true
	$CollisionShape3D.set_deferred("disabled", false)

	# Pick a random spawn point
	var map := get_tree().current_scene
	var spawns := map.get_node("PlayerSpawnPoints").get_children()
	if spawns.size() > 0:
		var spawn_point: Marker3D = spawns[randi() % spawns.size()]
		global_position = spawn_point.global_position
		velocity = Vector3.ZERO

	print("Player %d respawned" % peer_id)


func equip_weapon(weapon_data: WeaponData) -> void:
	## Server-only: equip a weapon by creating a WeaponHitscan node.
	if current_weapon != null:
		current_weapon.queue_free()

	if weapon_data.is_hitscan:
		current_weapon = WeaponHitscan.new()
	else:
		current_weapon = WeaponBase.new()

	current_weapon.setup(weapon_data)
	add_child(current_weapon)


func _on_item_pickup(world_item: Node) -> void:
	## Server-only: called when this player walks into a WorldItem.
	if not multiplayer.is_server() or not is_alive:
		return
	if inventory == null:
		return

	var item_data: ItemData = world_item.item_data
	if item_data == null:
		return

	# Shoes go into the dedicated shoe slot
	if item_data is ShoeData:
		var old_shoe: ItemStack = inventory.equip_shoe(item_data)
		# Drop old shoe back into the world with its remaining burn time
		if old_shoe != null and old_shoe.item_data != null:
			_drop_item_as_world_item(old_shoe)
		world_item.queue_free()
		print("Player %d equipped %s" % [peer_id, item_data.item_name])
		return

	var idx := inventory.add_item(item_data)
	if idx < 0:
		return  # Inventory full

	# If it's a weapon and we don't have one equipped, auto-equip
	if item_data is WeaponData and current_weapon == null:
		inventory.equip_slot(idx)
		equip_weapon(item_data as WeaponData)

	# Remove the world item
	world_item.queue_free()
	print("Player %d picked up %s" % [peer_id, item_data.item_name])


func _drop_item_as_world_item(stack: ItemStack) -> void:
	## Server-only: spawn a WorldItem on the ground with the remaining burn time.
	var world_item_scene := preload("res://items/world_item.tscn")
	var world_item: WorldItem = world_item_scene.instantiate()
	world_item.setup(stack.item_data)
	# Override burn time with the remaining time from the stack
	world_item.burn_time_remaining = stack.burn_time_remaining
	# Drop slightly behind the player
	var drop_pos := global_position - transform.basis.z * 1.5
	drop_pos.y = global_position.y
	world_item.position = drop_pos

	var map := get_tree().current_scene
	var container := map.get_node_or_null("WorldItems")
	if container:
		container.add_child(world_item, true)
	else:
		map.add_child(world_item, true)


@rpc("authority", "call_local", "unreliable")
func _show_shot_fx(from_pos: Vector3, to_pos: Vector3) -> void:
	## Visual effect: tracer line + muzzle flash. Runs on all clients.
	# Tracer line using ImmediateMesh
	var tracer := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	tracer.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.3, 0.8)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from_pos)
	im.surface_add_vertex(to_pos)
	im.surface_end()

	# Add to scene as top-level so it's in world space
	tracer.top_level = true
	add_child(tracer)

	# Muzzle flash light
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.3)
	flash.light_energy = 5.0
	flash.omni_range = 3.0
	flash.top_level = true
	add_child(flash)
	flash.global_position = from_pos

	# Fade out and cleanup after 0.1 seconds
	var tween := get_tree().create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.1)
	tween.parallel().tween_property(flash, "light_energy", 0.0, 0.08)
	tween.tween_callback(tracer.queue_free)
	tween.tween_callback(flash.queue_free)


@rpc("any_peer", "call_remote", "reliable")
func rpc_sacrifice_item(sacrifice_idx: int, target_idx: int) -> void:
	## Client requests sacrificing one item to extend another.
	if not multiplayer.is_server():
		return
	# Verify the request comes from the owning peer
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	if inventory:
		inventory.sacrifice_item(sacrifice_idx, target_idx)


@rpc("any_peer", "call_remote", "reliable")
func rpc_convert_to_currency(index: int) -> void:
	## Client requests converting an item to time currency.
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	if inventory:
		inventory.convert_to_time_currency(index)


@rpc("any_peer", "call_remote", "reliable")
func rpc_equip_from_inventory(index: int) -> void:
	## Client requests equipping a weapon from their inventory.
	if not multiplayer.is_server():
		return
	if multiplayer.get_remote_sender_id() != peer_id:
		return
	if inventory and index >= 0 and index < inventory.items.size():
		var stack: ItemStack = inventory.items[index]
		if stack.item_data is WeaponData:
			inventory.equip_slot(index)
			equip_weapon(stack.item_data as WeaponData)
