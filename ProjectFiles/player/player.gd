extends RigidBody3D
class_name Player

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.
##
## Uses RigidBody3D with custom_integrator=true so the player participates in
## Jolt's rigid body solver directly. Physics objects (toads, boulders, etc.)
## collide with the player natively — no shadow body proxy needed.
##
## GROUNDED movement bypasses Jolt's velocity integration for POSITION, but
## leaves velocity non-zero so Jolt's solver sees real movement speed for
## collision impulses (pushing toads, physics objects). Position is applied
## directly from _ground_velocity each frame. Jolt also integrates position
## from that velocity (unwanted), so the integration is undone at the start
## of the next _physics_process — before ground detection or movement run.
## This gives correct collision impulses AND correct position control.
##
## AIRBORNE movement uses Jolt's integration normally: linear_velocity contains
## Jolt's solver output, movement modifies it, and Jolt integrates position.
## When touching walls, movement is decomposed into wall-parallel and
## wall-perpendicular axes so that move_toward() only steers the parallel
## component — preserving Jolt's depenetration pushes.
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

const WeaponProjectileScript = preload("res://weapons/weapon_projectile.gd")
const WeaponMeleeScript = preload("res://weapons/weapon_melee.gd")

const SPEED := 9.1
const JUMP_VELOCITY := 10.5
const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

## Movement acceleration/deceleration
const ACCELERATION := 45.0         # ~0.16s to full speed — snappy
const DECELERATION := 30.0         # ~0.23s to stop — slight momentum
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 0.0        # No air friction — full momentum preservation

## Gravity applied manually in _server_process (gravity_scale=0 on the RigidBody3D
## so Jolt doesn't double-apply). Subsystems (slide_crouch, etc.) also read this.
var gravity: float = 17.5

## Velocity alias — bridges CharacterBody3D → RigidBody3D API.
## All subsystems continue to read/write player.velocity; this maps to linear_velocity.
var velocity: Vector3:
	get: return linear_velocity
	set(v): linear_velocity = v

## Floor detection constants (were CharacterBody3D scene properties)
const FLOOR_MAX_ANGLE: float = 0.8727  ## 50 degrees — steeper surfaces are walls
const FLOOR_SNAP_MARGIN: float = 0.3  ## Extra reach below feet for slope detection
const CAPSULE_RADIUS: float = 0.4  ## Must match CapsuleShape3D in player.tscn

## Floor detection state (replaces CharacterBody3D is_on_floor / get_floor_normal)
var _is_grounded: bool = false
var _floor_normal: Vector3 = Vector3.UP
var _floor_y: float = -INF  ## Y position of the floor surface (feet level)
var _was_grounded: bool = false  ## Previous frame's grounded state (for snap logic)

## Grounded velocity tracking — when on the floor, we bypass Jolt's velocity
## integration and control position directly. _ground_velocity stores the
## movement velocity between frames so we don't read Jolt's solver output
## (which would fight our position control and cause slope sliding).
var _ground_velocity: Vector3 = Vector3.ZERO

## Pre-solver velocity — saved at the end of each _physics_process BEFORE Jolt's
## solver runs next tick. Used to capture clean airborne momentum on landing
## instead of Jolt's contact-solver-contaminated velocity (which on slopes adds
## a large phantom horizontal component from the depenetration impulse).
var _pre_solver_velocity: Vector3 = Vector3.ZERO

## When true, the previous frame used grounded position control and left velocity
## non-zero so Jolt's solver could see real movement velocity for collision impulses
## (e.g. pushing toads). Jolt also integrates position from that velocity, which is
## unwanted — so we undo the integration at the start of the next _physics_process.
var _undo_jolt_integration: bool = false

## Dynamic body contact tracking (set in _integrate_forces each tick)
var _touching_dynamic_body: bool = false  ## True when ANY RigidBody3D contact exists
var _on_dynamic_body: bool = false  ## True when a RigidBody3D contact supports us from below (normal.y > 0.7)
var _dynamic_body_ref: RigidBody3D = null  ## The dynamic body we're touching

## Contact tolerance for is_on_floor() — true when capsule feet are within
## this distance of the floor surface. Must be large enough to absorb Jolt's
## solver depenetration (a few cm) without flickering, but small enough that
## a jump (10.5 m/s → ~0.175m after one 60Hz frame) registers as airborne
## on the very next physics tick.
const FLOOR_CONTACT_TOLERANCE: float = 0.1  ## 10cm — covers depenetration jitter


## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1
## True for server-controlled bot players.
var is_bot: bool = false
## True when player is inside the Toad Dimension (immune to fall death).
var in_toad_dimension: bool = false

## Layer 10 (bit 512) — physics push layer (was shadow body, now on the player directly).
const SHADOW_BODY_LAYER: int = 512

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
## Wall-slide: individual 2D normals of steep surfaces the player is touching,
## sampled from Jolt's contact solver via _integrate_forces(). The movement
## code picks the most relevant normal based on input direction, rather than
## averaging — averaging produces an unstable diagonal at corners where the
## capsule contacts two perpendicular faces.
var _wall_normals: Array[Vector2] = []
## Air-jump tracking for trinket-granted double jump. Reset on landing.
var _air_jumps_used: int = 0

## DEBUG: wall-slide diagnostics (toggle with F9)
var _debug_wall := false
var _jump_debug_frames: int = 0
var _debug_wall_key_held := false

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
const PLAYER_COLLISION_LAYER: int = 640   ## 128 | 512
const PLAYER_COLLISION_MASK: int = 2271   ## 1|2|4|8|16|64|128|2048

## Subsystem references
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

	# Duplicate collision shape so runtime resize doesn't affect other players
	var col_shape := $CollisionShape3D
	if col_shape.shape:
		col_shape.shape = col_shape.shape.duplicate()
		_original_capsule_height = col_shape.shape.height
	_original_camera_y = $CameraPivot.position.y
	_original_mesh_y = body_mesh.position.y
	_original_mesh_scale_y = body_mesh.scale.y

	# Setup subsystems
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
	phys_mat.friction = 0.0  # Zero friction — all movement is script-driven
	physics_material_override = phys_mat

	# Client peers: freeze the RigidBody3D to prevent physics simulation.
	# Clients don't run game physics — position is synced from server.
	if not multiplayer.is_server():
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC

	# Add VoxelViewer so the voxel terrain generates around each player.
	if not is_bot and ClassDB.class_exists(&"VoxelViewer"):
		var viewer: Node3D = ClassDB.instantiate(&"VoxelViewer")
		viewer.name = "VoxelViewer"
		add_child(viewer)

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
	## Called each physics tick. With custom_integrator=true, Jolt skips its own
	## gravity/damping but still integrates position from velocity during its step.
	## We DON'T call state.integrate_forces() — gravity is applied manually in
	## _physics_process(). We only sample contact normals for wall-slide detection.
	if not multiplayer.is_server():
		return

	# Track dynamic body contacts (for floor snap / grounding override)
	_touching_dynamic_body = false
	_on_dynamic_body = false
	_dynamic_body_ref = null

	# When airborne, use a tighter angle threshold for wall normals so that
	# edge contacts (~40-50° from vertical) are treated as walls. This prevents
	# the capsule from catching on wall top corners — without this, edge
	# contacts slip through the 60° floor threshold, the movement code applies
	# full horizontal input into the edge, and friction/reaction forces create
	# an equilibrium that holds the player on the corner.
	var wall_angle_threshold := FLOOR_MAX_ANGLE if _is_grounded else deg_to_rad(30.0)

	var normals: Array[Vector2] = []
	for i in state.get_contact_count():
		var normal: Vector3 = state.get_contact_local_normal(i)
		var collider := state.get_contact_collider_object(i)
		if collider is RigidBody3D:
			_touching_dynamic_body = true
			_dynamic_body_ref = collider
			# On top when contact normal is mostly upward (same threshold as
			# CharacterBody3D floor detection: ~45° from vertical)
			if normal.y > 0.7:
				_on_dynamic_body = true
		if normal.angle_to(Vector3.UP) > wall_angle_threshold:
			if collider is RigidBody3D:
				continue
			var n2 := Vector2(normal.x, normal.z).normalized()
			var is_dup := false
			for existing in normals:
				if n2.dot(existing) > 0.966:
					is_dup = true
					break
			if not is_dup:
				normals.append(n2)
	_wall_normals = normals


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

	# Debug freecam: freeze player physics but keep rendering visuals
	var freecam_frozen: bool = GameManager.debug_freecam_active and peer_id == multiplayer.get_unique_id()

	if multiplayer.is_server() and not freecam_frozen:
		# --- JUMP DEBUG: track position for 30 frames after a jump ---
		if _frame_jump:
			_jump_debug_frames = 30
		if _jump_debug_frames > 0 and peer_id == 1:
			print("[JUMP DBG %02d] pos_y=%.4f vel_y=%.3f grounded=%s floor_y=%.3f linvel_y=%.3f" % [
				30 - _jump_debug_frames, global_position.y, velocity.y, str(_is_grounded), _floor_y, linear_velocity.y])
			_jump_debug_frames -= 1

		# Save previous frame's grounded state for snap logic
		_was_grounded = _is_grounded

		# UNDO JOLT POSITION INTEGRATION (movement component only)
		# Position control leaves velocity non-zero so Jolt's solver computes
		# real collision impulses (pushing toads, etc.). Jolt also integrates
		# position from the post-solver velocity, which includes both:
		#   (a) our movement velocity — unwanted, already applied by position control
		#   (b) solver impulses (depenetration, collision response) — WANTED
		# By subtracting _pre_solver_velocity (our movement velocity BEFORE the
		# solver ran), we undo only (a) and preserve (b). This keeps collision
		# response (player doesn't clip into boxes) while preventing double-movement.
		if _undo_jolt_integration:
			global_position -= _pre_solver_velocity * delta
			_undo_jolt_integration = false

		# Update floor detection (downward raycast, must run in _physics_process)
		_update_ground_state()

		# Tick Second Wind timer
		if _second_wind_timer > 0.0:
			_second_wind_timer -= delta

		# _server_process computes movement velocity from _ground_velocity (when
		# grounded) or from Jolt's solver output (when airborne). Movement code,
		# slope alignment, jump, and gravity all modify `velocity` as before.
		_server_process(delta)

		# GROUNDED POSITION CONTROL
		# When on the floor, we apply movement as a direct position change.
		# Velocity is left non-zero so Jolt's solver sees real movement speed
		# for collision impulses (pushing toads etc.), but Jolt's unwanted
		# position integration is undone at the top of the next _physics_process.
		# This decouples position from Jolt's contact solver (preventing slope
		# sliding) while still allowing proper collision impulse computation.
		#
		# XZ: moved directly by the frame's velocity.
		# Y: estimated using the floor plane equation at the new XZ position.
		#    Same math as slope alignment (vy = -(nx*vx + nz*vz)/ny) but applied
		#    as a position delta from the known floor point. Exact for planar
		#    surfaces, negligible error on smooth terrain.
		#
		# Skipped on lightweight dynamic bodies — Jolt's solver manages stacking.
		# Skipped on first grounded frame — let Jolt handle the landing naturally.
		# Skipped when grapple is active — grapple expects Jolt velocity integration.
		var on_top_of_lightweight := _on_dynamic_body and _dynamic_body_ref != null \
				and is_instance_valid(_dynamic_body_ref) and _dynamic_body_ref.mass < 20.0
		if is_on_floor() and _was_grounded and not on_top_of_lightweight \
				and not grapple_system.is_active():
			# Apply horizontal movement as position change
			var dx := velocity.x * delta
			var dz := velocity.z * delta
			global_position.x += dx
			global_position.z += dz
			# Estimate floor Y at the new XZ using the floor plane equation.
			# From dot(normal, point - floor_point) = 0:
			#   ny*(y - floor_y) = -(nx*dx + nz*dz)
			#   y = floor_y - (nx*dx + nz*dz) / ny
			# This matches slope alignment's velocity.y formula integrated over dt.
			if _floor_y > -INF and _floor_normal.y > 0.001:
				var hemi_offset := CAPSULE_RADIUS * (1.0 - _floor_normal.y) / _floor_normal.y
				var estimated_floor_y := _floor_y - (_floor_normal.x * dx + _floor_normal.z * dz) / _floor_normal.y
				global_position.y = estimated_floor_y + hemi_offset
			# Save movement velocity for next frame. We intentionally leave
			# velocity NON-ZERO so Jolt's solver sees real movement speed for
			# collision impulses (pushing toads, physics objects). Jolt will
			# also integrate position from this velocity — the movement component
			# is undone next frame via _pre_solver_velocity, but the solver's
			# collision response (depenetration) is preserved.
			_ground_velocity = velocity
			_undo_jolt_integration = true
		elif on_top_of_lightweight and is_on_floor():
			# On dynamic body: Jolt handles positioning. Save velocity for
			# ground tracking (used if player walks off the body) but don't
			# zero it — Jolt needs to integrate position from this velocity.
			_ground_velocity = velocity

		# Save pre-solver velocity — Jolt's solver hasn't run yet (it runs at the
		# start of the NEXT physics tick). This captures our clean movement velocity
		# for use as landing momentum if the player transitions to airborne next frame.
		# When grounded with position control, velocity is _ground_velocity here.
		# When airborne, velocity has gravity + movement — the true airborne velocity.
		_pre_solver_velocity = velocity

		# Update sync vars AFTER all server movement (normal, grapple, kamikaze, respawn)
		sync_position = global_position
		sync_rotation_y = rotation.y

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
	# All client visuals run in _process() so they update every render frame and
	# sample the engine's physics-interpolated positions. This prevents visual
	# artifacts (e.g. grapple rope splitting) caused by drawing at the physics
	# tick rate while the player body is interpolated between ticks.
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		return
	_client_process(delta)


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

	# GROUNDED VELOCITY MANAGEMENT
	# When on the floor, position control handles movement directly (see
	# _physics_process). We restore _ground_velocity as the starting velocity
	# for movement code — Jolt's solver output is discarded to prevent the
	# solver from fighting our position control (which caused slope sliding).
	# Velocity is left non-zero after position control so Jolt's solver sees
	# real speed for collision impulses (pushing toads), but position
	# integration is undone at the start of the next frame.
	#
	# Exception: on lightweight dynamic bodies, position control is skipped
	# (Jolt manages stacking). We use Jolt's solver output as starting velocity
	# so movement accumulates properly instead of resetting to stale data.
	var _on_dynamic_lightweight := _on_dynamic_body and _dynamic_body_ref != null \
			and is_instance_valid(_dynamic_body_ref) and _dynamic_body_ref.mass < 20.0
	if is_on_floor() and not _on_dynamic_lightweight:
		if not _was_grounded:
			# Just landed — use PRE-SOLVER velocity (saved last frame before Jolt's
			# solver ran). Jolt's current velocity has contact solver contamination:
			# on a 45° slope, the solver converts landing impact into ~7.5 m/s
			# horizontal, causing the player to slide downhill uncontrollably.
			# The pre-solver velocity has the true airborne momentum (clean).
			_ground_velocity = Vector3(_pre_solver_velocity.x, 0.0, _pre_solver_velocity.z)
		# Restore our tracked velocity — movement code modifies this, not Jolt's output.
		velocity = _ground_velocity
	elif is_on_floor() and _on_dynamic_lightweight:
		# On dynamic body: Jolt's solver output is the starting velocity.
		# Clamp negative Y (grounded — don't sink into the body).
		if velocity.y < 0.0:
			velocity.y = 0.0
	elif _was_grounded:
		# Just went airborne (walked off edge, NOT jump — jump sets _is_grounded=false
		# during _server_process, so _was_grounded is false next frame).
		# Hand off ground velocity to Jolt for airborne physics.
		velocity = _ground_velocity
		_ground_velocity = Vector3.ZERO

	# Gravity (skip when grounded or sliding — slide manages its own Y velocity)
	if not is_on_floor() and not slide_crouch.is_sliding:
		velocity.y -= gravity * delta

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Reset air-jump counter on landing (trinket-granted double jump)
	if is_on_floor():
		_air_jumps_used = 0

	# Slide / crouch / normal movement
	if slide_crouch.is_sliding:
		slide_crouch.process_slide(delta)
	elif slide_crouch.is_crouching:
		slide_crouch.process_crouch(delta)
	else:
		# Post-slide jump window: rapidly decelerate, but jumping restores slide speed
		if not slide_crouch.process_post_slide_window(delta):
			# Jump (slide-jump is handled in process_slide; crouch-jump in process_crouch)
			if _frame_jump and is_on_floor():
				velocity.y = JUMP_VELOCITY
				_is_grounded = false  # Override hysteresis — we're airborne now
				slide_crouch.clear_slide_on_land()
			elif _frame_jump and not is_on_floor():
				# Air-jump (trinket-granted) — only if shoe has an extra-jump trinket
				# 50% stronger than a ground jump to reward the trinket investment
				var extra_jumps: int = inventory.get_shoe_extra_jumps() if inventory else 0
				if _air_jumps_used < extra_jumps:
					velocity.y = JUMP_VELOCITY * 1.5
					_air_jumps_used += 1

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
				_process_normal_movement(delta)

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
					_process_medkit_heal()

	# ADS state: server tracks whether the player is aiming
	var w_data: WeaponData = current_weapon.weapon_data if current_weapon else null
	is_aiming = player_input.action_aim and w_data != null and w_data.ads_fov > 0.0

	# Combat: shooting (damage scaled by heat)
	if player_input.action_shoot and current_weapon != null and current_weapon.can_fire():
		_process_combat()


func _process_medkit_heal() -> void:
	## Server-only: heal 1 HP per frame, costing 5 fuel per frame.
	if heat_system == null or inventory == null:
		return
	var effective_max_hp: float = get_max_health()
	if health >= effective_max_hp:
		return
	if not inventory.spend_fuel_silent(5.0):
		return
	health = minf(health + 1.0, effective_max_hp)


func _process_combat() -> void:
	## Server-only: handle weapon firing, damage, and VFX dispatch.
	# Calculate fuel cost (skip if free firing debug is on)
	var equipped_stack: ItemStack = null
	if inventory and inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size() and inventory.items[inventory.equipped_index] != null:
		equipped_stack = inventory.items[inventory.equipped_index]

	if not GameManager.debug_free_firing and not is_bot:
		var fuel_cost: float = current_weapon.weapon_data.burn_fuel_cost
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

	# Reduce spread (Steady Hand bonus + ADS)
	var saved_spread: float = current_weapon.weapon_data.spread
	if 1 in active_bonuses:  # Steady Hand: -15% spread
		current_weapon.weapon_data.spread *= 0.85
	if is_aiming:
		current_weapon.weapon_data.spread *= current_weapon.weapon_data.ads_spread_mult

	var hit_info := current_weapon.try_fire(self, muzzle_pos, aim_direction)

	# Quick Hands bonus: -20% fire rate cooldown
	if 4 in active_bonuses and current_weapon:
		current_weapon.cooldown_remaining *= 0.80

	# Restore original spread
	current_weapon.weapon_data.spread = saved_spread

	if hit_info.has("melee_hit") or hit_info.has("melee_miss"):
		combat_vfx.show_melee_swing_fx.rpc(muzzle_pos, aim_direction)

		if hit_info.has("melee_hit"):
			var melee_target = hit_info.get("hit_collider")
			print("[Melee] HIT collider=%s is_Player=%s has_take_damage=%s" % [
				str(melee_target), str(melee_target is Player),
				str(melee_target.has_method("take_damage") if melee_target else false)])
			if melee_target is Player and melee_target.has_method("take_damage"):
				if has_node("/root/ToadDimension"):
					get_node("/root/ToadDimension").enter(self, melee_target)
				heat_system.on_damage_dealt(10.0)
		else:
			print("[Melee] MISS")

	elif hit_info.has("pellets"):
		# Multi-pellet weapon (shotgun)
		var pellets: Array = hit_info["pellets"]
		var pellet_count := pellets.size()
		var rarity_damage_per_pellet: float = current_weapon.weapon_data.get_rarity_damage() / pellet_count
		var base_damage_per_pellet: float = current_weapon.weapon_data.damage / pellet_count
		var total_damage_dealt: float = 0.0

		var shot_ends: Array[Vector3] = []
		for pellet in pellets:
			if pellet.has("shot_end"):
				shot_ends.append(pellet["shot_end"])

		if shot_ends.size() > 0:
			combat_vfx.show_shotgun_fx.rpc(muzzle_pos, shot_ends)

		var hit_player_ids: Dictionary = {}  # peer_id -> true, to avoid duplicate whiz on hit targets
		for pellet in pellets:
			var collider = pellet.get("hit_collider")
			if collider != null and collider.has_method("take_damage"):
				var final_damage: float = rarity_damage_per_pellet * heat_system.get_damage_multiplier()
				if 11 in active_bonuses:  # Juggernaut: +10% damage
					final_damage *= 1.10
				collider.take_damage(final_damage, peer_id)
				# Only generate heat from hitting players, not structures
				if collider is Player:
					total_damage_dealt += base_damage_per_pellet
					hit_player_ids[collider.peer_id] = true
					combat_vfx.play_bullet_hit_sound.rpc(pellet["shot_end"])

		if total_damage_dealt > 0.0:
			heat_system.on_damage_dealt(total_damage_dealt)

		# Bullet whiz-by for shotgun: check each pellet ray against nearby players
		_dispatch_bullet_whiz(muzzle_pos, shot_ends, hit_player_ids)

	elif hit_info.has("shot_end"):
		# Single-pellet weapon
		combat_vfx.show_shot_fx.rpc(muzzle_pos, hit_info["shot_end"])

		var hit_player_ids: Dictionary = {}
		var collider = hit_info.get("hit_collider")
		if collider != null and collider.has_method("take_damage"):
			var final_damage: float = current_weapon.weapon_data.get_rarity_damage() * heat_system.get_damage_multiplier()
			if 11 in active_bonuses:  # Juggernaut: +10% damage
				final_damage *= 1.10
			collider.take_damage(final_damage, peer_id)
			# Only generate heat from hitting players, not structures
			if collider is Player:
				heat_system.on_damage_dealt(current_weapon.weapon_data.damage)
				hit_player_ids[collider.peer_id] = true
				combat_vfx.play_bullet_hit_sound.rpc(hit_info["shot_end"])

		# Bullet whiz-by for single shot
		_dispatch_bullet_whiz(muzzle_pos, [hit_info["shot_end"]], hit_player_ids)


func _dispatch_bullet_whiz(muzzle_pos: Vector3, shot_ends: Array, hit_player_ids: Dictionary) -> void:
	## Server-only: check all other players for bullet close-miss and send whiz sounds.
	## Uses point-to-line-segment distance from each player's head to each bullet ray.
	var whiz_dist_sq := CombatVFX.BULLET_WHIZ_DISTANCE * CombatVFX.BULLET_WHIZ_DISTANCE
	var notified: Dictionary = {}  # peer_id -> true, one whiz per player per volley

	for other_peer_id in NetworkManager.players:
		if other_peer_id == peer_id:
			continue  # Don't whiz the shooter
		if hit_player_ids.has(other_peer_id):
			continue  # Already hit — they get the hit sound, not whiz
		if notified.has(other_peer_id):
			continue

		var other_player: Player = NetworkManager.players[other_peer_id]
		if other_player == null or not is_instance_valid(other_player):
			continue
		if other_player.get("is_dead") == true:
			continue

		var other_pos: Vector3 = other_player.global_position + Vector3(0, 1.0, 0)  # Approximate head
		var best_dist_sq := INF
		var best_closest_point := Vector3.ZERO

		for shot_end in shot_ends:
			var closest := _closest_point_on_segment(muzzle_pos, shot_end, other_pos)
			var d_sq := closest.distance_squared_to(other_pos)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_closest_point = closest

		if best_dist_sq <= whiz_dist_sq:
			notified[other_peer_id] = true
			# Bots don't have clients to receive RPCs
			if other_peer_id >= 9000:
				continue
			other_player.combat_vfx.play_bullet_whiz_sound.rpc_id(other_peer_id, best_closest_point)


static func _closest_point_on_segment(a: Vector3, b: Vector3, p: Vector3) -> Vector3:
	## Returns the closest point on line segment AB to point P.
	var ab := b - a
	var ab_len_sq := ab.length_squared()
	if ab_len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	return a + ab * t


func _process_normal_movement(delta: float) -> void:
	## Acceleration-based horizontal movement. Uses different rates on ground vs air.
	var shoe_bonus: float = inventory.get_shoe_speed_bonus() if inventory else 0.0
	var bonus_speed: float = 0.0
	if 5 in active_bonuses:   # Adrenaline Rush: +10% speed
		bonus_speed += 0.10
	if _second_wind_timer > 0.0:  # Second Wind: +50% speed
		bonus_speed += 0.50
	var current_speed := SPEED * (heat_system.get_speed_multiplier() + shoe_bonus + bonus_speed)
	var input_dir: Vector2 = player_input.input_direction
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var horizontal := Vector2(velocity.x, velocity.z)
	var on_floor := is_on_floor()

	# --- Wall-slide projection ---
	# _wall_normals contains per-face normals from Jolt's contact solver.
	# When touching multiple walls (e.g. a corner), we must project the
	# target velocity against ALL walls the player pushes into — not just
	# one. Otherwise sliding along wall A produces velocity that drives
	# into wall B, and Jolt's solver zeroes it out next frame (stutter).
	#
	# After projecting the target, velocity is decomposed into wall-parallel
	# and wall-perpendicular axes. move_toward() only steers the parallel
	# component; perpendicular (Jolt's depenetration push) is preserved.

	if direction:
		var target := Vector2(direction.x, direction.z) * current_speed

		var best_normal := Vector2.ZERO
		var best_dot := 0.0
		for wn in _wall_normals:
			var d := target.dot(wn)
			if d < best_dot:
				best_dot = d
				best_normal = wn

		if best_normal != Vector2.ZERO:
			target -= best_normal * target.dot(best_normal)

			var wall_tang := Vector2(-best_normal.y, best_normal.x)
			var perp_speed := horizontal.dot(best_normal)
			var para_speed := horizontal.dot(wall_tang)
			var target_para := target.dot(wall_tang)

			var accel := ACCELERATION if on_floor else AIR_ACCELERATION
			para_speed = move_toward(para_speed, target_para, accel * delta)

			var perp_out := maxf(perp_speed, 0.0)

			horizontal = wall_tang * para_speed + best_normal * perp_out

			for wn in _wall_normals:
				var d := horizontal.dot(wn)
				if d < 0.0:
					horizontal -= wn * d
		else:
			# No wall contact or not pushing into any wall — normal acceleration
			if on_floor:
				horizontal = horizontal.move_toward(target, ACCELERATION * delta)
			else:
				var current_mag := horizontal.length()
				var input_dot := horizontal.normalized().dot(target.normalized()) if current_mag > 0.1 else 1.0
				horizontal = horizontal.move_toward(target, AIR_ACCELERATION * delta)
				if horizontal.length() < current_mag and input_dot > 0.0:
					horizontal = horizontal.normalized() * current_mag
	else:
		var decel := DECELERATION if on_floor else AIR_DECELERATION
		horizontal = horizontal.move_toward(Vector2.ZERO, decel * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.y

	# Velocity dead zone: when grounded with no input and near-zero speed,
	# hard-zero velocity immediately. Prevents any tiny residual from floating
	# point, solver contamination, or slope alignment rounding from creating
	# persistent micro-drift on slopes.
	if on_floor and not direction and horizontal.length_squared() < 0.01:
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y = 0.0
		return

	var on_slope := _floor_normal.dot(Vector3.UP) <= 0.999  # >~2.5 degrees from flat
	if on_floor and _floor_normal.y > 0.001 and on_slope and not _frame_jump:
		# Slope alignment: compute the Y velocity needed to move along the
		# floor surface instead of horizontally into it. X and Z stay exactly
		# as the movement system computed — no direction change, no sideways
		# deflection. Only the vertical component is added so the player
		# glides up/down hills at constant horizontal speed, matching
		# CharacterBody3D move_and_slide() with floor_constant_speed.
		#
		# From the plane equation dot(velocity, normal) = 0:
		#   nx*vx + ny*vy + nz*vz = 0  →  vy = -(nx*vx + nz*vz) / ny
		velocity.y = -(_floor_normal.x * velocity.x + _floor_normal.z * velocity.z) / _floor_normal.y


func is_on_floor() -> bool:
	## Floor detection — replaces CharacterBody3D.is_on_floor().
	## Updated each physics tick by _update_ground_state().
	return _is_grounded


func get_floor_normal() -> Vector3:
	## Floor normal — replaces CharacterBody3D.get_floor_normal().
	return _floor_normal


func _update_ground_state() -> void:
	## Downward raycast for floor detection. Must be called from _physics_process()
	## (threaded physics requires all queries in the physics tick).
	##
	## Casts from capsule center (Y=0.9) downward to FLOOR_SNAP_MARGIN below feet.
	## The capsule bottom is at Y=0.0 (center 0.9, radius 0.4, half-height 0.9-0.4=0.5,
	## so bottom = 0.9-0.5-0.4=0.0).
	##
	## Two thresholds:
	##   FLOOR_CONTACT_TOLERANCE (0.05m) — tight check for _is_grounded (drives
	##     movement: acceleration, gravity, jump). Matches CharacterBody3D which
	##     only reported is_on_floor() on actual contact.
	##   FLOOR_SNAP_MARGIN (0.3m) — extended reach for _floor_y (snap-to-floor
	##     mechanism that keeps the player grounded over bumps and slopes).
	var space := get_world_3d().direct_space_state
	if space == null:
		_is_grounded = false
		_floor_y = -INF
		return

	var origin := global_position + Vector3(0, 0.9, 0)  # Capsule center
	var end := origin + Vector3(0, -(0.9 + FLOOR_SNAP_MARGIN), 0)  # Below feet + snap margin
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.collision_mask = 1 | 2 | 16 | 64 | 2048  # World + items + toad walls + toad bodies + smooth walls (layer 12)
	query.exclude = [get_rid()]

	var result := space.intersect_ray(query)
	if result.is_empty():
		_is_grounded = false
		_floor_normal = Vector3.UP
		_floor_y = -INF
		return

	var normal: Vector3 = result["normal"]
	if normal.angle_to(Vector3.UP) > FLOOR_MAX_ANGLE:
		# Too steep — treat as a wall, not a floor
		_is_grounded = false
		_floor_normal = Vector3.UP
		_floor_y = -INF
		return

	# Floor surface found — always record for snap logic
	_floor_normal = normal
	_floor_y = result["position"].y

	# Hemisphere offset: on slopes, the capsule's bottom hemisphere contacts the
	# surface HIGHER than where the center-down raycast hits. The correct resting
	# height is floor_y + R*(1 - Ny)/Ny. We subtract this from feet_gap so the
	# grounding check measures distance from the CORRECT resting position,
	# working consistently on flat ground and steep walkable slopes alike.
	var hemi_offset := CAPSULE_RADIUS * (1.0 - normal.y) / normal.y
	var feet_gap := global_position.y - (_floor_y + hemi_offset)
	if _is_grounded:
		_is_grounded = feet_gap <= FLOOR_SNAP_MARGIN
	else:
		_is_grounded = feet_gap <= FLOOR_CONTACT_TOLERANCE

	# When ON TOP of a lightweight dynamic body (contact normal.y > 0.7),
	# force grounded. The terrain raycast hits through/under the body, so
	# terrain-based grounding is wrong — use contact-based grounding instead.
	# No gravity → no force pushing into sphere → no sliding.
	# Floor snap (below) is also skipped when on top.
	#
	# When touching from the SIDE (not on top), keep terrain-based grounding
	# unchanged — the player may be standing on the ground next to the body
	# and needs to jump/walk normally.
	#
	# Skip when rising (velocity.y > 0) — the player just jumped off the body.
	# Without this check, the contact persists for 1-2 frames after liftoff,
	# forcing _is_grounded = true, which makes _server_process() zero velocity.y
	# and kills the jump.
	if _on_dynamic_body and _dynamic_body_ref != null \
			and is_instance_valid(_dynamic_body_ref) \
			and _dynamic_body_ref.mass < 20.0 \
			and velocity.y <= 0.0:
		_is_grounded = true


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
	# Toad dimension players are on layer 9 (256) instead of layer 8 (128)
	var player_bit: int = 256 if in_toad_dimension else 128
	var query := PhysicsRayQueryParameters3D.create(cam_origin, far_point)
	query.exclude = [get_rid()]
	query.collision_mask = 1 | 2 | 4 | 8 | 16 | player_bit  # All gameplay layers (excludes debris/toad bodies)
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position
	return far_point


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
	_ground_velocity = Vector3.ZERO
	_pre_solver_velocity = Vector3.ZERO
	_undo_jolt_integration = false
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
	_is_grounded = false
	_was_grounded = false
	_floor_normal = Vector3.UP
	_floor_y = -INF


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

	# Reset air-jump counter, wall-slide state, and ground velocity
	_air_jumps_used = 0
	_wall_normals = []
	_ground_velocity = Vector3.ZERO
	_pre_solver_velocity = Vector3.ZERO
	_undo_jolt_integration = false

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
	_current_gun_model.scale = Vector3(0.15, 0.15, 0.15)
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


@rpc("any_peer", "call_local", "reliable")
func rpc_unslot_ammo(_weapon_index: int) -> void:
	## Ammo merging is permanent — this RPC is now a no-op.
	pass


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
