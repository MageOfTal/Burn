extends Control
class_name HUDYGraph

## Tall graph showing the player's Y position over time with auto-scaling axes.

const LABEL_W := 44.0
const PLOT_W := 120.0
const PLOT_H := 280.0
const TITLE_H := 12.0
const TOTAL_W := 164.0  # LABEL_W + PLOT_W
const TOTAL_H := 292.0  # TITLE_H + PLOT_H
const HISTORY := 300

const BG_COLOR := Color(0.0, 0.0, 0.0, 0.45)
const LINE_COL := Color(1.0, 0.85, 0.2, 0.9)
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.08)
const LABEL_COLOR := Color(0.8, 0.8, 0.8, 0.9)
const LINE_THICK := 1.5

var _buf := PackedFloat32Array()
var _wr: int = 0
var _count: int = 0
var _y_min: float = 0.0
var _y_max: float = 1.0


func _ready() -> void:
	_buf.resize(HISTORY)
	custom_minimum_size = Vector2(TOTAL_W, TOTAL_H)
	size = Vector2(TOTAL_W, TOTAL_H)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push_sample(y_pos: float) -> void:
	_buf[_wr] = y_pos
	_wr = (_wr + 1) % HISTORY
	_count = mini(_count + 1, HISTORY)

	var lo := _buf[0]
	var hi := lo
	for i in _count:
		lo = minf(lo, _buf[i])
		hi = maxf(hi, _buf[i])

	# Pad range by 5% each side so the line doesn't hug the edges
	var span := hi - lo
	if span < 0.01:
		span = 0.01
	var pad := span * 0.05
	_y_min = lo - pad
	_y_max = hi + pad

	queue_redraw()


func _draw() -> void:
	if _count < 2:
		return
	var font: Font = ThemeDB.fallback_font
	var px := LABEL_W
	var py := TITLE_H

	# Title
	draw_string(font, Vector2(px + 2.0, 9.0), "Player Y",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 9, LINE_COL)

	# Background
	draw_rect(Rect2(Vector2(px, py), Vector2(PLOT_W, PLOT_H)), BG_COLOR)

	# Grid lines + labels — 6 evenly spaced
	var span := _y_max - _y_min
	var num_lines := 6
	for j in num_lines:
		var frac := float(j) / float(num_lines - 1)
		var val := _y_min + frac * span
		var gy := py + PLOT_H - frac * PLOT_H
		draw_line(Vector2(px, gy), Vector2(px + PLOT_W, gy), GRID_COLOR)
		draw_string(font, Vector2(0.0, gy + 3.0), "%.2f" % val,
					HORIZONTAL_ALIGNMENT_RIGHT, int(LABEL_W - 2.0), 7, LABEL_COLOR)

	# Polyline
	var pts := PackedVector2Array()
	pts.resize(_count)
	var dx := PLOT_W / float(HISTORY - 1)
	for i in _count:
		var buf_i: int
		if _count < HISTORY:
			buf_i = i
		else:
			buf_i = (_wr + i) % HISTORY
		var x := px + float(HISTORY - _count + i) * dx
		var y := py + PLOT_H - clampf((_buf[buf_i] - _y_min) / (_y_max - _y_min), 0.0, 1.0) * PLOT_H
		pts[i] = Vector2(x, y)
	draw_polyline(pts, LINE_COL, LINE_THICK, true)
