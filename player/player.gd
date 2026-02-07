extends CharacterBody3D

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.

const SPEED := 7.0
const JUMP_VELOCITY := 5.5
const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1

## Combat state (synced via ServerSync)
var health: float = MAX_HEALTH
var is_alive: bool = true

## Current weapon (server-managed)
var current_weapon: WeaponBase = null
var _respawn_timer: float = 0.0

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

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if player_input.action_jump and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Movement (speed scaled by heat)
	var current_speed := SPEED * heat_system.get_speed_multiplier()
	var input_dir: Vector2 = player_input.input_direction
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	if direction:
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
	else:
		velocity.x = move_toward(velocity.x, 0, current_speed)
		velocity.z = move_toward(velocity.z, 0, current_speed)

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


func _client_process(_delta: float) -> void:
	if peer_id == multiplayer.get_unique_id():
		camera_pivot.rotation.x = player_input.look_pitch

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
	flash.global_position = from_pos
	add_child(flash)

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
