extends Control

# ---------------------------------------------------------------------------
# EndScreen.gd  –  Journey completion screen
# Reads stats from GameState.journey and displays a summary before returning
# the player to the Journey Select catalogue.
# ---------------------------------------------------------------------------

const COLOR_BG:           Color = Color(0.0,   0.0,   0.0,   1.0)
const COLOR_PANEL_BG:     Color = Color(0.055, 0.008, 0.086, 1.0)
const COLOR_PURPLE_BRIGHT:Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_PURPLE_MID:   Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_PURPLE_DARK:  Color = Color(0.176, 0.024, 0.259, 1.0)
const COLOR_MAGENTA:      Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:   Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_SEPARATOR:    Color = Color(0.698, 0.118, 1.0,   0.5)

const PANEL_HALF_W: int = 440
const BORDER_WIDTH: int = 3

@onready var _bg:           ColorRect     = $Background
@onready var _panel:        PanelContainer = $Panel
@onready var _vbox:         VBoxContainer  = $Panel/VBox
@onready var _title_lbl:    Label          = $Panel/VBox/TitleLabel
@onready var _journey_lbl:  Label          = $Panel/VBox/JourneyLabel
@onready var _divider:      HSeparator     = $Panel/VBox/StatsDivider
@onready var _stats_row:    HBoxContainer  = $Panel/VBox/StatsRow
@onready var _stat_rounds:  Label          = $Panel/VBox/StatsRow/StatRounds
@onready var _stat_actions: Label          = $Panel/VBox/StatsRow/StatActions
@onready var _stat_time:    Label          = $Panel/VBox/StatsRow/StatTime
@onready var _back_btn:     Button         = $Panel/VBox/BackButton


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate()
	_back_btn.pressed.connect(_on_back_pressed)


func _populate() -> void:
	var j: Dictionary = GameState.journey
	_journey_lbl.text  = (j.get("title", "Journey") as String).to_upper()
	_stat_rounds.text  = str(j.get("rounds", []).size()) + " ROUNDS"
	_stat_actions.text = str(j.get("total_actions", 0)) + " ACTIONS"
	var secs: int = (j.get("total_length_ms", 0) as int) / 1000
	_stat_time.text = _fmt(secs)


func _fmt(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	return "%d:%02d:%02d" % [h, m, s] if h > 0 else "%d:%02d" % [m, s]


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left   = 0
	_bg.offset_top    = 0
	_bg.offset_right  = 0
	_bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_panel.anchor_left   = 0.5
	_panel.anchor_right  = 0.5
	_panel.anchor_top    = 0.5
	_panel.anchor_bottom = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_HALF_W * 2, 0)

	_vbox.add_theme_constant_override("separation", 20)
	_stats_row.add_theme_constant_override("separation", 0)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color                   = COLOR_PANEL_BG
	s.border_color               = COLOR_PURPLE_BRIGHT
	s.border_width_left          = BORDER_WIDTH
	s.border_width_right         = BORDER_WIDTH
	s.border_width_top           = BORDER_WIDTH
	s.border_width_bottom        = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color               = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.5)
	s.shadow_size                = 16
	s.content_margin_left        = 48
	s.content_margin_right       = 48
	s.content_margin_top         = 48
	s.content_margin_bottom      = 48
	_panel.add_theme_stylebox_override("panel", s)

	_title_lbl.add_theme_color_override("font_color",    COLOR_PURPLE_BRIGHT)
	_title_lbl.add_theme_font_size_override("font_size", 36)
	_title_lbl.uppercase = true

	_journey_lbl.add_theme_color_override("font_color",    COLOR_MAGENTA)
	_journey_lbl.add_theme_font_size_override("font_size", 18)
	_journey_lbl.uppercase = true

	var sep: StyleBoxFlat = StyleBoxFlat.new()
	sep.bg_color           = COLOR_SEPARATOR
	sep.content_margin_top    = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	for lbl: Label in [_stat_rounds, _stat_actions, _stat_time]:
		lbl.add_theme_color_override("font_color",    COLOR_WHITE_SOFT)
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.uppercase = true

	_style_button(_back_btn, COLOR_PURPLE_BRIGHT)


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.uppercase = true

	var bs: StyleBoxFlat = StyleBoxFlat.new()
	bs.bg_color            = COLOR_PURPLE_DARK
	bs.border_color        = accent
	bs.border_width_left   = 2
	bs.border_width_right  = 2
	bs.border_width_top    = 2
	bs.border_width_bottom = 2
	bs.content_margin_left   = 20
	bs.content_margin_right  = 20
	bs.content_margin_top    = 14
	bs.content_margin_bottom = 14
	btn.add_theme_stylebox_override("normal", bs)

	var bs_hover: StyleBoxFlat = bs.duplicate()
	bs_hover.bg_color = COLOR_PURPLE_MID
	btn.add_theme_stylebox_override("hover", bs_hover)

	var bs_pressed: StyleBoxFlat = bs.duplicate()
	bs_pressed.bg_color = accent
	btn.add_theme_stylebox_override("pressed", bs_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
