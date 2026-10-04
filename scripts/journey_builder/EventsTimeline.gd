class_name EventsTimeline
extends Control

## Round custom-events lane: funscript reference, duration blocks, drag move/resize,
## snap (prefer event edges; Alt suppresses), Ctrl+wheel zoom, middle-drag pan.

signal selection_changed(indices: Array)  # Array[int]
signal events_mutated()  # working copy changed (move/resize/etc.)
signal gesture_began()  # fired once when a move/resize drag starts (for undo snapshot)
signal playhead_scrubbed(ms: int)
signal view_changed(start_ms: int, span_ms: int)

const MIN_DURATION_MS: int = 1000
const MIN_VIEW_MS: int = 500
const ZOOM_STEP: float = 0.8
const PAD: float = 8.0
const REFERENCE_H: float = 72.0
const LANE_H: float = 36.0
const RULER_H: float = 14.0
const EDGE_GRAB_PX: float = 8.0
const STACK_GAP: float = 4.0
const SNAP_PX: float = 10.0

const NAMED_COLORS: Dictionary = {
	"cum": Color(0.95, 0.15, 0.65),
	"edge": Color(1.0, 0.72, 0.12),
	"fast": Color(0.10, 0.85, 0.90),
	"fast-stroke": Color(0.10, 0.85, 0.90),
	"medium": Color(0.70, 0.20, 1.0),
	"medium-stroke": Color(0.70, 0.20, 1.0),
	"slow": Color(0.45, 0.55, 0.70),
	"slow-stroke": Color(0.45, 0.55, 0.70),
	"stay": Color(0.45, 0.55, 0.70),
	"ruin": Color(0.90, 0.15, 0.15),
}

const HASH_PALETTE: Array = [
	Color(0.35, 0.75, 0.45),
	Color(0.95, 0.55, 0.20),
	Color(0.55, 0.40, 0.95),
	Color(0.20, 0.65, 0.85),
	Color(0.85, 0.35, 0.55),
	Color(0.65, 0.80, 0.25),
	Color(0.90, 0.45, 0.75),
	Color(0.30, 0.50, 0.85),
]

var _events: Array = []  # working copy refs (mutated in place)
var _reference: Array = []  # Vector2(t_ms, pos)
var _snap_times_script: PackedInt32Array = PackedInt32Array()
var _full_ms: int = 1
var _selected: Dictionary = {}  # index → true
var _playhead_ms: int = 0
var _snap_enabled: bool = true

var _view_start: int = 0
var _view_span: int = 1

var _drag: String = ""  # "", "move", "resize", "resize_left", "scrub", "pan"
var _drag_indices: Array = []
var _drag_grab_offset_ms: int = 0
var _drag_end_ms: int = 0
var _drag_origins: Dictionary = {}  # index → {time_ms, duration_ms}
var _pan_anchor_ms: int = 0
var _stack_row: Dictionary = {}  # index → stack row 0..n


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, REFERENCE_H + LANE_H * 3.0 + RULER_H + PAD * 2.0)
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP


func setup(full_ms: int, events: Array, reference: Array) -> void:
	_full_ms = maxi(1, full_ms)
	_events = events
	_reference = reference
	_rebuild_snap_script()
	_rebuild_stacks()
	_view_start = 0
	_view_span = _full_ms
	_selected.clear()
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


func set_events(events: Array) -> void:
	_events = events
	_rebuild_stacks()
	# Drop stale selection indices
	var keep: Dictionary = {}
	for i: Variant in _selected.keys():
		if int(i) >= 0 and int(i) < _events.size():
			keep[int(i)] = true
	_selected = keep
	queue_redraw()
	selection_changed.emit(_selected_list())


func set_snap_enabled(on: bool) -> void:
	_snap_enabled = on


func set_playhead(ms: int) -> void:
	_playhead_ms = clampi(ms, 0, _full_ms)
	queue_redraw()


func get_playhead() -> int:
	return _playhead_ms


func get_selected() -> Array:
	return _selected_list()


func set_selected(indices: Array, additive: bool = false) -> void:
	if not additive:
		_selected.clear()
	for i: Variant in indices:
		var ii: int = int(i)
		if ii >= 0 and ii < _events.size():
			_selected[ii] = true
	queue_redraw()
	selection_changed.emit(_selected_list())


func clear_selection() -> void:
	_selected.clear()
	queue_redraw()
	selection_changed.emit([])


static func color_for_name(name: String) -> Color:
	var key: String = name.strip_edges().to_lower()
	if NAMED_COLORS.has(key):
		return NAMED_COLORS[key]
	var h: int = 0
	for i: int in key.length():
		h = (h * 31 + key.unicode_at(i)) & 0x7fffffff
	return HASH_PALETTE[h % HASH_PALETTE.size()]


func _selected_list() -> Array:
	var out: Array = _selected.keys()
	out.sort()
	return out


func _rebuild_snap_script() -> void:
	_snap_times_script = PackedInt32Array()
	var seen: Dictionary = {}
	for p: Variant in _reference:
		var t: int = int((p as Vector2).x)
		if not seen.has(t):
			seen[t] = true
			_snap_times_script.append(t)


func _rebuild_stacks() -> void:
	_stack_row.clear()
	# Greedy assign stack rows by overlap order
	var order: Array = range(_events.size())
	order.sort_custom(
		func(a: int, b: int) -> bool:
			return int((_events[a] as Dictionary).get("time_ms", 0)) < int(
				(_events[b] as Dictionary).get("time_ms", 0)
			)
	)
	var row_ends: Array = []  # end_ms per row
	for ii: Variant in order:
		var i: int = int(ii)
		var ev: Dictionary = _events[i]
		var start: int = int(ev.get("time_ms", 0))
		var dur: int = maxi(MIN_DURATION_MS, int((ev.get("params", {}) as Dictionary).get("duration_ms", 0)))
		if int((ev.get("params", {}) as Dictionary).get("duration_ms", 0)) <= 0:
			dur = MIN_DURATION_MS
		var end: int = start + dur
		var row: int = 0
		while row < row_ends.size() and int(row_ends[row]) > start:
			row += 1
		if row >= row_ends.size():
			row_ends.append(end)
		else:
			row_ends[row] = end
		_stack_row[i] = row
	var rows: int = maxi(1, row_ends.size())
	custom_minimum_size = Vector2(
		0, REFERENCE_H + RULER_H + PAD * 2.0 + float(rows) * (LANE_H + STACK_GAP)
	)


# ── View maths ───────────────────────────────────────────────────────────────


func _track_x0() -> float:
	return PAD


func _span_px() -> float:
	return maxf(1.0, size.x - PAD * 2.0)


func _ms_to_x(ms: int) -> float:
	return _track_x0() + (float(ms - _view_start) / float(_view_span)) * _span_px()


func _x_to_ms(x: float) -> int:
	return clampi(
		_view_start + roundi((x - _track_x0()) / _span_px() * float(_view_span)), 0, _full_ms
	)


func _snap_threshold_ms() -> int:
	return maxi(1, roundi(float(_view_span) * (SNAP_PX / _span_px())))


func _zoom_at(factor: float, anchor_x: float) -> void:
	var new_span: int = clampi(roundi(float(_view_span) * factor), MIN_VIEW_MS, _full_ms)
	if new_span == _view_span:
		return
	var anchor_ms: int = _x_to_ms(anchor_x)
	var frac: float = clampf((anchor_x - _track_x0()) / _span_px(), 0.0, 1.0)
	_view_span = new_span
	_view_start = clampi(anchor_ms - roundi(frac * float(new_span)), 0, _full_ms - new_span)
	queue_redraw()
	view_changed.emit(_view_start, _view_span)


func _event_duration(ev: Dictionary) -> int:
	return maxi(0, int((ev.get("params", {}) as Dictionary).get("duration_ms", 0)))


func _draw_duration_ms(ev: Dictionary) -> int:
	var d: int = _event_duration(ev)
	return maxi(MIN_DURATION_MS, d) if d > 0 else MIN_DURATION_MS


func _event_rect(i: int) -> Rect2:
	var ev: Dictionary = _events[i]
	var at: int = int(ev.get("time_ms", 0))
	var dur: int = _draw_duration_ms(ev)
	var x: float = _ms_to_x(at)
	var w: float = maxf(EDGE_GRAB_PX * 2.0, _ms_to_x(at + dur) - x)
	var row: int = int(_stack_row.get(i, 0))
	var y: float = PAD + REFERENCE_H + RULER_H + float(row) * (LANE_H + STACK_GAP)
	return Rect2(x, y, w, LANE_H)


# ── Snap ─────────────────────────────────────────────────────────────────────


func _snap_ms(raw: int, exclude_indices: Array) -> int:
	if not _snap_enabled or Input.is_key_pressed(KEY_ALT):
		return clampi(raw, 0, _full_ms)
	var thresh: int = _snap_threshold_ms()
	var best_edge: int = -1
	var best_edge_d: int = thresh + 1
	var best_script: int = -1
	var best_script_d: int = thresh + 1
	var excl: Dictionary = {}
	for i: Variant in exclude_indices:
		excl[int(i)] = true
	for i: int in _events.size():
		if excl.has(i):
			continue
		var ev: Dictionary = _events[i]
		var start: int = int(ev.get("time_ms", 0))
		var end: int = start + maxi(0, _event_duration(ev))
		for t: int in [start, end]:
			var d: int = absi(t - raw)
			if d < best_edge_d:
				best_edge_d = d
				best_edge = t
	for j: int in _snap_times_script.size():
		var t2: int = _snap_times_script[j]
		var d2: int = absi(t2 - raw)
		if d2 < best_script_d:
			best_script_d = d2
			best_script = t2
	# Prefer event edges when both in range
	if best_edge >= 0 and best_edge_d <= thresh:
		return clampi(best_edge, 0, _full_ms)
	if best_script >= 0 and best_script_d <= thresh:
		return clampi(best_script, 0, _full_ms)
	return clampi(raw, 0, _full_ms)


# ── Input ────────────────────────────────────────────────────────────────────


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed and mb.ctrl_pressed:
					_zoom_at(ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed and mb.ctrl_pressed:
					_zoom_at(1.0 / ZOOM_STEP, mb.position.x)
					accept_event()
			MOUSE_BUTTON_MIDDLE:
				_drag = "pan" if mb.pressed else ""
				if mb.pressed:
					_pan_anchor_ms = _x_to_ms(mb.position.x)
				accept_event()
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_begin_drag(mb.position, mb.shift_pressed or mb.ctrl_pressed)
				else:
					_drag = ""
					_drag_indices.clear()
					_drag_origins.clear()
				accept_event()
	elif event is InputEventMouseMotion and _drag != "":
		_apply_drag((event as InputEventMouseMotion).position)
		accept_event()


func _event_at_point(pos: Vector2) -> int:
	# Topmost stack first
	var best: int = -1
	var best_row: int = -1
	for i: int in _events.size():
		var r: Rect2 = _event_rect(i)
		if r.has_point(pos):
			var row: int = int(_stack_row.get(i, 0))
			if row >= best_row:
				best_row = row
				best = i
	return best


func _begin_drag(pos: Vector2, additive: bool) -> void:
	var hit: int = _event_at_point(pos)
	if hit < 0:
		_drag = "scrub"
		if not additive:
			clear_selection()
		_apply_drag(pos)
		return
	if additive:
		if _selected.has(hit):
			_selected.erase(hit)
		else:
			_selected[hit] = true
	else:
		if not _selected.has(hit):
			_selected.clear()
			_selected[hit] = true
	selection_changed.emit(_selected_list())
	var rect: Rect2 = _event_rect(hit)
	_drag_indices = _selected_list()
	if _drag_indices.is_empty():
		_drag_indices = [hit]
	_drag_origins.clear()
	for i: Variant in _drag_indices:
		var ev: Dictionary = _events[int(i)]
		_drag_origins[int(i)] = {
			"time_ms": int(ev.get("time_ms", 0)),
			"duration_ms": _event_duration(ev),
		}
	if pos.x >= rect.end.x - EDGE_GRAB_PX:
		_drag = "resize"
		_drag_indices = [hit]  # resize primary only
		_drag_origins = {hit: _drag_origins[hit]}
	elif pos.x <= rect.position.x + EDGE_GRAB_PX:
		_drag = "resize_left"
		_drag_end_ms = int((_events[hit] as Dictionary).get("time_ms", 0)) + maxi(
			MIN_DURATION_MS, _event_duration(_events[hit])
		)
		_drag_indices = [hit]
		_drag_origins = {hit: _drag_origins[hit]}
	else:
		_drag = "move"
		_drag_grab_offset_ms = _x_to_ms(pos.x) - int((_events[hit] as Dictionary).get("time_ms", 0))
	if _drag in ["move", "resize", "resize_left"]:
		gesture_began.emit()
	queue_redraw()


func _ensure_params(ev: Dictionary) -> Dictionary:
	if not (ev.get("params") is Dictionary):
		ev["params"] = {}
	return ev["params"]


func _apply_drag(pos: Vector2) -> void:
	match _drag:
		"scrub":
			_playhead_ms = _x_to_ms(pos.x)
			playhead_scrubbed.emit(_playhead_ms)
			queue_redraw()
		"pan":
			var cur: int = _x_to_ms(pos.x)
			var delta: int = _pan_anchor_ms - cur
			_view_start = clampi(_view_start + delta, 0, maxi(0, _full_ms - _view_span))
			queue_redraw()
			view_changed.emit(_view_start, _view_span)
		"move":
			if _drag_indices.is_empty():
				return
			var primary: int = int(_drag_indices[0])
			var raw: int = _x_to_ms(pos.x) - _drag_grab_offset_ms
			var new_start: int = _snap_ms(raw, _drag_indices)
			var origin_p: Dictionary = _drag_origins[primary]
			var delta_t: int = new_start - int(origin_p["time_ms"])
			for i: Variant in _drag_indices:
				var ii: int = int(i)
				var ev: Dictionary = _events[ii]
				var o: Dictionary = _drag_origins[ii]
				var dur: int = maxi(MIN_DURATION_MS, int(o["duration_ms"]))
				var t: int = clampi(int(o["time_ms"]) + delta_t, 0, maxi(0, _full_ms - dur))
				ev["time_ms"] = t
				_ensure_params(ev)["duration_ms"] = dur
			_rebuild_stacks()
			events_mutated.emit()
			queue_redraw()
		"resize":
			var ii: int = int(_drag_indices[0])
			var ev: Dictionary = _events[ii]
			var start: int = int(ev.get("time_ms", 0))
			var end_raw: int = _x_to_ms(pos.x)
			var end_s: int = _snap_ms(end_raw, [ii])
			var dur: int = clampi(end_s - start, MIN_DURATION_MS, maxi(MIN_DURATION_MS, _full_ms - start))
			_ensure_params(ev)["duration_ms"] = dur
			_rebuild_stacks()
			events_mutated.emit()
			queue_redraw()
		"resize_left":
			var ii2: int = int(_drag_indices[0])
			var ev2: Dictionary = _events[ii2]
			var start_raw: int = _x_to_ms(pos.x)
			var start_s: int = _snap_ms(start_raw, [ii2])
			start_s = clampi(start_s, 0, _drag_end_ms - MIN_DURATION_MS)
			ev2["time_ms"] = start_s
			_ensure_params(ev2)["duration_ms"] = _drag_end_ms - start_s
			_rebuild_stacks()
			events_mutated.emit()
			queue_redraw()


# ── Draw ─────────────────────────────────────────────────────────────────────


func _draw() -> void:
	var bg := Rect2(Vector2.ZERO, size)
	draw_rect(bg, Color(0.06, 0.05, 0.10, 0.95), true)
	_draw_reference()
	_draw_ruler()
	for i: int in _events.size():
		_draw_event(i)
	# Playhead
	var px: float = _ms_to_x(_playhead_ms)
	draw_line(Vector2(px, PAD), Vector2(px, size.y - PAD), Color(1, 1, 1, 0.85), 1.5)


func _draw_reference() -> void:
	var y0: float = PAD
	var y1: float = PAD + REFERENCE_H
	draw_rect(Rect2(PAD, y0, _span_px(), REFERENCE_H), Color(0.1, 0.08, 0.14, 1), true)
	if _reference.size() < 2:
		return
	var pts: PackedVector2Array = PackedVector2Array()
	for p: Variant in _reference:
		var v: Vector2 = p
		if v.x < float(_view_start) - 50.0:
			continue
		if v.x > float(_view_start + _view_span) + 50.0:
			break
		var x: float = _ms_to_x(int(v.x))
		var y: float = y1 - (clampf(v.y, 0.0, 100.0) / 100.0) * (REFERENCE_H - 4.0) - 2.0
		pts.append(Vector2(x, y))
	if pts.size() >= 2:
		draw_polyline(pts, Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.85), 1.5, true)


func _draw_ruler() -> void:
	var y: float = PAD + REFERENCE_H
	draw_rect(Rect2(PAD, y, _span_px(), RULER_H), Color(0.08, 0.07, 0.12, 1), true)
	var step: int = _nice_step(_view_span)
	var t: int = (_view_start / step) * step
	while t <= _view_start + _view_span:
		var x: float = _ms_to_x(t)
		draw_line(Vector2(x, y), Vector2(x, y + RULER_H), Color(1, 1, 1, 0.25), 1.0)
		t += step


func _nice_step(span: int) -> int:
	var candidates: Array = [1000, 2000, 5000, 10000, 15000, 30000, 60000, 120000]
	for c: Variant in candidates:
		if span / int(c) <= 12:
			return int(c)
	return 300000


func _draw_event(i: int) -> void:
	var ev: Dictionary = _events[i]
	var rect: Rect2 = _event_rect(i)
	var col: Color = color_for_name(str(ev.get("name", "")))
	var selected: bool = _selected.has(i)
	var fill: Color = Color(col.r, col.g, col.b, 0.55 if selected else 0.38)
	draw_rect(rect, fill, true)
	draw_rect(rect, Color(col.r, col.g, col.b, 1.0 if selected else 0.75), false, 2.0 if selected else 1.0)
	# Right resize grip
	var grip := Rect2(rect.end.x - 4.0, rect.position.y, 4.0, rect.size.y)
	draw_rect(grip, Color(1, 1, 1, 0.45), true)
	var label: String = str(ev.get("name", "?"))
	if rect.size.x > 28.0:
		draw_string(
			ThemeDB.fallback_font,
			Vector2(rect.position.x + 4.0, rect.position.y + rect.size.y * 0.7),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			int(rect.size.x - 8.0),
			12,
			Color(1, 1, 1, 0.95)
		)
