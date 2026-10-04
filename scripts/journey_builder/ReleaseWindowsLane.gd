class_name ReleaseWindowsLane
extends Control

## Contiguous release-window bands under the events timeline. Drag boundary handles
## to set until_ms; drag seek caret on the selected band; click a segment to select.

signal selection_changed(index: int)
signal bands_mutated()
signal boundary_drag_began()

const LANE_H: float = 28.0
const PAD: float = 8.0
const HANDLE_W: float = 8.0
const SEEK_W: float = 10.0
const SNAP_PX: float = 10.0
const MIN_VIEW_MS: int = 500

const BAND_COLORS: Array = [
	Color(0.15, 0.75, 0.85, 0.55),
	Color(0.75, 0.35, 0.90, 0.55),
	Color(0.95, 0.55, 0.20, 0.55),
	Color(0.35, 0.80, 0.45, 0.55),
	Color(0.90, 0.30, 0.55, 0.55),
	Color(0.55, 0.55, 0.95, 0.55),
]

var _bands: Array = []  # working-copy band dicts (mutated in place)
var _full_ms: int = 1
var _selected: int = -1
var _view_start: int = 0
var _view_span: int = 1
var _snap_times: PackedInt32Array = PackedInt32Array()
var _snap_enabled: bool = true

var _drag: String = ""  # "", "boundary", "seek"
var _drag_band: int = -1
var _drag_lo: int = 0
var _drag_hi: int = 0


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, LANE_H + PAD * 2.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK


func setup(full_ms: int, bands: Array) -> void:
	_full_ms = maxi(1, full_ms)
	_bands = bands
	_view_start = 0
	_view_span = _full_ms
	_selected = -1
	queue_redraw()


func set_bands(bands: Array) -> void:
	_bands = bands
	if _selected >= _bands.size():
		_selected = _bands.size() - 1
	queue_redraw()


func set_view(start_ms: int, span_ms: int) -> void:
	_view_start = clampi(start_ms, 0, maxi(0, _full_ms - 1))
	_view_span = clampi(span_ms, MIN_VIEW_MS, _full_ms)
	queue_redraw()


func set_selected(index: int) -> void:
	_selected = index if index >= 0 and index < _bands.size() else -1
	queue_redraw()


func set_snap_times(times: PackedInt32Array) -> void:
	_snap_times = times


func set_snap_enabled(on: bool) -> void:
	_snap_enabled = on


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


func _snap_ms(raw: int) -> int:
	if not _snap_enabled or Input.is_key_pressed(KEY_ALT):
		return clampi(raw, 0, _full_ms)
	var thresh: int = _snap_threshold_ms()
	var best: int = -1
	var best_d: int = thresh + 1
	for j: int in _snap_times.size():
		var t: int = _snap_times[j]
		var d: int = absi(t - raw)
		if d < best_d:
			best_d = d
			best = t
	if best >= 0:
		return clampi(best, 0, _full_ms)
	return clampi(raw, 0, _full_ms)


func _band_range(i: int) -> Vector2i:
	var prev: int = 0
	if i > 0:
		prev = int((_bands[i - 1] as Dictionary).get("until_ms", 0))
	var until: int = int((_bands[i] as Dictionary).get("until_ms", 0))
	var end: int = _full_ms if until == 0 else until
	return Vector2i(prev, end)


func _draw() -> void:
	var y: float = PAD
	var track := Rect2(PAD, y, maxf(1.0, size.x - PAD * 2.0), LANE_H)
	draw_rect(track, Color(0.10, 0.08, 0.14, 0.95), true)
	draw_rect(track, Color(UITheme.CYAN.r, UITheme.CYAN.g, UITheme.CYAN.b, 0.35), false, 1.0)

	if _bands.is_empty() or _full_ms <= 0:
		return

	for i: int in _bands.size():
		var rng: Vector2i = _band_range(i)
		var x0: float = _ms_to_x(rng.x)
		var x1: float = _ms_to_x(rng.y)
		if x1 < PAD or x0 > size.x - PAD:
			continue
		x0 = clampf(x0, PAD, size.x - PAD)
		x1 = clampf(x1, PAD, size.x - PAD)
		var col: Color = BAND_COLORS[i % BAND_COLORS.size()]
		if i == _selected:
			col = Color(col.r, col.g, col.b, 0.85)
		draw_rect(Rect2(x0, y + 2.0, maxf(2.0, x1 - x0), LANE_H - 4.0), col, true)
		var until: int = int((_bands[i] as Dictionary).get("until_ms", 0))
		if until > 0:
			var hx: float = _ms_to_x(until)
			var handle := Rect2(hx - HANDLE_W * 0.5, y, HANDLE_W, LANE_H)
			var hcol: Color = UITheme.CYAN if i == _selected else UITheme.PURPLE_BRIGHT
			draw_rect(handle, hcol, true)

	# Seek caret on selected band
	if _selected >= 0 and _selected < _bands.size():
		var seek: int = int((_bands[_selected] as Dictionary).get("seek_to_ms", -1))
		if seek >= 0:
			var sx: float = _ms_to_x(seek)
			var tip := PackedVector2Array(
				[
					Vector2(sx, y),
					Vector2(sx - SEEK_W * 0.5, y + LANE_H),
					Vector2(sx + SEEK_W * 0.5, y + LANE_H),
				]
			)
			draw_colored_polygon(tip, UITheme.AMBER)
			draw_line(Vector2(sx, y), Vector2(sx, y + LANE_H), UITheme.AMBER, 2.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_begin_press(mb.position)
		else:
			_drag = ""
			_drag_band = -1
		accept_event()
	elif event is InputEventMouseMotion and _drag != "":
		if _drag == "boundary":
			_apply_boundary_drag((event as InputEventMouseMotion).position)
		elif _drag == "seek":
			_apply_seek_drag((event as InputEventMouseMotion).position)
		accept_event()


func _begin_press(pos: Vector2) -> void:
	# Prefer seek caret on selected band
	if _selected >= 0 and _selected < _bands.size():
		var seek: int = int((_bands[_selected] as Dictionary).get("seek_to_ms", -1))
		if seek >= 0 and absf(pos.x - _ms_to_x(seek)) <= SEEK_W:
			_drag = "seek"
			_drag_band = _selected
			# Seek may land anywhere on the round clock (usually past this band).
			_drag_lo = 0
			_drag_hi = _full_ms
			boundary_drag_began.emit()
			return
	# Boundary handle hit
	for i: int in _bands.size():
		var until: int = int((_bands[i] as Dictionary).get("until_ms", 0))
		if until <= 0:
			continue
		var hx: float = _ms_to_x(until)
		if absf(pos.x - hx) <= HANDLE_W:
			_selected = i
			selection_changed.emit(i)
			_drag = "boundary"
			_drag_band = i
			var prev: int = 0 if i == 0 else int((_bands[i - 1] as Dictionary).get("until_ms", 0))
			var next_cap: int = _full_ms
			if i + 1 < _bands.size():
				var nu: int = int((_bands[i + 1] as Dictionary).get("until_ms", 0))
				if nu > 0:
					next_cap = nu
			_drag_lo = prev + 1
			_drag_hi = maxi(_drag_lo, next_cap - 1)
			boundary_drag_began.emit()
			queue_redraw()
			return
	# Segment click → select band
	var t: int = _x_to_ms(pos.x)
	for i: int in _bands.size():
		var rng: Vector2i = _band_range(i)
		if t >= rng.x and t < rng.y:
			_selected = i
			selection_changed.emit(i)
			queue_redraw()
			return
	_selected = -1
	selection_changed.emit(-1)
	queue_redraw()


func _apply_boundary_drag(pos: Vector2) -> void:
	if _drag_band < 0 or _drag_band >= _bands.size():
		return
	var raw: int = _snap_ms(_x_to_ms(pos.x))
	var until: int = clampi(raw, _drag_lo, _drag_hi)
	(_bands[_drag_band] as Dictionary)["until_ms"] = until
	bands_mutated.emit()
	queue_redraw()


func _apply_seek_drag(pos: Vector2) -> void:
	if _drag_band < 0 or _drag_band >= _bands.size():
		return
	var raw: int = _snap_ms(_x_to_ms(pos.x))
	var seek: int = clampi(raw, _drag_lo, _drag_hi)
	(_bands[_drag_band] as Dictionary)["seek_to_ms"] = seek
	bands_mutated.emit()
	queue_redraw()
