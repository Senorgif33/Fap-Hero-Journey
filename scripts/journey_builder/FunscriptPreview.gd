class_name FunscriptPreview
extends Control

# ---------------------------------------------------------------------------
# FunscriptPreview
# In-builder preview overlay for a round's funscript. Plots the raw stroke curve
# and — when the round has stroke modifiers (boss / curse / boon) — an overlaid
# curve showing what those do to it, so the author can see the effect beforehand.
#
# The funscript graph (zoomable, horizontally scrollable, draggable playhead) and
# the modifier overlay work on any codec and on unsaved edits, since funscripts
# are tiny JSON read straight from disk. A synced video pane sits above the graph
# when the source is decodable (H.264 — EIRTeam's limit); otherwise the preview
# stays graph-only. Video clock ↔ playhead are kept in lockstep both ways.
#
# Open with:
#   FunscriptPreview.new().open(parent, funscript_path, video_path, modifiers, name, mod_label)
# The overlay frees itself on close.
# ---------------------------------------------------------------------------

var _graph: _Graph = null
var _modifiers: Array = []  # effect-shaped dicts (boss modifiers / curse / boon)
var _mod_label: String = "Boss Modifiers"  # what the modifiers are called for this round
var _show_modifiers: bool = true
var _caption: Label = null
# Live-tuning callback: func(ref_name, key, value) — set when the caller wants the preview's
# stroke-magnitude controls editable (effect rounds). Persists each change back to the round.
var _on_tune: Callable = Callable()

# Video preview (H.264 only — EIRTeam's decode limit). Stays hidden / graph-only
# when the source can't be decoded.
var _video: VideoStreamPlayer = null
var _video_pane: Control = null
var _video_aspect: AspectRatioContainer = null
var _aspect_set: bool = false
var _video_ok: bool = false
var _play_btn: Button = null
# Audio toggle: ON by default in trim mode (cut points often sit on musical
# beats / scene changes), muted by default in the plain preview (no surprise
# audio in the builder) — toggleable either way once a video is confirmed.
var _audio_btn: Button = null
var _audio_on: bool = false

# Trim mode (✂ SET IN PREVIEW): the footer gains IN/OUT/CLEAR/APPLY controls and
# the graph shades outside the window. `_on_trim_applied` is the round editor's
# callback (trim_in_ms, trim_out_ms); its validity is what enables the mode.
var _trim_mode: bool = false
var _trim_in: int = 0
var _trim_out: int = 0
var _on_trim_applied: Callable = Callable()
var _trim_label: Label = null


# Builds and shows the overlay over `parent`. `modifiers` are stroke-affecting
# effect dicts (each {kind, factor?/min?/max?}); pass [] for none. `mod_label`
# names them ("Boss Modifiers" / "Curse effects" / "Boon effects").
# video_path may be "" (graph-only) or a non-decodable codec (falls back too).
# Passing a valid `on_trim_applied` opens in TRIM mode, seeded with trim_in/out.
func open(
	parent: Control,
	funscript_path: String,
	video_path: String,
	modifiers: Array,
	round_name: String,
	mod_label: String = "Boss Modifiers",
	trim_in: int = 0,
	trim_out: int = 0,
	on_trim_applied: Callable = Callable(),
	on_tune: Callable = Callable()
) -> void:
	_modifiers = modifiers
	_mod_label = mod_label
	_on_tune = on_tune
	_trim_mode = on_trim_applied.is_valid()
	_trim_in = trim_in
	_trim_out = trim_out
	_on_trim_applied = on_trim_applied
	_build_ui(round_name)
	parent.add_child(self)
	move_to_front()  # sit above the builder's graph / side panel siblings

	var raw: Array = JourneyData.read_funscript_actions(funscript_path)
	_graph.set_raw(raw)
	_refresh_modified()
	_setup_video(video_path)
	if _trim_mode:
		_sync_trim()


func _build_ui(round_name: String) -> void:
	# Fill the parent and capture input so the builder behind is inert.
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP

	var backdrop: ColorRect = ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.72)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel: PanelContainer = PanelContainer.new()
	panel.anchor_left = 0.08
	panel.anchor_right = 0.92
	panel.anchor_top = 0.1
	panel.anchor_bottom = 0.9
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG_DEEP
	panel_style.border_color = UITheme.PURPLE_MID
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(6)
	panel_style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", panel_style)
	add_child(panel)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	panel.add_child(col)

	# Header: title + close.
	var header: HBoxContainer = HBoxContainer.new()
	var title: Label = Label.new()
	title.text = (
		"▶  FUNSCRIPT PREVIEW" + ("  —  " + round_name.to_upper() if round_name != "" else "")
	)
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn: Button = UITheme.make_icon_btn("✕ CLOSE", false, UITheme.MAGENTA)
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)
	col.add_child(header)

	# Video pane — hidden until a decodable video confirms it can play (see
	# _setup_video). When hidden the container skips it and the graph gets the room.
	# An AspectRatioContainer letterboxes the video inside the black pane so it
	# isn't stretched; its ratio is set from the real video size once known.
	var video_pane: PanelContainer = PanelContainer.new()
	var vp_style: StyleBoxFlat = StyleBoxFlat.new()
	vp_style.bg_color = Color(0, 0, 0, 1)
	video_pane.add_theme_stylebox_override("panel", vp_style)
	video_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	video_pane.size_flags_stretch_ratio = 1.4
	video_pane.clip_contents = true
	video_pane.visible = false
	_video_aspect = AspectRatioContainer.new()
	_video_aspect.ratio = 16.0 / 9.0
	_video_aspect.stretch_mode = AspectRatioContainer.STRETCH_FIT
	video_pane.add_child(_video_aspect)
	_video = VideoStreamPlayer.new()
	_video.expand = true
	_video.volume_db = -80.0  # start silent; _apply_audio sets the real state once confirmed
	_video_aspect.add_child(_video)
	_video_pane = video_pane
	col.add_child(video_pane)

	# The graph fills the remaining space and scrolls horizontally — the curve is
	# drawn at a fixed time scale (px/sec) rather than squashed to fit, so strokes
	# stay legible on long scripts.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph = _Graph.new()
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL  # fill the viewport height
	_graph.time_label_format = func(ms: float) -> String: return _format_time(ms)
	scroll.add_child(_graph)
	# Redraw on scroll so the floating Y-axis labels track the viewport's left edge.
	scroll.get_h_scroll_bar().value_changed.connect(func(_v: float) -> void: _graph.queue_redraw())
	col.add_child(scroll)

	# Scrubbing the graph seeks the video; the graph's playhead and the video clock
	# stay in lockstep (video → playhead in _process, playhead → video here).
	_graph.scrubbed.connect(_on_scrubbed)

	# Live stroke-magnitude tuning (effect rounds): sliders that rewrite the modifier
	# curve as you drag and persist back to the round. Only when the caller opted in.
	if _on_tune.is_valid():
		var strip: Control = _build_tuning_strip()
		if strip != null:
			col.add_child(strip)

	# Footer: play/pause + zoom + modifier toggle + caption.
	var footer: HBoxContainer = HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)

	# Play / pause (disabled until a video confirms it can play).
	_play_btn = UITheme.make_icon_btn("▶ PLAY", true, UITheme.SUCCESS)
	_play_btn.pressed.connect(_toggle_play)
	footer.add_child(_play_btn)

	# Audio toggle (also disabled until a video confirms).
	_audio_on = _trim_mode
	_audio_btn = UITheme.make_icon_btn("🔊", true, UITheme.PURPLE_BRIGHT)
	_audio_btn.tooltip_text = "Toggle preview audio"
	_audio_btn.pressed.connect(
		func() -> void:
			_audio_on = not _audio_on
			_apply_audio()
	)
	footer.add_child(_audio_btn)

	# Zoom controls — adjust the horizontal time scale of the graph.
	var zoom_out: Button = UITheme.make_icon_btn("ZOOM −", false, UITheme.PURPLE_BRIGHT)
	zoom_out.tooltip_text = "Zoom out (show more time)"
	zoom_out.pressed.connect(func() -> void: _graph.zoom_by(0.8))
	footer.add_child(zoom_out)
	var zoom_in: Button = UITheme.make_icon_btn("ZOOM +", false, UITheme.PURPLE_BRIGHT)
	zoom_in.tooltip_text = "Zoom in (show less time, more detail)"
	zoom_in.pressed.connect(func() -> void: _graph.zoom_by(1.25))
	footer.add_child(zoom_in)

	# Trim mode: place the window with the playhead, then apply back to the round.
	if _trim_mode:
		var set_in: Button = UITheme.make_icon_btn("⟦ IN", false, UITheme.TOXIC_GREEN)
		set_in.tooltip_text = "Set the trim start to the playhead"
		set_in.pressed.connect(
			func() -> void:
				_trim_in = int(_graph.get_playhead())
				_sync_trim()
		)
		footer.add_child(set_in)
		var set_out: Button = UITheme.make_icon_btn("OUT ⟧", false, UITheme.AMBER)
		set_out.tooltip_text = "Set the trim end to the playhead"
		set_out.pressed.connect(
			func() -> void:
				_trim_out = int(_graph.get_playhead())
				_sync_trim()
		)
		footer.add_child(set_out)
		var trim_clear: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		trim_clear.tooltip_text = "Clear the trim window (keep the full video)"
		trim_clear.pressed.connect(
			func() -> void:
				_trim_in = 0
				_trim_out = 0
				_sync_trim()
		)
		footer.add_child(trim_clear)
		var trim_apply: Button = UITheme.make_icon_btn("✔ APPLY TRIM", false, UITheme.SUCCESS)
		trim_apply.tooltip_text = "Write this window to the round (baked at the next save)"
		trim_apply.pressed.connect(
			func() -> void:
				_on_trim_applied.call(_trim_in, _trim_out)
				_close()
		)
		footer.add_child(trim_apply)
		_trim_label = Label.new()
		_trim_label.add_theme_font_size_override("font_size", 11)
		_trim_label.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)
		footer.add_child(_trim_label)

	if not _modifiers.is_empty():
		var toggle: CheckButton = CheckButton.new()
		toggle.text = "SHOW %s" % _mod_label.to_upper()
		toggle.button_pressed = true
		toggle.add_theme_font_size_override("font_size", 12)
		toggle.toggled.connect(
			func(on: bool) -> void:
				_show_modifiers = on
				_refresh_modified()
		)
		footer.add_child(toggle)
	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 11)
	_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_child(_caption)
	col.add_child(footer)


# Recomputes (or clears) the modifier-applied curve and updates the caption.
func _refresh_modified() -> void:
	if _modifiers.is_empty():
		_graph.set_modified([], false)
		_caption.text = "No %s on this round — showing the raw script." % _mod_label.to_lower()
		_caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
		return
	if not _show_modifiers:
		_graph.set_modified([], false)
		_caption.text = "Modifiers hidden. " + _modifier_summary()
		_caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
		return

	# `block` suppresses all device output — the script is ignored and the device
	# holds. Represent that as a flat neutral line rather than a transformed curve.
	if _has_block():
		_graph.set_modified(_flat_line(50.0), true)
		_caption.text = (
			"BLOCK active — the device ignores the script (holds position). " + _modifier_summary()
		)
		_caption.add_theme_color_override("font_color", UITheme.AMBER)
		return

	var raw: Array = _graph.get_raw()
	var modified: Array = []
	for i in raw.size():
		modified.append(Vector2((raw[i] as Vector2).x, _transform_pos_at(raw, i, _modifiers)))
	_graph.set_modified(modified, true)
	_caption.text = _modifier_summary()
	_caption.add_theme_color_override("font_color", UITheme.CYAN)


# A row of live-tuning controls, one group per stroke effect that has a magnitude (scale →
# stroke-length %, clamp → min/max). reverse/block carry no magnitude and are skipped.
# Returns null when nothing is tunable. Dragging a control rewrites the effect's params in
# `_modifiers` (redrawing the curve) and persists via `_on_tune`.
func _build_tuning_strip() -> Control:
	var strip: HBoxContainer = HBoxContainer.new()
	strip.add_theme_constant_override("separation", 16)
	var lead: Label = Label.new()
	lead.text = "TUNE"
	lead.add_theme_font_size_override("font_size", 11)
	lead.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	strip.add_child(lead)

	var any: bool = false
	for m: Dictionary in _modifiers:
		var specs: Array = JourneyData.effect_param_specs(String(m.get("kind", "")))
		if specs.is_empty():
			continue
		any = true
		var group: VBoxContainer = VBoxContainer.new()
		group.add_theme_constant_override("separation", 1)
		var name_lbl: Label = Label.new()
		name_lbl.text = String(m.get("name", m.get("kind", ""))).to_upper()
		name_lbl.add_theme_font_size_override("font_size", 10)
		name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		group.add_child(name_lbl)
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		for spec: Dictionary in specs:
			row.add_child(_make_tune_control(m, spec))
		group.add_child(row)
		strip.add_child(group)

	if not any:
		return null

	# Wrap the controls with a caption so the strip reads as interactive, not decorative.
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(strip)
	var caption: Label = Label.new()
	caption.text = "Drag to reshape the strokes — the curve updates live and saves to the round."
	caption.add_theme_font_size_override("font_size", 10)
	caption.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(caption)
	return box


# One SpinBox editing `m[spec.key]` in place: rewrites the modifier params, redraws the
# curve, and reports the change through _on_tune (which persists / prunes on the round).
func _make_tune_control(m: Dictionary, spec: Dictionary) -> Control:
	var key: String = String(spec.get("key", ""))
	var ctl: String = String(spec.get("ctl", ""))
	var ref: String = String(m.get("_ref", m.get("name", "")))
	var view_scale: float = 100.0 if ctl == "pct" else 1.0

	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var lab: Label = Label.new()
	lab.text = String(spec.get("label", key))
	lab.add_theme_font_size_override("font_size", 9)
	lab.add_theme_color_override("font_color", UITheme.SEPARATOR)
	box.add_child(lab)
	var spin: SpinBox = SpinBox.new()
	spin.min_value = float(spec.get("min", 0)) * view_scale
	spin.max_value = float(spec.get("max", 1)) * view_scale
	spin.step = float(spec.get("step", 1)) * view_scale
	spin.suffix = "%" if ctl == "pct" else ""
	spin.custom_minimum_size = Vector2(84, 0)
	UITheme.style_spin_box(spin)
	spin.set_value_no_signal(float(m.get(key, spec.get("min", 0))) * view_scale)
	spin.value_changed.connect(
		func(v: float) -> void:
			var real: float = v / view_scale
			var store_val: Variant = int(round(real)) if ctl in ["pos", "coins"] else real
			m[key] = store_val
			_refresh_modified()
			if _on_tune.is_valid():
				_on_tune.call(ref, key, store_val)
	)
	box.add_child(spin)
	return box


# ── Modifier math ────────────────────────────────────────────────────────────
#
# IMPORTANT: this MUST stay in lockstep with FunscriptPlayer.TransformPos (C#),
# which is the runtime source of truth. Same order — mirror → scale → clamp — and
# same formulas (scale uses each stroke's LOCAL centre = neighbour midpoint), so
# the preview shows exactly what the device will do. If you change the transform
# in one place, change it in both.
func _transform_pos_at(points: Array, i: int, effects: Array) -> float:
	# Mirror (reverse): an odd number of reverse effects flips the stroke; even
	# cancels. The runtime eases the flip over time — a static preview shows the
	# fully-settled result.
	var reverse_count: int = 0
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "reverse":
			reverse_count += 1
	var mirrored: bool = reverse_count % 2 == 1
	var pos: float = _mirror_one((points[i] as Vector2).y, mirrored)

	# Scale each stroke around its local centre (neighbour midpoint). All scale
	# effects multiply into one factor.
	var scale_factor: float = 1.0
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "scale" and e.has("factor"):
			scale_factor *= float(e["factor"])
	if not is_equal_approx(scale_factor, 1.0):
		var prev: float = _mirror_one((points[maxi(0, i - 1)] as Vector2).y, mirrored)
		var nxt: float = _mirror_one(
			(points[mini(points.size() - 1, i + 1)] as Vector2).y, mirrored
		)
		var center: float = (prev + nxt) * 0.5
		pos = center + (pos - center) * scale_factor

	# Clamp into a sub-range (stacks successively).
	for e: Dictionary in effects:
		if String(e.get("kind", "")) == "clamp":
			var mn: float = float(e.get("min", 0))
			var mx: float = float(e.get("max", 100))
			pos = mn + clampf(pos, 0.0, 100.0) / 100.0 * (mx - mn)

	return clampf(pos, 0.0, 100.0)


func _mirror_one(v: float, mirrored: bool) -> float:
	return 100.0 - v if mirrored else v


func _has_block() -> bool:
	for e: Dictionary in _modifiers:
		if String(e.get("kind", "")) == "block":
			return true
	return false


# A flat curve at `pos` spanning the raw script's time range.
func _flat_line(pos: float) -> Array:
	var raw: Array = _graph.get_raw()
	if raw.is_empty():
		return []
	var first: float = (raw[0] as Vector2).x
	var last: float = (raw[-1] as Vector2).x
	return [Vector2(first, pos), Vector2(last, pos)]


# Human summary of the active modifiers, e.g. "Modifiers: Scale ×1.2 · Clamp 50–100".
func _modifier_summary() -> String:
	var parts: Array = []
	for e: Dictionary in _modifiers:
		match String(e.get("kind", "")):
			"scale":
				parts.append("Scale ×%s" % str(e.get("factor", 1.0)))
			"clamp":
				parts.append("Clamp %d–%d" % [int(e.get("min", 0)), int(e.get("max", 100))])
			"reverse":
				parts.append("Mirror")
			"block":
				parts.append("Block")
			"blackout":
				parts.append("Blackout (video only)")
			_:
				parts.append(String(e.get("kind", "")).capitalize())
	return "Modifiers: " + "  ·  ".join(parts) if not parts.is_empty() else ""


func _format_time(ms: float) -> String:
	var total_s: int = int(ms / 1000.0)
	return "%d:%02d" % [total_s / 60, total_s % 60]


func _close() -> void:
	if _video != null:
		_video.stop()
	queue_free()


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	# Handled here in _input (before the GUI focus pass) and consumed, so the keys
	# can't reach the still-focused "Preview" button behind us — Space on that
	# button would otherwise open another preview.
	match event.keycode:
		KEY_ESCAPE:
			_close()
			get_viewport().set_input_as_handled()
		KEY_SPACE:
			_toggle_play()  # no-op when there's no playable video
			get_viewport().set_input_as_handled()


# ── Video ────────────────────────────────────────────────────────────────────


# Loads the round's video into the preview, mirroring GameLoop's runtime loader
# (ogv via ResourceLoader, mp4/mkv/webm via EIRTeam). EIRTeam only decodes H.264,
# so an undecodable source never starts playing — we then hide the pane and the
# preview stays graph-only, exactly the runtime's behaviour. The pane must be
# visible for the player to actually start, so we show it, then poll is_playing().
func _setup_video(path: String) -> void:
	if path == "":
		return
	var ext: String = path.get_extension().to_lower()
	if ext == "ogv":
		var stream: Resource = ResourceLoader.load(path)
		if stream is VideoStream:
			_video.stream = stream as VideoStream
		else:
			return
	elif ClassDB.class_exists("FFmpegVideoStream"):
		var stream: Resource = ClassDB.instantiate("FFmpegVideoStream")
		stream.set("file", ProjectSettings.globalize_path(path))
		_video.stream = stream as VideoStream
	else:
		return  # no decoder available

	# Must be visible to actually decode and report is_playing() — a hidden
	# VideoStreamPlayer won't start, so show the pane first, then confirm.
	_video_pane.visible = true
	_video.play()
	# EIRTeam opens the file asynchronously; poll up to ~1s for playback to start.
	var started: bool = false
	for _i in 60:
		await get_tree().process_frame
		if not is_inside_tree():
			return  # overlay closed during detection
		if _video.is_playing():
			started = true
			break
	if started:
		_video_ok = true
		_play_btn.disabled = false
		_audio_btn.disabled = false
		_apply_audio()
		_update_play_btn()
		_apply_aspect()
		set_process(true)
	else:
		_video_pane.visible = false  # decode failed — stay graph-only
		_video.stream = null


# Sets the letterbox aspect from the real video dimensions once a frame exists.
func _apply_aspect() -> void:
	if _aspect_set:
		return
	var tex: Texture2D = _video.get_video_texture()
	if tex != null and tex.get_size().x > 0.0 and tex.get_size().y > 0.0:
		_video_aspect.ratio = tex.get_size().x / tex.get_size().y
		_aspect_set = true


func _process(_delta: float) -> void:
	if not _video_ok:
		return
	if not _aspect_set:
		_apply_aspect()  # the video texture can appear a frame or two after playback starts
	# Drive the playhead from the video clock only while actively advancing
	# (playing AND not paused), and never while the author is scrubbing.
	if _is_advancing() and not _graph.is_dragging():
		_graph.set_playhead(_video.stream_position * 1000.0)
	_update_play_btn()  # keeps the label correct through pause / resume / natural end


# True while the video is actually advancing. is_playing() stays true while
# paused (it means "a stream is loaded"), so pause state must be checked too.
func _is_advancing() -> bool:
	return _video.is_playing() and not _video.paused


func _toggle_play() -> void:
	if not _video_ok:
		return
	if not _video.is_playing():
		# Finished (or stopped) — restart playback from the current playhead.
		_video.play()
		_video.stream_position = _graph.get_playhead() / 1000.0
		_video.paused = false
	else:
		_video.paused = not _video.paused
	_update_play_btn()


func _update_play_btn() -> void:
	_play_btn.text = "⏸ PAUSE" if _is_advancing() else "▶ PLAY"


func _apply_audio() -> void:
	_video.volume_db = 0.0 if _audio_on else -80.0
	_audio_btn.text = "🔊" if _audio_on else "🔇"


# Graph scrub → seek the video to that time.
func _on_scrubbed(ms: float) -> void:
	if _video_ok:
		_video.stream_position = ms / 1000.0


# Pushes the current trim window to the graph markers + the footer readout.
func _sync_trim() -> void:
	_graph.set_trim(float(_trim_in), float(_trim_out) if _trim_out > 0 else -1.0)
	if _trim_label:
		if _trim_in <= 0 and _trim_out <= 0:
			_trim_label.text = "NO TRIM"
		else:
			_trim_label.text = (
				"TRIM %s – %s"
				% [
					JourneyData.ms_to_mmss(_trim_in),
					JourneyData.ms_to_mmss(_trim_out) if _trim_out > 0 else "END",
				]
			)


# ===========================================================================
# Inner graph control — draws the curves + a draggable playhead.
# ===========================================================================
class _Graph:
	extends Control
	const PAD_LEFT: float = 34.0  # left gutter the floating Y labels sit over
	const PAD_RIGHT: float = 16.0
	const PAD_TOP: float = 10.0
	const PAD_BOTTOM: float = 22.0

	# Time scale: how many horizontal pixels represent one second. Adjustable via
	# the zoom buttons so strokes stay legible; the canvas grows wider than the
	# viewport and scrolls.
	const DEFAULT_PX_PER_SEC: float = 150.0
	const MIN_PX_PER_SEC: float = 20.0
	const MAX_PX_PER_SEC: float = 800.0
	const GRID_SECONDS: int = 5  # vertical gridline + time label every N seconds

	# Emitted while the author drags the playhead, so the preview can seek video.
	signal scrubbed(ms: float)

	var _px_per_sec: float = DEFAULT_PX_PER_SEC
	var _raw: Array = []  # Array[Vector2(at_ms, pos)]
	var _modified: Array = []  # Array[Vector2(at_ms, pos)], empty when hidden
	var _has_modified: bool = false
	var _length_ms: float = 1.0
	var _playhead_ms: float = 0.0
	var _dragging: bool = false
	# Trim markers (trim mode only): in >= 0 shows the IN line, out > 0 the OUT
	# line; the excluded regions outside the window are shaded. -1/-1 = off.
	var _trim_in_ms: float = -1.0
	var _trim_out_ms: float = -1.0
	var time_label_format: Callable = func(ms: float) -> String: return str(int(ms))

	func set_trim(in_ms: float, out_ms: float) -> void:
		_trim_in_ms = in_ms
		_trim_out_ms = out_ms
		queue_redraw()

	func set_raw(points: Array) -> void:
		_raw = points
		_length_ms = maxf(1.0, (points[-1] as Vector2).x) if not points.is_empty() else 1.0
		_playhead_ms = clampf(_playhead_ms, 0.0, _length_ms)
		_update_width()
		queue_redraw()

	func get_raw() -> Array:
		return _raw

	func is_dragging() -> bool:
		return _dragging

	func get_playhead() -> float:
		return _playhead_ms

	# Sets the playhead from an external clock (the video) and keeps it visible by
	# auto-scrolling. Distinct from a user scrub, which must NOT auto-scroll (the
	# author controls the scroll while dragging).
	func set_playhead(ms: float) -> void:
		_playhead_ms = clampf(ms, 0.0, _length_ms)
		_follow_playhead()
		queue_redraw()

	# Nudges the parent ScrollContainer so the playhead stays within the middle
	# band of the viewport during playback.
	func _follow_playhead() -> void:
		var p: Node = get_parent()
		if not (p is ScrollContainer):
			return
		var sc: ScrollContainer = p as ScrollContainer
		var view_w: float = sc.size.x
		var x: float = _time_to_x(_playhead_ms)
		var margin: float = view_w * 0.2
		if x < sc.scroll_horizontal + margin:
			sc.scroll_horizontal = int(x - margin)
		elif x > sc.scroll_horizontal + view_w - margin:
			sc.scroll_horizontal = int(x - view_w + margin)

	# Drive the scrollable width from the time scale. Min height is a floor; the
	# ScrollContainer stretches us to the viewport height via size flags.
	func _update_width() -> void:
		custom_minimum_size = Vector2(
			PAD_LEFT + PAD_RIGHT + (_length_ms / 1000.0) * _px_per_sec, 240.0
		)

	# Multiply the zoom by `factor`, keeping the playhead centred in the viewport.
	func zoom_by(factor: float) -> void:
		_px_per_sec = clampf(_px_per_sec * factor, MIN_PX_PER_SEC, MAX_PX_PER_SEC)
		_update_width()
		call_deferred("_center_on_playhead")  # after the container re-lays-out
		queue_redraw()

	func _center_on_playhead() -> void:
		var p: Node = get_parent()
		if p is ScrollContainer:
			(p as ScrollContainer).scroll_horizontal = int(
				_time_to_x(_playhead_ms) - (p as ScrollContainer).size.x / 2.0
			)
			queue_redraw()

	func set_modified(points: Array, has_modified: bool) -> void:
		_modified = points
		_has_modified = has_modified
		queue_redraw()

	func _plot_area() -> Rect2:
		return Rect2(
			PAD_LEFT, PAD_TOP, size.x - PAD_LEFT - PAD_RIGHT, size.y - PAD_TOP - PAD_BOTTOM
		)

	func _time_to_x(at_ms: float) -> float:
		return PAD_LEFT + (at_ms / 1000.0) * _px_per_sec

	func _to_px(p: Vector2, area: Rect2) -> Vector2:
		var y: float = area.position.y + (1.0 - clampf(p.y, 0.0, 100.0) / 100.0) * area.size.y
		return Vector2(_time_to_x(p.x), y)

	# Builds the polyline for the part of `points` inside the visible scroll
	# window (plus one point each side for edge continuity), so render cost stays
	# flat no matter how long the script is.
	func _curve_px(points: Array, area: Rect2) -> PackedVector2Array:
		var out: PackedVector2Array = PackedVector2Array()
		if points.is_empty():
			return out
		var sx: float = _scroll_x()
		var view_w: float = (
			(get_parent() as Control).size.x if get_parent() is ScrollContainer else size.x
		)
		var t_min: float = (sx - PAD_LEFT) / _px_per_sec * 1000.0
		var t_max: float = (sx + view_w - PAD_LEFT) / _px_per_sec * 1000.0
		var prev_in: bool = false
		for i in points.size():
			var p: Vector2 = points[i]
			if p.x >= t_min and p.x <= t_max:
				if not prev_in and i > 0:
					out.append(_to_px(points[i - 1], area))  # carry the off-screen left point
				out.append(_to_px(p, area))
				prev_in = true
			elif prev_in:
				out.append(_to_px(p, area))  # carry the first off-screen right point, then stop
				break
		return out

	# Horizontal scroll offset of our parent ScrollContainer (0 if none) — used to
	# pin the Y-axis labels to the left edge of the visible area as we scroll.
	func _scroll_x() -> float:
		var p: Node = get_parent()
		return float(p.scroll_horizontal) if p is ScrollContainer else 0.0

	func _draw() -> void:
		var area: Rect2 = _plot_area()
		var font: Font = ThemeDB.fallback_font

		# Plot background + frame.
		draw_rect(area, Color(0.04, 0.02, 0.06, 1.0), true)
		draw_rect(
			area,
			Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.5),
			false,
			1.0
		)

		# Vertical time gridlines + labels every GRID_SECONDS.
		var total_s: int = int(_length_ms / 1000.0)
		for s in range(0, total_s + 1, GRID_SECONDS):
			var gx: float = _time_to_x(s * 1000.0)
			draw_line(
				Vector2(gx, area.position.y),
				Vector2(gx, area.position.y + area.size.y),
				Color(1, 1, 1, 0.06),
				1.0
			)
			draw_string(
				font,
				Vector2(gx + 2, area.position.y + area.size.y + 14),
				time_label_format.call(s * 1000.0),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(1, 1, 1, 0.4)
			)

		# Horizontal gridlines at 0 / 25 / 50 / 75 / 100.
		for pos in [0, 25, 50, 75, 100]:
			var y: float = _to_px(Vector2(0.0, float(pos)), area).y
			draw_line(
				Vector2(area.position.x, y),
				Vector2(area.position.x + area.size.x, y),
				Color(1, 1, 1, 0.16 if pos == 50 else 0.06),
				1.0
			)

		if _raw.size() >= 2:
			# Raw curve (dim when a modified curve is overlaid, so the modified pops).
			var raw_col: Color = Color(
				UITheme.WHITE_SOFT.r,
				UITheme.WHITE_SOFT.g,
				UITheme.WHITE_SOFT.b,
				0.35 if _has_modified else 0.9
			)
			_draw_curve(_curve_px(_raw, area), raw_col, 1.5)
		elif _raw.is_empty():
			draw_string(
				font,
				Vector2(_scroll_x() + PAD_LEFT + 20, area.position.y + area.size.y * 0.5),
				"No funscript to preview",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				13,
				Color(1, 1, 1, 0.5)
			)

		# Modified curve on top.
		if _has_modified and _modified.size() >= 2:
			_draw_curve(_curve_px(_modified, area), UITheme.CYAN, 2.0)

		if _trim_in_ms >= 0.0 or _trim_out_ms > 0.0:
			_draw_trim(area, font)
		_draw_playhead(area, font)
		_draw_y_labels(area, font)

	# Shades everything outside the trim window and draws the IN / OUT marker
	# lines, so the author sees exactly what the bake will keep.
	func _draw_trim(area: Rect2, font: Font) -> void:
		var shade: Color = Color(0, 0, 0, 0.55)
		var right: float = area.position.x + area.size.x
		if _trim_in_ms > 0.0:
			var x_in: float = clampf(_time_to_x(_trim_in_ms), area.position.x, right)
			draw_rect(
				Rect2(area.position.x, area.position.y, x_in - area.position.x, area.size.y),
				shade,
				true
			)
		if _trim_out_ms > 0.0:
			var x_out: float = clampf(_time_to_x(_trim_out_ms), area.position.x, right)
			draw_rect(Rect2(x_out, area.position.y, right - x_out, area.size.y), shade, true)
		if _trim_in_ms >= 0.0:
			var xi: float = _time_to_x(maxf(_trim_in_ms, 0.0))
			draw_line(
				Vector2(xi, area.position.y),
				Vector2(xi, area.position.y + area.size.y),
				UITheme.TOXIC_GREEN,
				2.0
			)
			draw_string(
				font,
				Vector2(xi + 4, area.position.y + area.size.y - 6),
				"⟦ IN",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				10,
				UITheme.TOXIC_GREEN
			)
		if _trim_out_ms > 0.0:
			var xo: float = _time_to_x(_trim_out_ms)
			draw_line(
				Vector2(xo, area.position.y),
				Vector2(xo, area.position.y + area.size.y),
				UITheme.AMBER,
				2.0
			)
			draw_string(
				font,
				Vector2(xo - 34, area.position.y + area.size.y - 6),
				"OUT ⟧",
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				10,
				UITheme.AMBER
			)

	# Position labels pinned to the left edge of the visible area (over a small
	# backing strip so curves don't run through the text) as the plot scrolls.
	func _draw_y_labels(area: Rect2, font: Font) -> void:
		var sx: float = _scroll_x()
		draw_rect(
			Rect2(sx, area.position.y, PAD_LEFT, area.size.y), Color(0.04, 0.02, 0.06, 0.85), true
		)
		for pos in [0, 25, 50, 75, 100]:
			var y: float = _to_px(Vector2(0.0, float(pos)), area).y
			draw_string(
				font,
				Vector2(sx + 4, y + 4),
				str(pos),
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				9,
				Color(1, 1, 1, 0.45)
			)

	# Draws a curve as individual line segments. draw_polyline triangulates the
	# whole strip and breaks up (looks dashed) on the sharp V-turns a funscript is
	# full of; per-segment draw_line renders solid.
	func _draw_curve(pts: PackedVector2Array, color: Color, width: float) -> void:
		for i in range(1, pts.size()):
			draw_line(pts[i - 1], pts[i], color, width)

	func _draw_playhead(area: Rect2, font: Font) -> void:
		var x: float = _time_to_x(_playhead_ms)
		draw_line(
			Vector2(x, area.position.y),
			Vector2(x, area.position.y + area.size.y),
			UITheme.AMBER,
			1.0
		)
		var label: String = (
			time_label_format.call(_playhead_ms) + " / " + time_label_format.call(_length_ms)
		)
		draw_string(
			font,
			Vector2(x + 4, area.position.y + 12),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			UITheme.AMBER
		)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_dragging = event.pressed
			if event.pressed:
				_seek_to_x(event.position.x)
		elif event is InputEventMouseMotion and _dragging:
			_seek_to_x(event.position.x)

	func _seek_to_x(px: float) -> void:
		# px is in local (content) coordinates, so it maps straight through the scale.
		_playhead_ms = clampf((px - PAD_LEFT) / _px_per_sec * 1000.0, 0.0, _length_ms)
		scrubbed.emit(_playhead_ms)
		queue_redraw()
