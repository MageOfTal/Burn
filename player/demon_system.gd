extends Node
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

# ======================================================================
#  Synced state (replicated via ServerSync)
# ======================================================================

var demon_active: bool = false
var demon_position: Vector3 = Vector3.ZERO
var demon_speed: float = DEMON_BASE_SPEED
var is_eliminated: bool = false

# ======================================================================
#  Server-only internal state
# ======================================================================

var _death_count: int = 0

# ======================================================================
#  Client-only visual state
# ======================================================================

var _demon_mesh: Node3D = null
var _warning_label: Label = null
var _game_over_overlay: Control = null
var _was_eliminated: bool = false  ## Track transition for game over overlay

# ======================================================================
#  Player reference
# ======================================================================

var player: CharacterBody3D


func setup(p: CharacterBody3D) -> void:
	player = p


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
	if not demon_active or is_eliminated:
		return

	# Don't check catch while player is dead (waiting to respawn)
	if not player.is_alive:
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

	# Broadcast elimination VFX
	_show_elimination.rpc(player.global_position)

	print("Player %d ELIMINATED by demon! (deaths: %d, final speed: %.1f)" % [
		player.peer_id, _death_count, demon_speed])


# ======================================================================
#  Client: demon visuals (LOCAL PLAYER ONLY)
# ======================================================================

func client_process_visuals(_delta: float) -> void:
	## Client-side: only the local player renders the demon.
	var is_local: bool = (player.peer_id == multiplayer.get_unique_id())
	if not is_local:
		return

	# Handle elimination transition
	if is_eliminated and not _was_eliminated:
		_was_eliminated = true
		_show_game_over_overlay()
		_cleanup_demon_mesh()
		_cleanup_warning_label()
		return
	if is_eliminated:
		return

	if not demon_active:
		_cleanup_demon_mesh()
		_cleanup_warning_label()
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

	# Proximity warning on HUD
	var dist: float = player.global_position.distance_to(demon_position)
	_update_warning_label(dist < DEMON_WARNING_DISTANCE, dist)


# ======================================================================
#  Client: demon mesh creation
# ======================================================================

func _create_demon_mesh() -> void:
	## Create demon visual using the demon.png sprite with particle trail and glow.
	_demon_mesh = Node3D.new()
	_demon_mesh.top_level = true

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

func _update_warning_label(show: bool, dist: float) -> void:
	## Update or create the proximity warning label.
	if show and _warning_label == null:
		_warning_label = Label.new()
		_warning_label.add_theme_font_size_override("font_size", 20)
		_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_warning_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_warning_label.offset_top = -60
		_warning_label.offset_bottom = -30
		_warning_label.offset_left = -200
		_warning_label.offset_right = 200
		var hud_layer := player.get_node_or_null("HUDLayer")
		if hud_layer:
			hud_layer.add_child(_warning_label)

	if _warning_label:
		_warning_label.visible = show
		if show:
			if dist < DEMON_CLOSE_WARNING:
				_warning_label.text = "THE DEMON IS NEAR... (%.0fm)" % dist
				_warning_label.add_theme_color_override("font_color", Color(1.0, 0.1, 0.0))
			else:
				_warning_label.text = "Demon approaching... (%.0fm)" % dist
				_warning_label.add_theme_color_override("font_color", Color(0.8, 0.3, 0.1))


func _cleanup_warning_label() -> void:
	if _warning_label and is_instance_valid(_warning_label):
		_warning_label.queue_free()
		_warning_label = null


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


# ======================================================================
#  RPCs — elimination VFX
# ======================================================================

@rpc("authority", "call_local", "reliable")
func _show_elimination(pos: Vector3) -> void:
	## Dark implosion VFX at elimination point (only local player sees it).
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
	scene_root.add_child(flash)
	flash.global_position = pos

	var tween := get_tree().create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 1.5)
	tween.tween_callback(flash.queue_free)
