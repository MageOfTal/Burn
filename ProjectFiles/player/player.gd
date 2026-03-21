extends RigidBody3D
class_name Player

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.
##
## Uses RigidBody3D with custom_integrator=true so the player participates in
## Jolt's rigid body solver directly. Physics objects (toads, boulders, etc.)
## collide with the player natively via layer 10 (physics push layer).
##
## Jolt handles ALL position integration and collision response (bumps, walls,
## depenetration). Movement sets velocity each frame; Jolt integrates it next
## frame. A downward-only Y-snap in post_physics_step keeps the player glued
## to the floor surface without fighting Jolt's upward depenetration for bumps.
## Wall-slide decomposes movement into wall-parallel and wall-perpendicular
## axes so that move_toward() only steers the parallel component.
##
## Subsystems (child nodes):
##   SlideCrouchSystem — slide/crouch physics
##   KamikazeSystem — kamikaze missile flight, explosion, flashbang
##   CombatVFX — weapon tracer lines, melee arcs, ADS visuals, scope
##   ItemManager — item pickup, drop, extend, scrap ground (X), scrap equipped (O)
##   HeatSystem — heat/fever combat multipliers
##   Inventory — item storage, burn fuel, sacrifice
##   GrappleSystem — grappling hook swing physics
##   DemonSystem — per-player demon stalker (spawns on first death)


const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

## Gravity applied manually in _server_process (gravity_scale=0 on the RigidBody3D
## so Jolt doesn't double-apply). Subsystems (slide_crouch, etc.) also read this.
var gravity: float = 22.05

## Velocity alias — maps to RigidBody3D.linear_velocity for convenience.
## All subsystems read/write player.velocity; this maps to linear_velocity.
var velocity: Vector3:
	get: return linear_velocity
	set(v): linear_velocity = v


## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1
## True for server-controlled bot players.
var is_bot: bool = false
## True when player is inside the Toad Dimension (immune to fall death).
var in_toad_dimension: bool = false

## Layer 10 — physics push layer (directly on the player RigidBody3D).
const PLAYER_PUSH_LAYER: int = CollisionLayers.PLAYERS_PUSH

## Combat state (synced via ServerSync)
var health: float = MAX_HEALTH
var is_alive: bool = true

## ADS state — synced via ServerSync
var is_aiming: bool = false

## Current weapon (server-managed)
var current_weapon: WeaponBase = null
var _respawn_timer: float = 0.0

## Input counter consumption — server tracks last-consumed count for each
## monotonic counter in PlayerInput. See player_input.gd for details.
var _last_jump := 0
var _last_pickup := 0
var _last_extend := 0
var _last_scrap := 0
var _last_scrap_inv := 0
var _last_slot := 0
## Frame-local flag: true if jump was pressed this frame. Set at the top of
## _server_process() and read by subsystems (slide_crouch_system, etc.)
var _frame_jump := false

## DEBUG: wall-slide diagnostics (toggle with F9)
var _debug_wall := false
var _jump_debug_frames: int = 0
var _debug_wall_key_held := false
## DEBUG: movement capture (toggle with F10) — gates ALL movement logging
var capture_movement := false
var _capture_key_held := false

## Forfeit (hold P to self-kill)
var _forfeit_hold_time := 0.0
const FORFEIT_DURATION := 3.0

## Kill store bonuses (persist after death, synced via ServerSync)
## Array of bonus IDs (ints 0-12). Empty = no bonuses.
var active_bonuses: Array = []

## Second Wind bonus timer (Bonus ID 12)
var _second_wind_timer: float = 0.0

## Synced weapon visual paths — clients use these to load 3D model + sound
var equipped_gun_model_path: String = ""
var equipped_fire_sound_path: String = ""
## Synced ADS properties — clients need these for scope/FOV visuals
var equipped_ads_fov: float = 0.0
var equipped_has_scope: bool = false
var _current_gun_model: Node3D = null
var _last_synced_gun_model_path: String = ""
var _last_synced_fire_sound_path: String = ""

## Network interpolation — synced via ServerSync instead of raw position/rotation.
## Server writes these each physics frame; clients lerp toward them smoothly.
var sync_position: Vector3 = Vector3.ZERO
var sync_rotation_y: float = 0.0
const INTERP_SPEED := 18.0  ## Higher = snappier, lower = smoother (18 ≈ ~55ms to 95%)

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
@onready var store_ui: Control = $HUDLayer/StoreUI

## Player collision layers — on both layer 8 (player targeting) and layer 10 (physics push).
const PLAYER_COLLISION_LAYER: int = CollisionLayers.PLAYER_LAYER
const PLAYER_COLLISION_MASK: int = CollisionLayers.PLAYER_MASK

## Subsystem references
@onready var movement: PlayerMovement = $PlayerMovement
@onready var combat: PlayerCombat = $PlayerCombat
@onready var slide_crouch: SlideCrouchSystem = $SlideCrouchSystem
@onready var kamikaze_system: KamikazeSystem = $KamikazeSystem
@onready var combat_vfx: CombatVFX = $CombatVFX
@onready var item_manager: ItemManager = $ItemManager
@onready var grapple_system: GrappleSystem = $GrappleSystem
@onready var demon_system: DemonSystem = $DemonSystem

signal player_killed(victim_id: int, killer_id: int)


func _enter_tree() -> void:
	# Set multiplayer authority in _enter_tree, NOT _ready.
	# Godot's MultiplayerSpawner requires synchronizer authority to be set
	# here so they get their network IDs before replication starts.
	# @onready vars aren't available yet, so use $NodePath directly.
	peer_id = name.to_int()
	if is_bot:
		$InputSync.set_multiplayer_authority(1)
		$PlayerInput.set_multiplayer_authority(1)
	else:
		$InputSync.set_multiplayer_authority(peer_id)
		$PlayerInput.set_multiplayer_authority(peer_id)


func _exit_tree() -> void:
	pass


func _ready() -> void:
	peer_id = name.to_int()
	var my_id: int = multiplayer.get_unique_id()
	var is_local: bool = (peer_id == my_id)
	print("[Player] _ready() — peer_id=%d  my_id=%d  is_local=%s  is_bot=%s  is_server=%s" % [
		peer_id, my_id, str(is_local), str(is_bot), str(multiplayer.is_server())])
	# Server: copy current position into sync vars so spawn replication sends it.
	# Client: sync vars already received from the server (spawn=true), so apply
	# them to the node's transform — otherwise the player starts at origin.
	if multiplayer.is_server():
		sync_position = global_position
		sync_rotation_y = rotation.y
	else:
		if sync_position != Vector3.ZERO:
			global_position = sync_position
		rotation.y = sync_rotation_y

	# Tag for fast C++ shielding classification (tag 2 = PLAYER).
	PhysicsServer3D.body_set_shielding_tag(get_rid(), 2)

	# Duplicate collision shape so runtime resize doesn't affect other players
	var col_shape := $CollisionShape3D
	if col_shape.shape:
		col_shape.shape = col_shape.shape.duplicate()
		_original_capsule_height = col_shape.shape.height
	_original_camera_y = $CameraPivot.position.y
	_original_mesh_y = body_mesh.position.y
	_original_mesh_scale_y = body_mesh.scale.y

	# Setup subsystems
	movement.setup(self)
	combat.setup(self)
	heat_system.setup(self)
	slide_crouch.setup(self)
	kamikaze_system.setup(self)
	combat_vfx.setup(self)
	item_manager.setup(self)
	grapple_system.setup(self)
	demon_system.setup(self)

	# Tell inventory which peer owns it so server→client sync works
	if inventory:
		inventory._owner_peer_id = peer_id

	# Put player visuals on both render layer 1 (overworld) and 2 (toad dimension)
	# so the camera sees players regardless of which dimension it's showing.
	_set_player_render_layers()

	# RigidBody3D setup: physics material for contact response
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.0
	phys_mat.friction = 0.0  # All ground movement is script-driven
	physics_material_override = phys_mat

	# Client peers: freeze the RigidBody3D to prevent physics simulation.
	# Clients don't run game physics — position is synced from server.
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC

	# Bots: flag input as bot, attach AI brain (server-side only), hide HUD/camera
	if is_bot:
		player_input.is_bot = true
		camera.current = false
		camera_pivot.visible = false
		# Bots are grey to distinguish from white players
		if body_mesh and body_mesh.material_override is ShaderMaterial:
			body_mesh.material_override = body_mesh.material_override.duplicate()
			body_mesh.material_override.set_shader_parameter("albedo_color", Color(0.5, 0.5, 0.5, 1.0))
		if player_hud:
			player_hud.visible = false
		if inventory_ui:
			inventory_ui.visible = false
		if store_ui:
			store_ui.visible = false
		if multiplayer.is_server():
			var brain_script := preload("res://player/bot_brain.gd")
			var brain := Node.new()
			brain.set_script(brain_script)
			brain.name = "BotBrain"
			add_child(brain)
			brain.setup(self)
		return

	if peer_id == multiplayer.get_unique_id():
		print("[Player] peer_id=%d is LOCAL — setting up camera, HUD, input" % peer_id)
		camera.current = true
		# Mouse capture is deferred via player_input._try_capture_mouse() —
		# don't capture here if loading screen is still up.
		if not (has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null):
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		if player_hud and player_hud.has_method("setup"):
			player_hud.setup(self)
		var gadget_xhair := player_hud.get_node_or_null("GadgetCrosshair") if player_hud else null
		if gadget_xhair and gadget_xhair.has_method("setup"):
			gadget_xhair.setup(self)
		if inventory_ui and inventory_ui.has_method("setup"):
			inventory_ui.setup(self)
			inventory_ui.visible = false
		if store_ui and store_ui.has_method("setup"):
			store_ui.setup(self)
			store_ui.visible = false
		print("[Player] LOCAL player %d ready!" % peer_id)
	else:
		print("[Player] peer_id=%d is REMOTE — hiding HUD/camera" % peer_id)
		camera.current = false
		camera_pivot.visible = false
		if player_hud:
			player_hud.visible = false
		if inventory_ui:
			inventory_ui.visible = false
		if store_ui:
			store_ui.visible = false


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	## Delegates to PlayerMovement for wall-slide and dynamic body tracking.
	if not multiplayer.is_server():
		return
	movement.on_integrate_forces(state)


func _physics_process(delta: float) -> void:
	# Skip all processing while loading screen is up (terrain collision may not be ready)
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		return

	# Toggle inventory UI for the local player
	if peer_id == multiplayer.get_unique_id() and inventory_ui:
		inventory_ui.visible = player_input.inventory_open

	# DEBUG: F9 toggles wall-slide diagnostics for the local player
	if peer_id == multiplayer.get_unique_id() and Input.is_key_pressed(KEY_F9) and not _debug_wall_key_held:
		_debug_wall = not _debug_wall
		_debug_wall_key_held = true
		print("[WALL_DEBUG] === %s ===" % ("ENABLED" if _debug_wall else "DISABLED"))
	if not Input.is_key_pressed(KEY_F9):
		_debug_wall_key_held = false
	# DEBUG: F10 toggles dynamic contact logging
	if peer_id == multiplayer.get_unique_id() and Input.is_key_pressed(KEY_F10) and not _capture_key_held:
		GameManager.debug_dynamic_contact_log = not GameManager.debug_dynamic_contact_log
		_capture_key_held = true
		print("[F10] Dynamic contact log: %s" % ("ON" if GameManager.debug_dynamic_contact_log else "OFF"))
	if not Input.is_key_pressed(KEY_F10):
		_capture_key_held = false

	# Debug freecam: freeze player physics but keep rendering visuals
	var freecam_frozen: bool = GameManager.debug_freecam_active and peer_id == multiplayer.get_unique_id()

	if multiplayer.is_server() and not freecam_frozen:
		Profiler.begin("player_physics")
		var _t_tick_player := Time.get_ticks_usec()

		# --- JUMP DEBUG: track position for 30 frames after a jump ---
		if _frame_jump:
			_jump_debug_frames = 30
		if _jump_debug_frames > 0 and peer_id == 1 and capture_movement:
			print("[JUMP DBG %02d] pos_y=%.4f vel_y=%.3f grounded=%s linvel_y=%.3f" % [
				30 - _jump_debug_frames, global_position.y, velocity.y, str(movement._is_grounded), linear_velocity.y])
			_jump_debug_frames -= 1

		# Update floor detection
		movement.pre_physics_step(delta)

		var _dbg_vel_y_after_detect := velocity.y
		var _dbg_grounded_after_detect := movement._is_grounded
		var _dbg_floor_normal := movement._floor_normal

		# Tick Second Wind timer
		if _second_wind_timer > 0.0:
			_second_wind_timer -= delta

		# Server game logic (input, movement, combat, subsystems)
		_server_process(delta)

		var _dbg_vel_y_after_move := velocity.y

		# Save grounded velocity for launch detection
		movement.post_physics_step(delta, grapple_system.is_active())

		if capture_movement and peer_id == 1:
			# Per-frame full velocity log (every frame while capturing)
			var sliding := slide_crouch.is_sliding
			var angle := rad_to_deg(movement._floor_normal.angle_to(Vector3.UP))
			var surface := movement._dbg_contact_body_class
			var mv_line := "[MV] pos=(%.2f,%.2f,%.2f) vel=(%.3f,%.3f,%.3f) h=%.2f gnd=%s angle=%.1f° slide=%s on=%s" % [
				global_position.x, global_position.y, global_position.z,
				velocity.x, velocity.y, velocity.z,
				Vector2(velocity.x, velocity.z).length(),
				str(movement._is_grounded), angle, str(sliding),
				surface if surface != "" else "none"]
			# Wall/obstacle contact details
			if movement._obstacle_normals.size() > 0:
				var wall_str := ""
				for on in movement._obstacle_normals:
					wall_str += " obs=(%.3f,%.3f)" % [on.x, on.y]
				mv_line += wall_str
			print(mv_line)

		# Update sync vars AFTER all server movement
		sync_position = global_position
		sync_rotation_y = rotation.y

		GameManager.tick_add("player", Time.get_ticks_usec() - _t_tick_player)
		Profiler.end("player_physics")

	# --- Client-side interpolation (all players on non-server peers) ---
	# Server runs physics directly via _server_process(); clients apply the
	# synced position/rotation for ALL player nodes, including the local one.
	# If distance is large (spawn, respawn, teleport), snap immediately.
	if not multiplayer.is_server():
		var dist_sq := global_position.distance_squared_to(sync_position)
		if dist_sq > 25.0:  # > 5 meters — snap (spawn/respawn/teleport)
			global_position = sync_position
			rotation.y = sync_rotation_y
		else:
			var weight := 1.0 - exp(-INTERP_SPEED * delta)
			global_position = global_position.lerp(sync_position, weight)
			rotation.y = lerp_angle(rotation.y, sync_rotation_y, weight)


func _process(delta: float) -> void:
	Profiler.begin("player_render")
	# All client visuals run in _process() so they update every render frame and
	# sample the engine's physics-interpolated positions. This prevents visual
	# artifacts (e.g. grapple rope splitting) caused by drawing at the physics
	# tick rate while the player body is interpolated between ticks.
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		Profiler.end("player_render")
		return
	# Visual interpolation debug: compare interpolated position with physics position
	if capture_movement and peer_id == multiplayer.get_unique_id():
		var interp_xform := get_global_transform_interpolated()
		var vis_pos: Vector3 = interp_xform.origin
		var phys_pos: Vector3 = global_position
		var diff := vis_pos - phys_pos
		var diff_h := Vector2(diff.x, diff.z).length()
		if diff_h > 0.0005:  # > 0.5mm horizontal
			print("  [INTERP] vis=(%.4f,%.4f,%.4f) phys=(%.4f,%.4f,%.4f) diff_h=%.3fmm" % [
				vis_pos.x, vis_pos.y, vis_pos.z,
				phys_pos.x, phys_pos.y, phys_pos.z,
				diff_h * 1000.0])
	_client_process(delta)
	Profiler.end("player_render")


## ======================================================================
##  Server-side game loop
## ======================================================================

func _server_process(delta: float) -> void:
	# --- Consume one-shot input counters (once per frame, before anything reads them) ---
	_frame_jump = player_input.jump_count > _last_jump
	if _frame_jump:
		_last_jump = player_input.jump_count
	var wants_pickup: bool = player_input.pickup_count > _last_pickup
	if wants_pickup:
		_last_pickup = player_input.pickup_count
	var wants_extend: bool = player_input.extend_count > _last_extend
	if wants_extend:
		_last_extend = player_input.extend_count
	var wants_scrap: bool = player_input.scrap_count > _last_scrap
	if wants_scrap:
		_last_scrap = player_input.scrap_count
	var wants_scrap_inv: bool = player_input.scrap_inv_count > _last_scrap_inv
	if wants_scrap_inv:
		_last_scrap_inv = player_input.scrap_inv_count
	var wants_slot: bool = player_input.slot_count > _last_slot
	if wants_slot:
		_last_slot = player_input.slot_count

	# Demon always ticks (chases even while player is dead/respawning)
	demon_system.process(delta)

	# Handle respawn timer
	if not is_alive:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			_do_respawn()
		return

	# Demon catch animation: freeze all movement, sinking is handled directly
	# by _tick_catch_animation modifying global_position.y
	if demon_system.is_being_caught:
		velocity = Vector3.ZERO
		return

	# --- Forfeit: hold P for 3 seconds to self-kill ---
	if player_input.action_forfeit:
		_forfeit_hold_time += delta
		if _forfeit_hold_time >= FORFEIT_DURATION:
			_forfeit_hold_time = 0.0
			die(peer_id)
			return
	else:
		_forfeit_hold_time = 0.0

	# Fall-through-ground safety (skip in Toad Dimension — arena at Y=-500)
	if global_position.y < -50.0 and not in_toad_dimension:
		reset_movement_states()
		_do_respawn()
		return

	# --- Kamikaze Missile state machine ---
	if kamikaze_system.is_active():
		kamikaze_system.process(delta)
		return

	# --- Grapple: feed shoot input for fire/release toggle ---
	# Must run BEFORE the grapple state machine so release is detected same frame
	if current_weapon == null and inventory:
		if inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size() and inventory.items[inventory.equipped_index] != null:
			var eq_grapple: ItemStack = inventory.items[inventory.equipped_index]
			if eq_grapple.item_data is GadgetData and (eq_grapple.item_data as GadgetData).gadget_type == 0:
				grapple_system.handle_shoot_input(player_input.action_shoot)

	# --- Grapple charge recharge (always ticks, even when not swinging) ---
	grapple_system.tick_charges(delta)

	# --- Grapple swing state machine ---
	if grapple_system.is_active():
		grapple_system.process(delta)
		return

	# Slide cooldown
	slide_crouch.tick_cooldown(delta)

	# Grounded velocity management (gravity is applied at the end of movement)
	movement.begin_movement(delta)

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Slide / crouch / normal movement
	if slide_crouch.is_sliding:
		slide_crouch.process_slide(delta)
	elif slide_crouch.is_crouching:
		slide_crouch.process_crouch(delta)
	else:
		# Post-slide jump window: rapidly decelerate, but jumping restores slide speed
		if not slide_crouch.process_post_slide_window(delta):
			# Jump (slide-jump is handled in process_slide; crouch-jump in process_crouch)
			if _frame_jump and movement.can_jump():
				movement.do_jump()
			elif _frame_jump and not movement.can_jump():
				movement.do_air_jump()

			# While airborne, queue/cancel slide for when we land
			if not is_on_floor():
				if player_input.action_slide:
					slide_crouch.queue_slide_on_land()
				else:
					slide_crouch.clear_slide_on_land()

			# Check if we should start a slide
			if player_input.action_slide and slide_crouch.can_start_slide():
				slide_crouch.start_slide()
				slide_crouch.process_slide(delta)
			elif player_input.action_slide and is_on_floor():
				slide_crouch.start_crouch()
				slide_crouch.process_crouch(delta)
			else:
				movement.process_normal_movement(delta)

	# Snap + gravity: runs after all movement branches so it's never skipped
	movement.apply_snap_and_gravity(delta)

	# Track pre-land velocity for slide-on-land momentum transfer
	slide_crouch.track_pre_land_velocity()

	# --- Slide-on-land system ---
	slide_crouch.process_landing(delta)

	# Slot switching (0 = shoe, 1-6 = weapon slots)
	if wants_slot:
		if player_input.slot_select == 0:
			# Select shoe slot
			if inventory:
				inventory.shoe_selected = true
				clear_equipped_weapon()
				inventory.equipped_index = -1
				inventory._notify_sync()
				if grapple_system.is_active():
					grapple_system._do_release(false)
		else:
			var slot_idx: int = player_input.slot_select - 1
			if inventory and slot_idx < inventory.items.size() and inventory.items[slot_idx] != null:
				inventory.shoe_selected = false
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

	# --- Extend selected item lifespan (F key) ---
	if wants_extend and inventory:
		if inventory.shoe_selected:
			item_manager.try_extend_shoe()
		else:
			item_manager.try_extend_equipped_item()

	# --- Open nearby chest OR store OR pickup nearby item (E key) ---
	# Unified: find the single closest interactable and act on it.
	# Note: get_interact_distance() uses popup range (visual), but the
	# actual action must be within the tighter interact range.
	if wants_pickup and inventory:
		var interact_target := _find_closest_interactable()
		if interact_target is LootChest:
			var chest: LootChest = interact_target as LootChest
			if not chest.is_open and global_position.distance_to(chest.global_position) < LootChest.CHEST_INTERACT_RANGE:
				chest.open(peer_id)
		elif interact_target is KillStore:
			if global_position.distance_to(interact_target.global_position) < KillStore.STORE_INTERACT_RANGE:
				_open_store_for_player()
		elif interact_target is WorldItem:
			item_manager.try_pickup_item(interact_target)

	# --- Scrap nearby ground item (X key) ---
	if wants_scrap and inventory:
		item_manager.try_scrap_ground_item()

	# --- Scrap selected inventory item (O key) ---
	if wants_scrap_inv and inventory:
		if inventory.shoe_selected:
			item_manager.try_scrap_shoe()
		else:
			item_manager.try_scrap_equipped_item()

	# --- Consumable activation: shoot while a consumable is equipped ---
	if player_input.action_shoot and current_weapon == null and inventory:
		if inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size() and inventory.items[inventory.equipped_index] != null:
			var eq_stack: ItemStack = inventory.items[inventory.equipped_index]
			if eq_stack.item_data is ConsumableData:
				var cons_data: ConsumableData = eq_stack.item_data as ConsumableData
				if cons_data.consumable_effect == 0:  # KAMIKAZE_MISSILE
					kamikaze_system.activate()
					inventory.remove_item(inventory.equipped_index)
				elif cons_data.consumable_effect == 1:  # MEDKIT
					combat.process_medkit_heal()

	# ADS + combat (delegated to PlayerCombat)
	combat.update_ads_state()
	if player_input.action_shoot and current_weapon != null and current_weapon.can_fire():
		combat.process_combat()






func is_on_floor() -> bool:
	## Proxy to PlayerMovement floor detection.
	return movement.is_on_floor()


func get_floor_normal() -> Vector3:
	## Proxy to PlayerMovement floor normal.
	return movement.get_floor_normal()




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
			combat_vfx.process_ads_visuals(delta, is_aiming, equipped_ads_fov, equipped_has_scope)

	# --- Grapple rope client visuals ---
	if grapple_system.is_grappling:
		var _vt0 := Time.get_ticks_usec()
		grapple_system.client_process_visuals(delta)
		var _vt1 := Time.get_ticks_usec()
		var _vis_us: float = _vt1 - _vt0
		if _vis_us > 500.0:
			print("[GRAPPLE VIS SPIKE] %.0fµs" % _vis_us)
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
		# During post-slide window, snap to standing immediately (no lerp through crouch)
		if slide_crouch._post_slide_timer > 0.0:
			body_mesh.scale.y = slide_crouch._original_mesh_scale_y
		else:
			body_mesh.scale.y = lerpf(body_mesh.scale.y, target_scale_y, 12.0 * delta)
		body_mesh.scale.x = lerpf(body_mesh.scale.x, 1.0, 12.0 * delta)
		body_mesh.scale.z = lerpf(body_mesh.scale.z, 1.0, 12.0 * delta)
		# Reset rotation back to upright when not in kamikaze
		body_mesh.rotation.x = lerpf(body_mesh.rotation.x, 0.0, 10.0 * delta)
		body_mesh.rotation.y = lerpf(body_mesh.rotation.y, 0.0, 10.0 * delta)
		var height_ratio := body_mesh.scale.y / slide_crouch._original_mesh_scale_y
		body_mesh.position.y = slide_crouch._original_mesh_y * height_ratio

	# Update mesh visibility based on alive state (stay visible during catch animation)
	body_mesh.visible = is_alive or demon_system.is_being_caught
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



## ======================================================================
##  Unified interaction (E key — closest interactable wins)
## ======================================================================

func _find_closest_interactable() -> Node:
	## Server-only: find the single closest interactable (WorldItem, LootChest,
	## or KillStore) using the same get_interact_distance() interface that the
	## client-side ProximityLabel uses for label display.
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var world_items := scene.get_node_or_null("WorldItems")
	if world_items == null:
		return null

	var best: Node = null
	var best_dist := INF

	for child in world_items.get_children():
		if not child.has_method("get_interact_distance"):
			continue
		var d: float = child.get_interact_distance(global_position)
		if d < best_dist:
			best_dist = d
			best = child

	return best


func _open_store_for_player() -> void:
	## Server-only: open the store UI for this player.
	# Bots don't use stores
	var net_mgr := get_node_or_null("/root/NetworkManager")
	if net_mgr and peer_id >= net_mgr.BOT_PEER_ID_START:
		return

	# Host opens store directly (peer 1 doesn't receive RPCs from itself)
	if peer_id == 1:
		if store_ui and store_ui.has_method("open_store"):
			store_ui.open_store()
	else:
		_rpc_open_store_ui.rpc_id(peer_id)


func _is_near_store() -> bool:
	## Server-only: check if this player is within interact range of any KillStore.
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var world_items := scene.get_node_or_null("WorldItems")
	if world_items == null:
		return false
	for child in world_items.get_children():
		if child is KillStore:
			if global_position.distance_to(child.global_position) < KillStore.STORE_INTERACT_RANGE:
				return true
	return false


@rpc("authority", "call_remote", "reliable")
func _rpc_open_store_ui() -> void:
	## Client-side: server tells us we're near a store, open the UI.
	if store_ui and store_ui.has_method("open_store"):
		store_ui.open_store()


@rpc("any_peer", "call_remote", "reliable")
func rpc_buy_bonus(bonus_id: int) -> void:
	## Server-only: validate and process a store purchase.
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	# Host (peer 1) calls this locally, so sender_id is 0 — allow it
	if sender_id != 0 and sender_id != peer_id:
		return

	# Validate bonus_id
	if bonus_id < 0 or bonus_id >= KillStore.BONUS_CATALOG.size():
		return

	# Already owned?
	if bonus_id in active_bonuses:
		return

	# Near a store?
	if not _is_near_store():
		return

	# Can afford?
	var cost: int = KillStore.BONUS_CATALOG[bonus_id]["cost"]
	if not inventory.has_kill_currency(cost):
		return

	# Purchase!
	inventory.spend_kill_currency(cost)
	active_bonuses.append(bonus_id)

	print("Player %d bought bonus '%s' for %d tokens (remaining: %.2f)" % [
		peer_id, KillStore.BONUS_CATALOG[bonus_id]["name"], cost, inventory.kill_currency])


func get_max_health() -> float:
	## Returns effective max health factoring in bonuses and heat.
	var base := MAX_HEALTH
	if 2 in active_bonuses:   # Thick Skin
		base += 15.0
	if 11 in active_bonuses:  # Juggernaut
		base += 40.0
	base += heat_system.get_health_bonus()
	return base


func has_bonus(bonus_id: int) -> bool:
	return bonus_id in active_bonuses


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
	var max_hp: float = get_max_health()
	_health_label_3d.text = "HP: %d / %d" % [ceili(health), int(max_hp)]

	# Color based on health percentage
	var hp_ratio: float = health / max_hp
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
	# No damage after victory
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		return
	# Blast Padding bonus: -20% damage taken
	if 6 in active_bonuses:
		amount *= 0.80
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
	# Zero physics state on death
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO
	movement.reset_movement()
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
	# Give the killer heat for the kill + award kill currency
	var players_container := get_parent()
	if players_container:
		var killer_node := players_container.get_node_or_null(str(killer_id))
		if killer_node and killer_node.has_node("HeatSystem"):
			killer_node.get_node("HeatSystem").on_kill()
		# Award kill currency (skip self-kills and zone kills)
		# Bot kills are worth 0.25 tokens; player kills are worth 1.0
		if killer_id != peer_id and killer_id != -1 and killer_node:
			if killer_node.has_node("Inventory"):
				var kill_value: float = 0.25 if is_bot else 1.0
				killer_node.get_node("Inventory").add_kill_currency(kill_value)
			# Vulture bonus: killer's kills drop a fuel canister at victim position
			if 10 in killer_node.active_bonuses:
				var map := get_tree().current_scene
				if map and map.has_method("spawn_world_item"):
					map.spawn_world_item(
						"res://items/definitions/fuel_uncommon.tres",
						global_position + Vector3(0, 0.5, 0),
						60.0,   # 60 second burn time
						-1      # No pickup immunity
					)
	player_killed.emit(peer_id, killer_id)
	print("Player %d killed by Player %d" % [peer_id, killer_id])

	# Kill feed: broadcast to all players (use {P:id} placeholders for client-side name coloring)
	var net_mgr := get_node_or_null("/root/NetworkManager")
	if net_mgr and net_mgr.has_method("broadcast_kill_feed"):
		var feed_text: String
		if killer_id == -1:
			# Zone kill
			feed_text = "{P:%d} [color=orange]died to the zone[/color]" % peer_id
		elif killer_id == peer_id:
			# Self-kill (forfeit)
			feed_text = "{P:%d} [color=gray]gave up[/color]" % peer_id
		else:
			var weapon_name := ""
			if players_container:
				var killer_node_for_feed := players_container.get_node_or_null(str(killer_id))
				if killer_node_for_feed and killer_node_for_feed.current_weapon and killer_node_for_feed.current_weapon.weapon_data:
					weapon_name = killer_node_for_feed.current_weapon.weapon_data.item_name
			feed_text = "{P:%d} [color=gray][%s][/color] {P:%d}" % [killer_id, weapon_name, peer_id]
		net_mgr.broadcast_kill_feed(feed_text)


func reset_movement_states() -> void:
	## Server-only: cancel any active movement abilities (grapple, kamikaze,
	## slide/crouch) and zero velocity.  Does NOT touch health, inventory,
	## heat, demon, or death state — used for toad dimension teleports.
	if slide_crouch.is_sliding:
		slide_crouch.end_slide()
	if slide_crouch.is_crouching:
		slide_crouch.end_crouch()
	if kamikaze_system.is_active():
		kamikaze_system.reset_state()
	if grapple_system.is_active():
		grapple_system.reset_state()
	velocity = Vector3.ZERO
	movement.reset_movement()


func _do_respawn() -> void:
	## Server-only: respawn at a random spawn point inside the current zone.
	# Demon-eliminated players cannot respawn
	if demon_system.is_eliminated:
		return
	is_alive = true
	health = MAX_HEALTH
	body_mesh.visible = true
	$CollisionShape3D.set_deferred("disabled", false)
	# Restore collision layers on respawn
	collision_layer = PLAYER_COLLISION_LAYER
	collision_mask = PLAYER_COLLISION_MASK

	var map := get_tree().current_scene
	var spawns := map.get_node("PlayerSpawnPoints").get_children()
	if spawns.size() > 0:
		# Filter to spawn points inside the current safe zone
		var zone: Node = get_node_or_null("/root/ZoneManager")
		var valid_spawns: Array[Node] = []
		if zone:
			for sp in spawns:
				if not zone.is_outside_zone(sp.global_position):
					valid_spawns.append(sp)

			# If no spawns are inside the zone, pick the closest one to zone center
			if valid_spawns.is_empty():
				var best_spawn: Node = spawns[0]
				var best_dist: float = INF
				for sp in spawns:
					var sp_xz := Vector2(sp.global_position.x, sp.global_position.z)
					var dist := sp_xz.distance_to(zone.zone_center)
					if dist < best_dist:
						best_dist = dist
						best_spawn = sp
				valid_spawns.append(best_spawn)
		else:
			for sp in spawns:
				valid_spawns.append(sp)

		var spawn_point: Marker3D = valid_spawns[randi() % valid_spawns.size()]
		global_position = spawn_point.global_position
		velocity = Vector3.ZERO

	# Reset movement state (air jumps, wall-slide, ground velocity, etc.)
	movement.reset_movement()

	# Sync input counters so presses during death don't phantom-fire on respawn
	_last_jump = player_input.jump_count
	_last_pickup = player_input.pickup_count
	_last_extend = player_input.extend_count
	_last_scrap = player_input.scrap_count
	_last_scrap_inv = player_input.scrap_inv_count
	_last_slot = player_input.slot_count
	_forfeit_hold_time = 0.0

	# Apply respawn fuel bonuses (kill store bonuses persist after death)
	var bonus_fuel: float = 0.0
	if 0 in active_bonuses:   # Iron Lungs: +100 starting fuel
		bonus_fuel += 100.0
	if 9 in active_bonuses:   # Phoenix Fuel: +500 starting fuel
		bonus_fuel += 500.0
	if bonus_fuel > 0.0 and inventory:
		inventory.burn_fuel += bonus_fuel
		inventory._notify_sync()

	# Second Wind bonus: 5s speed boost on respawn
	if 12 in active_bonuses:
		_second_wind_timer = 5.0

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
	equipped_ads_fov = 0.0
	equipped_has_scope = false


func equip_weapon(weapon_data: WeaponData) -> void:
	## Server-only: equip a weapon by creating the appropriate weapon node.
	if current_weapon != null:
		current_weapon.queue_free()

	current_weapon = WeaponFactory.create_weapon(weapon_data)
	add_child(current_weapon)

	equipped_gun_model_path = weapon_data.gun_model_path
	equipped_fire_sound_path = weapon_data.fire_sound_path
	equipped_ads_fov = weapon_data.ads_fov
	equipped_has_scope = weapon_data.has_scope

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
	_current_gun_model.scale = Vector3(0.6, 0.6, 0.6)
	_set_render_layers_recursive(_current_gun_model, 1 | 2)
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
	if inventory and index >= 0 and index < inventory.items.size() and inventory.items[index] != null:
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
	if ammo_stack == null or weapon_stack == null:
		return

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

	inventory.remove_item(ammo_index)



# ======================================================================
#  Trinket slot/unslot (shoe trinkets)
# ======================================================================

@rpc("any_peer", "call_local", "reliable")
func rpc_slot_trinket_on_shoe(trinket_bag_index: int) -> void:
	## Client requests slotting a trinket from the trinket bag onto the equipped shoe.
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != peer_id:
		return
	if inventory == null:
		return

	# Validate trinket bag index
	if trinket_bag_index < 0 or trinket_bag_index >= inventory.trinket_bag.size():
		return
	var trinket_stack: ItemStack = inventory.trinket_bag[trinket_bag_index]
	if trinket_stack == null or trinket_stack.item_data == null:
		return
	if not trinket_stack.item_data is TrinketData:
		return
	var trinket_data: TrinketData = trinket_stack.item_data as TrinketData
	if not trinket_data.attach_to_shoes:
		return

	# Validate shoe exists
	if inventory.equipped_shoe == null or inventory.equipped_shoe.item_data == null:
		return
	if not inventory.equipped_shoe.item_data is ShoeData:
		return
	var shoe_data: ShoeData = inventory.equipped_shoe.item_data as ShoeData

	# Check trinket slot capacity
	if inventory.equipped_shoe.slotted_trinkets.size() >= shoe_data.max_trinket_slots:
		return

	# Attach: move trinket data to shoe, remove from bag
	inventory.equipped_shoe.slotted_trinkets.append(trinket_data)
	inventory.trinket_bag.remove_at(trinket_bag_index)

	print("Player %d attached %s to %s" % [peer_id, trinket_data.item_name, shoe_data.item_name])

	inventory.trinket_bag_changed.emit()
	inventory.shoe_changed.emit()
	inventory.inventory_changed.emit()
	inventory._notify_sync()


@rpc("any_peer", "call_local", "reliable")
func rpc_unslot_trinket_from_shoe(trinket_slot_index: int) -> void:
	## Client requests removing a trinket from the equipped shoe back to trinket bag.
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != peer_id:
		return
	if inventory == null:
		return

	# Validate shoe and trinket slot
	if inventory.equipped_shoe == null:
		return
	if trinket_slot_index < 0 or trinket_slot_index >= inventory.equipped_shoe.slotted_trinkets.size():
		return

	var trinket_data: TrinketData = inventory.equipped_shoe.slotted_trinkets[trinket_slot_index]
	inventory.equipped_shoe.slotted_trinkets.remove_at(trinket_slot_index)

	# Try to return to trinket bag
	if inventory.trinket_bag.size() < Inventory.MAX_TRINKETS:
		var stack := ItemStack.create(trinket_data)
		inventory.trinket_bag.append(stack)
		print("Player %d detached %s back to bag" % [peer_id, trinket_data.item_name])
	else:
		# Bag full — drop to world
		var stack := ItemStack.create(trinket_data)
		var item_mgr := get_node_or_null("ItemManager")
		if item_mgr:
			item_mgr.drop_item_as_world_item(stack)
		print("Player %d detached %s — bag full, dropped to world" % [peer_id, trinket_data.item_name])

	inventory.trinket_bag_changed.emit()
	inventory.shoe_changed.emit()
	inventory.inventory_changed.emit()
	inventory._notify_sync()


## ======================================================================
##  Render layer setup — visible in both overworld and toad dimension
## ======================================================================

func _set_player_render_layers() -> void:
	## Set all VisualInstance3D children to render layers 1 | 2 so player meshes
	## are visible regardless of which dimension the camera is showing.
	## Layer 1 = overworld, Layer 2 = toad dimension.
	_set_render_layers_recursive(self, 1 | 2)


static func _set_render_layers_recursive(node: Node, layer_mask: int) -> void:
	if node is VisualInstance3D:
		node.layers = layer_mask
	for child in node.get_children():
		_set_render_layers_recursive(child, layer_mask)
