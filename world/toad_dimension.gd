extends Node

## The Toad Dimension — a shared pocket arena far below the map.
## All players sent here occupy the SAME space — multiple pairs can fight
## simultaneously amid a shared downpour of toads.
##
## Visual design:
##   - Endless dark grey ground plane with scattered rocks/bumps
##   - Broad grey foggy skybox — whitewashed, eerie atmosphere
##   - Giant toad models looming in all 4 cardinal directions
##   - Massive toad rain shared across all active sessions
##
## Server-authoritative: only the server teleports players and manages sessions.

const DIMENSION_Y := -500.0        ## Base Y for the arena floor
const FLOOR_SIZE := 500.0          ## Massive floor to look endless
const CEILING_HEIGHT := 60.0       ## Invisible ceiling height
const SESSION_DURATION := 10.0     ## Seconds trapped in the dimension
const GIANT_TOAD_Y_OFFSET := 30.0  ## Raise toad so it sits on the floor
const GIANT_TOAD_DISTANCE := 350.0 ## Far enough players can't reach it
const TOAD_RAIN_INTERVAL := 0.03   ## Seconds between toad spawns (massive downpour)
const TOAD_RAIN_AREA := 35.0       ## Radius of toad rain spread
const TOADS_PER_TICK := 3          ## Toads spawned per rain tick
const TOAD_SCATTER_SPEED := 8.0    ## How fast toads scatter on landing
const TOAD_DESPAWN_DELAY := 3.0    ## Seconds after session ends before toads fade

## Fixed arena center — all sessions share the same space
var _arena_center := Vector3(0, DIMENSION_Y + 1.0, 0)

## Track active sessions: {session_id: SessionData}
var _sessions: Dictionary = {}
var _next_session_id: int = 0
var _arena_built: bool = false
var _arena_node: Node3D = null

## Shared materials (created once)
var _floor_mat: StandardMaterial3D = null
var _toad_body_mat: StandardMaterial3D = null
var _toad_eye_mat: StandardMaterial3D = null
var _toad_pupil_mat: StandardMaterial3D = null

## Client-side environment swap
var _toad_env: Environment = null
var _overworld_env: Environment = null
var _is_showing_toad_env: bool = false

## Shared toad rain container (toads pile up across all sessions)
var _shared_toads_container: Node3D = null
var _toad_rain_timer: float = 0.0
var _toads_despawning: bool = false  ## True while scatter/despawn is in progress


class SessionData:
	var session_id: int
	var attacker: CharacterBody3D
	var victim: CharacterBody3D
	var attacker_saved_pos: Vector3
	var victim_saved_pos: Vector3
	var timer: float
	var ended: bool = false


func enter(attacker: CharacterBody3D, victim: CharacterBody3D) -> void:
	## Server-only: begin a toad dimension session for two players.
	if not multiplayer.is_server():
		return

	# Don't toad someone already in the toad dimension
	if attacker.get("in_toad_dimension") or victim.get("in_toad_dimension"):
		return

	# Build shared arena infrastructure on first use
	if not _arena_built:
		_build_arena()

	var session := SessionData.new()
	session.session_id = _next_session_id
	_next_session_id += 1

	# Save positions
	session.attacker = attacker
	session.victim = victim
	session.attacker_saved_pos = attacker.global_position
	session.victim_saved_pos = victim.global_position
	session.timer = SESSION_DURATION

	# Cancel any active movement abilities before teleporting
	attacker.reset_movement_states()
	victim.reset_movement_states()

	# Teleport players — spread them out a bit so multiple pairs don't stack
	var pair_offset := Vector3(randf_range(-8, 8), 0, randf_range(-8, 8))
	attacker.in_toad_dimension = true
	victim.in_toad_dimension = true
	attacker.global_position = _arena_center + pair_offset + Vector3(-3, 0, 0)
	victim.global_position = _arena_center + pair_offset + Vector3(3, 0, 0)

	# Notify clients for VFX / environment swap
	_on_enter_toad_dimension.rpc(attacker.peer_id, victim.peer_id, session.session_id)

	_sessions[session.session_id] = session
	print("[ToadDimension] Session %d started: Player %d vs Player %d (%d active sessions)" % [
		session.session_id, attacker.peer_id, victim.peer_id, _sessions.size()
	])


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return

	var finished_sessions: Array[int] = []
	var any_active := false

	for session_id in _sessions:
		var session: SessionData = _sessions[session_id]

		if session.ended:
			finished_sessions.append(session_id)
			continue

		any_active = true
		session.timer -= delta

		# Check for dead players — if either died, end early
		var attacker_dead: bool = not is_instance_valid(session.attacker) or not session.attacker.is_alive
		var victim_dead: bool = not is_instance_valid(session.victim) or not session.victim.is_alive

		if session.timer <= 0.0 or attacker_dead or victim_dead:
			_end_session(session)

	for sid in finished_sessions:
		_sessions.erase(sid)

	# Shared toad rain — runs as long as ANY session is active
	if any_active and is_instance_valid(_shared_toads_container):
		_toad_rain_timer -= delta
		if _toad_rain_timer <= 0.0:
			_toad_rain_timer = TOAD_RAIN_INTERVAL
			for _i in range(TOADS_PER_TICK):
				_spawn_falling_toad()

		# Cap total toad count to prevent performance issues
		var toad_count := _shared_toads_container.get_child_count()
		if toad_count > 500:
			# Remove oldest toads
			for _i in range(toad_count - 500):
				var oldest := _shared_toads_container.get_child(0)
				oldest.queue_free()

	# If no sessions active, clear remaining rain toads immediately
	if not any_active and not _toads_despawning and is_instance_valid(_shared_toads_container):
		if _shared_toads_container.get_child_count() > 0:
			_scatter_and_despawn_toads()


func _process(_delta: float) -> void:
	## Client-side: swap environment when the local player enters/exits.
	_update_client_environment()


func _end_session(session: SessionData) -> void:
	session.ended = true

	# Cancel active abilities and teleport survivors back — place on terrain
	# surface so they don't end up underground if it was cratered.
	if is_instance_valid(session.attacker) and session.attacker.is_alive:
		session.attacker.reset_movement_states()
		session.attacker.in_toad_dimension = false
		session.attacker.global_position = _get_safe_return_pos(session.attacker_saved_pos)

	if is_instance_valid(session.victim) and session.victim.is_alive:
		session.victim.reset_movement_states()
		session.victim.in_toad_dimension = false
		session.victim.global_position = _get_safe_return_pos(session.victim_saved_pos)

	_on_exit_toad_dimension.rpc(
		session.attacker.peer_id if is_instance_valid(session.attacker) else -1,
		session.victim.peer_id if is_instance_valid(session.victim) else -1,
		session.session_id
	)
	print("[ToadDimension] Session %d ended (%d sessions remain)" % [
		session.session_id, _sessions.size() - 1
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


func _scatter_and_despawn_toads() -> void:
	## Scatter all rain toads outward then queue them for cleanup.
	## Great toads and the arena are NOT affected — they live in _arena_node, not here.
	if not is_instance_valid(_shared_toads_container):
		return
	_toads_despawning = true
	for child in _shared_toads_container.get_children():
		if child is RigidBody3D:
			var scatter_dir := Vector3(
				randf_range(-1, 1), randf_range(0.3, 1.0), randf_range(-1, 1)
			).normalized()
			child.apply_impulse(scatter_dir * TOAD_SCATTER_SPEED)
			child.angular_velocity = Vector3(
				randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8)
			)
	# Despawn after brief scatter animation
	get_tree().create_timer(TOAD_DESPAWN_DELAY).timeout.connect(
		func() -> void:
			if is_instance_valid(_shared_toads_container):
				for child in _shared_toads_container.get_children():
					child.queue_free()
			_toads_despawning = false
	)


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

	# --- Endless floor ---
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

	# --- Invisible ceiling ---
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

	# --- Invisible walls ---
	var wall_dist := 40.0
	var wall_h := CEILING_HEIGHT
	for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var wall := StaticBody3D.new()
		wall.collision_layer = 1
		wall.collision_mask = 0
		wall.position = Vector3(0, DIMENSION_Y + wall_h * 0.5, 0) + dir * wall_dist
		_arena_node.add_child(wall)

		var wall_col := CollisionShape3D.new()
		var wall_shape := BoxShape3D.new()
		if absf(dir.x) > 0:
			wall_shape.size = Vector3(1.0, wall_h, wall_dist * 2)
		else:
			wall_shape.size = Vector3(wall_dist * 2, wall_h, 1.0)
		wall_col.shape = wall_shape
		wall.add_child(wall_col)

	# --- Giant toads in all 4 cardinal directions ---
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

	# --- Arena lighting ---
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

	# --- Ground detail ---
	_spawn_ground_details()

	_arena_built = true
	print("[ToadDimension] Shared arena built at Y=%.0f" % DIMENSION_Y)


func _create_shared_materials() -> void:
	_floor_mat = StandardMaterial3D.new()
	_floor_mat.albedo_color = Color(0.12, 0.12, 0.12)
	_floor_mat.roughness = 0.95
	_floor_mat.metallic = 0.05

	_toad_body_mat = StandardMaterial3D.new()
	_toad_body_mat.albedo_color = Color(0.15, 0.55, 0.1)
	_toad_body_mat.roughness = 0.7

	_toad_eye_mat = StandardMaterial3D.new()
	_toad_eye_mat.albedo_color = Color(0.95, 0.95, 0.8)

	_toad_pupil_mat = StandardMaterial3D.new()
	_toad_pupil_mat.albedo_color = Color(0.05, 0.05, 0.0)


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
#  Toad spawning (shared rain)
# ======================================================================

func _spawn_falling_toad() -> void:
	var toad := RigidBody3D.new()
	toad.gravity_scale = 2.0
	toad.collision_layer = 0
	toad.collision_mask = 1
	toad.mass = 0.8
	toad.physics_material_override = _get_toad_physics_mat()

	var body_mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	var body_scale := randf_range(0.2, 0.4)
	sphere.radius = body_scale
	sphere.height = body_scale * 1.3
	body_mesh.mesh = sphere
	body_mesh.material_override = _toad_body_mat
	toad.add_child(body_mesh)

	var eye_offset := body_scale * 0.55
	var eye_size := body_scale * 0.25
	for eye_x in [-eye_offset, eye_offset]:
		var eye := MeshInstance3D.new()
		var eye_sphere := SphereMesh.new()
		eye_sphere.radius = eye_size
		eye_sphere.height = eye_size * 1.5
		eye.mesh = eye_sphere
		eye.position = Vector3(eye_x * 0.7, body_scale * 0.5, -body_scale * 0.6)
		eye.material_override = _toad_eye_mat
		toad.add_child(eye)

		var pupil := MeshInstance3D.new()
		var pupil_sphere := SphereMesh.new()
		pupil_sphere.radius = eye_size * 0.45
		pupil_sphere.height = eye_size * 0.7
		pupil.mesh = pupil_sphere
		pupil.position = eye.position + Vector3(0, 0, -eye_size * 0.4)
		pupil.material_override = _toad_pupil_mat
		toad.add_child(pupil)

	var col := CollisionShape3D.new()
	var col_shape := SphereShape3D.new()
	col_shape.radius = body_scale
	col.shape = col_shape
	toad.add_child(col)

	var rng_x := randf_range(-TOAD_RAIN_AREA, TOAD_RAIN_AREA)
	var rng_z := randf_range(-TOAD_RAIN_AREA, TOAD_RAIN_AREA)
	toad.position = _arena_center + Vector3(rng_x, CEILING_HEIGHT - 5.0 + randf() * 3.0, rng_z)

	toad.angular_velocity = Vector3(randf_range(-4, 4), randf_range(-4, 4), randf_range(-4, 4))

	_shared_toads_container.add_child(toad)


var _toad_phys_mat: PhysicsMaterial = null

func _get_toad_physics_mat() -> PhysicsMaterial:
	if _toad_phys_mat == null:
		_toad_phys_mat = PhysicsMaterial.new()
		_toad_phys_mat.bounce = 0.3
		_toad_phys_mat.friction = 0.6
	return _toad_phys_mat


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
func _on_enter_toad_dimension(attacker_peer: int, victim_peer: int, _session_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if local_id == attacker_peer or local_id == victim_peer:
		print("[ToadDimension] You have entered the Toad Dimension!")


@rpc("authority", "call_remote", "reliable")
func _on_exit_toad_dimension(attacker_peer: int, victim_peer: int, _session_id: int) -> void:
	var local_id := multiplayer.get_unique_id()
	if local_id == attacker_peer or local_id == victim_peer:
		print("[ToadDimension] You have returned from the Toad Dimension.")


# ======================================================================
#  Query helpers
# ======================================================================

func is_in_toad_dimension(player: CharacterBody3D) -> bool:
	return player.get("in_toad_dimension") == true
