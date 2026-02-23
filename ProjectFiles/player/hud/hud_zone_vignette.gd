extends Control
class_name HUDZoneVignette

## Red haze overlay when the player is outside the fire circle.
## Intensity scales with distance from the zone edge — slight tint
## just outside, heavier haze when far out.

var _player: Player = null

var _haze: ColorRect = null
var _haze_material: ShaderMaterial = null

## How far outside the zone (in meters) to reach full haze intensity.
const MAX_DIST_FOR_FULL_HAZE := 40.0


func setup(player: Player) -> void:
	_player = player
	_build_haze()


func _build_haze() -> void:
	_haze = ColorRect.new()
	_haze.set_anchors_preset(Control.PRESET_FULL_RECT)
	_haze.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_haze.visible = false

	var shader := Shader.new()
	shader.code = """shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv_centered = UV - vec2(0.5);
	float dist = length(uv_centered) * 2.0;
	// Vignette: heavier at edges, lighter at center
	float edge = smoothstep(0.2, 1.4, dist);
	// Base haze covers the whole screen lightly
	float base_haze = 0.15;
	float alpha = (base_haze + edge * 0.55) * intensity;
	COLOR = vec4(0.75, 0.08, 0.0, alpha);
}
"""

	_haze_material = ShaderMaterial.new()
	_haze_material.shader = shader
	_haze_material.set_shader_parameter("intensity", 0.0)
	_haze.material = _haze_material

	add_child(_haze)
	move_child(_haze, 0)


func update_zone_vignette() -> void:
	if _haze == null or _haze_material == null or _player == null:
		return
	if not is_instance_valid(_player):
		return
	if not _player.is_alive:
		_haze.visible = false
		return

	var zm := _player.get_node_or_null("/root/ZoneManager")
	if zm == null or zm.zone_phase < 0:
		_haze.visible = false
		return

	var player_xz := Vector2(_player.global_position.x, _player.global_position.z)
	var dist_outside: float = player_xz.distance_to(zm.zone_center) - zm.zone_radius

	if dist_outside <= 0.0:
		_haze.visible = false
		return

	var t: float = clampf(dist_outside / MAX_DIST_FOR_FULL_HAZE, 0.0, 1.0)
	_haze_material.set_shader_parameter("intensity", t)
	_haze.visible = true
