extends Control
class_name HUDPerfGraph

## 2x2 grid of performance graphs, one per metric.
## Top-left: FPS (green), Top-right: TPS (cyan).
## Bottom-left: Tick ms (pink), Bottom-right: Frame ms (purple).
## Each graph has its own auto-scaled Y axis with exactly 4 evenly-spaced labels.
## Y ceilings snap to "nice" values so all 4 labels are clean integers.

const LABEL_W := 26.0    ## Left margin per cell for Y-axis labels
const CELL_PW := 104.0   ## Plot width per cell
const CELL_PH := 44.0    ## Plot height per cell
const TITLE_H := 12.0    ## Space above plot for title text
const GAP_X := 8.0       ## Horizontal gap between columns
const GAP_Y := 6.0       ## Vertical gap between rows
const HISTORY := 200
const CELL_W := 130.0    # LABEL_W + CELL_PW
const CELL_H := 56.0     # TITLE_H + CELL_PH
const TOTAL_W := 268.0   # CELL_W + GAP_X + CELL_W
const TOTAL_H := 118.0   # CELL_H + GAP_Y + CELL_H

## Ceilings that divide evenly into 4 clean integer labels.
const NICE_CEILINGS := [4.0, 8.0, 12.0, 16.0, 20.0, 40.0, 60.0, 80.0, 100.0,
	120.0, 160.0, 200.0, 400.0, 600.0, 800.0, 1000.0, 2000.0, 4000.0]

const BG_COLOR := Color(0.0, 0.0, 0.0, 0.45)
const FPS_COLOR := Color(0.4, 1.0, 0.4, 0.9)
const TPS_COLOR := Color(0.4, 0.8, 1.0, 0.9)
const TICK_COLOR := Color(1.0, 0.4, 0.7, 0.9)
const FRAME_COLOR := Color(0.6, 0.3, 1.0, 0.9)
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const LABEL_COLOR := Color(0.8, 0.8, 0.8, 0.9)
const LINE_W := 1.5

var _fps_buf := PackedFloat32Array()
var _tps_buf := PackedFloat32Array()
var _tick_buf := PackedFloat32Array()
var _frame_buf := PackedFloat32Array()
var _wr: int = 0
var _count: int = 0
var _y_max_fps: float = 60.0
var _y_max_tps: float = 60.0
var _y_max_tick: float = 4.0
var _y_max_frame: float = 4.0


func _ready() -> void:
	_fps_buf.resize(HISTORY)
	_tps_buf.resize(HISTORY)
	_tick_buf.resize(HISTORY)
	_frame_buf.resize(HISTORY)
	custom_minimum_size = Vector2(TOTAL_W, TOTAL_H)
	size = Vector2(TOTAL_W, TOTAL_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _nice_ceiling(peak: float, min_val: float) -> float:
	var val := maxf(peak, min_val)
	for c in NICE_CEILINGS:
		if c >= val:
			return c
	return ceilf(val / 4.0) * 4.0


func push_sample(fps: float, tps: float, tick_ms: float = 0.0, frame_ms: float = 0.0) -> void:
	_fps_buf[_wr] = fps
	_tps_buf[_wr] = tps
	_tick_buf[_wr] = tick_ms
	_frame_buf[_wr] = frame_ms
	_wr = (_wr + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)

	var peak_fps := 0.0
	var peak_tps := 0.0
	var peak_tick := 0.0
	var peak_frame := 0.0
	for i in HISTORY:
		peak_fps = maxf(peak_fps, _fps_buf[i])
		peak_tps = maxf(peak_tps, _tps_buf[i])
		peak_tick = maxf(peak_tick, _tick_buf[i])
		peak_frame = maxf(peak_frame, _frame_buf[i])
	_y_max_fps = _nice_ceiling(peak_fps, 60.0)
	_y_max_tps = _nice_ceiling(peak_tps, 60.0)
	_y_max_tick = _nice_ceiling(peak_tick, 4.0)
	_y_max_frame = _nice_ceiling(peak_frame, 4.0)

	queue_redraw()


func _draw_sub_graph(font: Font, ox: float, oy: float, buf: PackedFloat32Array,
					 y_max: float, color: Color, title: String) -> void:
	var px := ox + LABEL_W
	var py := oy + TITLE_H

	# Title (metric name in line color)
	draw_string(font, Vector2(px + 2.0, oy + 9.0), title,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color)

	# Background
	draw_rect(Rect2(Vector2(px, py), Vector2(CELL_PW, CELL_PH)), BG_COLOR)

	# 4 grid lines + labels at 25%, 50%, 75%, 100% of y_max
	var step := y_max / 4.0
	for j in 4:
		var val := step * float(j + 1)
		var gy := py + CELL_PH - (val / y_max) * CELL_PH
		draw_line(Vector2(px, gy), Vector2(px + CELL_PW, gy), GRID_COLOR)
		draw_string(font, Vector2(ox, gy + 3.0), "%d" % int(val),
					HORIZONTAL_ALIGNMENT_RIGHT, int(LABEL_W - 2.0), 7, LABEL_COLOR)

	# Polyline
	var pts := PackedVector2Array()
	pts.resize(_count)
	var dx := CELL_PW / float(HISTORY - 1)
	for i in _count:
		var buf_i: int
		if _count < HISTORY:
			buf_i = i
		else:
			buf_i = (_wr + i) % HISTORY
		var x := px + float(HISTORY - _count + i) * dx
		var y := py + CELL_PH - clampf(buf[buf_i] / y_max, 0.0, 1.0) * CELL_PH
		pts[i] = Vector2(x, y)
	draw_polyline(pts, color, LINE_W, true)


func _draw() -> void:
	if _count < 2:
		return
	var font: Font = ThemeDB.fallback_font
	# Top row
	_draw_sub_graph(font, 0.0, 0.0, _fps_buf, _y_max_fps, FPS_COLOR, "FPS")
	_draw_sub_graph(font, CELL_W + GAP_X, 0.0, _tps_buf, _y_max_tps, TPS_COLOR, "TPS")
	# Bottom row
	_draw_sub_graph(font, 0.0, CELL_H + GAP_Y, _tick_buf, _y_max_tick, TICK_COLOR, "Tick ms")
	_draw_sub_graph(font, CELL_W + GAP_X, CELL_H + GAP_Y, _frame_buf, _y_max_frame, FRAME_COLOR, "Frame ms")
