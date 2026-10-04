class_name JourneyEventsEditor
extends Node

## Full-screen overlay to author journey.json Events for one round.
## Working copy until Apply; Cancel discards. Defs must already be loaded by the caller.

signal applied(round_id: String, events: Array)
signal release_applied(round_id: String, fields: Dictionary)
signal cancelled

const MIN_DURATION_MS: int = 1000
const INSPECTOR_W: int = 340
const UNDO_DEPTH: int = 60
const COALESCE_MS: int = 400

var _round_id: String = ""
var _round_name: String = ""
var _full_ms: int = 1
var _video_path: String = ""
var _funscript_path: String = ""
var _defs: Dictionary = {}
var _events: Array = []  # working copy
var _dirty: bool = false

var _release_cfg: Dictionary = {}
var _release_windows: Array = []  # working copy of bands
var _release_focus: bool = false
var _selected_band: int = -1
var _release_lane: ReleaseWindowsLane = null
var _release_dirty: bool = false
var _known_flags: Array = []  # String flag names from journey
var _node_choices: Array = []  # [{id, label}, ...] exclude self

var _modal: Control = null
var _timeline: EventsTimeline = null
var _inspector: VBoxContainer = null
var _kit_box: HBoxContainer = null
var _snap_btn: Button = null
var _warn_lbl: Label = null
var _title_lbl: Label = null

var _video: VideoStreamPlayer = null
var _video_pane: Control = null
var _play_btn: Button = null
var _video_ok: bool = false
var _audio_on: bool = false

var _undo: Array = []
var _redo: Array = []
var _last_push_ms: int = 0
var _coalesce_kind: String = ""
var _rebuilding_inspector: bool = false


func open(
	parent: Node,
	round_id: String,
	round_name: String,
	full_ms: int,
	video_path: String,
	funscript_path: String,
	defs: Dictionary,
	round_events: Array,
	release_cfg: Dictionary = {},
	focus_release: bool = false,
	known_flags: Array = [],
	node_choices: Array = []
) -> void:
	_round_id = round_id
	_round_name = round_name
	_full_ms = maxi(1, full_ms)
	_video_path = video_path
	_funscript_path = funscript_path
	_defs = defs if defs is Dictionary else {}
	_release_focus = focus_release
	_known_flags = known_flags.duplicate()
	_node_choices = node_choices.duplicate(true)
	_release_cfg = release_cfg.duplicate(true) if not release_cfg.is_empty() else {}
	_events = []
	for e: Variant in round_events:
		if e is Dictionary:
			_events.append((e as Dictionary).duplicate(true))
	_release_windows = JourneyData.normalize_release_windows(
		_release_cfg.get("release_windows", [])
	)
	# Deep-copy so working copy does not alias normalize output.
	var bands_copy: Array = []
	for b: Variant in _release_windows:
		bands_copy.append((b as Dictionary).duplicate(true))
	_release_windows = bands_copy
	if _release_focus and _release_windows.is_empty():
		_release_windows = [_default_band(_full_ms / 2), _default_band(0)]
		_release_dirty = true
	_selected_band = 0 if (_release_focus and not _release_windows.is_empty()) else -1
	parent.add_child(self)

	var modal_title: String = "◆ RELEASE WINDOWS" if _release_focus else "◆ CUSTOM EVENTS"
	var parts: Dictionary = UITheme.build_centered_modal(modal_title, UITheme.CYAN, _modal_size())
	_modal = parts["modal"]
	var column: VBoxContainer = parts["vbox"]

	_title_lbl = Label.new()
	var focus_tag: String = "  ·  Release" if _release_focus else ""
	_title_lbl.text = (
		"%s  ·  %s%s"
		% [round_name if round_name != "" else round_id, _format_clock(_full_ms), focus_tag]
	)
	_title_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	_title_lbl.add_theme_font_size_override("font_size", 12)
	column.add_child(_title_lbl)

	var body: HBoxContainer = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)

	var left: VBoxContainer = VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	left.add_child(_build_video_block())
	left.add_child(_build_transport())
	left.add_child(_build_kit())
	left.add_child(_build_timeline())
	left.add_child(_build_release_lane())
	body.add_child(left)

	_inspector = VBoxContainer.new()
	_inspector.custom_minimum_size = Vector2(INSPECTOR_W, 0)
	_inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspector.add_theme_constant_override("separation", 6)
	body.add_child(_inspector)

	column.add_child(body)
	column.add_child(_build_footer())

	add_child(_modal)
	_disable_button_focus(_modal)
	get_viewport().gui_release_focus()

	var actions: Array = JourneyData.read_funscript_actions(_funscript_path)
	_timeline.setup(_full_ms, _events, actions)
	if _release_lane:
		_release_lane.setup(_full_ms, _release_windows)
		_release_lane.set_snap_times(_build_release_snap_times(actions))
		if _selected_band >= 0:
			_release_lane.set_selected(_selected_band)
	_refresh_inspector()
	_refresh_warnings()
	_setup_video.call_deferred()


func _build_release_snap_times(actions: Array) -> PackedInt32Array:
	var seen: Dictionary = {}
	var out: PackedInt32Array = PackedInt32Array()
	for e: Variant in _events:
		if not (e is Dictionary):
			continue
		var start: int = int((e as Dictionary).get("time_ms", 0))
		var dur: int = int(((e as Dictionary).get("params", {}) as Dictionary).get("duration_ms", 0))
		for t: int in [start, start + maxi(0, dur)]:
			if not seen.has(t):
				seen[t] = true
				out.append(t)
	for a: Variant in actions:
		var t2: int = int((a as Vector2).x) if a is Vector2 else int(a)
		if not seen.has(t2):
			seen[t2] = true
			out.append(t2)
	return out


func _modal_size() -> Vector2i:
	var viewport: Vector2 = Vector2(1600, 900)
	if is_inside_tree():
		viewport = get_viewport().get_visible_rect().size
	return Vector2i(int(viewport.x * 0.94), int(viewport.y * 0.94))


func _disable_button_focus(node: Node) -> void:
	if node is Button:
		(node as Button).focus_mode = Control.FOCUS_NONE
	for child: Node in node.get_children():
		_disable_button_focus(child)


func _format_clock(ms: int) -> String:
	var s: int = int(round(ms / 1000.0))
	return "%d:%02d" % [s / 60, s % 60]


func _build_video_block() -> Control:
	var pane: PanelContainer = PanelContainer.new()
	var st: StyleBoxFlat = StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 1)
	pane.add_theme_stylebox_override("panel", st)
	pane.custom_minimum_size = Vector2(0, 180)
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.size_flags_stretch_ratio = 1.2
	pane.clip_contents = true
	pane.visible = false
	_video_pane = pane
	var aspect: AspectRatioContainer = AspectRatioContainer.new()
	aspect.ratio = 16.0 / 9.0
	aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	pane.add_child(aspect)
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.volume_db = -80.0
	aspect.add_child(_video)
	return pane


func _build_transport() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_play_btn = UITheme.make_icon_btn("▶ PLAY", true, UITheme.SUCCESS)
	_play_btn.pressed.connect(_toggle_play)
	row.add_child(_play_btn)
	_snap_btn = Button.new()
	_snap_btn.toggle_mode = true
	_snap_btn.button_pressed = true
	_snap_btn.text = "SNAP"
	_snap_btn.tooltip_text = UITheme.wrap_tip(
		"Snap to other event edges (preferred) and funscript points. Hold Alt to place freely."
	)
	UITheme.style_button(_snap_btn, UITheme.PURPLE_MID)
	_snap_btn.toggled.connect(
		func(on: bool) -> void:
			if _timeline:
				_timeline.set_snap_enabled(on)
			if _release_lane:
				_release_lane.set_snap_enabled(on)
	)
	row.add_child(_snap_btn)
	var undo_btn: Button = UITheme.make_icon_btn("↶", false, UITheme.PURPLE_BRIGHT)
	undo_btn.tooltip_text = UITheme.wrap_tip("Undo")
	undo_btn.pressed.connect(_undo_step)
	row.add_child(undo_btn)
	var redo_btn: Button = UITheme.make_icon_btn("↷", false, UITheme.PURPLE_BRIGHT)
	redo_btn.tooltip_text = UITheme.wrap_tip("Redo")
	redo_btn.pressed.connect(_redo_step)
	row.add_child(redo_btn)
	var hint: Label = Label.new()
	hint.text = "Ctrl+wheel zoom · middle-drag pan · Alt = free place"
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(hint)
	return row


func _build_kit() -> Control:
	var wrap: VBoxContainer = VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	var lbl: Label = Label.new()
	lbl.text = "ADD EVENT (AT PLAYHEAD)"
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	wrap.add_child(lbl)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 36)
	_kit_box = HBoxContainer.new()
	_kit_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_kit_box)
	wrap.add_child(scroll)
	var names: Array = _defs.get("names", []) as Array if _defs is Dictionary else []
	if names.is_empty():
		var empty: Label = Label.new()
		empty.text = (
			"No event definitions — events lane is still visible; add defs to place new events."
			if _release_focus
			else "No event definitions loaded."
		)
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		_kit_box.add_child(empty)
	else:
		for n: Variant in names:
			var name: String = str(n)
			var btn: Button = Button.new()
			btn.text = name
			btn.focus_mode = Control.FOCUS_NONE
			var col: Color = EventsTimeline.color_for_name(name)
			UITheme.style_button(btn, col)
			btn.pressed.connect(func() -> void: _add_event(name))
			_kit_box.add_child(btn)
	return wrap


func _build_timeline() -> Control:
	_timeline = EventsTimeline.new()
	_timeline.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_timeline.size_flags_stretch_ratio = 1.0
	_timeline.selection_changed.connect(_on_selection_changed)
	_timeline.events_mutated.connect(_on_timeline_mutated)
	_timeline.gesture_began.connect(_on_gesture_began)
	_timeline.playhead_scrubbed.connect(_on_playhead_scrubbed)
	_timeline.view_changed.connect(_on_timeline_view_changed)
	return _timeline


func _build_release_lane() -> Control:
	var wrap: VBoxContainer = VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 8)
	var lbl: Label = Label.new()
	lbl.text = "RELEASE WINDOWS"
	lbl.add_theme_color_override("font_color", UITheme.CYAN)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(lbl)
	var add_btn: Button = Button.new()
	add_btn.text = "ADD BAND"
	add_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(_add_release_band)
	hdr.add_child(add_btn)
	var del_btn: Button = Button.new()
	del_btn.text = "DELETE BAND"
	del_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(del_btn, UITheme.MAGENTA)
	del_btn.pressed.connect(_delete_release_band)
	hdr.add_child(del_btn)
	wrap.add_child(hdr)
	_release_lane = ReleaseWindowsLane.new()
	_release_lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_release_lane.selection_changed.connect(_on_band_selection_changed)
	_release_lane.bands_mutated.connect(_on_bands_mutated)
	_release_lane.boundary_drag_began.connect(func() -> void: _release_dirty = true)
	wrap.add_child(_release_lane)
	# Always show lane when focusing release, or when bands already exist.
	wrap.visible = _release_focus or not _release_windows.is_empty()
	return wrap


func _on_timeline_view_changed(start_ms: int, span_ms: int) -> void:
	if _release_lane:
		_release_lane.set_view(start_ms, span_ms)


func _build_footer() -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_warn_lbl = Label.new()
	_warn_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_warn_lbl.add_theme_font_size_override("font_size", 11)
	_warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(_warn_lbl)
	var del_btn: Button = Button.new()
	del_btn.text = "DELETE"
	UITheme.style_button(del_btn, UITheme.MAGENTA)
	del_btn.pressed.connect(_delete_selected)
	row.add_child(del_btn)
	var apply_btn: Button = Button.new()
	apply_btn.text = "APPLY"
	UITheme.style_button(apply_btn, UITheme.SUCCESS)
	apply_btn.pressed.connect(_apply)
	row.add_child(apply_btn)
	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(_cancel)
	row.add_child(cancel_btn)
	return row


# ── Video ────────────────────────────────────────────────────────────────────


func _setup_video() -> void:
	if _video_path == "" or _video == null:
		return
	var ext: String = _video_path.get_extension().to_lower()
	if ext == "ogv":
		var stream: Resource = ResourceLoader.load(_video_path)
		if stream is VideoStream:
			_video.stream = stream as VideoStream
		else:
			return
	elif ClassDB.class_exists("FFmpegVideoStream"):
		var stream2: Resource = ClassDB.instantiate("FFmpegVideoStream")
		stream2.set("file", ProjectSettings.globalize_path(_video_path))
		_video.stream = stream2 as VideoStream
	else:
		return
	_video_pane.visible = true
	_video.play()
	var started: bool = false
	for _i in 60:
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if _video.is_playing():
			started = true
			break
	if started:
		_video_ok = true
		_play_btn.disabled = false
		_video.paused = true
		_video.stream_position = 0.0
		_update_play_btn()
		set_process(true)
	else:
		_video_pane.visible = false
		_video.stream = null


func _process(_dt: float) -> void:
	if not _video_ok or _video == null:
		return
	if _video.is_playing() and not _video.paused:
		var ms: int = int(_video.stream_position * 1000.0)
		if _timeline:
			_timeline.set_playhead(ms)


func _toggle_play() -> void:
	if not _video_ok or _video == null:
		return
	if _video.paused or not _video.is_playing():
		_video.paused = false
		if not _video.is_playing():
			_video.play()
	else:
		_video.paused = true
	_update_play_btn()


func _update_play_btn() -> void:
	if _video == null:
		return
	var playing: bool = _video.is_playing() and not _video.paused
	_play_btn.text = "⏸ PAUSE" if playing else "▶ PLAY"


func _on_playhead_scrubbed(ms: int) -> void:
	if _video_ok and _video != null:
		_video.stream_position = float(ms) / 1000.0
		_video.paused = true
		_update_play_btn()


# ── Events mutate ────────────────────────────────────────────────────────────


func _snapshot() -> Array:
	var out: Array = []
	for e: Variant in _events:
		out.append((e as Dictionary).duplicate(true))
	return out


func _push_undo(kind: String, coalesce: bool = true) -> void:
	# Snapshot CURRENT state before the caller mutates.
	var now: int = Time.get_ticks_msec()
	if (
		coalesce
		and kind == _coalesce_kind
		and not _undo.is_empty()
		and now - _last_push_ms < COALESCE_MS
	):
		_last_push_ms = now
		return
	_undo.append(_snapshot())
	if _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()
	_coalesce_kind = kind
	_last_push_ms = now
	_dirty = true


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_snapshot())
	_events = (_undo.pop_back() as Array).duplicate(true)
	_deep_dup_events()
	_timeline.set_events(_events)
	_refresh_inspector()
	_refresh_warnings()
	_dirty = true


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_snapshot())
	_events = (_redo.pop_back() as Array).duplicate(true)
	_deep_dup_events()
	_timeline.set_events(_events)
	_refresh_inspector()
	_refresh_warnings()
	_dirty = true


func _deep_dup_events() -> void:
	var fresh: Array = []
	for e: Variant in _events:
		fresh.append((e as Dictionary).duplicate(true))
	_events = fresh


func _add_event(name: String) -> void:
	_push_undo("add", false)
	var defaults: Dictionary = EventDefinitions.default_params_for(_defs, name)
	if not defaults.has("duration_ms") or int(defaults["duration_ms"]) < MIN_DURATION_MS:
		defaults["duration_ms"] = MIN_DURATION_MS
	else:
		defaults["duration_ms"] = maxi(MIN_DURATION_MS, int(defaults["duration_ms"]))
	var t: int = _timeline.get_playhead() if _timeline else 0
	t = clampi(t, 0, maxi(0, _full_ms - MIN_DURATION_MS))
	var ev: Dictionary = JourneyData.default_journey_event(_round_id, name, defaults)
	ev["time_ms"] = t
	_events.append(ev)
	_timeline.set_events(_events)
	_timeline.set_selected([_events.size() - 1])
	_refresh_inspector()
	_refresh_warnings()


func _delete_selected() -> void:
	var sel: Array = _timeline.get_selected() if _timeline else []
	if sel.is_empty():
		return
	_push_undo("delete", false)
	sel.sort()
	sel.reverse()
	for i: Variant in sel:
		_events.remove_at(int(i))
	_timeline.set_events(_events)
	_timeline.clear_selection()
	_refresh_inspector()
	_refresh_warnings()


func _on_gesture_began() -> void:
	_push_undo("drag", false)


func _on_timeline_mutated() -> void:
	_dirty = true
	_refresh_inspector()
	_refresh_warnings()


func _on_selection_changed(_indices: Array) -> void:
	# Event selection clears band focus so inspector shows event fields.
	if not _indices.is_empty():
		_selected_band = -1
		if _release_lane:
			_release_lane.set_selected(-1)
	_refresh_inspector()


func _on_band_selection_changed(index: int) -> void:
	_selected_band = index
	if index >= 0 and _timeline:
		_timeline.clear_selection()
	_refresh_inspector()


func _on_bands_mutated() -> void:
	_release_dirty = true
	_refresh_inspector()
	_refresh_warnings()


func _refresh_warnings() -> void:
	var parts: PackedStringArray = PackedStringArray()
	var warns: Array = JourneyData.validate_round_events(_events, _full_ms)
	if warns.is_empty():
		parts.append("%d event(s)" % _events.size())
	else:
		parts.append("⚠ " + " · ".join(PackedStringArray(warns)))
	if _release_focus or not _release_windows.is_empty():
		parts.append("%d band(s)" % _release_windows.size())
		var rw: Array = JourneyData.validate_release_windows(_release_windows, _full_ms)
		if not rw.is_empty():
			parts.append("⚠ " + " · ".join(PackedStringArray(rw)))
	parts.append("draft until Apply")
	_warn_lbl.text = "  ·  ".join(parts)
	_warn_lbl.add_theme_color_override(
		"font_color",
		(
			UITheme.ERROR_SOFT
			if not warns.is_empty() or (
				(_release_focus or not _release_windows.is_empty())
				and not JourneyData.validate_release_windows(_release_windows, _full_ms).is_empty()
			)
			else UITheme.SEPARATOR
		)
	)


# ── Release bands ────────────────────────────────────────────────────────────


func _default_band(until_ms: int) -> Dictionary:
	return {
		"until_ms": until_ms,
		"flag": "",
		"jump_to": "",
		"coins": 0,
		"expire_coins": 0,
		"seek_to_ms": -1,
	}


func _ensure_open_ended_last() -> void:
	if _release_windows.is_empty():
		_release_windows.append(_default_band(0))
		return
	var last: Dictionary = _release_windows[_release_windows.size() - 1]
	last["until_ms"] = 0


func _add_release_band() -> void:
	_release_dirty = true
	if _release_windows.is_empty():
		_release_windows = [_default_band(_full_ms / 2), _default_band(0)]
	else:
		# Split the last finite threshold, or insert a new finite band before open-ended last.
		var last_i: int = _release_windows.size() - 1
		var last: Dictionary = _release_windows[last_i]
		if int(last.get("until_ms", 0)) == 0:
			var prev_end: int = 0
			if last_i > 0:
				prev_end = int((_release_windows[last_i - 1] as Dictionary).get("until_ms", 0))
			var mid: int = clampi((prev_end + _full_ms) / 2, prev_end + 1, maxi(prev_end + 1, _full_ms - 1))
			_release_windows.insert(last_i, _default_band(mid))
		else:
			var until: int = int(last.get("until_ms", 0))
			var mid2: int = clampi((until + _full_ms) / 2, until + 1, maxi(until + 1, _full_ms - 1))
			last["until_ms"] = mid2
			_release_windows.append(_default_band(0))
	_ensure_open_ended_last()
	if _release_lane:
		_release_lane.set_bands(_release_windows)
		_selected_band = maxi(0, _release_windows.size() - 2)
		_release_lane.set_selected(_selected_band)
	_refresh_inspector()
	_refresh_warnings()


func _delete_release_band() -> void:
	if _release_windows.size() <= 1:
		return
	var i: int = _selected_band
	if i < 0 or i >= _release_windows.size():
		i = _release_windows.size() - 1
	_release_dirty = true
	_release_windows.remove_at(i)
	_ensure_open_ended_last()
	_selected_band = mini(i, _release_windows.size() - 1)
	if _release_lane:
		_release_lane.set_bands(_release_windows)
		_release_lane.set_selected(_selected_band)
	_refresh_inspector()
	_refresh_warnings()


# ── Inspector ────────────────────────────────────────────────────────────────


func _refresh_inspector() -> void:
	if _inspector == null:
		return
	_rebuilding_inspector = true
	for c in _inspector.get_children():
		c.queue_free()
	var hdr: Label = Label.new()
	hdr.text = "INSPECTOR"
	hdr.add_theme_color_override("font_color", UITheme.CYAN)
	hdr.add_theme_font_size_override("font_size", 13)
	_inspector.add_child(hdr)

	if _selected_band >= 0 and _selected_band < _release_windows.size():
		_build_band_inspector(_release_windows[_selected_band], _selected_band)
		_rebuilding_inspector = false
		return

	var sel: Array = _timeline.get_selected() if _timeline else []
	if sel.is_empty():
		var empty: Label = Label.new()
		empty.text = (
			"Select a release band below, or an event on the timeline."
			if (_release_focus or not _release_windows.is_empty())
			else "Select an event on the timeline, or add one from the kit."
		)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 11)
		_inspector.add_child(empty)
		_rebuilding_inspector = false
		return
	if sel.size() > 1:
		var multi: Label = Label.new()
		multi.text = "%d events selected — drag to move together, Delete to remove." % sel.size()
		multi.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		multi.add_theme_color_override("font_color", UITheme.SEPARATOR)
		_inspector.add_child(multi)
		_rebuilding_inspector = false
		return
	var i: int = int(sel[0])
	if i < 0 or i >= _events.size():
		_rebuilding_inspector = false
		return
	_build_event_inspector(_events[i], i)
	_rebuilding_inspector = false


func _build_band_inspector(band: Dictionary, index: int) -> void:
	var sub: Label = Label.new()
	sub.text = "RELEASE BAND %d / %d" % [index + 1, _release_windows.size()]
	sub.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	sub.add_theme_font_size_override("font_size", 11)
	_inspector.add_child(sub)

	var until: int = int(band.get("until_ms", 0))
	_inspector.add_child(_field_label("UNTIL"))
	var until_lbl: Label = Label.new()
	until_lbl.text = "→ end of round" if until == 0 else _format_clock(until)
	until_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	until_lbl.add_theme_font_size_override("font_size", 12)
	_inspector.add_child(until_lbl)
	var until_hint: Label = Label.new()
	until_hint.text = "Drag the boundary handle on the lane to change (open-ended last band)."
	until_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	until_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	until_hint.add_theme_font_size_override("font_size", 10)
	_inspector.add_child(until_hint)

	_inspector.add_child(_field_label("FLAG (OPTIONAL)"))
	_inspector.add_child(_band_flag_field(band))

	_inspector.add_child(_field_label("JUMP TO NODE (OPTIONAL)"))
	_inspector.add_child(_band_jump_dropdown(band))

	_inspector.add_child(_field_label("AWARD COINS ON RELEASE"))
	_inspector.add_child(
		_band_signed_spin(
			band,
			"coins",
			int(band.get("coins", band.get("score", 0))),
			0,
			999999
		)
	)

	_inspector.add_child(_field_label("AWARD COINS IF NO RELEASE"))
	_inspector.add_child(
		_band_signed_spin(
			band,
			"expire_coins",
			int(band.get("expire_coins", band.get("expire_score", 0))),
			0,
			999999
		)
	)
	var exp_hint: Label = Label.new()
	exp_hint.text = (
		"Only if Release was never pressed. Finite band: when until is crossed. "
		+ "Last open band: at round end. Put the “no release = early amount” on the last band, not the early boundary."
	)
	exp_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	exp_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	exp_hint.add_theme_font_size_override("font_size", 10)
	_inspector.add_child(exp_hint)

	_inspector.add_child(_field_label("SEEK TO TIMESTAMP (OPTIONAL)"))
	_inspector.add_child(_band_seek_timestamp_row(band))
	var seek_at: Button = Button.new()
	seek_at.text = "PLACE SEEK AT PLAYHEAD"
	seek_at.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(seek_at, UITheme.PURPLE_MID)
	seek_at.pressed.connect(
		func() -> void:
			_release_dirty = true
			var ph: int = _timeline.get_playhead() if _timeline else 0
			band["seek_to_ms"] = clampi(ph, 0, _full_ms)
			if _release_lane:
				_release_lane.set_bands(_release_windows)
				_release_lane.set_selected(_selected_band)
			_refresh_inspector()
	)
	_inspector.add_child(seek_at)
	var clear_seek: Button = Button.new()
	clear_seek.text = "CLEAR SEEK"
	clear_seek.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(clear_seek, UITheme.MAGENTA)
	clear_seek.pressed.connect(
		func() -> void:
			_release_dirty = true
			band["seek_to_ms"] = -1
			if _release_lane:
				_release_lane.set_bands(_release_windows)
				_release_lane.set_selected(_selected_band)
			_refresh_inspector()
	)
	_inspector.add_child(clear_seek)
	var seek_hint: Label = Label.new()
	seek_hint.text = (
		"Forward seek after release if jump is empty. Drag the amber caret anywhere on the round "
		+ "clock (usually past this band). Jump wins over seek."
	)
	seek_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	seek_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	seek_hint.add_theme_font_size_override("font_size", 10)
	_inspector.add_child(seek_hint)


# Free-type flag name (same idea as stamp Release) plus a quick-pick of known / suggested names.
func _band_flag_field(band: Dictionary) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var edit: LineEdit = LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.placeholder_text = "e.g. released"
	edit.text = str(band.get("flag", ""))
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(
		func(val: String) -> void:
			if _rebuilding_inspector:
				return
			_release_dirty = true
			band["flag"] = val.strip_edges()
	)
	box.add_child(edit)

	var flags: Array = _known_flags.duplicate()
	flags.sort_custom(
		func(a: Variant, b: Variant) -> bool: return str(a).to_lower() < str(b).to_lower()
	)
	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.add_item("Quick pick...")
	dd.set_item_metadata(0, "")
	for f_var: Variant in flags:
		var f: String = str(f_var).strip_edges()
		if f == "":
			continue
		dd.add_item(f)
		dd.set_item_metadata(dd.item_count - 1, f)
	dd.selected = 0
	dd.item_selected.connect(
		func(i: int) -> void:
			if _rebuilding_inspector:
				return
			var picked: String = str(dd.get_item_metadata(i))
			if picked == "":
				return
			_release_dirty = true
			band["flag"] = picked
			edit.text = picked
			dd.selected = 0
	)
	box.add_child(dd)

	var hint: Label = Label.new()
	hint.text = "Known: " + ", ".join(PackedStringArray(flags))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 9)
	box.add_child(hint)
	return box


func _band_jump_dropdown(band: Dictionary) -> Control:
	var dd: OptionButton = OptionButton.new()
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.add_item("(stay in round)")
	dd.set_item_metadata(0, "")
	var stored: String = str(band.get("jump_to", ""))
	var selected: int = 0
	for i: int in _node_choices.size():
		var c: Dictionary = _node_choices[i] as Dictionary
		dd.add_item(str(c.get("label", c.get("id", ""))))
		dd.set_item_metadata(i + 1, str(c.get("id", "")))
		if str(c.get("id", "")) == stored:
			selected = i + 1
	if stored != "" and selected == 0:
		dd.add_item("%s (missing)" % stored)
		dd.set_item_metadata(dd.item_count - 1, stored)
		selected = dd.item_count - 1
	dd.selected = selected
	dd.item_selected.connect(
		func(i: int) -> void:
			if _rebuilding_inspector:
				return
			_release_dirty = true
			band["jump_to"] = str(dd.get_item_metadata(i))
	)
	return dd


func _band_seek_timestamp_row(band: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var seek: int = int(band.get("seek_to_ms", -1))
	var enabled: bool = seek >= 0
	var mins: SpinBox = SpinBox.new()
	mins.min_value = 0
	mins.max_value = 999
	mins.step = 1
	mins.prefix = "m "
	mins.value = (seek / 60000) if enabled else 0
	mins.editable = enabled
	mins.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(mins)
	var secs: SpinBox = SpinBox.new()
	secs.min_value = 0
	secs.max_value = 59
	secs.step = 1
	secs.prefix = "s "
	secs.value = ((seek / 1000) % 60) if enabled else 0
	secs.editable = enabled
	secs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(secs)
	var sync := func() -> void:
		if _rebuilding_inspector:
			return
		if not mins.editable:
			return
		_release_dirty = true
		var ms: int = int(mins.value) * 60000 + int(secs.value) * 1000
		band["seek_to_ms"] = clampi(ms, 0, _full_ms)
		if _release_lane:
			_release_lane.set_bands(_release_windows)
	mins.value_changed.connect(func(_v: float) -> void: sync.call())
	secs.value_changed.connect(func(_v: float) -> void: sync.call())
	var tog: CheckButton = CheckButton.new()
	tog.text = "ON" if enabled else "OFF"
	tog.button_pressed = enabled
	tog.toggled.connect(
		func(on: bool) -> void:
			if _rebuilding_inspector:
				return
			_release_dirty = true
			tog.text = "ON" if on else "OFF"
			mins.editable = on
			secs.editable = on
			if on:
				var ms2: int = int(mins.value) * 60000 + int(secs.value) * 1000
				band["seek_to_ms"] = clampi(ms2, 0, _full_ms)
			else:
				band["seek_to_ms"] = -1
			if _release_lane:
				_release_lane.set_bands(_release_windows)
				_release_lane.set_selected(_selected_band)
	)
	row.add_child(tog)
	row.add_child(mins)
	row.add_child(secs)
	return row


func _band_signed_spin(band: Dictionary, key: String, cur: int, lo: int, hi: int) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = lo
	spin.max_value = hi
	spin.step = 1
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.value = cur
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(
		func(v: float) -> void:
			if _rebuilding_inspector:
				return
			_release_dirty = true
			band[key] = int(v)
	)
	return spin


func _build_event_inspector(ev: Dictionary, i: int) -> void:
	_inspector.add_child(_field_label("NAME"))
	var names: Array = _defs.get("names", []) as Array if _defs is Dictionary else []
	var name_dd: OptionButton = OptionButton.new()
	var cur: String = str(ev.get("name", ""))
	var sel_i: int = 0
	for ni: int in names.size():
		name_dd.add_item(str(names[ni]))
		if str(names[ni]) == cur:
			sel_i = ni
	if not names.has(cur) and cur != "":
		name_dd.add_item(cur)
		sel_i = name_dd.item_count - 1
	if names.is_empty() and cur == "":
		name_dd.add_item("(no defs)")
	name_dd.selected = sel_i
	UITheme.style_option_button(name_dd)
	name_dd.item_selected.connect(
		func(pick: int) -> void:
			_push_undo("name", false)
			var chosen: String = name_dd.get_item_text(pick)
			ev["name"] = chosen
			if names.has(chosen):
				var defaults: Dictionary = EventDefinitions.default_params_for(_defs, chosen)
				defaults["duration_ms"] = maxi(
					MIN_DURATION_MS, int(defaults.get("duration_ms", MIN_DURATION_MS))
				)
				ev["params"] = defaults
			_timeline.set_events(_events)
			_timeline.set_selected([i])
			_refresh_warnings()
			_refresh_inspector()
	)
	_inspector.add_child(name_dd)

	_inspector.add_child(_field_label("START (SECONDS)"))
	var start_spin: SpinBox = SpinBox.new()
	start_spin.min_value = 0
	start_spin.max_value = float(_full_ms) / 1000.0
	start_spin.step = 0.1
	start_spin.value = float(ev.get("time_ms", 0)) / 1000.0
	start_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(start_spin)
	start_spin.value_changed.connect(
		func(v: float) -> void:
			if _rebuilding_inspector:
				return
			_push_undo("time", true)
			var dur: int = maxi(
				MIN_DURATION_MS, int((ev.get("params", {}) as Dictionary).get("duration_ms", 0))
			)
			ev["time_ms"] = clampi(int(round(v * 1000.0)), 0, maxi(0, _full_ms - dur))
			_timeline.set_events(_events)
			_refresh_warnings()
	)
	_inspector.add_child(start_spin)

	if not (ev.get("params") is Dictionary):
		ev["params"] = {}
	var params: Dictionary = ev["params"]
	var defaults: Dictionary = EventDefinitions.default_params_for(_defs, str(ev.get("name", "")))
	for dk: Variant in defaults.keys():
		if not params.has(dk):
			params[dk] = defaults[dk]
	if int(params.get("duration_ms", 0)) < MIN_DURATION_MS:
		params["duration_ms"] = MIN_DURATION_MS

	_inspector.add_child(_field_label("DURATION (SECONDS)"))
	var dur_spin: SpinBox = SpinBox.new()
	dur_spin.min_value = float(MIN_DURATION_MS) / 1000.0
	dur_spin.max_value = float(_full_ms) / 1000.0
	dur_spin.step = 0.1
	dur_spin.value = float(params.get("duration_ms", MIN_DURATION_MS)) / 1000.0
	dur_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(dur_spin)
	dur_spin.value_changed.connect(
		func(v: float) -> void:
			if _rebuilding_inspector:
				return
			_push_undo("dur", true)
			var start: int = int(ev.get("time_ms", 0))
			params["duration_ms"] = clampi(
				int(round(v * 1000.0)), MIN_DURATION_MS, maxi(MIN_DURATION_MS, _full_ms - start)
			)
			_timeline.set_events(_events)
			_refresh_warnings()
	)
	_inspector.add_child(dur_spin)

	_inspector.add_child(_field_label("PARAMS"))
	var keys: Array = params.keys()
	keys.sort()
	for k: Variant in keys:
		var key: String = str(k)
		if key == "duration_ms":
			continue
		_inspector.add_child(_make_param_row(ev, params, key))

	var ew: Array = JourneyData.validate_journey_event(ev, _full_ms)
	if not ew.is_empty():
		var w: Label = Label.new()
		w.text = "⚠ " + "\n⚠ ".join(PackedStringArray(ew))
		w.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
		w.add_theme_font_size_override("font_size", 10)
		w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_inspector.add_child(w)


func _field_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	return lbl


func _is_percent_key(key: String) -> bool:
	var k: String = key.to_lower()
	return k.contains("intensity") or k.contains("boost") or k in ["volume_boost", "buzz_intensity"]


func _is_ms_key(key: String) -> bool:
	return key.ends_with("_ms")


func _make_param_row(_ev: Dictionary, params: Dictionary, key: String) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var cur: Variant = params.get(key, 0)
	if _is_percent_key(key) and (typeof(cur) == TYPE_FLOAT or typeof(cur) == TYPE_INT):
		box.add_child(_field_label("%s (%%)" % key.to_upper()))
		var spin: SpinBox = SpinBox.new()
		spin.min_value = -100
		spin.max_value = 200
		spin.step = 1
		spin.allow_greater = true
		spin.allow_lesser = true
		spin.value = float(cur) * 100.0
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_spin_box(spin)
		spin.value_changed.connect(
			func(v: float) -> void:
				if _rebuilding_inspector:
					return
				_push_undo("param", true)
				params[key] = v / 100.0
		)
		box.add_child(spin)
	elif _is_ms_key(key):
		box.add_child(_field_label("%s (SECONDS)" % key.to_upper()))
		var spin_s: SpinBox = SpinBox.new()
		spin_s.min_value = 0
		spin_s.max_value = 3600
		spin_s.step = 0.1
		spin_s.value = float(cur) / 1000.0
		spin_s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_spin_box(spin_s)
		spin_s.value_changed.connect(
			func(v: float) -> void:
				if _rebuilding_inspector:
					return
				_push_undo("param", true)
				params[key] = maxi(0, int(round(v * 1000.0)))
		)
		box.add_child(spin_s)
	elif typeof(cur) == TYPE_BOOL:
		box.add_child(_field_label(key.to_upper()))
		var tog: CheckButton = CheckButton.new()
		tog.text = "ON" if bool(cur) else "OFF"
		tog.button_pressed = bool(cur)
		tog.toggled.connect(
			func(on: bool) -> void:
				_push_undo("param", false)
				params[key] = on
				tog.text = "ON" if on else "OFF"
		)
		box.add_child(tog)
	elif typeof(cur) == TYPE_FLOAT:
		var unit: String = " (Hz)" if key.contains("freq") else ""
		box.add_child(_field_label(key.to_upper() + unit))
		var spin_f: SpinBox = SpinBox.new()
		spin_f.min_value = -1000000
		spin_f.max_value = 1000000
		spin_f.step = 0.01
		spin_f.allow_greater = true
		spin_f.allow_lesser = true
		spin_f.value = float(cur)
		spin_f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_spin_box(spin_f)
		spin_f.value_changed.connect(
			func(v: float) -> void:
				if _rebuilding_inspector:
					return
				_push_undo("param", true)
				params[key] = v
		)
		box.add_child(spin_f)
	else:
		var unit2: String = " (Hz)" if key.contains("freq") else ""
		box.add_child(_field_label(key.to_upper() + unit2))
		var spin_i: SpinBox = SpinBox.new()
		spin_i.min_value = -100000000
		spin_i.max_value = 100000000
		spin_i.step = 1
		spin_i.allow_greater = true
		spin_i.allow_lesser = true
		spin_i.value = int(cur) if str(cur).is_valid_int() else float(cur)
		spin_i.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_spin_box(spin_i)
		spin_i.value_changed.connect(
			func(v: float) -> void:
				if _rebuilding_inspector:
					return
				_push_undo("param", true)
				params[key] = int(v)
		)
		box.add_child(spin_i)
	return box


func _apply() -> void:
	# Normalize durations before commit
	for e: Variant in _events:
		var ev: Dictionary = e
		ev["round_id"] = _round_id
		var p: Dictionary = ev.get("params", {}) as Dictionary
		if not (ev.get("params") is Dictionary):
			ev["params"] = {}
			p = ev["params"]
		p["duration_ms"] = maxi(MIN_DURATION_MS, int(p.get("duration_ms", MIN_DURATION_MS)))
		ev["time_ms"] = clampi(
			int(ev.get("time_ms", 0)), 0, maxi(0, _full_ms - int(p["duration_ms"]))
		)
	applied.emit(_round_id, _snapshot())
	if _release_focus or _release_dirty or not _release_windows.is_empty():
		_ensure_open_ended_last()
		var fields: Dictionary = _release_cfg.duplicate(true)
		fields["release_enabled"] = true
		fields["release_mode"] = "windows"
		var bands_out: Array = []
		for b: Variant in _release_windows:
			bands_out.append((b as Dictionary).duplicate(true))
		fields["release_windows"] = JourneyData.normalize_release_windows(bands_out)
		release_applied.emit(_round_id, fields)
	_close()


func _cancel() -> void:
	cancelled.emit()
	_close()


func _close() -> void:
	if is_instance_valid(_modal):
		_modal.queue_free()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var k: InputEventKey = event
	if k.ctrl_pressed and k.keycode == KEY_Z:
		if k.shift_pressed:
			_redo_step()
		else:
			_undo_step()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_Y:
		_redo_step()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_DELETE or k.keycode == KEY_BACKSPACE:
		_delete_selected()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_ESCAPE:
		_cancel()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_SPACE:
		_toggle_play()
		get_viewport().set_input_as_handled()
