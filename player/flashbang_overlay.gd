extends ColorRect
class_name FlashbangOverlay

## Reusable screen overlay for flashbang effects.
## Lives on the player's HUDLayer. Created on first flash and reused.
## Stacking: takes max intensity (doesn't add).

var _flash_intensity: float = 0.0
var _flash_duration: float = 0.0
var _flash_timer: float = 0.0

## Ear ringing sound (2D so it plays at full volume regardless of position)
var _ring_player: AudioStreamPlayer = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color(1.0, 1.0, 1.0, 0.0)
	visible = false

	# Pre-load the ring sound
	_ring_player = AudioStreamPlayer.new()
	var ring_stream: AudioStream = load("res://assets/audio/sfx/ring.ogg")
	if ring_stream:
		_ring_player.stream = ring_stream
	_ring_player.volume_db = 0.0
	add_child(_ring_player)


func apply_flash(intensity: float, duration: float) -> void:
	## Apply a flash effect. Takes the max of current vs new intensity.
	if intensity <= _flash_intensity and _flash_timer > 0.0:
		return  # Current flash is stronger
	_flash_intensity = clampf(intensity, 0.0, 1.0)
	_flash_duration = duration
	_flash_timer = duration
	color.a = _flash_intensity
	visible = true

	# Play ear ringing sound scaled by intensity
	if _ring_player and _ring_player.stream:
		# Louder for stronger flashes: -20 dB at min intensity, 0 dB at full
		_ring_player.volume_db = lerpf(-20.0, 0.0, intensity)
		_ring_player.play()


func _process(delta: float) -> void:
	if _flash_timer <= 0.0:
		visible = false
		return

	_flash_timer -= delta
	if _flash_timer <= 0.0:
		_flash_timer = 0.0
		_flash_intensity = 0.0
		color.a = 0.0
		visible = false
		return

	# Fade out: alpha decreases linearly over duration
	var progress := _flash_timer / _flash_duration
	color.a = _flash_intensity * progress
