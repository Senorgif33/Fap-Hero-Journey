class_name GraphView
extends Control

# ---------------------------------------------------------------------------
# GraphView.gd
# Renders a journey's _items[] tree as an auto-laid-out graph. Top-to-bottom
# flow for sequences; forks branch horizontally with each path as a sub-column.
# Recurses through nested forks at arbitrary depth.
#
# Public API:
#   set_items(items: Array)        — sets the model and rebuilds the graph
#   refresh()                      — rebuilds from the current model
# Signals:
#   selection_changed(items, parent_arr) — emitted when the selection changes
# ---------------------------------------------------------------------------

signal selection_changed(items: Array, parent_arr: Array)
signal insert_requested(parent_arr: Array, idx: int, screen_pos: Vector2)
# Emitted when a fork-branch (path) label is clicked — selects that branch as an
# insertion target so new/pasted items land at the top of the path.
signal branch_selected(path: Dictionary)

const NODE_WIDTH:  float = 200.0
const NODE_HEIGHT: float = 64.0
const V_GAP:       float = 40.0
const H_GAP:       float = 36.0
const PATH_LABEL_HEIGHT: float = 32.0
const INSERT_BTN_SIZE: float = 22.0
const ZOOM_MIN:    float = 0.15
const ZOOM_MAX:    float = 4.0
const ZOOM_STEP:   float = 0.1
# Screen-space top margin when framing the graph at the top-center of the view.
const VIEW_TOP_MARGIN: float = 40.0
# Padding kept around the content when fit-to-view frames the whole graph.
const FIT_PADDING:     float = 60.0
# Minimum canvas extent, and extra margin added around the laid-out content. The
# canvas is grown to fit tall/wide journeys so its draw (the edges) is never
# culled — see _resize_canvas_to_content.
const CANVAS_MIN_SIZE:       float = 8000.0
const CANVAS_CONTENT_MARGIN: float = 600.0

var _items:           Array      = []
# Multi-selection: the selected item dicts (by reference) plus the single parent
# array they all belong to (same-branch constraint). Empty = nothing selected;
# size 1 = single selection (drives the per-node editor).
var _selected_items:  Array      = []
var _selected_arr:    Array      = []
# The selected fork-branch path dict (mutually exclusive with node selection),
# or {} when no branch is selected. Drives the path-label highlight.
var _selected_path:   Dictionary = {}

# Range-select anchor: the last single/ctrl-clicked node, used as the fixed end
# of a Shift+click range. {} when there's no anchor.
var _anchor_item:     Dictionary = {}
var _anchor_arr:      Array      = []

# Optional callback (set by the builder) that, given an item dict, returns a
# short problem summary String ("" when the item is fine). Drives the warning
# badge drawn on each node. Evaluated at layout time so badges always reflect
# the current model.
var validity_fn: Callable = Callable()
# Items that end the run (no items follow them anywhere in the flow).
# Rebuilt on every refresh() so the set is always current.
var _terminal_items:  Array      = []

# Pan / zoom state
var _pan_offset: Vector2 = Vector2(40, 40)
var _zoom:       float   = 1.0
var _panning:    bool    = false
var _last_mouse: Vector2 = Vector2.ZERO
var _has_initial_center: bool = false

# Marquee (drag-select) state. Coordinates are in GraphView-local (screen) space.
var _marquee_active:   bool    = false
var _marquee_additive: bool    = false   # Ctrl held at drag start → add to selection
var _marquee_start:    Vector2 = Vector2.ZERO
var _marquee_end:      Vector2 = Vector2.ZERO
const MARQUEE_DRAG_THRESHOLD: float = 6.0

# Auto-layout artefacts (rebuilt on refresh).
# Edges: list of {from: Vector2, to: Vector2, color: Color}
var _edges: Array = []

# Background grid + edges live on _canvas. Nodes are added as children of _canvas
# so they pan/zoom together with edges.
@onready var _canvas: Control = $Canvas

# Centered onboarding hint, shown only while the journey is empty. Lives on the
# GraphView (not _canvas) so it stays put regardless of pan/zoom.
var _empty_hint: Label = null


func _ready() -> void:
	clip_contents = true
	# Make sure we receive input events for pan/zoom.
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Start with a large bounding rect; _resize_canvas_to_content grows it to fit
	# the actual layout so the edge draw is never culled on tall/wide journeys.
	# (A canvas item whose rect leaves the viewport is skipped entirely, which
	# would drop every edge at once while the per-node child controls survive.)
	_canvas.custom_minimum_size = Vector2(CANVAS_MIN_SIZE, CANVAS_MIN_SIZE)
	_canvas.size = Vector2(CANVAS_MIN_SIZE, CANVAS_MIN_SIZE)

	_empty_hint = Label.new()
	_empty_hint.text = "Drop videos or a whole folder here to auto-create rounds —\nor click  +  to add your first item."
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.anchor_right  = 1.0
	_empty_hint.anchor_bottom = 1.0
	_empty_hint.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_empty_hint.add_theme_color_override("font_color", Color(UITheme.PURPLE_MID.r, UITheme.PURPLE_MID.g, UITheme.PURPLE_MID.b, 0.75))
	_empty_hint.add_theme_font_size_override("font_size", 16)
	_empty_hint.visible = false
	add_child(_empty_hint)


func set_items(items: Array) -> void:
	_items = items
	refresh()


func refresh() -> void:
	# Tear down old nodes.
	for c in _canvas.get_children():
		c.queue_free()
	_edges.clear()

	# Onboarding hint only while there's nothing authored yet.
	if _empty_hint:
		_empty_hint.visible = _items.is_empty()

	# Recompute which items end the run before laying out so _make_node can
	# query the set during layout.
	_terminal_items = _collect_terminal_items(_items, false)

	# Apply pan/zoom transform to the canvas.
	_apply_transform()

	# Lay out items starting at origin (0, 0) — the canvas transform handles offset.
	# We do this deferred so the freed children are gone before we add new ones.
	call_deferred("_do_layout")


func _do_layout() -> void:
	var bounds: Dictionary = _layout_items(_items, 0.0, 0.0)
	_canvas.set_edges(_edges)
	_resize_canvas_to_content(bounds.get("size", Vector2(CANVAS_MIN_SIZE, CANVAS_MIN_SIZE)))
	if not _has_initial_center:
		_has_initial_center = true
		call_deferred("_center_initial_view")


# Grows _canvas so its rect always covers the laid-out content. Edges are drawn
# on _canvas as part of its own _draw, so if the content is taller/wider than the
# canvas rect, the renderer culls the whole canvas item once you scroll past that
# rect — and every edge disappears at once (nodes are separate items and survive).
# Sizing to the real content height/width keeps the edges visible at any scroll.
func _resize_canvas_to_content(content_size: Vector2) -> void:
	var w: float = maxf(CANVAS_MIN_SIZE, content_size.x + CANVAS_CONTENT_MARGIN)
	var h: float = maxf(CANVAS_MIN_SIZE, content_size.y + CANVAS_CONTENT_MARGIN)
	_canvas.custom_minimum_size = Vector2(w, h)
	_canvas.size = Vector2(w, h)


# Aligns the top-center of the graph (where the first item sits, at x=0, y=0
# in canvas-local space) with the top-center of the visible area.
func _center_initial_view() -> void:
	# In case size hasn't been finalised yet, wait one more frame.
	if size.x <= 0.0:
		await get_tree().process_frame
	_pan_offset = Vector2(size.x * 0.5, VIEW_TOP_MARGIN)
	_apply_transform()


# Recursively lays out an items[] array as a vertical column centered on x_center.
# Returns { "size": Vector2(max_w, cur_y), "last_nodes": Array[Control] }
# where last_nodes are the Controls at the open ends of this subtree (can be
# multiple after an unresolved fork — used by the caller to draw merge arrows).
func _layout_items(items: Array, x_center: float, y: float) -> Dictionary:
	var cur_y: float = y
	var max_w: float = NODE_WIDTH
	# open_ends: Controls whose bottom port awaits an outgoing edge.
	# After a fork, this holds the last node of each path so merge arrows can
	# be drawn to whatever comes next at this level.
	var open_ends: Array  = []
	# Whether open_ends came from fork paths (drives edge colour for merges).
	var from_fork: bool   = false

	# Insert button before the first item (idx=0). Sits in the gap above y.
	_place_insert_btn(items, 0, x_center, y - V_GAP * 0.5)

	# Empty branch: just show the single insert button.
	if items.is_empty():
		return {"size": Vector2(NODE_WIDTH, y), "last_nodes": []}

	for i in items.size():
		var item: Dictionary = items[i]
		var item_type: String = item.get("type", "round")

		if item_type == "fork":
			# ── Fork node ────────────────────────────────────────────────────
			var fork_node: Control = _make_node(item, items, i)
			fork_node.position = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			_canvas.add_child(fork_node)
			# Connect whatever preceded this fork to the fork node.
			for oe in open_ends:
				_add_edge(_node_bottom(oe), _node_top(fork_node),
					UITheme.FORK_EDGE if from_fork else UITheme.EDGE)
			cur_y += NODE_HEIGHT + V_GAP

			# Compute path widths (recursive measure).
			var paths: Array = item.get("paths", [])
			var path_widths: Array = []
			for path in paths:
				path_widths.append(max(_measure_items_width(path.get("items", [])), NODE_WIDTH))

			var total_w: float = 0.0
			for w in path_widths:
				total_w += w
			if paths.size() > 1:
				total_w += (paths.size() - 1) * H_GAP
			max_w = max(max_w, total_w)

			# Place each path column, collecting each path's final nodes.
			var col_x: float  = x_center - total_w * 0.5
			var max_branch_y: float = cur_y
			var all_path_ends: Array = []

			for pi in paths.size():
				var path: Dictionary     = paths[pi]
				var pw: float            = path_widths[pi]
				var path_cx: float       = col_x + pw * 0.5

				var label_node: Control = _make_path_label(path, paths, pi)
				label_node.position = Vector2(path_cx - NODE_WIDTH * 0.5, cur_y)
				_canvas.add_child(label_node)
				_add_edge(_node_bottom(fork_node), _node_top(label_node), UITheme.FORK_EDGE)

				var path_items: Array = path.get("items", [])
				var sub: Dictionary   = _layout_items(path_items, path_cx, cur_y + PATH_LABEL_HEIGHT + V_GAP)

				if not path_items.is_empty():
					var first_item_node: Control = _find_first_node_at_x(path_cx, cur_y + PATH_LABEL_HEIGHT + V_GAP)
					if first_item_node != null:
						_add_edge(_node_bottom(label_node), _node_top(first_item_node), UITheme.EDGE)

				max_branch_y = max(max_branch_y, sub["size"].y)
				all_path_ends.append_array(sub["last_nodes"])
				col_x += pw + H_GAP

			cur_y     = max_branch_y
			# Path ends become the new open ends — the next item at this level
			# receives merge arrows from all of them.
			open_ends = all_path_ends
			from_fork = true

		else:
			# ── Non-fork node ────────────────────────────────────────────────
			var is_term: bool  = _terminal_items.any(func(ti: Dictionary) -> bool: return is_same(item, ti))
			var node: Control  = _make_node(item, items, i, is_term)
			node.position = Vector2(x_center - NODE_WIDTH * 0.5, cur_y)
			_canvas.add_child(node)
			# Draw edge(s) from all open ends into this node.
			for oe in open_ends:
				_add_edge(_node_bottom(oe), _node_top(node),
					UITheme.FORK_EDGE if from_fork else UITheme.EDGE)
			open_ends = [node]
			from_fork = false
			cur_y += NODE_HEIGHT + V_GAP

		# Insert button in the gap AFTER this item (idx = i+1).
		_place_insert_btn(items, i + 1, x_center, cur_y - V_GAP * 0.5)

	return {"size": Vector2(max_w, cur_y), "last_nodes": open_ends}


# Returns all items (by reference) that would end the run — i.e., no item in
# the journey flow comes after them. Called once per refresh().
#
# has_successor_after: true when the caller knows something follows this items[]
# array in the parent scope (e.g. the fork that contains this path has a sibling
# item after it at the outer level).
func _collect_terminal_items(items: Array, has_successor_after: bool) -> Array:
	if items.is_empty():
		return []
	var last: Dictionary = items[-1]
	var item_type: String = last.get("type", "round")
	if item_type == "fork":
		if has_successor_after:
			# Fork converges into a successor — the fork's paths are not terminal.
			return []
		# Fork is the last item with nothing after it: recurse into each path.
		var result: Array = []
		for path: Dictionary in last.get("paths", []):
			result.append_array(_collect_terminal_items(path.get("items", []), false))
		return result
	else:
		# Non-fork last item.
		if has_successor_after:
			return []
		return [last]


# Recursively measures the width an items[] array will consume at layout time.
func _measure_items_width(items: Array) -> float:
	var max_w: float = NODE_WIDTH
	for item in items:
		if item.get("type", "round") == "fork":
			var paths: Array = item.get("paths", [])
			var sub_total: float = 0.0
			for path in paths:
				sub_total += max(_measure_items_width(path.get("items", [])), NODE_WIDTH)
			if paths.size() > 1:
				sub_total += (paths.size() - 1) * H_GAP
			max_w = max(max_w, sub_total)
	return max_w


func _find_first_node_at_x(x_center: float, y: float) -> Control:
	# Linear scan through canvas children to find the node placed at this position.
	for c in _canvas.get_children():
		if c.position.y == y and abs(c.position.x - (x_center - NODE_WIDTH * 0.5)) < 0.5:
			return c
	return null


# Places a small "+" button centered at (x_center, mid_y) that, when clicked,
# requests an insert into `arr` at the given index.
func _place_insert_btn(arr: Array, idx: int, x_center: float, mid_y: float) -> void:
	var btn: Button = Button.new()
	btn.text = "+"
	btn.size = Vector2(INSERT_BTN_SIZE, INSERT_BTN_SIZE)
	btn.custom_minimum_size = Vector2(INSERT_BTN_SIZE, INSERT_BTN_SIZE)
	btn.position = Vector2(x_center - INSERT_BTN_SIZE * 0.5, mid_y - INSERT_BTN_SIZE * 0.5)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_color_override("font_color",         UITheme.PURPLE_MID)
	btn.add_theme_color_override("font_hover_color",   UITheme.WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", Color.BLACK)
	btn.add_theme_font_size_override("font_size", 16)

	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.02, 0.0, 0.04, 0.95)
	s.border_color = UITheme.PURPLE_MID
	s.border_width_left   = 1; s.border_width_right  = 1
	s.border_width_top    = 1; s.border_width_bottom = 1
	s.corner_radius_top_left     = 11
	s.corner_radius_top_right    = 11
	s.corner_radius_bottom_left  = 11
	s.corner_radius_bottom_right = 11
	s.content_margin_left   = 0; s.content_margin_right  = 0
	s.content_margin_top    = 0; s.content_margin_bottom = 0
	btn.add_theme_stylebox_override("normal", s)

	var s_hover: StyleBoxFlat = s.duplicate()
	s_hover.bg_color = Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.35)
	s_hover.border_color = UITheme.PURPLE_BRIGHT
	btn.add_theme_stylebox_override("hover", s_hover)

	var s_pressed: StyleBoxFlat = s.duplicate()
	s_pressed.bg_color = UITheme.PURPLE_BRIGHT
	btn.add_theme_stylebox_override("pressed", s_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	btn.pressed.connect(func() -> void:
		# Report the button's screen-space position so the popup appears near it.
		var screen_pos: Vector2 = btn.get_global_rect().position + Vector2(INSERT_BTN_SIZE, 0)
		emit_signal("insert_requested", arr, idx, screen_pos)
	)

	_canvas.add_child(btn)


# ---------------------------------------------------------------------------
# Node makers
# ---------------------------------------------------------------------------

# is_terminal: true when this node ends the run (no path leads beyond it).
func _make_node(item: Dictionary, arr: Array, _idx: int, is_terminal: bool = false) -> Control:
	var item_type: String = item.get("type", "round")
	var is_boss: bool = item_type == "round" and item.get("round_type", "normal") == "boss"
	# Terminal nodes use AMBER; boss rounds use DANGER red; else the type colour.
	var accent: Color = UITheme.AMBER if is_terminal else (UITheme.DANGER if is_boss else _type_color(item_type))
	var icon: String = "⚔" if is_boss else _type_icon(item_type)
	var primary: String = _type_label(item)
	var secondary: String = _type_sublabel(item)
	if is_terminal:
		secondary = secondary + ("  ·  " if secondary != "" else "") + "END OF RUN"

	var panel: PanelContainer = PanelContainer.new()
	panel.size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.custom_minimum_size = Vector2(NODE_WIDTH, NODE_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# Use is_same() (reference identity) — Dictionary's == does deep equality,
	# so two newly-created nodes with identical default fields would compare
	# equal and both light up as "selected".
	var is_selected: bool = _is_selected(item)
	panel.add_theme_stylebox_override("panel", _node_stylebox(accent, is_selected, is_terminal))

	# Stash the model link so marquee hit-testing can map a node back to its
	# (item, parent array) without re-walking the tree.
	panel.set_meta("graph_item", item)
	panel.set_meta("graph_arr",  arr)

	# Live validation: a non-empty summary means this node has a problem the
	# author would otherwise only discover at save time.
	var issue: String = ""
	if validity_fn.is_valid():
		issue = validity_fn.call(item)
	if issue != "":
		panel.tooltip_text = issue

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)

	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)

	# Icon
	var icon_lbl: Label = Label.new()
	icon_lbl.text = icon
	icon_lbl.add_theme_color_override("font_color", accent)
	icon_lbl.add_theme_font_size_override("font_size", 22)
	icon_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon_lbl)

	# Labels column
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)

	var primary_lbl: Label = Label.new()
	primary_lbl.text = primary
	primary_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	primary_lbl.add_theme_font_size_override("font_size", 13)
	primary_lbl.clip_text = true
	primary_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(primary_lbl)

	var secondary_lbl: Label = Label.new()
	secondary_lbl.text = secondary
	secondary_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	secondary_lbl.add_theme_font_size_override("font_size", 10)
	secondary_lbl.clip_text = true
	secondary_lbl.uppercase = true
	secondary_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(secondary_lbl)

	# Warning badge — sits at the right edge (the labels column expands to push
	# it there). Hovering the node shows the issue via panel.tooltip_text.
	if issue != "":
		var warn_lbl: Label = Label.new()
		warn_lbl.text = "⚠"
		warn_lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT)
		warn_lbl.add_theme_font_size_override("font_size", 18)
		warn_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		warn_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(warn_lbl)

	# Click selection. Shift+click selects the range from the anchor; Ctrl+click
	# toggles membership; a plain click selects just this node (and sets the
	# anchor for a subsequent shift+click).
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				if mb.shift_pressed:
					_range_select(item, arr)
				elif mb.ctrl_pressed:
					_toggle_selection(item, arr)
				else:
					_select_single(item, arr)
				accept_event()
	)

	return panel


func _make_path_label(path: Dictionary, paths_arr: Array, path_idx: int) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	panel.size = Vector2(NODE_WIDTH, PATH_LABEL_HEIGHT)
	panel.custom_minimum_size = Vector2(NODE_WIDTH, PATH_LABEL_HEIGHT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var selected: bool = is_same(path, _selected_path)
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.22 if selected else 0.10)
	s.border_color = UITheme.MAGENTA
	var bw: int = 3 if selected else 1
	s.border_width_left   = bw
	s.border_width_right  = bw
	s.border_width_top    = bw
	s.border_width_bottom = bw
	s.corner_radius_top_left     = 14
	s.corner_radius_top_right    = 14
	s.corner_radius_bottom_left  = 14
	s.corner_radius_bottom_right = 14
	s.content_margin_left   = 12
	s.content_margin_right  = 12
	s.content_margin_top    = 4
	s.content_margin_bottom = 4
	if selected:
		s.shadow_color = Color(UITheme.MAGENTA.r, UITheme.MAGENTA.g, UITheme.MAGENTA.b, 0.50)
		s.shadow_size  = 8
	panel.add_theme_stylebox_override("panel", s)

	var name_text: String = path.get("name", "Path %d" % (path_idx + 1))
	if (name_text as String).strip_edges() == "":
		name_text = "Path %d" % (path_idx + 1)

	var lbl: Label = Label.new()
	lbl.text = "↳ " + name_text.to_upper()
	lbl.add_theme_color_override("font_color", UITheme.MAGENTA)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)

	# Click selects this branch as an insertion target (new/pasted items go to
	# the top of the path).
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_select_branch(path)
				accept_event()
	)

	return panel


func _node_stylebox(accent: Color, selected: bool, terminal: bool = false) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.0, 0.06, 0.96)
	s.border_color = accent
	# Border: thicker when selected; slightly heavier than default when terminal.
	var w: int = 3 if selected else (2 if terminal else 1)
	s.border_width_left   = w
	s.border_width_right  = w
	s.border_width_top    = w
	s.border_width_bottom = w
	s.corner_radius_top_left     = 6
	s.corner_radius_top_right    = 6
	s.corner_radius_bottom_left  = 6
	s.corner_radius_bottom_right = 6
	if selected:
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.50)
		s.shadow_size  = 8
	elif terminal:
		# Warm amber glow to signal "this is where the run ends".
		s.shadow_color = Color(accent.r, accent.g, accent.b, 0.55)
		s.shadow_size  = 14
	return s


func _type_color(item_type: String) -> Color:
	match item_type:
		"round":      return UITheme.PURPLE_BRIGHT
		"shop":       return UITheme.AMBER
		"storyboard": return UITheme.CYAN
		"fork":       return UITheme.MAGENTA
	return UITheme.PURPLE_MID


func _type_icon(item_type: String) -> String:
	match item_type:
		"round":      return "▶"
		"shop":       return "◆"
		"storyboard": return "◈"
		"fork":       return "⑂"
	return "•"


func _type_label(item: Dictionary) -> String:
	var item_type: String = item.get("type", "round")
	match item_type:
		"round":
			var n: String = item.get("name", "")
			return n if n != "" else "Round"
		"shop":
			var n2: String = item.get("title", "")
			return n2 if n2 != "" else "Shop"
		"storyboard":
			var first_speaker: String = ""
			var lines: Array = item.get("lines", [])
			if lines.size() > 0:
				first_speaker = lines[0].get("speaker", "")
			return first_speaker if first_speaker != "" else "Storyboard"
		"fork":
			var n3: String = item.get("title", "")
			return n3 if n3 != "" else "Fork"
	return "?"


func _type_sublabel(item: Dictionary) -> String:
	var item_type: String = item.get("type", "round")
	match item_type:
		"round":
			var c: int = item.get("coins", 0)
			var is_boss: bool = item.get("round_type", "normal") == "boss"
			var rlabel: String = "BOSS ROUND" if is_boss else "ROUND"
			# Checkpoint marker — author-set save point. Suppressed on bosses
			# since the runtime ignores the flag inside a boss round, so the
			# graph shouldn't claim something the play loop won't deliver.
			if not is_boss and item.get("is_checkpoint", false):
				rlabel += "   ◆ CHECKPOINT"
			return "%s   ♦ %d" % [rlabel, c] if c > 0 else rlabel
		"shop":
			return "SHOP"
		"storyboard":
			var n: int = (item.get("lines", []) as Array).size()
			return "STORYBOARD   %d LINE%s" % [n, "S" if n != 1 else ""]
		"fork":
			var paths: Array = item.get("paths", [])
			return "%s   %d PATHS" % [_fork_type_label(item.get("resolution", "choice")), paths.size()]
	return ""


# Sublabel prefix for a fork node, by resolution: "FORK" (choice), "RANDOM FORK",
# "CONDITIONAL FORK", "SACRIFICE FORK".
func _fork_type_label(resolution: String) -> String:
	match resolution:
		"random":      return "RANDOM FORK"
		"conditional": return "CONDITIONAL FORK"
		"sacrifice":   return "SACRIFICE FORK"
	return "FORK"


# ---------------------------------------------------------------------------
# Edges
# ---------------------------------------------------------------------------

func _add_edge(from: Vector2, to: Vector2, color: Color) -> void:
	_edges.append({"from": from, "to": to, "color": color})


func _node_top(node: Control) -> Vector2:
	return node.position + Vector2(node.size.x * 0.5, 0.0)


func _node_bottom(node: Control) -> Vector2:
	return node.position + Vector2(node.size.x * 0.5, node.size.y)


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _is_selected(item: Dictionary) -> bool:
	for s: Dictionary in _selected_items:
		if is_same(item, s):
			return true
	return false


func _emit_selection() -> void:
	emit_signal("selection_changed", _selected_items, _selected_arr)


# Replaces the selection with a single node (plain click / programmatic select).
func _select_single(item: Dictionary, arr: Array) -> void:
	_selected_items = [item]
	_selected_arr   = arr
	_selected_path  = {}
	_anchor_item    = item   # becomes the fixed end of a later Shift+click range
	_anchor_arr     = arr
	_emit_selection()
	refresh()


# Index of `item` in `arr` by reference identity, or -1.
func _index_of(arr: Array, item: Dictionary) -> int:
	for i in arr.size():
		if is_same(arr[i], item):
			return i
	return -1


# Shift+click: selects the inclusive range between the anchor and `item` within
# the same branch. With no valid anchor (or a different branch), falls back to a
# plain single select.
func _range_select(item: Dictionary, arr: Array) -> void:
	var a_idx: int = -1
	if not _anchor_item.is_empty() and is_same(arr, _anchor_arr):
		a_idx = _index_of(arr, _anchor_item)
	var c_idx: int = _index_of(arr, item)
	if a_idx < 0 or c_idx < 0:
		_select_single(item, arr)
		return
	var lo: int = min(a_idx, c_idx)
	var hi: int = max(a_idx, c_idx)
	var items: Array = []
	for i in range(lo, hi + 1):
		items.append(arr[i])
	_selected_items = items
	_selected_arr   = arr
	_selected_path  = {}
	# Anchor stays put so the range can be re-stretched with another Shift+click.
	_emit_selection()
	refresh()


# Selects a fork branch (path) as an insertion target — new/pasted items go to
# the top of the path. Mutually exclusive with node selection.
func _select_branch(path: Dictionary) -> void:
	_selected_items = []
	_selected_arr   = []
	_selected_path  = path
	emit_signal("branch_selected", path)
	refresh()


# Ctrl+click: toggle a node in/out of the selection. Selecting in a different
# branch than the current selection starts a fresh selection there (same-branch
# constraint keeps group ops unambiguous).
func _toggle_selection(item: Dictionary, arr: Array) -> void:
	if not _selected_items.is_empty() and not is_same(arr, _selected_arr):
		_select_single(item, arr)
		return
	var found: int = -1
	for i in _selected_items.size():
		if is_same(_selected_items[i], item):
			found = i
			break
	if found >= 0:
		_selected_items.remove_at(found)
		if _selected_items.is_empty():
			_selected_arr = []
	else:
		_selected_items.append(item)
		_selected_arr = arr
	_selected_path = {}
	_anchor_item   = item   # extend a future Shift+click range from here
	_anchor_arr    = arr
	_emit_selection()
	refresh()


# Sets the selection to an explicit set of items (all expected to live in `arr`).
# Used by the builder after group move/paste to re-highlight the same items.
func set_selection(items: Array, arr: Array) -> void:
	_selected_items = items.duplicate()
	_selected_arr   = arr if not items.is_empty() else []
	_selected_path  = {}
	_emit_selection()
	refresh()


# Programmatically select the item at arr[idx]. Used by side-panel editors
# after a structural change so both the graph and the editor re-render.
func select_item(arr: Array, idx: int) -> void:
	if idx < 0 or idx >= arr.size():
		clear_selection()
		return
	_select_single(arr[idx], arr)


func clear_selection() -> void:
	if _selected_items.is_empty() and _selected_path.is_empty():
		# Force the signal so consumers can update on a forced clear.
		_emit_selection()
		return
	_selected_items = []
	_selected_arr   = []
	_selected_path  = {}
	_anchor_item    = {}
	_anchor_arr     = []
	_emit_selection()
	refresh()


# ---------------------------------------------------------------------------
# Pan + zoom
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			_last_mouse = mb.position
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(mb.position, _zoom + ZOOM_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(mb.position, _zoom - ZOOM_STEP)
			accept_event()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# Left press reaching GraphView (not a node) starts a marquee drag.
			# A press+release without movement collapses to "clear selection".
			if mb.pressed:
				_marquee_active   = true
				_marquee_additive = mb.ctrl_pressed
				_marquee_start    = mb.position
				_marquee_end      = mb.position
				accept_event()
			elif _marquee_active:
				_finish_marquee()
				accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			var delta: Vector2 = mm.position - _last_mouse
			_last_mouse = mm.position
			_pan_offset += delta
			_apply_transform()
		elif _marquee_active:
			_marquee_end = mm.position
			queue_redraw()
			accept_event()


# Draws the marquee selection rectangle (screen space, on top of the graph).
func _draw() -> void:
	if not _marquee_active:
		return
	var rect: Rect2 = Rect2(_marquee_start, Vector2.ZERO).expand(_marquee_end)
	var accent: Color = UITheme.PURPLE_BRIGHT
	draw_rect(rect, Color(accent.r, accent.g, accent.b, 0.12), true)
	draw_rect(rect, accent, false, 1.5)


# Finalizes a marquee drag: selects every node whose on-screen rect intersects
# the marquee box, constrained to a single branch (the first hit's parent array).
# A drag too small to count is treated as a plain click → clear selection.
func _finish_marquee() -> void:
	_marquee_active = false
	var rect: Rect2 = Rect2(_marquee_start, Vector2.ZERO).expand(_marquee_end)
	queue_redraw()

	if rect.size.length() < MARQUEE_DRAG_THRESHOLD:
		if not _marquee_additive:
			clear_selection()
		return

	var hit_items: Array = []
	var hit_arrs:  Array = []
	for c: Node in _canvas.get_children():
		if not (c is Control) or not c.has_meta("graph_item"):
			continue
		var node: Control = c as Control
		var screen_rect: Rect2 = Rect2(_canvas.position + node.position * _zoom, node.size * _zoom)
		if rect.intersects(screen_rect):
			hit_items.append(node.get_meta("graph_item"))
			hit_arrs.append(node.get_meta("graph_arr"))

	if hit_items.is_empty():
		if not _marquee_additive:
			clear_selection()
		return

	# Same-branch: keep only hits sharing the first hit's parent array.
	var target_arr: Array = hit_arrs[0]
	var items: Array = []
	if _marquee_additive and not _selected_items.is_empty() and is_same(_selected_arr, target_arr):
		items = _selected_items.duplicate()
	for i in hit_items.size():
		if is_same(hit_arrs[i], target_arr):
			var already: bool = false
			for s: Dictionary in items:
				if is_same(s, hit_items[i]):
					already = true
					break
			if not already:
				items.append(hit_items[i])

	_selected_items = items
	_selected_arr   = target_arr
	_selected_path  = {}
	_emit_selection()
	refresh()


func _zoom_at(focus: Vector2, new_zoom: float) -> void:
	new_zoom = clamp(new_zoom, ZOOM_MIN, ZOOM_MAX)
	if abs(new_zoom - _zoom) < 0.001:
		return
	# Preserve the canvas point under the cursor.
	var world_before: Vector2 = (focus - _pan_offset) / _zoom
	_zoom = new_zoom
	_pan_offset = focus - world_before * _zoom
	_apply_transform()


func _apply_transform() -> void:
	_canvas.position = _pan_offset
	_canvas.scale    = Vector2(_zoom, _zoom)
	# Re-invoke _draw() — pan/zoom changes don't automatically invalidate the
	# CanvasItem's drawn primitives, so without this the edges flicker out.
	_canvas.queue_redraw()


# Frames the whole graph: zooms/pans so every node fits in the viewport with a
# margin. Falls back to the default view when there's nothing to frame.
func fit_to_view() -> void:
	var min_p: Vector2 = Vector2(INF, INF)
	var max_p: Vector2 = Vector2(-INF, -INF)
	var found: bool = false
	for c: Node in _canvas.get_children():
		if not (c is Control) or not c.has_meta("graph_item"):
			continue
		found = true
		var node: Control = c as Control
		min_p.x = min(min_p.x, node.position.x)
		min_p.y = min(min_p.y, node.position.y)
		max_p.x = max(max_p.x, node.position.x + node.size.x)
		max_p.y = max(max_p.y, node.position.y + node.size.y)

	if not found:
		reset_view()
		return

	var content: Vector2 = max_p - min_p
	if content.x <= 0.0 or content.y <= 0.0:
		reset_view()
		return

	var avail: Vector2 = size - Vector2(FIT_PADDING * 2.0, FIT_PADDING * 2.0)
	var z: float = clamp(min(avail.x / content.x, avail.y / content.y), ZOOM_MIN, ZOOM_MAX)
	_zoom = z
	# Map the content's center to the viewport center.
	var content_center: Vector2 = (min_p + max_p) * 0.5
	_pan_offset = size * 0.5 - content_center * _zoom
	_apply_transform()


# Restores the default zoom + top-center framing.
func reset_view() -> void:
	_zoom = 1.0
	_pan_offset = Vector2(size.x * 0.5, VIEW_TOP_MARGIN)
	_apply_transform()


