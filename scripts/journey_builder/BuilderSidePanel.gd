class_name BuilderSidePanel
extends RefCounted

# ---------------------------------------------------------------------------
# BuilderSidePanel
# Renders the journey-builder's right-hand editor panel. Owns no state of its
# own — reads from and mutates the JourneyBuilder it was constructed with.
#
# Public entry points:
#   show_journey_info_panel()                 – default view, journey metadata
#   show_graph_node_editor(node_id)           – per-node editor for the selected graph node
#
# Everything else is internal. The owner (JourneyBuilder) is accessed via
# `_owner.<field>` / `_owner.<method>()`.
# ---------------------------------------------------------------------------

const COVER_HEIGHT: int = 280
const ROW_SEP: int = 8

# Difficulty list and file-extension sets are owned by JourneyData — the single
# canonical schema. Referenced here as JourneyData.<NAME>.

const DropZoneScript = preload("res://scripts/journey_builder/DropZone.gd")

# T-code secondary axes shown in the collapsible expander for each round.
const EXTRA_AXES_INFO: Array = [
	{"axis": "L1", "label": "L1  —  SURGE  (in / out)"},
	{"axis": "L2", "label": "L2  —  SWAY  (left / right)"},
	{"axis": "R0", "label": "R0  —  TWIST  (rotate)"},
	{"axis": "R1", "label": "R1  —  ROLL  (tilt side)"},
	{"axis": "R2", "label": "R2  —  PITCH  (tilt fwd / back)"},
]

# Vibrator channel drop zones shown in the collapsible expander for each round.
# key matches the vib_scripts dict key used by JourneyBuilder and GameLoop.
const VIB_CHANNELS_INFO: Array = [
	{"key": "vib1", "label": "VIB1  —  CHANNEL 0  (primary motor)"},
	{"key": "vib2", "label": "VIB2  —  CHANNEL 1  (secondary motor)"},
]

# Forced-modifier kinds a boss round can impose. Parallel arrays: KINDS feeds the
# saved data, LABELS feeds the editor dropdown.
# Gameplay forced-modifier kinds a boss round can impose. Visual/audio effects
# (incl. the old BLACKOUT) now live in the "Non-gameplay modifiers" picker.
const BOSS_MODIFIER_KINDS: Array = ["scale", "clamp", "reverse", "score_multiplier"]
const BOSS_MODIFIER_LABELS: Array = [
	"SCALE  —  STROKE LENGTH",
	"CLAMP  —  POSITION RANGE",
	"REVERSE  —  MIRROR",
	"SCORE MULTIPLIER",
]

var _owner: JourneyBuilder


func _init(owner: JourneyBuilder) -> void:
	_owner = owner


# ── Public API ──────────────────────────────────────────────────────────────


# Default side-panel view (no node selected). Shows journey metadata + quick-add.
func show_journey_info_panel() -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	if side_vbox == null:
		return
	for c in side_vbox.get_children():
		c.queue_free()

	var hdr: Label = Label.new()
	hdr.text = "// JOURNEY INFO //"
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)

	# Open-folder shortcut — jumps to this journey's media/ folder on disk (only
	# once it has been saved, since the folder won't exist before then).
	var open_folder_btn: Button = Button.new()
	open_folder_btn.text = "📁 OPEN MEDIA FOLDER"
	open_folder_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(open_folder_btn, UITheme.PURPLE_MID)
	open_folder_btn.pressed.connect(_owner._open_journey_folder)
	side_vbox.add_child(open_folder_btn)

	# Cover preview + button
	side_vbox.add_child(_side_field_label("COVER IMAGE"))
	var cover_border: PanelContainer = PanelContainer.new()
	cover_border.custom_minimum_size = Vector2(0, COVER_HEIGHT * 0.9)
	var cb_style: StyleBoxFlat = StyleBoxFlat.new()
	cb_style.bg_color = UITheme.PURPLE_DARK
	cb_style.border_color = UITheme.PURPLE_MID
	cb_style.border_width_left = 2
	cb_style.border_width_right = 2
	cb_style.border_width_top = 2
	cb_style.border_width_bottom = 2
	cover_border.add_theme_stylebox_override("panel", cb_style)
	side_vbox.add_child(cover_border)

	var cover_preview: TextureRect = TextureRect.new()
	cover_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	cover_preview.clip_contents = true
	if _owner._cover_texture != null:
		cover_preview.texture = _owner._cover_texture
	cover_border.add_child(cover_preview)

	if _owner._cover_path != "":
		var cover_row: HBoxContainer = HBoxContainer.new()
		cover_row.add_theme_constant_override("separation", 6)
		var change_btn: Button = Button.new()
		change_btn.text = "CHANGE COVER"
		change_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(change_btn, UITheme.PURPLE_MID)
		change_btn.pressed.connect(_owner._on_cover_pressed)
		cover_row.add_child(change_btn)
		var cover_rm_btn: Button = Button.new()
		cover_rm_btn.text = "✕ REMOVE"
		cover_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(cover_rm_btn, UITheme.MAGENTA)
		cover_rm_btn.pressed.connect(
			func() -> void:
				_delete_saved_image(_owner._cover_path)
				_owner._cover_path = ""
				_owner._cover_texture = null
				show_journey_info_panel()
		)
		cover_row.add_child(cover_rm_btn)
		side_vbox.add_child(cover_row)
	else:
		var cover_btn: Button = Button.new()
		cover_btn.text = "DROP IMAGE OR CLICK TO BROWSE"
		UITheme.style_button(cover_btn, UITheme.PURPLE_MID)
		cover_btn.pressed.connect(_owner._on_cover_pressed)
		side_vbox.add_child(cover_btn)

	side_vbox.add_child(_side_section_separator())

	# Name
	side_vbox.add_child(_side_field_label("JOURNEY NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Journey name..."
	name_edit.text = _owner._journey_name
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: _owner._journey_name = val)
	side_vbox.add_child(name_edit)

	# Author
	side_vbox.add_child(_side_field_label("AUTHOR"))
	var author_edit: LineEdit = LineEdit.new()
	author_edit.placeholder_text = "Author name..."
	author_edit.text = _owner._journey_author
	UITheme.style_line_edit(author_edit)
	author_edit.text_changed.connect(func(val: String) -> void: _owner._journey_author = val)
	side_vbox.add_child(author_edit)

	# Difficulty
	side_vbox.add_child(_side_field_label("DIFFICULTY"))
	var diff_btn: OptionButton = OptionButton.new()
	for diff: String in JourneyData.DIFFICULTIES:
		diff_btn.add_item(diff)
	diff_btn.selected = _owner._journey_difficulty_idx
	UITheme.style_option_button(diff_btn)
	diff_btn.item_selected.connect(func(idx: int) -> void: _owner._journey_difficulty_idx = idx)
	side_vbox.add_child(diff_btn)

	# Description
	side_vbox.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: TextEdit = TextEdit.new()
	desc_edit.placeholder_text = "Optional description..."
	desc_edit.text = _owner._journey_desc
	desc_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_edit.custom_minimum_size = Vector2(0, 90)
	desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(desc_edit)
	desc_edit.text_changed.connect(func() -> void: _owner._journey_desc = desc_edit.text)
	side_vbox.add_child(desc_edit)

	# Tags — toggle chips, one per definition in tags.json.
	side_vbox.add_child(_side_field_label("TAGS"))
	var tag_flow: HFlowContainer = HFlowContainer.new()
	tag_flow.add_theme_constant_override("h_separation", 6)
	tag_flow.add_theme_constant_override("v_separation", 6)
	side_vbox.add_child(tag_flow)
	for tag_def: Dictionary in TagRegistry.all():
		tag_flow.add_child(_make_tag_toggle(tag_def))

	side_vbox.add_child(_side_section_separator())

	# Player map — author switch. Off enforces "surprise": the player can't open
	# the in-play journey map (◇ MAP / M) for this journey.
	side_vbox.add_child(_side_field_label("PLAYER MAP"))
	var map_toggle: CheckButton = CheckButton.new()
	map_toggle.text = "ALLOW JOURNEY MAP"
	map_toggle.tooltip_text = "Let the player open the read-only journey map during play (◇ MAP button / M key). Turn off to keep the journey's layout a surprise."
	map_toggle.add_theme_font_size_override("font_size", 12)
	map_toggle.button_pressed = _owner._journey_map_enabled
	side_vbox.add_child(map_toggle)

	# Sub-options: fog of war + how far ahead it reveals. All grey out when the map is off; the step
	# count additionally greys out under "whole structure". Declared before the wiring so the shared
	# refresh closure can reach them all.
	var fog_toggle: CheckButton = CheckButton.new()
	fog_toggle.text = "FOG OF WAR  (REVEAL ON DISCOVERY)"
	fog_toggle.tooltip_text = "Reveal the map as the player plays: visited nodes shown in full, the steps ahead ghosted as '?', everything beyond hidden. Discovery resets each run."
	fog_toggle.add_theme_font_size_override("font_size", 12)
	fog_toggle.button_pressed = _owner._journey_map_fog
	side_vbox.add_child(fog_toggle)

	var reveal_row: HBoxContainer = HBoxContainer.new()
	reveal_row.add_theme_constant_override("separation", 8)
	var reveal_lbl: Label = Label.new()
	reveal_lbl.text = "STEPS REVEALED AHEAD"
	reveal_lbl.add_theme_font_size_override("font_size", 11)
	reveal_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	reveal_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reveal_row.add_child(reveal_lbl)
	var reveal_spin: SpinBox = SpinBox.new()
	reveal_spin.min_value = 0
	reveal_spin.max_value = 20
	reveal_spin.step = 1
	reveal_spin.value = maxi(0, _owner._journey_map_fog_reveal)
	reveal_spin.tooltip_text = "How many steps of '?' ghosts to show beyond the visited trail. 0 = trail only."
	UITheme.style_spin_box(reveal_spin)
	reveal_row.add_child(reveal_spin)
	side_vbox.add_child(reveal_row)

	var whole_toggle: CheckButton = CheckButton.new()
	whole_toggle.text = "REVEAL WHOLE STRUCTURE"
	whole_toggle.tooltip_text = "Show EVERY node as a '?' ghost so the player sees the journey's shape without learning what each node is. Overrides the step count."
	whole_toggle.add_theme_font_size_override("font_size", 12)
	whole_toggle.button_pressed = _owner._journey_map_fog_reveal < 0
	side_vbox.add_child(whole_toggle)

	# Shared enable-state refresh: reveal controls need the map AND fog on; the step spin also greys out
	# under "whole structure".
	var refresh_fog: Callable = func() -> void:
		var fog_on: bool = _owner._journey_map_enabled and _owner._journey_map_fog
		fog_toggle.disabled = not _owner._journey_map_enabled
		whole_toggle.disabled = not fog_on
		reveal_spin.editable = fog_on and not whole_toggle.button_pressed
	refresh_fog.call()

	reveal_spin.value_changed.connect(
		func(v: float) -> void:
			if not whole_toggle.button_pressed:
				_owner._journey_map_fog_reveal = int(v)
	)
	whole_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_fog_reveal = -1 if on else int(reveal_spin.value)
			refresh_fog.call()
	)
	fog_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_fog = on
			refresh_fog.call()
	)
	map_toggle.toggled.connect(
		func(on: bool) -> void:
			_owner._journey_map_enabled = on
			refresh_fog.call()
	)

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# Toggle chip for one journey tag. Filled with the tag's colour when on,
# faintly tinted when off. Mutates _owner._journey_tags directly.
func _make_tag_toggle(tag_def: Dictionary) -> Button:
	var id: String = tag_def["id"]
	var color: Color = tag_def["color"]

	var btn: Button = Button.new()
	btn.text = tag_def["label"]
	btn.toggle_mode = true
	btn.button_pressed = id in _owner._journey_tags
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 11)

	var off_style: StyleBoxFlat = StyleBoxFlat.new()
	off_style.bg_color = Color(color.r, color.g, color.b, 0.06)
	off_style.border_color = Color(color.r, color.g, color.b, 0.45)
	off_style.border_width_left = 1
	off_style.border_width_right = 1
	off_style.border_width_top = 1
	off_style.border_width_bottom = 1
	off_style.set_corner_radius_all(UITheme.CORNER_RADIUS)
	off_style.content_margin_left = 11
	off_style.content_margin_right = 11
	off_style.content_margin_top = 5
	off_style.content_margin_bottom = 5

	var on_style: StyleBoxFlat = off_style.duplicate()
	on_style.bg_color = color
	on_style.border_color = color

	btn.add_theme_stylebox_override("normal", off_style)
	btn.add_theme_stylebox_override("hover", off_style)
	btn.add_theme_stylebox_override("pressed", on_style)
	btn.add_theme_stylebox_override("hover_pressed", on_style)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", color)
	btn.add_theme_color_override("font_pressed_color", UITheme.BG)
	btn.add_theme_color_override("font_hover_pressed_color", UITheme.BG)

	btn.toggled.connect(
		func(on_state: bool) -> void:
			if on_state:
				if id not in _owner._journey_tags:
					_owner._journey_tags.append(id)
			else:
				_owner._journey_tags.erase(id)
	)
	return btn


# Graph-editor: the "ADD NODE" button row (round/shop/storyboard/fork → _create_graph_node). Shown
# in both the journey-info panel and the node editor so creating a node is always reachable.
func _make_graph_add_buttons() -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label("ADD NODE"))
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for spec: Array in [
		["▶ ROUND", "round", UITheme.PURPLE_MID],
		["◆ SHOP", "shop", UITheme.PURPLE_BRIGHT],
		["◈ STORY", "storyboard", UITheme.STORYBOARD],
		["⑂ FORK", "fork", UITheme.MAGENTA]
	]:
		var btn: Button = UITheme.make_icon_btn(spec[0], false, spec[2])
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t: String = spec[1]
		btn.pressed.connect(func() -> void: _owner._create_graph_node(t))
		row.add_child(btn)
	box.add_child(row)
	return box


# Graph-editor (L1 slice 2b/3b): the editor for a selected GRAPH node. Reuses the per-type field
# editors by pointing them at node.data (arr = [node.data], idx = 0), so edits mutate the node in
# place. Forks edit their out-edges (slice 3c), so they show a placeholder for now. Topped with the
# add-node row and tailed with a delete button. Field edits reflect on the canvas on the next
# refresh (re-selecting a node, or a structural change).
func show_graph_node_editor(node_id: String) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	var node: Dictionary = (_owner._graph_model.get("nodes", {}) as Dictionary).get(node_id, {})
	if node.is_empty():
		show_journey_info_panel()
		return
	# Test From Here at the top — save + play the journey starting at this node (a synthetic
	# {node_id} item is all _save_and_test_from needs; the graph is node-id native).
	side_vbox.add_child(_make_test_controls({"node_id": node_id}, []))
	side_vbox.add_child(_side_divider_line())
	# ⚖ ON ARRIVAL — what the audit says the player has when reaching this node.
	side_vbox.add_child(_make_arrival_audit_block(node_id))
	side_vbox.add_child(_side_divider_line())
	var node_type: String = node.get("type", "round")
	if node_type == "fork":
		# Fork editing = out-edges as choices (3c-ii). reselect rebuilds the side panel after a
		# structural change (resolution toggle, add/remove choice) so per-choice fields match.
		var fork_reselect: Callable = func(_i: int) -> void:
			_owner._refresh_graph()
			show_graph_node_editor(node_id)
		side_vbox.add_child(_make_graph_fork_editor(node_id, node, fork_reselect))
	else:
		var data: Dictionary = node.get("data", {})
		var display: Dictionary = data.duplicate()  # gives _build_side_panel_editor a "type" to dispatch on
		display["type"] = node_type
		var arr: Array = [data]  # arr[0] IS node.data — editors mutate the node
		var reselect: Callable = func(_new_idx: int) -> void:
			_owner._refresh_graph()  # structural change → re-render the canvas
			show_graph_node_editor(node_id)
		_build_side_panel_editor(side_vbox, display, arr, 0, reselect)
		# Round nodes group SETS FLAGS with Coins inside their editor (Rewards group); shop / storyboard
		# nodes, whose editors aren't grouped, get it appended here. Read by flag-conditional forks.
		if node_type != "round":
			side_vbox.add_child(_make_set_flags_field(data))
		# Divider between the content editor (round types / fields) and the node-operations block
		# (connect / duplicate / delete / add) below.
		side_vbox.add_child(_side_divider_line())
		# Edge wiring (slice 3c): connect this node's flow to a target, or disconnect (end here).
		var connecting: bool = _owner._connecting_from == node_id
		var conn_btn: Button = UITheme.make_icon_btn(
			"✕ CANCEL CONNECT" if connecting else "🔗 CONNECT TO…", false, UITheme.AMBER
		)
		conn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		conn_btn.pressed.connect(func() -> void: _owner._begin_connect(node_id))
		side_vbox.add_child(conn_btn)
		var node_out: Array = node.get("out", [])
		if not node_out.is_empty() and str((node_out[0] as Dictionary).get("to", "")) != "":
			var disc_btn: Button = UITheme.make_icon_btn(
				"✂ DISCONNECT (END HERE)", false, UITheme.PURPLE_MID
			)
			disc_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			disc_btn.pressed.connect(func() -> void: _owner._disconnect_graph_node(node_id))
			side_vbox.add_child(disc_btn)
	side_vbox.add_child(_side_section_separator())
	var dup_btn: Button = UITheme.make_icon_btn("⎘ DUPLICATE", false, UITheme.PURPLE_MID)
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.pressed.connect(func() -> void: _owner._duplicate_selection())
	side_vbox.add_child(dup_btn)
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE NODE", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_graph_node(node_id))
	side_vbox.add_child(del_btn)

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# Graph editor: the side panel for a selected sticky-note comment — edit its text or delete it.
func show_comment_editor(idx: int) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	var comments: Array = _owner._graph_model.get("comments", [])
	if idx < 0 or idx >= comments.size():
		show_journey_info_panel()
		return
	var hdr: Label = Label.new()
	hdr.text = "// NOTE //"
	hdr.add_theme_color_override("font_color", UITheme.AMBER)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)
	side_vbox.add_child(_side_field_label("TEXT"))
	var edit: TextEdit = TextEdit.new()
	edit.text = str((comments[idx] as Dictionary).get("text", ""))
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 140)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(edit)
	edit.text_changed.connect(
		func() -> void:
			var cs: Array = _owner._graph_model.get("comments", [])
			if idx < cs.size():
				(cs[idx] as Dictionary)["text"] = edit.text
	)
	edit.focus_exited.connect(func() -> void: _owner._refresh_graph())
	side_vbox.add_child(edit)
	side_vbox.add_child(_side_field_label("COLOUR"))
	var swatch_row: HBoxContainer = HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	for col: Color in [
		UITheme.AMBER, UITheme.CYAN, Color(0.45, 0.95, 0.30), UITheme.MAGENTA, UITheme.PURPLE_BRIGHT
	]:
		var sw: Button = Button.new()
		sw.custom_minimum_size = Vector2(30, 26)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = "Set note colour"
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = col
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		sw.pressed.connect(
			func() -> void:
				var cs: Array = _owner._graph_model.get("comments", [])
				if idx < cs.size():
					_owner._push_undo()
					(cs[idx] as Dictionary)["color"] = col
					_owner._refresh_graph()
		)
		swatch_row.add_child(sw)
	side_vbox.add_child(swatch_row)
	side_vbox.add_child(_side_section_separator())
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE NOTE", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_comment(idx))
	side_vbox.add_child(del_btn)


# Graph editor: the side panel for a selected group frame — rename it, recolour it, or delete it.
func show_frame_editor(idx: int) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	for c in side_vbox.get_children():
		c.queue_free()
	var groups: Array = _owner._graph_model.get("groups", [])
	if idx < 0 or idx >= groups.size():
		show_journey_info_panel()
		return
	var hdr: Label = Label.new()
	hdr.text = "// GROUP //"
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)
	side_vbox.add_child(_side_field_label("LABEL"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.text = str((groups[idx] as Dictionary).get("label", ""))
	name_edit.placeholder_text = "Group label..."
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(
		func(val: String) -> void:
			var gs: Array = _owner._graph_model.get("groups", [])
			if idx < gs.size():
				(gs[idx] as Dictionary)["label"] = val
	)
	name_edit.focus_exited.connect(func() -> void: _owner._refresh_graph())
	side_vbox.add_child(name_edit)
	side_vbox.add_child(_side_field_label("COLOUR"))
	var swatch_row: HBoxContainer = HBoxContainer.new()
	swatch_row.add_theme_constant_override("separation", 6)
	for col: Color in [
		UITheme.PURPLE_BRIGHT, UITheme.AMBER, UITheme.CYAN, Color(0.45, 0.95, 0.30), UITheme.MAGENTA
	]:
		var sw: Button = Button.new()
		sw.custom_minimum_size = Vector2(30, 26)
		sw.focus_mode = Control.FOCUS_NONE
		sw.tooltip_text = "Set frame colour"
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = col
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		sw.pressed.connect(
			func() -> void:
				var gs: Array = _owner._graph_model.get("groups", [])
				if idx < gs.size():
					_owner._push_undo()
					(gs[idx] as Dictionary)["color"] = col
					_owner._refresh_graph()
		)
		swatch_row.add_child(sw)
	side_vbox.add_child(swatch_row)
	side_vbox.add_child(_side_section_separator())
	var collapsed: bool = bool((groups[idx] as Dictionary).get("collapsed", false))
	var collapse_btn: Button = UITheme.make_icon_btn(
		"▸ EXPAND" if collapsed else "▾ COLLAPSE", false, UITheme.PURPLE_MID
	)
	collapse_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collapse_btn.pressed.connect(func() -> void: _owner._on_frame_toggle_collapse(idx))
	side_vbox.add_child(collapse_btn)
	var del_btn: Button = UITheme.make_icon_btn("🗑 DELETE GROUP", false, UITheme.ERROR_SOFT)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_frame(idx))
	side_vbox.add_child(del_btn)


# Graph editor: the side panel shown when 2+ nodes are selected. Group actions only (per-node field
# editing needs a single selection); the ADD NODE row stays so creating is always reachable.
func show_graph_multi_select_panel(ids: Array) -> void:
	var side_vbox: VBoxContainer = _owner._side_vbox
	if side_vbox == null:
		return
	for c in side_vbox.get_children():
		c.queue_free()

	var hdr: Label = Label.new()
	hdr.text = "// %d NODES SELECTED //" % ids.size()
	hdr.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	side_vbox.add_child(hdr)

	var hint: Label = Label.new()
	hint.text = "Drag any selected node to move the group. Ctrl/Shift-click a node to adjust the selection; click empty space to clear."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 11)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side_vbox.add_child(hint)

	side_vbox.add_child(_side_section_separator())
	var copy_btn: Button = UITheme.make_icon_btn(
		"⧉ COPY (%d)" % ids.size(), false, UITheme.PURPLE_BRIGHT
	)
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.pressed.connect(func() -> void: _owner._copy_selection())
	side_vbox.add_child(copy_btn)
	var dup_btn: Button = UITheme.make_icon_btn(
		"⎘ DUPLICATE (%d)" % ids.size(), false, UITheme.PURPLE_MID
	)
	dup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup_btn.pressed.connect(func() -> void: _owner._duplicate_selection())
	side_vbox.add_child(dup_btn)
	var del_btn: Button = UITheme.make_icon_btn(
		"🗑 DELETE SELECTED (%d)" % ids.size(), false, UITheme.ERROR_SOFT
	)
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(func() -> void: _owner._delete_selected_nodes())
	side_vbox.add_child(del_btn)

	side_vbox.add_child(_side_section_separator())
	side_vbox.add_child(_make_graph_add_buttons())


# Graph-editor fork editor (3c-ii): edits the fork's meta (title/description/resolution + the
# conditional sub-config) and its CHOICES — one per out-edge. Unlike the tree fork editor, a
# choice holds no nested items; it just carries its config and a `to` target wired by connect
# mode. Mutates node.data + node.out in place; structural changes go through `reselect`.
# A "SETS FLAGS" comma-separated field writing a cleaned string array to target["set_flags"] — shared
# by a playable node's data and a fork choice's edge. Flags are set when the node plays or the choice
# is taken, and read by flag-conditional forks downstream.
# A small label listing the flags already used in the journey, so authors reuse consistent names (a
# lightweight stand-in for autocomplete). "No flags used yet." when there are none.
func _known_flags_hint() -> Label:
	var known: Array = (_owner._all_set_flags() as Dictionary).keys()
	known.sort()
	var lbl: Label = Label.new()
	lbl.text = (
		("Known: " + ", ".join(PackedStringArray(known)))
		if not known.is_empty()
		else "No flags used yet."
	)
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


func _make_set_flags_field(target: Dictionary) -> Control:
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.add_child(_side_field_label("SETS FLAGS (COMMA-SEPARATED)"))
	var edit: LineEdit = LineEdit.new()
	edit.placeholder_text = "e.g. spared_boss, found_key"
	edit.text = ", ".join(
		PackedStringArray(JourneyData.clean_flag_list(target.get("set_flags", [])))
	)
	UITheme.style_line_edit(edit)
	edit.text_changed.connect(
		func(v: String) -> void:
			target["set_flags"] = JourneyData.clean_flag_list(Array(v.split(",")))
	)
	col.add_child(edit)
	col.add_child(_known_flags_hint())
	return col


func _make_graph_fork_editor(node_id: String, node: Dictionary, reselect: Callable) -> Control:
	var data: Dictionary = node.get("data", {})
	var out: Array = node.get("out", [])

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)

	col.add_child(_side_field_label("TITLE"))
	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Fork title (optional)..."
	title_edit.text = data.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(v: String) -> void: data["title"] = v)
	col.add_child(title_edit)

	col.add_child(_side_field_label("DESCRIPTION"))
	var desc_edit: LineEdit = LineEdit.new()
	desc_edit.placeholder_text = "Fork description (optional)..."
	desc_edit.text = data.get("description", "")
	UITheme.style_line_edit(desc_edit)
	desc_edit.text_changed.connect(func(v: String) -> void: data["description"] = v)
	col.add_child(desc_edit)

	# Resolution: how the journey picks a choice.
	col.add_child(_side_field_label("RESOLUTION"))
	var res_values: Array = ["choice", "random", "conditional", "sacrifice"]
	var res_dd: OptionButton = OptionButton.new()
	res_dd.add_item("Player Choice")
	res_dd.add_item("Random")
	res_dd.add_item("Conditional")
	res_dd.add_item("Sacrifice")
	res_dd.selected = max(0, res_values.find(data.get("resolution", "choice")))
	res_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(res_dd)
	res_dd.item_selected.connect(
		func(i: int) -> void:
			data["resolution"] = res_values[i]
			reselect.call(0)  # rebuild so per-choice fields match the new type
	)
	col.add_child(res_dd)

	var resolution: String = data.get("resolution", "choice")
	var metric: String = data.get("cond_metric", "score")

	# Conditional sub-config: which metric + the fallback choice.
	if resolution == "conditional":
		col.add_child(_side_field_label("CONDITION"))
		var metric_values: Array = ["score", "coins", "item", "flag"]
		var metric_dd: OptionButton = OptionButton.new()
		metric_dd.add_item("Last Round Score")
		metric_dd.add_item("Coin Balance")
		metric_dd.add_item("Item Owned")
		metric_dd.add_item("Flag Set")
		metric_dd.selected = max(0, metric_values.find(metric))
		metric_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(metric_dd)
		metric_dd.item_selected.connect(
			func(i: int) -> void:
				data["cond_metric"] = metric_values[i]
				reselect.call(0)
		)
		col.add_child(metric_dd)

		# Who resolves it: the game auto-spins to the best match, or the player picks among the paths
		# they've unlocked (the condition gates which choices are selectable).
		col.add_child(_side_field_label("RESOLVED BY"))
		var decider_values: Array = ["game", "player"]
		var decider_dd: OptionButton = OptionButton.new()
		decider_dd.add_item("Game (auto-spin)")
		decider_dd.add_item("Player (picks unlocked)")
		decider_dd.selected = max(0, decider_values.find(data.get("cond_decider", "game")))
		decider_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(decider_dd)
		decider_dd.item_selected.connect(
			func(i: int) -> void:
				data["cond_decider"] = decider_values[i]
				reselect.call(0)
		)
		col.add_child(decider_dd)

		col.add_child(_side_field_label("DEFAULT CHOICE (FALLBACK / ALWAYS AVAILABLE)"))
		var def_dd: OptionButton = OptionButton.new()
		for ej in out.size():
			var en: String = str((out[ej] as Dictionary).get("name", "")).strip_edges()
			def_dd.add_item("Choice %d%s" % [ej + 1, ("  " + en) if en != "" else ""])
		def_dd.selected = clampi(int(data.get("default_path", 0)), 0, max(0, out.size() - 1))
		def_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(def_dd)
		def_dd.item_selected.connect(func(i: int) -> void: data["default_path"] = i)
		col.add_child(def_dd)

	var res_hint: Label = Label.new()
	res_hint.text = _fork_resolution_hint(resolution, metric, data.get("cond_decider", "game"))
	res_hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	res_hint.add_theme_font_size_override("font_size", 10)
	res_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(res_hint)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("CHOICES"))

	for ei in out.size():
		col.add_child(_make_graph_choice_block(node_id, out, ei, resolution, metric, reselect))

	# Cap at 4 to match the proven ForkScreen choice layout.
	if out.size() < 4:
		var add_btn: Button = Button.new()
		add_btn.text = "+ ADD CHOICE"
		add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(add_btn, UITheme.PURPLE_MID)
		add_btn.pressed.connect(func() -> void: _owner._add_fork_edge(node_id))
		col.add_child(add_btn)

	return col


# One choice card inside the graph fork editor: name / description / card image, the per-
# resolution field (weight / threshold / cost / required item — reusing the tree helpers, which
# write to out[ei] just as they do for a tree path), and the "LEADS TO" wiring (connect / clear).
func _make_graph_choice_block(
	node_id: String, out: Array, ei: int, resolution: String, metric: String, reselect: Callable
) -> Control:
	var edge: Dictionary = out[ei]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.08)
	ps.border_color = UITheme.MAGENTA
	ps.border_width_left = 1
	ps.border_width_right = 1
	ps.border_width_top = 1
	ps.border_width_bottom = 1
	ps.content_margin_left = 10
	ps.content_margin_right = 10
	ps.content_margin_top = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sub: VBoxContainer = VBoxContainer.new()
	sub.add_theme_constant_override("separation", 4)
	panel.add_child(sub)

	var hdr: HBoxContainer = HBoxContainer.new()
	hdr.add_theme_constant_override("separation", ROW_SEP)
	sub.add_child(hdr)
	var choice_lbl: Label = Label.new()
	choice_lbl.text = "CHOICE %d" % (ei + 1)
	choice_lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	choice_lbl.add_theme_font_size_override("font_size", 11)
	choice_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(choice_lbl)
	# A fork needs ≥2 choices (matches the tree's path minimum + ForkScreen).
	if out.size() > 2:
		var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
		rm_btn.tooltip_text = "Delete this choice"
		rm_btn.pressed.connect(func() -> void: _owner._remove_fork_edge(node_id, ei))
		hdr.add_child(rm_btn)

	sub.add_child(_side_field_label("NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Choice name..."
	name_edit.text = edge.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(v: String) -> void: out[ei]["name"] = v)
	sub.add_child(name_edit)

	sub.add_child(_side_field_label("DESCRIPTION"))
	var cdesc_edit: LineEdit = LineEdit.new()
	cdesc_edit.placeholder_text = "Description (optional)..."
	cdesc_edit.text = edge.get("description", "")
	UITheme.style_line_edit(cdesc_edit)
	cdesc_edit.text_changed.connect(func(v: String) -> void: out[ei]["description"] = v)
	sub.add_child(cdesc_edit)

	sub.add_child(_side_field_label("CARD IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Card Image for Choice %d" % (ei + 1)
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(img_zone)
	if edge.get("image_path", "") != "":
		img_zone.call_deferred("set_file", edge["image_path"])
	var img_rm_btn: Button = Button.new()
	img_rm_btn.text = "✕ REMOVE IMAGE"
	img_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img_rm_btn.visible = edge.get("image_path", "") != ""
	UITheme.style_button(img_rm_btn, UITheme.MAGENTA)
	img_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(out[ei].get("image_path", ""))
			out[ei]["image_path"] = ""
			img_zone.call_deferred("set_file", "")
			img_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			out[ei]["image_path"] = p
			img_rm_btn.visible = true
	)
	sub.add_child(img_rm_btn)

	# Per-resolution field — the shared helpers write to out[ei][key] (out is an edge array,
	# indexed exactly like the tree's paths array).
	if resolution == "random":
		_add_path_int_field(sub, out, ei, "weight", "WEIGHT (RELATIVE ODDS)", 1000)
	elif resolution == "sacrifice":
		_add_path_int_field(sub, out, ei, "cost", "COIN COST", 999999)
		_add_required_item_field(sub, out, ei, edge, "REQUIRED ITEM (CONSUMED)")
	elif resolution == "conditional" and metric == "item":
		_add_required_item_field(sub, out, ei, edge, "REQUIRED ITEM")
	elif resolution == "conditional" and metric == "flag":
		sub.add_child(_side_field_label("REQUIRED FLAG"))
		var rf_edit: LineEdit = LineEdit.new()
		rf_edit.placeholder_text = "Flag name (e.g. spared_boss)..."
		rf_edit.text = str(edge.get("required_flag", ""))
		UITheme.style_line_edit(rf_edit)
		rf_edit.text_changed.connect(
			func(v: String) -> void: out[ei]["required_flag"] = v.strip_edges()
		)
		sub.add_child(rf_edit)
		sub.add_child(_known_flags_hint())
	elif resolution == "conditional":
		var thr_label: String = "ACTIVATES AT ≥  (%s)" % ("SCORE" if metric == "score" else "COINS")
		_add_path_int_field(sub, out, ei, "threshold", thr_label, 999999)

	# A choice can set flags when it's taken ("you chose mercy").
	sub.add_child(_make_set_flags_field(edge))
	# LEADS TO — the choice's target node, wired via connect mode.
	sub.add_child(_side_section_separator())
	sub.add_child(_side_field_label("LEADS TO"))
	var to_id: String = str(edge.get("to", ""))
	var target_lbl: Label = Label.new()
	target_lbl.text = (
		_graph_node_label(to_id) if to_id != "" else "(not set — ends the run on this choice)"
	)
	target_lbl.add_theme_color_override(
		"font_color", UITheme.SUCCESS if to_id != "" else UITheme.DARK_TEXT
	)
	target_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_child(target_lbl)

	var connecting: bool = _owner._connecting_from == node_id and _owner._connecting_edge_idx == ei
	var conn_btn: Button = UITheme.make_icon_btn(
		"✕ CANCEL CONNECT" if connecting else "🔗 CONNECT TO…", false, UITheme.AMBER
	)
	conn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conn_btn.pressed.connect(func() -> void: _owner._begin_connect_fork_edge(node_id, ei))
	sub.add_child(conn_btn)
	if to_id != "":
		var clear_btn: Button = UITheme.make_icon_btn(
			"✂ CLEAR (END ON THIS CHOICE)", false, UITheme.PURPLE_MID
		)
		clear_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clear_btn.pressed.connect(func() -> void: _owner._clear_fork_edge(node_id, ei))
		sub.add_child(clear_btn)

	return panel


# Short readable label for a graph node (used by the fork choice "LEADS TO" line).
func _graph_node_label(node_id: String) -> String:
	var nodes: Dictionary = _owner._graph_model.get("nodes", {})
	if not nodes.has(node_id):
		return "(missing node)"
	var n: Dictionary = nodes[node_id]
	var d: Dictionary = n.get("data", {})
	match str(n.get("type", "")):
		"round":
			var rn: String = str(d.get("name", "")).strip_edges()
			return "Round — %s" % (rn if rn != "" else "(unnamed)")
		"shop":
			var sn: String = str(d.get("title", "")).strip_edges()
			return "Shop — %s" % (sn if sn != "" else "(unnamed)")
		"storyboard":
			return "Storyboard"
		"fork":
			var fn: String = str(d.get("title", "")).strip_edges()
			return "Fork — %s" % (fn if fn != "" else "(unnamed)")
	return node_id


# Test-play controls block: the "Test From Here" button plus the seed inputs.
# `item` carries the node_id to launch from; `arr` is vestigial (graph mode passes []),
# kept only for the shared _save_and_test_from signature.
func _make_test_controls(item: Dictionary, arr: Array) -> Control:
	# Collapsible "Test From Here" group: the play action plus its score / coin / flag seeds. Collapsed
	# by default to cut side-panel clutter; the open/closed state is persisted on the owner so it
	# survives the panel rebuild that fires on every node selection.
	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var expanded: bool = bool(_owner._test_panel_expanded)
	var toggle_btn: Button = Button.new()
	toggle_btn.text = ("▾  TEST FROM HERE" if expanded else "▸  TEST FROM HERE")
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = expanded
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toggle_btn.tooltip_text = "Save the journey and play it from this node, with optional starting score / coins / flags."
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var panel: VBoxContainer = VBoxContainer.new()
	panel.add_theme_constant_override("separation", 4)
	panel.visible = expanded
	wrapper.add_child(panel)

	# Primary action: save the journey and play the real runtime starting at this node.
	var btn: Button = UITheme.make_icon_btn("▶  PLAY FROM HERE", false, UITheme.SUCCESS)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.tooltip_text = "Save the journey and play it in the real runtime starting at this node."
	btn.pressed.connect(func() -> void: _owner._save_and_test_from(item, arr))
	panel.add_child(btn)

	# Starting score / coins for the preview. Mainly for Conditional / Sacrifice
	# forks, which read last-round score and coin balance to resolve. Persist on
	# the owner so they survive selection changes.
	panel.add_child(_side_field_label("TEST SEEDS  (SCORE / COINS)"))
	var seed_row: HBoxContainer = HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	seed_row.add_child(
		_make_seed_spin(_owner._test_seed_score, func(v: int) -> void: _owner._test_seed_score = v)
	)
	seed_row.add_child(
		_make_seed_spin(_owner._test_seed_coins, func(v: int) -> void: _owner._test_seed_coins = v)
	)
	panel.add_child(seed_row)

	# Pre-set flags for the test run, so flag-gated forks can be exercised from a mid-journey node.
	panel.add_child(_side_field_label("SEED FLAGS  (COMMA-SEPARATED)"))
	var flag_edit: LineEdit = LineEdit.new()
	flag_edit.placeholder_text = "e.g. spared_boss"
	flag_edit.text = ", ".join(
		PackedStringArray(JourneyData.clean_flag_list(_owner._test_seed_flags))
	)
	UITheme.style_line_edit(flag_edit)
	flag_edit.text_changed.connect(
		func(v: String) -> void:
			_owner._test_seed_flags = JourneyData.clean_flag_list(Array(v.split(",")))
	)
	panel.add_child(flag_edit)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = ("▾  TEST FROM HERE" if pressed else "▸  TEST FROM HERE")
			panel.visible = pressed
			_owner._test_panel_expanded = pressed
	)
	return wrapper


# One expanding integer SpinBox for the test-seed row, writing through `setter`.
func _make_seed_spin(value: int, setter: Callable) -> SpinBox:
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 9999999
	spin.step = 1
	spin.value = value
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: setter.call(int(v)))
	return spin


# Group-action panel shown when 2+ nodes are selected. Lists the selection and
# offers Copy / Cut / Delete and block Move Up / Down — all routed to the owner's
# set-based operations. No per-field editing while multiple are selected.

# ── Internal: per-type editors ──────────────────────────────────────────────


# Dispatches to the right inline editor based on item type. The editors work directly
# on the passed array reference (arr = [node.data]), so field edits persist into the
# graph node in place.
func _build_side_panel_editor(
	container: VBoxContainer,
	item: Dictionary,
	arr: Array,
	idx: int,
	reselect_override: Callable = Callable()
) -> void:
	var item_type: String = item.get("type", "round")

	var hdr: Label = Label.new()
	var accent: Color
	match item_type:
		"round":
			hdr.text = "// ROUND //"
			accent = UITheme.PURPLE_BRIGHT
		"shop":
			hdr.text = "// SHOP //"
			accent = UITheme.PURPLE_BRIGHT
		"storyboard":
			hdr.text = "// STORYBOARD //"
			accent = UITheme.STORYBOARD
		_:
			hdr.text = "// ITEM //"
			accent = UITheme.PURPLE_MID
	hdr.add_theme_color_override("font_color", accent)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	container.add_child(hdr)

	# Called by the editors after a structural change (move / delete / add line) to re-show the
	# node (the graph editor passes a re-show-by-node-id callback).
	var reselect: Callable = reselect_override

	match item_type:
		"round":
			container.add_child(_make_side_round_editor(arr, idx, reselect))
		"shop":
			container.add_child(_make_side_shop_editor(arr, idx))
		"storyboard":
			container.add_child(_make_side_storyboard_editor(arr, idx, reselect))


# ── Internal: small helpers ─────────────────────────────────────────────────


func _side_field_label(text: String) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.uppercase = true
	return lbl


func _side_section_separator() -> Control:
	var spacer: Control = Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	return spacer


# A visible horizontal divider line (thin, in the separator colour) marking a major break between
# side-panel groups — heavier than the subtle _side_section_separator spacer. Used between a node's
# content editor and its operations block (connect / duplicate / delete / add).
func _side_divider_line() -> HSeparator:
	var line: HSeparator = HSeparator.new()
	line.add_theme_constant_override("separation", 13)
	var sb: StyleBoxLine = StyleBoxLine.new()
	sb.color = UITheme.SEPARATOR
	sb.thickness = 1
	line.add_theme_stylebox_override("separator", sb)
	return line


# Fills `lbl` with a round's funscript length + action count (e.g. "4:32 · 812
# actions"), or flags an empty/missing script. Cleared when no funscript is set.
func _update_funscript_readout(lbl: Label, path: String) -> void:
	if path == "":
		lbl.text = ""
		return
	var stats: Dictionary = JourneyData.read_funscript_stats(path)
	var count: int = stats["count"]
	if count <= 0:
		lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
		lbl.text = "⚠ funscript has no actions"
		return
	lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	lbl.text = "%s  ·  %d actions" % [_format_duration(stats["length_ms"]), count]


# Formats milliseconds as m:ss for the funscript readout.
func _format_duration(ms: int) -> String:
	var total_s: int = int(round(ms / 1000.0))
	return "%d:%02d" % [total_s / 60, total_s % 60]


# ── Internal: round / shop / storyboard / fork inline editors ──────────────


func _make_side_round_editor(arr: Array, idx: int, reselect: Callable) -> Control:
	var round_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	# Multi-drop hint — shown at the top so it's the first thing the user sees.
	var drop_hint: Label = Label.new()
	drop_hint.text = "TIP: DROP ALL SCRIPTS AT ONCE TO AUTO-ROUTE BY AXIS"
	drop_hint.add_theme_color_override(
		"font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
	)
	drop_hint.add_theme_font_size_override("font_size", 10)
	drop_hint.uppercase = true
	drop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drop_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(drop_hint)

	col.add_child(_side_field_label("ROUND NAME"))
	var name_edit: LineEdit = LineEdit.new()
	name_edit.placeholder_text = "Round name..."
	name_edit.text = round_data.get("name", "")
	UITheme.style_line_edit(name_edit)
	name_edit.text_changed.connect(func(val: String) -> void: arr[idx]["name"] = val)
	col.add_child(name_edit)

	# ── Media & scripts ─────────────────────────────────────────────────────────
	col.add_child(_side_divider_line())
	col.add_child(_side_field_label("VIDEO FILE"))
	var video_zone: PanelContainer = DropZoneScript.new()
	video_zone.accepted_extensions = JourneyData.VIDEO_EXTENSIONS.duplicate()
	video_zone.picker_title = "Select Video"
	video_zone.picker_filters = [
		"*.mp4,*.m4v,*.mkv,*.avi,*.mov,*.wmv,*.webm ; Video Files", "*.* ; All Files"
	]
	video_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(video_zone)
	if round_data.get("video_path", "") != "":
		video_zone.call_deferred("set_file", round_data["video_path"], false)
	video_zone.file_dropped.connect(
		func(p: String) -> void:
			arr[idx]["video_path"] = p
			if (arr[idx].get("name", "") as String).strip_edges() == "":
				arr[idx]["name"] = p.get_file().get_basename()
			# Auto-fill the funscript + any secondary axis / vib scripts from same-
			# named siblings on disk, then rebuild so the DropZones show them.
			if ImportScanner.autofill_round_siblings(arr[idx], p):
				_owner._show_status("Auto-filled matching scripts from file names.", false)
				reselect.call(idx)
				return
			name_edit.text = arr[idx].get("name", "")
			_owner._refresh_graph()  # update the node's validation badge live
	)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("FUNSCRIPT"))
	# Declared before the drop handler so the closure can refresh it in place.
	var fs_stats_lbl: Label = Label.new()
	fs_stats_lbl.add_theme_font_size_override("font_size", 11)
	fs_stats_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
	var fs_zone: PanelContainer = DropZoneScript.new()
	fs_zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
	fs_zone.picker_title = "Select Funscript"
	fs_zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
	fs_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Zone + inline ✕ remove (disabled until a funscript is set).
	var fs_rm: Button = UITheme.make_icon_btn(
		"✕", round_data.get("funscript_path", "") == "", UITheme.MAGENTA
	)
	fs_rm.tooltip_text = "Remove funscript"
	fs_rm.pressed.connect(func() -> void: fs_zone.set_file(""))
	var fs_row: HBoxContainer = HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 6)
	fs_row.add_child(fs_zone)
	fs_row.add_child(fs_rm)
	col.add_child(fs_row)
	if round_data.get("funscript_path", "") != "":
		fs_zone.call_deferred("set_file", round_data["funscript_path"], false)
	fs_zone.file_dropped.connect(
		func(p: String) -> void:
			arr[idx]["funscript_path"] = p
			_update_funscript_readout(fs_stats_lbl, p)
			fs_rm.disabled = (p == "")
			# Removal (cleared zone): nothing to auto-fill or rename — just refresh.
			if p == "":
				_owner._refresh_graph()
				return
			if (arr[idx].get("name", "") as String).strip_edges() == "":
				arr[idx]["name"] = p.get_file().get_basename()
			# Auto-fill the video + any secondary axis / vib scripts from same-named
			# siblings on disk, then rebuild so the DropZones show them.
			if ImportScanner.autofill_round_siblings(arr[idx], p):
				_owner._show_status("Auto-filled matching scripts from file names.", false)
				reselect.call(idx)
				return
			name_edit.text = arr[idx].get("name", "")
			_owner._refresh_graph()  # update the node's validation badge live
	)
	# Length / action-count readout (sits just under the funscript zone).
	_update_funscript_readout(fs_stats_lbl, round_data.get("funscript_path", ""))
	col.add_child(fs_stats_lbl)

	# Preview the funscript curve (and any stroke modifiers a boss / cursed /
	# blessed round applies to it) in a graph overlay. Enabled once a funscript
	# is attached.
	var preview_btn: Button = UITheme.make_icon_btn(
		"📈 PREVIEW FUNSCRIPT", round_data.get("funscript_path", "") == "", UITheme.CYAN
	)
	preview_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_btn.pressed.connect(
		func() -> void:
			FunscriptPreview.new().open(
				_owner,
				arr[idx].get("funscript_path", ""),
				arr[idx].get("video_path", ""),
				_round_preview_modifiers(arr[idx]),
				arr[idx].get("name", ""),
				_round_preview_label(arr[idx])
			)
	)
	col.add_child(preview_btn)

	# Secondary device scripts (optional, collapsed) — they round out the media group.
	col.add_child(_side_section_separator())
	col.add_child(_make_axis_expander(arr, idx))

	col.add_child(_side_section_separator())
	col.add_child(_make_vib_expander(arr, idx))

	# ── Rewards & state ─────────────────────────────────────────────────────────
	col.add_child(_side_divider_line())
	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_spin: SpinBox = SpinBox.new()
	coins_spin.min_value = 0
	coins_spin.max_value = 999999
	coins_spin.step = 1
	coins_spin.value = round_data.get("coins", 0)
	coins_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(coins_spin)
	coins_spin.value_changed.connect(func(v: float) -> void: arr[idx]["coins"] = int(v))
	col.add_child(coins_spin)

	# Flags this round sets when it plays (read by flag-conditional forks downstream).
	col.add_child(_side_section_separator())
	col.add_child(_make_set_flags_field(arr[idx]))

	# ── Round behavior (checkpoint + the mutually-exclusive round types) ─────────
	col.add_child(_side_divider_line())
	col.add_child(_make_checkpoint_toggle(arr, idx))

	col.add_child(_side_section_separator())
	col.add_child(_make_boss_expander(arr, idx, reselect))

	col.add_child(_side_section_separator())
	col.add_child(_make_cursed_toggle(arr, idx, reselect))

	col.add_child(_side_section_separator())
	col.add_child(_make_blessed_toggle(arr, idx, reselect))
	return col


func _make_side_shop_editor(arr: Array, idx: int) -> Control:
	var shop_data: Dictionary = arr[idx]
	# Backfill config defaults so first-time edits have keys to write to.
	if not shop_data.has("mode"):
		shop_data["mode"] = "pool"
	if not shop_data.has("count"):
		shop_data["count"] = 3
	if not shop_data.has("items"):
		shop_data["items"] = []
	if not shop_data.has("guaranteed"):
		shop_data["guaranteed"] = []
	if not shop_data.has("price_multiplier"):
		shop_data["price_multiplier"] = 1.0

	# Item registry — also bounds the pool-draw count, since a draw can never
	# yield more distinct items than exist. Clamp any stale/out-of-range count.
	var all_item_ids: Array = InventoryService.GetAllItemIds()
	var item_count: int = all_item_ids.size()
	shop_data["count"] = clampi(int(shop_data.get("count", 3)), 1, max(1, item_count))

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("SHOP TITLE"))
	var title_edit: LineEdit = LineEdit.new()
	title_edit.placeholder_text = "Shop title (optional)..."
	title_edit.text = shop_data.get("title", "")
	UITheme.style_line_edit(title_edit)
	title_edit.text_changed.connect(func(val: String) -> void: arr[idx]["title"] = val)
	col.add_child(title_edit)

	# Selection mode — random pool draw vs. a fixed authored lineup.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("ITEM SELECTION"))
	var mode_dd: OptionButton = OptionButton.new()
	mode_dd.add_item("RANDOM FROM POOL")  # index 0 → "pool"
	mode_dd.add_item("FIXED LINEUP")  # index 1 → "fixed"
	mode_dd.selected = 1 if shop_data.get("mode", "pool") == "fixed" else 0
	mode_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(mode_dd)
	col.add_child(mode_dd)

	# Item count — only consulted in pool mode; disabled in fixed mode where the
	# lineup length is the checklist itself. Clamped to [1, item registry size].
	col.add_child(_side_field_label("ITEMS SHOWN (POOL MODE)"))
	var count_spin: SpinBox = SpinBox.new()
	count_spin.min_value = 1
	count_spin.max_value = max(1, item_count)
	count_spin.step = 1
	count_spin.value = clampi(int(shop_data.get("count", 3)), 1, max(1, item_count))
	count_spin.editable = shop_data.get("mode", "pool") == "pool"
	count_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(count_spin)
	count_spin.value_changed.connect(func(v: float) -> void: arr[idx]["count"] = int(v))
	col.add_child(count_spin)

	# Two per-mode checklists over the same registry: fixed mode picks the exact
	# lineup ("items"); pool mode picks the always-included subset ("guaranteed" —
	# the rest of the lineup is drawn randomly). Both lists persist across mode
	# switches so toggling the dropdown is non-destructive.
	var fixed_section: VBoxContainer = _shop_item_checklist(
		arr, idx, "items", "ITEMS", "PICK THE EXACT ITEMS THIS SHOP SELLS.", all_item_ids
	)
	fixed_section.visible = shop_data.get("mode", "pool") == "fixed"
	col.add_child(fixed_section)

	var pool_section: VBoxContainer = _shop_item_checklist(
		arr,
		idx,
		"guaranteed",
		"GUARANTEED IN LINEUP",
		"CHECKED ITEMS ALWAYS APPEAR; THE REST OF THE LINEUP IS DRAWN RANDOMLY.",
		all_item_ids
	)
	pool_section.visible = shop_data.get("mode", "pool") == "pool"
	col.add_child(pool_section)

	mode_dd.item_selected.connect(
		func(sel: int) -> void:
			arr[idx]["mode"] = "fixed" if sel == 1 else "pool"
			fixed_section.visible = sel == 1
			pool_section.visible = sel == 0
			count_spin.editable = sel == 0
	)

	# Price multiplier — applied on top of each item's base price.
	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("PRICE MULTIPLIER"))
	var mult_spin: SpinBox = SpinBox.new()
	mult_spin.min_value = 0.1
	mult_spin.max_value = 100.0
	mult_spin.step = 0.1
	mult_spin.value = float(shop_data.get("price_multiplier", 1.0))
	mult_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(mult_spin)
	mult_spin.value_changed.connect(func(v: float) -> void: arr[idx]["price_multiplier"] = v)
	col.add_child(mult_spin)
	return col


# ⚖ ON ARRIVAL — the audit's view of the player state reaching this node:
# coins/last-round-score bounds (interval walk) + averages and reach share
# (Monte-Carlo). Reads the owner's cached audit; a structural edit invalidates
# it, so the block offers COMPUTE (no cache) or ⟳ REFRESH (stale-able cache).
func _make_arrival_audit_block(node_id: String) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label("⚖ ON ARRIVAL"))

	var info: Dictionary = _owner.audit_arrival_info(node_id)
	if info.is_empty():
		var hint: Label = Label.new()
		hint.text = "COMPUTE THE AUDIT TO SEE COINS / SCORE ARRIVING AT THIS NODE."
		hint.add_theme_color_override(
			"font_color",
			Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
		)
		hint.add_theme_font_size_override("font_size", 10)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(hint)
	else:
		box.add_child(
			_arrival_stat_row(
				"COINS",
				(
					"♦ %d – %d   (avg ≈ %d)"
					% [info["coins_lo"], info["coins_hi"], roundi(info["coins_avg"])]
				)
			)
		)
		box.add_child(
			_arrival_stat_row(
				"LAST SCORE",
				(
					"%d – %d   (avg ≈ %d)"
					% [info["score_lo"], info["score_hi"], roundi(info["score_avg"])]
				)
			)
		)
		box.add_child(
			_arrival_stat_row("REACHED IN", "%.0f%% OF SIMULATED RUNS" % float(info["seen_pct"]))
		)

	var btn: Button = UITheme.make_icon_btn(
		"⚖ COMPUTE" if info.is_empty() else "⟳ REFRESH", false, UITheme.PURPLE_MID
	)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: _owner.refresh_arrival_audit(node_id))
	box.add_child(btn)
	return box


func _arrival_stat_row(key_text: String, value_text: String) -> Control:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var key: Label = Label.new()
	key.text = key_text
	key.custom_minimum_size = Vector2(84, 0)
	key.add_theme_color_override("font_color", UITheme.PURPLE_MID)
	key.add_theme_font_size_override("font_size", 10)
	row.add_child(key)
	var value: Label = Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	value.add_theme_font_size_override("font_size", 11)
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.clip_text = true
	row.add_child(value)
	return row


# A labelled item-registry checklist section whose checked ids are written to
# shop_data[key]. Used twice by the shop editor: the fixed lineup ("items") and
# the pool-mode guaranteed subset ("guaranteed").
func _shop_item_checklist(
	arr: Array, idx: int, key: String, label: String, hint_text: String, all_item_ids: Array
) -> VBoxContainer:
	var section: VBoxContainer = VBoxContainer.new()
	section.add_theme_constant_override("separation", 6)

	section.add_child(_side_section_separator())
	section.add_child(_side_field_label(label))
	var hint: Label = Label.new()
	hint.text = hint_text
	hint.add_theme_color_override(
		"font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.7)
	)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	section.add_child(hint)

	for item_id: String in all_item_ids:
		var item_data: Dictionary = InventoryService.GetItemData(item_id)
		var cb: CheckBox = CheckBox.new()
		cb.text = "%s  (♦%d)" % [item_data.get("name", item_id), item_data.get("price", 0)]
		cb.button_pressed = item_id in (arr[idx].get(key, []) as Array)
		cb.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
		cb.add_theme_font_size_override("font_size", 12)
		cb.toggled.connect(
			func(pressed: bool) -> void:
				var list: Array = arr[idx][key]
				if pressed and item_id not in list:
					list.append(item_id)
				elif not pressed:
					list.erase(item_id)
		)
		section.add_child(cb)
	return section


func _make_side_storyboard_editor(arr: Array, idx: int, reselect: Callable) -> Control:
	var sb_data: Dictionary = arr[idx]
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)

	col.add_child(_side_field_label("COINS AWARDED"))
	var coins_spin: SpinBox = SpinBox.new()
	coins_spin.min_value = 0
	coins_spin.max_value = 999999
	coins_spin.step = 1
	coins_spin.value = sb_data.get("coins", 0)
	coins_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(coins_spin)
	coins_spin.value_changed.connect(func(v: float) -> void: arr[idx]["coins"] = int(v))
	col.add_child(coins_spin)

	# Optional item reward — granted (alongside coins) when the storyboard ends.
	col.add_child(_side_field_label("ITEM REWARD  (OPTIONAL)"))
	var item_values: Array = [""]
	var item_dd: OptionButton = OptionButton.new()
	item_dd.add_item("None")
	for k: String in InventoryService.GetAllItemIds():
		item_values.append(k)
		item_dd.add_item(str(InventoryService.GetItemData(k).get("name", k)))
	item_dd.selected = max(0, item_values.find(str(sb_data.get("item", ""))))
	item_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(item_dd)
	item_dd.item_selected.connect(func(i: int) -> void: arr[idx]["item"] = item_values[i])
	col.add_child(item_dd)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DEFAULT IMAGE"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Default Image"
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if sb_data.get("image", "") != "":
		img_zone.call_deferred("set_file", sb_data["image"])
	var sb_rm_btn: Button = Button.new()
	sb_rm_btn.text = "✕ REMOVE DEFAULT IMAGE"
	sb_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb_rm_btn.visible = sb_data.get("image", "") != ""
	UITheme.style_button(sb_rm_btn, UITheme.MAGENTA)
	sb_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(arr[idx].get("image", ""))
			arr[idx]["image"] = ""
			img_zone.call_deferred("set_file", "")
			sb_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			arr[idx]["image"] = p
			sb_rm_btn.visible = true
	)
	col.add_child(sb_rm_btn)

	col.add_child(_side_section_separator())
	col.add_child(_side_field_label("DIALOGUE LINES"))

	var lines_arr: Array = sb_data.get("lines", [])
	if not sb_data.has("lines"):
		arr[idx]["lines"] = lines_arr

	var lines_col: VBoxContainer = VBoxContainer.new()
	lines_col.add_theme_constant_override("separation", 6)
	col.add_child(lines_col)

	var refresh_self: Callable = func() -> void: reselect.call(idx)

	# Opening slot — insert before the first line (also serves as "add first line").
	lines_col.add_child(_make_insert_line_btn(lines_arr, 0, refresh_self))

	for li in lines_arr.size():
		lines_col.add_child(_make_side_storyboard_line_block(lines_arr, li, refresh_self))
		# Slot after each line; the last one doubles as "append at end".
		lines_col.add_child(_make_insert_line_btn(lines_arr, li + 1, refresh_self))

	var paste_btn: Button = Button.new()
	paste_btn.text = "⎘ PASTE LINES"
	paste_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(paste_btn, UITheme.PURPLE_MID)
	paste_btn.pressed.connect(func() -> void: _show_paste_lines_popup(lines_arr, refresh_self))
	col.add_child(paste_btn)
	return col


# Opens a popup with a large TextEdit. Each non-empty line of the pasted text
# becomes a new dialogue line. Format: "SPEAKER: text" splits on the first
# colon; lines without a colon become narration (no speaker).
func _show_paste_lines_popup(lines_arr: Array, refresh_storyboard: Callable) -> void:
	var popup: PopupPanel = PopupPanel.new()
	_owner.add_child(popup)

	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG
	panel_style.border_color = UITheme.STORYBOARD
	panel_style.border_width_left = 2
	panel_style.border_width_right = 2
	panel_style.border_width_top = 2
	panel_style.border_width_bottom = 2
	panel_style.content_margin_left = 16
	panel_style.content_margin_right = 16
	panel_style.content_margin_top = 16
	panel_style.content_margin_bottom = 16
	popup.add_theme_stylebox_override("panel", panel_style)

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	popup.add_child(vbox)

	var hdr: Label = Label.new()
	hdr.text = "// PASTE DIALOGUE LINES //"
	hdr.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr.add_theme_font_size_override("font_size", 14)
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hdr)

	var hint: Label = Label.new()
	hint.text = "ONE LINE PER DIALOGUE.  FORMAT:  SPEAKER: text  (LINES WITHOUT A COLON BECOME NARRATION.)"
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)

	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text = "ARIA: Hello there.\nThe wind howled outside.\nKAI: It's getting cold."
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.size_flags_vertical = Control.SIZE_FILL
	text_edit.custom_minimum_size = Vector2(0, 200)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	vbox.add_child(text_edit)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(cancel_btn, UITheme.PURPLE_MID)
	cancel_btn.pressed.connect(func() -> void: popup.queue_free())
	btn_row.add_child(cancel_btn)

	var apply_btn: Button = Button.new()
	apply_btn.text = "+ APPEND LINES"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(apply_btn, UITheme.STORYBOARD)
	apply_btn.pressed.connect(
		func() -> void:
			var parsed: Array = _parse_pasted_lines(text_edit.text)
			for line: Dictionary in parsed:
				lines_arr.append(line)
			popup.queue_free()
			refresh_storyboard.call()
	)
	btn_row.add_child(apply_btn)

	popup.popup_centered_clamped(Vector2i(720, 560), 0.9)
	text_edit.grab_focus()


# Parses a pasted multi-line block into dialogue-line dicts.
# Format: "SPEAKER: text" → {speaker: "SPEAKER", text: "text"}.
# Lines without a colon become narration: {speaker: "", text: "<line>"}.
# Blank lines are skipped.
func _parse_pasted_lines(raw: String) -> Array:
	var result: Array = []
	for raw_line in raw.split("\n"):
		var line: String = (raw_line as String).strip_edges()
		if line == "":
			continue
		var colon_idx: int = line.find(":")
		if colon_idx > 0:
			var speaker: String = line.substr(0, colon_idx).strip_edges()
			var text: String = line.substr(colon_idx + 1).strip_edges()
			result.append({"speaker": speaker, "text": text, "image": ""})
		else:
			result.append({"speaker": "", "text": line, "image": ""})
	return result


# Per-line sub-block for the storyboard side editor: speaker, text (multi-line),
# optional per-line image override, and line move/remove buttons.
func _make_side_storyboard_line_block(
	lines_arr: Array, line_idx: int, refresh_storyboard: Callable
) -> Control:
	var line_data: Dictionary = lines_arr[line_idx]

	var panel: PanelContainer = PanelContainer.new()
	var ps: StyleBoxFlat = StyleBoxFlat.new()
	ps.bg_color = UITheme.PANEL_BG
	ps.border_color = Color(UITheme.STORYBOARD.r, UITheme.STORYBOARD.g, UITheme.STORYBOARD.b, 0.35)
	ps.border_width_left = 1
	ps.border_width_right = 1
	ps.border_width_top = 1
	ps.border_width_bottom = 1
	ps.content_margin_left = 10
	ps.content_margin_right = 10
	ps.content_margin_top = 8
	ps.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", ps)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	panel.add_child(col)

	var hdr_lbl: Label = Label.new()
	hdr_lbl.text = "LINE %d" % (line_idx + 1)
	hdr_lbl.add_theme_color_override("font_color", UITheme.STORYBOARD)
	hdr_lbl.add_theme_font_size_override("font_size", 11)
	hdr_lbl.uppercase = true
	col.add_child(hdr_lbl)

	col.add_child(_side_field_label("SPEAKER"))
	var speaker_edit: LineEdit = LineEdit.new()
	speaker_edit.placeholder_text = "Speaker (optional)..."
	speaker_edit.text = line_data.get("speaker", "")
	UITheme.style_line_edit(speaker_edit)
	speaker_edit.text_changed.connect(
		func(val: String) -> void: lines_arr[line_idx]["speaker"] = val
	)
	col.add_child(speaker_edit)

	col.add_child(_side_field_label("DIALOGUE"))
	var text_edit: TextEdit = TextEdit.new()
	text_edit.placeholder_text = "Dialogue text..."
	text_edit.text = line_data.get("text", "")
	text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_edit.custom_minimum_size = Vector2(0, 90)
	text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	UITheme.style_text_edit(text_edit)
	text_edit.text_changed.connect(func() -> void: lines_arr[line_idx]["text"] = text_edit.text)
	col.add_child(text_edit)

	col.add_child(_side_field_label("SPEAKER IMAGE (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Speaker Image for Line %d" % (line_idx + 1)
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(img_zone)
	if line_data.get("image", "") != "":
		img_zone.call_deferred("set_file", line_data["image"])
	var line_rm_btn: Button = Button.new()
	line_rm_btn.text = "✕ REMOVE IMAGE"
	line_rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_rm_btn.visible = line_data.get("image", "") != ""
	UITheme.style_button(line_rm_btn, UITheme.MAGENTA)
	line_rm_btn.pressed.connect(
		func() -> void:
			_delete_saved_image(lines_arr[line_idx].get("image", ""))
			lines_arr[line_idx]["image"] = ""
			img_zone.call_deferred("set_file", "")
			line_rm_btn.visible = false
	)
	img_zone.file_dropped.connect(
		func(p: String) -> void:
			lines_arr[line_idx]["image"] = p
			line_rm_btn.visible = p != ""
	)
	col.add_child(line_rm_btn)

	# "Use image from line above" — shown for every line except the first.
	if line_idx > 0:
		var ref_btn: Button = Button.new()
		ref_btn.text = "↑  USE IMAGE FROM LINE ABOVE"
		ref_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(ref_btn, UITheme.STORYBOARD)
		ref_btn.pressed.connect(
			func() -> void:
				var prev_image: String = lines_arr[line_idx - 1].get("image", "")
				if prev_image == "":
					return
				img_zone.set_file(prev_image)  # emits file_dropped → updates dict + rm btn
		)
		col.add_child(ref_btn)

	# Line action row (move + delete).
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var up_btn: Button = UITheme.make_icon_btn("↑", line_idx == 0, UITheme.STORYBOARD)
	up_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	up_btn.pressed.connect(
		func() -> void:
			if line_idx <= 0:
				return
			var tmp: Dictionary = lines_arr[line_idx]
			lines_arr[line_idx] = lines_arr[line_idx - 1]
			lines_arr[line_idx - 1] = tmp
			refresh_storyboard.call()
	)
	row.add_child(up_btn)
	var dn_btn: Button = UITheme.make_icon_btn(
		"↓", line_idx == lines_arr.size() - 1, UITheme.STORYBOARD
	)
	dn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dn_btn.pressed.connect(
		func() -> void:
			if line_idx >= lines_arr.size() - 1:
				return
			var tmp: Dictionary = lines_arr[line_idx]
			lines_arr[line_idx] = lines_arr[line_idx + 1]
			lines_arr[line_idx + 1] = tmp
			refresh_storyboard.call()
	)
	row.add_child(dn_btn)
	var rm_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.MAGENTA)
	rm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rm_btn.pressed.connect(
		func() -> void:
			lines_arr.remove_at(line_idx)
			refresh_storyboard.call()
	)
	row.add_child(rm_btn)
	col.add_child(row)

	return panel


# Thin "insert a new line here" button placed between line blocks in the
# storyboard editor.  Subtle by default, highlights on hover so it doesn't
# compete visually with the line content above/below it.
func _make_insert_line_btn(lines_arr: Array, insert_at: int, refresh: Callable) -> Control:
	var btn: Button = Button.new()
	btn.text = "╋  INSERT LINE"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 24)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 10)

	var c: Color = UITheme.STORYBOARD

	var s_n: StyleBoxFlat = StyleBoxFlat.new()
	s_n.bg_color = Color(c.r, c.g, c.b, 0.04)
	s_n.border_color = Color(c.r, c.g, c.b, 0.22)
	s_n.border_width_left = 1
	s_n.border_width_right = 1
	s_n.border_width_top = 1
	s_n.border_width_bottom = 1
	s_n.content_margin_top = 2
	s_n.content_margin_bottom = 2
	s_n.set_corner_radius_all(UITheme.CORNER_RADIUS)
	btn.add_theme_stylebox_override("normal", s_n)

	var s_h: StyleBoxFlat = s_n.duplicate()
	s_h.bg_color = Color(c.r, c.g, c.b, 0.15)
	s_h.border_color = c
	btn.add_theme_stylebox_override("hover", s_h)

	var s_p: StyleBoxFlat = s_n.duplicate()
	s_p.bg_color = Color(c.r, c.g, c.b, 0.28)
	btn.add_theme_stylebox_override("pressed", s_p)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	btn.add_theme_color_override("font_color", Color(c.r, c.g, c.b, 0.45))
	btn.add_theme_color_override("font_hover_color", c)
	btn.add_theme_color_override("font_pressed_color", c)

	btn.pressed.connect(
		func() -> void:
			lines_arr.insert(insert_at, {"speaker": "", "text": "", "image": ""})
			refresh.call()
	)
	return btn


# Adds a labeled integer SpinBox to `container` that writes its value back to
# paths_arr[pi][key]. Shared by the per-path weight / cost / threshold fields.
func _add_path_int_field(
	container: VBoxContainer, paths_arr: Array, pi: int, key: String, label: String, max_value: int
) -> void:
	container.add_child(_side_field_label(label))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = max_value
	spin.step = 1
	spin.value = int(paths_arr[pi].get(key, 0))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: paths_arr[pi][key] = int(v))
	container.add_child(spin)


# Adds a "required item" label + dropdown (with a None/free option) to `container`,
# writing the chosen item id (or "" for none) to paths_arr[pi].required_item.
# Shared by Sacrifice (consumed) and item-Conditional (checked).
func _add_required_item_field(
	container: VBoxContainer, paths_arr: Array, pi: int, path: Dictionary, label: String
) -> void:
	container.add_child(_side_field_label(label))
	var values: Array = [""]
	var item_ids: Array = InventoryService.GetAllItemIds()
	var dd: OptionButton = OptionButton.new()
	dd.add_item("None (free)")
	for k: String in item_ids:
		values.append(k)
		dd.add_item(str(InventoryService.GetItemData(k).get("name", k)))
	dd.selected = max(0, values.find(str(path.get("required_item", ""))))
	dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(dd)
	dd.item_selected.connect(func(i: int) -> void: paths_arr[pi]["required_item"] = values[i])
	container.add_child(dd)


# Short human description of a fork resolution type for the editor.
func _fork_resolution_hint(resolution: String, metric: String, decider: String) -> String:
	match resolution:
		"choice":
			return "The player picks a path."
		"random":
			return "The game picks a path at random, weighted by each path's weight (reveal shown)."
		"conditional":
			if decider == "player":
				match metric:
					"score":
						return "The player picks — but only paths whose score threshold the last round met are selectable (plus the default, always available)."
					"coins":
						return "The player picks — but only paths whose coin threshold the balance meets are selectable (plus the default). Coins are NOT spent."
					"item":
						return "The player picks — but only paths whose required item the player owns are selectable (plus the default). The item is NOT consumed."
					"flag":
						return "The player picks — but only paths whose required flag is set are selectable (plus the default)."
				return "The player picks among the paths they qualify for (plus the default)."
			match metric:
				"score":
					return "The game auto-picks the highest path whose score threshold the last round met, else the default path."
				"coins":
					return "The game auto-picks the highest path whose coin threshold the player's balance meets, else the default path. Coins are NOT spent."
				"item":
					return "The game auto-picks the first path whose required item the player owns (a pure check — the item is NOT consumed), else the default path."
				"flag":
					return "The game auto-picks the first path whose required flag is set (by a node played or a choice taken earlier), else the default path."
		"sacrifice":
			return "The player picks a path and spends its cost — coins and/or an item (e.g. a Key), both consumed. Paths they can't afford are disabled, so include at least one free (0 coins, item None) path."
	return ""


# ── Extra axes expander ──────────────────────────────────────────────────────


# Collapsed "▶ EXTRA AXES (SERIAL ONLY)" expander with one DropZone per axis.
# Serial-only: Buttplug devices ignore all secondary axes.
func _make_axis_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("axis_scripts"):
		arr[idx]["axis_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  EXTRA AXES  (SERIAL ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var axes_panel: VBoxContainer = VBoxContainer.new()
	axes_panel.add_theme_constant_override("separation", 6)
	axes_panel.visible = false
	wrapper.add_child(axes_panel)

	var hint: Label = Label.new()
	hint.text = "SECONDARY-AXIS .FUNSCRIPT FILES FOR T-CODE SR6 / OSR2+ DEVICES.  SERIAL OUTPUT ONLY — IGNORED FOR BUTTPLUG."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	axes_panel.add_child(hint)

	for info: Dictionary in EXTRA_AXES_INFO:
		var axis: String = info["axis"]
		axes_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title = "Select %s Funscript" % axis
		zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var current_path: String = (arr[idx]["axis_scripts"] as Dictionary).get(axis, "")
		# Zone + inline ✕ remove (disabled until this axis is set).
		var rm: Button = UITheme.make_icon_btn("✕", current_path == "", UITheme.MAGENTA)
		rm.tooltip_text = "Remove %s funscript" % axis
		rm.pressed.connect(func() -> void: zone.set_file(""))
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(zone)
		row.add_child(rm)
		axes_panel.add_child(row)
		if current_path != "":
			zone.call_deferred("set_file", current_path, false)
		# Capture axis in closure.
		var captured_axis: String = axis
		zone.file_dropped.connect(
			func(p: String) -> void:
				rm.disabled = (p == "")
				if p == "":
					(arr[idx]["axis_scripts"] as Dictionary).erase(captured_axis)
				else:
					arr[idx]["axis_scripts"][captured_axis] = p
		)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = (
				"▼  EXTRA AXES  (SERIAL ONLY)" if pressed else "▶  EXTRA AXES  (SERIAL ONLY)"
			)
			axes_panel.visible = pressed
	)

	return wrapper


# ── Vibrator channel expander ────────────────────────────────────────────────


# Collapsed "▶ VIBRATOR SCRIPTS (BUTTPLUG ONLY)" expander with one DropZone per
# vibration channel. Accepts .vib1 / .vib2 funscripts for multi-motor devices.
# When only vib1 is provided and the device has 2+ channels, FunscriptPlayer
# mirrors it automatically — no need to fill both unless you want distinct patterns.
func _make_vib_expander(arr: Array, idx: int) -> Control:
	# Ensure the dict key exists.
	if not arr[idx].has("vib_scripts"):
		arr[idx]["vib_scripts"] = {}

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = false
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.PURPLE_MID)
	wrapper.add_child(toggle_btn)

	var vib_panel: VBoxContainer = VBoxContainer.new()
	vib_panel.add_theme_constant_override("separation", 6)
	vib_panel.visible = false
	wrapper.add_child(vib_panel)

	var hint: Label = Label.new()
	hint.text = "PER-CHANNEL FUNSCRIPTS FOR MULTI-MOTOR VIBRATORS (E.G. WE-VIBE, LOVENSE NORA).  LEAVE EMPTY TO USE THE MAIN FUNSCRIPT FOR ALL CHANNELS."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vib_panel.add_child(hint)

	for info: Dictionary in VIB_CHANNELS_INFO:
		var ch_key: String = info["key"]
		vib_panel.add_child(_side_field_label(info["label"]))
		var zone: PanelContainer = DropZoneScript.new()
		zone.accepted_extensions = JourneyData.FUNSCRIPT_EXTENSIONS.duplicate()
		zone.picker_title = "Select %s Funscript" % ch_key.to_upper()
		zone.picker_filters = ["*.funscript,*.json ; Funscript Files", "*.* ; All Files"]
		zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var current_path: String = (arr[idx]["vib_scripts"] as Dictionary).get(ch_key, "")
		# Zone + inline ✕ remove (disabled until this channel is set).
		var rm: Button = UITheme.make_icon_btn("✕", current_path == "", UITheme.MAGENTA)
		rm.tooltip_text = "Remove %s funscript" % ch_key.to_upper()
		rm.pressed.connect(func() -> void: zone.set_file(""))
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(zone)
		row.add_child(rm)
		vib_panel.add_child(row)
		if current_path != "":
			zone.call_deferred("set_file", current_path, false)
		# Capture key in closure.
		var captured_key: String = ch_key
		zone.file_dropped.connect(
			func(p: String) -> void:
				rm.disabled = (p == "")
				if p == "":
					(arr[idx]["vib_scripts"] as Dictionary).erase(captured_key)
				else:
					arr[idx]["vib_scripts"][captured_key] = p
		)

	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			toggle_btn.text = (
				"▼  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
				if pressed
				else "▶  VIBRATOR SCRIPTS  (BUTTPLUG ONLY)"
			)
			vib_panel.visible = pressed
	)

	return wrapper


# ── Checkpoint toggle ───────────────────────────────────────────────────────


# Author-marked save point. When this round starts during play, the game shows
# a CHECKPOINT REACHED banner offering Save & Quit so the player can resume the
# run later. Works on any round type, including bosses — the banner is shown
# before the boss intro card, so the player can save out before committing.
func _make_checkpoint_toggle(arr: Array, idx: int) -> Control:
	if not arr[idx].has("is_checkpoint"):
		arr[idx]["is_checkpoint"] = false

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", ROW_SEP)
	wrapper.add_child(row)

	var label: Label = Label.new()
	label.text = "CHECKPOINT ROUND"
	label.add_theme_color_override("font_color", UITheme.AMBER)
	label.add_theme_font_size_override("font_size", 12)
	label.uppercase = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var toggle: Button = Button.new()
	toggle.toggle_mode = true
	toggle.button_pressed = arr[idx]["is_checkpoint"]
	toggle.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(toggle, UITheme.AMBER)
	toggle.text = "✓ ON" if arr[idx]["is_checkpoint"] else "OFF"
	toggle.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["is_checkpoint"] = pressed
			toggle.text = "✓ ON" if pressed else "OFF"
	)
	row.add_child(toggle)

	var hint: Label = Label.new()
	hint.text = "PLAYERS REACHING THIS ROUND SEE A CHECKPOINT BANNER WITH A SAVE & QUIT OPTION. USE FOR NATURAL STOPPING POINTS — END OF ACT, BEFORE A BIG BOSS, BETWEEN STORY ARCS."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wrapper.add_child(hint)

	return wrapper


# ── Boss round expander ──────────────────────────────────────────────────────


# A "BOSS ROUND" toggle that, when on, marks the round as a boss and reveals its
# config: an optional intro image, an optional tagline, and a list of forced
# modifiers the player cannot remove. Toggling off reverts it to a normal round.
func _make_boss_expander(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	if not arr[idx].has("boss_modifiers"):
		arr[idx]["boss_modifiers"] = []
	_migrate_sensory_boss_modifiers(arr, idx)

	var is_boss: bool = arr[idx]["round_type"] == "boss"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = ("▼  BOSS ROUND" if is_boss else "▶  BOSS ROUND")
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_boss
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.MAGENTA)
	wrapper.add_child(toggle_btn)

	var boss_panel: VBoxContainer = VBoxContainer.new()
	boss_panel.add_theme_constant_override("separation", 8)
	boss_panel.visible = is_boss
	wrapper.add_child(boss_panel)

	var hint: Label = Label.new()
	hint.text = "BOSS ROUNDS DISABLE ITEM USE, APPLY FORCED MODIFIERS THE PLAYER CANNOT REMOVE, AND OPEN WITH A TELEGRAPHED INTRO CARD."
	hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
	hint.add_theme_font_size_override("font_size", 10)
	hint.uppercase = true
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	boss_panel.add_child(hint)

	# Intro image (optional).
	boss_panel.add_child(_side_field_label("BOSS IMAGE  (OPTIONAL)"))
	var img_zone: PanelContainer = DropZoneScript.new()
	img_zone.accepted_extensions = JourneyData.IMAGE_EXTENSIONS.duplicate()
	img_zone.picker_title = "Select Boss Image"
	img_zone.picker_filters = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	img_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boss_panel.add_child(img_zone)
	if arr[idx].get("boss_image", "") != "":
		img_zone.call_deferred("set_file", arr[idx]["boss_image"])
	img_zone.file_dropped.connect(func(p: String) -> void: arr[idx]["boss_image"] = p)

	# Intro tagline (optional).
	boss_panel.add_child(_side_field_label("INTRO TAGLINE  (OPTIONAL)"))
	var tagline: LineEdit = LineEdit.new()
	tagline.placeholder_text = "A threat, a theme line..."
	tagline.text = arr[idx].get("boss_tagline", "")
	UITheme.style_line_edit(tagline)
	tagline.text_changed.connect(func(val: String) -> void: arr[idx]["boss_tagline"] = val)
	boss_panel.add_child(tagline)

	# Forced modifiers list.
	boss_panel.add_child(_side_field_label("FORCED MODIFIERS"))
	var mods_list: VBoxContainer = VBoxContainer.new()
	mods_list.add_theme_constant_override("separation", 6)
	boss_panel.add_child(mods_list)
	_rebuild_boss_modifiers(arr, idx, mods_list)

	var add_btn: Button = Button.new()
	add_btn.text = "+ ADD MODIFIER"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(add_btn, UITheme.PURPLE_MID)
	add_btn.pressed.connect(
		func() -> void:
			(arr[idx]["boss_modifiers"] as Array).append(_default_boss_modifier("scale"))
			_rebuild_boss_modifiers(arr, idx, mods_list)
	)
	boss_panel.add_child(add_btn)

	# Optional non-gameplay (visual/audio) modifiers the boss imposes alongside its
	# forced modifiers. Explicit-pick only for boss rounds — no random pool.
	boss_panel.add_child(_build_sensory_picker(arr, idx))

	# Rebuild on toggle so the round-type stays consistent with the Cursed toggle
	# (turning boss on clears cursed, and vice versa — they share round_type).
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "boss" if pressed else "normal"
			reselect.call(idx)
	)

	return wrapper


# Cursed-round toggle. Shares round_type with the boss toggle (mutually
# exclusive). A cursed round rolls a random negative modifier at the start;
# there's nothing to configure, so this is just a switch.
func _make_cursed_toggle(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	var is_cursed: bool = arr[idx]["round_type"] == "cursed"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "☠  CURSED ROUND  ✓" if is_cursed else "☠  CURSED ROUND"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_cursed
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.ERROR_SOFT)
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "cursed" if pressed else "normal"
			reselect.call(idx)
	)
	wrapper.add_child(toggle_btn)

	if is_cursed:
		var hint: Label = Label.new()
		hint.text = "A hex is applied at the start. Items stay usable; the player can pay to cleanse it, or endure it for the reward."
		hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
		hint.add_theme_font_size_override("font_size", 10)
		hint.uppercase = true
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wrapper.add_child(hint)

		wrapper.add_child(_make_reveal_toggle(arr, idx))
		wrapper.add_child(
			_make_cursed_int_field(arr, idx, "cleanse_cost", "CLEANSE COST (COINS)", 50)
		)
		wrapper.add_child(
			_make_cursed_int_field(arr, idx, "curse_reward", "ENDURE REWARD (COINS)", 0)
		)

		# Random vs fixed selection.
		var rand_toggle: CheckButton = CheckButton.new()
		rand_toggle.text = "RANDOM (roll the curse)"
		rand_toggle.add_theme_font_size_override("font_size", 12)
		rand_toggle.button_pressed = bool(arr[idx].get("curse_random", true))
		rand_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["curse_random"] = on)
		wrapper.add_child(rand_toggle)

		wrapper.add_child(_side_field_label("CURSES  (NONE TICKED = FULL RANDOM POOL)"))
		var selected: Array = arr[idx].get("curses", [])
		for entry: Dictionary in JourneyData.CURSE_CATALOG:
			var cname: String = str(entry.get("name", ""))
			var cb: CheckButton = CheckButton.new()
			cb.text = cname
			cb.tooltip_text = str(entry.get("desc", ""))
			cb.add_theme_font_size_override("font_size", 11)
			cb.button_pressed = cname in selected
			cb.toggled.connect(func(on: bool) -> void: _toggle_curse(arr, idx, cname, on))
			wrapper.add_child(cb)

		# Divider — sets the non-gameplay (visual/audio) section apart from the
		# gameplay curses above.
		wrapper.add_child(HSeparator.new())

		# Pool toggle sits above the picker. Ticked modifiers always apply; the
		# toggle additionally lets random sensory modifiers be rolled into the curse.
		var pool_toggle: CheckButton = CheckButton.new()
		pool_toggle.text = "INCLUDE IN RANDOM POOL"
		pool_toggle.tooltip_text = "When on, the random curse roll can also surface non-gameplay modifiers from the full sensory set (not just ticked ones)."
		pool_toggle.add_theme_font_size_override("font_size", 12)
		pool_toggle.button_pressed = bool(arr[idx].get("sensory_in_pool", false))
		pool_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["sensory_in_pool"] = on)
		wrapper.add_child(pool_toggle)

		wrapper.add_child(_build_sensory_picker(arr, idx))

	return wrapper


# Labeled int SpinBox bound to arr[idx][key]. Used by the cursed-round fields.
func _make_cursed_int_field(arr: Array, idx: int, key: String, label: String, def: int) -> Control:
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_side_field_label(label))
	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0
	spin.max_value = 999999
	spin.step = 1
	spin.value = int(arr[idx].get(key, def))
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_spin_box(spin)
	spin.value_changed.connect(func(v: float) -> void: arr[idx][key] = int(v))
	box.add_child(spin)
	return box


# Adds/removes a curse name from a cursed round's selected-curses list.
func _toggle_curse(arr: Array, idx: int, curse_name: String, on: bool) -> void:
	if not arr[idx].has("curses"):
		arr[idx]["curses"] = []
	var list: Array = arr[idx]["curses"]
	if on:
		if curse_name not in list:
			list.append(curse_name)
	else:
		list.erase(curse_name)


# A "Non-gameplay modifiers" checklist bound to arr[idx]["sensory"], split into
# Visual and Audio subsections. Shared by the boss and cursed editors.
func _build_sensory_picker(arr: Array, idx: int) -> Control:
	if not arr[idx].has("sensory"):
		arr[idx]["sensory"] = []
	var selected: Array = arr[idx]["sensory"]

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 4)

	# Collapsed by default to keep the panel tidy; auto-expanded when the round
	# already has modifiers so its setup is visible at a glance.
	var open: bool = not selected.is_empty()
	var header: Button = Button.new()
	header.toggle_mode = true
	header.button_pressed = open
	header.text = (
		("▼  NON-GAMEPLAY MODIFIERS  (%d)" % selected.size())
		if open
		else "▶  NON-GAMEPLAY MODIFIERS"
	)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(header, UITheme.PURPLE_MID)
	wrapper.add_child(header)

	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	content.visible = open
	wrapper.add_child(content)

	content.add_child(_side_field_label("VISUAL"))
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) not in JourneyData.AUDIO_SENSORY_KINDS:
			content.add_child(_make_sensory_row(arr, idx, entry, selected))

	content.add_child(HSeparator.new())
	content.add_child(_side_field_label("AUDIO"))
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) in JourneyData.AUDIO_SENSORY_KINDS:
			content.add_child(_make_sensory_row(arr, idx, entry, selected))

	header.toggled.connect(
		func(on: bool) -> void:
			content.visible = on
			header.text = (
				("▼  NON-GAMEPLAY MODIFIERS  (%d)" % (arr[idx].get("sensory", []) as Array).size())
				if on
				else "▶  NON-GAMEPLAY MODIFIERS"
			)
	)
	return wrapper


# One non-gameplay-modifier row: a tick (bound to the round's sensory list) and,
# for effects with an adjustable strength, an intensity control on its own
# indented line below — a slider plus a synced % spin box for precise entry. The
# control is only editable while the modifier is ticked; binary effects
# (Blinded/Silence) show no control.
func _make_sensory_row(arr: Array, idx: int, entry: Dictionary, selected: Array) -> Control:
	var sname: String = str(entry.get("name", ""))
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	var cb: CheckButton = CheckButton.new()
	cb.text = sname
	cb.tooltip_text = str(entry.get("desc", ""))
	cb.add_theme_font_size_override("font_size", 11)
	cb.button_pressed = sname in selected
	col.add_child(cb)

	if not entry.has("idef"):
		cb.toggled.connect(func(on: bool) -> void: _toggle_sensory(arr, idx, sname, on))
		return col

	# Intensity line, indented under the checkbox: slider (drag) + spin box (exact).
	var indent: MarginContainer = MarginContainer.new()
	indent.add_theme_constant_override("margin_left", 28)
	col.add_child(indent)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	indent.add_child(row)

	var slider: HSlider = HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.tooltip_text = "Intensity"
	row.add_child(slider)

	var spin: SpinBox = SpinBox.new()
	spin.min_value = 0.0
	spin.max_value = 100.0
	spin.step = 1.0
	spin.suffix = "%"
	spin.custom_minimum_size = Vector2(68, 0)
	UITheme.style_spin_box(spin)
	row.add_child(spin)

	var pct: float = _sensory_intensity_pct(arr, idx, entry)
	slider.set_value_no_signal(pct)
	spin.set_value_no_signal(pct)
	slider.editable = cb.button_pressed
	spin.editable = cb.button_pressed

	# Keep the two in sync without re-triggering each other, and persist the value.
	slider.value_changed.connect(
		func(v: float) -> void:
			spin.set_value_no_signal(v)
			_set_sensory_intensity(arr, idx, sname, v / 100.0)
	)
	spin.value_changed.connect(
		func(v: float) -> void:
			slider.set_value_no_signal(v)
			_set_sensory_intensity(arr, idx, sname, v / 100.0)
	)
	cb.toggled.connect(
		func(on: bool) -> void:
			_toggle_sensory(arr, idx, sname, on)
			slider.editable = on
			spin.editable = on
	)
	return col


# The stored intensity for a modifier as a 0–100 percentage (author override, or
# the catalog default when unset).
func _sensory_intensity_pct(arr: Array, idx: int, entry: Dictionary) -> float:
	var nm: String = str(entry.get("name", ""))
	var overrides: Dictionary = arr[idx].get("sensory_intensity", {})
	var v: float = float(overrides[nm]) if overrides.has(nm) else float(entry.get("idef", 0.5))
	return v * 100.0


# Stores a modifier's intensity override (normalized 0–1) on the round.
func _set_sensory_intensity(arr: Array, idx: int, sensory_name: String, value: float) -> void:
	if not arr[idx].has("sensory_intensity"):
		arr[idx]["sensory_intensity"] = {}
	(arr[idx]["sensory_intensity"] as Dictionary)[sensory_name] = clampf(value, 0.0, 1.0)


# Back-compat: older journeys could carry visual/audio kinds (e.g. BLACKOUT) as
# boss FORCED modifiers. Those kinds are now non-gameplay, so on load we move them
# into the round's sensory list and drop them from boss_modifiers. Idempotent.
func _migrate_sensory_boss_modifiers(arr: Array, idx: int) -> void:
	var mods: Array = arr[idx].get("boss_modifiers", [])
	if mods.is_empty():
		return
	var kept: Array = []
	for mod: Dictionary in mods:
		var mname: String = _sensory_name_for_kind(str(mod.get("kind", "")))
		if mname == "":
			kept.append(mod)  # genuine gameplay modifier — leave it
			continue
		if not arr[idx].has("sensory"):
			arr[idx]["sensory"] = []
		if mname not in (arr[idx]["sensory"] as Array):
			(arr[idx]["sensory"] as Array).append(mname)
	if kept.size() != mods.size():
		arr[idx]["boss_modifiers"] = kept


# The SENSORY_CATALOG display name for a kind, or "" if the kind isn't sensory.
func _sensory_name_for_kind(kind: String) -> String:
	for entry: Dictionary in JourneyData.SENSORY_CATALOG:
		if str(entry.get("kind", "")) == kind:
			return str(entry.get("name", ""))
	return ""


# Adds/removes a non-gameplay modifier name from a round's sensory list.
func _toggle_sensory(arr: Array, idx: int, sensory_name: String, on: bool) -> void:
	if not arr[idx].has("sensory"):
		arr[idx]["sensory"] = []
	var list: Array = arr[idx]["sensory"]
	if on:
		if sensory_name not in list:
			list.append(sensory_name)
	else:
		list.erase(sensory_name)


# A "Show intro card" toggle (default on) — whether a cursed/blessed round plays
# its animated reveal card naming the effect(s) before the video starts. Off =
# surprise the player. Shared by the cursed and blessed editors.
func _make_reveal_toggle(arr: Array, idx: int) -> CheckButton:
	var t: CheckButton = CheckButton.new()
	t.text = "SHOW INTRO CARD"
	t.tooltip_text = "Play the animated card naming the effect(s) before the round starts. Off = no telegraph; the effect just hits."
	t.add_theme_font_size_override("font_size", 12)
	t.button_pressed = bool(arr[idx].get("show_reveal", true))
	t.toggled.connect(func(on: bool) -> void: arr[idx]["show_reveal"] = on)
	return t


# Blessed-round toggle — the positive mirror of cursed. Shares round_type (so it's
# mutually exclusive with Boss / Cursed). Boons are pure upside: no cleanse/cost.
func _make_blessed_toggle(arr: Array, idx: int, reselect: Callable) -> Control:
	if not arr[idx].has("round_type"):
		arr[idx]["round_type"] = "normal"
	var is_blessed: bool = arr[idx]["round_type"] == "blessed"

	var wrapper: VBoxContainer = VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 6)

	var toggle_btn: Button = Button.new()
	toggle_btn.text = "✦  BLESSED ROUND  ✓" if is_blessed else "✦  BLESSED ROUND"
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = is_blessed
	toggle_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(toggle_btn, UITheme.AMBER)
	toggle_btn.toggled.connect(
		func(pressed: bool) -> void:
			arr[idx]["round_type"] = "blessed" if pressed else "normal"
			reselect.call(idx)
	)
	wrapper.add_child(toggle_btn)

	if is_blessed:
		var hint: Label = Label.new()
		hint.text = "A boon is applied at the start — score, coins, stronger strokes, a free item, a ward against the next curse, or lingering buffs."
		hint.add_theme_color_override("font_color", UITheme.SEPARATOR)
		hint.add_theme_font_size_override("font_size", 10)
		hint.uppercase = true
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wrapper.add_child(hint)

		wrapper.add_child(_make_reveal_toggle(arr, idx))

		var rand_toggle: CheckButton = CheckButton.new()
		rand_toggle.text = "RANDOM (roll the boon)"
		rand_toggle.add_theme_font_size_override("font_size", 12)
		rand_toggle.button_pressed = bool(arr[idx].get("boon_random", true))
		rand_toggle.toggled.connect(func(on: bool) -> void: arr[idx]["boon_random"] = on)
		wrapper.add_child(rand_toggle)

		wrapper.add_child(_side_field_label("BOONS  (NONE TICKED = FULL RANDOM POOL)"))
		var selected: Array = arr[idx].get("boons", [])
		for entry: Dictionary in JourneyData.BLESSING_CATALOG:
			var bname: String = str(entry.get("name", ""))
			var cb: CheckButton = CheckButton.new()
			cb.text = bname
			cb.tooltip_text = str(entry.get("desc", ""))
			cb.add_theme_font_size_override("font_size", 11)
			cb.button_pressed = bname in selected
			cb.toggled.connect(func(on: bool) -> void: _toggle_boon(arr, idx, bname, on))
			wrapper.add_child(cb)

		wrapper.add_child(_side_field_label("GIFT ITEM  (FOR THE GIFT BOON)"))
		var values: Array = [""]
		var gift_dd: OptionButton = OptionButton.new()
		gift_dd.add_item("None")
		for k: String in InventoryService.GetAllItemIds():
			values.append(k)
			gift_dd.add_item(str(InventoryService.GetItemData(k).get("name", k)))
		gift_dd.selected = max(0, values.find(str(arr[idx].get("gift_item", ""))))
		gift_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_option_button(gift_dd)
		gift_dd.item_selected.connect(func(i: int) -> void: arr[idx]["gift_item"] = values[i])
		wrapper.add_child(gift_dd)

	return wrapper


# Adds/removes a boon name from a blessed round's selected-boons list.
func _toggle_boon(arr: Array, idx: int, boon_name: String, on: bool) -> void:
	if not arr[idx].has("boons"):
		arr[idx]["boons"] = []
	var list: Array = arr[idx]["boons"]
	if on:
		if boon_name not in list:
			list.append(boon_name)
	else:
		list.erase(boon_name)


# Stroke-affecting modifiers to preview for this round, by type: boss modifiers
# directly, or the round's selected curse/boon catalog entries — filtered to the
# kinds that actually change the funscript curve (others don't show in a preview).
func _round_preview_modifiers(item: Dictionary) -> Array:
	match item.get("round_type", "normal"):
		"boss":
			return _stroke_only(item.get("boss_modifiers", []))
		"cursed":
			return _stroke_only(_catalog_entries(JourneyData.CURSE_CATALOG, item.get("curses", [])))
		"blessed":
			return _stroke_only(
				_catalog_entries(JourneyData.BLESSING_CATALOG, item.get("boons", []))
			)
	return []


func _round_preview_label(item: Dictionary) -> String:
	match item.get("round_type", "normal"):
		"cursed":
			return "Curse effects"
		"blessed":
			return "Boon effects"
	return "Boss modifiers"


# Catalog entries whose name is in `names`, preserving catalog order.
func _catalog_entries(catalog: Array, names: Array) -> Array:
	var out: Array = []
	for entry: Dictionary in catalog:
		if entry.get("name", "") in names:
			out.append(entry)
	return out


# Keeps only modifiers whose kind changes the stroke curve.
func _stroke_only(mods: Array) -> Array:
	var out: Array = []
	for m: Dictionary in mods:
		if String(m.get("kind", "")) in ["scale", "clamp", "reverse", "block"]:
			out.append(m)
	return out


# Returns a fresh modifier dict for `kind` seeded with sensible default params.
func _default_boss_modifier(kind: String) -> Dictionary:
	match kind:
		"scale":
			return {"kind": "scale", "factor": 1.2}
		"clamp":
			return {"kind": "clamp", "min": 0, "max": 50}
		"score_multiplier":
			return {"kind": "score_multiplier", "factor": 2.0}
		_:
			return {"kind": kind}


# Rebuilds the forced-modifier rows from scratch — called on add / remove / kind
# change so each row's parameter fields always match its kind.
func _rebuild_boss_modifiers(arr: Array, idx: int, list: VBoxContainer) -> void:
	for child in list.get_children():
		child.queue_free()
	var mods: Array = arr[idx].get("boss_modifiers", [])
	if mods.is_empty():
		var empty: Label = Label.new()
		empty.text = "NO MODIFIERS — THE BOSS PLAYS ITS SCRIPT AS-IS."
		empty.add_theme_color_override("font_color", UITheme.SEPARATOR)
		empty.add_theme_font_size_override("font_size", 10)
		empty.uppercase = true
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(empty)
		return
	for m_idx: int in mods.size():
		list.add_child(_make_boss_modifier_row(arr, idx, list, m_idx))


# Builds one forced-modifier row: a kind dropdown, kind-specific parameter
# fields, and a remove button.
func _make_boss_modifier_row(arr: Array, idx: int, list: VBoxContainer, m_idx: int) -> Control:
	var mod: Dictionary = arr[idx]["boss_modifiers"][m_idx]
	var kind: String = mod.get("kind", "scale")

	var panel: PanelContainer = PanelContainer.new()
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.CARD_BG
	s.border_color = UITheme.PURPLE_MID
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", s)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	# Row 1 — kind dropdown + remove button.
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	col.add_child(head)

	var kind_dd: OptionButton = OptionButton.new()
	for label: String in BOSS_MODIFIER_LABELS:
		kind_dd.add_item(label)
	kind_dd.selected = BOSS_MODIFIER_KINDS.find(kind)
	kind_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_option_button(kind_dd)
	head.add_child(kind_dd)
	kind_dd.item_selected.connect(
		func(sel: int) -> void:
			arr[idx]["boss_modifiers"][m_idx] = _default_boss_modifier(BOSS_MODIFIER_KINDS[sel])
			_rebuild_boss_modifiers(arr, idx, list)
	)

	var remove_btn: Button = UITheme.make_icon_btn("✕", false, UITheme.DANGER)
	remove_btn.pressed.connect(
		func() -> void:
			(arr[idx]["boss_modifiers"] as Array).remove_at(m_idx)
			_rebuild_boss_modifiers(arr, idx, list)
	)
	head.add_child(remove_btn)

	# Row 2 — kind-specific parameters.
	match kind:
		"scale", "score_multiplier":
			var prow: HBoxContainer = HBoxContainer.new()
			prow.add_theme_constant_override("separation", 6)
			var plbl: Label = _side_field_label("FACTOR")
			plbl.custom_minimum_size = Vector2(60, 0)
			prow.add_child(plbl)
			var pedit: LineEdit = LineEdit.new()
			pedit.text = str(mod.get("factor", 1.0))
			pedit.custom_minimum_size = Vector2(70, 0)
			UITheme.style_line_edit(pedit)
			pedit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["factor"] = maxf(0.0, val.to_float())
			)
			prow.add_child(pedit)
			col.add_child(prow)
		"clamp":
			var crow: HBoxContainer = HBoxContainer.new()
			crow.add_theme_constant_override("separation", 6)
			crow.add_child(_side_field_label("MIN"))
			var min_edit: LineEdit = LineEdit.new()
			min_edit.text = str(mod.get("min", 0))
			min_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(min_edit)
			min_edit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["min"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(min_edit)
			crow.add_child(_side_field_label("MAX"))
			var max_edit: LineEdit = LineEdit.new()
			max_edit.text = str(mod.get("max", 100))
			max_edit.custom_minimum_size = Vector2(56, 0)
			UITheme.style_line_edit(max_edit)
			max_edit.text_changed.connect(
				func(val: String) -> void:
					arr[idx]["boss_modifiers"][m_idx]["max"] = clampi(val.to_int(), 0, 100)
			)
			crow.add_child(max_edit)
			col.add_child(crow)
		_:
			var none_lbl: Label = Label.new()
			none_lbl.text = "NO PARAMETERS"
			none_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
			none_lbl.add_theme_font_size_override("font_size", 10)
			col.add_child(none_lbl)

	return panel


# Deletes an image file only if it lives inside the app's user data directory
# (i.e. it has already been saved into a journey folder). Staging paths that
# point to the user's own filesystem are left untouched — only the reference
# in the data dict is cleared by the caller.
func _delete_saved_image(path: String) -> void:
	if path == "":
		return
	var abs_path: String = ProjectSettings.globalize_path(path)
	var user_data: String = ProjectSettings.globalize_path("user://")
	if abs_path.begins_with(user_data) and FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
