extends CharacterBody3D

## Server-authoritative player controller.
## The server reads input from PlayerInput (synced via InputSync),
## computes movement and combat, and the result is synced back via ServerSync.

const WeaponProjectileScript = preload("res://weapons/weapon_projectile.gd")

const SPEED := 7.0
const JUMP_VELOCITY := 7.5
const MAX_HEALTH := 100.0
const RESPAWN_DELAY := 3.0

## Movement acceleration/deceleration
const ACCELERATION := 45.0         # ~0.16s to full speed — snappy
const DECELERATION := 30.0         # ~0.23s to stop — slight momentum
const AIR_ACCELERATION := 15.0
const AIR_DECELERATION := 5.0

## Slide constants — physics-based
const SLIDE_INITIAL_SPEED := 12.0    ## Only used as fallback if somehow speed is 0
const SLIDE_FRICTION_COEFF := 0.35   ## Ground friction (higher = grippier, Fortnite-like)
const SLIDE_MIN_SPEED := 0.5        ## Low threshold — let slides die naturally via physics
const SLIDE_MIN_ENTRY_SPEED := 3.5
const SLIDE_COOLDOWN := 0.4
const SLIDE_CAPSULE_HEIGHT := 1.0
const SLIDE_CAMERA_OFFSET := -0.5
const SLIDE_AIRBORNE_GRACE := 0.2
const SLIDE_SNAP_DOWN := 4.0
const SLIDE_TO_CROUCH_DELAY := 0.3   ## Seconds coasting at low speed before crouch transition
const SLIDE_MAX_SPEED := 14.0        ## Hard cap — prevents runaway downhill speed
const SLIDE_LATERAL_FRICTION := 12.0  ## How quickly lateral (sideways) drift is killed

## Rarity damage bonus: +15% per rarity tier (Common=1.0, Uncommon=1.15, Rare=1.30, Epic=1.45, Legendary=1.60)
const RARITY_DAMAGE_BONUS := 0.15

## Crouch constants
const CROUCH_CAPSULE_HEIGHT := 1.0
const CROUCH_CAMERA_OFFSET := -0.5
const CROUCH_SPEED_MULT := 0.5
const CROUCH_MESH_SCALE_Y := 0.55  # Visual squish

var gravity: float = 17.5  ## Heavier gravity for snappy movement (default Godot is 9.8)

## The peer ID that owns this player. Set by NetworkManager on spawn.
var peer_id: int = 1

## Combat state (synced via ServerSync)
var health: float = MAX_HEALTH
var is_alive: bool = true

## Current weapon (server-managed)
var current_weapon: WeaponBase = null
var _respawn_timer: float = 0.0

## Synced weapon visual paths — clients use these to load 3D model + sound
var equipped_gun_model_path: String = ""
var equipped_fire_sound_path: String = ""
var _current_gun_model: Node3D = null
var _last_synced_gun_model_path: String = ""
var _last_synced_fire_sound_path: String = ""

## ADS (Aim Down Sights) state — synced via ServerSync
var is_aiming: bool = false
const DEFAULT_FOV := 70.0
const ADS_LERP_SPEED := 12.0         ## How fast FOV/spring transitions
const ADS_SPRING_LENGTH := 1.0       ## Camera pulls closer when aiming
const DEFAULT_SPRING_LENGTH := 2.2
var _scope_overlay: ColorRect = null  ## Scope vignette for scoped weapons

## Slide/crouch state (server-managed, synced to clients)
var is_sliding: bool = false
var is_crouching: bool = false
var _slide_velocity: Vector3 = Vector3.ZERO
var _slide_cooldown_timer: float = 0.0
var _slide_airborne_timer: float = 0.0
var _slide_low_speed_timer: float = 0.0
var _slide_smoothed_normal: Vector3 = Vector3.UP  ## Smoothed floor normal to avoid jitter
var _slide_forward_dir: Vector3 = Vector3.ZERO    ## Original slide direction for lateral friction
var _wants_slide_on_land: bool = false             ## Queue slide when landing from a jump
var _slide_on_land_grace: float = 0.0              ## Grace window after landing to trigger slide
var _was_on_floor: bool = true                     ## Track floor state for landing detection
var _pre_land_velocity_y: float = 0.0              ## Vertical speed right before landing
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
	_original_mesh_y = body_mesh.position.y
	_original_mesh_scale_y = body_mesh.scale.y

	# Add VoxelViewer so the voxel terrain generates around each player.
	# Without this, VoxelTerrain won't load any chunks.
	if ClassDB.class_exists(&"VoxelViewer"):
		var viewer: Node3D = ClassDB.instantiate(&"VoxelViewer")
		viewer.name = "VoxelViewer"
		add_child(viewer)

	if peer_id == multiplayer.get_unique_id():
		camera.current = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Setup HUD for local player
		if player_hud and player_hud.has_method("setup"):
			player_hud.setup(self)
		# Setup inventory UI for local player
		if inventory_ui and inventory_ui.has_method("setup"):
			inventory_ui.setup(self)
			inventory_ui.visible = false
	else:
		camera.current = false
		camera_pivot.visible = false
		# Hide HUD for non-local players
		if player_hud:
			player_hud.visible = false
		if inventory_ui:
			inventory_ui.visible = false


func _physics_process(delta: float) -> void:
	# Toggle inventory UI for the local player (must happen regardless of server/client)
	if peer_id == multiplayer.get_unique_id() and inventory_ui:
		inventory_ui.visible = player_input.inventory_open

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

	# Fall-through-ground safety: respawn if player falls below the map
	if global_position.y < -50.0:
		_do_respawn()
		return

	# Slide cooldown
	if _slide_cooldown_timer > 0.0:
		_slide_cooldown_timer -= delta

	# Gravity (skip during slide — slide manages its own Y velocity)
	if not is_on_floor() and not is_sliding:
		velocity.y -= gravity * delta

	# Rotation from look input
	rotation.y = player_input.look_yaw
	camera_pivot.rotation.x = player_input.look_pitch

	# Slide / crouch / normal movement
	if is_sliding:
		_process_slide(delta)
	elif is_crouching:
		_process_crouch(delta)
	else:
		# Jump (no jumping while sliding/crouching)
		if player_input.action_jump and is_on_floor():
			velocity.y = JUMP_VELOCITY
			_wants_slide_on_land = false  # Clear on new jump

		# While airborne, queue slide for when we land
		if not is_on_floor() and player_input.action_slide:
			_wants_slide_on_land = true

		# Check if we should start a slide (must be moving fast enough)
		if player_input.action_slide and _can_start_slide():
			_start_slide()
			_process_slide(delta)
		elif player_input.action_slide and is_on_floor():
			# Not fast enough to slide — enter crouch
			_start_crouch()
			_process_crouch(delta)
		else:
			_process_normal_movement(delta)

	# Track floor state before move_and_slide for landing detection
	var was_airborne := not _was_on_floor
	if was_airborne:
		_pre_land_velocity_y = velocity.y  # Capture vertical speed before landing
	move_and_slide()
	_was_on_floor = is_on_floor()

	# --- Push nearby bubbles ---
	# Bubbles are on layer 3 (not layer 1), so move_and_slide() doesn't see them.
	# We manually detect nearby bubbles and apply impulses. Since bubbles have
	# mass 0.1 and we push with player velocity * 80kg equivalent, they fly easily.
	_push_nearby_bubbles()

	# --- Slide-on-land system ---
	# When the player presses crouch while airborne, give a generous grace window
	# after landing to trigger the slide. This accounts for the fact that landing
	# on slopes can eat horizontal speed on the first frame.
	if was_airborne and is_on_floor() and _wants_slide_on_land:
		# Convert some downward velocity into horizontal speed on landing.
		# Falling faster = more slide momentum. Going upward = no bonus.
		var land_speed_bonus := maxf(-_pre_land_velocity_y, 0.0) * 0.5
		if land_speed_bonus > 0.1:
			var horiz_dir := Vector3(velocity.x, 0.0, velocity.z)
			if horiz_dir.length() < 0.1:
				horiz_dir = -transform.basis.z  # Fallback: forward
			horiz_dir = horiz_dir.normalized()
			velocity.x += horiz_dir.x * land_speed_bonus
			velocity.z += horiz_dir.z * land_speed_bonus
		# Start grace window
		_slide_on_land_grace = 0.15  # 150ms to trigger slide after landing

	# Process grace window: try to start slide each frame for a few frames after landing
	if _slide_on_land_grace > 0.0 and not is_sliding and not is_crouching:
		_slide_on_land_grace -= delta
		if is_on_floor() and _can_start_slide():
			_wants_slide_on_land = false
			_slide_on_land_grace = 0.0
			_start_slide()
		elif _slide_on_land_grace <= 0.0:
			# Grace expired — fall back to crouch if still holding
			_wants_slide_on_land = false
			if player_input.action_slide:
				_start_crouch()

	# Weapon slot switching (1-6)
	if player_input.action_slot > 0:
		var slot_idx: int = player_input.action_slot - 1  # Convert 1-6 to 0-5
		if inventory and slot_idx < inventory.items.size():
			inventory.equip_slot(slot_idx)
			var stack: ItemStack = inventory.items[slot_idx]
			if stack.item_data is WeaponData:
				equip_weapon(stack.item_data as WeaponData)

	# --- Extend equipped item lifespan (F key) ---
	if player_input.action_extend and inventory:
		_try_extend_equipped_item()

	# --- Scrap nearby ground item or equipped item (X key) ---
	if player_input.action_scrap and inventory:
		_try_scrap_item()

	# ADS state: server tracks whether the player is aiming
	var w_data: WeaponData = current_weapon.weapon_data if current_weapon else null
	is_aiming = player_input.action_aim and w_data != null and w_data.ads_fov > 0.0

	# Combat: shooting (damage scaled by heat)
	if player_input.action_shoot and current_weapon != null and current_weapon.can_fire():
		# Calculate fuel cost: weapon base cost + ammo cost (if ammo slotted)
		var fuel_cost: float = current_weapon.weapon_data.burn_fuel_cost
		var equipped_stack: ItemStack = null
		if inventory and inventory.equipped_index >= 0 and inventory.equipped_index < inventory.items.size():
			equipped_stack = inventory.items[inventory.equipped_index]
			if equipped_stack and equipped_stack.slotted_ammo:
				if equipped_stack.slotted_ammo is AmmoData:
					fuel_cost += equipped_stack.slotted_ammo.burn_cost_per_shot
				elif equipped_stack.slotted_ammo is WeaponData:
					fuel_cost += equipped_stack.slotted_ammo.ammo_burn_cost_per_shot

		# Check fuel before firing
		if inventory.has_fuel(fuel_cost):
			# Spend fuel only when the weapon is actually ready to fire
			inventory.spend_fuel(fuel_cost)

			# Set ammo context on weapon before firing
			if equipped_stack and equipped_stack.slotted_ammo:
				current_weapon.ammo_data = equipped_stack.slotted_ammo
			else:
				current_weapon.ammo_data = null

			# Third-person aiming: cast a ray from the camera through the crosshair
			# (screen center) to find the world-space target, then fire from the
			# character's muzzle position toward that target.
			var cam_origin := camera.global_position
			var cam_forward := -camera.global_transform.basis.z
			var aim_target := _get_camera_aim_target(cam_origin, cam_forward)

			# Fire from the gun barrel, not camera pivot
			var muzzle_pos := _get_barrel_position()
			var aim_direction := (aim_target - muzzle_pos).normalized()

			# Reduce spread while ADS
			var saved_spread: float = current_weapon.weapon_data.spread
			if is_aiming:
				current_weapon.weapon_data.spread *= current_weapon.weapon_data.ads_spread_mult

			var hit_info := current_weapon.try_fire(self, muzzle_pos, aim_direction)

			# Restore original spread
			current_weapon.weapon_data.spread = saved_spread
			if hit_info.has("pellets"):
				# Multi-pellet weapon (shotgun) — process each pellet independently.
				# Damage is split evenly across all pellets.
				var pellets: Array = hit_info["pellets"]
				var pellet_count := pellets.size()
				var base_damage_per_pellet: float = current_weapon.weapon_data.damage / pellet_count
				var total_damage_dealt: float = 0.0

				# Collect all shot endpoints for a single batched RPC
				var shot_ends: Array[Vector3] = []
				for pellet in pellets:
					if pellet.has("shot_end"):
						shot_ends.append(pellet["shot_end"])

				# Show all tracers on all clients in one RPC
				if shot_ends.size() > 0:
					_show_shotgun_fx.rpc(muzzle_pos, shot_ends)

				# Rarity multiplier: higher rarity weapons deal more damage
				var rarity_mult: float = 1.0 + current_weapon.weapon_data.rarity * RARITY_DAMAGE_BONUS

				# Process damage per pellet — each pellet can hit a different target
				for pellet in pellets:
					var collider = pellet.get("hit_collider")
					if collider != null and collider.has_method("take_damage"):
						var final_damage: float = base_damage_per_pellet * heat_system.get_damage_multiplier() * rarity_mult
						collider.take_damage(final_damage, peer_id)
						total_damage_dealt += base_damage_per_pellet

				# Add heat based on total damage actually dealt
				if total_damage_dealt > 0.0:
					heat_system.on_damage_dealt(total_damage_dealt)

			elif hit_info.has("shot_end"):
				# Single-pellet weapon — original path
				_show_shot_fx.rpc(muzzle_pos, hit_info["shot_end"])

				var collider = hit_info.get("hit_collider")
				if collider != null and collider.has_method("take_damage"):
					var base_damage: float = current_weapon.weapon_data.damage
					var rarity_mult: float = 1.0 + current_weapon.weapon_data.rarity * RARITY_DAMAGE_BONUS
					var final_damage: float = base_damage * heat_system.get_damage_multiplier() * rarity_mult
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
	if horiz_speed < SLIDE_MIN_ENTRY_SPEED:
		return false
	# Block slide initiation only on steep uphill (>~20°) — anything gentler is fine
	var floor_normal := get_floor_normal()
	var slope_steepness := sqrt(1.0 - floor_normal.y * floor_normal.y)
	if slope_steepness > 0.35:  # ~20°
		var downhill_3d := (Vector3.DOWN - floor_normal * Vector3.DOWN.dot(floor_normal))
		var downhill_horiz := Vector3(downhill_3d.x, 0.0, downhill_3d.z)
		if downhill_horiz.length() > 0.001:
			var move_dir := Vector3(velocity.x, 0.0, velocity.z).normalized()
			var alignment := move_dir.dot(downhill_horiz.normalized())
			if alignment < -0.3:
				return false
	return true


func _start_slide() -> void:
	is_sliding = true
	is_crouching = false
	_slide_airborne_timer = 0.0
	_slide_low_speed_timer = 0.0
	_slide_smoothed_normal = get_floor_normal() if is_on_floor() else Vector3.UP
	# Lock slide direction to current movement direction — NO speed boost.
	# Enter at your current speed so it doesn't feel like you get launched.
	var horiz := Vector2(velocity.x, velocity.z)
	var horiz_speed := horiz.length()
	if horiz_speed > 0.01:
		var dir_2d := horiz.normalized()
		_slide_velocity = Vector3(dir_2d.x * horiz_speed, 0.0, dir_2d.y * horiz_speed)
		_slide_forward_dir = _slide_velocity.normalized()
	else:
		# Fallback: slide forward at entry threshold speed
		var forward := -transform.basis.z
		_slide_velocity = forward * SLIDE_MIN_ENTRY_SPEED
		_slide_forward_dir = Vector3(forward.x, 0.0, forward.z).normalized()

	_apply_lowered_pose(SLIDE_CAPSULE_HEIGHT, SLIDE_CAMERA_OFFSET)


func _process_slide(delta: float) -> void:
	## Server-only: physics-based slide.
	## Uses real inclined-plane physics: a = g * (sin(angle)*alignment - friction*cos(angle))
	## A single formula handles flat, downhill, and uphill — no arbitrary penalty constants.
	var on_floor := is_on_floor()

	# --- Airborne grace ---
	if on_floor:
		_slide_airborne_timer = 0.0
	else:
		_slide_airborne_timer += delta

	# --- Smooth the floor normal to prevent jitter on procedural terrain ---
	var raw_normal := get_floor_normal() if on_floor else _slide_smoothed_normal
	var smooth_rate := 6.0 * delta
	_slide_smoothed_normal = _slide_smoothed_normal.lerp(raw_normal, clampf(smooth_rate, 0.0, 1.0)).normalized()

	var slope_steepness := sqrt(1.0 - _slide_smoothed_normal.y * _slide_smoothed_normal.y)

	# Downhill direction from smoothed normal (horizontal only)
	var downhill_3d := (Vector3.DOWN - _slide_smoothed_normal * Vector3.DOWN.dot(_slide_smoothed_normal))
	var downhill_horiz := Vector3(downhill_3d.x, 0.0, downhill_3d.z)
	if downhill_horiz.length() > 0.001:
		downhill_horiz = downhill_horiz.normalized()
	else:
		downhill_horiz = Vector3.ZERO

	var slide_dir := _slide_velocity.normalized() if _slide_velocity.length() > 0.01 else Vector3.ZERO
	var alignment := slide_dir.dot(downhill_horiz) if downhill_horiz.length() > 0.001 else 0.0

	# --- On downhill slopes, gently redirect slide toward downhill ---
	if on_floor and slope_steepness > 0.1 and alignment > 0.0:
		var redirect_strength := slope_steepness * 2.5 * delta
		redirect_strength = minf(redirect_strength, 0.5)
		var redirect_spd := _slide_velocity.length()
		var redirected_dir := slide_dir.lerp(downhill_horiz, redirect_strength).normalized()
		_slide_velocity = redirected_dir * redirect_spd
		# Recalculate after redirect
		slide_dir = _slide_velocity.normalized() if _slide_velocity.length() > 0.01 else Vector3.ZERO
		alignment = slide_dir.dot(downhill_horiz) if downhill_horiz.length() > 0.001 else 0.0

	# --- Unified physics-based slope force ---
	# a = g * (sin(angle) * alignment - friction * cos(angle))
	# alignment > 0 = downhill (gravity helps), < 0 = uphill (gravity resists)
	# Friction always opposes motion.
	var slope_force: float = 0.0
	if on_floor and slope_steepness > 0.01:
		var sin_angle := slope_steepness
		var cos_angle := _slide_smoothed_normal.y
		slope_force = gravity * (sin_angle * alignment - SLIDE_FRICTION_COEFF * cos_angle)
	else:
		# Flat or airborne: friction only
		slope_force = -gravity * SLIDE_FRICTION_COEFF

	# Apply force as speed change
	var spd := _slide_velocity.length()
	spd = maxf(spd + slope_force * delta, 0.0)
	# Hard speed cap — prevents runaway downhill acceleration
	spd = minf(spd, SLIDE_MAX_SPEED)
	if spd > 0.01 and slide_dir.length() > 0.001:
		_slide_velocity = slide_dir * spd
	else:
		_slide_velocity = Vector3.ZERO

	# --- Kill lateral drift ---
	# Decompose velocity into forward (original entry direction) and sideways.
	# Apply heavy friction to the sideways component so it's hard to veer off course.
	if _slide_velocity.length() > 0.01 and _slide_forward_dir.length() > 0.001:
		var forward_speed := _slide_velocity.dot(_slide_forward_dir)
		var forward_component := _slide_forward_dir * forward_speed
		var lateral_component := _slide_velocity - forward_component
		lateral_component = lateral_component.move_toward(Vector3.ZERO, SLIDE_LATERAL_FRICTION * delta)
		_slide_velocity = forward_component + lateral_component
		# Slowly update the forward direction toward current movement so
		# downhill gravity redirect still works, but much more gradually
		_slide_forward_dir = _slide_forward_dir.lerp(_slide_velocity.normalized(), 1.5 * delta).normalized()

	# --- Apply velocity ---
	velocity.x = _slide_velocity.x
	velocity.z = _slide_velocity.z

	if on_floor:
		# Snap down onto slope to prevent bouncing
		var speed_factor := _slide_velocity.length() / SLIDE_INITIAL_SPEED
		var snap_force := SLIDE_SNAP_DOWN + gravity * slope_steepness * speed_factor
		velocity.y = -snap_force * maxf(slope_steepness, 0.08)
	else:
		velocity.y -= gravity * delta

	# --- End conditions: gradual transition, not abrupt ---
	# Track time coasting at low speed
	if _slide_velocity.length() < SLIDE_MIN_SPEED:
		_slide_low_speed_timer += delta
	else:
		_slide_low_speed_timer = 0.0

	var should_end := false
	if not player_input.action_slide:
		should_end = true
	if not on_floor and _slide_airborne_timer > SLIDE_AIRBORNE_GRACE:
		should_end = true
	# Only end after coasting at low speed for a bit — smooth transition
	if _slide_low_speed_timer > SLIDE_TO_CROUCH_DELAY:
		should_end = true

	if should_end:
		_end_slide()


func _end_slide() -> void:
	is_sliding = false
	_slide_cooldown_timer = SLIDE_COOLDOWN
	_slide_low_speed_timer = 0.0
	_slide_velocity = Vector3.ZERO
	_slide_forward_dir = Vector3.ZERO

	# Transition to crouch if still holding Ctrl, or if there's no headroom
	if player_input.action_slide or not _has_headroom():
		# Always use WASD input for crouch velocity so the player
		# immediately starts crouch walking and never feels frozen
		var input_dir: Vector2 = player_input.input_direction
		if input_dir.length() > 0.1:
			var shoe_bonus: float = inventory.get_shoe_speed_bonus() if inventory else 0.0
			var crouch_speed := SPEED * (heat_system.get_speed_multiplier() + shoe_bonus) * CROUCH_SPEED_MULT
			var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
			velocity.x = direction.x * crouch_speed
			velocity.z = direction.z * crouch_speed
		else:
			velocity.x = 0.0
			velocity.z = 0.0
		_start_crouch()
	else:
		velocity.x = 0.0
		velocity.z = 0.0
		_apply_standing_pose()


## ---- Crouch mechanics (server-only) ----

func _start_crouch() -> void:
	is_crouching = true
	is_sliding = false
	_apply_lowered_pose(CROUCH_CAPSULE_HEIGHT, CROUCH_CAMERA_OFFSET)


func _process_crouch(delta: float) -> void:
	## Server-only: crouched movement with reduced speed.
	# Try to stand up if no longer holding crouch AND there's headroom
	if not player_input.action_slide and _has_headroom():
		_end_crouch()
		return

	# Allow jumping out of crouch (uncrouch + jump)
	if player_input.action_jump and is_on_floor() and _has_headroom():
		_end_crouch()
		velocity.y = JUMP_VELOCITY
		return

	# Crouched movement — slower, same acceleration feel
	var shoe_bonus: float = inventory.get_shoe_speed_bonus() if inventory else 0.0
	var current_speed := SPEED * (heat_system.get_speed_multiplier() + shoe_bonus) * CROUCH_SPEED_MULT
	var input_dir: Vector2 = player_input.input_direction
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var horizontal := Vector2(velocity.x, velocity.z)
	if direction:
		var target := Vector2(direction.x, direction.z) * current_speed
		horizontal = horizontal.move_toward(target, ACCELERATION * delta)
	else:
		horizontal = horizontal.move_toward(Vector2.ZERO, DECELERATION * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.y


func _end_crouch() -> void:
	is_crouching = false
	_apply_standing_pose()


## ---- Shared pose helpers ----

func _apply_lowered_pose(capsule_height: float, camera_offset: float) -> void:
	## Shrink capsule, mesh, and lower camera for slide/crouch.
	var col_shape := $CollisionShape3D
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = capsule_height
		col_shape.position.y = capsule_height * 0.5

	# Shrink and lower the body mesh to match the smaller capsule
	var height_ratio := capsule_height / _original_capsule_height
	body_mesh.scale.y = _original_mesh_scale_y * height_ratio
	body_mesh.position.y = _original_mesh_y * height_ratio

	# Camera offset (server sets it; client will lerp)
	camera_pivot.position.y = _original_camera_y + camera_offset


func _apply_standing_pose() -> void:
	## Restore capsule, mesh, and camera to full standing height.
	var col_shape := $CollisionShape3D
	if col_shape.shape is CapsuleShape3D:
		col_shape.shape.height = _original_capsule_height
		col_shape.position.y = _original_capsule_height * 0.5

	body_mesh.scale.y = _original_mesh_scale_y
	body_mesh.position.y = _original_mesh_y
	camera_pivot.position.y = _original_camera_y


func _has_headroom() -> bool:
	## Check if there's enough space above to stand up from crouch/slide.
	var space_state := get_world_3d().direct_space_state
	var head_pos := global_position + Vector3(0, CROUCH_CAPSULE_HEIGHT, 0)
	var stand_pos := global_position + Vector3(0, _original_capsule_height + 0.1, 0)
	var query := PhysicsRayQueryParameters3D.create(head_pos, stand_pos)
	query.exclude = [get_rid()]
	var result := space_state.intersect_ray(query)
	return result.is_empty()


func _get_barrel_position() -> Vector3:
	## Returns the world-space position of the gun barrel tip.
	## Uses the barrel_offset from WeaponData, transformed by the WeaponMount.
	if current_weapon and current_weapon.weapon_data:
		var offset: Vector3 = current_weapon.weapon_data.barrel_offset
		return weapon_mount.global_transform * offset
	# Fallback: use camera pivot position (old behavior)
	return camera_pivot.global_position


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


func _push_nearby_bubbles() -> void:
	## Server-only: push nearby bubbles away from the player using impulses.
	## Jolt already applies collision response forces (player is kinematic,
	## bubble is dynamic with mass 0.1), so this is a supplemental push
	## that adds slight upward bias and works at the outer detection edge
	## before physics contact actually occurs.
	var projectiles := get_tree().current_scene.get_node_or_null("Projectiles")
	if projectiles == null:
		return

	var player_pos := global_position + Vector3(0, 0.9, 0)  # Capsule center
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
		# Slightly larger than physics contact distance so we push before overlap
		var push_threshold := 1.4  # 0.4 (player) + 0.6 (bubble) + 0.4 outer margin

		if dist < push_threshold and dist > 0.01:
			var overlap := 1.0 - (dist / push_threshold)
			var push_dir := to_bubble.normalized()
			# Scale with player speed — running shoves harder than standing still
			var speed_factor := maxf(player_speed * 0.3, 0.5)
			# Light impulse — Jolt collision response handles the heavy push.
			# This mainly adds the upward arc and pre-contact nudge.
			var impulse := push_dir * overlap * speed_factor * 0.4
			# Upward bias so bubbles arc over the player's head
			impulse.y += 0.2 * overlap
			body.apply_push_impulse(impulse)


func _client_process(delta: float) -> void:
	var is_local := (peer_id == multiplayer.get_unique_id())
	if is_local:
		camera_pivot.rotation.x = player_input.look_pitch
		# Smooth camera height for slide/crouch
		var cam_lowered := is_sliding or is_crouching
		var target_cam_y := _original_camera_y + SLIDE_CAMERA_OFFSET if cam_lowered else _original_camera_y
		camera_pivot.position.y = lerpf(camera_pivot.position.y, target_cam_y, 10.0 * delta)

		# --- ADS: FOV zoom, spring arm pull-in, scope overlay ---
		var w_data: WeaponData = null
		if current_weapon and current_weapon.weapon_data:
			w_data = current_weapon.weapon_data
		var target_fov := DEFAULT_FOV
		var target_spring := DEFAULT_SPRING_LENGTH
		var show_scope := false

		if is_aiming and w_data and w_data.ads_fov > 0.0:
			target_fov = w_data.ads_fov
			target_spring = ADS_SPRING_LENGTH
			show_scope = w_data.has_scope

		# Smooth FOV transition
		camera.fov = lerpf(camera.fov, target_fov, ADS_LERP_SPEED * delta)
		# Smooth spring arm transition (camera distance)
		spring_arm.spring_length = lerpf(spring_arm.spring_length, target_spring, ADS_LERP_SPEED * delta)

		# Scope overlay
		_update_scope_overlay(show_scope, delta)


	# Smooth mesh scale for all players (slide/crouch visual)
	var lowered := is_sliding or is_crouching
	var target_scale_y := CROUCH_MESH_SCALE_Y if lowered else _original_mesh_scale_y
	body_mesh.scale.y = lerpf(body_mesh.scale.y, target_scale_y, 12.0 * delta)
	var height_ratio := body_mesh.scale.y / _original_mesh_scale_y
	body_mesh.position.y = _original_mesh_y * height_ratio

	# Update mesh visibility based on alive state
	body_mesh.visible = is_alive
	weapon_mount.visible = is_alive

	# Check if synced weapon visuals changed — load new model/sound on clients
	if equipped_gun_model_path != _last_synced_gun_model_path:
		_last_synced_gun_model_path = equipped_gun_model_path
		_load_gun_model(equipped_gun_model_path)
	if equipped_fire_sound_path != _last_synced_fire_sound_path:
		_last_synced_fire_sound_path = equipped_fire_sound_path
		_load_fire_sound(equipped_fire_sound_path)


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
	# End slide/crouch if active
	if is_sliding:
		_end_slide()
	if is_crouching:
		_end_crouch()
	# Disable collision while dead
	$CollisionShape3D.set_deferred("disabled", true)
	# Clear inventory on death (keep time currency)
	if inventory:
		inventory.clear_all()
	# Drop weapon
	if current_weapon:
		current_weapon.queue_free()
		current_weapon = null
	if _current_gun_model:
		_current_gun_model.queue_free()
		_current_gun_model = null
	equipped_gun_model_path = ""
	equipped_fire_sound_path = ""
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
	## Server-only: equip a weapon by creating the appropriate weapon node
	## and syncing visual paths so clients load the 3D model + sound.
	if current_weapon != null:
		current_weapon.queue_free()

	if weapon_data.is_hitscan:
		current_weapon = WeaponHitscan.new()
	else:
		# Projectile weapon (e.g. rocket launcher)
		current_weapon = WeaponProjectileScript.new()

	current_weapon.setup(weapon_data)
	add_child(current_weapon)

	# Sync weapon visual paths — clients will pick these up and load the model
	equipped_gun_model_path = weapon_data.gun_model_path
	equipped_fire_sound_path = weapon_data.fire_sound_path

	# Server also loads the model (for other players to see)
	_load_gun_model(weapon_data.gun_model_path)
	_load_fire_sound(weapon_data.fire_sound_path)


func _load_gun_model(model_path: String) -> void:
	## Load a .glb gun model and attach it to the weapon mount.
	# Remove old model
	if _current_gun_model != null:
		_current_gun_model.queue_free()
		_current_gun_model = null

	if model_path.is_empty() or not ResourceLoader.exists(model_path):
		return

	var scene: PackedScene = load(model_path)
	if scene == null:
		return

	_current_gun_model = scene.instantiate()
	# Scale the model down to a reasonable size — .glb imports can vary
	_current_gun_model.scale = Vector3(0.15, 0.15, 0.15)
	weapon_mount.add_child(_current_gun_model)


func _load_fire_sound(sound_path: String) -> void:
	## Load a fire sound .ogg into the AudioStreamPlayer3D.
	if sound_path.is_empty() or not ResourceLoader.exists(sound_path):
		fire_sound_player.stream = null
		return

	var stream: AudioStream = load(sound_path)
	fire_sound_player.stream = stream


func _on_item_pickup(world_item: Node) -> void:
	## Server-only: called when this player walks into a WorldItem.
	if not multiplayer.is_server() or not is_alive:
		return
	if inventory == null:
		return

	var item_data: ItemData = world_item.item_data
	if item_data == null:
		return

	# Fuel pickups: consumed instantly, don't occupy a slot
	if item_data.item_type == ItemData.ItemType.FUEL and item_data is FuelData:
		inventory.add_fuel(item_data.fuel_amount)
		world_item.queue_free()
		print("Player %d picked up %s (+%.0f fuel)" % [peer_id, item_data.item_name, item_data.fuel_amount])
		return

	# Shoes go into the dedicated shoe slot
	if item_data.item_type == ItemData.ItemType.SHOE:
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
	# Prevent the dropping player from immediately re-picking this up
	world_item.set_pickup_immunity(peer_id)
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
	## Visual effect: tracer line + muzzle flash + fire sound. Runs on all clients.

	# Play fire sound
	if fire_sound_player and fire_sound_player.stream:
		# If already playing, don't cut off — let rapid-fire overlap
		if fire_sound_player.playing:
			# Spawn a one-shot audio player for overlapping sounds
			var one_shot := AudioStreamPlayer3D.new()
			one_shot.stream = fire_sound_player.stream
			one_shot.max_distance = 60.0
			one_shot.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			one_shot.top_level = true
			add_child(one_shot)
			one_shot.global_position = global_position
			one_shot.play()
			one_shot.finished.connect(one_shot.queue_free)
		else:
			fire_sound_player.play()

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


@rpc("authority", "call_local", "unreliable")
func _show_shotgun_fx(from_pos: Vector3, shot_ends: Array[Vector3]) -> void:
	## Visual effect for multi-pellet weapons: multiple tracer lines + muzzle flash + fire sound.

	# Play fire sound (once per shot, not per pellet)
	if fire_sound_player and fire_sound_player.stream:
		if fire_sound_player.playing:
			var one_shot := AudioStreamPlayer3D.new()
			one_shot.stream = fire_sound_player.stream
			one_shot.max_distance = 60.0
			one_shot.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			one_shot.top_level = true
			add_child(one_shot)
			one_shot.global_position = global_position
			one_shot.play()
			one_shot.finished.connect(one_shot.queue_free)
		else:
			fire_sound_player.play()

	# Draw all pellet tracers in a single ImmediateMesh for efficiency
	var tracer := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	tracer.mesh = im

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.3, 0.6)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 2.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.material_override = mat

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for end_pos in shot_ends:
		im.surface_add_vertex(from_pos)
		im.surface_add_vertex(end_pos)
	im.surface_end()

	tracer.top_level = true
	add_child(tracer)

	# Muzzle flash light (brighter for shotguns)
	var flash := OmniLight3D.new()
	flash.light_color = Color(1.0, 0.8, 0.3)
	flash.light_energy = 8.0
	flash.omni_range = 4.0
	flash.top_level = true
	add_child(flash)
	flash.global_position = from_pos

	# Fade out and cleanup
	var tween := get_tree().create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.12)
	tween.parallel().tween_property(flash, "light_energy", 0.0, 0.1)
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


@rpc("any_peer", "call_local", "reliable")
func rpc_slot_ammo(ammo_index: int, weapon_index: int) -> void:
	## Client requests slotting an ammo module into a weapon.
	if not multiplayer.is_server():
		return
	# Validate sender: remote clients send their ID, host sends 0 (local call)
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != peer_id:
		return
	if inventory == null:
		return

	# Validate indices
	if ammo_index < 0 or ammo_index >= inventory.items.size():
		return
	if weapon_index < 0 or weapon_index >= inventory.items.size():
		return

	var ammo_stack: ItemStack = inventory.items[ammo_index]
	var weapon_stack: ItemStack = inventory.items[weapon_index]

	# Verify types: ammo must be AmmoData OR WeaponData with can_slot_as_ammo
	var valid_ammo: bool = false
	if ammo_stack.item_data is AmmoData:
		valid_ammo = true
	elif ammo_stack.item_data is WeaponData and ammo_stack.item_data.can_slot_as_ammo:
		valid_ammo = true
	if not valid_ammo:
		return
	if not weapon_stack.item_data is WeaponData:
		return
	# Can't slot a weapon into itself
	if ammo_index == weapon_index:
		return
	# Weapon must accept ammo (some weapons like Bubble and Rubber Ball don't)
	if not weapon_stack.item_data.can_receive_ammo:
		return

	# Weapon already has ammo merged — can't merge again
	if weapon_stack.slotted_ammo != null:
		return

	# --- Permanent merge: combine timers, consume ammo item ---
	# Merge burn timers: (weapon_time + ammo_time) * 0.8
	var merged_time: float = (weapon_stack.burn_time_remaining + ammo_stack.burn_time_remaining) * 0.8
	weapon_stack.burn_time_remaining = merged_time

	# Set ammo reference on the weapon
	weapon_stack.slotted_ammo = ammo_stack.item_data
	weapon_stack.slotted_ammo_source_index = -1  # No source — ammo is consumed

	print("Player %d merged %s into %s (timer: %.0fs)" % [peer_id, ammo_stack.item_data.item_name, weapon_stack.item_data.item_name, merged_time])

	# Remove the ammo item from inventory (consumed permanently)
	# Must adjust weapon_index if it comes after ammo_index — the weapon_stack
	# ref is still valid but its position in items[] shifts after removal.
	if ammo_index < weapon_index:
		weapon_index -= 1
	inventory.remove_item(ammo_index)


@rpc("any_peer", "call_local", "reliable")
func rpc_unslot_ammo(_weapon_index: int) -> void:
	## Ammo merging is permanent — this RPC is now a no-op.
	## Keeping the method so old clients don't crash.
	pass


## ---- Extend Item Lifespan (F key) ----
## Spend burn fuel to add time to the equipped weapon. Each press adds a fixed
## chunk of time, but the cost scales up based on how much fuel has already been
## spent on this item — up to 2.5x the base cost.

const EXTEND_BASE_COST := 50.0       ## Fuel cost for the first extension press
const EXTEND_TIME_ADDED := 30.0      ## Seconds added per extension press
const EXTEND_MAX_COST_MULT := 2.5    ## Maximum cost multiplier after many extensions
const EXTEND_SCALE_RATE := 0.003     ## How fast cost ramps up per fuel spent (higher = faster)

func _try_extend_equipped_item() -> void:
	## Server-only: extend the equipped weapon's burn timer by spending fuel.
	if not multiplayer.is_server():
		return
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return

	var stack: ItemStack = inventory.items[inventory.equipped_index]
	if stack.item_data == null:
		return

	# Calculate scaling cost: starts at base, ramps toward base * max_mult
	# Formula: cost = base * (1 + (max_mult - 1) * (1 - e^(-scale_rate * fuel_spent)))
	# This gives a smooth curve: cheap at first, expensive after heavy investment.
	var progress: float = 1.0 - exp(-EXTEND_SCALE_RATE * stack.fuel_spent_extending)
	var cost_mult: float = 1.0 + (EXTEND_MAX_COST_MULT - 1.0) * progress
	var fuel_cost: float = EXTEND_BASE_COST * cost_mult

	if not inventory.has_fuel(fuel_cost):
		return

	inventory.spend_fuel(fuel_cost)
	stack.burn_time_remaining += EXTEND_TIME_ADDED
	stack.fuel_spent_extending += fuel_cost
	print("Player %d extended %s by %.0fs (cost: %.0f fuel, total spent: %.0f)" % [
		peer_id, stack.item_data.item_name, EXTEND_TIME_ADDED, fuel_cost, stack.fuel_spent_extending])


## ---- Scrap Item (X key) ----
## Scrap a nearby ground item (priority) or the equipped weapon into burn fuel.
## Rarer items give significantly more fuel.

const SCRAP_FUEL_BY_RARITY := [30.0, 75.0, 175.0, 400.0, 800.0]  # Common → Legendary
const SCRAP_PICKUP_RANGE := 4.0  ## Max distance to scrap a ground item

func _try_scrap_item() -> void:
	## Server-only: look for a nearby ground item to scrap first, then fall back
	## to scrapping the equipped weapon.
	if not multiplayer.is_server():
		return

	# Priority 1: scrap a nearby WorldItem on the ground
	var scrapped_ground := _try_scrap_ground_item()
	if scrapped_ground:
		return

	# Priority 2: scrap the equipped weapon
	if inventory.equipped_index < 0 or inventory.equipped_index >= inventory.items.size():
		return

	var stack: ItemStack = inventory.items[inventory.equipped_index]
	if stack.item_data == null:
		return

	var rarity: int = stack.item_data.rarity
	var fuel_gained: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	# Bonus fuel based on remaining burn time (more time left = more value)
	fuel_gained += stack.burn_time_remaining * 0.1

	var item_name: String = stack.item_data.item_name
	var idx := inventory.equipped_index

	# If this was the equipped weapon, drop the weapon node
	if current_weapon:
		current_weapon.queue_free()
		current_weapon = null
	if _current_gun_model:
		_current_gun_model.queue_free()
		_current_gun_model = null
	equipped_gun_model_path = ""
	equipped_fire_sound_path = ""

	inventory.remove_item(idx)
	inventory.add_fuel(fuel_gained)
	print("Player %d scrapped %s for %.0f fuel" % [peer_id, item_name, fuel_gained])


func _try_scrap_ground_item() -> bool:
	## Look for the nearest WorldItem within range and scrap it for fuel.
	## Returns true if an item was scrapped.
	var world_items := get_tree().current_scene.get_node_or_null("WorldItems")
	if world_items == null:
		return false

	var player_pos := global_position
	var best_item: Node = null
	var best_dist := SCRAP_PICKUP_RANGE

	for child in world_items.get_children():
		if not child is Area3D or not child.has_method("setup"):
			continue
		if not "item_data" in child or child.item_data == null:
			continue
		var dist: float = player_pos.distance_to(child.global_position)
		if dist < best_dist:
			best_dist = dist
			best_item = child

	if best_item == null:
		return false

	var item_data: ItemData = best_item.item_data
	var rarity: int = item_data.rarity
	var fuel_gained: float = SCRAP_FUEL_BY_RARITY[clampi(rarity, 0, 4)]
	# Bonus fuel based on remaining burn time
	if "burn_time_remaining" in best_item:
		fuel_gained += best_item.burn_time_remaining * 0.1

	inventory.add_fuel(fuel_gained)
	print("Player %d scrapped ground item %s for %.0f fuel" % [peer_id, item_data.item_name, fuel_gained])
	best_item.queue_free()
	return true


func _update_scope_overlay(scope_visible: bool, delta: float) -> void:
	## Show/hide the scope overlay vignette when ADS with a scoped weapon.
	if scope_visible and _scope_overlay == null:
		# Create scope overlay: dark vignette with a circular cutout feel
		_scope_overlay = ColorRect.new()
		_scope_overlay.color = Color(0, 0, 0, 0.0)
		_scope_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_scope_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Add a cross-hair in the scope
		var scope_hud := get_node_or_null("HUDLayer")
		if scope_hud:
			scope_hud.add_child(_scope_overlay)
			# Add fine crosshair lines
			var h_line := ColorRect.new()
			h_line.color = Color(0, 0, 0, 0.8)
			h_line.set_anchors_preset(Control.PRESET_CENTER)
			h_line.custom_minimum_size = Vector2(300, 1)
			h_line.position = Vector2(-150, 0)
			h_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_scope_overlay.add_child(h_line)
			var v_line := ColorRect.new()
			v_line.color = Color(0, 0, 0, 0.8)
			v_line.set_anchors_preset(Control.PRESET_CENTER)
			v_line.custom_minimum_size = Vector2(1, 300)
			v_line.position = Vector2(0, -150)
			v_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_scope_overlay.add_child(v_line)

	if _scope_overlay:
		var target_alpha := 0.6 if scope_visible else 0.0
		_scope_overlay.color.a = lerpf(_scope_overlay.color.a, target_alpha, ADS_LERP_SPEED * delta)
		if not scope_visible and _scope_overlay.color.a < 0.01:
			_scope_overlay.queue_free()
			_scope_overlay = null
