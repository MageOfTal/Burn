extends CanvasLayer
## Lightweight profiler overlay. Toggle with F11.
## Shows frame time breakdown for all major systems.

var _visible := false
var _label: RichTextLabel
var _update_timer: float = 0.0
const UPDATE_INTERVAL := 0.25  # refresh 4x per second

# Timing accumulators (microseconds). Systems call Profiler.begin/end.
var _timers: Dictionary = {}      # name -> { total_us, count, worst_us }
var _frame_timers: Dictionary = {} # name -> start_usec (in-flight)

# Godot built-in stats cached per update
var _fps: float = 0.0
var _frame_time_ms: float = 0.0
var _physics_time_ms: float = 0.0
var _render_objects: int = 0
var _render_draw_calls: int = 0
var _render_primitives: int = 0
var _physics_active: int = 0
var _physics_pairs: int = 0


func _ready() -> void:
	layer = 101
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.position = Vector2(10, 10)
	_label.custom_minimum_size = Vector2(500, 0)
	_label.add_theme_font_size_override("normal_font_size", 13)
	_label.add_theme_font_size_override("mono_font_size", 13)
	_label.visible = false
	add_child(_label)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		_visible = not _visible
		_label.visible = _visible


func _process(delta: float) -> void:
	if not _visible:
		return
	_update_timer += delta
	if _update_timer < UPDATE_INTERVAL:
		return
	_update_timer = 0.0
	_refresh()


# ── Public API: systems call these ──────────────────────────────────

func begin(timer_name: String) -> void:
	if _frame_timers.has(timer_name):
		push_warning("Profiler.begin('%s') called twice without matching end() — first interval lost" % timer_name)
	_frame_timers[timer_name] = Time.get_ticks_usec()


func end(timer_name: String) -> void:
	if not _frame_timers.has(timer_name):
		push_warning("Profiler.end('%s') called without matching begin()" % timer_name)
		return
	var elapsed: int = Time.get_ticks_usec() - _frame_timers[timer_name]
	_frame_timers.erase(timer_name)
	if not _timers.has(timer_name):
		_timers[timer_name] = { "total_us": 0, "count": 0, "worst_us": 0 }
	var t: Dictionary = _timers[timer_name]
	t["total_us"] += elapsed
	t["count"] += 1
	if elapsed > t["worst_us"]:
		t["worst_us"] = elapsed


# ── Display ─────────────────────────────────────────────────────────

func _refresh() -> void:
	_fps = Performance.get_monitor(Performance.TIME_FPS)
	_frame_time_ms = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_physics_time_ms = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_render_objects = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_render_draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_render_primitives = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_physics_active = int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	_physics_pairs = int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))

	# GPU rendering breakdown
	var gpu_time_ms := Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0  # approximate
	var render_ms := _frame_time_ms - _physics_time_ms

	# RenderingServer stats
	var rs := RenderingServer
	var vram_tex := rs.get_rendering_info(rs.RENDERING_INFO_TEXTURE_MEM_USED) / (1024 * 1024)
	var vram_buf := rs.get_rendering_info(rs.RENDERING_INFO_BUFFER_MEM_USED) / (1024 * 1024)
	var vram_total := rs.get_rendering_info(rs.RENDERING_INFO_VIDEO_MEM_USED) / (1024 * 1024)

	var text := "[b]PROFILER (F11)[/b]\n"
	text += "[color=yellow]FPS: %.0f  Frame: %.1fms  Physics: %.1fms  Render: %.1fms[/color]\n" % [
		_fps, _frame_time_ms, _physics_time_ms, render_ms]
	text += "Draw calls: %d  Primitives: %dk  Objects: %d\n" % [
		_render_draw_calls, _render_primitives / 1000, _render_objects]
	text += "VRAM: %dMB (tex=%dMB buf=%dMB)\n" % [vram_total, vram_tex, vram_buf]
	text += "Physics bodies: %d  Pairs: %d\n" % [_physics_active, _physics_pairs]
	text += "\n[b]System Timings[/b] (avg / worst / calls)\n"

	# Sort by total time descending
	var sorted_names: Array = _timers.keys()
	sorted_names.sort_custom(func(a, b): return _timers[a]["total_us"] > _timers[b]["total_us"])

	for name in sorted_names:
		var t: Dictionary = _timers[name]
		if t["count"] == 0:
			continue
		var avg_us: float = float(t["total_us"]) / t["count"]
		var worst_us: int = t["worst_us"]
		var color := "green"
		if avg_us > 1000:
			color = "red"
		elif avg_us > 200:
			color = "orange"
		elif avg_us > 50:
			color = "yellow"
		text += "[color=%s]%s[/color]: %.0fus / %dus / %d\n" % [
			color, name, avg_us, worst_us, t["count"]]

	_label.text = text

	# Print to log for offline analysis
	var log_line := "[PROFILER] FPS=%.0f frame=%.1fms phys=%.1fms render=%.1fms draws=%d prims=%dk objs=%d vram=%dMB bodies=%d pairs=%d" % [
		_fps, _frame_time_ms, _physics_time_ms, render_ms, _render_draw_calls,
		_render_primitives / 1000, _render_objects, vram_total, _physics_active, _physics_pairs]
	for timer_name in sorted_names:
		var t: Dictionary = _timers[timer_name]
		if t["count"] == 0:
			continue
		var avg_us: float = float(t["total_us"]) / t["count"]
		log_line += " %s=%.0f/%dus" % [timer_name, avg_us, t["worst_us"]]
	print(log_line)

	# Reset for next interval
	_timers.clear()
