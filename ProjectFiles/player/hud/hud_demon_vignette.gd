extends Control
class_name HUDDemonVignette

## Demon proximity red vignette — full-screen shader overlay that intensifies
## as the player's demon gets closer (within 10m edge-to-edge).

var _player: Player = null

var _vignette: ColorRect = null
var _vignette_material: ShaderMaterial = null


func setup(player: Player) -> void:
	_player = player
	_build_vignette()


func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.visible = false

	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\n\nuniform float intensity : hint_range(0.0, 1.0) = 0.0;\n\nvoid fragment() {\n\tvec2 uv_centered = UV - vec2(0.5);\n\tfloat dist = length(uv_centered) * 2.0;\n\tfloat vignette = smoothstep(0.3, 1.2, dist);\n\tfloat alpha = vignette * intensity * 0.7;\n\tCOLOR = vec4(0.8, 0.0, 0.0, alpha);\n}\n"

	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = shader
	_vignette_material.set_shader_parameter("intensity", 0.0)
	_vignette.material = _vignette_material

	# Add as first child so it renders behind other HUD elements in this widget
	add_child(_vignette)
	move_child(_vignette, 0)


func update_demon_vignette() -> void:
	if _vignette == null or _vignette_material == null or _player == null:
		return
	if not is_instance_valid(_player):
		return

	var demon_sys: DemonSystem = _player.get_node_or_null("DemonSystem") as DemonSystem
	if demon_sys == null or not is_instance_valid(demon_sys) or not demon_sys.demon_active or demon_sys.is_eliminated:
		_vignette.visible = false
		return

	if not _player.is_alive:
		_vignette.visible = false
		return

	var center_dist: float = _player.global_position.distance_to(demon_sys.demon_position)
	var edge_dist: float = maxf(center_dist - DemonSystem.DEMON_CATCH_RADIUS - 0.4, 0.0)

	var threshold := 10.0

	if edge_dist >= threshold:
		_vignette.visible = false
		return

	var vignette_intensity: float = clampf(1.0 - (edge_dist / threshold), 0.0, 1.0)
	_vignette_material.set_shader_parameter("intensity", vignette_intensity)
	_vignette.visible = true
