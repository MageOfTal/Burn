extends Node

## Server-side AI brain for bot players.
## Directly writes to the sibling PlayerInput node to simulate input.
## The player.gd _server_process reads PlayerInput the same way for bots
## and real players — no special cases needed in the movement code.
##
## Five-state FSM: WANDER → LOOT_CHEST / PICKUP_ITEM → COMBAT / FLEE_DEMON
## Bots open chests, pick up items, equip the best weapon for the range,
## and fight with weapon-appropriate tactics (projectile leading, shotgun
## rushing, sniper distancing, etc.). Bots flee from nearby active demons.

# ======================================================================
#  Enums
# ======================================================================

enum BotState { WANDER, LOOT_CHEST, PICKUP_ITEM, COMBAT, FLEE_DEMON }

enum WeaponClass { NONE, HITSCAN_GENERAL, SHOTGUN, FLAMETHROWER, SNIPER, PROJECTILE, MELEE }

# ======================================================================
#  Behaviour tuning
# ======================================================================

## --- General ---
const WANDER_INTERVAL_MIN := 2.0     ## Min seconds between picking a new wander target
const WANDER_INTERVAL_MAX := 4.0     ## Max seconds
const WANDER_RADIUS := 50.0          ## How far from current position to pick targets
const EDGE_MARGIN := 20.0            ## Start turning away this far from map edge
const EDGE_HARD_MARGIN := 10.0       ## Emergency turn-around distance
const STUCK_THRESHOLD := 0.3         ## If speed stays below this for STUCK_TIME, re-pick target
const STUCK_TIME := 1.5              ## Seconds of low speed before considered stuck
const LOOK_SMOOTHING := 5.0          ## How fast the bot rotates toward its target yaw
const COMBAT_SCAN_INTERVAL := 0.4    ## Seconds between combat target scans

## --- Item / Chest seeking ---
const PICKUP_RANGE := 8.0            ## Distance to notice and walk toward items
const PICKUP_RANGE_SEEKING := 30.0   ## Extended range when actively seeking weapons (<2 equipped)
const ITEM_PICKUP_RANGE := 3.5       ## Press E when this close to a non-fuel item
const CHEST_SEEK_RANGE := 20.0       ## How far to look for closed chests
const CHEST_SEEK_RANGE_EXTENDED := 50.0 ## Extended range when bot needs weapons
const CHEST_APPROACH_RANGE := 2.5    ## Get this close before pressing E on chest
const CHEST_LINGER_TIME := 1.5       ## Seconds to stay near opened chest to collect loot
const CHEST_SCAN_INTERVAL := 2.0     ## Seconds between chest scans

## --- Weapon seeking ---
const MIN_WEAPONS_BEFORE_FIGHT := 2  ## Bot wants at least this many weapons before engaging

## --- Combat: default ---
const SHOOT_RANGE := 55.0            ## Default max engagement distance (no weapon fallback)
const SHOOT_ANGLE := 0.5             ## Default radians: must face within this angle to fire

## --- Combat: range fractions (applied to weapon_range) ---
## Bots derive engagement distances from the weapon's actual weapon_range property.
## Close-range weapons (shotgun, flamethrower, melee): bot rushes to get within range.
## Long-range weapons (sniper, rifles): bot maintains distance, backs up if too close.
const RANGE_IDEAL_FRACTION := 0.6    ## Bot prefers to fight at 60% of weapon_range
const RANGE_MIN_FRACTION := 0.35     ## Back up if closer than 35% of weapon_range (long-range only)
const MELEE_ENGAGE_RANGE := 6.0      ## Max range to rush with melee (melee has tiny weapon_range)

## --- Weapon switching ---
const WEAPON_SWITCH_COOLDOWN := 1.0  ## Min seconds between weapon switches

## --- Projectile leading ---
const LEAD_INACCURACY := 0.10        ## Random imperfection factor (0 = perfect, 1 = terrible)

## --- Demon fear ---
const DEMON_FEAR_RANGE := 25.0       ## Start fleeing when any demon is this close
const DEMON_PANIC_RANGE := 10.0      ## Sprint and jump when demon is very close

# ======================================================================
#  State
# ======================================================================

var _player: CharacterBody3D = null
var _player_input: Node = null
var _map_half_size: float = 112.0
var _rng := RandomNumberGenerator.new()

## FSM
var _state: int = BotState.WANDER

## Wander
var _wander_target: Vector3 = Vector3.ZERO
var _wander_timer: float = 0.0
var _target_yaw: float = 0.0

## Stuck detection
var _stuck_timer: float = 0.0

## Combat
var _combat_target: CharacterBody3D = null
var _combat_scan_timer: float = 0.0
var _weapon_class: int = WeaponClass.NONE

## Chest seeking
var _target_chest: Node = null
var _chest_scan_timer: float = 0.0
var _chest_linger_timer: float = 0.0

## Item pickup
var _target_item: Node = null

## Weapon switching
var _weapon_switch_cooldown: float = 0.0

## Jump timer: occasionally jump over obstacles
var _random_jump_timer: float = 0.0

## Demon fear
var _nearest_demon_pos: Vector3 = Vector3.ZERO
var _nearest_demon_dist: float = INF

## Deferred first wander (physics queries can't run in _ready with threaded physics)
var _needs_first_wander: bool = false

# ======================================================================
#  Setup
# ======================================================================

func setup(player: CharacterBody3D) -> void:
	_player = player
	_player_input = player.get_node("PlayerInput")
	_rng.seed = hash(player.name) + Time.get_ticks_msec()
	_target_yaw = _rng.randf_range(-PI, PI)
	_needs_first_wander = true  # Deferred to first _physics_process (threaded physics)

	# Try to get map size from the world generator
	var map := player.get_tree().current_scene
	if map:
		var world := map.get_node_or_null("SeedWorld")
		if world and "map_size" in world:
			_map_half_size = world.map_size * 0.5

# ======================================================================
#  Main loop — 5-state FSM
# ======================================================================

func _physics_process(delta: float) -> void:
	if _player == null or _player_input == null:
		return
	if _needs_first_wander:
		_needs_first_wander = false
		_pick_new_wander_target()
	# Skip bot AI while loading screen is up
	if has_node("/root/NetworkManager") and get_node("/root/NetworkManager")._loading_screen != null:
		_clear_inputs()
		return
	if not _player.is_alive:
		_clear_inputs()
		return

	# Tick cooldowns
	_weapon_switch_cooldown -= delta

	# --- Scan for combat targets (always, regardless of state) ---
	_combat_scan_timer -= delta
	if _combat_scan_timer <= 0.0:
		_combat_scan_timer = COMBAT_SCAN_INTERVAL
		_scan_for_targets()

	# --- Scan for nearby demons (every combat scan tick) ---
	_scan_for_demons()

	# --- Scan for chests (periodically during non-combat) ---
	if _state != BotState.COMBAT and _state != BotState.FLEE_DEMON:
		_chest_scan_timer -= delta
		if _chest_scan_timer <= 0.0:
			_chest_scan_timer = CHEST_SCAN_INTERVAL
			if _target_chest == null or not is_instance_valid(_target_chest) or _target_chest.is_open:
				_target_chest = _find_nearest_closed_chest()

	# --- State transitions (priority: FLEE_DEMON > COMBAT > PICKUP_ITEM > LOOT_CHEST > WANDER) ---
	var weapon_count := _count_weapons_in_inventory()
	var needs_weapons: bool = weapon_count < MIN_WEAPONS_BEFORE_FIGHT

	# Highest priority: flee from nearby demons
	if _nearest_demon_dist < DEMON_FEAR_RANGE:
		_state = BotState.FLEE_DEMON
	else:
		var has_combat_target: bool = _combat_target != null and is_instance_valid(_combat_target) and _combat_target.is_alive

		# Under-armed bots avoid fights unless the enemy is very close (within 12m)
		# or they're being shot at (target is close enough to be a threat)
		var should_fight: bool = has_combat_target
		if should_fight and needs_weapons:
			var target_dist := _player.global_position.distance_to(_combat_target.global_position)
			should_fight = target_dist < 12.0  # Only fight if cornered

		if should_fight:
			_state = BotState.COMBAT
		else:
			if _state == BotState.COMBAT:
				_combat_target = null
				_state = BotState.WANDER

			# Check for nearby items — use extended range when seeking weapons
			var nearby_item := _find_nearest_item()
			if nearby_item != null:
				_target_item = nearby_item
				_state = BotState.PICKUP_ITEM
			elif _target_chest != null and is_instance_valid(_target_chest) and not _target_chest.is_open:
				_state = BotState.LOOT_CHEST
			elif _state == BotState.LOOT_CHEST and _chest_linger_timer > 0.0:
				pass  # Keep lingering
			else:
				_target_item = null
				if _state != BotState.WANDER:
					_state = BotState.WANDER

	# --- Execute current state ---
	match _state:
		BotState.WANDER:
			_do_wander(delta)
		BotState.LOOT_CHEST:
			_do_loot_chest(delta)
		BotState.PICKUP_ITEM:
			_do_pickup_item(delta)
		BotState.COMBAT:
			_do_combat(delta)
		BotState.FLEE_DEMON:
			_do_flee_demon(delta)

	# --- Edge avoidance: override direction if near map edge ---
	_apply_edge_avoidance(delta)

	# --- Stuck detection: if barely moving, pick a new target + jump ---
	var horiz_speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	if horiz_speed < STUCK_THRESHOLD and _player.is_on_floor():
		_stuck_timer += delta
		if _stuck_timer > STUCK_TIME:
			_stuck_timer = 0.0
			_pick_new_wander_target()
			_player_input.jump_count += 1
			# Give up on current chest/item if stuck
			if _state == BotState.LOOT_CHEST:
				_target_chest = null
			elif _state == BotState.PICKUP_ITEM:
				_target_item = null
			_state = BotState.WANDER
	else:
		_stuck_timer = 0.0

	# --- Smooth yaw toward target ---
	_player_input.look_yaw = lerp_angle(_player_input.look_yaw, _target_yaw, LOOK_SMOOTHING * delta)

	# Pitch: combat sets it toward aim point; other states keep it level
	if _state != BotState.COMBAT:
		_player_input.look_pitch = lerp(_player_input.look_pitch, -0.1, 2.0 * delta)

# ======================================================================
#  State: WANDER
# ======================================================================

func _do_wander(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_pick_new_wander_target()

	var to_target := _wander_target - _player.global_position
	to_target.y = 0.0

	if to_target.length() < 2.0:
		_pick_new_wander_target()
		_player_input.input_direction = Vector2.ZERO
		return

	# Face the target
	_target_yaw = atan2(-to_target.x, -to_target.z)

	# Always walk forward (input_direction is relative to player facing)
	_player_input.input_direction = Vector2(0, -1)

	# Occasional random jump
	_random_jump_timer -= delta
	if _random_jump_timer <= 0.0:
		_random_jump_timer = _rng.randf_range(4.0, 12.0)
		_player_input.jump_count += 1

	_player_input.action_shoot = false
	_player_input.action_aim = false

	# If we have weapons in inventory but none equipped, equip one
	if _player.current_weapon == null and _count_weapons_in_inventory() > 0:
		_try_switch_weapon()

# ======================================================================
#  State: LOOT_CHEST
# ======================================================================

func _do_loot_chest(delta: float) -> void:
	## Walk toward a closed chest, press E when close, linger to pick up items.
	_player_input.action_shoot = false
	_player_input.action_aim = false

	# --- Linger phase: chest was opened, wait to pick up dropped items ---
	if _chest_linger_timer > 0.0:
		_chest_linger_timer -= delta
		# Try to pick up items during linger
		var nearby_item := _find_nearest_item()
		if nearby_item != null:
			var dist := _player.global_position.distance_to(nearby_item.global_position)
			if dist < ITEM_PICKUP_RANGE:
				_player_input.pickup_count += 1
				_player_input.input_direction = Vector2.ZERO
				# Try to equip after pickup
				if _player.current_weapon == null:
					_try_switch_weapon()
			else:
				# Walk toward the item
				var to_item: Vector3 = nearby_item.global_position - _player.global_position
				to_item.y = 0.0
				if to_item.length() > 0.5:
					_target_yaw = atan2(-to_item.x, -to_item.z)
				_player_input.input_direction = Vector2(0, -1)
		else:
			_player_input.input_direction = Vector2.ZERO
		if _chest_linger_timer <= 0.0:
			_target_chest = null
			_state = BotState.WANDER
		return

	# --- Validate chest still exists and is closed ---
	if _target_chest == null or not is_instance_valid(_target_chest) or _target_chest.is_open:
		_target_chest = null
		_state = BotState.WANDER
		return

	var to_chest: Vector3 = _target_chest.global_position - _player.global_position
	to_chest.y = 0.0
	var dist: float = to_chest.length()

	# Face the chest
	if dist > 0.5:
		_target_yaw = atan2(-to_chest.x, -to_chest.z)

	if dist < CHEST_APPROACH_RANGE:
		# Close enough to open — press E
		_player_input.pickup_count += 1
		_player_input.input_direction = Vector2.ZERO
		_chest_linger_timer = CHEST_LINGER_TIME
	else:
		# Walk toward chest
		_player_input.input_direction = Vector2(0, -1)

	# Occasional jump to clear obstacles
	_random_jump_timer -= delta
	if _random_jump_timer <= 0.0:
		_random_jump_timer = _rng.randf_range(4.0, 12.0)
		_player_input.jump_count += 1

# ======================================================================
#  State: PICKUP_ITEM
# ======================================================================

func _do_pickup_item(delta: float) -> void:
	## Walk toward a nearby item and press E to pick it up.
	_player_input.action_shoot = false
	_player_input.action_aim = false

	if _target_item == null or not is_instance_valid(_target_item):
		_target_item = null
		_state = BotState.WANDER
		return

	var to_item: Vector3 = _target_item.global_position - _player.global_position
	to_item.y = 0.0
	var dist: float = to_item.length()

	if dist > 0.5:
		_target_yaw = atan2(-to_item.x, -to_item.z)

	if dist < ITEM_PICKUP_RANGE:
		# Close enough — press E
		_player_input.pickup_count += 1
		_player_input.input_direction = Vector2.ZERO
		_target_item = null  # Done, will transition next frame

		# After pickup, try to equip a weapon if we have none
		if _player.current_weapon == null:
			_try_switch_weapon()
	else:
		_player_input.input_direction = Vector2(0, -1)

	# Occasional jump
	_random_jump_timer -= delta
	if _random_jump_timer <= 0.0:
		_random_jump_timer = _rng.randf_range(4.0, 12.0)
		_player_input.jump_count += 1

# ======================================================================
#  State: COMBAT (weapon-aware)
# ======================================================================

func _do_combat(delta: float) -> void:
	# Try to equip a weapon if we don't have one
	if _player.current_weapon == null:
		_try_switch_weapon()

	# Validate target
	if _combat_target == null or not is_instance_valid(_combat_target) or not _combat_target.is_alive:
		_combat_target = null
		_state = BotState.WANDER
		return

	var target_pos := _combat_target.global_position
	var to_target := target_pos - _player.global_position
	var horiz_to := Vector3(to_target.x, 0, to_target.z)
	var dist := horiz_to.length()

	# Update weapon class
	var w_data: WeaponData = _player.current_weapon.weapon_data if _player.current_weapon else null
	_weapon_class = _classify_weapon(w_data) if w_data != null else WeaponClass.NONE

	# Consider switching to a better weapon for current range
	_try_switch_weapon()

	# --- Calculate aim position (with projectile leading if needed) ---
	var aim_pos := target_pos
	if _weapon_class == WeaponClass.PROJECTILE and w_data != null:
		var proj_speed := _get_projectile_speed(w_data)
		var target_vel: Vector3 = _combat_target.velocity
		aim_pos = _calculate_lead_position(target_pos, target_vel, proj_speed)

	# --- Face the aim position ---
	var aim_horiz := Vector3(aim_pos.x - _player.global_position.x, 0, aim_pos.z - _player.global_position.z)
	if aim_horiz.length() > 0.5:
		_target_yaw = atan2(-aim_horiz.x, -aim_horiz.z)

	# --- Pitch toward aim position ---
	if dist > 1.0:
		var aim_to := aim_pos - _player.global_position
		var aim_flat_dist := Vector2(aim_to.x, aim_to.z).length()
		var pitch := atan2(-aim_to.y, aim_flat_dist)
		_player_input.look_pitch = clampf(pitch, -1.0, 0.5)

	# --- Movement: depends on weapon class ---
	_do_combat_movement(dist)

	# --- Jump during combat to be harder to hit ---
	_random_jump_timer -= delta
	if _random_jump_timer <= 0.0:
		_random_jump_timer = _rng.randf_range(1.5, 4.0)
		_player_input.jump_count += 1

	# --- Shooting: check angle and range ---
	var facing_dir := Vector3(sin(_player_input.look_yaw), 0, cos(_player_input.look_yaw))
	var angle_to_target := facing_dir.angle_to(horiz_to.normalized()) if horiz_to.length() > 0.5 else PI

	var effective_range := _get_effective_range()
	var shoot_angle := _get_shoot_angle()

	if _player.current_weapon != null:
		_player_input.action_shoot = dist < effective_range and angle_to_target < shoot_angle
	else:
		# No weapon — just rush (action_shoot does nothing without a weapon)
		_player_input.action_shoot = false

	# --- ADS ---
	var w_range_ads: float = w_data.weapon_range if w_data else 0.0
	match _weapon_class:
		WeaponClass.SNIPER:
			# ADS when beyond close-quarters range
			_player_input.action_aim = dist > w_range_ads * RANGE_MIN_FRACTION
		WeaponClass.HITSCAN_GENERAL:
			# ADS at mid-to-long range (beyond 25% of weapon range)
			_player_input.action_aim = dist > w_range_ads * 0.25 and dist < effective_range
		_:
			_player_input.action_aim = false


func _do_combat_movement(dist: float) -> void:
	## Move toward/away from target based on weapon type, weapon_range, and distance.
	## Short-range weapons: rush in aggressively.
	## Long-range weapons: maintain distance, back up if too close.
	var w_data: WeaponData = _player.current_weapon.weapon_data if _player.current_weapon else null
	var w_range: float = w_data.weapon_range if w_data != null else 0.0

	match _weapon_class:
		WeaponClass.MELEE, WeaponClass.NONE:
			# Always rush toward target aggressively
			if dist > 2.0:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.2, 0.2), -1)
			else:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), -0.3)

		WeaponClass.SHOTGUN:
			# Shotguns: rush to ~60% of weapon_range, strafe once in sweet spot
			var ideal := w_range * RANGE_IDEAL_FRACTION
			if dist > ideal:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.2, 0.2), -1)
			else:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.6, 0.6), -0.2)

		WeaponClass.FLAMETHROWER:
			# Flamethrower: rush into range, stay close
			var ideal := w_range * RANGE_IDEAL_FRACTION
			if dist > ideal:
				_player_input.input_direction = Vector2(0, -1)
			elif dist < 3.0:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.4, 0.4), 0)
			else:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), -0.2)

		WeaponClass.SNIPER:
			# Sniper: keep distance, back up if too close
			var min_range := w_range * RANGE_MIN_FRACTION
			var max_range := w_range * 0.85  # Use up to 85% of weapon_range
			if dist < min_range:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.3, 0.3), 0.5)  # Back up
			elif dist > max_range:
				_player_input.input_direction = Vector2(0, -1)  # Close in
			else:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.4, 0.4), 0)  # Strafe

		WeaponClass.PROJECTILE:
			# Projectile: maintain mid-range, slight retreat if too close
			var ideal := w_range * RANGE_IDEAL_FRACTION
			var min_range := w_range * RANGE_MIN_FRACTION
			if dist > ideal:
				_player_input.input_direction = Vector2(0, -1)
			elif dist < min_range:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.4, 0.4), 0.3)  # Retreat
			else:
				_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), -0.2)

		_:  # HITSCAN_GENERAL
			# General hitscan: use weapon_range to decide aggression
			# Short-range hitscan (pistol/smg ≤60m): push in close aggressively
			# Long-range hitscan (AR/LMG/minigun >60m): keep at mid-range
			var ideal := w_range * RANGE_IDEAL_FRACTION
			var min_range := w_range * RANGE_MIN_FRACTION
			if w_range <= 60.0:
				# Short-range hitscan — aggressive push
				if dist > ideal:
					_player_input.input_direction = Vector2(0, -1)
				elif dist < 6.0:
					_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), 0)
				else:
					_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), -0.3)
			else:
				# Long-range hitscan — maintain distance, strafe
				if dist > ideal:
					_player_input.input_direction = Vector2(0, -1)
				elif dist < min_range:
					_player_input.input_direction = Vector2(_rng.randf_range(-0.3, 0.3), 0.4)  # Back up
				else:
					_player_input.input_direction = Vector2(_rng.randf_range(-0.5, 0.5), 0)  # Strafe

# ======================================================================
#  Combat helpers: effective range & shoot angle per weapon
# ======================================================================

func _get_effective_range() -> float:
	## Returns the max distance at which the bot will pull the trigger.
	## Derived from the weapon's actual weapon_range property.
	var w_data: WeaponData = _player.current_weapon.weapon_data if _player.current_weapon else null
	if w_data == null:
		return MELEE_ENGAGE_RANGE if _weapon_class == WeaponClass.MELEE else SHOOT_RANGE

	match _weapon_class:
		WeaponClass.MELEE:
			return MELEE_ENGAGE_RANGE
		WeaponClass.SHOTGUN:
			# Shotguns: shoot up to full weapon_range (pellet spread handles falloff)
			return w_data.weapon_range
		WeaponClass.FLAMETHROWER:
			# Flamethrower: fire at ~90% of range (particles have some travel)
			return w_data.weapon_range * 0.9
		WeaponClass.SNIPER:
			# Sniper: use most of weapon_range
			return w_data.weapon_range * 0.85
		WeaponClass.PROJECTILE:
			# Projectile: effective up to ~80% of range (travel time reduces accuracy)
			return w_data.weapon_range * 0.8
		_:
			# Hitscan general: use ~90% of weapon_range
			return w_data.weapon_range * 0.9


func _get_shoot_angle() -> float:
	match _weapon_class:
		WeaponClass.SNIPER:
			return 0.15  # Very precise aiming required
		WeaponClass.SHOTGUN:
			return 0.6   # Wide spread is forgiving
		WeaponClass.FLAMETHROWER:
			return 0.7   # Very forgiving
		WeaponClass.PROJECTILE:
			return 0.35  # Moderate precision
		WeaponClass.MELEE:
			return 0.5   # Fairly forgiving
		_:
			return SHOOT_ANGLE

# ======================================================================
#  Projectile leading
# ======================================================================

func _get_projectile_speed(w_data: WeaponData) -> float:
	## Get the launch speed for the given weapon's projectile.
	## Hardcoded by scene path to avoid instantiation overhead.
	if w_data == null or w_data.projectile_scene == null:
		return 0.0
	var path: String = w_data.projectile_scene.resource_path
	if "rocket" in path:
		return 50.0
	elif "rubber_ball" in path:
		return 40.0
	elif "bubble" in path:
		return 8.0
	return 10.0  # ProjectileBase default


func _calculate_lead_position(target_pos: Vector3, target_vel: Vector3, projectile_speed: float) -> Vector3:
	## Calculate where to aim to hit a moving target with a projectile.
	## Uses iterative linear prediction with random inaccuracy.
	if projectile_speed <= 0.0:
		return target_pos

	var dist := _player.global_position.distance_to(target_pos)
	if dist < 1.0:
		return target_pos

	var flight_time := dist / projectile_speed

	# Two refinement iterations for better accuracy
	for _i in 2:
		var predicted_pos := target_pos + target_vel * flight_time
		var new_dist := _player.global_position.distance_to(predicted_pos)
		flight_time = new_dist / projectile_speed

	var lead_pos := target_pos + target_vel * flight_time

	# Add inaccuracy (humanlike imperfection)
	var inaccuracy := LEAD_INACCURACY * dist * 0.01
	lead_pos.x += _rng.randf_range(-inaccuracy, inaccuracy)
	lead_pos.z += _rng.randf_range(-inaccuracy, inaccuracy)

	return lead_pos

# ======================================================================
#  Weapon classification & switching
# ======================================================================

func _classify_weapon(weapon_data: WeaponData) -> int:
	## Classify a WeaponData into a WeaponClass for combat behavior selection.
	if weapon_data == null:
		return WeaponClass.NONE

	# Melee: not hitscan AND no projectile scene
	if not weapon_data.is_hitscan and weapon_data.projectile_scene == null:
		return WeaponClass.MELEE

	# Projectile weapons
	if not weapon_data.is_hitscan and weapon_data.projectile_scene != null:
		return WeaponClass.PROJECTILE

	# Hitscan sub-types
	if weapon_data.has_scope:
		return WeaponClass.SNIPER
	if weapon_data.pellet_count > 1:
		return WeaponClass.SHOTGUN
	if weapon_data.weapon_range <= 20.0 and weapon_data.fire_rate <= 0.1:
		return WeaponClass.FLAMETHROWER

	return WeaponClass.HITSCAN_GENERAL


func _try_switch_weapon() -> void:
	## Evaluate all inventory slots and switch to the best weapon for current situation.
	if _weapon_switch_cooldown > 0.0:
		return

	var inv = _player.inventory
	if inv == null:
		return

	# Determine combat distance (use 15.0 as default if no target)
	var combat_dist := 15.0
	if _combat_target != null and is_instance_valid(_combat_target):
		combat_dist = _player.global_position.distance_to(_combat_target.global_position)

	var best_score := -999.0
	var best_slot := -1

	for i in inv.items.size():
		if inv.items[i] == null:
			continue
		if not inv.items[i].item_data is WeaponData:
			continue
		var score := _score_weapon(inv.items[i].item_data as WeaponData, combat_dist)
		if score > best_score:
			best_score = score
			best_slot = i

	if best_slot >= 0 and best_slot != inv.equipped_index:
		_player_input.slot_select = best_slot + 1  # 1-indexed
		_player_input.slot_count += 1
		_weapon_switch_cooldown = WEAPON_SWITCH_COOLDOWN


func _score_weapon(weapon_data: WeaponData, combat_dist: float) -> float:
	## Score a weapon for how good it is at the given combat distance.
	## Uses the weapon's actual weapon_range to evaluate suitability.
	## Higher score = better choice.
	if weapon_data == null:
		return 0.0

	var score: float = 0.0

	# Base score from rarity (0-4 mapped to 10-50)
	score += (weapon_data.rarity + 1) * 10.0

	# DPS approximation
	var dps: float = weapon_data.damage / maxf(weapon_data.fire_rate, 0.01)
	score += dps * 0.5

	# Range suitability — score based on how well weapon_range matches combat distance
	var w_range := weapon_data.weapon_range
	var wclass := _classify_weapon(weapon_data)
	match wclass:
		WeaponClass.MELEE:
			if combat_dist < MELEE_ENGAGE_RANGE:
				score += 40.0
			else:
				score -= 100.0
		WeaponClass.SHOTGUN, WeaponClass.FLAMETHROWER:
			# Close-range weapons: great when in range, terrible outside it
			if combat_dist <= w_range:
				score += 35.0
			elif combat_dist <= w_range * 1.5:
				score += 0.0  # Reachable if we close in
			else:
				score -= 60.0  # Way too far
		WeaponClass.SNIPER:
			# Snipers: want distance, penalized up close
			var min_range := w_range * RANGE_MIN_FRACTION
			if combat_dist > min_range and combat_dist < w_range:
				score += 30.0
			elif combat_dist <= min_range:
				score -= 20.0  # Too close for comfort
			else:
				score += 10.0  # Can still try at long range
		_:  # HITSCAN_GENERAL, PROJECTILE
			# Score based on how well combat_dist fits within weapon_range
			if combat_dist <= w_range:
				# Within range: closer to ideal (60% of range) = higher score
				var ideal := w_range * RANGE_IDEAL_FRACTION
				var range_fit := 1.0 - absf(combat_dist - ideal) / w_range
				score += 20.0 + range_fit * 15.0
			else:
				# Out of range: penalize proportionally
				score -= 30.0 * (combat_dist / w_range)

	return score

# ======================================================================
#  Scanning: targets, chests, items
# ======================================================================

func _scan_for_targets() -> void:
	_combat_target = null
	# Use weapon's effective range for scan distance, with a minimum of SHOOT_RANGE
	var scan_range := _get_effective_range()
	scan_range = maxf(scan_range, SHOOT_RANGE)  # Never scan shorter than default
	var best_dist := scan_range
	var my_in_toad: bool = _player.get("in_toad_dimension") == true

	# Use NetworkManager.players dict to find targets regardless of container
	for peer_id in NetworkManager.players:
		var other: Node = NetworkManager.players[peer_id]
		if other == _player:
			continue
		if not other is CharacterBody3D:
			continue
		if not other.get("is_alive"):
			continue
		# Skip targets in a different dimension
		if (other.get("in_toad_dimension") == true) != my_in_toad:
			continue
		var dist := _player.global_position.distance_to(other.global_position)
		if dist < best_dist:
			best_dist = dist
			_combat_target = other


func _find_nearest_closed_chest() -> Node:
	## Find the nearest closed LootChest within range.
	## Uses extended range when bot needs weapons.
	var scene := _player.get_tree().current_scene
	if scene == null:
		return null
	var items_container := scene.get_node_or_null("WorldItems")
	if items_container == null:
		return null

	var needs_weapons: bool = _count_weapons_in_inventory() < MIN_WEAPONS_BEFORE_FIGHT
	var seek_range: float = CHEST_SEEK_RANGE_EXTENDED if needs_weapons else CHEST_SEEK_RANGE
	var best_dist := seek_range
	var best_chest: Node = null
	for child in items_container.get_children():
		if not child is LootChest:
			continue
		if child.is_open:
			continue
		var dist := _player.global_position.distance_to(child.global_position)
		if dist < best_dist:
			best_dist = dist
			best_chest = child
	return best_chest


func _find_nearest_item() -> Node:
	## Find the nearest non-fuel, non-chest WorldItem within range.
	## Prioritizes weapons when the bot has fewer than MIN_WEAPONS_BEFORE_FIGHT.
	## Uses extended range when actively seeking weapons.
	var scene := _player.get_tree().current_scene
	if scene == null:
		return null
	var items_container := scene.get_node_or_null("WorldItems")
	if items_container == null:
		return null

	var weapon_count := _count_weapons_in_inventory()
	var needs_weapons: bool = weapon_count < MIN_WEAPONS_BEFORE_FIGHT
	var search_range: float = PICKUP_RANGE_SEEKING if needs_weapons else PICKUP_RANGE
	var best_dist := search_range
	var best_item: Node = null
	var best_is_weapon := false

	for item in items_container.get_children():
		if not is_instance_valid(item):
			continue
		# Skip chests — handled by _find_nearest_closed_chest
		if item is LootChest:
			continue
		if not "item_data" in item or item.item_data == null:
			continue
		# Skip fuel — auto-picked up on contact
		if item.item_data.item_type == ItemData.ItemType.FUEL:
			continue
		# Skip items with pickup immunity for this bot
		if item.has_method("is_immune_to") and item.is_immune_to(_player.peer_id):
			continue

		var dist := _player.global_position.distance_to(item.global_position)
		var is_weapon: bool = item.item_data is WeaponData

		# When seeking weapons, extend range only for weapons; non-weapons still use normal range
		var max_range: float = search_range if (needs_weapons and is_weapon) else PICKUP_RANGE
		if dist >= max_range:
			continue

		# Prioritize weapons when we need them
		if needs_weapons and is_weapon and not best_is_weapon:
			# First weapon found — always take it
			best_dist = dist
			best_item = item
			best_is_weapon = true
		elif is_weapon == best_is_weapon:
			# Same priority tier — pick the closer one
			if dist < best_dist:
				best_dist = dist
				best_item = item
		elif not best_is_weapon:
			# Current best is non-weapon; this is also non-weapon — pick closer
			if dist < best_dist:
				best_dist = dist
				best_item = item

	return best_item

# ======================================================================
#  Inventory helpers
# ======================================================================

func _count_weapons_in_inventory() -> int:
	var inv = _player.inventory
	if inv == null:
		return 0
	var count := 0
	for stack in inv.items:
		if stack != null and stack.item_data is WeaponData:
			count += 1
	return count

# ======================================================================
#  Demon fear: scan and flee
# ======================================================================

func _scan_for_demons() -> void:
	## Check all players' demon systems for active demons near this bot.
	## Bots fear ANY active demon, not just their own (they don't have one).
	_nearest_demon_dist = INF
	_nearest_demon_pos = Vector3.ZERO

	for peer_id in NetworkManager.players:
		var other: Node = NetworkManager.players[peer_id]
		if not other is CharacterBody3D:
			continue
		var demon_sys = other.get_node_or_null("DemonSystem")
		if demon_sys == null:
			continue
		if not demon_sys.demon_active:
			continue
		var dist := _player.global_position.distance_to(demon_sys.demon_position)
		if dist < _nearest_demon_dist:
			_nearest_demon_dist = dist
			_nearest_demon_pos = demon_sys.demon_position


func _do_flee_demon(delta: float) -> void:
	## Run directly away from the nearest demon. Panic jump when very close.
	_player_input.action_shoot = false
	_player_input.action_aim = false

	var away_dir := _player.global_position - _nearest_demon_pos
	away_dir.y = 0.0
	if away_dir.length() < 0.1:
		away_dir = Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1))
	away_dir = away_dir.normalized()

	# Face away from demon and sprint
	_target_yaw = atan2(-away_dir.x, -away_dir.z)
	_player_input.input_direction = Vector2(0, -1)

	# Panic jump when demon is very close
	if _nearest_demon_dist < DEMON_PANIC_RANGE:
		_random_jump_timer -= delta
		if _random_jump_timer <= 0.0:
			_random_jump_timer = _rng.randf_range(0.5, 1.5)
			_player_input.jump_count += 1


# ======================================================================
#  Navigation helpers
# ======================================================================

func _pick_new_wander_target() -> void:
	_wander_timer = _rng.randf_range(WANDER_INTERVAL_MIN, WANDER_INTERVAL_MAX)

	# Pick a random point within WANDER_RADIUS, clamped to safe area
	var safe_limit := _map_half_size - EDGE_MARGIN
	var target_x := _player.global_position.x + _rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS)
	var target_z := _player.global_position.z + _rng.randf_range(-WANDER_RADIUS, WANDER_RADIUS)
	target_x = clampf(target_x, -safe_limit, safe_limit)
	target_z = clampf(target_z, -safe_limit, safe_limit)

	# Query terrain height at target position
	var target_y := _player.global_position.y  # Fallback
	var map := _player.get_tree().current_scene
	if map:
		var world := map.get_node_or_null("SeedWorld")
		if world and world.has_method("get_height_at"):
			target_y = world.get_height_at(target_x, target_z) + 1.0

	_wander_target = Vector3(target_x, target_y, target_z)


func _apply_edge_avoidance(_delta: float) -> void:
	## If near the map edge, steer the bot away from the edge.
	var pos := _player.global_position
	var hard := _map_half_size - EDGE_HARD_MARGIN
	var soft := _map_half_size - EDGE_MARGIN

	var nudge := Vector3.ZERO
	# X edges
	if pos.x > soft:
		nudge.x -= (pos.x - soft) / (hard - soft)
	elif pos.x < -soft:
		nudge.x -= (pos.x + soft) / (hard - soft)
	# Z edges
	if pos.z > soft:
		nudge.z -= (pos.z - soft) / (hard - soft)
	elif pos.z < -soft:
		nudge.z -= (pos.z + soft) / (hard - soft)

	if nudge.length() > 0.1:
		# Override wander target to move away from edge
		_wander_target = _player.global_position + nudge.normalized() * 30.0
		_wander_target.x = clampf(_wander_target.x, -soft, soft)
		_wander_target.z = clampf(_wander_target.z, -soft, soft)
		# Face away from edge
		_target_yaw = atan2(-nudge.x, -nudge.z)

	# Emergency: hard clamp position if somehow past the hard edge
	if absf(pos.x) > hard or absf(pos.z) > hard:
		_player_input.input_direction = Vector2(0, -1)
		_target_yaw = atan2(-nudge.x, -nudge.z) if nudge.length() > 0.01 else _target_yaw

# ======================================================================
#  Input clearing
# ======================================================================

func _clear_inputs() -> void:
	_player_input.input_direction = Vector2.ZERO
	_player_input.action_shoot = false
	_player_input.action_aim = false
	_player_input.action_slide = false
