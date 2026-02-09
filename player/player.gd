extends CharacterBody3D

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.
##
## Subsystems (child nodes):
##   SlideCrouchSystem — slide/crouch physics
##   KamikazeSystem — kamikaze missile flight, explosion, flashbang
##   CombatVFX — weapon tracer lines, melee arcs, ADS visuals, scope
##   ItemManager — item pickup, drop, extend, scrap
##   HeatSystem — heat/fever combat multipliers
##   Inventory — item storage, burn fuel, sacrifice
##   GrappleSystem — grappling hook swing physics
##   DemonSystem — per-player demon stalker (spawns on first death)

const WeaponProjectileScript = preload("res://weapons/weapon_projectile.gd")
const WeaponMeleeScript = preload("res://weapons/weapon_melee.gd")

const SPEED := 7.0
const JUMP_VELOCITY := 9.0
const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

## Movement acceleration/deceleration
const ACCELERATION := 45.0         # ~0.16s to full speed — snappy
const DECELERATION := 30.0         # ~0.23s to stop — slight momentum
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 5.0

## Rarity damage bonus: +15% per rarity tier
const RARITY_DAMAGE_BONUS := 0.15

var gravity: float = 17.5  ## Heavier gravity for snappy movement

## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1
## True for server-controlled bot players.
var is_bot: bool = false
## True when player is inside the Toad Dimension (immune to fall death).
var in_toad_dimension: bool = false

## Combat state (synced via ServerSync)
var health: float = MAX_HEALTH
var is_alive: bool = true

## ADS state — synced via ServerSync
var is_aiming: bool = false

## Current weapon (server-managed)
var current_weapon: WeaponBase = null
var _respawn_timer: float = 0.0

## Synced weapon visual paths — clients use these to load 3D model + sound
var equipped_gun_model_path: String = ""
var equipped_fire_sound_path: String = ""
var _current_gun_model: Node3D = null
var _last_synced_gun_model_path: String = ""
var _last_synced_fire_sound_path: String = ""

## 3D health bar label (visible to other players above this player's head)
var _health_label_3d: Label3D = null

## Stored geometry defaults (used by subsystems via setup)
var _original_capsule_height: float = 1.8
var _original_camera_y: float = 1.5
var _original_mesh_y: float = 0.9
var _original_mesh_scale_y: float = 1.0

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var player_input: Node = $PlayerInput
@onready var body_mesh: MeshInstance3D = $BodyMesh
@onready var input_sync: MultiplayerSynchronizer = $InputSync
@onready var inventory: Inventory = $Inventory
@onready var heat_system: HeatSystem = $HeatSystem
@onready var player_hud: Control = $HUDLayer/PlayerHUD
@onready var weapon_mount: Node3D = $WeaponMount
@onready var fire_sound_player: AudioStreamPlayer3D = $FireSoundPlayer
@onready var inventory_ui: Control = $HUDLayer/InventoryUI

## Subsystem references
@onready var slide_crouch: SlideCrouchSystem = $SlideCrouchSystem
@onready var kamikaze_system: KamikazeSystem = $KamikazeSystem
@onready var combat_vfx: CombatVFX = $CombatVFX
@onready var item_manager: ItemManager = $ItemManager
@onready var grapple_system: GrappleSystem = $GrappleSystem
@onready var demon_system: DemonSystem = $DemonSystem

signal player_killed(victim_id: int, killer_id: int)


func _ready() -> void:
	peer_id = name.to_int()

	# Bots: server owns input, skip InputSync replication
	if is_bot:
		player_input.is_bot = true
		input_sync.set_multiplayer_authority(1)
		player_input.set_multiplayer_authority(1)
	else:
		input_sync.set_multiplayer_authority(peer_id)
		player_input.set_multiplayer_authority(peer_id)

	# Duplicate collision shape so runtime resize doesn't affect other players
	var col_shape := $CollisionShape3D
	if col_shape.shape:
		col_shape.shape = col_shape.shape.duplicate()
		_original_capsule_height = col_shape.shape.height
	_original_camera_y = $CameraPivot.position.y
	_original_mesh_y = body_mesh.position.y
	_original_mesh_scale_y = body_mesh.scale.y

	# Setup subsystems
	slide_crouch.setup(self)
	kamikaze_system.setup(self)
	combat_vfx.setup(self)
	item_manager.setup(self)
	grapple_system.setup(self)
	demon_system.setup(self)

	# Add VoxelViewer so the voxel terrain generates around each player.
	if not is_bot and ClassDB.class_exists(&"VoxelViewer"):
		var viewer: Node3D = ClassDB.instantiate(&"VoxelViewer")
		viewer.name = "VoxelViewer"
		add_child(viewer)

	# Bots: attach AI brain (server-side only), hide HUD/camera
	if is_bot:
		camera.current = false
		camera_pivot.visible = false
		if player_hud:
			player_hud.visible = false
		if inventory_ui:
			inventory_ui.visible = false
		if multiplayer.is_server():
			var brain_script := preload("res://player/bot_brain.gd")
			var brain := Node.new()
			brain.set_script(brain_script)
			brain.name = "BotBrain"
			add_child(brain)
			brain.setup(self)
		return

	if peer_id == multiplayer.get_unique_id():
		camera.current = true
		# Mouse capture is deferred via player_input._try_capture_mouse() —
		# don't capture here if loading screen is still up.
		if not (has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		if player_hud and player_hud.has_method("setup"):
			player_hud.setup(self)
		if inventory_ui and inventory_ui.has_method("setup"):
			inventory_ui.setup(self)
			inventory_ui.visible = false
	else:
		camera.current = false
		camera_pivot.visible = false
		if player_hud:
			player_hud.visible = false
		if inventory_ui:
			inventory_ui.visible = false


func _physics_process(delta: float) -> void:
	# Skip all processing while loading screen is up (terrain collision may not be ready)
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		return

	# Toggle inventory UI for the local player
	if peer_id == multiplayer.get_unique_id() and inventory_ui:
		inventory_ui.visible = player_input.inventory_open

	if multiplayer.is_server():
		_server_process(delta)
		# On a listen server the host needs client visuals for ALL player nodes
		# (own camera/ADS, other players' health bars, grapple rope, demon, etc.)
		_client_process(delta)
	else:
		_client_process(delta)


## ======================================================================
##  Server-side game loop
## ======================================================================

func _server_process(delta: float) -> void:
	# Demon always ticks (chases even while player is dead/respawning)
	demon_system.process(delta)

	# Handle respawn timer
	if not is_alive:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_do_respawn()
		return

	# Fall-through-ground safety (skip in Toad Dimension at Y=-500)
	if global_position.y < -50.0 and not in_toad_dimension:
		_do_respawn()
		return

	# --- Kamikaze Missile state machine ---
	if kamikaze_system.is_active():
		kamikaze_system.process(delta)
		return

	# --- Grapple: feed shoot input for fire/release toggle ---
	# Must run BEFORE the grapple state machine so release is detected same frame
	if current_weapon == null and inventory:
		if inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size():
			var eq_grapple: ItemStack = inventory.items[inventory.equipped_index]
			if eq_grapple.item_data is GadgetData and (eq_grapple.item_data as GadgetData).gadget_type == 0:
				grapple_system.handle_shoot_input(player_input.action_shoot)

	# --- Grapple swing state machine ---
	if grapple_system.is_active():
		grapple_system.process(delta)
		return

	# Slide cooldown
	slide_crouch.tick_cooldown(delta)

	# Gravity (skip during slide — slide manages its own Y velocity)
	if not is_on_floor() and not slide_crouch.is_sliding:
		velocity.y -= gravity * delta

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Slide / crouch / normal movement
	if slide_crouch.is_sliding:
		slide_crouch.process_slide(delta)
	elif slide_crouch.is_crouching:
		slide_crouch.process_crouch(delta)
	else:
		# Jump (slide-jump is handled in process_slide; crouch-jump in process_crouch)
		if player_input.action_jump and is_on_floor():
			velocity.y = JUMP_VELOCITY
			slide_crouch.clear_slide_on_land()

		# While airborne, queue slide for when we land
		if not is_on_floor() and player_input.action_slide:
			slide_crouch.queue_slide_on_land()

		# Check if we should start a slide
		if player_input.action_slide and slide_crouch.can_start_slide():
			slide_crouch.start_slide()
			slide_crouch.process_slide(delta)
		elif player_input.action_slide and is_on_floor():
			slide_crouch.start_crouch()
			slide_crouch.process_crouch(delta)
		else:
			_process_normal_movement(delta)

	# Track pre-land velocity for slide-on-land momentum transfer
	slide_crouch.track_pre_land_velocity()
	move_and_slide()

	# --- Push nearby bubbles ---
	_push_nearby_bubbles()

	# --- Slide-on-land system ---
	slide_crouch.process_landing(delta)

	# Weapon slot switching (1-6)
	if player_input.action_slot > 0:
		var slot_idx: int = player_input.action_slot - 1
		if inventory and slot_idx < inventory.items.size():
			inventory.equip_slot(slot_idx)
			var stack: ItemStack = inventory.items[slot_idx]
			if stack.item_data is WeaponData:
				equip_weapon(stack.item_data as WeaponData)
			elif stack.item_data is ConsumableData:
				clear_equipped_weapon()
			elif stack.item_data is GadgetData:
				clear_equipped_weapon()
			# Release grapple if switching away from the grapple gadget
			if grapple_system.is_active():
				grapple_system._do_release(false)

	# --- Extend equipped item lifespan (F key) ---
	if player_input.action_extend and inventory:
		item_manager.try_extend_equipped_item()

	# --- Open nearby chest OR pickup nearby item (E key) ---
	if player_input.action_pickup and inventory:
		if not _try_open_nearby_chest():
			item_manager.try_pickup_nearby_item()

	# --- Scrap nearby ground item or equipped item (X key) ---
	if player_input.action_scrap and inventory:
		item_manager.try_scrap_item()

	# --- Consumable activation: shoot while a consumable is equipped ---
	if player_input.action_shoot and current_weapon == null and inventory:
		if inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size():
			var eq_stack: ItemStack = inventory.items[inventory.equipped_index]
			if eq_stack.item_data is ConsumableData:
				var cons_data: ConsumableData = eq_stack.item_data as ConsumableData
				if cons_data.consumable_effect == 0:  # KAMIKAZE_MISSILE
					kamikaze_system.activate()
					inventory.remove_item(inventory.equipped_index)

	# ADS state: server tracks whether the player is aiming
	var w_data: WeaponData = current_weapon.weapon_data if current_weapon else null
	is_aiming = player_input.action_aim and w_data != null and w_data.ads_fov > 0.0

	# Combat: shooting (damage scaled by heat)
	if player_input.action_shoot and current_weapon != null and current_weapon.can_fire():
		_process_combat()


func _process_combat() -> void:
	## Server-only: handle weapon firing, damage, and VFX dispatch.
	# Calculate fuel cost
	var fuel_cost: float = current_weapon.weapon_data.burn_fuel_cost
	var equipped_stack: ItemStack = null
	if inventory and inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size():
		equipped_stack = inventory.items[inventory.equipped_index]
		if equipped_stack and equipped_stack.slotted_ammo:
			fuel_cost += equipped_stack.slotted_ammo.ammo_burn_cost_per_shot

	if not inventory.has_fuel(fuel_cost):
		return

	inventory.spend_fuel(fuel_cost)

	# Set ammo context on weapon before firing
	if equipped_stack and equipped_stack.slotted_ammo:
		current_weapon.ammo_data = equipped_stack.slotted_ammo
	else:
		current_weapon.ammo_data = null

	# Third-person aiming: ray from camera through crosshair
	var cam_origin := camera.global_position
	var cam_forward := -camera.global_transform.basis.z
	var aim_target := _get_camera_aim_target(cam_origin, cam_forward)

	var is_melee: bool = current_weapon is WeaponMelee
	var muzzle_pos: Vector3
	if is_melee:
		muzzle_pos = global_position + Vector3(0, 1.2, 0)
	else:
		muzzle_pos = _get_barrel_position()
	var aim_direction := (aim_target - muzzle_pos).normalized()

	# Reduce spread while ADS
	var saved_spread: float = current_weapon.weapon_data.spread
	if is_aiming:
		current_weapon.weapon_data.spread *= current_weapon.weapon_data.ads_spread_mult

	var hit_info := current_weapon.try_fire(self, muzzle_pos, aim_direction)

	# Restore original spread
	current_weapon.weapon_data.spread = saved_spread

	if hit_info.has("melee_hit") or hit_info.has("melee_miss"):
		combat_vfx.show_melee_swing_fx.rpc(muzzle_pos, aim_direction)

		if hit_info.has("melee_hit"):
			var melee_target = hit_info.get("hit_collider")
			if melee_target is CharacterBody3D and melee_target.has_method("take_damage"):
				if has_node("/root/ToadDimension"):
					get_node("/root/ToadDimension").enter(self, melee_target)
				heat_system.on_damage_dealt(10.0)

	elif hit_info.has("pellets"):
		# Multi-pellet weapon (shotgun)
		var pellets: Array = hit_info["pellets"]
		var pellet_count := pellets.size()
		var base_damage_per_pellet: float = current_weapon.weapon_data.damage / pellet_count
		var total_damage_dealt: float = 0.0

		var shot_ends: Array[Vector3] = []
		for pellet in pellets:
			if pellet.has("shot_end"):
				shot_ends.append(pellet["shot_end"])

		if shot_ends.size() > 0:
			combat_vfx.show_shotgun_fx.rpc(muzzle_pos, shot_ends)

		var rarity_mult: float = 1.0 + current_weapon.weapon_data.rarity * RARITY_DAMAGE_BONUS

		for pellet in pellets:
			var collider = pellet.get("hit_collider")
			if collider != null and collider.has_method("take_damage"):
				var final_damage: float = base_damage_per_pellet * heat_system.get_damage_multiplier() * rarity_mult
				collider.take_damage(final_damage, peer_id)
				total_damage_dealt += base_damage_per_pellet

		if total_damage_dealt > 0.0:
			heat_system.on_damage_dealt(total_damage_dealt)

	elif hit_info.has("shot_end"):
		# Single-pellet weapon
		combat_vfx.show_shot_fx.rpc(muzzle_pos, hit_info["shot_end"])

		var collider = hit_info.get("hit_collider")
		if collider != null and collider.has_method("take_damage"):
			var base_damage: float = current_weapon.weapon_data.damage
			var rarity_mult: float = 1.0 + current_weapon.weapon_data.rarity * RARITY_DAMAGE_BONUS
			var final_damage: float = base_damage * heat_system.get_damage_multiplier() * rarity_mult
			collider.take_damage(final_damage, peer_id)
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


## ======================================================================
##  Client-side visuals
## ======================================================================

func _client_process(delta: float) -> void:
	var is_local := (peer_id == multiplayer.get_unique_id())
	if is_local:
		camera_pivot.rotation.x = player_input.look_pitch
		# Smooth camera height for slide/crouch
		var cam_lowered := slide_crouch.is_sliding or slide_crouch.is_crouching
		var target_cam_y := slide_crouch._original_camera_y + SlideCrouchSystem.SLIDE_CAMERA_OFFSET if cam_lowered else slide_crouch._original_camera_y
		camera_pivot.position.y = lerpf(camera_pivot.position.y, target_cam_y, 10.0 * delta)

		# ADS visuals (skip if kamikaze — it overrides FOV/spring)
		if not kamikaze_system.is_kamikaze:
			var w_data: WeaponData = null
			if current_weapon and current_weapon.weapon_data:
				w_data = current_weapon.weapon_data
			combat_vfx.process_ads_visuals(delta, is_aiming, w_data)

	# --- Grapple rope client visuals ---
	if grapple_system.is_grappling:
		grapple_system.client_process_visuals(delta)
	else:
		grapple_system.cleanup()

	# --- Demon client visuals (local player only) ---
	demon_system.client_process_visuals(delta)

	# --- Kamikaze missile client visuals ---
	if kamikaze_system.is_kamikaze:
		kamikaze_system.client_process_visuals(delta)
	else:
		# Smooth mesh scale for all players (slide/crouch visual)
		var lowered := slide_crouch.is_sliding or slide_crouch.is_crouching
		var target_scale_y := SlideCrouchSystem.CROUCH_MESH_SCALE_Y if lowered else slide_crouch._original_mesh_scale_y
		body_mesh.scale.y = lerpf(body_mesh.scale.y, target_scale_y, 12.0 * delta)
		body_mesh.scale.x = lerpf(body_mesh.scale.x, 1.0, 12.0 * delta)
		body_mesh.scale.z = lerpf(body_mesh.scale.z, 1.0, 12.0 * delta)
		# Reset rotation back to upright when not in kamikaze
		body_mesh.rotation.x = lerpf(body_mesh.rotation.x, 0.0, 10.0 * delta)
		body_mesh.rotation.y = lerpf(body_mesh.rotation.y, 0.0, 10.0 * delta)
		var height_ratio := body_mesh.scale.y / slide_crouch._original_mesh_scale_y
		body_mesh.position.y = slide_crouch._original_mesh_y * height_ratio

	# Update mesh visibility based on alive state
	body_mesh.visible = is_alive
	weapon_mount.visible = is_alive and not kamikaze_system.is_kamikaze and not grapple_system.is_grappling

	# Check if synced weapon visuals changed — load new model/sound on clients
	if equipped_gun_model_path != _last_synced_gun_model_path:
		_last_synced_gun_model_path = equipped_gun_model_path
		_load_gun_model(equipped_gun_model_path)
	if equipped_fire_sound_path != _last_synced_fire_sound_path:
		_last_synced_fire_sound_path = equipped_fire_sound_path
		_load_fire_sound(equipped_fire_sound_path)

	# --- 3D health bar above non-local players (bots and other players) ---
	if not is_local:
		_update_health_label_3d()


## ======================================================================
##  Utility functions
## ======================================================================

func _get_barrel_position() -> Vector3:
	## Returns the world-space position of the gun barrel tip.
	if current_weapon and current_weapon.weapon_data:
		var offset: Vector3 = current_weapon.weapon_data.barrel_offset
		return weapon_mount.global_transform * offset
	return camera_pivot.global_position


func _get_camera_aim_target(cam_origin: Vector3, cam_forward: Vector3) -> Vector3:
	## Raycast from the camera through screen-center to find the aim target.
	var space_state := get_world_3d().direct_space_state
	var far_point := cam_origin + cam_forward * 1000.0
	var query := PhysicsRayQueryParameters3D.create(cam_origin, far_point)
	query.exclude = [get_rid()]
	query.collision_mask = 0xFFFFFFFF
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position
	return far_point


func _push_nearby_bubbles() -> void:
	## Server-only: push nearby bubbles away from the player using impulses.
	var projectiles := get_tree().current_scene.get_node_or_null("Projectiles")
	if projectiles == null:
		return

	var player_pos := global_position + Vector3(0, 0.9, 0)
	var player_speed := velocity.length()

	for child in projectiles.get_children():
		if not child is RigidBody3D:
			continue
		if not child.has_method("apply_push_impulse"):
			continue
		if not is_instance_valid(child):
			continue

		var body: RigidBody3D = child as RigidBody3D
		var to_bubble := body.global_position - player_pos
		var dist := to_bubble.length()
		var push_threshold := 1.4

		if dist < push_threshold and dist > 0.01:
			var overlap := 1.0 - (dist / push_threshold)
			var push_dir := to_bubble.normalized()
			var speed_factor := maxf(player_speed * 0.3, 0.5)
			var impulse := push_dir * overlap * speed_factor * 0.4
			impulse.y += 0.2 * overlap
			body.apply_push_impulse(impulse)


## ======================================================================
##  Chest interaction (E key opens nearest chest in range)
## ======================================================================

func _try_open_nearby_chest() -> bool:
	## Server-only: find the nearest closed LootChest within interact range and open it.
	## Returns true if a chest was opened, false otherwise.
	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		world_items = get_tree().current_scene

	var best_chest: Node = null
	var best_dist: float = INF

	for child in world_items.get_children():
		if not child is LootChest:
			continue
		if child.is_open:
			continue
		var dist: float = global_position.distance_to(child.global_position)
		if dist < LootChest.CHEST_INTERACT_RANGE and dist < best_dist:
			best_chest = child
			best_dist = dist

	if best_chest != null:
		best_chest.open(peer_id)
		return true
	return false


## ======================================================================
##  3D health bar (visible above non-local players)
## ======================================================================

func _update_health_label_3d() -> void:
	## Create or update a billboard Label3D showing this player's health above their head.
	## Only shown for non-local players (bots and other human players).
	if not is_alive:
		if _health_label_3d and is_instance_valid(_health_label_3d):
			_health_label_3d.visible = false
		return

	if _health_label_3d == null or not is_instance_valid(_health_label_3d):
		_health_label_3d = Label3D.new()
		_health_label_3d.font_size = 36
		_health_label_3d.outline_size = 8
		_health_label_3d.outline_modulate = Color(0, 0, 0)
		_health_label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_health_label_3d.position = Vector3(0, 2.2, 0)
		_health_label_3d.pixel_size = 0.005
		_health_label_3d.no_depth_test = true
		add_child(_health_label_3d)

	_health_label_3d.visible = true
	_health_label_3d.text = "HP: %d / %d" % [ceili(health), int(MAX_HEALTH)]

	# Color based on health percentage
	var hp_ratio: float = health / MAX_HEALTH
	if hp_ratio > 0.6:
		_health_label_3d.modulate = Color(0.3, 1.0, 0.3)
	elif hp_ratio > 0.3:
		_health_label_3d.modulate = Color(1.0, 0.8, 0.2)
	else:
		_health_label_3d.modulate = Color(1.0, 0.2, 0.2)


## ======================================================================
##  Combat / Death / Respawn
## ======================================================================

func take_damage(amount: float, attacker_id: int) -> void:
	## Server-only: apply damage to this player.
	if not multiplayer.is_server() or not is_alive:
		return
	health -= amount
	heat_system.on_damage_taken(amount)
	if health <= 0.0:
		health = 0.0
		die(attacker_id)


func die(killer_id: int) -> void:
	## Server-only: handle player death.
	is_alive = false
	_respawn_timer = RESPAWN_DELAY
	body_mesh.visible = false
	# End slide/crouch if active
	if slide_crouch.is_sliding:
		slide_crouch.end_slide()
	if slide_crouch.is_crouching:
		slide_crouch.end_crouch()
	# Reset kamikaze state if active
	if kamikaze_system.is_active():
		kamikaze_system.reset_state()
	# Reset grapple if swinging
	if grapple_system.is_active():
		grapple_system.reset_state()
	# Disable collision while dead
	$CollisionShape3D.set_deferred("disabled", true)
	# Clear inventory on death
	if inventory:
		inventory.clear_all()
	# Drop weapon
	clear_equipped_weapon()
	# Reset heat
	heat_system.reset()
	# Trigger demon stalker (activates on first death, repositions on subsequent)
	if not demon_system.is_eliminated:
		demon_system.on_player_death()
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
	# Demon-eliminated players cannot respawn
	if demon_system.is_eliminated:
		return
	is_alive = true
	health = MAX_HEALTH
	body_mesh.visible = true
	$CollisionShape3D.set_deferred("disabled", false)

	var map := get_tree().current_scene
	var spawns := map.get_node("PlayerSpawnPoints").get_children()
	if spawns.size() > 0:
		var spawn_point: Marker3D = spawns[randi() % spawns.size()]
		global_position = spawn_point.global_position
		velocity = Vector3.ZERO

	print("Player %d respawned" % peer_id)


## ======================================================================
##  Weapon equip / model loading
## ======================================================================

func clear_equipped_weapon() -> void:
	## Clear current weapon node and gun model. Used by die(), scrap, slot switching.
	if current_weapon:
		current_weapon.queue_free()
		current_weapon = null
	if _current_gun_model:
		_current_gun_model.queue_free()
		_current_gun_model = null
	equipped_gun_model_path = ""
	equipped_fire_sound_path = ""


func equip_weapon(weapon_data: WeaponData) -> void:
	## Server-only: equip a weapon by creating the appropriate weapon node.
	if current_weapon != null:
		current_weapon.queue_free()

	if weapon_data.is_hitscan:
		current_weapon = WeaponHitscan.new()
	elif weapon_data.projectile_scene != null:
		current_weapon = WeaponProjectileScript.new()
	else:
		current_weapon = WeaponMeleeScript.new()

	current_weapon.setup(weapon_data)
	add_child(current_weapon)

	equipped_gun_model_path = weapon_data.gun_model_path
	equipped_fire_sound_path = weapon_data.fire_sound_path

	_load_gun_model(weapon_data.gun_model_path)
	_load_fire_sound(weapon_data.fire_sound_path)


func _load_gun_model(model_path: String) -> void:
	## Load a .glb gun model and attach it to the weapon mount.
	if _current_gun_model != null:
		_current_gun_model.queue_free()
		_current_gun_model = null

	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return

	var scene: PackedScene = load(model_path)
	if scene == null:
		return

	_current_gun_model = scene.instantiate()
	_current_gun_model.scale = Vector3(0.15, 0.15, 0.15)
	weapon_mount.add_child(_current_gun_model)


func _load_fire_sound(sound_path: String) -> void:
	## Load a fire sound .ogg into the AudioStreamPlayer3D.
	if sound_path.is_empty() or not ResourceLoader.exists(sound_path):
		fire_sound_player.stream = null
		return

	var stream: AudioStream = load(sound_path)
	fire_sound_player.stream = stream


## ======================================================================
##  Item pickup proxy (called from world_item.gd via has_method check)
## ======================================================================

func _on_item_pickup(world_item: Node) -> void:
	## Proxy: delegates to ItemManager subsystem.
	item_manager.on_item_pickup(world_item)


## ======================================================================
##  Inventory RPCs (called from inventory_ui.gd on the client)
## ======================================================================

@rpc("any_peer", "call_remote", "reliable")
func rpc_sacrifice_item(sacrifice_idx: int, target_idx: int) -> void:
	## Client requests sacrificing one item to extend another.
	if not multiplayer.is_server():
		return
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
		elif stack.item_data is GadgetData or stack.item_data is ConsumableData:
			inventory.equip_slot(index)
			clear_equipped_weapon()


@rpc("any_peer", "call_local", "reliable")
func rpc_slot_ammo(ammo_index: int, weapon_index: int) -> void:
	## Client requests slotting an ammo module into a weapon.
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != peer_id:
		return
	if inventory == null:
		return

	if ammo_index < 0 or ammo_index >= inventory.items.size():
		return
	if weapon_index < 0 or weapon_index >= inventory.items.size():
		return

	var ammo_stack: ItemStack = inventory.items[ammo_index]
	var weapon_stack: ItemStack = inventory.items[weapon_index]

	var valid_ammo: bool = ammo_stack.item_data is WeaponData and ammo_stack.item_data.can_slot_as_ammo
	if not valid_ammo:
		return
	if not weapon_stack.item_data is WeaponData:
		return
	if ammo_index == weapon_index:
		return
	if not weapon_stack.item_data.can_receive_ammo:
		return
	if weapon_stack.slotted_ammo != null:
		return

	# Permanent merge: combine timers, consume ammo item
	var merged_time: float = (weapon_stack.burn_time_remaining + ammo_stack.burn_time_remaining) * 0.8
	weapon_stack.burn_time_remaining = merged_time
	weapon_stack.slotted_ammo = ammo_stack.item_data
	weapon_stack.slotted_ammo_source_index = -1

	print("Player %d merged %s into %s (timer: %.0fs)" % [peer_id, ammo_stack.item_data.item_name, weapon_stack.item_data.item_name, merged_time])

	if ammo_index < weapon_index:
		weapon_index -= 1
	inventory.remove_item(ammo_index)


@rpc("any_peer", "call_local", "reliable")
func rpc_unslot_ammo(_weapon_index: int) -> void:
	## Ammo merging is permanent — this RPC is now a no-op.
	pass
