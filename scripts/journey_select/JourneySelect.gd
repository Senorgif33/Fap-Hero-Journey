extends Control

# ---------------------------------------------------------------------------
# JourneySelect.gd
# Purple matrix theme. Scrollable catalogue grid of journey cards. Clicking
# a card opens a detail modal with stats parsed from journey.json and
# funscript files found in user://journeys/<folder>/<round-name>/.
# ---------------------------------------------------------------------------

const TOP_BAR_HEIGHT: int = 64
const GRID_TOP_MARGIN: int = 16
const GRID_PADDING: int = 40
const GRID_SEPARATION: int = 24
const CARD_MIN_WIDTH: int = 280
# Inset around the card grid so hover-scaled cards on the outer edge have room
# to expand without being clipped by the scroll viewport.
const HOVER_MARGIN: int = 12
const MODAL_MIN_WIDTH: int = 980
const MODAL_MIN_HEIGHT: int = 600
const MODAL_COVER_W: int = 280
const BORDER_WIDTH: int = 3

# Journeys root is configurable via Options → Journey Storage Location.
# Read via SettingsService.get_journeys_dir() so changes take effect next scan.

# Difficulty list is owned by JourneyData (canonical schema) — JourneyData.DIFFICULTIES.

const DIFF_COLORS: Dictionary = {
	"Easy": Color(0.35, 0.95, 0.35),
	"Medium": Color(0.95, 0.95, 0.25),
	"Hard": Color(1.0, 0.55, 0.1),
	"Very Hard": Color(1.0, 0.25, 0.05),
	"Extreme": Color(1.0, 0.1, 0.1),
	"Insane": Color(0.9, 0.05, 0.5),
}

const JourneyCardScene = preload("res://scenes/journey_select/JourneyCard.tscn")

@onready var _bg: ColorRect = $Background
@onready var _top_bar: HBoxContainer = $TopBar
@onready var _back_btn: Button = $TopBar/BackButton
@onready var _title_lbl: Label = $TopBar/TitleLabel
@onready var _sort_lbl: Label = $TopBar/SortContainer/SortLabel
@onready var _sort_name: Button = $TopBar/SortContainer/SortNameBtn
@onready var _sort_duration: Button = $TopBar/SortContainer/SortDurationBtn
@onready var _sort_actions: Button = $TopBar/SortContainer/SortActionsBtn
@onready var _scroll: ScrollContainer = $ScrollContainer
@onready var _grid: GridContainer = $ScrollContainer/Grid
@onready var _empty_lbl: Label = $EmptyLabel
@onready var _modal: Control = $DetailModal
@onready var _backdrop: ColorRect = $DetailModal/Backdrop
@onready var _modal_panel: PanelContainer = $DetailModal/ModalPanel
@onready var _modal_layout: HBoxContainer = $DetailModal/ModalPanel/ModalLayout
@onready var _cover_img: TextureRect = $DetailModal/ModalPanel/ModalLayout/CoverImage
@onready var _details_col: VBoxContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn
@onready var _modal_title: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalTitle
@onready var _modal_author: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalAuthor
@onready var _modal_diff: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDifficulty
@onready var _modal_desc: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ModalDescription
@onready
var _stat_rounds: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatRounds
@onready
var _stat_actions: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatActions
@onready
var _stat_length: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsRow/StatLength
@onready var _rounds_hdr: Label = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundsHeader
@onready
var _round_scroll: ScrollContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll
@onready
var _round_list: VBoxContainer = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundListScroll/RoundList
@onready
var _play_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/PlayButton
@onready
var _edit_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/EditButton
@onready
var _delete_btn: Button = $DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionRow/DeleteButton

# Dynamically created in _populate_modal when the current journey has a save.
# Inserted as the first child of the ActionRow so it sits before Play. Removed
# (and Play recoloured) when the modal switches to a journey without a save.
var _resume_btn: Button = null
# Extra ActionRow buttons for shave_cooldown items while Resume is locked.
var _cooldown_shave_btns: Array = []

# Separate scoreboard panel, floated to the right of the detail modal. Built once
# (lazily) and repositioned against the modal's right edge when the modal opens
# or the viewport resizes. _scoreboard_content holds the per-journey rows.
var _scoreboard_panel: PanelContainer = null
var _scoreboard_content: VBoxContainer = null
const SCOREBOARD_PANEL_W: int = 300
const SCOREBOARD_PANEL_GAP: int = 16

var _journeys: Array = []
var _sort_field: String = "name"
var _sort_asc: bool = true
var _current_journey: Dictionary = {}

# Set true for one call when the user chose "Open Anyway" past the newer-version warning, so
# the re-invoked play/resume/edit handler skips the gate instead of looping the dialog.
var _bypass_version_gate: bool = false

# Search / filter state
var _search_text: String = ""
var _diff_filter_idx: int = 0  # 0 = all, 1+ = DIFFICULTIES[idx-1]
var _tag_filter_idx: int = 0  # 0 = all, 1+ = TagRegistry.all()[idx-1]

# Dynamically-created filter widgets (added to _top_bar in _apply_layout)
var _search_field: LineEdit = null
var _diff_filter: OptionButton = null
var _tag_filter: OptionButton = null
var _count_label: Label = null


func _ready() -> void:
	MusicService.play()
	_apply_layout()
	_apply_theme()
	_connect_signals()
	_scan_journeys()
	_sort_and_populate()
	_modal.visible = false
	# Keep the floating scoreboard glued to the modal's right edge across resizes.
	get_viewport().size_changed.connect(_position_scoreboard_panel)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right = 1.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_left = 16
	_top_bar.offset_right = -16
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 10)

	# Header background strip — a dark, slightly translucent panel with an accent
	# underline that grounds the bar and separates it from the grid below.
	var bar_bg: Panel = Panel.new()
	var bar_style: StyleBoxFlat = StyleBoxFlat.new()
	bar_style.bg_color = UITheme.BAR_BG
	bar_style.border_width_bottom = 2
	bar_style.border_color = UITheme.PURPLE_MID
	bar_bg.add_theme_stylebox_override("panel", bar_style)
	bar_bg.anchor_right = 1.0
	bar_bg.anchor_bottom = 0.0
	bar_bg.offset_bottom = TOP_BAR_HEIGHT
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar_bg)
	# Place just before the TopBar so it renders behind the controls.
	move_child(bar_bg, _top_bar.get_index())

	# Journey count — sits right after the title; reflects the active filter.
	_count_label = Label.new()
	_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_top_bar.add_child(_count_label)
	_top_bar.move_child(_count_label, 2)

	# Search field — expands to fill space between the title and sort controls.
	# We create it here so it's available for _apply_theme(); move_child positions
	# it after BackButton(0) + TitleLabel(1) + CountLabel(2).
	_search_field = LineEdit.new()
	_search_field.placeholder_text = "Search journeys…"
	_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_field.custom_minimum_size = Vector2(180, 0)
	_top_bar.add_child(_search_field)
	_top_bar.move_child(_search_field, 3)

	# Difficulty filter dropdown
	_diff_filter = OptionButton.new()
	_diff_filter.custom_minimum_size = Vector2(172, 0)
	_diff_filter.add_item("ALL DIFFICULTIES")
	for d: String in JourneyData.DIFFICULTIES:
		_diff_filter.add_item(d.to_upper())
	_top_bar.add_child(_diff_filter)
	_top_bar.move_child(_diff_filter, 4)

	# Tag filter dropdown
	_tag_filter = OptionButton.new()
	_tag_filter.custom_minimum_size = Vector2(150, 0)
	_tag_filter.add_item("ALL TAGS")
	for tag_def: Dictionary in TagRegistry.all():
		_tag_filter.add_item((tag_def["label"] as String).to_upper())
	_top_bar.add_child(_tag_filter)
	_top_bar.move_child(_tag_filter, 5)

	_scroll.anchor_right = 1.0
	_scroll.anchor_bottom = 1.0
	_scroll.offset_top = TOP_BAR_HEIGHT + GRID_TOP_MARGIN
	_scroll.offset_left = GRID_PADDING
	_scroll.offset_right = -GRID_PADDING
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	_grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the grid in a MarginContainer so hover-scaled cards along the grid's
	# outer edge expand into this inset instead of being clipped by the scroll.
	var grid_mc: MarginContainer = MarginContainer.new()
	grid_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_mc.add_theme_constant_override("margin_left", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_right", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_top", HOVER_MARGIN)
	grid_mc.add_theme_constant_override("margin_bottom", HOVER_MARGIN)
	_scroll.remove_child(_grid)
	grid_mc.add_child(_grid)
	_scroll.add_child(grid_mc)

	_empty_lbl.anchor_right = 1.0
	_empty_lbl.anchor_bottom = 1.0
	_empty_lbl.offset_top = TOP_BAR_HEIGHT + GRID_TOP_MARGIN

	_scroll.resized.connect(_update_grid_columns)
	get_viewport().size_changed.connect(_update_grid_columns)
	_update_grid_columns.call_deferred()

	_modal.anchor_right = 1.0
	_modal.anchor_bottom = 1.0

	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0

	_modal_panel.anchor_left = 0.5
	_modal_panel.anchor_right = 0.5
	_modal_panel.anchor_top = 0.5
	_modal_panel.anchor_bottom = 0.5
	_modal_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_modal_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_modal_panel.custom_minimum_size = Vector2(MODAL_MIN_WIDTH, MODAL_MIN_HEIGHT)
	# Keep the floating scoreboard glued to the modal panel's actual rect. The
	# panel re-lays-out (and re-centres) for a frame or two after the modal opens
	# with fresh content, so positioning it once off a single-frame size read was
	# racy — it would intermittently latch a stale/huge size and stretch off
	# screen until reopened. Tracking item_rect_changed self-corrects every pass.
	_modal_panel.item_rect_changed.connect(_position_scoreboard_panel)

	_modal_layout.add_theme_constant_override("separation", 20)

	_cover_img.custom_minimum_size = Vector2(MODAL_COVER_W, 0)
	_cover_img.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_details_col.add_theme_constant_override("separation", 10)
	_details_col.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_round_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_round_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the round list in a MarginContainer so the rightmost column (coins)
	# always has breathing room and is never crowded by the vertical scrollbar.
	var round_list_mc: MarginContainer = MarginContainer.new()
	round_list_mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	round_list_mc.add_theme_constant_override("margin_right", 12)
	_round_scroll.remove_child(_round_list)
	round_list_mc.add_child(_round_list)
	_round_scroll.add_child(round_list_mc)


func _update_grid_columns() -> void:
	# Subtract the margin inset on both sides — the grid no longer spans the
	# full scroll width now that it lives inside a MarginContainer.
	var available: float = _scroll.size.x - 2.0 * HOVER_MARGIN
	if available <= 0:
		return
	var cols: int = max(1, int((available + GRID_SEPARATION) / (CARD_MIN_WIDTH + GRID_SEPARATION)))
	_grid.columns = cols


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


func _apply_theme() -> void:
	_bg.color = UITheme.BG

	# TopBar background via a Panel behind the HBoxContainer would need an extra
	# node; instead we apply a dark strip by styling the scroll container top offset.
	_style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	# Title no longer expands — the search field takes the flexible slot instead.
	_title_lbl.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	_style_label(_sort_lbl, UITheme.PURPLE_MID, 13, true)
	_style_label(_empty_lbl, UITheme.PURPLE_MID, 15, true)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_button(_back_btn, UITheme.MAGENTA)
	_style_button(_sort_name, UITheme.PURPLE_BRIGHT)
	_style_button(_sort_duration, UITheme.PURPLE_MID)
	_style_button(_sort_actions, UITheme.PURPLE_MID)
	_style_button(_play_btn, UITheme.PURPLE_BRIGHT)
	_style_button(_edit_btn, UITheme.PURPLE_MID)
	_style_button(_delete_btn, UITheme.DANGER)

	UITheme.style_line_edit(_search_field)
	UITheme.style_option_button(_diff_filter)
	UITheme.style_option_button(_tag_filter)
	_style_label(_count_label, UITheme.PURPLE_MID, 12, true)

	_style_modal_panel()

	_style_label(_modal_title, UITheme.PURPLE_BRIGHT, 22, true)
	_style_label(_modal_author, UITheme.PURPLE_MID, 13, false)
	_style_label(_modal_diff, UITheme.MAGENTA, 15, true)
	_style_label(_modal_desc, UITheme.WHITE_SOFT, 12, false)
	_modal_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_style_label(_stat_rounds, UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_actions, UITheme.WHITE_SOFT, 13, true)
	_style_label(_stat_length, UITheme.WHITE_SOFT, 13, true)

	_style_label(_rounds_hdr, UITheme.SEPARATOR, 11, true)

	var sep_style: StyleBoxFlat = StyleBoxFlat.new()
	sep_style.bg_color = UITheme.SEPARATOR
	for sep_path in [
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/StatsDivider",
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/RoundsDivider",
		"DetailModal/ModalPanel/ModalLayout/DetailsColumn/ActionDivider",
	]:
		var sep: HSeparator = get_node_or_null(sep_path)
		if sep:
			sep.add_theme_stylebox_override("separator", sep_style)

	_backdrop.color = Color(0.0, 0.0, 0.0, 0.85)


func _style_modal_panel() -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.5)
	s.shadow_size = 16
	s.content_margin_left = 20
	s.content_margin_right = 28
	s.content_margin_top = 28
	s.content_margin_bottom = 28
	_modal_panel.add_theme_stylebox_override("panel", s)


# Thin delegates to UITheme — the canonical styling lives there. Args preserve this screen's padding.
func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	UITheme.style_label(label, color, size, uppercase)


func _style_button(btn: Button, accent: Color) -> void:
	UITheme.style_button(btn, accent, 18, 12)


func _set_active_sort() -> void:
	var arrow: String = " ▲" if _sort_asc else " ▼"
	_style_button(
		_sort_name, UITheme.PURPLE_BRIGHT if _sort_field == "name" else UITheme.PURPLE_MID
	)
	_style_button(
		_sort_duration, UITheme.PURPLE_BRIGHT if _sort_field == "duration" else UITheme.PURPLE_MID
	)
	_style_button(
		_sort_actions, UITheme.PURPLE_BRIGHT if _sort_field == "actions" else UITheme.PURPLE_MID
	)
	_sort_name.text = ("NAME" + arrow) if _sort_field == "name" else "NAME"
	_sort_duration.text = ("DURATION" + arrow) if _sort_field == "duration" else "DURATION"
	_sort_actions.text = ("ACTIONS" + arrow) if _sort_field == "actions" else "ACTIONS"


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _modal.visible:
		_close_modal()
		get_viewport().set_input_as_handled()


func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_sort_name.pressed.connect(_on_sort_pressed.bind("name"))
	_sort_duration.pressed.connect(_on_sort_pressed.bind("duration"))
	_sort_actions.pressed.connect(_on_sort_pressed.bind("actions"))
	_backdrop.gui_input.connect(_on_backdrop_input)
	_play_btn.pressed.connect(_on_play_pressed)
	# Play plays start_journey at the embark point (not on press — a New Run shows
	# an overwrite confirm first), so mute its default click.
	UISound.mute_button(_play_btn)
	_edit_btn.pressed.connect(_on_edit_pressed)
	_delete_btn.pressed.connect(_on_delete_pressed)
	_search_field.text_changed.connect(
		func(text: String) -> void:
			_search_text = text.strip_edges()
			_sort_and_populate()
	)
	_diff_filter.item_selected.connect(
		func(idx: int) -> void:
			_diff_filter_idx = idx
			_sort_and_populate()
	)
	_tag_filter.item_selected.connect(
		func(idx: int) -> void:
			_tag_filter_idx = idx
			_sort_and_populate()
	)


func _on_sort_pressed(field: String) -> void:
	if _sort_field == field:
		_sort_asc = not _sort_asc
	else:
		_sort_field = field
		_sort_asc = true
	_sort_and_populate()


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_close_modal()


# Version gate: true when the running app is new enough for the selected journey (journeys
# stamp a MinVersion at save; older/unstamped ones always pass). See UpdateService.app_meets.
func _app_supports_current() -> bool:
	return UpdateService.app_meets(str(_current_journey.get("min_version", "")))


# Pops a "made for a newer version" warning. On "Open Anyway", sets the one-shot bypass and
# re-runs `retry` (the originating play/resume/edit handler), which then skips the gate.
func _warn_version_then(retry: Callable) -> void:
	var need: String = str(_current_journey.get("min_version", ""))
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Newer Version Needed"
	dialog.dialog_text = (
		"This journey was made for FHJ v%s or newer. You're on v%s, so it may not open or play correctly.\n\nUpdate from the main menu to be safe."
		% [need, UpdateService.current_version()]
	)
	dialog.ok_button_text = "OPEN ANYWAY"
	dialog.cancel_button_text = "CANCEL"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			_bypass_version_gate = true
			dialog.queue_free()
			retry.call()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()


func _on_play_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_play_pressed)
		return
	_bypass_version_gate = false
	# When a save exists, "Play" means New Run — confirm overwrite first so
	# the user doesn't lose progress they may have forgotten about.
	var folder_name: String = _current_journey.get("folder_name", "")
	if JourneySaveService.has_save(folder_name):
		var title: String = _current_journey.get("title", "this journey")
		var dialog: ConfirmationDialog = ConfirmationDialog.new()
		dialog.title = "Start a New Run?"
		dialog.dialog_text = (
			'You have a saved run for "%s". Starting a new run will permanently delete that save.\n\nUse the Resume button instead to continue where you left off.'
			% title
		)
		dialog.ok_button_text = "DELETE SAVE & PLAY"
		dialog.cancel_button_text = "CANCEL"
		dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
		dialog.confirmed.connect(_on_play_pressed_unguarded)
		dialog.canceled.connect(func() -> void: dialog.queue_free())
		add_child(dialog)
		dialog.popup_centered()
		return
	_on_play_pressed_unguarded()


func _on_edit_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_edit_pressed)
		return
	_bypass_version_gate = false
	JourneyBuilder.edit_journey = _current_journey
	Transition.change_scene("res://scenes/journey_builder/JourneyBuilder.tscn")


func _on_delete_pressed() -> void:
	if _current_journey.is_empty():
		return
	var title: String = _current_journey.get("title", "this journey")
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Delete Journey"
	dialog.dialog_text = (
		'Permanently delete "%s"?\n\nAll videos, funscripts, and cover images in the journey folder will be removed. This cannot be undone.'
		% title
	)
	dialog.ok_button_text = "DELETE"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			_confirm_delete()
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _confirm_delete() -> void:
	var folder: String = _current_journey.get("folder", "")
	if folder != "":
		JourneyData.delete_dir_recursive(folder)
	# Also drop the save file and scoreboard — a deleted journey shouldn't leave
	# orphan data in user:// that would resurface if the user creates a new
	# journey with the same folder name.
	JourneySaveService.delete_save(_current_journey.get("folder_name", ""))
	ScoreboardService.clear(_current_journey.get("folder_name", ""))
	_journeys.erase(_current_journey)
	_current_journey = {}
	_close_modal()
	_sort_and_populate()


# ---------------------------------------------------------------------------
# Journey scanning
# ---------------------------------------------------------------------------


# Scanning + journey.json parsing lives in JourneyScanner (RefCounted helper).
func _scan_journeys() -> void:
	_journeys = JourneyScanner.scan_all(SettingsService.get_journeys_dir())


# ---------------------------------------------------------------------------
# Grid population
# ---------------------------------------------------------------------------


func _sort_and_populate() -> void:
	_set_active_sort()
	# Apply search + difficulty filter first, then sort the surviving subset.
	var filtered: Array = _journeys.filter(func(j: Dictionary) -> bool: return _passes_filter(j))
	var asc: bool = _sort_asc
	match _sort_field:
		"name":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
					var cmp: int = (a["title"] as String).naturalnocasecmp_to(b["title"] as String)
					return cmp < 0 if asc else cmp > 0
			)
		"duration":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
					var va: int = a["total_length_ms"]
					var vb: int = b["total_length_ms"]
					return va < vb if asc else va > vb
			)
		"actions":
			filtered.sort_custom(
				func(a: Dictionary, b: Dictionary) -> bool:
					var va: int = a["total_actions"]
					var vb: int = b["total_actions"]
					return va < vb if asc else va > vb
			)
	_populate_grid(filtered)


# Returns true when journey `j` matches the current search text, difficulty
# filter, and tag filter.
func _passes_filter(j: Dictionary) -> bool:
	if _search_text != "":
		var title: String = (j.get("title", "") as String).to_lower()
		if not title.contains(_search_text.to_lower()):
			return false
	if _diff_filter_idx > 0:
		var required: String = JourneyData.DIFFICULTIES[_diff_filter_idx - 1]
		if j.get("difficulty", "") != required:
			return false
	if _tag_filter_idx > 0:
		var tags_all: Array = TagRegistry.all()
		if _tag_filter_idx - 1 < tags_all.size():
			var required_tag: String = tags_all[_tag_filter_idx - 1]["id"]
			if required_tag not in (j.get("tags", []) as Array):
				return false
	return true


func _populate_grid(journeys: Array) -> void:
	for child in _grid.get_children():
		child.queue_free()
	if journeys.is_empty():
		_empty_lbl.text = (
			"No journeys match your filter."
			if not _journeys.is_empty()
			else "No journeys yet.\nCreate one in the builder!"
		)
	_empty_lbl.visible = journeys.is_empty()

	# Header count — total catalogue size, or "shown OF total" while filtering.
	if _count_label != null:
		var total: int = _journeys.size()
		var shown: int = journeys.size()
		_count_label.text = (
			("%d JOURNEY%s" % [total, "" if total == 1 else "S"])
			if shown == total
			else "%d OF %d" % [shown, total]
		)

	var idx: int = 0
	for journey: Dictionary in journeys:
		var card: PanelContainer = JourneyCardScene.instantiate()
		_grid.add_child(card)
		card.setup(journey)
		card.selected.connect(_on_journey_selected.bind(journey))
		# Staggered fade/scale-in so the catalogue builds in. The per-card delay
		# is capped so a large catalogue still finishes quickly.
		card.animate_in(min(idx, 16) * 0.022)
		idx += 1


func _on_journey_selected(journey: Dictionary) -> void:
	UISound.journey()
	_current_journey = journey
	_populate_modal(journey)
	_open_modal()


# Fades the backdrop in and scales the panel up from 95% with a slight overshoot.
func _open_modal() -> void:
	_modal.visible = true
	_backdrop.modulate.a = 0.0
	_modal_panel.modulate.a = 0.0
	if _scoreboard_panel != null:
		_scoreboard_panel.modulate.a = 0.0
	# Wait one frame so the panel has its final size before computing the pivot.
	await get_tree().process_frame
	_modal_panel.pivot_offset = _modal_panel.size / 2.0
	_modal_panel.scale = Vector2(0.95, 0.95)
	_position_scoreboard_panel()
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop, "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "modulate:a", 1.0, 0.16)
	t.tween_property(_modal_panel, "scale", Vector2.ONE, 0.18).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_BACK
	)
	if _scoreboard_panel != null:
		t.tween_property(_scoreboard_panel, "modulate:a", 1.0, 0.16)


# Fades + shrinks the modal out, then hides it and resets the transform.
func _close_modal() -> void:
	if not _modal.visible:
		return
	var t: Tween = create_tween().set_parallel(true)
	t.tween_property(_backdrop, "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "modulate:a", 0.0, 0.12)
	t.tween_property(_modal_panel, "scale", Vector2(0.96, 0.96), 0.12)
	if _scoreboard_panel != null:
		t.tween_property(_scoreboard_panel, "modulate:a", 0.0, 0.12)
	await t.finished
	_modal.visible = false
	_modal_panel.scale = Vector2.ONE
	_modal_panel.modulate.a = 1.0
	_backdrop.modulate.a = 1.0


# ---------------------------------------------------------------------------
# Detail modal
# ---------------------------------------------------------------------------


func _populate_modal(journey: Dictionary) -> void:
	_modal_title.text = journey.get("title", "Unknown")
	_modal_author.text = "by " + (journey.get("author", "Unknown") as String)

	var diff: String = journey.get("difficulty", "Unknown")
	_modal_diff.text = "◆  " + diff.to_upper()
	var diff_color: Color = DIFF_COLORS.get(diff, UITheme.WHITE_SOFT)
	_modal_diff.add_theme_color_override("font_color", diff_color)

	# Tag chips — rebuilt each time the modal opens (named so the prior row,
	# if any, can be removed first).
	var old_tag_row: Node = _details_col.get_node_or_null("ModalTagRow")
	if old_tag_row:
		old_tag_row.free()
	var tag_ids: Array = journey.get("tags", [])
	if not tag_ids.is_empty():
		var tag_row: HFlowContainer = HFlowContainer.new()
		tag_row.name = "ModalTagRow"
		tag_row.add_theme_constant_override("h_separation", 6)
		tag_row.add_theme_constant_override("v_separation", 6)
		for id: String in tag_ids:
			tag_row.add_child(
				UITheme.make_tag_chip(TagRegistry.label_of(id), TagRegistry.color_of(id))
			)
		_details_col.add_child(tag_row)
		_details_col.move_child(tag_row, _modal_diff.get_index() + 1)

	var rounds: Array = journey.get("rounds", [])
	var total_rounds: int = journey.get("total_rounds", rounds.size())
	_stat_rounds.text = str(total_rounds) + " ROUNDS"
	_stat_actions.text = str(journey.get("total_actions", 0)) + " ACTIONS"
	var total_secs: int = (journey.get("total_length_ms", 0) as int) / 1000
	_stat_length.text = _format_duration(total_secs)

	var desc: String = journey.get("description", "")
	_modal_desc.text = desc
	_modal_desc.visible = desc != ""

	var cover_path: String = journey.get("cover_path", "")
	var cover_img: Image = JourneyData.load_image_smart(cover_path)
	_cover_img.texture = ImageTexture.create_from_image(cover_img) if cover_img else null

	for child in _round_list.get_children():
		child.queue_free()

	var shops_data: Array = journey.get("shops", [])

	# Column headers
	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 12)
	_round_list.add_child(hdr)
	for col in [
		["", 36, false],
		["ROUND", -1, false],
		["DURATION", 56, true],
		["ACTIONS", 72, true],
		["COINS", 72, true]
	]:
		var lbl: Label = Label.new()
		lbl.text = col[0]
		if col[1] == -1:
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			lbl.custom_minimum_size = Vector2(col[1], 0)
		if col[2]:
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.uppercase = true
		hdr.add_child(lbl)
	var hdr_line: HSeparator = HSeparator.new()
	var hdr_style: StyleBoxFlat = StyleBoxFlat.new()
	hdr_style.bg_color = Color(UITheme.SEPARATOR.r, UITheme.SEPARATOR.g, UITheme.SEPARATOR.b, 0.3)
	hdr_line.add_theme_stylebox_override("separator", hdr_style)
	_round_list.add_child(hdr_line)

	var forks_data: Array = journey.get("forks", [])
	var storyboards_data: Array = journey.get("storyboards", [])

	_add_seq_to_list(_round_list, rounds, shops_data, storyboards_data, forks_data, 0)

	# Resume vs Play UI. When a save exists for this journey, surface a Resume
	# button as the primary action and recolour Play to make it clear it'll
	# start a fresh run (overwriting the save). When no save exists, the
	# button row is the original Play / Edit / Delete trio.
	_refresh_resume_button(journey)

	# Local scoreboard — ranked past runs for this journey.
	_populate_scoreboard(journey)


const SCORE_MONTHS: Array = [
	"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
]


# Lazily builds the floating scoreboard panel (a styled card with a header and a
# scrollable content column) as a sibling of the modal panel under DetailModal.
func _ensure_scoreboard_panel() -> void:
	if _scoreboard_panel != null:
		return
	_scoreboard_panel = PanelContainer.new()
	_scoreboard_panel.name = "ScoreboardPanel"
	_scoreboard_panel.custom_minimum_size = Vector2(SCOREBOARD_PANEL_W, 0)
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT
	s.border_width_left = BORDER_WIDTH
	s.border_width_right = BORDER_WIDTH
	s.border_width_top = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 20
	s.content_margin_bottom = 20
	_scoreboard_panel.add_theme_stylebox_override("panel", s)

	_scoreboard_content = VBoxContainer.new()
	_scoreboard_content.add_theme_constant_override("separation", 6)
	_scoreboard_content.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_scoreboard_panel.add_child(_scoreboard_content)

	_modal.add_child(_scoreboard_panel)


# Rebuilds the floating HIGH SCORES panel from the journey's recorded runs
# (ranked by score). Called each modal open and after the player clears the board.
func _populate_scoreboard(journey: Dictionary) -> void:
	_ensure_scoreboard_panel()
	for child in _scoreboard_content.get_children():
		child.queue_free()

	var folder: String = journey.get("folder_name", "")
	var runs: Array = ScoreboardService.read_runs(folder)

	# Header: title + a Clear button (only when there's something to clear).
	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 8)
	var title: Label = Label.new()
	title.text = "HIGH SCORES"
	title.uppercase = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	title.add_theme_font_size_override("font_size", 13)
	hdr.add_child(title)
	if not runs.is_empty():
		var clear_btn: Button = Button.new()
		clear_btn.text = "CLEAR"
		clear_btn.focus_mode = Control.FOCUS_NONE
		clear_btn.add_theme_font_size_override("font_size", 10)
		clear_btn.add_theme_color_override("font_color", UITheme.DANGER)
		clear_btn.flat = true
		clear_btn.pressed.connect(_on_clear_scores_pressed)
		hdr.add_child(clear_btn)
	_scoreboard_content.add_child(hdr)

	var hdr_line: HSeparator = HSeparator.new()
	_scoreboard_content.add_child(hdr_line)

	if runs.is_empty():
		var empty: Label = Label.new()
		empty.text = "No runs yet — play it!"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_color_override("font_color", UITheme.PURPLE_MID)
		empty.add_theme_font_size_override("font_size", 11)
		_scoreboard_content.add_child(empty)
	else:
		for i in runs.size():
			_scoreboard_content.add_child(_make_score_row(i + 1, runs[i]))


# Places the scoreboard panel against the modal panel's right edge, matching its
# height. Driven by the modal panel's item_rect_changed (so it tracks every
# layout/centre pass), plus viewport resize and the initial open.
func _position_scoreboard_panel() -> void:
	if _scoreboard_panel == null or not _modal.visible:
		return
	_scoreboard_panel.custom_minimum_size = Vector2(SCOREBOARD_PANEL_W, _modal_panel.size.y)
	_scoreboard_panel.size = Vector2(SCOREBOARD_PANEL_W, _modal_panel.size.y)
	_scoreboard_panel.position = (
		_modal_panel.position + Vector2(_modal_panel.size.x + SCOREBOARD_PANEL_GAP, 0.0)
	)


# One ranked run row: rank · score · outcome badge · date.
func _make_score_row(rank: int, run: Dictionary) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var rank_lbl: Label = Label.new()
	rank_lbl.text = "%d." % rank
	rank_lbl.custom_minimum_size = Vector2(22, 0)
	rank_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	rank_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(rank_lbl)

	var score_lbl: Label = Label.new()
	score_lbl.text = _format_score(int(run.get("score", 0)))
	score_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	score_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	score_lbl.add_theme_font_size_override("font_size", 12)
	row.add_child(score_lbl)

	var outcome_lbl: Label = Label.new()
	if bool(run.get("completed", false)):
		outcome_lbl.text = "✓ COMPLETE"
		outcome_lbl.add_theme_color_override("font_color", UITheme.SUCCESS)
	else:
		outcome_lbl.text = (
			"✗ ROUND %d/%d" % [int(run.get("rounds_done", 0)), int(run.get("rounds_total", 0))]
		)
		outcome_lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
	outcome_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(outcome_lbl)

	var date_lbl: Label = Label.new()
	date_lbl.text = _format_short_date(str(run.get("date", "")))
	date_lbl.custom_minimum_size = Vector2(56, 0)
	date_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	date_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	date_lbl.add_theme_font_size_override("font_size", 11)
	row.add_child(date_lbl)

	return row


# Thousands-separated score, e.g. 14200 → "14,200".
func _format_score(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	out = s + out
	return ("-" + out) if n < 0 else out


# ISO datetime ("2026-06-12T14:30:25") → "Jun 12". Falls back to the raw date
# portion if parsing fails.
func _format_short_date(iso: String) -> String:
	if iso.is_empty():
		return ""
	var dt: Dictionary = Time.get_datetime_dict_from_datetime_string(iso, false)
	var month: int = int(dt.get("month", 0))
	var day: int = int(dt.get("day", 0))
	if month >= 1 and month <= 12 and day >= 1:
		return "%s %d" % [SCORE_MONTHS[month - 1], day]
	return iso.split("T")[0]


# Confirms, then wipes the current journey's recorded runs and refreshes the
# section in place.
func _on_clear_scores_pressed() -> void:
	if _current_journey.is_empty():
		return
	var title: String = _current_journey.get("title", "this journey")
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Clear Run History"
	dialog.dialog_text = 'Clear all recorded runs for "%s"?\n\nThis cannot be undone.' % title
	dialog.ok_button_text = "CLEAR"
	dialog.get_ok_button().add_theme_color_override("font_color", UITheme.DANGER)
	dialog.confirmed.connect(
		func() -> void:
			ScoreboardService.clear(_current_journey.get("folder_name", ""))
			_populate_scoreboard(_current_journey)
			dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


# Creates or removes the Resume button based on whether the current journey
# has a save. Idempotent — safe to call every time the modal opens.
func _refresh_resume_button(journey: Dictionary) -> void:
	var folder_name: String = journey.get("folder_name", "")
	var has_save: bool = JourneySaveService.has_save(folder_name)
	var cooldown_locked: bool = (
		has_save and JourneySaveService.is_cooldown_active(folder_name)
	)

	if has_save:
		if _resume_btn == null:
			_resume_btn = Button.new()
			_resume_btn.text = "▶  RESUME"
			_style_button(_resume_btn, UITheme.AMBER)
			_resume_btn.pressed.connect(_on_resume_pressed)
			var action_row: HBoxContainer = _play_btn.get_parent()
			action_row.add_child(_resume_btn)
			action_row.move_child(_resume_btn, _play_btn.get_index())
			# Resume plays start_journey at the embark point; mute its default click
			# (after add_child, which is where the global wiring hooks it).
			UISound.mute_button(_resume_btn)
		if cooldown_locked:
			var remain: String = JourneySaveService.format_cooldown_remaining(folder_name)
			_resume_btn.text = "⏳  LOCKED  %s" % remain
			_resume_btn.disabled = true
			_style_button(_resume_btn, UITheme.DANGER)
			_offer_cooldown_shave_buttons(folder_name)
		else:
			_resume_btn.text = "▶  RESUME"
			_resume_btn.disabled = false
			_style_button(_resume_btn, UITheme.AMBER)
			_clear_cooldown_shave_buttons()
		_play_btn.text = "↻  NEW RUN"
		_style_button(_play_btn, UITheme.PURPLE_MID)
	else:
		if _resume_btn != null:
			_resume_btn.queue_free()
			_resume_btn = null
		_clear_cooldown_shave_buttons()
		_play_btn.text = "▶  PLAY"
		_style_button(_play_btn, UITheme.PURPLE_BRIGHT)


func _clear_cooldown_shave_buttons() -> void:
	for b: Variant in _cooldown_shave_btns:
		if is_instance_valid(b):
			(b as Node).queue_free()
	_cooldown_shave_btns.clear()


# When Resume is cooldown-locked, offer shave items from save inventory charges
# and from unlocked modifiers (Inferno PPU amulet / psychic divorce).
func _offer_cooldown_shave_buttons(folder_name: String) -> void:
	_clear_cooldown_shave_buttons()
	var save_data: Dictionary = JourneySaveService.read_save(folder_name)
	var action_row: HBoxContainer = _play_btn.get_parent()
	var seen: Dictionary = {}
	var candidates: Array = []

	for entry: Variant in save_data.get("inventory", []) as Array:
		if entry is Dictionary:
			candidates.append({"src": "charge", "item": entry})
	for uid: Variant in save_data.get("unlocked", []) as Array:
		var id: String = str(uid)
		if id == "":
			continue
		var data: Dictionary = InventoryService.GetItemData(id)
		if not data.is_empty():
			candidates.append({"src": "unlocked", "item": data})

	for c: Variant in candidates:
		var wrap: Dictionary = c
		var item: Dictionary = wrap.get("item", {})
		if str(item.get("kind", "")) != "shave_cooldown":
			continue
		var id: String = str(item.get("id", ""))
		if id == "" or seen.has(id):
			continue
		seen[id] = true
		var hours: int = int(item.get("shave_hours", 24))
		var price: int = int(item.get("price", 0))
		var btn: Button = Button.new()
		var label: String = str(item.get("name", id)).to_upper()
		if price > 0 and str(wrap.get("src", "")) == "unlocked":
			btn.text = "✧  %s (−%dh, ♦ %d)" % [label, hours, price]
		else:
			btn.text = "✧  %s (−%dh)" % [label, hours]
		_style_button(btn, UITheme.PURPLE_BRIGHT)
		btn.pressed.connect(
			_on_cooldown_shave_pressed.bind(folder_name, id, hours, str(wrap.get("src", "charge")), price)
		)
		action_row.add_child(btn)
		if _resume_btn != null:
			action_row.move_child(btn, _resume_btn.get_index() + 1)
		UISound.mute_button(btn)
		_cooldown_shave_btns.append(btn)


func _on_cooldown_shave_pressed(
	folder_name: String, item_id: String, hours: int, src: String, price: int
) -> void:
	var save_data: Dictionary = JourneySaveService.read_save(folder_name)
	if save_data.is_empty():
		return
	var until: int = int(save_data.get("cooldown_until", 0))
	if until <= 0 or hours <= 0:
		return

	if src == "unlocked":
		var unlocked: Array = (save_data.get("unlocked", []) as Array).duplicate()
		var idx: int = unlocked.find(item_id)
		if idx < 0:
			return
		var coins: int = int(save_data.get("coins", 0))
		if price > 0 and coins < price:
			return
		if price > 0:
			save_data["coins"] = coins - price
		unlocked.remove_at(idx)
		# Amulet is single-use; Psychic stays re-unlockable via shop but this
		# consume matches ActivateUnlocked amulet behavior. Psychic: remove too
		# so one shave per unlock (rebuy/re-unlock at shop).
		save_data["unlocked"] = unlocked
	else:
		var inv: Array = (save_data.get("inventory", []) as Array).duplicate()
		var removed: bool = false
		for i in range(inv.size()):
			var entry: Variant = inv[i]
			if entry is Dictionary and str((entry as Dictionary).get("id", "")) == item_id:
				inv.remove_at(i)
				removed = true
				break
		if not removed:
			return
		save_data["inventory"] = inv

	save_data["cooldown_until"] = maxi(0, until - hours * 3600)
	if not JourneySaveService.write_save(folder_name, save_data):
		return
	if not _current_journey.is_empty():
		_refresh_resume_button(_current_journey)


# Loads the save file for the current journey, restores game state into the
# autoload services, and transitions to the gameplay scene. Bypasses the
# normal StartJourney path so the saved sequence (including any fork choices
# already made) is preserved.
#
# Saves are single-use by design: the file is deleted as part of the resume
# so the player has to actively earn a new save point (reach a checkpoint
# round or use The Safe Word) before they can quit-and-resume again. This
# keeps the save model thematically consistent — checkpoints are recoveries
# you commit to, not safety nets you indefinitely fall back on.
func _on_resume_pressed() -> void:
	if _current_journey.is_empty():
		return
	if not _bypass_version_gate and not _app_supports_current():
		_warn_version_then(_on_resume_pressed)
		return
	_bypass_version_gate = false
	var folder_name: String = _current_journey.get("folder_name", "")
	if JourneySaveService.is_cooldown_active(folder_name):
		var remain: String = JourneySaveService.format_cooldown_remaining(folder_name)
		# Button should already be disabled; keep a hard gate anyway.
		push_warning("JourneySelect: resume blocked — cooldown %s remaining" % remain)
		_refresh_resume_button(_current_journey)
		return
	var save_data: Dictionary = JourneySaveService.read_save(folder_name)
	if save_data.is_empty():
		# Save vanished between modal open and Resume click (deleted in another
		# window?). Fall back to a fresh start so the user isn't stuck.
		push_warning("JourneySelect: save missing or unreadable — starting fresh")
		_on_play_pressed_unguarded()
		return

	# The runtime walks the journey GRAPH (parse_graph migrates legacy journeys on the
	# fly); _current_journey stays the catalogue model for the detail panel.
	var play_journey: Dictionary = JourneyScanner.parse_graph(
		_current_journey.get("folder", ""), _current_journey.get("folder_name", "")
	)
	GameState.LoadFromSave(play_journey, save_data)
	CoinService.SetBalance(int(save_data.get("coins", 0)))
	(
		ScoreService
		. LoadFromSave(
			{
				"score": save_data.get("score", 0),
				"strokes": save_data.get("total_actions", 0),
			}
		)
	)
	# Inventory restoration — utility charges + unlocked modifiers. Active
	# effects are not carried (deliberate; see InventoryService.LoadFromSave).
	# Economy mode must be set BEFORE load so PPU migrates/loads unlocks correctly.
	InventoryService.SetUnlockPayPerUse(bool(play_journey.get("unlock_pay_per_use", false)))
	InventoryService.LoadFromSave(save_data.get("inventory", []) as Array)
	InventoryService.LoadUnlockedFromSave(save_data.get("unlocked", []) as Array)
	# Restore the round-names log so the end-screen breakdown is complete.
	var names: PackedStringArray = PackedStringArray()
	for n in save_data.get("round_names", []) as Array:
		names.append(str(n))
	GameState.set_meta("_round_names", names)
	# Restore the route trail so the end-screen route recap spans the whole
	# run, not just the resumed half (old saves load as an empty trail).
	var trail: Array = []
	for t in save_data.get("route_trail", []) as Array:
		trail.append(str(t))
	GameState.set_meta("_route_trail", trail)

	# Consume the save NOW (before the transition). If the player quits at any
	# point in the resumed run without writing a fresh save, the journey is
	# back to fresh-start state in the catalogue.
	JourneySaveService.delete_save(folder_name)

	# Handshake with GameLoop._ready — without this, GameLoop would treat
	# the scene change as a fresh start and Reset() each service, wiping
	# all the state we just restored from the save record.
	GameState.set_meta("_resuming", true)
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Internal: starts a fresh journey without any save-overwrite check. Used by
# both the new-run path (after the user confirms overwrite) and the fallback
# path when a save is unreadable.
func _on_play_pressed_unguarded() -> void:
	JourneySaveService.delete_save(_current_journey.get("folder_name", ""))
	var play_journey: Dictionary = JourneyScanner.parse_graph(
		_current_journey.get("folder", ""), _current_journey.get("folder_name", "")
	)
	GameState.StartJourney(play_journey)
	UISound.start_journey()
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# ---------------------------------------------------------------------------
# Recursive sequence renderer
# ---------------------------------------------------------------------------

# Builds and inserts interleaved rows for rounds/shops/storyboards/forks into
# `list`. `indent` is the nesting depth (0 = top level); each level adds
# INDENT_PX pixels of left margin via a MarginContainer wrapper.
const INDENT_PX: int = 16


func _add_seq_to_list(
	list: VBoxContainer, rounds: Array, shops: Array, storyboards: Array, forks: Array, indent: int
) -> void:
	var seq: Array = []
	for rd: Dictionary in rounds:
		seq.append({"type": "round", "data": rd, "key": (rd.get("order", 0) as int) * 3})
	for sb: Dictionary in storyboards:
		seq.append({"type": "storyboard", "data": sb, "key": (sb.get("order", 0) as int) * 3})
	for sh: Dictionary in shops:
		seq.append({"type": "shop", "data": sh, "key": (sh.get("after_order", 0) as int) * 3 + 1})
	for fk: Dictionary in forks:
		seq.append({"type": "fork", "data": fk, "key": (fk.get("after_order", 0) as int) * 3 + 2})
	seq.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool: return (a["key"] as int) < (b["key"] as int)
	)

	for item: Dictionary in seq:
		match item["type"]:
			"fork":
				_add_fork_to_list(list, item["data"], indent)
			"shop":
				var shop: Dictionary = item["data"]
				var shop_row: HBoxContainer = HBoxContainer.new()
				shop_row.add_theme_constant_override("separation", 8)
				var shop_lbl: Label = Label.new()
				var shop_title: String = shop.get("title", "")
				if shop_title != "":
					shop_lbl.text = "  ◆  SHOP: %s" % shop_title.to_upper()
				else:
					shop_lbl.text = "  ◆  SHOP"
				shop_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				shop_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				shop_lbl.add_theme_font_size_override("font_size", 11)
				shop_row.add_child(shop_lbl)
				list.add_child(_indent_wrap(shop_row, indent))
			"storyboard":
				var storyboard_data: Dictionary = item["data"]
				var sb_row: HBoxContainer = HBoxContainer.new()
				sb_row.add_theme_constant_override("separation", 8)
				var sb_lbl: Label = Label.new()
				var sb_line_count: int = (storyboard_data.get("lines", []) as Array).size()
				sb_lbl.text = (
					"  ◈  STORYBOARD  (%d LINE%s)"
					% [sb_line_count, "S" if sb_line_count != 1 else ""]
				)
				sb_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				sb_lbl.add_theme_color_override("font_color", Color(0.10, 0.85, 0.90, 1.0))
				sb_lbl.add_theme_font_size_override("font_size", 11)
				sb_row.add_child(sb_lbl)
				var sb_coins: int = storyboard_data.get("coins", 0)
				if sb_coins > 0:
					var sb_coins_lbl: Label = Label.new()
					sb_coins_lbl.text = "♦ %d" % sb_coins
					sb_coins_lbl.custom_minimum_size = Vector2(72, 0)
					sb_coins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
					sb_coins_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
					sb_coins_lbl.add_theme_font_size_override("font_size", 12)
					sb_row.add_child(sb_coins_lbl)
				list.add_child(_indent_wrap(sb_row, indent))
			"round":
				var round_data: Dictionary = item["data"]
				var order: int = round_data.get("order", 0)
				var is_boss: bool = round_data.get("round_type", "normal") == "boss"
				var row: HBoxContainer = HBoxContainer.new()
				row.add_theme_constant_override("separation", 12)
				var order_lbl: Label = Label.new()
				order_lbl.text = "%02d." % order
				order_lbl.custom_minimum_size = Vector2(36, 0)
				order_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				order_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(order_lbl)
				var name_lbl: Label = Label.new()
				var round_name_text: String = (round_data.get("name", "") as String).to_upper()
				name_lbl.text = ("⚔  " + round_name_text) if is_boss else round_name_text
				name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				name_lbl.add_theme_color_override(
					"font_color", UITheme.DANGER if is_boss else UITheme.WHITE_SOFT
				)
				name_lbl.add_theme_font_size_override("font_size", 13)
				row.add_child(name_lbl)
				var dur_secs: int = (round_data.get("length_ms", 0) as int) / 1000
				var dur_lbl: Label = Label.new()
				dur_lbl.text = _format_duration(dur_secs)
				dur_lbl.custom_minimum_size = Vector2(56, 0)
				dur_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				dur_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
				dur_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(dur_lbl)
				var acts_lbl: Label = Label.new()
				acts_lbl.text = str(round_data.get("action_count", 0)) + " actions"
				acts_lbl.custom_minimum_size = Vector2(72, 0)
				acts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				acts_lbl.add_theme_color_override("font_color", UITheme.PURPLE_MID)
				acts_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(acts_lbl)
				var coins_lbl: Label = Label.new()
				coins_lbl.text = "♦ " + str(round_data.get("coins", 0))
				coins_lbl.custom_minimum_size = Vector2(72, 0)
				coins_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				coins_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
				coins_lbl.add_theme_font_size_override("font_size", 12)
				row.add_child(coins_lbl)
				list.add_child(_indent_wrap(row, indent))


# Renders a fork header + each path (with path header + recursed items).
func _add_fork_to_list(list: VBoxContainer, fork: Dictionary, indent: int) -> void:
	# Fork header row
	var fork_row: HBoxContainer = HBoxContainer.new()
	fork_row.add_theme_constant_override("separation", 8)
	var fork_lbl: Label = Label.new()
	var paths: Array = fork.get("paths", [])
	var fork_title: String = fork.get("title", "")
	if fork_title != "":
		fork_lbl.text = "⑂  FORK: %s  (%d PATHS)" % [fork_title.to_upper(), paths.size()]
	else:
		fork_lbl.text = "⑂  FORK  (%d PATHS)" % paths.size()
	fork_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fork_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	fork_lbl.add_theme_font_size_override("font_size", 11)
	fork_row.add_child(fork_lbl)
	list.add_child(_indent_wrap(fork_row, indent))

	# Each path
	for pi: int in paths.size():
		var path: Dictionary = paths[pi]
		var path_name: String = path.get("name", "Path %d" % (pi + 1))

		# Path header
		var path_row: HBoxContainer = HBoxContainer.new()
		path_row.add_theme_constant_override("separation", 8)
		var path_lbl: Label = Label.new()
		path_lbl.text = "▸  PATH %d: %s" % [pi + 1, path_name.to_upper()]
		path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		path_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
		path_lbl.add_theme_font_size_override("font_size", 11)
		path_row.add_child(path_lbl)
		list.add_child(_indent_wrap(path_row, indent + 1))

		# Path contents (recurse)
		_add_seq_to_list(
			list,
			path.get("rounds", []),
			path.get("shops", []),
			path.get("storyboards", []),
			path.get("forks", []),
			indent + 2
		)


# Wraps a control in a MarginContainer that adds `indent * INDENT_PX` of left padding.
func _indent_wrap(child: Control, indent: int) -> Control:
	if indent == 0:
		return child
	var mc: MarginContainer = MarginContainer.new()
	mc.add_theme_constant_override("margin_left", indent * INDENT_PX)
	mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mc.add_child(child)
	return mc


func _format_duration(total_seconds: int) -> String:
	var h: int = total_seconds / 3600
	var m: int = (total_seconds % 3600) / 60
	var s: int = total_seconds % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, s]
	return "%d:%02d" % [m, s]
