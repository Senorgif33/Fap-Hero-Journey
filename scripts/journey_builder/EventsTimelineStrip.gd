class_name EventsTimelineStrip
extends Control

## Phase-1 round events timeline: a duration bar with start markers (+ optional duration width).
## Pure view — no journey mutation. Click a marker to select; parent edits TimeMs elsewhere.

signal event_selected(index: int)

const BAR_H: float = 18.0
const MARKER_W: float = 3.0
const PAD_X: float = 4.0

var length_ms: int = 0
var events: Array = []  # runtime snake_case dicts for one round, display order
var selected_index: int = -1


func _ready() -> void:
	custom_minimum_size = Vector2(0, 36)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "Event markers on this round's clock. Click a marker to select."


func set_data(p_length_ms: int, p_events: Array, p_selected: int = -1) -> void:
	length_ms = maxi(0, p_length_ms)
	events = p_events
	selected_index = p_selected
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 8.0:
		return
	var bar_y: float = (h - BAR_H) * 0.5
	var bar_w: float = maxf(1.0, w - PAD_X * 2.0)
	var bar_rect := Rect2(PAD_X, bar_y, bar_w, BAR_H)
	draw_rect(bar_rect, Color(0.12, 0.09, 0.18, 0.95), true)
	draw_rect(bar_rect, Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.55), false, 1.0)

	if length_ms <= 0:
		# No clock yet — still show an empty track.
		return

	for i: int in events.size():
		var ev: Dictionary = events[i]
		var t: int = maxi(0, int(ev.get("time_ms", 0)))
		var dur: int = maxi(0, int((ev.get("params", {}) as Dictionary).get("duration_ms", 0)))
		var x0: float = PAD_X + (float(t) / float(length_ms)) * bar_w
		x0 = clampf(x0, PAD_X, PAD_X + bar_w)
		var selected: bool = i == selected_index
		var accent: Color = UITheme.CYAN if selected else UITheme.PURPLE_BRIGHT
		if dur > 0:
			var x1: float = PAD_X + (float(mini(t + dur, length_ms)) / float(length_ms)) * bar_w
			var span := Rect2(x0, bar_y + 3.0, maxf(MARKER_W, x1 - x0), BAR_H - 6.0)
			var fill: Color = Color(accent.r, accent.g, accent.b, 0.35 if selected else 0.22)
			draw_rect(span, fill, true)
		var marker := Rect2(x0 - MARKER_W * 0.5, bar_y, MARKER_W, BAR_H)
		draw_rect(marker, accent, true)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if length_ms <= 0 or events.is_empty():
		return
	var bar_w: float = maxf(1.0, size.x - PAD_X * 2.0)
	var best_i: int = -1
	var best_d: float = 12.0  # px hit tolerance
	for i: int in events.size():
		var t: int = maxi(0, int((events[i] as Dictionary).get("time_ms", 0)))
		var x: float = PAD_X + (float(t) / float(length_ms)) * bar_w
		var d: float = absf(mb.position.x - x)
		if d < best_d:
			best_d = d
			best_i = i
	if best_i >= 0:
		selected_index = best_i
		queue_redraw()
		event_selected.emit(best_i)
		accept_event()
