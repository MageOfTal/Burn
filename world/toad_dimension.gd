extends Node

## The Toad Dimension — a shared pocket arena at Y=-500 in the main World3D.
## Players are teleported down, not reparented (reparenting breaks the
## MultiplayerSpawner). Physics isolation is achieved via collision layer
## swapping so overworld hitscan/physics queries don't interact with toad
## dimension players and vice versa.
##
## Visual isolation is handled by environment swapping (fog, sky, ambient light)
## — 500m underground, the overworld is not visible.
##
## Each player gets their own independent exit timer. Multiple pairs can fight
## simultaneously in the same space amid a shared toad rain.
##
## Server-authoritative: only the server teleports players and manages sessions.
##
## Toad bodies are full RigidBody3D physics objects (toad_body.tscn).
## Each toad bounces once off the floor, then phases through the ground
## and despawns when it falls far enough below. Toads push players on
## contact via PhysicsBodyBase (mass = 4 kg, 1/20th of player mass).

const DIMENSION_Y: float = -500.0        ## Arena floor Y
const FLOOR_SIZE: float = 500.0          ## Massive floor to look endless
const CEILING_HEIGHT: float = 60.0       ## Invisible ceiling height
const SESSION_DURATION: float = 10.0     ## Seconds trapped in the dimension
const GIANT_TOAD_Y_OFFSET: float = 30.0  ## Raise toad so it sits on the floor
const GIANT_TOAD_DISTANCE: float = 350.0 ## Far enough players can't reach it
const TOAD_RAIN_INTERVAL: float = 0.03   ## Seconds between toad spawns (massive downpour)
const TOAD_RAIN_AREA: float = 52.5       ## Radius of toad rain spread (50% larger)
var toads_per_tick: int = 400             ## Toads spawned per rain tick (adjustable via pause menu)
const TOAD_SCATTER_SPEED: float = 8.0    ## How fast toads scatter on session end
const TOAD_DESPAWN_DELAY: float = 3.0    ## Seconds after session ends before remaining toads are freed
const TOAD_MAX: int = 1000000              ## Maximum toad bodies alive at once

## Collision layers saved/restored during dimension transition.
## Toad dimension players move to layer 9 (bit 256) — an unused layer
## that no overworld weapon mask includes. Their mask hits world geometry
## (toad floor/ceiling), toad walls, toad rain, and other toad players.
## Overworld hitscan masks (1|2|4|8|16|128) don't include 256, so
## toad players are completely invisible to overworld weapons.
const TOAD_COLLISION_LAYER: int = 256        ## Layer 9 (toad dimension players)
const TOAD_COLLISION_MASK: int = 1 | 16 | 64 | 256  ## World + toad walls + toad rain + toad players

## Pre-loaded toad body scene
var _toad_body_scene: PackedScene = null

## Fixed arena center — all sessions share the same space
var _arena_center: Vector3 = Vector3(0, DIMENSION_Y + 1.0, 0)

var _arena_built: bool = false
var _arena_node: Node3D = null

## Shared materials (created once)
var _floor_mat: StandardMaterial3D = null

## Client-side environment swap
var _toad_env: Environment = null
var _overworld_env: Environment = null
var _is_showing_toad_env: bool = false

## Container node for spawned toad RigidBody3D instances
var _shared_toads_container: Node3D = null
var _toad_rain_timer: float = 0.0
var _toads_despawning: bool = false  ## True while scatter/despawn is in progress

## Per-player tracking: {peer_id: PlayerToadData}
## Each player has their own timer and saved position. Leaving is independent.
var _players: Dictionary = {}

## Shared rain timer — reset (not stacked) when new players enter.
var _rain_duration: float = 0.0


class PlayerToadData:
	var player: CharacterBody3D
	var saved_pos: Vector3
	var saved_collision_layer: int
	var saved_collision_mask: int
	var timer: float


func enter(attacker: CharacterBody3D, victim: CharacterBody3D) -> void:
	## Server-only: send two players to the toad dimension.
	## Each player gets their own independent exit timer.
	## The shared rain timer is reset (not stacked) on each new entry.
	if not multiplayer.is_server():
		return

	# Don't toad someone already in the toad dimension
	if attacker.get("in_toad_dimension") or victim.get("in_toad_dimension"):
		return

	# Build shared arena infrastructure on first use
	if not _arena_built:
		_build_arena()

	# Save positions before teleport
	var attacker_saved_pos := attacker.global_position
	var victim_saved_pos := victim.global_position

	# Register both players with independent timers
	_register_player(attacker, attacker_saved_pos)
	_register_player(victim, victim_saved_pos)

	# Cancel any active movement abilities before teleporting
	attacker.reset_movement_states()
	victim.reset_movement_states()

	# Mark as in toad dimension so the flag is synced
	attacker.in_toad_dimension = true
	victim.in_toad_dimension = true

	# Swap collision layers for physics isolation
	_apply_toad_collision(attacker)
	_apply_toad_collision(victim)

	# Disable VoxelViewers (no voxel terrain at Y=-500)
	_set_voxel_viewer_enabled(attacker, false)
	_set_voxel_viewer_enabled(victim, false)

	# Teleport players to the toad arena — spread them out per pair
	var pair_offset := Vector3(randf_range(-8, 8), 0, randf_range(-8, 8))
	var attacker_pos := _arena_center + pair_offset + Vector3(-3, 0, 0)
	var victim_pos := _arena_center + pair_offset + Vector3(3, 0, 0)
	attacker.global_position = attacker_pos
	victim.global_position = victim_pos

	# Zero velocity to prevent carrying momentum from overworld
	attacker.velocity = Vector3.ZERO
	victim.velocity = Vector3.ZERO

	# Face players toward each other
	var to_victim := victim_pos - attacker_pos
	attacker.rotation.y = atan2(to_victim.x, to_victim.z)
	victim.rotation.y = atan2(-to_victim.x, -to_victim.z)

	# Reset (not stack) the shared rain timer
	_rain_duration = SESSION_DURATION

	# Notify clients for VFX / environment swap
	_on_enter_toad_dimension.rpc(attacker.peer_id, victim.peer_id)

	print("[ToadDimension] Players %d and %d entered (%d players in dimension)" % [
		attacker.peer_id, victim.peer_id, _players.size()
	])


func _register_player(player: CharacterBody3D, overworld_pos: Vector3) -> void:
	## Add a player to the dimension with their own exit timer.
	## If already inside, reset their timer.
	var data := PlayerToadData.new()
	data.player = player
	data.saved_pos = overworld_pos
	data.saved_collision_layer = player.collision_layer
	data.saved_collision_mask = player.collision_mask
	data.timer = SESSION_DURATION
	_players[player.peer_id] = data


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	# Tick each player's individual exit timer
	var exiting_peers: Array[int] = []
	for peer_id in _players:
		var data: PlayerToadData = _players[peer_id]

		if not is_instance_valid(data.player) or not data.player.is_alive:
			exiting_peers.append(peer_id)
			continue

		data.timer -= delta
		if data.timer <= 0.0:
			exiting_peers.append(peer_id)

	# Return players whose timers expired or who died
	for peer_id in exiting_peers:
		_exit_player(peer_id)

	var anyone_inside: bool = _players.size() > 0

	# Shared toad rain — single rain source, ticking down independently
	if anyone_inside and is_instance_valid(_shared_toads_container):
		_rain_duration -= delta
		if _rain_duration > 0.0:
			_toad_rain_timer -= delta
			if _toad_rain_timer <= 0.0:
				_toad_rain_timer = TOAD_RAIN_INTERVAL
				for _i in range(toads_per_tick):
					_spawn_toad()

		# Cap total toad count by removing oldest
		var toad_count := _shared_toads_container.get_child_count()
		if toad_count > TOAD_MAX:
			_remove_oldest_toads(toad_count - TOAD_MAX)

	# If nobody is in the dimension, despawn all toads immediately
	if not anyone_inside and not _toads_despawning and _shared_toads_container and _shared_toads_container.get_child_count() > 0:
		_clear_all_toads()


func _process(_delta: float) -> void:
	## Client-side: swap environment when the local player enters/exits.
	_update_client_environment()


func _exit_player(peer_id: int) -> void:
	## Remove a single player from the toad dimension and return them.
	var data: PlayerToadData = _players.get(peer_id)
	if data == null:
		return

	_players.erase(peer_id)

	if is_instance_valid(data.player):
		data.player.reset_movement_states()
		data.player.in_toad_dimension = false

		# Restore original collision layers
		_restore_collision(data)

		# Re-enable VoxelViewer for terrain streaming
		_set_voxel_viewer_enabled(data.player, true)

		if data.player.is_alive:
			data.player.global_position = _get_safe_return_pos(data.saved_pos)
			data.player.velocity = Vector3.ZERO

	_on_exit_toad_dimension_player.rpc(peer_id)
	print("[ToadDimension] Player %d exited (%d players remain)" % [
		peer_id, _players.size()
	])


func _get_safe_return_pos(saved_pos: Vector3) -> Vector3:
	## Return the saved position, but if it's now underground (e.g. terrain
	## was cratered while in the toad dimension), move Y up to the surface.
	var seed_world := get_tree().current_scene.get_node_or_null("SeedWorld")
	if seed_world and seed_world.has_method("get_height_at"):
		var surface_y: float = seed_world.get_height_at(saved_pos.x, saved_pos.z)
		if saved_pos.y < surface_y:
			return Vector3(saved_pos.x, surface_y, saved_pos.z)
	return saved_pos


# ======================================================================
#  Collision layer isolation
# ======================================================================

func _apply_toad_collision(player: CharacterBody3D) -> void:
	## Swap the player's collision layers so they only interact with
	## toad arena geometry and other players — not overworld objects.
	player.collision_layer = TOAD_COLLISION_LAYER
	player.collision_mask = TOAD_COLLISION_MASK


func _restore_collision(data: PlayerToadData) -> void:
	## Restore the player's original collision layers.
	if is_instance_valid(data.player):
		data.player.collision_layer = data.saved_collision_layer
		data.player.collision_mask = data.saved_collision_mask


func _set_voxel_viewer_enabled(player: CharacterBody3D, enabled: bool) -> void:
	## Enable/disable the VoxelViewer child to prevent streaming at Y=-500.
	var viewer := player.get_node_or_null("VoxelViewer")
	if viewer:
		viewer.set_process(enabled)
		viewer.set_physics_process(enabled)
		if viewer.has_method("set_enabled"):
			viewer.set_enabled(enabled)


# ======================================================================
#  Client-side environment swap
# ======================================================================

func _update_client_environment() -> void:
	var local_player := _get_local_player()
	if local_player == null:
		if _is_showing_toad_env:
			_restore_overworld_env()
		return

	var should_show_toad: bool = local_player.get("in_toad_dimension") == true

	if should_show_toad and not _is_showing_toad_env:
		_apply_toad_env()
	elif not should_show_toad and _is_showing_toad_env:
		_restore_overworld_env()


func _apply_toad_env() -> void:
	var world_env := _find_world_environment()
	if world_env == null:
		return

	_overworld_env = world_env.environment

	if _toad_env == null:
		_toad_env = _create_toad_environment()

	world_env.environment = _toad_env
	_is_showing_toad_env = true


func _restore_overworld_env() -> void:
	if _overworld_env == null:
		_is_showing_toad_env = false
		return

	var world_env := _find_world_environment()
	if world_env:
		world_env.environment = _overworld_env

	_is_showing_toad_env = false


func _create_toad_environment() -> Environment:
	var env := Environment.new()

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.42, 0.44, 0.42)
	sky_mat.sky_horizon_color = Color(0.48, 0.50, 0.48)
	sky_mat.ground_bottom_color = Color(0.2, 0.2, 0.2)
	sky_mat.ground_horizon_color = Color(0.45, 0.47, 0.45)
	sky_mat.sky_curve = 0.05
	sky_mat.ground_curve = 0.02
	sky_mat.sky_energy_multiplier = 0.3

	var sky := Sky.new()
	sky.sky_material = sky_mat

	env.background_mode = Environment.BG_SKY
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.45, 0.38)
	env.ambient_light_energy = 1.0

	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.4
	env.tonemap_white = 1.0

	env.fog_enabled = true
	env.fog_light_color = Color(0.45, 0.47, 0.45)
	env.fog_density = 0.003
	env.fog_sky_affect = 0.8
	env.fog_height = DIMENSION_Y + 30
	env.fog_height_density = 0.005

	return env


func _find_world_environment() -> WorldEnvironment:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	for child in scene.get_children():
		if child is WorldEnvironment:
			return child
	var seed_world := scene.get_node_or_null("SeedWorld")
	if seed_world:
		for child in seed_world.get_children():
			if child is WorldEnvironment:
				return child
	return null


func _get_local_player() -> CharacterBody3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var players := scene.get_node_or_null("Players")
	if players == null:
		return null
	var local_id := multiplayer.get_unique_id()
	var player_node := players.get_node_or_null(str(local_id))
	if player_node is CharacterBody3D:
		return player_node
	return null


# ======================================================================
#  Toad spawning — RigidBody3D scene instances
# ======================================================================

func _spawn_toad() -> void:
	## Instantiate a toad_body.tscn and add it to the toads container.
	## Each toad is a full RigidBody3D with physics, collision, and visuals.
	## The toad body script handles bounce detection, floor pass-through,
	## and self-despawn automatically.
	if _toad_body_scene == null:
		_toad_body_scene = load("res://world/toad_body.tscn")

	var toad: RigidBody3D = _toad_body_scene.instantiate()

	# Random size (collision radius and visual scale)
	var body_scale: float = randf_range(0.2, 0.4)

	# Set collision shape radius to match visual scale
	var col_shape: CollisionShape3D = toad.get_node("CollisionShape3D")
	if col_shape and col_shape.shape is SphereShape3D:
		col_shape.shape = col_shape.shape.duplicate()
		col_shape.shape.radius = body_scale

	# Scale the body mesh (squished sphere — 0.65 height ratio like original)
	var body_mesh: MeshInstance3D = toad.get_node("Body")
	if body_mesh:
		body_mesh.scale = Vector3(body_scale, body_scale * 0.65, body_scale)

	# Position eyes and pupils relative to body size
	_setup_toad_eyes(toad, body_scale)

	# Random spawn position in rain area
	var rng_x: float = randf_range(-TOAD_RAIN_AREA, TOAD_RAIN_AREA)
	var rng_z: float = randf_range(-TOAD_RAIN_AREA, TOAD_RAIN_AREA)
	toad.position = _arena_center + Vector3(rng_x, CEILING_HEIGHT - 5.0 + randf() * 3.0, rng_z)

	# Give a small random angular velocity so they tumble
	toad.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))

	# Tell the toad body where the floor is for despawn detection
	toad._floor_y = DIMENSION_Y

	# Apply current toggle states before adding to scene
	if GameManager.debug_toad_no_physics:
		toad.start_physics_disabled()

	if GameManager.debug_toad_no_shadows:
		toad.set_shadows_enabled(false)

	_shared_toads_container.add_child(toad)


func _setup_toad_eyes(toad: RigidBody3D, radius: float) -> void:
	## Position and scale eye + pupil meshes relative to the toad body size.
	var eye_offset: float = radius * 0.55
	var eye_size: float = radius * 0.25
	var pupil_size: float = eye_size * 0.45

	var eye_l: MeshInstance3D = toad.get_node_or_null("EyeL")
	var eye_r: MeshInstance3D = toad.get_node_or_null("EyeR")
	var pupil_l: MeshInstance3D = toad.get_node_or_null("PupilL")
	var pupil_r: MeshInstance3D = toad.get_node_or_null("PupilR")

	if eye_l:
		eye_l.scale = Vector3(eye_size, eye_size * 0.75, eye_size)
		eye_l.position = Vector3(eye_offset * 0.7, radius * 0.5, -radius * 0.6)
	if eye_r:
		eye_r.scale = Vector3(eye_size, eye_size * 0.75, eye_size)
		eye_r.position = Vector3(-eye_offset * 0.7, radius * 0.5, -radius * 0.6)

	var pupil_z_offset: float = -eye_size * 0.4
	if pupil_l:
		pupil_l.scale = Vector3(pupil_size, pupil_size * 0.78, pupil_size)
		pupil_l.position = Vector3(eye_offset * 0.7, radius * 0.5, -radius * 0.6 + pupil_z_offset)
	if pupil_r:
		pupil_r.scale = Vector3(pupil_size, pupil_size * 0.78, pupil_size)
		pupil_r.position = Vector3(-eye_offset * 0.7, radius * 0.5, -radius * 0.6 + pupil_z_offset)


func _remove_oldest_toads(count: int) -> void:
	## Free the oldest `count` toad nodes from the container.
	var children := _shared_toads_container.get_children()
	var to_remove: int = mini(count, children.size())
	for i in range(to_remove):
		if is_instance_valid(children[i]):
			children[i].queue_free()


func _clear_all_toads() -> void:
	## Immediately free all toad bodies.
	if _shared_toads_container == null:
		return
	for child in _shared_toads_container.get_children():
		if is_instance_valid(child):
			child.queue_free()


# ======================================================================
#  Live toggle application (called from pause menu)
# ======================================================================

func apply_toad_physics_toggle(physics_enabled: bool) -> void:
	## Apply physics toggle to all existing toad bodies.
	if _shared_toads_container == null:
		return
	for child in _shared_toads_container.get_children():
		if not is_instance_valid(child) or not child is RigidBody3D:
			continue
		if physics_enabled:
			child.restore_physics()
		else:
			child.start_physics_disabled()


func apply_toad_shadow_toggle(shadows_enabled: bool) -> void:
	## Apply shadow toggle to all existing toad bodies.
	if _shared_toads_container == null:
		return
	for child in _shared_toads_container.get_children():
		if not is_instance_valid(child) or not child is RigidBody3D:
			continue
		child.set_shadows_enabled(shadows_enabled)


# ======================================================================
#  Scatter & despawn
# ======================================================================

func _scatter_and_despawn_toads() -> void:
	## Give all toads a random outward impulse, then clear after a delay.
	## Handles both live (pre-bounce) and frozen (post-bounce) toads.
	if _shared_toads_container == null or _shared_toads_container.get_child_count() == 0:
		return
	_toads_despawning = true

	# Apply scatter impulse to all living toads
	for child in _shared_toads_container.get_children():
		if not is_instance_valid(child) or not child is RigidBody3D:
			continue
		var scatter_dir := Vector3(
			randf_range(-1, 1), randf_range(0.3, 1.0), randf_range(-1, 1)
		).normalized()
		var scatter_angular := Vector3(
			randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8)
		)

		if child.freeze:
			# Post-bounce toad: already out of Jolt, set manual velocity directly
			child._manual_velocity = scatter_dir * TOAD_SCATTER_SPEED
			child._manual_angular_vel = scatter_angular
		else:
			# Pre-bounce toad: still in Jolt, use physics impulse
			child.apply_central_impulse(scatter_dir * TOAD_SCATTER_SPEED * child.mass)
			child.angular_velocity = scatter_angular

	# Despawn after brief scatter animation
	get_tree().create_timer(TOAD_DESPAWN_DELAY).timeout.connect(
		func() -> void:
			_clear_all_toads()
			_toads_despawning = false
	)


# ======================================================================
#  Arena construction (built once, shared by all sessions)
# ======================================================================

func _build_arena() -> void:
	_arena_node = Node3D.new()
	_arena_node.name = "ToadDimensionArena"
	get_tree().current_scene.add_child(_arena_node)

	_create_shared_materials()

	# --- Shared toad rain container ---
	_shared_toads_container = Node3D.new()
	_shared_toads_container.name = "SharedToadRain"
	_arena_node.add_child(_shared_toads_container)

	# --- Build arena geometry ---
	_build_floor()
	_build_ceiling()
	_build_cylindrical_barrier()
	_build_giant_toads()
	_build_arena_lighting()
	_spawn_ground_details()

	_arena_built = true
	print("[ToadDimension] Shared arena built at Y=%.0f (max_toads=%d)" % [DIMENSION_Y, TOAD_MAX])


func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "ToadFloor"
	floor_body.position = Vector3(0, DIMENSION_Y, 0)
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	_arena_node.add_child(floor_body)

	var floor_col := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(FLOOR_SIZE, 1.0, FLOOR_SIZE)
	floor_col.shape = floor_shape
	floor_col.position = Vector3(0, -0.5, 0)
	floor_body.add_child(floor_col)

	var floor_mesh := MeshInstance3D.new()
	var floor_box := BoxMesh.new()
	floor_box.size = Vector3(FLOOR_SIZE, 0.5, FLOOR_SIZE)
	floor_mesh.mesh = floor_box
	floor_mesh.position = Vector3(0, -0.25, 0)
	floor_mesh.material_override = _floor_mat
	floor_body.add_child(floor_mesh)


func _build_ceiling() -> void:
	var ceil_body := StaticBody3D.new()
	ceil_body.position = Vector3(0, DIMENSION_Y + CEILING_HEIGHT, 0)
	ceil_body.collision_layer = 1
	ceil_body.collision_mask = 0
	_arena_node.add_child(ceil_body)
	var ceil_col := CollisionShape3D.new()
	var ceil_shape := BoxShape3D.new()
	ceil_shape.size = Vector3(FLOOR_SIZE, 1.0, FLOOR_SIZE)
	ceil_col.shape = ceil_shape
	ceil_body.add_child(ceil_col)


func _build_cylindrical_barrier() -> void:
	var barrier_radius := 150.0
	var barrier_segments := 32  # Number of flat panels forming the cylinder
	var wall_h := CEILING_HEIGHT
	for i in barrier_segments:
		var angle: float = TAU * float(i) / float(barrier_segments)
		var next_angle: float = TAU * float(i + 1) / float(barrier_segments)
		var mid_angle: float = (angle + next_angle) * 0.5

		var wall := StaticBody3D.new()
		wall.collision_layer = 16  # Layer 5 — player collides but grapple ignores
		wall.collision_mask = 0
		var wall_x: float = cos(mid_angle) * barrier_radius
		var wall_z: float = sin(mid_angle) * barrier_radius
		wall.position = Vector3(wall_x, DIMENSION_Y + wall_h * 0.5, wall_z)
		wall.rotation.y = -mid_angle  # Face inward
		_arena_node.add_child(wall)

		# Panel width = chord length of one segment
		var panel_width: float = 2.0 * barrier_radius * sin(PI / barrier_segments)
		var wall_col := CollisionShape3D.new()
		var wall_shape := BoxShape3D.new()
		wall_shape.size = Vector3(panel_width, wall_h, 1.0)
		wall_col.shape = wall_shape
		wall.add_child(wall_col)


func _build_giant_toads() -> void:
	var toad_dirs: Array[Dictionary] = [
		{"offset": Vector3(0, 0, -1), "rot": 0.0},
		{"offset": Vector3(0, 0, 1), "rot": PI},
		{"offset": Vector3(-1, 0, 0), "rot": PI * 0.5},
		{"offset": Vector3(1, 0, 0), "rot": -PI * 0.5},
	]
	for td in toad_dirs:
		var dir_offset: Vector3 = td["offset"]
		var toad_pos := _arena_center + dir_offset * GIANT_TOAD_DISTANCE + Vector3(0, GIANT_TOAD_Y_OFFSET, 0)
		var giant := _create_giant_toad(toad_pos, td["rot"] as float)
		_arena_node.add_child(giant)

		var toad_light := OmniLight3D.new()
		toad_light.light_color = Color(0.2, 0.6, 0.15)
		toad_light.light_energy = 6.0
		toad_light.omni_range = 80.0
		toad_light.position = toad_pos + Vector3(0, 30, 0) + dir_offset * -20.0
		_arena_node.add_child(toad_light)


func _build_arena_lighting() -> void:
	var light1 := OmniLight3D.new()
	light1.light_color = Color(0.3, 0.8, 0.35)
	light1.light_energy = 4.0
	light1.omni_range = 80.0
	light1.position = _arena_center + Vector3(0, 15, 0)
	_arena_node.add_child(light1)

	var light2 := OmniLight3D.new()
	light2.light_color = Color(0.5, 0.55, 0.5)
	light2.light_energy = 3.0
	light2.omni_range = 100.0
	light2.position = _arena_center + Vector3(10, 10, -10)
	_arena_node.add_child(light2)


func _create_shared_materials() -> void:
	_floor_mat = StandardMaterial3D.new()
	_floor_mat.albedo_color = Color(0.12, 0.12, 0.12)
	_floor_mat.roughness = 0.95
	_floor_mat.metallic = 0.05


func _spawn_ground_details() -> void:
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.08, 0.08, 0.08)
	rock_mat.roughness = 1.0

	var bump_mat := StandardMaterial3D.new()
	bump_mat.albedo_color = Color(0.15, 0.16, 0.13)
	bump_mat.roughness = 0.9

	for i in range(60):
		var rock := MeshInstance3D.new()
		var rx := randf_range(-25, 25)
		var rz := randf_range(-25, 25)
		var scale_xz := randf_range(0.3, 1.5)
		var scale_y := randf_range(0.1, 0.5)

		var sphere := SphereMesh.new()
		sphere.radius = scale_xz * 0.5
		sphere.height = scale_y
		rock.mesh = sphere
		rock.position = _arena_center + Vector3(rx, -0.8 + scale_y * 0.3, rz)
		rock.material_override = rock_mat if randf() > 0.4 else bump_mat
		rock.rotation = Vector3(randf_range(-0.3, 0.3), randf_range(0, TAU), randf_range(-0.3, 0.3))
		_arena_node.add_child(rock)

	for i in range(8):
		var mound := MeshInstance3D.new()
		var mx := randf_range(-18, 18)
		var mz := randf_range(-18, 18)
		var sphere := SphereMesh.new()
		sphere.radius = randf_range(1.5, 3.0)
		sphere.height = randf_range(0.5, 1.2)
		mound.mesh = sphere
		mound.position = _arena_center + Vector3(mx, -0.5, mz)
		mound.material_override = bump_mat
		_arena_node.add_child(mound)


# ======================================================================
#  Giant toad
# ======================================================================

var _giant_toad_mesh: Mesh = null

func _create_giant_toad(center: Vector3, y_rotation: float = 0.0) -> Node3D:
	var toad := Node3D.new()
	toad.name = "GiantToad"
	toad.position = center

	if _giant_toad_mesh == null:
		_giant_toad_mesh = load("res://models/giant_toad.obj")

	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.08, 0.35, 0.05)
	body_mat.roughness = 0.85
	body_mat.metallic = 0.05
	body_mat.emission_enabled = true
	body_mat.emission = Color(0.06, 0.2, 0.03)
	body_mat.emission_energy_multiplier = 1.5
	body_mat.vertex_color_use_as_albedo = true

	if _giant_toad_mesh:
		var mesh_inst := MeshInstance3D.new()
		mesh_inst.mesh = _giant_toad_mesh
		mesh_inst.material_override = body_mat
		mesh_inst.scale = Vector3(60.0, 60.0, 60.0)
		mesh_inst.rotation.y = y_rotation
		toad.add_child(mesh_inst)
	else:
		push_warning("[ToadDimension] Could not load giant_toad.obj — using fallback sphere")
		var body := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 45.0
		sphere.height = 55.0
		body.mesh = sphere
		body.material_override = body_mat
		toad.add_child(body)

	return toad


# ======================================================================
#  Client-side notification RPCs
# ======================================================================

@rpc("authority", "call_remote", "reliable")
func _on_enter_toad_dimension(attacker_peer: int, victim_peer: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if local_id == attacker_peer or local_id == victim_peer:
		print("[ToadDimension] You have entered the Toad Dimension!")


@rpc("authority", "call_remote", "reliable")
func _on_exit_toad_dimension_player(peer_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if local_id == peer_id:
		print("[ToadDimension] You have returned from the Toad Dimension.")


# ======================================================================
#  Query helpers
# ======================================================================

func is_in_toad_dimension(player: CharacterBody3D) -> bool:
	return player.get("in_toad_dimension") == true


func find_player_anywhere(peer_id: int) -> CharacterBody3D:
	## Find a player node by peer_id. Players always remain in the
	## Players container (no reparenting), so this is a simple lookup.
	var scene := get_tree().current_scene
	if scene:
		var players := scene.get_node_or_null("Players")
		if players:
			var p: Node = players.get_node_or_null(str(peer_id))
			if p is CharacterBody3D:
				return p
	return null


func get_all_player_nodes() -> Array[CharacterBody3D]:
	## Returns all player nodes. Players always remain in the Players
	## container (no reparenting), so this iterates that container.
	var result: Array[CharacterBody3D] = []
	var scene := get_tree().current_scene
	if scene:
		var players := scene.get_node_or_null("Players")
		if players:
			for child in players.get_children():
				if child is CharacterBody3D:
					result.append(child)
	return result


# ======================================================================
#  Game reset (called by NetworkManager)
# ======================================================================

func reset() -> void:
	## Full cleanup: return all players to overworld, clear toads, reset state.
	for peer_id in _players.keys():
		var data: PlayerToadData = _players[peer_id]
		if is_instance_valid(data.player):
			data.player.in_toad_dimension = false
			_restore_collision(data)
			_set_voxel_viewer_enabled(data.player, true)

	_players.clear()
	_rain_duration = 0.0
	_toad_rain_timer = 0.0
	_toads_despawning = false

	_clear_all_toads()
	_restore_overworld_env()
