extends Control

# ---------------------------------------------------------------------------
# EndScreen.gd  –  Journey completion screen
# Reads stats from GameState.journey and displays a summary before returning
# the player to the Journey Select catalogue.
# ---------------------------------------------------------------------------

const PANEL_HALF_W: int  = 440
const BORDER_WIDTH: int  = 3
const LOG_INDENT_PX: int = 14  # pixels of left indent per fork-nesting depth

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
@onready var _score_divider:    HSeparator    = $Panel/VBox/ScoreDivider
@onready var _score_title:      Label         = $Panel/VBox/ScoreSection/ScoreTitle
@onready var _round_breakdown:  VBoxContainer = $Panel/VBox/ScoreSection/RoundBreakdownContainer
@onready var _total_score_lbl: Label         = $Panel/VBox/ScoreSection/TotalScoreRow/TotalScoreLabel
@onready var _total_score_val: Label         = $Panel/VBox/ScoreSection/TotalScoreRow/TotalScoreValue
@onready var _back_btn:        Button        = $Panel/VBox/BackButton


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate()
	_back_btn.pressed.connect(_on_back_pressed)


func _populate() -> void:
	var j: Dictionary = GameState.Journey
	_journey_lbl.text = (j.get("title", "Journey") as String).to_upper()

	# Use the actual played rounds from the log (fork paths may differ from
	# the catalogue's top-level round list).
	var log: Array        = GameState.GetPlayLog()
	var played_rounds: Array = log.filter(func(e: Dictionary) -> bool: return e.get("type","") == "round")
	var total_actions: int   = ScoreService.GetRoundBreakdowns().reduce(
		func(acc: int, b: Dictionary) -> int: return acc + b.get("actions", 0), 0)
	var total_ms: int = played_rounds.reduce(
		func(acc: int, e: Dictionary) -> int:
			return acc + e.get("length_ms", 0) as int, 0)

	_stat_rounds.text  = str(played_rounds.size()) + " ROUNDS"
	_stat_actions.text = str(total_actions) + " ACTIONS"
	_stat_time.text    = _fmt(total_ms / 1000)
	_populate_score()


# Wraps `row` in a MarginContainer with `depth * LOG_INDENT_PX` of left padding.
# Returns `row` unchanged when depth is 0 to avoid an extra node allocation.
func _indent_row(row: Control, depth: int) -> Control:
	if depth == 0:
		return row
	var mc: MarginContainer = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", depth * LOG_INDENT_PX)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(row)
	return mc


func _populate_score() -> void:
	var breakdowns: Array  = ScoreService.GetRoundBreakdowns()
	var play_log:   Array  = GameState.GetPlayLog()
	# GDScript-side round names, populated by GameLoop._on_round_ended.
	# Used as the authoritative source for round names — bypasses any C# Dict
	# marshalling issues. See GameLoop._on_round_ended.
	var round_names: PackedStringArray = GameState.get_meta("_round_names", PackedStringArray()) as PackedStringArray
	_total_score_val.text  = str(ScoreService.TotalScore) + " PTS"

	var round_num: int = 0  # 1-based counter across all played rounds
	var bd_idx:    int = 0  # index into breakdowns (one per round in log order)

	for entry: Dictionary in play_log:
		match entry.get("type", ""):

			# ── Fork-choice header ────────────────────────────────────────────
			"fork_choice":
				var depth: int      = entry.get("depth", 0) as int
				var fork_title: String = entry.get("fork_title", "")
				var path_name:  String = entry.get("path_name",  "")

				var sep: HSeparator = HSeparator.new()
				var sep_s: StyleBoxFlat = StyleBoxFlat.new()
				sep_s.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.35)
				sep_s.content_margin_top    = 1
				sep_s.content_margin_bottom = 1
				sep.add_theme_stylebox_override("separator", sep_s)
				_round_breakdown.add_child(_indent_row(sep, depth))

				var hdr: HBoxContainer = HBoxContainer.new()
				hdr.add_theme_constant_override("separation", 8)
				var icon_lbl: Label = Label.new()
				icon_lbl.text = "⑂"
				icon_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				icon_lbl.add_theme_font_size_override("font_size", 14)
				hdr.add_child(icon_lbl)
				var hdr_lbl: Label = Label.new()
				if fork_title != "":
					hdr_lbl.text = "%s  →  %s" % [fork_title.to_upper(), path_name.to_upper()]
				else:
					hdr_lbl.text = "FORK  →  %s" % path_name.to_upper()
				hdr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				hdr_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				hdr_lbl.add_theme_font_size_override("font_size", 11)
				hdr_lbl.uppercase = true
				hdr.add_child(hdr_lbl)
				_round_breakdown.add_child(_indent_row(hdr, depth))

			# ── Round row ─────────────────────────────────────────────────────
			"round":
				var depth: int = entry.get("depth", 0) as int
				round_num += 1
				var r: Dictionary = breakdowns[bd_idx] if bd_idx < breakdowns.size() else {}
				bd_idx += 1

				var row: HBoxContainer = HBoxContainer.new()
				row.add_theme_constant_override("separation", 16)

				var name_lbl: Label = Label.new()
				# Round name comes from the GDScript-side log (set in GameLoop). Falls back
				# to the C# play-log entry, then to a numeric placeholder.
				var rname: String = ""
				if (round_num - 1) < round_names.size():
					rname = round_names[round_num - 1]
				if rname == "":
					rname = entry.get("name", "") as String
				if rname == "":
					rname = "Round %d" % round_num
				name_lbl.text = "R%d  %s" % [round_num, rname.to_upper()]
				name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				# Guaranteed minimum width — without this, OVERRUN_TRIM_ELLIPSIS lets
				# the HBoxContainer collapse the label to zero width and it disappears.
				name_lbl.custom_minimum_size = Vector2(160, 0)
				name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
				name_lbl.add_theme_font_size_override("font_size", 13)

				var time_lbl: Label = Label.new()
				var secs: int = (entry.get("length_ms", 0) as int) / 1000
				time_lbl.text = _fmt(secs)
				time_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				time_lbl.add_theme_font_size_override("font_size", 12)

				var act_lbl: Label = Label.new()
				act_lbl.text = "%d ACTIONS" % r.get("actions", 0)
				act_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				act_lbl.add_theme_font_size_override("font_size", 12)

				var detail_lbl: Label = Label.new()
				detail_lbl.text = "%dS %dM %dL" % [r.get("small", 0), r.get("medium", 0), r.get("large", 0)]
				detail_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				detail_lbl.add_theme_font_size_override("font_size", 12)

				var pts_lbl: Label = Label.new()
				pts_lbl.text = str(r.get("score", 0)) + " PTS"
				pts_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				pts_lbl.add_theme_font_size_override("font_size", 13)

				row.add_child(name_lbl)
				row.add_child(time_lbl)
				row.add_child(act_lbl)
				row.add_child(detail_lbl)
				row.add_child(pts_lbl)
				_round_breakdown.add_child(_indent_row(row, depth))


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

	# Viewport-bounded panel so it never overflows regardless of journey length.
	_panel.anchor_left   = 0.08
	_panel.anchor_right  = 0.92
	_panel.anchor_top    = 0.04
	_panel.anchor_bottom = 0.96
	_panel.offset_left   = 0.0
	_panel.offset_right  = 0.0
	_panel.offset_top    = 0.0
	_panel.offset_bottom = 0.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	_panel.custom_minimum_size = Vector2(PANEL_HALF_W * 2, 0)

	_vbox.add_theme_constant_override("separation", 20)
	_stats_row.add_theme_constant_override("separation", 0)

	var score_section: VBoxContainer = $Panel/VBox/ScoreSection
	score_section.add_theme_constant_override("separation", 12)
	# Let the score section expand to fill all space the panel gives it so the
	# breakdown scroll area uses as much vertical room as possible.
	score_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	$Panel/VBox/ScoreSection/TotalScoreRow.add_theme_constant_override("separation", 16)
	_round_breakdown.add_theme_constant_override("separation", 6)

	# Wrap the breakdown in a ScrollContainer so a long journey (many rounds +
	# fork headers) scrolls rather than growing the panel off screen.
	var breakdown_scroll: ScrollContainer = ScrollContainer.new()
	breakdown_scroll.size_flags_vertical         = Control.SIZE_EXPAND_FILL
	breakdown_scroll.horizontal_scroll_mode      = ScrollContainer.SCROLL_MODE_DISABLED
	# Generous minimum so a short journey still looks balanced; SIZE_EXPAND_FILL
	# above means it grows to use the full available height on larger panels.
	breakdown_scroll.custom_minimum_size         = Vector2(0, 220)
	score_section.remove_child(_round_breakdown)
	breakdown_scroll.add_child(_round_breakdown)
	score_section.add_child(breakdown_scroll)
	# Re-order: ScoreTitle(0), ScrollContainer(1), TotalScoreRow(2)
	score_section.move_child(breakdown_scroll, 1)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = UITheme.BG

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color                   = UITheme.PANEL_BG
	s.border_color               = UITheme.PURPLE_BRIGHT
	s.border_width_left          = BORDER_WIDTH
	s.border_width_right         = BORDER_WIDTH
	s.border_width_top           = BORDER_WIDTH
	s.border_width_bottom        = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color               = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size                = 16
	s.content_margin_left        = 48
	s.content_margin_right       = 48
	s.content_margin_top         = 48
	s.content_margin_bottom      = 48
	_panel.add_theme_stylebox_override("panel", s)

	_title_lbl.add_theme_color_override("font_color",    UITheme.PURPLE_BRIGHT)
	_title_lbl.add_theme_font_size_override("font_size", 36)
	_title_lbl.uppercase = true

	_journey_lbl.add_theme_color_override("font_color",    UITheme.MAGENTA)
	_journey_lbl.add_theme_font_size_override("font_size", 18)
	_journey_lbl.uppercase = true

	var sep: StyleBoxFlat = StyleBoxFlat.new()
	sep.bg_color           = UITheme.SEPARATOR
	sep.content_margin_top    = 1
	sep.content_margin_bottom = 1
	_divider.add_theme_stylebox_override("separator", sep)

	for lbl: Label in [_stat_rounds, _stat_actions, _stat_time]:
		lbl.add_theme_color_override("font_color",    UITheme.WHITE_SOFT)
		lbl.add_theme_font_size_override("font_size", 15)
		lbl.uppercase = true

	var score_sep: StyleBoxFlat = StyleBoxFlat.new()
	score_sep.bg_color           = UITheme.SEPARATOR
	score_sep.content_margin_top    = 1
	score_sep.content_margin_bottom = 1
	_score_divider.add_theme_stylebox_override("separator", score_sep)

	_score_title.add_theme_color_override("font_color",    UITheme.PURPLE_BRIGHT)
	_score_title.add_theme_font_size_override("font_size", 18)
	_score_title.uppercase = true

	_total_score_lbl.add_theme_color_override("font_color",    UITheme.WHITE_SOFT)
	_total_score_lbl.add_theme_font_size_override("font_size", 15)
	_total_score_lbl.uppercase = true

	_total_score_val.add_theme_color_override("font_color",    UITheme.MAGENTA)
	_total_score_val.add_theme_font_size_override("font_size", 15)
	_total_score_val.uppercase = true

	UITheme.style_button(_back_btn, UITheme.PURPLE_BRIGHT, 20, 14)
