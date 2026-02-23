extends Control
class_name HUDPerfGraph

## Rolling FPS + TPS performance graph drawn with _draw() / draw_polyline().
## Green line = render FPS, cyan line = physics TPS.
## One sample pushed per render frame from player_hud.gd.
##
## Ring buffer stores HISTORY samples (~3.3 s at 60 FPS).
## Y axis auto-scales to the nearest multiple of 30 above the peak value.

const GRAPH_W := 220.0
const GRAPH_H := 80.0
const HISTORY := 200

const BG_COLOR := Color(0.0, 0.0, 0.0, 0.45)
const FPS_COLOR := Color(0.4, 1.0, 0.4, 0.9)   ## Green
const TPS_COLOR := Color(0.4, 0.8, 1.0, 0.9)   ## Cyan
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const LABEL_COLOR := Color(0.7, 0.7, 0.7, 0.5)
const LINE_W := 1.5

var _fps_buf := PackedFloat32Array()
var _tps_buf := PackedFloat32Array()
var _wr: int = 0          ## Write index into ring buffer
var _count: int = 0       ## Samples stored so far (up to HISTORY)
var _y_max: float = 120.0 ## Dynamic ceiling


func _ready() -> void:
	_fps_buf.resize(HISTORY)
	_tps_buf.resize(HISTORY)
	custom_minimum_size = Vector2(GRAPH_W, GRAPH_H)
	size = Vector2(GRAPH_W, GRAPH_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push_sample(fps: float, tps: float) -> void:
	_fps_buf[_wr] = fps
	_tps_buf[_wr] = tps
	_wr = (_wr + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)

	# Recompute Y ceiling from entire buffer (200 floats — trivial cost).
	var peak := 0.0
	for i in HISTORY:
		peak = maxf(peak, maxf(_fps_buf[i], _tps_buf[i]))
	# Round up to nearest 30, minimum 60.
	_y_max = maxf(60.0, ceilf(peak / 30.0) * 30.0)

	queue_redraw()


func _draw() -> void:
	if _count < 2:
		return

	var font: Font = ThemeDB.fallback_font

	# ---- Background ----
	draw_rect(Rect2(Vector2.ZERO, Vector2(GRAPH_W, GRAPH_H)), BG_COLOR)

	# ---- Horizontal grid lines at every 30 units ----
	var v := 30.0
	while v < _y_max:
		var py: float = GRAPH_H - (v / _y_max) * GRAPH_H
		draw_line(Vector2(0.0, py), Vector2(GRAPH_W, py), GRID_COLOR)
		draw_string(font, Vector2(2.0, py - 2.0), str(int(v)),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 8, LABEL_COLOR)
		v += 30.0

	# Y-max label at top edge
	draw_string(font, Vector2(2.0, 9.0), str(int(_y_max)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 8, LABEL_COLOR)

	# ---- Build polylines (oldest → newest, right-aligned) ----
	var fps_pts := PackedVector2Array()
	var tps_pts := PackedVector2Array()
	fps_pts.resize(_count)
	tps_pts.resize(_count)

	var dx: float = GRAPH_W / float(HISTORY - 1)
	for i in _count:
		var buf_i: int
		if _count < HISTORY:
			buf_i = i
		else:
			buf_i = (_wr + i) % HISTORY

		var x: float = float(HISTORY - _count + i) * dx
		var fy: float = GRAPH_H - clampf(_fps_buf[buf_i] / _y_max, 0.0, 1.0) * GRAPH_H
		var ty: float = GRAPH_H - clampf(_tps_buf[buf_i] / _y_max, 0.0, 1.0) * GRAPH_H
		fps_pts[i] = Vector2(x, fy)
		tps_pts[i] = Vector2(x, ty)

	# TPS drawn first so FPS line renders on top.
	draw_polyline(tps_pts, TPS_COLOR, LINE_W, true)
	draw_polyline(fps_pts, FPS_COLOR, LINE_W, true)

	# ---- Legend (top-right) ----
	draw_string(font, Vector2(GRAPH_W - 60.0, 10.0), "FPS",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, FPS_COLOR)
	draw_string(font, Vector2(GRAPH_W - 28.0, 10.0), "TPS",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, TPS_COLOR)
