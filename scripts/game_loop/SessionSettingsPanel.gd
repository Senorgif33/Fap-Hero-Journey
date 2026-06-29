class_name SessionSettingsPanel
extends Control

## In-play "Quick Settings" drawer (stroke range + delay), toggled by the "S" key from GameLoop. Slides
## in from the right like the inventory panel and is mutually exclusive with it. Adjustments persist to
## the same settings as Options and apply to the player live — no pause, no round restart.

signal closed

const PANEL_WIDTH: int = 320
const SLIDE_TIME: float = 0.18

var _panel: PanelContainer = null
var _range_slider: RangeSlider = null
var _delay_slider: HSlider = null
var _delay_value_lbl: Label = null


func _ready() -> void:
	# Root spans the viewport for the slide only; it must not block clicks to the game beneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_right = 1.0
	anchor_bottom = 1.0
	_build()
	_slide_in()


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG_DEEP
	ps.border_color = UITheme.PURPLE_BRIGHT
	ps.border_width_left = 3
	ps.content_margin_left = 18
	ps.content_margin_right = 18
	ps.content_margin_top = 18
	ps.content_margin_bottom = 18
	_panel.add_theme_stylebox_override("panel", ps)
	add_child(_panel)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	_panel.add_child(vb)

	# ── Header ────────────────────────────────────────────────────────────────
	var header: HBoxContainer = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	vb.add_child(header)

	var title: Label = Label.new()
	title.text = "QUICK SETTINGS"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	title.add_theme_font_size_override("font_size", 20)
	header.add_child(title)

	var close_btn: Button = Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	_style_close_button(close_btn)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	# ── Stroke range ──────────────────────────────────────────────────────────
	vb.add_child(_section_label("STROKE RANGE"))

	_range_slider = RangeSlider.new()
	_range_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_range_slider.set_range_values(SettingsService.get_range_min(), SettingsService.get_range_max())
	_range_slider.range_changed.connect(_on_range_changed)
	vb.add_child(_range_slider)

	vb.add_child(_hint_label("How much of the stroke the device uses.  ↑/↓ max · ←/→ min."))

	# ── Delay ─────────────────────────────────────────────────────────────────
	vb.add_child(_section_label("DELAY"))

	_delay_slider = HSlider.new()
	_delay_slider.min_value = -500
	_delay_slider.max_value = 500
	_delay_slider.step = 10
	_delay_slider.value = SettingsService.get_latency_offset_ms()
	_delay_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delay_slider.value_changed.connect(_on_delay_changed)
	vb.add_child(_delay_slider)

	_delay_value_lbl = Label.new()
	_delay_value_lbl.text = "%d ms" % SettingsService.get_latency_offset_ms()
	_delay_value_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	_delay_value_lbl.add_theme_font_size_override("font_size", 11)
	vb.add_child(_delay_value_lbl)

	(
		vb
		. add_child(
			_hint_label(
				"Shifts the funscript relative to the video for device/Bluetooth lag. Positive = device acts earlier."
			)
		)
	)


func _section_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	lbl.add_theme_font_size_override("font_size", 13)
	return lbl


func _hint_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	return lbl


# ── Apply (persist + push to the player live; same settings as Options) ────────


func _on_range_changed(lo: float, hi: float) -> void:
	SettingsService.set_range_min(int(lo))
	SettingsService.set_range_max(int(hi))
	SettingsService.save()
	FunscriptPlayer.SetRangeClamp(int(lo), int(hi))


func _on_delay_changed(v: float) -> void:
	_delay_value_lbl.text = "%d ms" % int(v)
	SettingsService.set_latency_offset_ms(int(v))
	SettingsService.save()
	FunscriptPlayer.SetLatencyOffset(int(v))


# Nudge the stroke range from GameLoop's arrow-key hotkeys (active only while this panel is open).
func nudge_range(d_min: int, d_max: int) -> void:
	var lo: int = clampi(int(_range_slider.lo) + d_min, 0, 99)
	var hi: int = clampi(int(_range_slider.hi) + d_max, lo + 1, 100)
	_range_slider.set_range_values(lo, hi)  # moves handles without re-emitting
	_on_range_changed(lo, hi)


# Re-read the sliders from settings (e.g. after the full Options screen changed them while this is open).
func resync() -> void:
	if _range_slider != null:
		_range_slider.set_range_values(
			SettingsService.get_range_min(), SettingsService.get_range_max()
		)
	if _delay_slider != null:
		_delay_slider.set_value_no_signal(SettingsService.get_latency_offset_ms())
		_delay_value_lbl.text = "%d ms" % SettingsService.get_latency_offset_ms()


# ── Slide animation (mirrors InventoryPanel) ───────────────────────────────────


func close() -> void:
	emit_signal("closed")
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", get_viewport_rect().size.x, SLIDE_TIME)
	tween.tween_callback(queue_free)


func _slide_in() -> void:
	var w: float = get_viewport_rect().size.x
	_panel.position.x = w
	var tween: Tween = create_tween()
	tween.tween_property(_panel, "position:x", w - PANEL_WIDTH, SLIDE_TIME)


# Thin delegate to UITheme — the canonical styling lives there.
func _style_close_button(btn: Button) -> void:
	UITheme.style_close_button(btn)
