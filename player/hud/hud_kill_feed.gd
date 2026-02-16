extends Control
class_name HUDKillFeed

## Kill feed widget — scrolling event log on the left side of the screen.
## Entries appear at the top, fade out after a delay, and are capped at a max count.

const KILL_FEED_MAX := 6
const KILL_FEED_DISPLAY_TIME := 8.0
const KILL_FEED_FADE_TIME := 1.5

var _player: CharacterBody3D = null
var _kill_feed_container: VBoxContainer = null


func setup(player: CharacterBody3D) -> void:
	_player = player
	_build_kill_feed()


func _build_kill_feed() -> void:
	_kill_feed_container = VBoxContainer.new()
	_kill_feed_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_kill_feed_container.offset_left = 12.0
	_kill_feed_container.offset_top = 220.0
	_kill_feed_container.offset_right = 362.0
	_kill_feed_container.offset_bottom = 500.0
	_kill_feed_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_kill_feed_container)


func add_kill_feed_entry(bbcode_text: String) -> void:
	## Add a new entry to the kill feed. Called by NetworkManager RPC.
	if _kill_feed_container == null:
		return

	# Resolve player name placeholders ({P:peer_id}) to actual names.
	var display_text := bbcode_text
	if _player:
		var my_id: int = _player.peer_id
		var regex := RegEx.new()
		regex.compile("\\{P:(\\d+)\\}")
		var result := regex.search(display_text)
		while result:
			var pid := int(result.get_string(1))
			var pname := GameManager.get_username(pid)
			var replacement: String
			if pid == my_id:
				replacement = "[color=yellow]%s[/color]" % pname
			else:
				replacement = pname
			display_text = display_text.substr(0, result.get_start()) + replacement + display_text.substr(result.get_end())
			result = regex.search(display_text, result.get_start() + replacement.length())

	var entry := RichTextLabel.new()
	entry.bbcode_enabled = true
	entry.fit_content = true
	entry.scroll_active = false
	entry.text = display_text
	entry.add_theme_font_size_override("normal_font_size", 13)
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entry.custom_minimum_size = Vector2(350, 0)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.4)
	style.content_margin_left = 4.0
	style.content_margin_right = 4.0
	style.content_margin_top = 2.0
	style.content_margin_bottom = 2.0
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	entry.add_theme_stylebox_override("normal", style)

	# Insert at top (index 0)
	_kill_feed_container.add_child(entry)
	_kill_feed_container.move_child(entry, 0)

	# Remove oldest if over limit
	while _kill_feed_container.get_child_count() > KILL_FEED_MAX:
		var oldest := _kill_feed_container.get_child(_kill_feed_container.get_child_count() - 1)
		_kill_feed_container.remove_child(oldest)
		oldest.queue_free()

	# Auto-fade after display time
	var tween := create_tween()
	tween.tween_interval(KILL_FEED_DISPLAY_TIME)
	tween.tween_property(entry, "modulate:a", 0.0, KILL_FEED_FADE_TIME)
	tween.tween_callback(entry.queue_free)
