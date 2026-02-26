extends PlayerSubsystem
class_name PlayerCombat

## Player combat subsystem — owns weapon firing, damage dispatch, ADS state,
## bullet whiz-by, and aim target resolution.
##
## Delegated from player.gd: player retains weapon equip/unequip and health
## management, but calls into combat for fire processing and ADS updates.


# ======================================================================
#  ADS
# ======================================================================

func update_ads_state() -> void:
	## Update ADS (aim down sights) state based on input and weapon capability.
	var w_data: WeaponData = player.current_weapon.weapon_data if player.current_weapon else null
	player.is_aiming = player.player_input.action_aim and w_data != null and w_data.ads_fov > 0.0


# ======================================================================
#  Medkit heal
# ======================================================================

func process_medkit_heal() -> void:
	## Server-only: heal 1 HP per frame, costing 5 fuel per frame.
	if player.heat_system == null or player.inventory == null:
		return
	var effective_max_hp: float = player.get_max_health()
	if player.health >= effective_max_hp:
		return
	if not player.inventory.spend_fuel_silent(5.0):
		return
	player.health = minf(player.health + 1.0, effective_max_hp)


# ======================================================================
#  Combat processing (weapon fire + damage dispatch)
# ======================================================================

func process_combat() -> void:
	## Server-only: handle weapon firing, damage, and VFX dispatch.
	var current_weapon: WeaponBase = player.current_weapon

	# Calculate fuel cost (skip if free firing debug is on)
	var equipped_stack: ItemStack = null
	if player.inventory and player.inventory.equipped_index >= 0 \
			and player.inventory.equipped_index < player.inventory.items.size() \
			and player.inventory.items[player.inventory.equipped_index] != null:
		equipped_stack = player.inventory.items[player.inventory.equipped_index]

	if not GameManager.debug_free_firing and not player.is_bot:
		var fuel_cost: float = current_weapon.weapon_data.burn_fuel_cost
		if equipped_stack and equipped_stack.slotted_ammo:
			fuel_cost += equipped_stack.slotted_ammo.ammo_burn_cost_per_shot

		if not player.inventory.has_fuel(fuel_cost):
			return

		player.inventory.spend_fuel(fuel_cost)

	# Set ammo context on weapon before firing
	if equipped_stack and equipped_stack.slotted_ammo:
		current_weapon.ammo_data = equipped_stack.slotted_ammo
	else:
		current_weapon.ammo_data = null

	# Third-person aiming: ray from camera through crosshair
	var cam_origin := player.camera.global_position
	var cam_forward := -player.camera.global_transform.basis.z
	var aim_target := _get_camera_aim_target(cam_origin, cam_forward)

	var is_melee: bool = current_weapon is WeaponMelee
	var muzzle_pos: Vector3
	if is_melee:
		muzzle_pos = player.global_position + Vector3(0, 1.2, 0)
	else:
		muzzle_pos = _get_barrel_position()
	var aim_direction := (aim_target - muzzle_pos).normalized()

	# Reduce spread (Steady Hand bonus + ADS)
	var saved_spread: float = current_weapon.weapon_data.spread
	if 1 in player.active_bonuses:  # Steady Hand: -15% spread
		current_weapon.weapon_data.spread *= 0.85
	if player.is_aiming:
		current_weapon.weapon_data.spread *= current_weapon.weapon_data.ads_spread_mult

	var hit_info := current_weapon.try_fire(player, muzzle_pos, aim_direction)

	# Quick Hands bonus: -20% fire rate cooldown
	if 4 in player.active_bonuses and current_weapon:
		current_weapon.cooldown_remaining *= 0.80

	# Restore original spread
	current_weapon.weapon_data.spread = saved_spread

	if hit_info.has("melee_hit") or hit_info.has("melee_miss"):
		player.combat_vfx.show_melee_swing_fx.rpc(muzzle_pos, aim_direction)

		if hit_info.has("melee_hit"):
			var melee_target = hit_info.get("hit_collider")
			print("[Melee] HIT collider=%s is_Player=%s has_take_damage=%s" % [
				str(melee_target), str(melee_target is Player),
				str(melee_target.has_method("take_damage") if melee_target else false)])
			if melee_target is Player and melee_target.has_method("take_damage"):
				if player.has_node("/root/ToadDimension"):
					player.get_node("/root/ToadDimension").enter(player, melee_target)
				player.heat_system.on_damage_dealt(10.0)
		else:
			print("[Melee] MISS")

	elif hit_info.has("pellets"):
		_process_pellet_hits(hit_info, current_weapon, muzzle_pos)

	elif hit_info.has("shot_end"):
		_process_single_hit(hit_info, current_weapon, muzzle_pos)


func _process_pellet_hits(hit_info: Dictionary, current_weapon: WeaponBase, muzzle_pos: Vector3) -> void:
	## Multi-pellet weapon (shotgun) damage dispatch.
	var pellets: Array = hit_info["pellets"]
	var pellet_count := pellets.size()
	var rarity_damage_per_pellet: float = current_weapon.weapon_data.get_rarity_damage() / pellet_count
	var rarity_struct_dmg_per_pellet: float = current_weapon.weapon_data.get_rarity_structure_damage() / pellet_count
	var base_damage_per_pellet: float = current_weapon.weapon_data.damage / pellet_count
	var total_damage_dealt: float = 0.0

	var shot_ends: Array[Vector3] = []
	for pellet in pellets:
		if pellet.has("shot_end"):
			shot_ends.append(pellet["shot_end"])

	if shot_ends.size() > 0:
		player.combat_vfx.show_shotgun_fx.rpc(muzzle_pos, shot_ends)

	var hit_player_ids: Dictionary = {}  # peer_id -> true, to avoid duplicate whiz on hit targets
	for pellet in pellets:
		var collider = pellet.get("hit_collider")
		if collider == null:
			continue
		var is_player_hit := collider is Player
		var base_pellet_dmg := rarity_damage_per_pellet if is_player_hit else rarity_struct_dmg_per_pellet
		var final_damage: float = base_pellet_dmg * player.heat_system.get_damage_multiplier()
		if 11 in player.active_bonuses:  # Juggernaut: +10% damage
			final_damage *= 1.10
		if not is_player_hit and collider.has_method("take_damage_at"):
			var hit_pos: Vector3 = pellet.get("hit_position", collider.global_position)
			collider.take_damage_at(hit_pos, final_damage, 0.5, player.peer_id)
		elif collider.has_method("take_damage"):
			collider.take_damage(final_damage, player.peer_id)
		if is_player_hit:
			total_damage_dealt += base_damage_per_pellet
			hit_player_ids[collider.peer_id] = true
			player.combat_vfx.play_bullet_hit_sound.rpc(pellet["shot_end"])

	if total_damage_dealt > 0.0:
		player.heat_system.on_damage_dealt(total_damage_dealt)

	_dispatch_bullet_whiz(muzzle_pos, shot_ends, hit_player_ids)


func _process_single_hit(hit_info: Dictionary, current_weapon: WeaponBase, muzzle_pos: Vector3) -> void:
	## Single-pellet weapon damage dispatch.
	player.combat_vfx.show_shot_fx.rpc(muzzle_pos, hit_info["shot_end"])

	var hit_player_ids: Dictionary = {}
	var collider = hit_info.get("hit_collider")
	if collider != null:
		var is_player_hit := collider is Player
		var base_dmg: float
		if is_player_hit:
			base_dmg = current_weapon.weapon_data.get_rarity_damage()
		else:
			base_dmg = current_weapon.weapon_data.get_rarity_structure_damage()
		var final_damage: float = base_dmg * player.heat_system.get_damage_multiplier()
		if 11 in player.active_bonuses:  # Juggernaut: +10% damage
			final_damage *= 1.10
		if not is_player_hit and collider.has_method("take_damage_at"):
			var hit_pos: Vector3 = hit_info.get("hit_position", collider.global_position)
			collider.take_damage_at(hit_pos, final_damage, 0.5, player.peer_id)
		elif collider.has_method("take_damage"):
			collider.take_damage(final_damage, player.peer_id)
		if is_player_hit:
			player.heat_system.on_damage_dealt(current_weapon.weapon_data.damage)
			hit_player_ids[collider.peer_id] = true
			player.combat_vfx.play_bullet_hit_sound.rpc(hit_info["shot_end"])

	_dispatch_bullet_whiz(muzzle_pos, [hit_info["shot_end"]], hit_player_ids)


# ======================================================================
#  Bullet whiz-by
# ======================================================================

func _dispatch_bullet_whiz(muzzle_pos: Vector3, shot_ends: Array, hit_player_ids: Dictionary) -> void:
	## Server-only: check all other players for bullet close-miss and send whiz sounds.
	var whiz_dist_sq := CombatVFX.BULLET_WHIZ_DISTANCE * CombatVFX.BULLET_WHIZ_DISTANCE
	var notified: Dictionary = {}  # peer_id -> true, one whiz per player per volley

	for other_peer_id in NetworkManager.players:
		if other_peer_id == player.peer_id:
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


# ======================================================================
#  Aim helpers
# ======================================================================

func _get_barrel_position() -> Vector3:
	## Returns the world-space position of the gun barrel tip.
	if player.current_weapon and player.current_weapon.weapon_data:
		var offset: Vector3 = player.current_weapon.weapon_data.barrel_offset
		return player.weapon_mount.global_transform * offset
	return player.camera_pivot.global_position


func _get_camera_aim_target(cam_origin: Vector3, cam_forward: Vector3) -> Vector3:
	## Raycast from the camera through screen-center to find the aim target.
	var space_state := player.get_world_3d().direct_space_state
	var far_point := cam_origin + cam_forward * 1000.0
	var player_bit: int = CollisionLayers.player_bit(player.in_toad_dimension)
	var query := PhysicsRayQueryParameters3D.create(cam_origin, far_point)
	query.exclude = [player.get_rid()]
	query.collision_mask = CollisionLayers.WORLD | CollisionLayers.ITEMS | CollisionLayers.BUBBLES | CollisionLayers.RUBBER_BALLS | CollisionLayers.TOAD_WALLS | player_bit
	var result := space_state.intersect_ray(query)
	if not result.is_empty():
		return result.position
	return far_point
