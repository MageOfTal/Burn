extends PlayerSubsystem
class_name DemonSystem

## Demon Stalker subsystem — personal death punishment.
## Each player has their own demon that spawns on first death, is visible
## ONLY to them, and relentlessly chases them. The demon gets faster with
## each death. When it catches you, you are permanently eliminated.
##
## Server-authoritative: server tracks demon position and catch detection.
## Client-side: only the owning player renders the demon mesh and HUD warning.

# ======================================================================
#  Constants
# ======================================================================

const DEMON_BASE_SPEED := 3.0             ## Base speed (player walks at 7.0)
const DEMON_SPEED_PER_DEATH := 1.5        ## Additional speed per death
const DEMON_CATCH_RADIUS := 2.0           ## Distance to trigger elimination
const DEMON_SPAWN_HEIGHT := 1.0           ## Hover offset above player's Y
const DEMON_WARNING_DISTANCE := 30.0      ## Start showing proximity warning
const DEMON_CLOSE_WARNING := 10.0         ## Critical proximity threshold
const DEMON_VISUAL_SCALE_BASE := 1.0      ## Base visual scale
const DEMON_VISUAL_SCALE_PER_DEATH := 0.35  ## Gets noticeably bigger each death

## Catch animation timing
const CATCH_MIN_GRAB_PHASE := 0.3          ## Minimum time for arm to reach player (seconds)
const CATCH_ARM_REACH_RATE := 8.0          ## Arm travels this many meters per second (reach-up)
const CATCH_PULL_DURATION := 0.8           ## Time for the pull-down phase (after grab)
const CATCH_SINK_TOTAL := 3.5              ## Total distance player sinks (meters)

# ======================================================================
#  Synced state (replicated via ServerSync)
# ======================================================================

var demon_active: bool = false
var demon_position: Vector3 = Vector3.ZERO
var demon_speed: float = DEMON_BASE_SPEED
var is_eliminated: bool = false
var is_being_caught: bool = false          ## True during the 2s catch animation

# ======================================================================
#  Server-only internal state
# ======================================================================

var _death_count: int = 0
var _catch_anim_timer: float = 0.0         ## Tracks progress through catch animation
var _catch_grab_duration: float = 0.3      ## Computed grab phase duration (scales with height)
var _catch_total_duration: float = 2.0     ## Computed total animation duration

# ======================================================================
#  Client-only visual state
# ======================================================================

var _demon_mesh: Node3D = null
var _game_over_overlay: Control = null
var _was_eliminated: bool = false  ## Track transition for game over overlay

## 3D arrowhead that points toward demon when within 10m (local player only)
var _arrow_mesh: MeshInstance3D = null
var _arrow_spin: float = 0.0         ## Current spin angle (radians, accumulated)
var _arrow_flash_time: float = 0.0   ## Flash timer (accumulates, wraps)
const ARROW_SHOW_DISTANCE := 10.0    ## Edge-to-edge distance at which arrow appears
const ARROW_ORBIT_RADIUS := 1.2      ## Distance from player center the arrow floats
const ARROW_HEIGHT_OFFSET := 1.0     ## Y offset above player feet
const PLAYER_CAPSULE_RADIUS := 0.4   ## Player capsule radius for edge distance calc

func setup(p: Player) -> void:
	super.setup(p)


# ======================================================================
#  Server: debug spawn (for testing)
# ======================================================================

func debug_spawn_nearby() -> void:
	## Server-only: spawn demon ~20m away from player for testing.
	if not multiplayer.is_server():
		return
	var forward := -player.transform.basis.z
	demon_position = player.global_position + forward * 20.0 + Vector3(0, 2.0, 0)
	demon_speed = DEMON_BASE_SPEED
	_death_count = 0
	demon_active = true
	print("DEBUG: Demon spawned 20m from player %d at %s" % [player.peer_id, str(demon_position)])


# ======================================================================
#  Server: death handling
# ======================================================================

func on_player_death() -> void:
	## Server-only: increment death count, reposition demon, increase speed.
	if GameManager.debug_disable_demon:
		return
	_death_count += 1
	demon_speed = DEMON_BASE_SPEED + (_death_count * DEMON_SPEED_PER_DEATH)

	# Calculate opposite side of map from where player will respawn
	var map := get_tree().current_scene
	var spawn_container := map.get_node_or_null("PlayerSpawnPoints")
	if spawn_container == null or spawn_container.get_child_count() == 0:
		# Fallback: place demon far away
		demon_position = player.global_position + Vector3(100, DEMON_SPAWN_HEIGHT, 100)
	else:
		var spawns := spawn_container.get_children()
		# Pick where the player will respawn (same logic as _do_respawn)
		var respawn_point: Vector3 = spawns[randi() % spawns.size()].global_position

		# Approximate map center from all spawn points
		var map_center := Vector3.ZERO
		for sp in spawns:
			map_center += sp.global_position
		map_center /= spawns.size()

		# Place demon on the opposite side of map from respawn
		var respawn_to_center: Vector3 = map_center - respawn_point
		demon_position = respawn_point + respawn_to_center * 2.0
		demon_position.y = respawn_point.y + DEMON_SPAWN_HEIGHT

	if not demon_active:
		demon_active = true
		print("Player %d: Demon activated! (death #%d, speed: %.1f)" % [
			player.peer_id, _death_count, demon_speed])
	else:
		print("Player %d: Demon repositioned (death #%d, speed: %.1f)" % [
			player.peer_id, _death_count, demon_speed])


# ======================================================================
#  Server: demon movement and catch detection
# ======================================================================

func process(delta: float) -> void:
	## Server-only: move demon toward player, check catch distance.
	if GameManager.debug_disable_demon:
		if demon_active:
			demon_active = false
			print("Player %d: Demon removed (debug disabled)" % player.peer_id)
		return

	# Tick the catch animation if active (runs even when demon_active is false)
	if is_being_caught:
		_tick_catch_animation(delta)
		return

	if not demon_active or is_eliminated:
		return
	# Freeze demons after victory
	if GameManager.current_state == GameManager.GameState.GAME_OVER:
		return

	# Don't check catch while player is dead (waiting to respawn)
	if not player.is_alive:
		return

	# Freeze demon while player is in the toad dimension
	if player.in_toad_dimension:
		return

	# Move toward player in full 3D — demon must physically reach the player,
	# not just match their XZ position and float to their height
	var target_pos := player.global_position + Vector3(0, 1.0, 0)  # Aim at body center
	var to_player := target_pos - demon_position
	var dist := to_player.length()

	if dist > 0.1:
		var move_dir := to_player.normalized()
		demon_position += move_dir * demon_speed * delta

	# Catch check — full 3D distance so the demon can't kill through floors/ceilings
	var dist_3d: float = player.global_position.distance_to(demon_position)
	if dist_3d < DEMON_CATCH_RADIUS:
		_begin_catch_animation()


func _begin_catch_animation() -> void:
	## Server-only: start the dramatic catch sequence instead of instant elimination.
	is_being_caught = true
	_catch_anim_timer = 0.0
	demon_active = false
	player.velocity = Vector3.ZERO

	# Disable collision immediately — player is no longer a physical object
	player.get_node("CollisionShape3D").set_deferred("disabled", true)

	# End any active movement states
	if player.slide_crouch.is_sliding:
		player.slide_crouch.end_slide()
	if player.slide_crouch.is_crouching:
		player.slide_crouch.end_crouch()
	if player.kamikaze_system.is_active():
		player.kamikaze_system.reset_state()
	if player.grapple_system.is_active():
		player.grapple_system.reset_state()

	# Clear inventory and weapon — player is effectively dead
	if player.inventory:
		player.inventory.clear_all()
	player.clear_equipped_weapon()

	# Raycast straight down to find ground level for the arm origin
	var ground_y: float = player.global_position.y - 2.0  # Fallback: 2m below feet
	var space_state := player.get_world_3d().direct_space_state
	if space_state:
		var ray_from := player.global_position
		var ray_to := player.global_position - Vector3(0, 200.0, 0)
		var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		query.exclude = [player.get_rid()]
		query.collision_mask = 1  # World geometry only
		var result := space_state.intersect_ray(query)
		if not result.is_empty():
			ground_y = result.position.y

	# Compute animation timing based on arm length (higher = faster reach-up)
	var arm_length: float = maxf(player.global_position.y - ground_y, 2.0)
	_catch_grab_duration = maxf(arm_length / CATCH_ARM_REACH_RATE, CATCH_MIN_GRAB_PHASE)
	_catch_total_duration = _catch_grab_duration + CATCH_PULL_DURATION

	# Broadcast catch VFX to all clients (interpolated so VFX matches rendered body)
	_play_catch_animation.rpc(player.get_global_transform_interpolated().origin, ground_y, _catch_grab_duration, _catch_total_duration)

	print("Player %d: Demon catch animation started (deaths: %d, arm: %.1fm, grab: %.2fs, total: %.2fs)" % [
		player.peer_id, _death_count, arm_length, _catch_grab_duration, _catch_total_duration])


func _tick_catch_animation(delta: float) -> void:
	## Server-only: progress the catch animation — sink player underground.
	## Uses eased sinking: slow at first (the grab), then accelerating downward
	## like being yanked into the earth.
	var prev_timer := _catch_anim_timer
	_catch_anim_timer += delta

	# After the grab phase, sink using quintic ease-in (brief hesitation then violent yank)
	if _catch_anim_timer > _catch_grab_duration:
		var prev_t := clampf((prev_timer - _catch_grab_duration) / CATCH_PULL_DURATION, 0.0, 1.0)
		var curr_t := clampf((_catch_anim_timer - _catch_grab_duration) / CATCH_PULL_DURATION, 0.0, 1.0)
		# Quintic ease-in: ~0.2s of barely moving, then ripped underground
		var prev_eased := prev_t * prev_t * prev_t * prev_t * prev_t
		var curr_eased := curr_t * curr_t * curr_t * curr_t * curr_t
		var sink_delta := (curr_eased - prev_eased) * CATCH_SINK_TOTAL
		player.global_position.y -= sink_delta

	# Animation complete — finalize elimination
	if _catch_anim_timer >= _catch_total_duration:
		is_being_caught = false
		_eliminate_player()


func _eliminate_player() -> void:
	## Server-only: permanent elimination. Game over for this player.
	is_eliminated = true
	demon_active = false
	player.is_alive = false
	player.body_mesh.visible = false
	player.get_node("CollisionShape3D").set_deferred("disabled", true)

	# Clear inventory and weapon
	if player.inventory:
		player.inventory.clear_all()
	player.clear_equipped_weapon()

	# Broadcast elimination VFX (interpolated so VFX matches rendered body)
	_show_elimination.rpc(player.get_global_transform_interpolated().origin)

	print("Player %d ELIMINATED by demon! (deaths: %d, final speed: %.1f)" % [
		player.peer_id, _death_count, demon_speed])

	# Kill feed: red demon elimination message (use {P:id} placeholder)
	var net_mgr := player.get_node_or_null("/root/NetworkManager")
	if net_mgr and net_mgr.has_method("broadcast_kill_feed"):
		net_mgr.broadcast_kill_feed("[color=red]{P:%d} was caught by THE DEMON[/color]" % player.peer_id)

	# Check if only one player remains (victory condition)
	if net_mgr and net_mgr.has_method("check_victory"):
		net_mgr.check_victory()


# ======================================================================
#  Client: demon visuals (LOCAL PLAYER ONLY)
# ======================================================================

func client_process_visuals(delta: float) -> void:
	## Client-side: only the local player renders the demon.
	var is_local: bool = (player.peer_id == multiplayer.get_unique_id())
	if not is_local:
		return

	# Handle elimination transition
	if is_eliminated and not _was_eliminated:
		_was_eliminated = true
		_show_game_over_overlay()
		_cleanup_demon_mesh()
		_cleanup_arrow()
		return
	if is_eliminated:
		return

	if not demon_active or is_being_caught:
		_cleanup_demon_mesh()
		_cleanup_arrow()
		return

	# Create demon mesh if needed
	if _demon_mesh == null or not is_instance_valid(_demon_mesh):
		_create_demon_mesh()

	# Update position (sprite billboard auto-faces camera, no manual look_at needed)
	_demon_mesh.global_position = demon_position

	# Scale increases with speed (proxy for death count via synced demon_speed)
	var death_est: float = (demon_speed - DEMON_BASE_SPEED) / maxf(DEMON_SPEED_PER_DEATH, 0.01)
	var scale_val: float = DEMON_VISUAL_SCALE_BASE + (death_est * DEMON_VISUAL_SCALE_PER_DEATH)
	_demon_mesh.scale = Vector3(scale_val, scale_val, scale_val)

	# Use interpolated position so visuals match where the player is rendered
	var interp_pos: Vector3 = player.get_global_transform_interpolated().origin

	var center_dist: float = interp_pos.distance_to(demon_position)
	var edge_dist: float = maxf(center_dist - DEMON_CATCH_RADIUS - PLAYER_CAPSULE_RADIUS, 0.0)

	# 3D arrowhead pointing toward demon when within 10m edge-to-edge
	_update_demon_arrow(edge_dist, delta)


# ======================================================================
#  Client: demon mesh creation
# ======================================================================

func _create_demon_mesh() -> void:
	## Create demon visual using the demon.png sprite with particle trail and glow.
	_demon_mesh = Node3D.new()
	_demon_mesh.top_level = true
	_demon_mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	# --- Demon sprite: billboard that always faces the camera ---
	var sprite := Sprite3D.new()
	var tex := load("res://assets/textures/demon.png") as Texture2D
	if tex:
		sprite.texture = tex
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.transparent = true
	sprite.shaded = false
	sprite.no_depth_test = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.1
	# Scale the sprite to roughly 2m tall (adjust pixel_size based on image)
	sprite.pixel_size = 0.005
	sprite.position.y = 1.0
	sprite.modulate = Color(0.8, 0.7, 0.9, 0.9)  # Slight ghostly purple tint
	_demon_mesh.add_child(sprite)

	# --- Red particle trail ---
	var particles := GPUParticles3D.new()
	particles.emitting = true
	particles.amount = 20
	particles.lifetime = 1.0

	var part_mat := ParticleProcessMaterial.new()
	part_mat.direction = Vector3(0, -1, 0)
	part_mat.spread = 30.0
	part_mat.initial_velocity_min = 0.5
	part_mat.initial_velocity_max = 1.5
	part_mat.gravity = Vector3(0, -2, 0)
	part_mat.scale_min = 0.1
	part_mat.scale_max = 0.3

	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.8, 0.0, 0.0, 0.7))
	gradient.set_color(1, Color(0.3, 0.0, 0.0, 0.0))
	var grad_tex := GradientTexture1D.new()
	grad_tex.gradient = gradient
	part_mat.color_ramp = grad_tex
	particles.process_material = part_mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.2, 0.2)
	var draw_mat := StandardMaterial3D.new()
	draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	draw_mat.vertex_color_use_as_albedo = true
	quad.material = draw_mat
	particles.draw_pass_1 = quad
	particles.position.y = 0.5
	_demon_mesh.add_child(particles)

	# --- Eerie red glow ---
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.8, 0.0, 0.1)
	glow.light_energy = 3.0
	glow.omni_range = 5.0
	glow.position.y = 1.0
	_demon_mesh.add_child(glow)

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_demon_mesh)


# ======================================================================
#  Client: HUD warning label
# ======================================================================



# ======================================================================
#  Client: 3D arrowhead pointing toward demon
# ======================================================================

func _update_demon_arrow(edge_dist: float, delta: float) -> void:
	## Show/hide and position the 3D arrowhead that points toward the demon.
	## Only visible within ARROW_SHOW_DISTANCE (10m edge-to-edge).
	## Spins around its pointing axis and flashes (faster when closer).
	if edge_dist >= ARROW_SHOW_DISTANCE or not player.is_alive:
		_cleanup_arrow()
		return

	if _arrow_mesh == null or not is_instance_valid(_arrow_mesh):
		_create_arrow_mesh()

	# Direction from player to demon (XZ plane for horizontal pointing)
	var interp_pos: Vector3 = player.get_global_transform_interpolated().origin
	var to_demon: Vector3 = demon_position - interp_pos
	var to_demon_xz := Vector3(to_demon.x, 0.0, to_demon.z)
	if to_demon_xz.length() < 0.01:
		_arrow_mesh.visible = false
		return

	var dir_xz: Vector3 = to_demon_xz.normalized()

	# Proximity factor: 0 at 10m, 1 at 0m (touching)
	var proximity: float = clampf(1.0 - (edge_dist / ARROW_SHOW_DISTANCE), 0.0, 1.0)

	# Position the arrow orbiting around the player, toward the demon
	var arrow_pos: Vector3 = interp_pos + dir_xz * ARROW_ORBIT_RADIUS
	arrow_pos.y += ARROW_HEIGHT_OFFSET
	_arrow_mesh.global_position = arrow_pos

	# Point toward demon, then spin around the pointing axis
	var look_target: Vector3 = arrow_pos + dir_xz
	_arrow_mesh.look_at(look_target, Vector3.UP)
	# Spin: speed ramps from 2 rad/s at far edge to 12 rad/s when very close
	var spin_speed: float = lerpf(2.0, 12.0, proximity)
	_arrow_spin += spin_speed * delta
	# look_at resets rotation each frame, so apply total accumulated spin
	_arrow_mesh.rotate_object_local(Vector3(0.0, 0.0, -1.0), _arrow_spin)
	# Wrap to avoid float overflow over long sessions
	if _arrow_spin > TAU * 10.0:
		_arrow_spin = fmod(_arrow_spin, TAU)

	# Flash: oscillate alpha. Frequency ramps from 1.5 Hz at far edge to 6 Hz when close
	var flash_freq: float = lerpf(1.5, 6.0, proximity)
	_arrow_flash_time += delta * flash_freq
	var flash_wave: float = (sin(_arrow_flash_time * TAU) + 1.0) * 0.5  # 0..1
	var base_alpha: float = lerpf(0.15, 0.85, proximity)
	var alpha: float = lerpf(base_alpha * 0.3, base_alpha, flash_wave)

	var mat: StandardMaterial3D = _arrow_mesh.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = Color(1.0, 0.1, 0.05, alpha)
		var emission_strength: float = lerpf(0.3, 1.0, proximity) * lerpf(0.4, 1.0, flash_wave)
		mat.emission = Color(0.8, 0.0, 0.0) * emission_strength

	_arrow_mesh.visible = true


func _create_arrow_mesh() -> void:
	## Create a 3D arrowhead (chevron/pyramid pointing forward along -Z).
	## No tail — just a pointed triangular arrowhead.
	_arrow_mesh = MeshInstance3D.new()
	_arrow_mesh.top_level = true
	_arrow_mesh.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_arrow_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Build arrowhead geometry: a flat chevron (4 triangles forming a pointed shape)
	var mesh := ImmediateMesh.new()
	_arrow_mesh.mesh = mesh

	# Arrowhead dimensions
	var tip_z := -0.4     # Tip of the arrow (forward, pointing at demon)
	var back_z := 0.2     # Back of the arrowhead
	var notch_z := 0.05   # Inner notch (V shape at rear)
	var half_w := 0.25    # Half-width of the arrowhead wings
	var y := 0.0

	# Two triangles forming a chevron/arrowhead shape (double-sided)
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# Left wing (front face)
	mesh.surface_add_vertex(Vector3(0.0, y, tip_z))
	mesh.surface_add_vertex(Vector3(-half_w, y, back_z))
	mesh.surface_add_vertex(Vector3(0.0, y, notch_z))
	# Right wing (front face)
	mesh.surface_add_vertex(Vector3(0.0, y, tip_z))
	mesh.surface_add_vertex(Vector3(0.0, y, notch_z))
	mesh.surface_add_vertex(Vector3(half_w, y, back_z))
	# Left wing (back face — reverse winding for double-sided)
	mesh.surface_add_vertex(Vector3(0.0, y, tip_z))
	mesh.surface_add_vertex(Vector3(0.0, y, notch_z))
	mesh.surface_add_vertex(Vector3(-half_w, y, back_z))
	# Right wing (back face)
	mesh.surface_add_vertex(Vector3(0.0, y, tip_z))
	mesh.surface_add_vertex(Vector3(half_w, y, back_z))
	mesh.surface_add_vertex(Vector3(0.0, y, notch_z))
	mesh.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.1, 0.05, 0.7)
	mat.emission_enabled = true
	mat.emission = Color(0.8, 0.0, 0.0)
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	_arrow_mesh.material_override = mat

	var scene_root := get_tree().current_scene
	if scene_root:
		scene_root.add_child(_arrow_mesh)


func _cleanup_arrow() -> void:
	if _arrow_mesh and is_instance_valid(_arrow_mesh):
		_arrow_mesh.queue_free()
		_arrow_mesh = null
	_arrow_spin = 0.0
	_arrow_flash_time = 0.0


# ======================================================================
#  Client: game over overlay
# ======================================================================

func _show_game_over_overlay() -> void:
	## Display permanent elimination screen.
	if _game_over_overlay != null:
		return

	_game_over_overlay = ColorRect.new()
	_game_over_overlay.color = Color(0.3, 0.0, 0.0, 0.7)
	_game_over_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_over_overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	# Main message
	var msg := Label.new()
	msg.text = "THE DEMON CAUGHT YOU"
	msg.add_theme_font_size_override("font_size", 48)
	msg.add_theme_color_override("font_color", Color(1.0, 0.1, 0.0))
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	msg.set_anchors_preset(Control.PRESET_CENTER)
	msg.offset_left = -300
	msg.offset_right = 300
	msg.offset_top = -80
	msg.offset_bottom = -20
	_game_over_overlay.add_child(msg)

	# Sub message
	var sub_msg := Label.new()
	sub_msg.text = "You have been eliminated."
	sub_msg.add_theme_font_size_override("font_size", 20)
	sub_msg.add_theme_color_override("font_color", Color(0.8, 0.5, 0.4))
	sub_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub_msg.set_anchors_preset(Control.PRESET_CENTER)
	sub_msg.offset_left = -200
	sub_msg.offset_right = 200
	sub_msg.offset_top = 10
	sub_msg.offset_bottom = 50
	_game_over_overlay.add_child(sub_msg)

	var hud_layer := player.get_node_or_null("HUDLayer")
	if hud_layer:
		hud_layer.add_child(_game_over_overlay)


# ======================================================================
#  Cleanup helpers
# ======================================================================

func _cleanup_demon_mesh() -> void:
	if _demon_mesh and is_instance_valid(_demon_mesh):
		_demon_mesh.queue_free()
		_demon_mesh = null


func _exit_tree() -> void:
	## Clean up top-level nodes that survive player despawning (e.g. on game reset).
	_cleanup_demon_mesh()
	_cleanup_arrow()
	if _game_over_overlay and is_instance_valid(_game_over_overlay):
		_game_over_overlay.queue_free()
		_game_over_overlay = null


# ======================================================================
#  RPCs — catch animation & elimination VFX
# ======================================================================

@rpc("authority", "call_local", "reliable")
func _play_catch_animation(pos: Vector3, ground_y: float, grab_duration: float, total_duration: float) -> void:
	## Dramatic catch VFX: dark red fire plume + clawed arm shooting up from the
	## ground to grab the player, then pulling them underground.
	## Visible to ALL clients (everyone sees the catch happen).
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Arm length = distance from ground to player feet (minimum 2m so it's always visible)
	var arm_length: float = maxf(pos.y - ground_y, 2.0)

	# --- Container for all VFX (auto-cleanup) ---
	var vfx_root := Node3D.new()
	vfx_root.top_level = true
	vfx_root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	scene_root.add_child(vfx_root)
	# Anchor at ground level below the player
	vfx_root.global_position = Vector3(pos.x, ground_y, pos.z)

	# --- Dark red fire plume (erupts at player position) ---
	var fire := GPUParticles3D.new()
	fire.emitting = true
	fire.amount = 40
	fire.lifetime = 1.5
	fire.one_shot = false
	fire.explosiveness = 0.8
	fire.position.y = pos.y - ground_y  # Emit at player height

	var fire_mat := ParticleProcessMaterial.new()
	fire_mat.direction = Vector3(0, 1, 0)
	fire_mat.spread = 45.0
	fire_mat.initial_velocity_min = 3.0
	fire_mat.initial_velocity_max = 6.0
	fire_mat.gravity = Vector3(0, -1.5, 0)
	fire_mat.scale_min = 0.15
	fire_mat.scale_max = 0.5
	fire_mat.damping_min = 1.0
	fire_mat.damping_max = 2.0

	var fire_gradient := Gradient.new()
	fire_gradient.set_offset(0, 0.0)
	fire_gradient.set_color(0, Color(1.0, 0.3, 0.0, 0.9))
	fire_gradient.set_offset(1, 1.0)
	fire_gradient.set_color(1, Color(0.15, 0.0, 0.0, 0.0))
	fire_gradient.add_point(0.3, Color(0.7, 0.05, 0.0, 0.8))
	fire_gradient.add_point(0.7, Color(0.3, 0.0, 0.0, 0.5))
	var fire_grad_tex := GradientTexture1D.new()
	fire_grad_tex.gradient = fire_gradient
	fire_mat.color_ramp = fire_grad_tex
	fire.process_material = fire_mat

	var fire_quad := QuadMesh.new()
	fire_quad.size = Vector2(0.4, 0.4)
	var fire_draw_mat := StandardMaterial3D.new()
	fire_draw_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fire_draw_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire_draw_mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fire_draw_mat.vertex_color_use_as_albedo = true
	fire_quad.material = fire_draw_mat
	fire.draw_pass_1 = fire_quad
	vfx_root.add_child(fire)

	# --- Dark red glow light (at player height) ---
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.6, 0.0, 0.0)
	glow.light_energy = 15.0
	glow.omni_range = 10.0
	glow.position.y = pos.y - ground_y + 1.0
	vfx_root.add_child(glow)

	# --- Arm + claw shooting up from the ground ---
	var arm_assembly := _create_arm_and_claw(arm_length)
	arm_assembly.position.y = -1.0  # Start below ground surface
	vfx_root.add_child(arm_assembly)

	# --- Animate the sequence ---
	var pull_duration: float = total_duration - grab_duration

	# Phase 1: Arm shoots up from ground to grab position (speed scales with height)
	# Claw is at local y=arm_length inside the assembly. Player is at arm_length
	# above vfx_root. So assembly.y = 0 puts claw at player feet; -0.5 wraps torso.
	var tween := get_tree().create_tween()
	var grab_target_y: float = -0.5
	tween.tween_property(arm_assembly, "position:y", grab_target_y, grab_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	# Phase 2: Arm pulls player down — sink exactly CATCH_SINK_TOTAL to match server
	var pull_end_y: float = grab_target_y - CATCH_SINK_TOTAL
	tween.tween_property(arm_assembly, "position:y", pull_end_y, pull_duration).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUINT)

	# Fade out the glow over the full duration
	var glow_tween := get_tree().create_tween()
	glow_tween.tween_property(glow, "light_energy", 2.0, total_duration)
	glow_tween.tween_property(glow, "light_energy", 0.0, 0.5)

	# Stop fire emission partway through, let remaining particles expire
	var fire_tween := get_tree().create_tween()
	fire_tween.tween_interval(minf(grab_duration + 0.5, total_duration))
	fire_tween.tween_callback(func(): fire.emitting = false)

	# Clean up everything after animation + particle lifetime
	var cleanup_tween := get_tree().create_tween()
	cleanup_tween.tween_interval(total_duration + 1.5)
	cleanup_tween.tween_callback(vfx_root.queue_free)


func _create_arm_and_claw(arm_length: float) -> Node3D:
	## Build a long crooked arm with a grabbing claw at the top.
	## The arm extends vertically for arm_length meters, with slight crookedness.
	## At the top, 5 large fingers wrap around the player like gripping a handle.
	var root := Node3D.new()

	var arm_mat := StandardMaterial3D.new()
	arm_mat.albedo_color = Color(0.08, 0.03, 0.03, 1.0)
	arm_mat.emission_enabled = true
	arm_mat.emission = Color(0.35, 0.0, 0.0)
	arm_mat.emission_energy_multiplier = 2.0
	arm_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arm_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# --- Arm: segmented column with slight crooked wobble (single mesh) ---
	var arm_segments := int(maxf(arm_length / 0.8, 3))  # ~0.8m per segment
	var seg_height := arm_length / float(arm_segments)
	var arm_base_radius := 0.15
	var arm_top_radius := 0.2  # Slightly thicker at the wrist/hand junction

	var arm_mesh_inst := MeshInstance3D.new()
	arm_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var arm_im := ImmediateMesh.new()
	arm_mesh_inst.mesh = arm_im

	var hex_sides := 6
	arm_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, arm_mat)

	var prev_y := 0.0
	var prev_offset := Vector2.ZERO  # XZ wobble offset

	for seg in range(arm_segments):
		var seg_t := float(seg) / float(arm_segments)
		var next_t := float(seg + 1) / float(arm_segments)

		# Radius tapers slightly then widens at top (forearm shape)
		var r0 := lerpf(arm_base_radius, arm_base_radius * 0.85, sin(seg_t * PI))
		r0 = lerpf(r0, arm_top_radius, seg_t * seg_t)  # Widen toward top
		var r1 := lerpf(arm_base_radius, arm_base_radius * 0.85, sin(next_t * PI))
		r1 = lerpf(r1, arm_top_radius, next_t * next_t)

		# Crooked wobble: sinusoidal offset that gives it a bent, organic look
		var wobble_x := sin(seg_t * PI * 2.5 + 0.7) * 0.12
		var wobble_z := cos(seg_t * PI * 1.8 + 1.3) * 0.1
		var curr_offset := Vector2(wobble_x, wobble_z)

		var y0 := prev_y
		var y1 := y0 + seg_height
		var ox0 := prev_offset.x
		var oz0 := prev_offset.y
		var ox1 := curr_offset.x
		var oz1 := curr_offset.y

		for h in range(hex_sides):
			var a0 := float(h) / float(hex_sides) * TAU
			var a1 := float(h + 1) / float(hex_sides) * TAU
			var vb0 := Vector3(ox0 + cos(a0) * r0, y0, oz0 + sin(a0) * r0)
			var vb1 := Vector3(ox0 + cos(a1) * r0, y0, oz0 + sin(a1) * r0)
			var vt0 := Vector3(ox1 + cos(a0) * r1, y1, oz1 + sin(a0) * r1)
			var vt1 := Vector3(ox1 + cos(a1) * r1, y1, oz1 + sin(a1) * r1)
			_add_quad(arm_im, vb0, vb1, vt1, vt0)

		prev_y = y1
		prev_offset = curr_offset

	arm_im.surface_end()
	root.add_child(arm_mesh_inst)

	# --- Claw: 5 fingers at the top of the arm, wrapping around the player ---
	var claw := _create_claw_fingers(arm_mat)
	claw.position.y = arm_length
	claw.position.x = prev_offset.x
	claw.position.z = prev_offset.y
	root.add_child(claw)

	return root


func _create_claw_fingers(mat: StandardMaterial3D) -> Node3D:
	## Build 5 large fingers that wrap around the player like gripping a handle.
	## Fingers are placed in a 270-degree arc and curve inward sharply.
	var claw_root := Node3D.new()

	var finger_count := 5
	var arc_total := deg_to_rad(270.0)
	var arc_start := -arc_total * 0.5
	var palm_radius := 0.65  # Just outside the player capsule (0.4m radius)

	for i in range(finger_count):
		var t: float = float(i) / float(finger_count - 1)
		var angle: float = arc_start + arc_total * t

		var finger_root := Node3D.new()
		var dir := Vector3(sin(angle), 0.0, cos(angle))
		finger_root.position = dir * palm_radius
		finger_root.rotation.y = -angle

		# 4 segments that curve inward — wrapping around the player body
		var segments := 4
		var total_height := 1.4
		var seg_h := total_height / float(segments)
		var base_width := 0.12
		var tip_width := 0.04
		var base_depth := 0.08
		var tip_depth := 0.03

		var prev_bottom_y := 0.0
		var prev_inward_z := 0.0

		for seg in range(segments):
			var seg_t := float(seg) / float(segments)
			var next_seg_t := float(seg + 1) / float(segments)

			var w0 := lerpf(base_width, tip_width, seg_t) * 0.5
			var w1 := lerpf(base_width, tip_width, next_seg_t) * 0.5
			var d0 := lerpf(base_depth, tip_depth, seg_t) * 0.5
			var d1 := lerpf(base_depth, tip_depth, next_seg_t) * 0.5

			# Curve inward more aggressively at the top (quadratic)
			var curve := next_seg_t * next_seg_t * 0.5
			var y0 := prev_bottom_y
			var y1 := y0 + seg_h
			var z0 := prev_inward_z
			var z1 := z0 - curve * seg_h

			var seg_mesh := MeshInstance3D.new()
			seg_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var im := ImmediateMesh.new()
			seg_mesh.mesh = im

			var b0 := Vector3(-w0, y0, z0 - d0)
			var b1 := Vector3( w0, y0, z0 - d0)
			var b2 := Vector3( w0, y0, z0 + d0)
			var b3 := Vector3(-w0, y0, z0 + d0)
			var ct0 := Vector3(-w1, y1, z1 - d1)
			var ct1 := Vector3( w1, y1, z1 - d1)
			var ct2 := Vector3( w1, y1, z1 + d1)
			var ct3 := Vector3(-w1, y1, z1 + d1)

			im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
			_add_quad(im, b3, b2, ct2, ct3)
			_add_quad(im, b1, b0, ct0, ct1)
			_add_quad(im, b0, b3, ct3, ct0)
			_add_quad(im, b2, b1, ct1, ct2)
			_add_quad(im, ct3, ct2, ct1, ct0)
			_add_quad(im, b0, b1, b2, b3)
			im.surface_end()

			finger_root.add_child(seg_mesh)
			prev_bottom_y = y1
			prev_inward_z = z1

		claw_root.add_child(finger_root)

	return claw_root


func _add_quad(im: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	## Helper: add two triangles forming a quad (a-b-c, a-c-d).
	im.surface_add_vertex(a)
	im.surface_add_vertex(b)
	im.surface_add_vertex(c)
	im.surface_add_vertex(a)
	im.surface_add_vertex(c)
	im.surface_add_vertex(d)


@rpc("authority", "call_local", "reliable")
func _show_elimination(pos: Vector3) -> void:
	## Final elimination flash (only local player sees it — triggers game over overlay).
	var is_local: bool = (player.peer_id == multiplayer.get_unique_id())
	if not is_local:
		return

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	# Dark red flash
	var flash := OmniLight3D.new()
	flash.light_color = Color(0.5, 0.0, 0.0)
	flash.light_energy = 20.0
	flash.omni_range = 8.0
	flash.top_level = true
	flash.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	scene_root.add_child(flash)
	flash.global_position = pos

	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 1.5)
	tween.tween_callback(flash.queue_free)
