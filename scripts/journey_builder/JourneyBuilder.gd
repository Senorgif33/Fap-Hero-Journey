class_name JourneyBuilder
extends Control

# ---------------------------------------------------------------------------
# JourneyBuilder.gd  –  Create and save custom journeys
# Users fill out journey metadata, add rounds by picking funscript + video
# files via OS file dialog or drag-and-drop. The folder structure is built
# automatically under user://journeys/ and all files are copied in.
# ---------------------------------------------------------------------------

# All shared colors and style helpers live in `UITheme` (autoload). See
# Globals/UITheme.gd. Local references use UITheme.<COLOR_NAME> / UITheme.style_*.

const TOP_BAR_HEIGHT:  int = 64

# Journeys root is configurable via Options → Journey Storage Location.
# Always read via SettingsService.get_journeys_dir() so a path change takes
# effect on the next save without restarting the scene.

# Difficulty list and file-extension sets live in JourneyData (canonical schema).
# Referenced here as JourneyData.DIFFICULTIES / JourneyData.IMAGE_EXTENSIONS etc.

# EIRTeam.FFmpeg only decodes H.264; everything else gets transcoded on save.
const H264_NAMES: Array[String] = ["h264", "avc1", "avc"]
const TRANSCODE_PROGRESS_FILE: String = "user://transcode_progress.txt"

# ── Save error / copy result cause codes ────────────────────────────────────
# Every SaveError flowing through _show_save_error_modal carries one of these
# in its `cause` field, and every _copy_file_chunked result carries one in
# its `reason` field. Centralised as constants so typos surface at parse time
# (string-literal mismatches in match statements silently fall through to the
# default arm otherwise) and the full taxonomy is easy to grep.
const CAUSE_BAD_NAME:           String = "bad_name"
const CAUSE_NAME_COLLISION:     String = "name_collision"
const CAUSE_MISSING_SOURCE:     String = "missing_source"
const CAUSE_NO_ROUNDS:          String = "no_rounds"
const CAUSE_FORK_UNDERFILLED:   String = "fork_underfilled"
const CAUSE_FFMPEG_MISSING:     String = "ffmpeg_missing"
const CAUSE_CANCELLED:          String = "cancelled"
const CAUSE_SRC_UNREADABLE:     String = "src_unreadable"
const CAUSE_DST_UNWRITABLE:     String = "dst_unwritable"
const CAUSE_TRANSCODE_FAILED:   String = "transcode_failed"
const CAUSE_UNKNOWN_COPY_ERROR: String = "unknown_copy_error"

const GraphViewScene = preload("res://scenes/graph_view/GraphView.tscn")

@onready var _bg:          ColorRect       = $Background
@onready var _top_bar:     HBoxContainer   = $TopBar
@onready var _back_btn:    Button          = $TopBar/BackButton
@onready var _title_lbl:   Label           = $TopBar/TitleLabel
@onready var _status_lbl:  Label           = $TopBar/StatusLabel
@onready var _save_btn:    Button          = $TopBar/SaveButton
@onready var _main_layout: HBoxContainer   = $MainLayout
@onready var _graph_host:  Control         = $MainLayout/GraphHost
@onready var _side_panel:  PanelContainer  = $MainLayout/SidePanel
@onready var _side_scroll: ScrollContainer = $MainLayout/SidePanel/SideScroll
@onready var _side_vbox:   VBoxContainer   = $MainLayout/SidePanel/SideScroll/SideVBox

static var edit_journey: Dictionary = {}

const SIDE_PANEL_WIDTH: int = 480

# Journey metadata: stored as member vars since the side-panel editor widgets
# are created and destroyed dynamically when the user navigates the graph.
var _journey_name:           String = ""
var _journey_author:         String = ""
var _journey_desc:           String = ""
var _journey_difficulty_idx: int    = 0
var _journey_tags:           Array  = []  # Array[String] of tag ids (see TagRegistry)

# Folder the journey was loaded from when editing. If the journey is renamed,
# the save writes a new folder; this lets us delete the stale original.
var _original_journey_folder: String = ""

var _cover_path:    String       = ""
var _cover_texture: ImageTexture = null  # cached so the journey-info view can re-show the preview without re-reading from disk

var _items:      Array  = []  # Array[Dictionary] — {type:"round"|"fork"|"shop"|"storyboard", ...}

var _graph: Control = null  # GraphView instance, host inside _graph_host
# Single-selection mirror of GraphView (valid only when exactly one node is
# selected). Drives the per-node side-panel editor. When 0 or 2+ nodes are
# selected, _selected_item is {} and _selected_idx is -1.
var _selected_item: Dictionary = {}  # The lone selected item, or {}.
var _selected_arr:  Array      = []  # The array the selection lives in (any size).
var _selected_idx:  int        = -1  # Index of the lone selected item, or -1.

# Full selection set mirror (1+ items, all in _selected_arr). Group operations
# (copy / cut / delete / move) act on this.
var _selected_items: Array = []

# Fork-branch selection (mutually exclusive with node selection): when true,
# new/pasted items are inserted at the TOP of _branch_arr (a fork path's items).
var _has_branch: bool  = false
var _branch_arr: Array = []

# Module-level copy/paste clipboard. Holds deep duplicates of the copied item(s)
# (round / shop / storyboard / fork-with-subtree, or several at once). Paste
# inserts fresh deep duplicates so the same entry can be pasted repeatedly
# without the pastes sharing references. Image/script paths inside the copies
# resolve to the same source files, so a paste + save re-copies the media into
# the new spot — this is what lets a fully-built storyboard (speaker images and
# all) move to another branch, which plain text paste could never do. Empty ==
# nothing copied.
var _clipboard_items: Array = []

# ── Undo / redo ─────────────────────────────────────────────────────────────
# Snapshot-based undo of the journey STRUCTURE only. Each stack entry is a deep
# copy of the whole _items tree taken just before a structural mutation (add /
# delete / move / duplicate / paste of modules, fork paths, storyboard lines).
# In-field text edits are deliberately NOT snapshotted — they keep their own
# native LineEdit/TextEdit undo, and snapshotting per keystroke would be noise.
# Undo never touches disk, so it can't (and never needs to) resurrect deleted
# image files; that's why image/field removals stay out of scope.
var _undo_stack: Array = []  # Array[Array] — past states, most recent last.
var _redo_stack: Array = []  # Array[Array] — undone states available to redo.
const UNDO_LIMIT: int = 50

# Side panel renderer — owns no state of its own; reads/mutates this controller.
var _side_renderer: BuilderSidePanel = null

var _transcode_cancel: bool = false
var _transcode_pid:    int  = -1

# Set true when a video copy/transcode is cancelled mid-save inside a fork path,
# so the recursive _save_fork/_save_path chain can unwind and _on_save_pressed
# can abort the whole save cleanly.
var _save_aborted: bool = false

# Detailed failure info captured during a fork-path copy so the top-level
# handler can produce a specific error message instead of a generic "save
# cancelled". Shape: {"reason": String, "item": String, "detail": String}.
# Reset to {} at the start of every save.
var _save_abort_error: Dictionary = {}

# Save-wide counter that yields short, unique, filesystem-safe folder names
# for every round (top-level + every fork path at every nesting depth). Bounds
# the on-disk path length regardless of how long the user's round names are,
# and eliminates the round-name-collision bug where two rounds in different
# fork paths sharing a name landed in the same folder. The human-readable
# round name is preserved in journey.json's "Name" field; the slug ends up in
# the new "FolderName" field and is what the catalogue reads on load.
var _round_folder_counter: int = 0

# Save-wide map of non-H.264 video source paths → {codec, duration}. Built
# once at the start of _on_save_pressed by walking the whole journey tree,
# then consulted in both the top-level round save AND the recursive
# _save_path so that videos inside fork paths get transcoded too.
var _transcode_plan: Dictionary = {}

# Shared content-pool state for the current save. Reset at the start of
# _save_all_items. `_pooled_media` maps a source fingerprint → its journey-root-
# relative pooled path (content/m_<fp>.<ext>); the second+ round to reference a
# source reuses the path and skips the transcode/copy. `_pooled_fs_stats` caches
# funscript {count,length_ms} per fingerprint so a reused script isn't re-parsed.
var _pooled_media: Dictionary = {}
var _pooled_fs_stats: Dictionary = {}

# Count of player run-saves invalidated by this builder save (typically 0 or
# 1, possibly 2 if both the renamed-from and renamed-to folders had saves).
# Drives the contextual "Existing run reset" message in the success status
# so the author isn't surprised that the Resume button disappeared from the
# catalogue. Reset in _reset_save_state.
var _invalidated_save_count: int = 0

# Location of the node to test-play from after this save, or {} for a normal
# save (which returns to the catalogue instead of launching a preview). Shape:
#   {"chain": Array[[fork_local_idx, path_idx]], "final": int}
# An empty chain means a top-level node ("final" is its _items index); each chain
# entry descends into a fork path, so nodes nested inside forks are reachable.
# Set by _save_and_test_from, consulted at the tail of _do_save, reset in
# _reset_save_state. See _seek_to_location for how it drives GameState.
var _pending_test_location: Dictionary = {}

# Starting score / coin balance for a test play, applied by GameLoop before the
# first node loads. Lets the author exercise Conditional / Sacrifice forks (which
# read last-round score and coin balance) from a chosen node. Persist across
# selections so they aren't re-entered every time; edited via the test controls
# in the node editor side panel.
var _test_seed_score: int = 0
var _test_seed_coins: int = 0

# Streaming-copy tuning. Chunks are read/written 1 MB at a time; the main thread
# yields one frame only after COPY_FRAME_BUDGET_MS of accumulated work — frequent
# enough that the window stays responsive, rare enough that the frame-wait tax
# stays under ~1 s even on multi-GB videos.
const COPY_CHUNK_SIZE:       int = 1024 * 1024
const COPY_FRAME_BUDGET_MS:  int = 100


func _ready() -> void:
	MusicService.play()
	_side_renderer = BuilderSidePanel.new(self)
	_apply_layout()
	_apply_theme()
	_setup_toolbar_buttons()
	_connect_signals()
	_setup_graph_view()
	if not edit_journey.is_empty():
		_original_journey_folder = edit_journey.get("folder", "")
		_load_journey(edit_journey)
		edit_journey = {}
	_side_renderer.show_journey_info_panel()
	# Check for leftover staging folders from interrupted saves (crash, force-
	# kill, power loss). They take disk space and the user has no way to know
	# they exist otherwise — the dot prefix hides them from the catalogue.
	# Deferred so the dialog appears over the fully-rendered builder.
	call_deferred("_check_for_stale_staging_folders")


# Builds the GraphView inside the GraphHost slot, wires its selection / insert
# signals to the side panel.
func _setup_graph_view() -> void:
	_graph = GraphViewScene.instantiate()
	_graph.anchor_right  = 1.0
	_graph.anchor_bottom = 1.0
	_graph_host.add_child(_graph)
	_graph.selection_changed.connect(_on_graph_selection_changed)
	_graph.branch_selected.connect(_on_graph_branch_selected)
	_graph.insert_requested.connect(_on_graph_insert_requested)
	# Live per-node validation badges (evaluated at layout time).
	_graph.validity_fn = _item_issue_summary
	# Initial state: render current _items (empty for a new journey).
	_graph.call_deferred("set_items", _items)


# Reacts to a selection change from the graph. Keeps both the single-selection
# mirror (for the per-node editor) and the full set mirror (for group ops) in
# sync, then renders the matching side panel: journey info (0), node editor (1),
# or the multi-select panel (2+).
func _on_graph_selection_changed(items: Array, arr: Array) -> void:
	# Any node/empty selection ends a branch selection.
	_has_branch = false
	_branch_arr = []
	_selected_items = items
	_selected_arr   = arr
	if items.size() == 1:
		_selected_item = items[0]
		_selected_idx  = _index_in_arr(arr, items[0])
		_side_renderer.show_node_editor(_selected_item, arr, _selected_idx)
	else:
		_selected_item = {}
		_selected_idx  = -1
		if items.is_empty():
			_side_renderer.show_journey_info_panel()
		else:
			_side_renderer.show_multi_select_panel(items, arr)


# A fork branch (path) was clicked. Becomes the insertion target — new/pasted
# items land at the top of the path. Clears node selection (mutually exclusive).
func _on_graph_branch_selected(path: Dictionary) -> void:
	if not path.has("items"):
		path["items"] = []
	_selected_items = []
	_selected_arr   = []
	_selected_item  = {}
	_selected_idx   = -1
	_has_branch = true
	_branch_arr = path["items"]
	_side_renderer.show_branch_panel(path)


# Index of `item` within `arr` by reference identity (Dictionary == is deep
# equality, which is unreliable for look-alike items). Returns -1 if absent.
func _index_in_arr(arr: Array, item: Dictionary) -> int:
	for i in arr.size():
		if is_same(arr[i], item):
			return i
	return -1


func _on_graph_insert_requested(arr: Array, idx: int, screen_pos: Vector2) -> void:
	_side_renderer.show_insert_popup(self, _graph, arr, idx, screen_pos)


# Replaces _refresh_items()'s former role: rebuild the graph from _items.
# Called after structural changes (load, drop import, etc).
func _refresh_graph() -> void:
	if _graph:
		_graph.set_items(_items)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0; _bg.offset_top = 0; _bg.offset_right = 0; _bg.offset_bottom = 0

	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right  = 1.0
	_top_bar.offset_left   = 16
	_top_bar.offset_right  = -16
	_top_bar.offset_top    = 12
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 12)

	# Title expands to fill space between Back (left) and Status/Save (right).
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_main_layout.anchor_right  = 1.0
	_main_layout.anchor_bottom = 1.0
	_main_layout.offset_left   = 16
	_main_layout.offset_right  = -16
	_main_layout.offset_top    = TOP_BAR_HEIGHT + 8
	_main_layout.offset_bottom = -16
	_main_layout.add_theme_constant_override("separation", 12)

	_graph_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph_host.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_graph_host.clip_contents         = true

	_side_panel.custom_minimum_size = Vector2(SIDE_PANEL_WIDTH, 0)
	_side_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_side_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	_side_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_side_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_side_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	_side_vbox.add_theme_constant_override("separation", 10)
	_side_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = UITheme.BG

	UITheme.style_label(_title_lbl, UITheme.PURPLE_BRIGHT, 18, true)
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	UITheme.style_button(_back_btn, UITheme.MAGENTA)
	UITheme.style_button(_save_btn, UITheme.PURPLE_BRIGHT)
	_save_btn.custom_minimum_size = Vector2(180, 0)

	_status_lbl.add_theme_font_size_override("font_size", 13)
	_status_lbl.visible = false

	# Side panel background
	var sp_style: StyleBoxFlat = StyleBoxFlat.new()
	sp_style.bg_color           = UITheme.PANEL_BG
	sp_style.border_color       = UITheme.PURPLE_MID
	sp_style.border_width_left  = 1; sp_style.border_width_right  = 1
	sp_style.border_width_top   = 1; sp_style.border_width_bottom = 1
	sp_style.content_margin_left   = 14; sp_style.content_margin_right  = 14
	sp_style.content_margin_top    = 14; sp_style.content_margin_bottom = 14
	_side_panel.add_theme_stylebox_override("panel", sp_style)


# ---------------------------------------------------------------------------
# Toolbar (top bar) — Fit + Shortcuts buttons inserted before Save
# ---------------------------------------------------------------------------

# Adds the "Fit" (frame the whole graph) and "Shortcuts" (keybinding reference)
# buttons to the top bar, just left of Save. Created in code so the .tscn stays
# untouched.
func _setup_toolbar_buttons() -> void:
	var fit_btn: Button = Button.new()
	fit_btn.text = "⊡ FIT"
	fit_btn.focus_mode = Control.FOCUS_NONE
	fit_btn.tooltip_text = "Frame the whole journey in view"
	UITheme.style_button(fit_btn, UITheme.PURPLE_MID)
	fit_btn.pressed.connect(func() -> void:
		if _graph:
			_graph.fit_to_view()
	)
	_top_bar.add_child(fit_btn)
	_top_bar.move_child(fit_btn, _save_btn.get_index())

	var img_btn: Button = Button.new()
	img_btn.text = "📷 IMAGE"
	img_btn.focus_mode = Control.FOCUS_NONE
	img_btn.tooltip_text = "Export a high-res PNG of the whole journey layout (to share)"
	UITheme.style_button(img_btn, UITheme.PURPLE_MID)
	img_btn.pressed.connect(_on_export_image_pressed)
	_top_bar.add_child(img_btn)
	_top_bar.move_child(img_btn, _save_btn.get_index())

	var keys_btn: Button = Button.new()
	keys_btn.text = "⌨ SHORTCUTS"
	keys_btn.focus_mode = Control.FOCUS_NONE
	keys_btn.tooltip_text = "Show keyboard & mouse shortcuts"
	UITheme.style_button(keys_btn, UITheme.PURPLE_MID)
	keys_btn.pressed.connect(_show_shortcuts_overlay)
	_top_bar.add_child(keys_btn)
	_top_bar.move_child(keys_btn, _save_btn.get_index())


# ---------------------------------------------------------------------------
# Export image — high-res PNG of the whole journey layout (for sharing)
# ---------------------------------------------------------------------------

const CAPTURE_SCALE:          float = 1.0             # render multiplier (native = crisp text; >1 = more pixels but softer)
const CAPTURE_MARGIN:         float = 48.0            # px padding around the graph
const CAPTURE_MAX_DIM:        int   = 12000           # cap longest side
const CAPTURE_MAX_MEGAPIXELS: float = 48.0            # cap total area (bounds the render target's GPU/RAM)
const CAPTURE_MAX_BYTES:      int   = 8 * 1024 * 1024  # 8 MB site upload limit
const CAPTURE_JPEG_QUALITY:   float = 0.9             # used when a PNG would blow the 8 MB budget


func _on_export_image_pressed() -> void:
	if _items.is_empty():
		_show_status("Nothing to capture — add a round first.", true)
		return
	_show_status("Rendering layout image…", false)
	var img: Image = await _render_graph_image()
	if img == null:
		_show_status("Couldn't render the layout image.", true)
		return
	_save_capture_with_dialog(_encode_for_sharing(img))


# Renders a FRESH GraphView of the current items into an offscreen SubViewport at
# full content size (× CAPTURE_SCALE) on a dark background, and reads it back as an
# Image. The live builder graph is a separate instance and stays untouched.
# Returns null on an empty graph / failure.
func _render_graph_image() -> Image:
	var svp: SubViewport = SubViewport.new()
	svp.transparent_bg = false
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svp.size = Vector2i(64, 64)

	var bg: ColorRect = ColorRect.new()
	bg.color = UITheme.BG
	bg.anchor_right = 1.0; bg.anchor_bottom = 1.0
	svp.add_child(bg)

	var g: GraphView = GraphViewScene.instantiate()
	g.anchor_right = 1.0; g.anchor_bottom = 1.0
	svp.add_child(g)
	add_child(svp)   # offscreen — a bare SubViewport still renders to its texture

	g.set_items(_items)
	# Wait for the deferred layout chain (refresh → _do_layout → centre) to settle.
	var tries: int = 0
	while g.content_bounds().is_empty() and tries < 30:
		await get_tree().process_frame
		tries += 1

	var scale: float = CAPTURE_SCALE
	var img_size: Vector2 = g.frame_for_capture(scale, CAPTURE_MARGIN)
	if img_size == Vector2.ZERO:
		svp.queue_free()
		return null

	# Bound BOTH the longest side and the total area so a huge journey never
	# allocates an enormous render target. We shrink as little as possible — the
	# JPEG encoder (below) carries the rest of the size budget so text stays large.
	var dim_factor: float = 1.0
	var longest: float = maxf(img_size.x, img_size.y)
	if longest > float(CAPTURE_MAX_DIM):
		dim_factor = float(CAPTURE_MAX_DIM) / longest
	var area_factor: float = 1.0
	var megapixels: float = (img_size.x * img_size.y) / 1_000_000.0
	if megapixels > CAPTURE_MAX_MEGAPIXELS:
		area_factor = sqrt(CAPTURE_MAX_MEGAPIXELS / megapixels)
	var factor: float = minf(dim_factor, area_factor)
	if factor < 1.0:
		scale *= factor
		img_size = g.frame_for_capture(scale, CAPTURE_MARGIN)

	svp.size = Vector2i(ceili(img_size.x), ceili(img_size.y))
	# Let it render at the final size before the CPU read-back.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img: Image = svp.get_texture().get_image()
	svp.queue_free()
	return img


# Encodes the image for sharing under the upload budget, returning {data, ext}.
# Prefers lossless PNG (crispest for graph text/edges). When a PNG would exceed
# 8 MB — the usual case for big journeys — it switches to high-quality JPEG, which
# holds ~3–5× more pixels per byte, so the layout keeps its resolution (and the
# text stays readable) instead of being downscaled to a blur. Downscaling is the
# last resort, only if even the JPEG is over budget.
func _encode_for_sharing(img: Image) -> Dictionary:
	var png: PackedByteArray = img.save_png_to_buffer()
	if png.size() <= CAPTURE_MAX_BYTES:
		return {"data": png, "ext": "png"}

	var jpg: PackedByteArray = img.save_jpg_to_buffer(CAPTURE_JPEG_QUALITY)
	while jpg.size() > CAPTURE_MAX_BYTES and img.get_width() > 200:
		var ratio: float = sqrt(float(CAPTURE_MAX_BYTES) / float(jpg.size())) * 0.95
		var nw: int = maxi(200, int(img.get_width() * ratio))
		var nh: int = maxi(200, int(img.get_height() * ratio))
		if nw >= img.get_width():
			break
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
		jpg = img.save_jpg_to_buffer(CAPTURE_JPEG_QUALITY)
	return {"data": jpg, "ext": "jpg"}


# Native save dialog → writes the pre-encoded bytes (PNG or JPEG, per the encoder)
# to the chosen path and opens the containing folder.
func _save_capture_with_dialog(result: Dictionary) -> void:
	var data: PackedByteArray = result["data"]
	var ext: String = result["ext"]
	var base: String = JourneyData.sanitize_folder_name(_journey_name.strip_edges())
	if base == "":
		base = "journey"

	var dlg: FileDialog = FileDialog.new()
	dlg.file_mode        = FileDialog.FILE_MODE_SAVE_FILE
	dlg.access           = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.add_filter("*." + ext, ext.to_upper() + " image")
	dlg.current_file = "%s_layout.%s" % [base, ext]
	add_child(dlg)
	dlg.file_selected.connect(func(path: String) -> void:
		if not path.to_lower().ends_with("." + ext):
			path += "." + ext
		var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			_show_status("Couldn't write %s." % path.get_file(), true)
		else:
			f.store_buffer(data)
			f.close()
			_show_status("Saved layout image (%.1f MB) — %s" % [data.size() / 1048576.0, path.get_file()], false)
			OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.popup_centered_ratio(0.6)


# Centered modal listing every builder keyboard / mouse shortcut. Closeable via
# the Close button or the backdrop.
func _show_shortcuts_overlay() -> void:
	var parts: Dictionary = UITheme.build_centered_modal("⌨  SHORTCUTS", UITheme.PURPLE_BRIGHT, Vector2i(580, 640))
	var modal: Control = parts["modal"]
	var vbox: VBoxContainer = parts["vbox"]
	add_child(modal)

	# Rows live in a scroll region so the reference can grow without overflowing
	# the panel; the Close button stays pinned below it.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal  = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.add_theme_constant_override("separation", 5)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	var groups: Array = [
		["EDITING", [
			["Ctrl + C", "Copy selected module(s)"],
			["Ctrl + X", "Cut selected module(s)"],
			["Ctrl + V", "Paste after selection"],
			["Ctrl + Z", "Undo"],
			["Ctrl + Y  /  Ctrl + Shift + Z", "Redo"],
			["Backspace  /  Delete", "Delete selected module(s)"],
			["Ctrl + S", "Save journey"],
		]],
		["ADD", [
			["Ctrl + 1", "Add a round"],
			["Ctrl + 2", "Add a shop"],
			["Ctrl + 3", "Add a storyboard"],
			["Ctrl + 4", "Add a fork"],
		]],
		["SELECTION", [
			["Click", "Select a node"],
			["Click a fork branch", "Target it — add/paste to the top of that path"],
			["Shift + Click", "Select a range of nodes (same branch)"],
			["Ctrl + Click", "Add / remove a node from selection"],
			["Drag on empty canvas", "Marquee-select (same branch)"],
			["Ctrl + A", "Select all in the current branch"],
			["Escape", "Clear selection"],
		]],
		["NAVIGATION", [
			["Middle-drag", "Pan the graph"],
			["Mouse wheel", "Zoom in / out"],
			["⊡ Fit button", "Frame the whole journey"],
		]],
		["IMPORT", [
			["Drop files on the graph", "Auto-create rounds (paired by name)"],
			["Drop a folder on the graph", "Recursively import every scene"],
		]],
	]

	for group: Array in groups:
		var section_lbl: Label = Label.new()
		section_lbl.text = group[0]
		section_lbl.add_theme_color_override("font_color", UITheme.SEPARATOR)
		section_lbl.add_theme_font_size_override("font_size", 11)
		section_lbl.uppercase = true
		list.add_child(section_lbl)
		for row_spec: Array in group[1]:
			var row: HBoxContainer = HBoxContainer.new()
			row.add_theme_constant_override("separation", 14)
			var key_lbl: Label = Label.new()
			key_lbl.text = row_spec[0]
			key_lbl.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
			key_lbl.add_theme_font_size_override("font_size", 12)
			key_lbl.custom_minimum_size = Vector2(240, 0)
			row.add_child(key_lbl)
			var desc_lbl: Label = Label.new()
			desc_lbl.text = row_spec[1]
			desc_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
			desc_lbl.add_theme_font_size_override("font_size", 12)
			desc_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(desc_lbl)
			list.add_child(row)
		var spacer: Control = Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		list.add_child(spacer)

	var close_btn: Button = Button.new()
	close_btn.text = "CLOSE"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_button(close_btn, UITheme.PURPLE_BRIGHT)
	close_btn.pressed.connect(func() -> void: modal.queue_free())
	vbox.add_child(close_btn)

	# Backdrop click also dismisses (the backdrop is the modal's first child).
	var backdrop: Control = modal.get_child(0) as Control
	if backdrop:
		backdrop.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
				modal.queue_free()
		)


# ---------------------------------------------------------------------------
# Style helpers
# ---------------------------------------------------------------------------

# Style helpers moved to UITheme (autoload). Callers use UITheme.style_*(...).


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_save_btn.pressed.connect(_on_save_pressed)
	get_viewport().files_dropped.connect(_on_viewport_files_dropped)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# Only fresh key-down events; ignore key-up and auto-repeat (echo). The echo
	# guard also stops a held Backspace/Delete from chain-deleting nodes.
	if not k.pressed or k.echo:
		return

	if k.ctrl_pressed:
		# ── Ctrl-modified shortcuts ──────────────────────────────────────────
		match k.keycode:
			KEY_S:
				if not _save_btn.disabled:
					_on_save_pressed()
				get_viewport().set_input_as_handled()
			KEY_C:
				# Defer to native text copy when a text field is focused — do NOT
				# consume the event in that case, or the LineEdit/TextEdit never
				# sees it.
				if _focus_is_text_field():
					return
				_copy_selection()
				get_viewport().set_input_as_handled()
			KEY_X:
				if _focus_is_text_field():
					return
				_cut_selection()
				get_viewport().set_input_as_handled()
			KEY_V:
				if _focus_is_text_field():
					return
				_paste_clipboard_after_selection()
				get_viewport().set_input_as_handled()
			KEY_Z:
				# Ctrl+Shift+Z is the common redo alias; plain Ctrl+Z undoes.
				if _focus_is_text_field():
					return
				if k.shift_pressed:
					_redo()
				else:
					_undo()
				get_viewport().set_input_as_handled()
			KEY_Y:
				if _focus_is_text_field():
					return
				_redo()
				get_viewport().set_input_as_handled()
			KEY_A:
				# Defer to native "select all" inside a text field.
				if _focus_is_text_field():
					return
				_select_all_in_branch()
				get_viewport().set_input_as_handled()
			KEY_1:
				if _focus_is_text_field():
					return
				_insert_new_item("round")
				get_viewport().set_input_as_handled()
			KEY_2:
				if _focus_is_text_field():
					return
				_insert_new_item("shop")
				get_viewport().set_input_as_handled()
			KEY_3:
				if _focus_is_text_field():
					return
				_insert_new_item("storyboard")
				get_viewport().set_input_as_handled()
			KEY_4:
				if _focus_is_text_field():
					return
				_insert_new_item("fork")
				get_viewport().set_input_as_handled()
		return

	# ── Unmodified shortcuts ─────────────────────────────────────────────────
	match k.keycode:
		KEY_BACKSPACE, KEY_DELETE:
			# Must yield to text editing — Backspace/Delete still edit characters
			# inside a focused LineEdit/TextEdit.
			if _focus_is_text_field():
				return
			_delete_selection()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			# Clear the current selection (node set or fork branch). Only consume
			# the event when there was something to clear.
			if _focus_is_text_field() or (_selected_items.is_empty() and not _has_branch):
				return
			if _graph:
				_graph.clear_selection()
			get_viewport().set_input_as_handled()


# True when the keyboard focus is inside a text-entry control, so module
# copy/paste shortcuts should stand down and let normal text editing happen.
func _focus_is_text_field() -> bool:
	var f: Control = get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


# Where a new/pasted item should go, as {arr, at}:
#   • a node selection → right after the last selected item (same branch)
#   • a fork-branch selection → the top of that path
#   • nothing selected → the end of the top level
func _insertion_target() -> Dictionary:
	if not _selected_items.is_empty():
		return {"arr": _selected_arr, "at": _selected_indices_sorted()[-1] + 1}
	if _has_branch:
		return {"arr": _branch_arr, "at": 0}
	return {"arr": _items, "at": _items.size()}


# Ctrl+1–4 — inserts a new item of `type` at the current insertion target. The
# new node becomes the selection so its editor opens immediately.
func _insert_new_item(type: String) -> void:
	var item: Dictionary = JourneyData.new_item(type)
	var target: Dictionary = _insertion_target()
	var arr: Array = target["arr"]
	var at: int    = target["at"]
	_push_undo()
	arr.insert(at, item)
	_refresh_graph()
	_graph.call_deferred("select_item", arr, at)
	_show_status("Added %s." % _item_type_label(item), false)


# Ctrl+A — selects every node in the current branch: the node selection's parent
# array, the selected fork branch's items, or the top level when nothing's
# selected. Does not descend into fork paths.
func _select_all_in_branch() -> void:
	var arr: Array = _items
	if not _selected_arr.is_empty():
		arr = _selected_arr
	elif _has_branch:
		arr = _branch_arr
	if arr.is_empty():
		return
	_graph.set_selection(arr.duplicate(), arr)


# Indices of the current selection within _selected_arr, ascending. Identity-
# based (look-alike dicts would confuse ==).
func _selected_indices_sorted() -> Array:
	var idxs: Array = []
	for it: Dictionary in _selected_items:
		var i: int = _index_in_arr(_selected_arr, it)
		if i >= 0:
			idxs.append(i)
	idxs.sort()
	return idxs


# Selected items ordered by their position in the sequence (so copy/paste keeps
# authoring order regardless of click order).
func _selected_items_in_order() -> Array:
	var out: Array = []
	for i: int in _selected_indices_sorted():
		out.append(_selected_arr[i])
	return out


# Removes every selected item from _selected_arr (descending index so earlier
# removals don't shift later ones).
func _remove_selected_from_arr() -> void:
	var idxs: Array = _selected_indices_sorted()
	idxs.reverse()
	for i: int in idxs:
		_selected_arr.remove_at(i)


# Label for the clipboard contents: the type when one item, else a count.
func _clipboard_label() -> String:
	if _clipboard_items.size() == 1:
		return _item_type_label(_clipboard_items[0])
	return "%d modules" % _clipboard_items.size()


# Ctrl+C — copies the whole selection (deep; a fork brings its subtree) into the
# shared clipboard, in sequence order. No-op with a hint when nothing's selected.
func _copy_selection() -> void:
	if _selected_items.is_empty():
		_show_status("Nothing selected to copy. Click a module first.", true)
		return
	_clipboard_items = []
	for it: Dictionary in _selected_items_in_order():
		_clipboard_items.append(it.duplicate(true))
	_show_status("Copied %s — press Ctrl+V to paste." % _clipboard_label(), false)


# Ctrl+X — copies the selection to the clipboard, then removes it (one undo
# step). The classic "move" gesture: cut here, then paste elsewhere.
func _cut_selection() -> void:
	if _selected_items.is_empty():
		_show_status("Nothing selected to cut. Click a module first.", true)
		return
	_clipboard_items = []
	for it: Dictionary in _selected_items_in_order():
		_clipboard_items.append(it.duplicate(true))
	var label: String = _clipboard_label()
	_push_undo()
	_remove_selected_from_arr()
	_refresh_graph()
	if _graph:
		_graph.clear_selection()
	_show_status("Cut %s — press Ctrl+V to paste elsewhere (Ctrl+Z to undo)." % label, false)


# Backspace / Delete — removes the whole selection after snapshotting for undo.
func _delete_selection() -> void:
	if _selected_items.is_empty():
		_show_status("Nothing selected to delete. Click a module first.", true)
		return
	var label: String = ("%d modules" % _selected_items.size()) if _selected_items.size() > 1 else _item_type_label(_selected_items[0])
	_push_undo()
	_remove_selected_from_arr()
	_refresh_graph()
	if _graph:
		_graph.clear_selection()
	_show_status("Deleted %s. Press Ctrl+Z to undo." % label, false)


# Shifts the selected block by one position within its branch (delta -1 up / +1
# down). Blocked when the block already touches that end. Selection is preserved.
func _move_selection(delta: int) -> void:
	if _selected_items.is_empty():
		return
	var idxs: Array = _selected_indices_sorted()
	if delta < 0 and idxs[0] <= 0:
		return
	if delta > 0 and idxs[-1] >= _selected_arr.size() - 1:
		return
	_push_undo()
	if delta < 0:
		for i: int in idxs:  # ascending — each swaps up into the freed slot
			var tmp: Variant = _selected_arr[i]
			_selected_arr[i]     = _selected_arr[i - 1]
			_selected_arr[i - 1] = tmp
	else:
		idxs.reverse()       # descending — swap down without clobbering
		for i: int in idxs:
			var tmp: Variant = _selected_arr[i]
			_selected_arr[i]     = _selected_arr[i + 1]
			_selected_arr[i + 1] = tmp
	_refresh_graph()
	# Same item references, new positions — re-highlight them.
	_graph.set_selection(_selected_items, _selected_arr)


# Inserts fresh deep duplicates of the clipboard into `arr` at `idx`, as one undo
# step, and selects the pasted block. The single paste primitive shared by every
# entry point (Ctrl+V, the insert-menu Paste, and top-level Paste).
func _paste_clipboard_into(arr: Array, idx: int) -> void:
	if _clipboard_items.is_empty():
		_show_status("Clipboard is empty. Copy a module first (Ctrl+C).", true)
		return
	_push_undo()
	for i in _clipboard_items.size():
		arr.insert(idx + i, _clipboard_items[i].duplicate(true))
	_refresh_graph()
	var pasted: Array = []
	for i in _clipboard_items.size():
		pasted.append(arr[idx + i])
	_graph.call_deferred("set_selection", pasted, arr)


# Ctrl+V — pastes at the current insertion target (after a node selection, the
# top of a selected branch, or the end of the top level).
func _paste_clipboard_after_selection() -> void:
	var target: Dictionary = _insertion_target()
	_paste_clipboard_into(target["arr"], target["at"])


# Records the current journey structure so the next mutation can be undone.
# MUST be called *before* a structural change is applied (and only when the
# change will actually happen — e.g. after a move's bounds guard). Clears the
# redo stack, since a fresh edit forks history away from any undone states.
func _push_undo() -> void:
	_undo_stack.append(_items.duplicate(true))
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()


# Ctrl+Z — reverts to the structure captured by the last _push_undo().
func _undo() -> void:
	if _undo_stack.is_empty():
		_show_status("Nothing to undo.", false)
		return
	_redo_stack.append(_items.duplicate(true))
	_restore_snapshot(_undo_stack.pop_back())
	_show_status("Undid last change.", false)


# Ctrl+Y (or Ctrl+Shift+Z) — re-applies the most recently undone structure.
func _redo() -> void:
	if _redo_stack.is_empty():
		_show_status("Nothing to redo.", false)
		return
	_undo_stack.append(_items.duplicate(true))
	_restore_snapshot(_redo_stack.pop_back())
	_show_status("Redid change.", false)


# Swaps the live _items tree for a snapshot. Mutates in place rather than
# reassigning, because GraphView and the open side-panel editors close over the
# _items array reference (and its sub-arrays); replacing the reference would
# leave them pointing at the stale tree. Selection is cleared afterwards since
# the old selection's array/index may no longer be valid in the restored tree.
func _restore_snapshot(snapshot: Array) -> void:
	_items.clear()
	for it in snapshot:
		_items.append(it)
	if _graph:
		_graph.set_items(_items)
		_graph.clear_selection()


# Short uppercase label for an item's type, for status messages.
func _item_type_label(item: Dictionary) -> String:
	match item.get("type", "round"):
		"round":      return "ROUND"
		"shop":       return "SHOP"
		"storyboard": return "STORYBOARD"
		"fork":       return "FORK"
	return "ITEM"


func _on_back_pressed() -> void:
	Transition.change_scene("res://scenes/main/Main.tscn")


# Absolute path of this journey's folder on disk, or "" if it hasn't been saved
# yet. Prefers the folder for the current (possibly renamed) name; falls back to
# the folder it was loaded from.
func _saved_journey_folder_abs() -> String:
	var name: String = _journey_name.strip_edges()
	if name != "":
		var folder: String = SettingsService.get_journeys_dir() + "/" + JourneyData.sanitize_folder_name(name)
		var abs: String = ProjectSettings.globalize_path(folder)
		if DirAccess.dir_exists_absolute(abs):
			return abs
	if _original_journey_folder != "":
		var orig_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if DirAccess.dir_exists_absolute(orig_abs):
			return orig_abs
	return ""


# Opens this journey's media/ folder in the OS file browser. Requires a prior
# save so the folder exists; otherwise nudges the user to save first. Falls back
# to the journey root on the off chance media/ isn't there.
func _open_journey_folder() -> void:
	var abs: String = _saved_journey_folder_abs()
	if abs == "":
		_show_status("Save the journey first — its folder doesn't exist yet.", true)
		return
	var media_abs: String = abs + "/media"
	OS.shell_open(media_abs if DirAccess.dir_exists_absolute(media_abs) else abs)


# Funscript filename suffixes that mark a secondary axis or a vibrator channel.
# Kept in sync with _detect_funscript_axis / _detect_vib_channel — used to strip
# the suffix so "scene1", "scene1_L1", "scene1.vib1" all share a round key during
# bulk import.
const SCRIPT_SUFFIXES: Array[String] = [
	"_l1", ".l1", "_l2", ".l2", "_r0", ".r0", "_r1", ".r1", "_r2", ".r2",
	"_surge", ".surge", "_sway", ".sway", "_twist", ".twist", "_roll", ".roll", "_pitch", ".pitch",
	".vib1", "_vib1", ".vibe1", "_vibe1", ".vib2", "_vib2", ".vibe2", "_vibe2",
]


func _on_viewport_files_dropped(files: PackedStringArray) -> void:
	# Two drop surfaces with distinct intents:
	#   • Side panel  → "edit the selected node": multi-axis routing into the
	#     selected round, or a cover image when nothing is selected. (Single-file
	#     drops are handled by the DropZone controls themselves, which listen to
	#     the same viewport signal and only act when the mouse is over them.)
	#   • Graph canvas → "create rounds": bulk-import a round per video/funscript
	#     group, matched by filename.
	# Folder drop: a dropped directory can't target a single DropZone or be a
	# cover, so always treat it as a bulk import — expand it (recursively) into
	# its videos/funscripts and route straight to the importer.
	var has_folder: bool = false
	for f: String in files:
		if DirAccess.dir_exists_absolute(f):
			has_folder = true
			break
	if has_folder:
		var expanded: PackedStringArray = _expand_dropped_paths(files)
		if _bulk_import_rounds(expanded):
			return
		# Import created nothing. If the folder held no media at all, say so; if it
		# held only funscripts, _bulk_import_rounds already showed that message.
		if expanded.is_empty():
			_show_status("No videos or funscripts found in the dropped folder(s).", true)
		return

	var mouse: Vector2 = get_viewport().get_mouse_position()
	if _side_panel.get_global_rect().has_point(mouse):
		_handle_side_panel_drop(files)
		return

	# Canvas drop. Try a bulk round import first; if there was nothing round-like
	# in the drop, fall back to accepting an image as the journey cover.
	if not _bulk_import_rounds(files):
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.IMAGE_EXTENSIONS:
				_cover_path = f
				_update_cover_preview()
				return


# Side-panel drop behavior (unchanged from the original handler): auto-route
# multiple funscripts into the selected round's axis/vib slots, else accept a
# dropped image as the cover when nothing is selected.
func _handle_side_panel_drop(files: PackedStringArray) -> void:
	if _selected_item.get("type", "") == "round" and _selected_idx >= 0:
		var fs_files: Array = []
		for f: String in files:
			if f.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
				fs_files.append(f)

		if fs_files.size() > 1:
			if not _selected_arr[_selected_idx].has("axis_scripts"):
				_selected_arr[_selected_idx]["axis_scripts"] = {}
			if not _selected_arr[_selected_idx].has("vib_scripts"):
				_selected_arr[_selected_idx]["vib_scripts"] = {}
			for f: String in fs_files:
				var vib_ch: String = _detect_vib_channel(f)
				if vib_ch != "":
					_selected_arr[_selected_idx]["vib_scripts"][vib_ch] = f
				else:
					var axis: String = _detect_funscript_axis(f)
					if axis == "L0":
						_selected_arr[_selected_idx]["funscript_path"] = f
						if (_selected_arr[_selected_idx].get("name", "") as String).strip_edges() == "":
							_selected_arr[_selected_idx]["name"] = f.get_file().get_basename()
					else:
						_selected_arr[_selected_idx]["axis_scripts"][axis] = f
			# Refresh the side panel so the new paths show up in the DropZones.
			_graph.call_deferred("select_item", _selected_arr, _selected_idx)
			return

	if not _selected_item.is_empty():
		return
	for f: String in files:
		if f.get_extension().to_lower() in JourneyData.IMAGE_EXTENSIONS:
			_cover_path = f
			_update_cover_preview()
			return


# Bulk-import handler. Groups the dropped files by folder + base name and builds
# one round per group — main funscript + video + any secondary axis / vib
# scripts, matched by suffix. A group MUST end up with a video to become a round:
# funscript-only groups (with no matching video on disk) are skipped, while a
# video with no funscript still becomes a round. New rounds land after the
# current selection (or at the end of the top level when nothing is selected).
# Returns true if it created at least one round, false otherwise (so the caller
# can fall back to cover-image handling). The whole import is one undo step.
func _bulk_import_rounds(files: PackedStringArray) -> bool:
	var groups: Dictionary = {}  # round_key -> {video, funscript, axis:{}, vib:{}, name}
	var order:  Array      = []  # round_keys in first-seen order

	for f: String in files:
		var ext: String = f.get_extension().to_lower()
		var key: String = _round_group_key(f)
		if ext in JourneyData.VIDEO_EXTENSIONS:
			_ensure_import_group(groups, order, key)
			groups[key]["video"] = f
			if groups[key]["name"] == "":
				groups[key]["name"] = f.get_file().get_basename()
		elif ext in JourneyData.FUNSCRIPT_EXTENSIONS:
			_ensure_import_group(groups, order, key)
			var vib_ch: String = _detect_vib_channel(f)
			if vib_ch != "":
				groups[key]["vib"][vib_ch] = f
			else:
				var axis: String = _detect_funscript_axis(f)
				if axis == "L0":
					groups[key]["funscript"] = f
					if groups[key]["name"] == "":
						groups[key]["name"] = f.get_file().get_basename()
				else:
					groups[key]["axis"][axis] = f
		# Non-round files (images, etc.) are ignored here.

	if order.is_empty():
		return false

	var new_rounds: Array = []
	var skipped_no_video: int = 0
	for key: String in order:
		var g: Dictionary = groups[key]
		var rname: String = g["name"] if g["name"] != "" else key
		var rd: Dictionary = {
			"type":           "round",
			"name":           rname,
			"funscript_path": g["funscript"],
			"video_path":     g["video"],
			"coins":          0,
			"axis_scripts":   g["axis"],
			"vib_scripts":    g["vib"],
		}
		# Fill any slots the drop didn't include (e.g. axes left on disk) from
		# same-named siblings next to whichever file the group does have.
		var anchor: String = _group_anchor_path(g)
		if anchor != "":
			_autofill_round_siblings(rd, anchor)
		# A round must have a video. Funscript-only groups (no matching video on
		# disk either) are skipped entirely — a script with no video isn't a
		# playable round. A video with no funscript still becomes a round.
		if (rd["video_path"] as String) == "":
			skipped_no_video += 1
			continue
		new_rounds.append(rd)

	if new_rounds.is_empty():
		if skipped_no_video > 0:
			_show_status("No rounds created — found %d funscript%s with no matching video." % [
				skipped_no_video, "s" if skipped_no_video != 1 else ""], true)
		return false

	_push_undo()

	# Placement: after the selected node (into its branch), else top-level append.
	var target_arr: Array = _items
	var insert_base: int  = _items.size()
	if _selected_idx >= 0 and _selected_idx < _selected_arr.size():
		target_arr  = _selected_arr
		insert_base = _selected_idx + 1

	for i in new_rounds.size():
		target_arr.insert(insert_base + i, new_rounds[i])

	_refresh_graph()
	# Select the last imported round so the user lands on the newest content.
	_graph.call_deferred("select_item", target_arr, insert_base + new_rounds.size() - 1)
	var msg: String = "Imported %d round%s." % [new_rounds.size(), "s" if new_rounds.size() != 1 else ""]
	if skipped_no_video > 0:
		msg += " Skipped %d funscript%s with no video." % [skipped_no_video, "s" if skipped_no_video != 1 else ""]
	msg += " Press Ctrl+Z to undo."
	_show_status(msg, false)
	return true


# Expands a dropped path list: directories are walked recursively and replaced
# by the video/funscript files inside them; plain files pass through unchanged.
# The result is sorted so rounds come out in a stable, predictable order.
func _expand_dropped_paths(files: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	for f: String in files:
		if DirAccess.dir_exists_absolute(f):
			_collect_files_recursive(f, out)
		else:
			out.append(f)
	out.sort()
	return out


# Recursively appends every video/funscript file under `dir` (and its
# subdirectories) into `out`. Other file types are skipped.
func _collect_files_recursive(dir: String, out: PackedStringArray) -> void:
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if fname != "." and fname != "..":
			var full: String = "%s/%s" % [dir, fname]
			if d.current_is_dir():
				_collect_files_recursive(full, out)
			else:
				var ext: String = fname.get_extension().to_lower()
				if ext in JourneyData.VIDEO_EXTENSIONS or ext in JourneyData.FUNSCRIPT_EXTENSIONS:
					out.append(full)
		fname = d.get_next()
	d.list_dir_end()


# Round grouping key for bulk import: directory + base name (suffix stripped),
# lowercased. Including the directory keeps same-name files in different folders
# as separate rounds while still pairing a video with its scripts in one folder.
func _round_group_key(f: String) -> String:
	return ("%s/%s" % [f.get_base_dir(), _strip_script_suffix(f)]).to_lower()


# Returns any one real file path from an import group (video preferred, then
# main funscript, then a secondary axis, then a vib script), or "" if the group
# somehow holds none. Used to anchor the disk scan for sibling autofill.
func _group_anchor_path(g: Dictionary) -> String:
	if g["video"] != "":
		return g["video"]
	if g["funscript"] != "":
		return g["funscript"]
	for a: String in (g["axis"] as Dictionary).values():
		return a
	for v: String in (g["vib"] as Dictionary).values():
		return v
	return ""


# Creates an empty import group for `key` (preserving first-seen order) if it
# doesn't exist yet.
func _ensure_import_group(groups: Dictionary, order: Array, key: String) -> void:
	if not groups.has(key):
		groups[key] = {"video": "", "funscript": "", "axis": {}, "vib": {}, "name": ""}
		order.append(key)


# Returns the file's basename with any recognised axis/vib suffix removed, so a
# secondary-axis or vib script groups with its main round during bulk import.
func _strip_script_suffix(path: String) -> String:
	var stem: String = path.get_file().get_basename()
	var low:  String = stem.to_lower()
	for s: String in SCRIPT_SUFFIXES:
		if low.ends_with(s):
			return stem.substr(0, stem.length() - s.length())
	return stem


# Scans `dir` for every funscript whose base name (suffix stripped) matches
# `base`, classifying each into the main stroke script, a secondary axis, or a
# vib channel — reusing the same suffix detection as drag-routing. Returns
# {"funscript": String, "axis": Dictionary, "vib": Dictionary}; first match wins
# per slot. Used to auto-fill all of a round's scripts from a single anchor file.
func _find_sibling_scripts(dir: String, base: String) -> Dictionary:
	var result: Dictionary = {"funscript": "", "axis": {}, "vib": {}}
	var base_low: String = base.to_lower()
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return result
	d.list_dir_begin()
	var fname: String = d.get_next()
	while fname != "":
		if not d.current_is_dir() and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
			var full: String = "%s/%s" % [dir, fname]
			if _strip_script_suffix(full).to_lower() == base_low:
				var vib_ch: String = _detect_vib_channel(full)
				if vib_ch != "":
					if not result["vib"].has(vib_ch):
						result["vib"][vib_ch] = full
				else:
					var axis: String = _detect_funscript_axis(full)
					if axis == "L0":
						if result["funscript"] == "":
							result["funscript"] = full
					elif not result["axis"].has(axis):
						result["axis"][axis] = full
		fname = d.get_next()
	d.list_dir_end()
	return result


# Finds a video next to a funscript/round by base name. Returns its path, or ""
# if none exists.
func _find_sibling_video(dir: String, base: String) -> String:
	for ext: String in JourneyData.VIDEO_EXTENSIONS:
		var cand: String = "%s/%s.%s" % [dir, base, ext]
		if FileAccess.file_exists(cand):
			return cand
	return ""


# Fills any EMPTY slots of `round` (main funscript, video, secondary axes, vib
# channels) from same-named files sitting next to `anchor_path` on disk. Never
# overwrites a slot the author already set. Returns true if anything was filled.
# Used by both the single-round drop autofill and the bulk importer.
func _autofill_round_siblings(round_data: Dictionary, anchor_path: String) -> bool:
	var dir:  String = anchor_path.get_base_dir()
	var base: String = _strip_script_suffix(anchor_path)
	var changed: bool = false

	var scan: Dictionary = _find_sibling_scripts(dir, base)

	if (round_data.get("funscript_path", "") as String) == "" and scan["funscript"] != "":
		round_data["funscript_path"] = scan["funscript"]
		changed = true
	if (round_data.get("video_path", "") as String) == "":
		var sv: String = _find_sibling_video(dir, base)
		if sv != "":
			round_data["video_path"] = sv
			changed = true

	if not round_data.has("axis_scripts"):
		round_data["axis_scripts"] = {}
	for axis: String in scan["axis"]:
		if not (round_data["axis_scripts"] as Dictionary).has(axis):
			round_data["axis_scripts"][axis] = scan["axis"][axis]
			changed = true

	if not round_data.has("vib_scripts"):
		round_data["vib_scripts"] = {}
	for ch: String in scan["vib"]:
		if not (round_data["vib_scripts"] as Dictionary).has(ch):
			round_data["vib_scripts"][ch] = scan["vib"][ch]
			changed = true

	return changed


# Infers the T-code axis from a funscript filename. Checks T-code axis-code
# suffixes first (_L1, .L1) then human-readable names (_surge, .pitch, etc.).
# Returns "L0" if no axis marker is found (main stroke script).
func _detect_funscript_axis(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	# T-code axis code suffixes (underscore or dot separator).
	var axis_codes: Dictionary = {
		"_l1": "L1", ".l1": "L1",
		"_l2": "L2", ".l2": "L2",
		"_r0": "R0", ".r0": "R0",
		"_r1": "R1", ".r1": "R1",
		"_r2": "R2", ".r2": "R2",
	}
	for suffix: String in axis_codes:
		if stem.ends_with(suffix):
			return axis_codes[suffix]
	# Human-readable axis name suffixes used by common multi-axis script authors.
	var name_codes: Dictionary = {
		"_surge": "L1", ".surge": "L1",
		"_sway":  "L2", ".sway":  "L2",
		"_twist": "R0", ".twist": "R0",
		"_roll":  "R1", ".roll":  "R1",
		"_pitch": "R2", ".pitch": "R2",
	}
	for suffix: String in name_codes:
		if stem.ends_with(suffix):
			return name_codes[suffix]
	return "L0"


# Returns "vib1" or "vib2" when the filename carries a recognised vibrator-script
# suffix (.vib1, _vib1, .vibe1, _vibe1 → "vib1"; .vib2 variants → "vib2").
# Returns "" for any other filename (not a vib script).
func _detect_vib_channel(path: String) -> String:
	var stem: String = path.get_file().get_basename().to_lower()
	for s: String in [".vib1", "_vib1", ".vibe1", "_vibe1"]:
		if stem.ends_with(s):
			return "vib1"
	for s: String in [".vib2", "_vib2", ".vibe2", "_vibe2"]:
		if stem.ends_with(s):
			return "vib2"
	return ""


# ---------------------------------------------------------------------------
# Cover image
# ---------------------------------------------------------------------------

func _on_cover_pressed() -> void:
	var dialog: FileDialog = FileDialog.new()
	dialog.access    = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.filters   = ["*.png,*.jpg,*.jpeg,*.webp ; Image Files"]
	dialog.title     = "Select Cover Image"
	add_child(dialog)
	dialog.popup_centered(Vector2i(900, 600))
	dialog.file_selected.connect(func(path: String) -> void:
		_cover_path = path
		_update_cover_preview()
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())


# Loads the cover image from _cover_path into _cover_texture. The journey-info
# side-panel view reads _cover_texture when building its preview widget.
func _update_cover_preview() -> void:
	if _cover_path == "":
		_cover_texture = null
	else:
		var img: Image = JourneyData.load_image_smart(_cover_path)
		if img != null:
			_cover_texture = ImageTexture.create_from_image(img)
	# Rebuild journey-info panel so the preview widget picks up the new texture
	# (only if no node is currently selected).
	if _selected_item.is_empty():
		_side_renderer.show_journey_info_panel()


# ---------------------------------------------------------------------------
# Load existing journey for editing
# ---------------------------------------------------------------------------

func _load_journey(journey: Dictionary) -> void:
	# Parse all data via JourneyData; copy fields into our member vars so the
	# existing UI handlers can continue to read/write them directly.
	var parsed: Dictionary = JourneyData.parse_journey(journey)
	_journey_name           = parsed["name"]
	_journey_author         = parsed["author"]
	_journey_desc           = parsed["description"]
	_journey_difficulty_idx = parsed["difficulty_idx"]
	_journey_tags           = (parsed.get("tags", []) as Array).duplicate()
	if (parsed["cover_path"] as String) != "":
		_cover_path = parsed["cover_path"]
		_update_cover_preview()
	# Mutate in place rather than replacing the reference — _setup_graph_view
	# has already done call_deferred("set_items", _items), which captures the
	# array reference. If we reassign _items here, that deferred call fires
	# after _load_journey with the stale (empty) reference and clears the graph.
	_items.clear()
	for item in parsed["items"]:
		_items.append(item)
	_refresh_items()


# ---------------------------------------------------------------------------
# Round list
# ---------------------------------------------------------------------------

func _refresh_items() -> void:
	# Now an alias for the graph-rebuild path. The function name is kept
	# because many internal handlers still call it after mutating _items.
	_refresh_graph()


# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------

func _show_status(msg: String, is_error: bool) -> void:
	_status_lbl.text = msg
	_status_lbl.add_theme_color_override("font_color", UITheme.ERROR_SOFT if is_error else UITheme.SUCCESS)
	_status_lbl.visible = true


func _on_save_pressed() -> void:
	# Top-level orchestrator. Each phase is a named helper returning a clear
	# success/failure signal so the flow reads as a sequence of steps rather
	# than 250 lines of nested branches. Helpers that fail are responsible for
	# their own user-facing error modal and any staging cleanup.
	_save_btn.disabled = true
	_reset_save_state()
	if not await _do_save():
		_save_btn.disabled = false


# "Save & Test from here" entry point. Runs the exact same save pipeline as a
# normal save (so the preview plays the real, transcoded on-disk journey), then
# — instead of returning to the catalogue — launches GameLoop in test mode at
# the selected node. `item`/`arr` identify the node (arr is its containing array:
# _items for a top-level node, or a fork path's `items` for a nested one).
# _reset_save_state clears the pending location, so it's set *after* the reset.
func _save_and_test_from(item: Dictionary, arr: Array) -> void:
	var location: Dictionary = _locate_node_for_test(arr, item)
	if location.is_empty():
		_show_status("Test play: couldn't locate that node in the journey.", true)
		return
	_save_btn.disabled = true
	_reset_save_state()
	_pending_test_location = location
	if not await _do_save():
		_save_btn.disabled = false
		_pending_test_location = {}


# Resolves a selected node to a test-play location: a chain of fork decisions
# from the top level down to the node's containing array, plus the node's
# position within that array. Returns {} if the node can't be found. Positions
# are runtime-sequence positions (see _seq_pos_in_level), not raw array indices.
func _locate_node_for_test(target_arr: Array, target_item: Dictionary) -> Dictionary:
	var raw_final: int = _index_in_arr(target_arr, target_item)
	if raw_final < 0:
		return {}
	var final_pos: int = _seq_pos_in_level(target_arr, raw_final)
	if is_same(target_arr, _items):
		return {"chain": [], "final": final_pos}
	var chain: Array = []
	if _find_arr_chain(_items, target_arr, chain):
		return {"chain": chain, "final": final_pos}
	return {}


# Depth-first search for `target_arr` among the fork paths reachable from
# `level_items`. On success, `chain` is filled (outermost first) with
# [fork_seq_pos, path_idx] entries describing the descent and returns true.
# fork_seq_pos is the fork's position in its level's runtime sequence.
func _find_arr_chain(level_items: Array, target_arr: Array, chain: Array) -> bool:
	for li in level_items.size():
		var it: Dictionary = level_items[li]
		if it.get("type", "") != "fork":
			continue
		var paths: Array = it.get("paths", [])
		for p in paths.size():
			var path_items: Array = (paths[p] as Dictionary).get("items", [])
			if is_same(path_items, target_arr) or _find_arr_chain(path_items, target_arr, chain):
				chain.push_front([_seq_pos_in_level(level_items, li), p])
				return true
	return false


# Position of items[raw_idx] within its level's runtime sequence. The runtime
# orders a level by sort key — round/storyboard = order*3, shop = after*3+1,
# fork = after*3+2 (see GameState.BuildSequence / ResolveFork and the _save_path
# scheme) — which can differ from authoring order (e.g. a shop authored right
# after a fork sorts ahead of it). Replicating that here keeps the seek correct
# regardless of how the level was authored. Ties break by authoring order.
func _seq_pos_in_level(items: Array, raw_idx: int) -> int:
	var keyed: Array = []  # [[sort_key, raw_i], …]
	var order: int = 0
	var last_order: int = 0
	for i in items.size():
		var t: String = (items[i] as Dictionary).get("type", "round")
		var key: int
		match t:
			"shop":
				key = last_order * 3 + 1
			"fork":
				key = last_order * 3 + 2
			_:  # round or storyboard — both advance the order counter
				order += 1
				last_order = order
				key = order * 3
		keyed.append([key, i])
	keyed.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])
	for pos in keyed.size():
		if int(keyed[pos][1]) == raw_idx:
			return pos
	return raw_idx


# Parses the just-saved journey back into the runtime model (same path the
# catalogue uses), starts it in GameState, seeks to the chosen node, and hands
# off to GameLoop in test mode. Called from _do_save after the staging swap, so
# the on-disk journey is final and complete.
func _launch_test_play(paths: Dictionary) -> void:
	var location: Dictionary = _pending_test_location
	_pending_test_location = {}

	var folder_name: String   = (paths["final_abs_dir"] as String).get_file()
	var journey_path: String  = SettingsService.get_journeys_dir() + "/" + folder_name
	var journey: Dictionary   = JourneyScanner.parse_journey(journey_path, folder_name)
	if journey.is_empty():
		_show_status("Test play failed: could not read the saved journey.", true)
		_save_btn.disabled = false
		return

	GameState.StartJourney(journey)
	_seek_to_location(location)

	# Handshake metas read (and cleared) by GameLoop._ready. The return journey
	# is the catalogue-model dict the builder reloads when the test exits.
	GameState.set_meta("_test_mode", true)
	GameState.set_meta("_test_return_journey", journey)
	GameState.set_meta("_test_seed_score", _test_seed_score)
	GameState.set_meta("_test_seed_coins", _test_seed_coins)
	Transition.change_scene("res://scenes/game_loop/GameLoop.tscn")


# Drives GameState from a fresh StartJourney to the located node. For each fork
# decision in the chain we advance to that fork and resolve it down the chosen
# path (which splices the path's items into the sequence in authoring order),
# then advance to the next level's fork — finally stepping to the target's index
# within the deepest level. Positions map 1:1 because each authored item yields
# exactly one sequence entry, and we never advance past a path's tail sentinel
# (we only ever move forward to a fork or the target, both inside the path).
func _seek_to_location(location: Dictionary) -> void:
	var chain: Array = location.get("chain", [])
	var final_idx: int = int(location.get("final", 0))
	var level_start: int = 0
	for decision: Array in chain:
		var fork_seq: int = level_start + int(decision[0])
		while GameState.RoundIndex < fork_seq:
			GameState.Advance()
		if GameState.CurrentItemType() != "fork":
			push_warning("Test play: expected a fork at sequence index %d; starting from the journey beginning." % fork_seq)
			return
		GameState.ResolveFork(int(decision[1]))
		level_start = GameState.RoundIndex  # first item of the spliced path
	var target: int = level_start + final_idx
	while GameState.RoundIndex < target:
		GameState.Advance()


# Returns true on a fully successful save (which transitions the user away
# from the editor), false on any failure or cancellation. Each helper that
# returns false has already shown the user a specific error modal. Staging-
# folder cleanup is centralised here so the per-phase code stays focused on
# its own responsibility.
func _do_save() -> bool:
	if not _validate_presave():
		return false
	if not _build_transcode_plan():
		return false

	var paths: Dictionary = _setup_save_folders()
	var modal: Control    = _create_save_progress_modal_if_needed()

	var data: Dictionary = await _save_all_items(paths, modal)
	if modal:
		modal.queue_free()

	# Any failure past this point (including an empty data return from
	# _save_all_items) requires wiping the staging folder. Each helper
	# already showed its own error modal; we just handle the disk cleanup.
	if data.is_empty():
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false

	if not _write_journey_json(paths, data):
		JourneyData.delete_dir_recursive(paths["abs_dir"])
		return false

	_swap_staging_into_place(paths)
	_invalidate_existing_run_saves(paths)
	if not _pending_test_location.is_empty():
		_launch_test_play(paths)
	else:
		_finalize_save_success()
	return true


# Clears all in-flight save state so a previous failed save can't bleed into
# this one (stale _save_aborted flag, leftover error stash, round counter
# from a partial walk).
func _reset_save_state() -> void:
	_status_lbl.visible        = false
	_transcode_cancel          = false
	_save_aborted              = false
	_save_abort_error          = {}
	_round_folder_counter      = 0
	_invalidated_save_count    = 0
	_pending_test_location     = {}


# Runs the whole-tree presave validation pass. Returns false (and shows the
# multi-issue modal) when any problems exist.
func _validate_presave() -> bool:
	var issues: Array = _collect_presave_issues()
	if issues.is_empty():
		return true
	var headline: String = "Found %d issue%s that prevent saving. Fix the items below and try again." % [
		issues.size(),
		"s" if issues.size() != 1 else "",
	]
	_show_save_error_modal("CANNOT SAVE JOURNEY", headline, issues)
	return false


# Pixel formats the runtime decoder (EIRTeam.FFmpeg) handles: 8-bit 4:2:0, both
# the standard (`yuv420p`) and full-range JPEG (`yuvj420p`) variants. Anything
# else (10-bit, 4:2:2, 4:4:4) is re-encoded when auto-transcode is on, even if
# the codec is already H.264 — these are the "it's h264 but still won't play"
# cases. Kept broad to avoid needless re-encodes.
const SAFE_PIX_FMTS: Array[String] = ["yuv420p", "yuvj420p"]


# Populates _transcode_plan by probing every video source in the tree. With
# auto-transcode off, the plan stays empty (everything is copied as-is). With it
# on, a source is planned for transcoding when its codec isn't H.264, or it's
# H.264 in a pixel format the decoder can't handle. Returns false — and shows a
# clear, actionable modal — when auto-transcode is on but ffmpeg can't be run,
# so the save never produces a silently-unplayable video.
func _build_transcode_plan() -> bool:
	_transcode_plan = {}
	if not JourneyData.items_have_any_video(_items):
		return true

	# Auto-transcode disabled: copy every video verbatim and require nothing of
	# ffmpeg. The author has opted to manage compatibility themselves (and this
	# is the escape hatch for setups where ffmpeg can't run, e.g. some Wine).
	if not SettingsService.get_auto_transcode():
		return true

	# Honest fallback: without ffprobe we can neither verify nor convert videos.
	# Rather than silently copy and hope (the old behavior, which produced
	# unplayable rounds), stop with guidance — including the new custom-path
	# option, which is the usual fix under Wine. (Turning off auto-transcode is
	# the other way out.)
	if not _ffmpeg_available():
		_show_save_error_single(
			"CANNOT SAVE JOURNEY",
			CAUSE_FFMPEG_MISSING,
			"Journey",
			"ffmpeg / ffprobe could not be run, so videos can't be verified or converted to a format the player can decode.",
			"Set a custom ffmpeg location in Options → Transcoding (a folder containing ffmpeg and ffprobe), or install ffmpeg on your PATH. If your videos are already H.264, you can instead turn off Auto-Transcode in Options → Transcoding to use them as-is. (Under Wine, the bundled Windows ffmpeg may not launch — a system ffmpeg path usually fixes this.)")
		return false

	var all_video_sources: Array = []
	_collect_video_sources(_items, all_video_sources)

	# Probe every unique source. Same source used in multiple rounds is identity-
	# by-path so we only probe once; the plan is consulted at every save site.
	# A source is transcoded when its codec isn't H.264, or it's H.264 in a pixel
	# format the runtime decoder can't handle (10-bit, 4:2:2, …).
	for src: String in all_video_sources:
		if _transcode_plan.has(src):
			continue
		var info: Dictionary = _get_video_stream_info(src)
		var codec: String = info["codec"]
		var pix:   String = info["pix_fmt"]

		var reason: String = ""
		if codec == "":
			reason = "unverifiable"                      # couldn't read — re-encode to be safe
		elif not (codec in H264_NAMES):
			reason = codec                               # wrong codec (HEVC/AV1/VP9/…)
		elif pix != "" and not (pix in SAFE_PIX_FMTS):
			reason = "%s %s" % [codec, pix]              # h264 but undecodable profile

		if reason != "":
			_transcode_plan[src] = {"codec": reason, "duration": _video_duration_seconds(src)}

	return true


# Computes both staging and final folder paths, creates the staging tree
# (wiping any leftover from a previous interrupted save), and pre-copies the
# cover image so the loop has its dedup entry primed.
#
# Returns a Dictionary holding everything downstream phases need:
#   {
#     journey_name:        String  - sanitized + edge-stripped journey name
#     staging_journey_dir: String  - user://... path for journey.json writes
#     abs_dir:             String  - OS-absolute staging root (for file ops)
#     abs_media_dir:       String  - OS-absolute media/ subfolder
#     final_abs_dir:       String  - OS-absolute final target for the swap
#     copied_images:       Dict    - dedup map shared with _save_all_items
#   }
func _setup_save_folders() -> Dictionary:
	var journey_name: String      = _journey_name.strip_edges()
	var journeys_root: String     = SettingsService.get_journeys_dir()
	var folder_name: String       = JourneyData.sanitize_folder_name(journey_name)
	var final_journey_dir: String = journeys_root + "/" + folder_name
	var final_abs_dir: String     = ProjectSettings.globalize_path(final_journey_dir)

	# Stage to a sibling temp folder so a mid-save failure or user cancel can
	# roll back cleanly — the existing journey on disk is never touched until
	# the swap at the end. The dot prefix makes JourneyScanner skip leftover
	# staging folders if the app crashes before the swap.
	var staging_journey_dir: String = journeys_root + "/.~save_" + folder_name
	var abs_dir: String             = ProjectSettings.globalize_path(staging_journey_dir)
	if DirAccess.dir_exists_absolute(abs_dir):
		JourneyData.delete_dir_recursive(abs_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

	# All images (cover + storyboard backgrounds + line images + fork path
	# illustrations) live in media/ so the journey root only holds journey.json
	# and per-round subdirectories.
	var abs_media_dir: String = abs_dir + "/media"
	DirAccess.make_dir_recursive_absolute(abs_media_dir)

	# Pooled per-round playback content (video/funscript/axis/vib/boss image),
	# hashed and deduped, lives here — separate from media/ (journey images).
	DirAccess.make_dir_recursive_absolute(abs_dir + "/content")

	# Dedup map: source_path → dest_filename (relative to abs_media_dir).
	# Primed with the cover image when present so the same image dropped into
	# the cover slot AND a storyboard wouldn't get copied twice.
	var copied_images: Dictionary = {}
	if _cover_path != "":
		var ext: String = _cover_path.get_extension().to_lower()
		_copy_image_deduped(_cover_path, abs_media_dir, "cover." + ext, copied_images)

	return {
		"journey_name":        journey_name,
		"staging_journey_dir": staging_journey_dir,
		"abs_dir":             abs_dir,
		"abs_media_dir":       abs_media_dir,
		"final_abs_dir":       final_abs_dir,
		"copied_images":       copied_images,
	}


# Creates and parents the streaming progress modal IF the save will actually
# transfer video bytes. Returns null when there are no videos to save (no
# point in flashing a modal that immediately dismisses).
func _create_save_progress_modal_if_needed() -> Control:
	if not JourneyData.items_have_any_video(_items):
		return null
	var modal: Control = _create_transcode_modal()
	add_child(modal)
	return modal


# Walks _items, dispatching each to its per-type handler and accumulating the
# four output arrays (rounds, forks, shops, storyboards). Returns the
# journey.json data on success or an empty Dictionary on cancel/I-O failure;
# in the latter case the user-facing error modal is already shown and the
# staging folder is already cleaned up.
# Maps the in-memory round_type to its journey.json label.
func _save_all_items(paths: Dictionary, modal: Control) -> Dictionary:
	# Pull the paths-dict entries into the locals the loop body already uses,
	# so the legacy code below doesn't have to be reflowed to dict access.
	var abs_dir: String       = paths["abs_dir"]
	var abs_media_dir: String = paths["abs_media_dir"]
	var copied_images: Dictionary = paths["copied_images"]

	# Fresh content pool for this save — staging is rebuilt from scratch each time,
	# so there's no cross-save state to carry (no refcount/GC needed).
	_pooled_media = {}
	_pooled_fs_stats = {}

	var rounds_json:      Array = []
	var forks_json:       Array = []
	var shops_json:       Array = []
	var storyboards_json: Array = []
	var rorder: int = 0
	# Monotonic authoring position — incremented for EVERY item so each gets a
	# unique, strictly-increasing sort anchor. Items sort by (pos*3 [+1 shop /
	# +2 fork]); since consecutive positions differ by 3 the offsets never
	# collide, so authored order is preserved exactly — including a shop placed
	# *after* a fork (which the old "anchor to the previous round" scheme could
	# not express: shop's +1 sorted before the fork's +2 at the same anchor).
	var pos: int = 0
	var total_main_rounds: int = _items.filter(func(item: Dictionary) -> bool: return item.get("type","round") == "round").size()

	for i in _items.size():
		# Early bail: a previous iteration's _copy_file (funscript / axis /
		# vib / boss image / storyboard image) may have failed and set
		# _save_aborted. The error is surfaced after the loop.
		if _save_aborted:
			break
		var item: Dictionary = _items[i]
		var item_type: String = item.get("type","round")
		pos += 1
		if item_type == "shop":
			shops_json.append({
				"AfterOrder":      pos,
				"Title":           item.get("title",""),
				"Mode":            item.get("mode", "pool"),
				"Count":           item.get("count", 3),
				"Items":           item.get("items", []),
				"PriceMultiplier": item.get("price_multiplier", 1.0),
			})
			continue
		if item_type == "storyboard":
			rorder += 1
			var sb_slug: String = "storyboard_%d" % rorder
			var sb_img_src: String = item.get("image", "")
			var sb_img_fname: String = ""
			if sb_img_src != "":
				var sb_ext: String = sb_img_src.get_extension().to_lower()
				var sb_f: String = _copy_image_deduped(sb_img_src, abs_media_dir, sb_slug + "." + sb_ext, copied_images)
				sb_img_fname = "media/" + sb_f if sb_f != "" else ""
			var sb_lines_json: Array = []
			for sb_li_idx in (item.get("lines", []) as Array).size():
				var sb_li: Dictionary = item["lines"][sb_li_idx]
				var li_img_src: String = sb_li.get("image", "")
				var li_img_fname: String = ""
				if li_img_src != "":
					var li_ext: String = li_img_src.get_extension().to_lower()
					var li_f: String = _copy_image_deduped(li_img_src, abs_media_dir, sb_slug + "_line_%d.%s" % [sb_li_idx, li_ext], copied_images)
					li_img_fname = "media/" + li_f if li_f != "" else ""
				sb_lines_json.append({
					"Speaker": sb_li.get("speaker", ""),
					"Text":    sb_li.get("text",    ""),
					"Image":   li_img_fname,
				})
			storyboards_json.append({
				"Order":        pos,
				"CoinsAwarded": item.get("coins", 0) as int,
				"Item":         item.get("item", ""),
				"Image":        sb_img_fname,
				"Lines":        sb_lines_json,
			})
			continue
		if item_type == "round":
			rorder += 1

			# Human-readable name kept in journey.json's "Name" for display. The
			# short slug (r001, r002, …) is still written as FolderName — a stable
			# logical round id and the legacy folder-scan fallback key — but no
			# per-round folder is created any more: all playback assets are pooled
			# into content/ by hash.
			var round_name: String = (item.get("name","") as String).strip_edges()
			var round_slug: String = _next_round_folder_slug()

			var fs_src: String = item.get("funscript_path","")
			# Funscript goes into the shared content pool (content/m_<fp>.<ext>) — a
			# script reused across rounds is stored and parsed once. Stats are cached
			# per fingerprint so a reused script is not re-read.
			var funscript_rel: String = ""
			var fs_stats: Dictionary = {"count": 0, "length_ms": 0}
			if fs_src != "":
				var fs_pool: Dictionary = _assign_pooled_media(fs_src, fs_src.get_extension())
				funscript_rel = fs_pool["rel"]
				if fs_pool["copy"]:
					var fs_dst: String = abs_dir + "/" + funscript_rel
					_copy_file(fs_src, fs_dst)
					fs_stats = JourneyData.read_funscript_stats(fs_dst)
					_pooled_fs_stats[fs_pool["fingerprint"]] = fs_stats
				else:
					fs_stats = _pooled_fs_stats.get(fs_pool["fingerprint"], fs_stats)

			# Secondary-axis scripts — pooled into content/ (deduped), keyed by axis.
			var axis_scripts_in: Dictionary = item.get("axis_scripts", {})
			var axis_scripts_rel: Dictionary = {}
			for axis: String in axis_scripts_in:
				var ax_src: String = axis_scripts_in[axis]
				var ax_rel: String = _pool_small_file(ax_src, abs_dir, _channel_pool_ext(JourneyData.AXIS_SUFFIXES.get(axis, ""), ax_src))
				if ax_rel != "":
					axis_scripts_rel[axis] = ax_rel

			# Vibrator-channel scripts — pooled into content/, keyed by channel.
			var vib_scripts_in: Dictionary = item.get("vib_scripts", {})
			var vib_scripts_rel: Dictionary = {}
			for ch_key: String in vib_scripts_in:
				var vib_src: String = vib_scripts_in[ch_key]
				var vib_rel: String = _pool_small_file(vib_src, abs_dir, _channel_pool_ext(JourneyData.VIB_SUFFIXES.get(ch_key, ""), vib_src))
				if vib_rel != "":
					vib_scripts_rel[ch_key] = vib_rel

			# Boss-round config — pool the optional intro image into content/.
			var round_type: String = item.get("round_type", "normal")
			var boss_image_rel: String = ""
			if round_type == "boss":
				boss_image_rel = _pool_small_file(item.get("boss_image", ""), abs_dir)

			# Journey-root-relative video path written as VideoPath. Pooled under
			# content/ and shared across rounds that reuse the same source clip; stays
			# "" when the round has no video. The pooled file is transcoded/copied only
			# the first time the source is seen this save (_assign_pooled_media).
			var video_rel: String = ""
			var vid_src: String = item.get("video_path","")
			if vid_src != "":
				var is_transcode: bool = _transcode_plan.has(vid_src)
				var vid_ext: String = "mp4" if is_transcode else vid_src.get_extension()
				var vid_pool: Dictionary = _assign_pooled_media(vid_src, vid_ext)
				video_rel = vid_pool["rel"]
				if vid_pool["copy"]:
					var vid_dst: String = abs_dir + "/" + video_rel
					if is_transcode:
						var info: Dictionary = _transcode_plan[vid_src]
						_update_modal_round(modal, rorder, total_main_rounds, round_name, info["codec"])
						var ok: bool = await _transcode_video(vid_src, vid_dst, info["duration"], modal)
						if not ok:
							# _transcode_cancel distinguishes user cancel from ffmpeg
							# failure (e.g. bad input file). Same return-value path,
							# different remediation. Modal + staging cleanup happen
							# in _do_save when we return {}.
							if _transcode_cancel:
								_show_save_error_single(
									"SAVE CANCELLED",
									CAUSE_CANCELLED,
									"Round %d \"%s\"" % [rorder, round_name],
									"You cancelled the transcode while round \"%s\" was being processed." % round_name,
									"Press Save again to retry. Nothing on disk was changed.")
							else:
								_show_save_error_single(
									"SAVE FAILED",
									CAUSE_TRANSCODE_FAILED,
									"Round %d \"%s\"" % [rorder, round_name],
									"ffmpeg failed to transcode video \"%s\" (codec %s → h264)." % [vid_src.get_file(), info["codec"]],
									"The source video may be corrupt or use an unsupported variant. Try re-encoding it to H.264 .mp4 outside the editor, then re-drag it into this round.")
							return {}
					else:
						_update_modal_label(modal, "Round %d / %d — %s  (copying video)" % [rorder, total_main_rounds, round_name])
						var copy_result: Dictionary = await _copy_file_chunked(
							vid_src, vid_dst,
							func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
						if not copy_result["ok"]:
							_show_copy_failure_modal(copy_result, "Round %d \"%s\"" % [rorder, round_name])
							return {}

			# (Renamed-round cleanup happens implicitly at swap time: the old
			# journey folder is deleted wholesale, taking any stale round
			# subfolders with it. Touching the live folder mid-save would break
			# the staging rollback on a later failure.)

			# Authored gameplay fields come from the shared serializer; the media /
			# slug fields are merged in from what this save loop computed.
			var round_json: Dictionary = JourneyData.round_to_json(item)
			round_json["Name"]          = round_name
			round_json["FolderName"]    = round_slug
			round_json["Order"]         = pos
			round_json["BossImage"]     = boss_image_rel
			round_json["FunscriptPath"] = funscript_rel
			round_json["VideoPath"]     = video_rel
			round_json["AxisScripts"]   = axis_scripts_rel
			round_json["VibScripts"]    = vib_scripts_rel
			round_json["ActionCount"]   = fs_stats["count"]
			round_json["LengthMs"]      = fs_stats["length_ms"]
			rounds_json.append(round_json)
		else:
			# Fork — recursively save the fork and all nested forks.
			var slug_prefix: String = "fork%d" % forks_json.size()
			forks_json.append(await _save_fork(item, abs_dir, abs_media_dir, pos, slug_prefix, copied_images, modal))
			# A failed video copy deep inside a fork path unwinds to here. Use
			# the stashed failure info so the modal shows the actual cause
			# (cancel vs source unreadable vs destination unwritable) and the
			# specific fork-path round that failed.
			if _save_aborted:
				var stashed_result: Dictionary = _save_abort_error.get("result", {"reason": CAUSE_UNKNOWN_COPY_ERROR})
				var stashed_item: String       = _save_abort_error.get("item",   "Fork path video")
				_show_copy_failure_modal(stashed_result, stashed_item)
				return {}

	# Catches _save_aborted set by a non-video _copy_file (funscript / axis /
	# vib / boss / storyboard image) during top-level iteration. Fork-path
	# failures already returned via the inline `if _save_aborted:` block above.
	if _save_aborted:
		var stashed_result: Dictionary = _save_abort_error.get("result", {"reason": CAUSE_UNKNOWN_COPY_ERROR})
		var stashed_item: String       = _save_abort_error.get("item",   "File copy")
		_show_copy_failure_modal(stashed_result, stashed_item)
		return {}

	return {
		"Name":        paths["journey_name"],
		"Author":      _journey_author.strip_edges(),
		"Description": _journey_desc.strip_edges(),
		"Difficulty":  JourneyData.DIFFICULTIES[_journey_difficulty_idx],
		"Tags":        TagRegistry.sanitize(_journey_tags),
		"Rounds":      rounds_json,
		"Forks":       forks_json,
		"Shops":       shops_json,
		"Storyboards": storyboards_json,
	}


# Writes journey.json into the staging folder. Returns false (showing the
# dst_unwritable modal) on I/O failure; the caller is responsible for
# subsequent cleanup of staging in that case.
func _write_journey_json(paths: Dictionary, data: Dictionary) -> bool:
	var json_path: String = paths["staging_journey_dir"] + "/journey.json"
	var f: FileAccess = FileAccess.open(json_path, FileAccess.WRITE)
	if f == null:
		_show_save_error_single(
			"SAVE FAILED",
			CAUSE_DST_UNWRITABLE,
			"journey.json",
			"Could not create %s." % json_path,
			"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location.")
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true


# Atomic-ish swap of the staging folder into its final location. The save
# wrote everything under a hidden sibling folder so the existing journey was
# untouched; now we clear the destination (in-place edit) and the old-name
# folder (journey rename), then rename staging into place. Per-round renames
# vanish implicitly along with the old folder.
func _swap_staging_into_place(paths: Dictionary) -> void:
	var abs_dir: String       = paths["abs_dir"]
	var final_abs_dir: String = paths["final_abs_dir"]
	if DirAccess.dir_exists_absolute(final_abs_dir):
		JourneyData.delete_dir_recursive(final_abs_dir)
	if _original_journey_folder != "":
		var old_abs: String = ProjectSettings.globalize_path(_original_journey_folder)
		if old_abs != final_abs_dir and DirAccess.dir_exists_absolute(old_abs):
			JourneyData.delete_dir_recursive(old_abs)
	DirAccess.rename_absolute(abs_dir, final_abs_dir)


# Player run-saves point at a specific sequence snapshot of this journey. As
# soon as the author re-saves with any structural changes (rounds added /
# removed / reordered / forks reshaped), that snapshot can reference items
# that no longer exist or skip new ones. Rather than try to detect "did the
# structure actually change" — which is brittle and hard to be sure about —
# treat every successful builder save as a write barrier and wipe the run
# save. The author can always edit content (descriptions, coin values, etc.)
# without breaking the player's run, but to be safe we invalidate anyway.
#
# Covers two cases:
#   • In-place edit: same folder name → delete that folder's save.
#   • Rename: old folder name had the save → delete it. New folder name
#     wouldn't have one unless the user authored a duplicate elsewhere; we
#     attempt the delete defensively (no-op when nothing's there).
func _invalidate_existing_run_saves(paths: Dictionary) -> void:
	var final_abs: String = paths["final_abs_dir"]
	var new_folder_name: String = final_abs.get_file()
	# The run-save snapshot can reference rounds that no longer exist after an
	# edit, and recorded scores are no longer comparable — so a rebuild clears
	# both the resume save and the journey's scoreboard.
	if JourneySaveService.has_save(new_folder_name):
		JourneySaveService.delete_save(new_folder_name)
		_invalidated_save_count += 1
	ScoreboardService.clear(new_folder_name)
	if _original_journey_folder != "":
		var old_folder_name: String = (_original_journey_folder as String).get_file()
		if old_folder_name != "" and old_folder_name != new_folder_name:
			if JourneySaveService.has_save(old_folder_name):
				JourneySaveService.delete_save(old_folder_name)
				_invalidated_save_count += 1
			ScoreboardService.clear(old_folder_name)


# Final UX after a clean save: brief success message, then transition back
# to the journey catalogue. The 1.5s delay gives the user a moment to see
# the confirmation before the scene changes.
func _finalize_save_success() -> void:
	var message: String = "Journey saved! Returning to catalogue..."
	if _invalidated_save_count > 0:
		message = "Journey saved! Existing player save reset. Returning to catalogue..."
	_show_status(message, false)
	await get_tree().create_timer(1.5).timeout
	Transition.change_scene("res://scenes/journey_select/JourneySelect.tscn")


# Recursively serializes a fork item to JSON. Calls _save_path for each path.
# `slug_prefix` makes nested-storyboard filenames unique across the journey.
func _save_fork(fork_item: Dictionary, abs_dir: String, abs_media_dir: String, after_order: int, slug_prefix: String, copied_images: Dictionary, modal: Control) -> Dictionary:
	var fork_entry: Dictionary = {
		"AfterOrder":  after_order,
		"Title":       fork_item.get("title",""),
		"Description": fork_item.get("description",""),
		"Resolution":  fork_item.get("resolution", "choice"),
		"CondMetric":  fork_item.get("cond_metric", "score"),
		"DefaultPath": int(fork_item.get("default_path", 0)),
		"Paths":       [],
	}
	for pi in (fork_item.get("paths", []) as Array).size():
		var path_data: Dictionary = fork_item["paths"][pi]
		var path_slug: String = "%s_p%d" % [slug_prefix, pi]
		fork_entry["Paths"].append(await _save_path(path_data, abs_dir, abs_media_dir, path_slug, copied_images, modal))
		if _save_aborted:
			return fork_entry
	return fork_entry


# Recursively serializes a single fork path to JSON, splitting its items into
# Rounds, Shops, Storyboards, and (nested) Forks arrays.
func _save_path(path_data: Dictionary, abs_dir: String, abs_media_dir: String, slug_prefix: String, copied_images: Dictionary, modal: Control) -> Dictionary:
	var img_src: String  = path_data.get("image_path", "")
	var img_fname: String = ""
	if img_src != "":
		# Use slug_prefix ("fork0_p0", "fork0_p1_f0_p0", …) for the filename so
		# two paths sharing a name (e.g. "Yes" / "No" branches across multiple
		# nested forks) can't overwrite each other's card image. The human-
		# readable Name lives in journey.json's Image field via the resolved
		# media/<slug>_cover.<ext> path, but the filename itself is collision-
		# free regardless of what the user calls each path.
		var img_f: String = _copy_image_deduped(img_src, abs_media_dir, slug_prefix + "_cover." + img_src.get_extension().to_lower(), copied_images)
		img_fname = "media/" + img_f if img_f != "" else ""

	var path_entry: Dictionary = {
		"Name":         path_data.get("name", ""),
		"Description":  path_data.get("description", ""),
		"Image":        img_fname,
		"Weight":       int(path_data.get("weight", 1)),
		"Threshold":    int(path_data.get("threshold", 0)),
		"RequiredItem": path_data.get("required_item", ""),
		"Cost":         int(path_data.get("cost", 0)),
		"Rounds":       [],
		"Shops":        [],
		"Storyboards":  [],
		"Forks":        [],
	}

	var pr_order: int = 0
	# Monotonic authoring position, same scheme as the top-level loop — every
	# item bumps it so a shop placed after a (nested) fork sorts correctly.
	var pr_pos: int = 0
	var nested_fork_count: int = 0

	for pi_item: Dictionary in path_data.get("items", []):
		var pi_type: String = pi_item.get("type","round")
		pr_pos += 1
		match pi_type:
			"shop":
				path_entry["Shops"].append({
					"AfterOrder":      pr_pos,
					"Title":           pi_item.get("title",""),
					"Mode":            pi_item.get("mode", "pool"),
					"Count":           pi_item.get("count", 3),
					"Items":           pi_item.get("items", []),
					"PriceMultiplier": pi_item.get("price_multiplier", 1.0),
				})
			"storyboard":
				pr_order += 1
				var psb_slug: String = "%s_storyboard_%d" % [slug_prefix, pr_order]
				var psb_img_src: String = pi_item.get("image", "")
				var psb_img_fname: String = ""
				if psb_img_src != "":
					var psb_ext: String = psb_img_src.get_extension().to_lower()
					var psb_f: String = _copy_image_deduped(psb_img_src, abs_media_dir, psb_slug + "." + psb_ext, copied_images)
					psb_img_fname = "media/" + psb_f if psb_f != "" else ""
				var psb_lines_json: Array = []
				for psb_li_idx in (pi_item.get("lines",[]) as Array).size():
					var psb_li: Dictionary = pi_item["lines"][psb_li_idx]
					var psb_li_img_src: String = psb_li.get("image","")
					var psb_li_img_fname: String = ""
					if psb_li_img_src != "":
						var psb_li_ext: String = psb_li_img_src.get_extension().to_lower()
						var psb_li_f: String = _copy_image_deduped(psb_li_img_src, abs_media_dir, psb_slug + "_line_%d.%s" % [psb_li_idx, psb_li_ext], copied_images)
						psb_li_img_fname = "media/" + psb_li_f if psb_li_f != "" else ""
					psb_lines_json.append({
						"Speaker": psb_li.get("speaker",""),
						"Text":    psb_li.get("text",""),
						"Image":   psb_li_img_fname,
					})
				path_entry["Storyboards"].append({
					"Order":        pr_pos,
					"CoinsAwarded": pi_item.get("coins",0) as int,
					"Item":         pi_item.get("item", ""),
					"Image":        psb_img_fname,
					"Lines":        psb_lines_json,
				})
			"fork":
				# Nested fork — recurse. Sort key uses the monotonic position so it
				# lands exactly where it was authored within this path.
				var nested_slug: String = "%s_f%d" % [slug_prefix, nested_fork_count]
				nested_fork_count += 1
				path_entry["Forks"].append(await _save_fork(pi_item, abs_dir, abs_media_dir, pr_pos, nested_slug, copied_images, modal))
				if _save_aborted:
					return path_entry
			_:
				# Round (inside a fork path). Same scheme as top-level rounds: the
				# slug is written as FolderName (logical id / legacy fallback key),
				# but no per-round folder is created — assets are pooled into content/.
				pr_order += 1
				var pr_name: String = (pi_item.get("name","") as String).strip_edges()
				var pr_slug: String = _next_round_folder_slug()
				var pr_fs: String = pi_item.get("funscript_path","")
				# Funscript into the shared content pool (see the top-level round save).
				var pr_funscript_rel: String = ""
				var pr_fs_stats: Dictionary = {"count": 0, "length_ms": 0}
				if pr_fs != "":
					var pr_fs_pool: Dictionary = _assign_pooled_media(pr_fs, pr_fs.get_extension())
					pr_funscript_rel = pr_fs_pool["rel"]
					if pr_fs_pool["copy"]:
						var pr_fs_dst: String = abs_dir + "/" + pr_funscript_rel
						_copy_file(pr_fs, pr_fs_dst)
						pr_fs_stats = JourneyData.read_funscript_stats(pr_fs_dst)
						_pooled_fs_stats[pr_fs_pool["fingerprint"]] = pr_fs_stats
					else:
						pr_fs_stats = _pooled_fs_stats.get(pr_fs_pool["fingerprint"], pr_fs_stats)
				# Journey-root-relative video path (VideoPath), pooled under content/ and
				# shared across rounds that reuse the same source. Transcoded/copied only
				# the first time the source is seen this save (_assign_pooled_media).
				var pr_video_rel: String = ""
				var pr_vid: String = pi_item.get("video_path","")
				if pr_vid != "":
					var pr_is_transcode: bool = _transcode_plan.has(pr_vid)
					var pr_vid_ext: String = "mp4" if pr_is_transcode else pr_vid.get_extension()
					var pr_vid_pool: Dictionary = _assign_pooled_media(pr_vid, pr_vid_ext)
					pr_video_rel = pr_vid_pool["rel"]
					if pr_vid_pool["copy"]:
						var pr_vid_dst_path: String = abs_dir + "/" + pr_video_rel
						if pr_is_transcode:
							var pr_info: Dictionary = _transcode_plan[pr_vid]
							_update_modal_label(modal, "Fork round — %s  (transcoding %s → h264)" % [pr_name, pr_info["codec"]])
							var pr_transcode_ok: bool = await _transcode_video(pr_vid, pr_vid_dst_path, pr_info["duration"], modal)
							if not pr_transcode_ok:
								_save_aborted = true
								_save_abort_error = {
									"result": {"ok": false, "reason": (CAUSE_CANCELLED if _transcode_cancel else CAUSE_TRANSCODE_FAILED), "detail": pr_vid},
									"item":   "%s → Round \"%s\"" % [slug_prefix, pr_name],
								}
								return path_entry
						else:
							_update_modal_label(modal, "Fork round — %s  (copying video)" % pr_name)
							var pr_copy_result: Dictionary = await _copy_file_chunked(
								pr_vid, pr_vid_dst_path,
								func(done: int, tot: int) -> void: _update_modal_copy(modal, done, tot))
							if not pr_copy_result["ok"]:
								# Cancelled / failed — unwind the recursive save and stash
								# the detailed failure so the top-level handler can show
								# a specific error instead of a generic message.
								_save_aborted = true
								_save_abort_error = {
									"result": pr_copy_result,
									"item":   "%s → Round \"%s\"" % [slug_prefix, pr_name],
								}
								return path_entry
				var pr_axis_in: Dictionary = pi_item.get("axis_scripts", {})
				var pr_axis_rel: Dictionary = {}
				for axis: String in pr_axis_in:
					var ax_src: String = pr_axis_in[axis]
					var ax_rel: String = _pool_small_file(ax_src, abs_dir, _channel_pool_ext(JourneyData.AXIS_SUFFIXES.get(axis, ""), ax_src))
					if ax_rel != "":
						pr_axis_rel[axis] = ax_rel
				var pr_vib_in: Dictionary = pi_item.get("vib_scripts", {})
				var pr_vib_rel: Dictionary = {}
				for ch_key: String in pr_vib_in:
					var vib_src: String = pr_vib_in[ch_key]
					var vib_rel: String = _pool_small_file(vib_src, abs_dir, _channel_pool_ext(JourneyData.VIB_SUFFIXES.get(ch_key, ""), vib_src))
					if vib_rel != "":
						pr_vib_rel[ch_key] = vib_rel
				var pr_round_type: String = pi_item.get("round_type", "normal")
				var pr_boss_image_rel: String = ""
				if pr_round_type == "boss":
					pr_boss_image_rel = _pool_small_file(pi_item.get("boss_image", ""), abs_dir)
				# (Renamed-round cleanup is implicit at swap time — see the
				# top-level round save above. Deleting the live original mid-
				# save would break the staging rollback if a later step fails.)
				# Same shared serializer as the top-level round save; merge in the
				# fork-path media / slug fields.
				var pr_json: Dictionary = JourneyData.round_to_json(pi_item)
				pr_json["Name"]          = pr_name
				pr_json["FolderName"]    = pr_slug
				pr_json["Order"]         = pr_pos
				pr_json["BossImage"]     = pr_boss_image_rel
				pr_json["FunscriptPath"] = pr_funscript_rel
				pr_json["VideoPath"]     = pr_video_rel
				pr_json["AxisScripts"]   = pr_axis_rel
				pr_json["VibScripts"]    = pr_vib_rel
				pr_json["ActionCount"]   = pr_fs_stats["count"]
				pr_json["LengthMs"]      = pr_fs_stats["length_ms"]
				path_entry["Rounds"].append(pr_json)

	return path_entry


# ---------------------------------------------------------------------------
# Transcoding
# ---------------------------------------------------------------------------

# Recursively walks the journey items tree and appends every non-empty
# video_path it finds (top-level rounds + every round in every fork path at
# every depth) into `sources`. Duplicates may appear if the same source video
# is used in multiple rounds; callers dedupe by checking has() on the plan
# dictionary before probing the codec a second time.
func _collect_video_sources(items: Array, sources: Array) -> void:
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				var vid: String = item.get("video_path", "")
				if vid != "":
					sources.append(vid)
			"fork":
				for p: Dictionary in item.get("paths", []):
					_collect_video_sources(p.get("items", []) as Array, sources)


func _ffmpeg_binary(name: String) -> String:
	# Resolution order (custom folder → bundled → PATH) lives in
	# SettingsService.resolve_ffmpeg_binary so the Options "Test" button shares
	# it. The one builder-only concern: in an exported build res://bin/ is inside
	# the PCK and can't be executed, so extract to user://bin/ on first use. Only
	# bother when resolution otherwise falls through to a bare PATH name (i.e. no
	# custom folder and nothing extracted yet).
	var path: String = SettingsService.resolve_ffmpeg_binary(name)
	if path == name and not OS.has_feature("editor"):
		var exe: String = name + ".exe" if OS.get_name() == "Windows" else name
		var user_abs: String = ProjectSettings.globalize_path("user://bin/" + exe)
		if not FileAccess.file_exists(user_abs):
			_extract_ffmpeg_binary("res://bin/" + exe, user_abs)
		path = SettingsService.resolve_ffmpeg_binary(name)
	return path


# Copies a binary from the PCK (res://) to an absolute filesystem path so it
# can be executed. Called once per binary per user data directory.
func _extract_ffmpeg_binary(src_res: String, dst_abs: String) -> void:
	if not FileAccess.file_exists(src_res):
		return
	DirAccess.make_dir_recursive_absolute(dst_abs.get_base_dir())
	var f_in: FileAccess = FileAccess.open(src_res, FileAccess.READ)
	if f_in == null:
		return
	var bytes: PackedByteArray = f_in.get_buffer(f_in.get_length())
	f_in.close()
	var f_out: FileAccess = FileAccess.open(dst_abs, FileAccess.WRITE)
	if f_out == null:
		return
	f_out.store_buffer(bytes)
	f_out.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", dst_abs], [], true)


func _ffmpeg_available() -> bool:
	var out: Array = []
	return OS.execute(_ffmpeg_binary("ffprobe"), ["-version"], out, true, false) == 0




# Probes a video's primary stream for both codec name and pixel format in one
# ffprobe call. Returns {"codec": String, "pix_fmt": String} (lowercased; empty
# strings when the probe fails). Used by the transcode planner.
func _get_video_stream_info(path: String) -> Dictionary:
	var out: Array = []
	var args: PackedStringArray = [
		"-v", "error",
		"-select_streams", "v:0",
		"-show_entries", "stream=codec_name,pix_fmt",
		"-of", "csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(_ffmpeg_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return {"codec": "", "pix_fmt": ""}
	# csv=p=0 yields "codec_name,pix_fmt" on the first non-empty line. Take the
	# first non-empty line (stderr is merged in with read_stderr=true).
	for raw_line: String in (out[0] as String).split("\n"):
		var line: String = raw_line.strip_edges().to_lower()
		if line == "":
			continue
		var parts: PackedStringArray = line.split(",")
		var codec: String   = parts[0].strip_edges() if parts.size() > 0 else ""
		var pix_fmt: String = parts[1].strip_edges() if parts.size() > 1 else ""
		return {"codec": codec, "pix_fmt": pix_fmt}
	return {"codec": "", "pix_fmt": ""}


func _video_duration_seconds(path: String) -> float:
	var out: Array = []
	var args: PackedStringArray = [
		"-v", "error",
		"-show_entries", "format=duration",
		"-of", "csv=p=0",
		ProjectSettings.globalize_path(path),
	]
	if OS.execute(_ffmpeg_binary("ffprobe"), args, out, true, false) != 0 or out.is_empty():
		return 0.0
	return (out[0] as String).strip_edges().to_float()


func _transcode_video(input: String, output: String, duration: float, modal: Control) -> bool:
	_transcode_cancel = false

	var progress_abs: String = ProjectSettings.globalize_path(TRANSCODE_PROGRESS_FILE)
	# Truncate any prior progress file so old data doesn't mislead the parser.
	var pf: FileAccess = FileAccess.open(progress_abs, FileAccess.WRITE)
	if pf:
		pf.close()

	var args: PackedStringArray = [
		"-y",
		"-hide_banner",
		"-loglevel", "error",
		"-i", ProjectSettings.globalize_path(input),
		"-c:v", "libx264",
		"-preset", "fast",
		"-crf", "22",
		"-pix_fmt", "yuv420p",
		"-c:a", "aac",
		"-b:a", "192k",
		"-progress", progress_abs,
		ProjectSettings.globalize_path(output),
	]

	_transcode_pid = OS.create_process(_ffmpeg_binary("ffmpeg"), args)
	if _transcode_pid <= 0:
		return false

	while OS.is_process_running(_transcode_pid):
		if _transcode_cancel:
			OS.kill(_transcode_pid)
			_transcode_pid = -1
			return false
		_poll_progress(progress_abs, duration, modal)
		await get_tree().create_timer(0.4).timeout

	# Final poll to flush "progress=end".
	_poll_progress(progress_abs, duration, modal)
	_transcode_pid = -1
	return FileAccess.file_exists(output)


func _poll_progress(progress_path: String, duration: float, modal: Control) -> void:
	if modal == null:
		return
	var f: FileAccess = FileAccess.open(progress_path, FileAccess.READ)
	if f == null:
		return
	var text: String = f.get_as_text()
	f.close()
	var out_time_us: int = 0
	var speed: String = ""
	for raw_line: String in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("out_time_us="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("out_time_ms="):
			out_time_us = line.substr(12).to_int()
		elif line.begins_with("speed="):
			speed = line.substr(6)
	var current_seconds: float = out_time_us / 1_000_000.0
	var progress: float = 0.0
	if duration > 0.0:
		progress = clampf(current_seconds / duration, 0.0, 1.0)
	_update_modal_progress(modal, progress, current_seconds, duration, speed)


# ---------------------------------------------------------------------------
# Transcode modal UI
# ---------------------------------------------------------------------------

func _create_transcode_modal() -> Control:
	var parts: Dictionary    = UITheme.build_centered_modal("SAVING JOURNEY", UITheme.PURPLE_BRIGHT, Vector2i(520, 240))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]
	modal.name           = "TranscodeModal"
	parts["title"].name  = "Title"
	# Override the default 12-separation with the transcode modal's looser 14
	# spacing — the progress bar reads more cleanly with extra breathing room.
	vbox.add_theme_constant_override("separation", 14)

	var round_lbl: Label = Label.new()
	round_lbl.name = "RoundLabel"
	round_lbl.text = ""
	UITheme.style_label(round_lbl, UITheme.WHITE_SOFT, 13, false)
	round_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(round_lbl)

	var bar: ProgressBar = ProgressBar.new()
	bar.name = "Bar"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	var bar_bg: StyleBoxFlat = StyleBoxFlat.new()
	bar_bg.bg_color = UITheme.PURPLE_DARK
	bar.add_theme_stylebox_override("background", bar_bg)
	var bar_fill: StyleBoxFlat = StyleBoxFlat.new()
	bar_fill.bg_color = UITheme.PURPLE_BRIGHT
	bar.add_theme_stylebox_override("fill", bar_fill)
	vbox.add_child(bar)

	var status_lbl: Label = Label.new()
	status_lbl.name = "Status"
	status_lbl.text = "Starting..."
	UITheme.style_label(status_lbl, UITheme.PURPLE_MID, 12, false)
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status_lbl)

	var cancel_btn: Button = Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(cancel_btn, UITheme.MAGENTA)
	cancel_btn.pressed.connect(func() -> void: _transcode_cancel = true)
	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_child(cancel_btn)
	vbox.add_child(btn_row)

	return modal


func _update_modal_round(modal: Control, round_num: int, total: int, round_name: String, codec: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.get_node("PanelContainer/VBoxContainer/RoundLabel") as Label
	if lbl == null:
		# Fallback: walk children since we didn't name the intermediate panel/vbox.
		lbl = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = "Round %d / %d — %s  (%s → h264)" % [round_num, total, round_name, codec.to_upper()]


func _update_modal_progress(modal: Control, progress: float, current_s: float, total_s: float, speed: String) -> void:
	if modal == null:
		return
	var bar: ProgressBar = modal.find_child("Bar", true, false) as ProgressBar
	if bar:
		bar.value = progress
	var status: Label = modal.find_child("Status", true, false) as Label
	if status:
		var pct: int = int(round(progress * 100.0))
		var cur: String = _format_time(current_s)
		var tot: String = _format_time(total_s) if total_s > 0.0 else "?"
		var spd: String = ("  •  " + speed) if speed != "" else ""
		status.text = "%s / %s  •  %d%%%s" % [cur, tot, pct, spd]


func _format_time(seconds: float) -> String:
	var s: int = int(seconds)
	return "%02d:%02d" % [s / 60, s % 60]


# Sets the modal's secondary label to a plain message (no codec suffix).
func _update_modal_label(modal: Control, text: String) -> void:
	if modal == null:
		return
	var lbl: Label = modal.find_child("RoundLabel", true, false) as Label
	if lbl:
		lbl.text = text


# Updates the modal bar + status line for a byte-based file copy.
func _update_modal_copy(modal: Control, copied: int, total: int) -> void:
	if modal == null:
		return
	var frac: float = (float(copied) / float(total)) if total > 0 else 0.0
	var bar: ProgressBar = modal.find_child("Bar", true, false) as ProgressBar
	if bar:
		bar.value = frac
	var status: Label = modal.find_child("Status", true, false) as Label
	if status:
		status.text = "Copying… %d%%  (%s / %s)" % [
			int(round(frac * 100.0)), _format_size(copied), _format_size(total)]


func _format_size(bytes: int) -> String:
	var mb: float = bytes / (1024.0 * 1024.0)
	if mb >= 1024.0:
		return "%.1f GB" % (mb / 1024.0)
	return "%.0f MB" % mb


# Returns the destination filename (relative to abs_dir) for an image. If the
# same source path was already copied during this save, reuses the existing
# destination file rather than copying again. `copied` maps src_path → fname.
func _copy_image_deduped(src: String, abs_dir: String, candidate_fname: String, copied: Dictionary) -> String:
	if src == "":
		return ""
	if copied.has(src):
		return copied[src]
	_copy_file(src, abs_dir + "/" + candidate_fname)
	copied[src] = candidate_fname
	return candidate_fname


# Assigns a source file to the shared content pool for this save. Returns
# {rel, copy, fingerprint}: `rel` is the journey-root-relative pooled path
# (content/m_<fp>.<ext>), `copy` is true only the FIRST time this source is seen —
# the caller does the actual transcode/copy then and skips it on repeats. `ext`
# is the destination extension (mp4 for transcoded video, else the source ext).
# Mirrors JourneyData.plan_media_pool's first-sighting logic with a live map.
func _assign_pooled_media(src: String, ext: String) -> Dictionary:
	var fp: String = JourneyData.media_fingerprint(src)
	var rel: String = JourneyData.pooled_media_rel(fp, ext)
	var is_new: bool = not _pooled_media.has(fp)
	if is_new:
		_pooled_media[fp] = rel
	return {"rel": _pooled_media[fp], "copy": is_new, "fingerprint": fp}


# Pools a small file (funscript / axis / vib / boss image) into content/ via the
# synchronous _copy_file, copying only on the first sighting of its source so
# reused assets are stored once. Returns the journey-root-relative pooled path
# ("" for an empty source). `ext_override` sets the pooled file's extension —
# used to keep the channel suffix on axis/vib scripts (e.g. "pitch.funscript");
# falls back to the source's extension when empty. A copy failure sets
# _save_aborted (surfaced at the next checkpoint), like the other _copy_file sites.
func _pool_small_file(src: String, abs_dir: String, ext_override: String = "") -> String:
	if src == "":
		return ""
	var ext: String = ext_override if ext_override != "" else src.get_extension()
	var pool: Dictionary = _assign_pooled_media(src, ext)
	if pool["copy"]:
		_copy_file(src, abs_dir + "/" + pool["rel"])
	return pool["rel"]


# Builds the pooled extension for a channel script so it keeps the standard
# funscript suffix (content/m_<fp>.<suffix>.<ext>, e.g. ...pitch.funscript).
# `suffix` is the channel's funscript suffix (surge/sway/…/vibe1); falls back to
# the bare source extension when the channel id isn't recognised.
func _channel_pool_ext(suffix: String, src: String) -> String:
	var src_ext: String = src.get_extension()
	if suffix == "" or src_ext == "":
		return src_ext
	return suffix + "." + src_ext


# Synchronous whole-file copy. Use only for small files (funscripts, images) —
# for video use _copy_file_chunked so the main thread doesn't freeze.
#
# On failure (source unreadable or destination unwritable), sets _save_aborted
# and _save_abort_error so the next `if _save_aborted:` checkpoint in the save
# loop can surface a specific error modal. This matches the existing fork-path
# unwind pattern, so callers don't need to inspect the result individually.
func _copy_file(src: String, dst: String) -> void:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_SRC_UNREADABLE, "detail": src},
			"item":   "File copy",
		}
		return
	var bytes: PackedByteArray = src_file.get_buffer(src_file.get_length())
	src_file.close()
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		_save_aborted = true
		_save_abort_error = {
			"result": {"ok": false, "reason": CAUSE_DST_UNWRITABLE, "detail": dst},
			"item":   "File copy",
		}
		return
	dst_file.store_buffer(bytes)
	dst_file.close()


# Returns the next short folder slug for a round and bumps the counter.
# Format: "r" + zero-padded 3-digit index ("r001", "r002", …). Three digits
# comfortably fits any journey (max real-world rounds is well under 1000;
# the format gracefully handles overflow by growing to 4+ digits).
func _next_round_folder_slug() -> String:
	_round_folder_counter += 1
	return "r%03d" % _round_folder_counter


# Streaming file copy for large files (video). Reads/writes in COPY_CHUNK_SIZE
# blocks and yields one frame whenever COPY_FRAME_BUDGET_MS of work has piled
# up — so the window stays responsive and the modal can repaint, without paying
# a full frame-wait per chunk. `progress` (optional) is called as
# progress.call(copied_bytes, total_bytes). Honours the modal's cancel button
# via _transcode_cancel.
#
# Returns a Dictionary describing the outcome:
#   {"ok": true,  "reason": "ok"}
#   {"ok": false, "reason": "src_unreadable", "detail": <path>}
#   {"ok": false, "reason": "dst_unwritable", "detail": <path>}
#   {"ok": false, "reason": "cancelled",      "detail": ""}
# Callers use `reason` to pick a specific error message + remediation hint.
func _copy_file_chunked(src: String, dst: String, progress: Callable = Callable()) -> Dictionary:
	var src_file: FileAccess = FileAccess.open(src, FileAccess.READ)
	if src_file == null:
		printerr("JourneyBuilder: cannot read: " + src)
		return {"ok": false, "reason": CAUSE_SRC_UNREADABLE, "detail": src}
	var dst_file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if dst_file == null:
		printerr("JourneyBuilder: cannot write: " + dst)
		src_file.close()
		return {"ok": false, "reason": CAUSE_DST_UNWRITABLE, "detail": dst}

	var total: int = src_file.get_length()
	var copied: int = 0
	var budget_start: int = Time.get_ticks_msec()

	while copied < total:
		if _transcode_cancel:
			src_file.close()
			dst_file.close()
			return {"ok": false, "reason": CAUSE_CANCELLED, "detail": ""}
		var chunk: PackedByteArray = src_file.get_buffer(COPY_CHUNK_SIZE)
		if chunk.is_empty():
			break
		dst_file.store_buffer(chunk)
		copied += chunk.size()
		if progress.is_valid():
			progress.call(copied, total)
		if Time.get_ticks_msec() - budget_start >= COPY_FRAME_BUDGET_MS:
			await get_tree().process_frame
			budget_start = Time.get_ticks_msec()

	src_file.close()
	dst_file.close()
	return {"ok": true, "reason": "ok"}


# Removes files inside `dir_path` whose extension is in `extensions` but whose
# filename is NOT `keep_filename`. Called after writing a replacement video
# (for funscripts use _delete_stale_l0_files / _delete_stale_axis_files instead).
func _delete_stale_files(dir_path: String, keep_filename: String, extensions: Array) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() \
				and fname.get_extension().to_lower() in extensions \
				and fname != keep_filename:
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Like _delete_stale_files but specifically for the L0 (main stroke) funscript.
# Skips files that look like secondary-axis scripts (`*_L1.*`, `*_R0.*`, etc.) or
# vibrator-channel scripts (`*_vib1.*`, `*_vib2.*`) so they are never accidentally
# deleted when the L0 name changes.
func _delete_stale_l0_files(dir_path: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS:
			var stem: String = fname.get_basename()
			var is_secondary: bool = false
			for ax: String in JourneyData.EXTRA_AXES:
				if stem.ends_with("_" + ax):
					is_secondary = true
					break
			if not is_secondary:
				for vk: String in ["_vib1", "_vib2", "_vibe1", "_vibe2"]:
					if stem.ends_with(vk):
						is_secondary = true
						break
			if not is_secondary:
				to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Removes stale funscript files that belong to a specific secondary axis
# (i.e. `*_AXIS.funscript`) but are not the newly written `keep_filename`.
func _delete_stale_axis_files(dir_path: String, axis: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS \
				and fname.get_basename().ends_with("_" + axis):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# Converts the internal boss-modifier model ({kind, factor, min, max}) into the
# PascalCase form written to journey.json, keeping only the keys each kind uses.
# Removes stale vibrator-channel funscript files for a specific channel key
# (i.e. `*_vib1.funscript`) but are not the newly written `keep_filename`.
func _delete_stale_vib_files(dir_path: String, ch_key: String, keep_filename: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var to_delete: PackedStringArray = []
	var fname: String = da.get_next()
	while fname != "":
		if not da.current_is_dir() and fname != keep_filename \
				and fname.get_extension().to_lower() in JourneyData.FUNSCRIPT_EXTENSIONS \
				and fname.get_basename().ends_with("_" + ch_key):
			to_delete.append(dir_path + "/" + fname)
		fname = da.get_next()
	da.list_dir_end()
	for p: String in to_delete:
		DirAccess.remove_absolute(p)


# ---------------------------------------------------------------------------
# Save error reporting
# ---------------------------------------------------------------------------
#
# Every save problem flows through a "SaveError" Dictionary with this shape:
#   {
#     "cause":  String   – short machine code, see SAVE_ERROR_CAUSES below
#     "item":   String   – user-facing label, e.g. 'Round 3 "Boss Fight"'
#                          or 'Fork 1 → Path "Adventure" → Round 2'
#     "detail": String   – the specific failure (path, error, etc.)
#     "hint":   String   – one-line remediation suggestion
#   }
#
# Pre-save validation collects ALL problems before any file is touched so the
# user sees them in one pass. Mid-save failures (cancel, copy error, transcode
# error) build one SaveError and route through the same modal.

# Returns true if the given source-file path exists on disk. Used by validation
# instead of FileAccess.file_exists so user:// paths and absolute paths both work.
func _save_source_exists(path: String) -> bool:
	if path == "":
		return false
	return FileAccess.file_exists(ProjectSettings.globalize_path(path))


# Returns a short, node-local problem summary for an item ("" when it's fine).
# Mirrors the save-time validation rules but only for THIS node (children get
# their own badges), so the graph can flag issues live instead of at save. Used
# as GraphView.validity_fn.
func _item_issue_summary(item: Dictionary) -> String:
	match item.get("type", "round"):
		"round":
			if (item.get("name", "") as String).strip_edges() == "":
				return "This round has no name."
			var fs: String = item.get("funscript_path", "")
			if fs == "":
				return "No funscript selected — required for a playable round."
			if not _save_source_exists(fs):
				return "Funscript file is missing (moved or deleted)."
			var vid: String = item.get("video_path", "")
			if vid != "" and not _save_source_exists(vid):
				return "Video file is missing (moved or deleted)."
			for axis: String in item.get("axis_scripts", {}):
				if not _save_source_exists(item["axis_scripts"][axis]):
					return "An axis funscript (%s) is missing." % axis
			for ch: String in item.get("vib_scripts", {}):
				if not _save_source_exists(item["vib_scripts"][ch]):
					return "A vibrator funscript (%s) is missing." % ch
			var boss_img: String = item.get("boss_image", "")
			if boss_img != "" and not _save_source_exists(boss_img):
				return "Boss intro image is missing."
			return ""
		"storyboard":
			if (item.get("lines", []) as Array).is_empty():
				return "Storyboard has no dialogue lines."
			var def_img: String = item.get("image", "")
			if def_img != "" and not _save_source_exists(def_img):
				return "Default image is missing."
			for line: Dictionary in item.get("lines", []):
				var li_img: String = line.get("image", "")
				if li_img != "" and not _save_source_exists(li_img):
					return "A line's speaker image is missing."
			return ""
		"fork":
			var paths: Array = item.get("paths", [])
			if paths.size() < 2:
				return "Fork needs at least 2 paths."
			for p: Dictionary in paths:
				if (p.get("name", "") as String).strip_edges() == "":
					return "A fork path has no name."
				if (p.get("items", []) as Array).is_empty():
					return "A fork path is empty."
				var pimg: String = p.get("image_path", "")
				if pimg != "" and not _save_source_exists(pimg):
					return "A fork path's card image is missing."
			return ""
	return ""


# Recursively walks an items[] tree (top-level + every fork path at every
# nesting depth) and returns true if any round exists anywhere. Used by the
# journey-level "needs at least one round somewhere" check so authors can
# gate their gameplay behind a fork (e.g. "Cutscene → Choose difficulty fork
# → each path has its own boss") and still pass validation.
func _has_any_round_in_tree(items: Array) -> bool:
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		if item_type == "round":
			return true
		if item_type == "fork":
			for p: Dictionary in item.get("paths", []):
				if _has_any_round_in_tree(p.get("items", []) as Array):
					return true
	return false


# Walks the entire journey tree (top-level + every fork path recursively) and
# returns an Array of SaveError dicts for all problems found. An empty array
# means the journey is safe to save.
func _collect_presave_issues() -> Array:
	var issues: Array = []

	# Journey-level checks.
	var jn: String = _journey_name.strip_edges()
	if jn == "":
		issues.append({
			"cause":  CAUSE_BAD_NAME,
			"item":   "Journey",
			"detail": "Journey name is required.",
			"hint":   "Enter a name in the Journey Info panel (right-side, no node selected).",
		})
	else:
		# Rename-collision guard. If the sanitized name maps to a folder that
		# already exists AND it's not the journey we're editing, the swap at
		# the end of save would wipe that other journey's data. Refuse here.
		var sanitized_jn: String      = JourneyData.sanitize_folder_name(jn)
		var target_journey_dir: String = SettingsService.get_journeys_dir() + "/" + sanitized_jn
		var target_abs: String        = ProjectSettings.globalize_path(target_journey_dir)
		var original_abs: String      = ""
		if _original_journey_folder != "":
			original_abs = ProjectSettings.globalize_path(_original_journey_folder)
		if target_abs != original_abs and DirAccess.dir_exists_absolute(target_abs):
			issues.append({
				"cause":  CAUSE_NAME_COLLISION,
				"item":   "Journey",
				"detail": "A journey already exists at: %s" % target_abs,
				"hint":   "Saving with this name would replace that other journey. Pick a different name, or delete the existing journey from the catalogue first.",
			})
	if _cover_path != "" and not _save_source_exists(_cover_path):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   "Journey cover image",
			"detail": "Cover image no longer exists at: %s" % _cover_path,
			"hint":   "Re-drag the cover image into the Journey Info panel, or remove it.",
		})

	# "Journey" is loosely defined as "has gameplay somewhere." A round inside
	# a fork path still counts — e.g. a cutscene-intro storyboard followed by
	# a "choose your difficulty" fork whose paths all contain rounds. Only
	# truly round-less journeys (slideshows of storyboards / shops) are blocked.
	if not _has_any_round_in_tree(_items):
		issues.append({
			"cause":  CAUSE_NO_ROUNDS,
			"item":   "Journey",
			"detail": "A journey needs at least one round somewhere — top-level or inside any fork path.",
			"hint":   "Add a round from the side panel, or add a round inside one of your fork paths.",
		})

	_save_collect_items_issues(_items, "Top level", issues)
	return issues


# Recursively scans an items[] array (used at both top level and inside fork
# paths). `context` is a human-readable trail like
# 'Fork 1 → Path "Adventure"' so issue messages can pinpoint the location.
func _save_collect_items_issues(items: Array, context: String, issues: Array) -> void:
	var round_num: int = 0
	var sb_num:    int = 0
	var fork_num:  int = 0
	for item: Dictionary in items:
		var item_type: String = item.get("type", "round")
		match item_type:
			"round":
				round_num += 1
				_save_check_round(item, "%s, Round %d" % [context, round_num], issues)
			"storyboard":
				sb_num += 1
				_save_check_storyboard(item, "%s, Storyboard %d" % [context, sb_num], issues)
			"fork":
				fork_num += 1
				_save_check_fork(item, "%s, Fork %d" % [context, fork_num], issues)
			"shop":
				# Shops write no filesystem paths and have no source files.
				pass


func _save_check_round(round_data: Dictionary, ctx: String, issues: Array) -> void:
	var name: String = (round_data.get("name", "") as String).strip_edges()
	var label: String = "%s \"%s\"" % [ctx, name] if name != "" else ctx

	# Names are display-only now (see short-folder slug scheme). Any character
	# is fine — only empty names need to be flagged, since the name is the
	# user's identifier for the round in journey.json and the editor.
	if name == "":
		issues.append({
			"cause":  CAUSE_BAD_NAME,
			"item":   ctx,
			"detail": "Round name is empty.",
			"hint":   "Give the round a name in the side-panel editor.",
		})

	# Required: funscript.
	var fs: String = round_data.get("funscript_path", "")
	if fs == "":
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "No funscript file selected.",
			"hint":   "Drag a .funscript or .json file into the Funscript field for this round.",
		})
	elif not _save_source_exists(fs):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Funscript file no longer exists at: %s" % fs,
			"hint":   "The source file may have been moved or deleted. Re-drag it into the editor.",
		})

	# Optional: video.
	var vid: String = round_data.get("video_path", "")
	if vid != "" and not _save_source_exists(vid):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Video file no longer exists at: %s" % vid,
			"hint":   "The source file may have been moved or deleted. Re-drag it into the editor or remove the video.",
		})

	# Secondary axis scripts.
	var axis_scripts: Dictionary = round_data.get("axis_scripts", {})
	for axis: String in axis_scripts:
		var p: String = axis_scripts[axis]
		if p != "" and not _save_source_exists(p):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   label,
				"detail": "%s axis funscript no longer exists at: %s" % [axis, p],
				"hint":   "Re-drag the %s funscript in the Extra Axes section." % axis,
			})

	# Vibrator-channel scripts.
	var vib_scripts: Dictionary = round_data.get("vib_scripts", {})
	for ch_key: String in vib_scripts:
		var p: String = vib_scripts[ch_key]
		if p != "" and not _save_source_exists(p):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   label,
				"detail": "%s vibrator funscript no longer exists at: %s" % [ch_key, p],
				"hint":   "Re-drag the %s funscript in the Vibrator Scripts section." % ch_key,
			})

	# Boss intro image.
	var boss_image: String = round_data.get("boss_image", "")
	if boss_image != "" and not _save_source_exists(boss_image):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   label,
			"detail": "Boss intro image no longer exists at: %s" % boss_image,
			"hint":   "Re-drag the boss image in the Boss Round section, or disable boss mode.",
		})

	# (Path-length check used to live here. Removed once round folder names
	# became fixed-length slugs — a round folder is always exactly 4 chars
	# (`rNNN`) and the longest filename inside is `axis_<XY>.funscript` (~22
	# chars), so the only path-length lever left is the journey name itself,
	# which would need to be hundreds of characters to come close to MAX_PATH.)


func _save_check_storyboard(sb_data: Dictionary, ctx: String, issues: Array) -> void:
	var default_img: String = sb_data.get("image", "")
	if default_img != "" and not _save_source_exists(default_img):
		issues.append({
			"cause":  CAUSE_MISSING_SOURCE,
			"item":   ctx,
			"detail": "Default image no longer exists at: %s" % default_img,
			"hint":   "Re-drag the default image into the storyboard, or remove it.",
		})
	var lines: Array = sb_data.get("lines", [])
	for li in lines.size():
		var line: Dictionary = lines[li]
		var img: String = line.get("image", "")
		if img != "" and not _save_source_exists(img):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   "%s, Line %d" % [ctx, li + 1],
				"detail": "Speaker image no longer exists at: %s" % img,
				"hint":   "Re-drag the speaker image into this line, or remove it.",
			})


func _save_check_fork(fork_data: Dictionary, ctx: String, issues: Array) -> void:
	var paths: Array = fork_data.get("paths", [])
	if paths.size() < 2:
		issues.append({
			"cause":  CAUSE_FORK_UNDERFILLED,
			"item":   ctx,
			"detail": "Fork has only %d path(s); needs at least 2." % paths.size(),
			"hint":   "Add a second path in the fork editor.",
		})

	# A Sacrifice fork must offer at least one free path (no coin cost and no
	# required item), so the player always has an option even when broke / out of
	# items.
	if fork_data.get("resolution", "choice") == "sacrifice" and not paths.is_empty():
		var has_free: bool = false
		for p: Dictionary in paths:
			if int(p.get("cost", 0)) <= 0 and str(p.get("required_item", "")).strip_edges() == "":
				has_free = true
				break
		if not has_free:
			issues.append({
				"cause":  CAUSE_FORK_UNDERFILLED,
				"item":   ctx,
				"detail": "This Sacrifice fork has no free path — the player could be stuck with no affordable option.",
				"hint":   "Make at least one path free: Coin Cost 0 and Required Item None.",
			})
	for pi in paths.size():
		var p: Dictionary = paths[pi]
		var pname: String = (p.get("name", "") as String).strip_edges()
		var path_ctx: String = "%s → Path %d \"%s\"" % [ctx, pi + 1, pname] if pname != "" \
			else "%s → Path %d" % [ctx, pi + 1]

		# Names are display-only now (see fork-path slug scheme for the card
		# image filename and round-folder slugs for rounds inside the path).
		# Any character is fine — only empty names need to be flagged, since
		# the name is what the player sees on the fork choice screen.
		if pname == "":
			issues.append({
				"cause":  CAUSE_BAD_NAME,
				"item":   path_ctx,
				"detail": "Path name is empty.",
				"hint":   "Give the path a name (e.g. \"Adventure\" or \"Reward\", or even \"What's next?\").",
			})

		var img: String = p.get("image_path", "")
		if img != "" and not _save_source_exists(img):
			issues.append({
				"cause":  CAUSE_MISSING_SOURCE,
				"item":   path_ctx,
				"detail": "Card image no longer exists at: %s" % img,
				"hint":   "Re-drag the card image for this path, or remove it.",
			})

		# A fork path must contain at least one item of any kind — round,
		# storyboard, shop, or nested fork. The "narrative-only" path
		# (storyboards as the consequence of a choice) and "skip-this-section"
		# patterns are explicit author intents we want to support, so we
		# don't require a round here. A completely empty path is still
		# rejected because it would be a button-that-does-nothing UX trap.
		var sub_items: Array = p.get("items", [])
		if sub_items.is_empty():
			issues.append({
				"cause":  CAUSE_NO_ROUNDS,
				"item":   path_ctx,
				"detail": "This fork path is empty.",
				"hint":   "Add at least one round, storyboard, shop, or nested fork to the path.",
			})
		_save_collect_items_issues(sub_items, path_ctx, issues)




# ---------------------------------------------------------------------------
# Error modal
# ---------------------------------------------------------------------------

# Shows a centred modal listing one or more SaveError dicts. Closeable via the
# OK button or backdrop. "Copy details" copies a plain-text version of every
# issue to the clipboard so users can paste it into a bug report.
func _show_save_error_modal(title: String, headline: String, errors: Array) -> void:
	if errors.is_empty():
		return

	var parts: Dictionary    = UITheme.build_centered_modal(title, UITheme.ERROR_SOFT, Vector2i(720, 520))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]
	modal.name = "SaveErrorModal"

	var headline_lbl: Label = Label.new()
	headline_lbl.text = headline
	UITheme.style_label(headline_lbl, UITheme.WHITE_SOFT, 13, false)
	headline_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	headline_lbl.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(headline_lbl)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)

	for err: Dictionary in errors:
		list.add_child(_make_save_error_row(err))

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var copy_btn: Button = Button.new()
	copy_btn.text = "⎘  COPY DETAILS"
	copy_btn.custom_minimum_size = Vector2(160, 0)
	UITheme.style_button(copy_btn, UITheme.PURPLE_MID)
	copy_btn.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_save_errors_to_text(title, errors))
		copy_btn.text = "✓  COPIED"
	)
	btn_row.add_child(copy_btn)

	var ok_btn: Button = Button.new()
	ok_btn.text = "OK"
	ok_btn.custom_minimum_size = Vector2(120, 0)
	UITheme.style_button(ok_btn, UITheme.PURPLE_BRIGHT)
	ok_btn.pressed.connect(func() -> void: modal.queue_free())
	btn_row.add_child(ok_btn)

	add_child(modal)


# Builds one row for a single SaveError dict. The item label is the most
# prominent line; cause+detail explain what; hint suggests a fix.
func _make_save_error_row(err: Dictionary) -> Control:
	var row: PanelContainer = PanelContainer.new()
	var rs: StyleBoxFlat = StyleBoxFlat.new()
	rs.bg_color              = UITheme.CARD_BG
	rs.border_color          = Color(UITheme.ERROR_SOFT.r, UITheme.ERROR_SOFT.g, UITheme.ERROR_SOFT.b, 0.45)
	rs.border_width_left     = 1; rs.border_width_right  = 1
	rs.border_width_top      = 1; rs.border_width_bottom = 1
	rs.content_margin_left   = 10; rs.content_margin_right  = 10
	rs.content_margin_top    = 8;  rs.content_margin_bottom = 8
	row.add_theme_stylebox_override("panel", rs)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	row.add_child(col)

	var item_lbl: Label = Label.new()
	item_lbl.text = (err.get("item", "") as String).to_upper()
	UITheme.style_label(item_lbl, UITheme.PURPLE_BRIGHT, 12, true)
	col.add_child(item_lbl)

	var detail_lbl: Label = Label.new()
	detail_lbl.text = err.get("detail", "")
	detail_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(detail_lbl, UITheme.WHITE_SOFT, 12, false)
	col.add_child(detail_lbl)

	var hint_text: String = err.get("hint", "")
	if hint_text != "":
		var hint_lbl: Label = Label.new()
		hint_lbl.text = "→  " + hint_text
		hint_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(hint_lbl, UITheme.SEPARATOR, 11, false)
		col.add_child(hint_lbl)

	return row


# Serialises a list of SaveErrors into a plain-text block users can paste
# into a bug report. Format mirrors what the modal displays.
func _save_errors_to_text(title: String, errors: Array) -> String:
	var out: String = title + "\n" + "=".repeat(title.length()) + "\n\n"
	for i in errors.size():
		var err: Dictionary = errors[i]
		out += "%d. %s\n" % [i + 1, err.get("item", "")]
		out += "   Cause:  %s — %s\n" % [err.get("cause", ""), err.get("detail", "")]
		var hint: String = err.get("hint", "")
		if hint != "":
			out += "   Hint:   %s\n" % hint
		out += "\n"
	return out


# Builds a one-off SaveError list and shows the modal. Used by mid-save
# failures that produce a single specific error (copy failed, transcode
# failed, journey.json write failed, etc.).
func _show_save_error_single(title: String, cause: String, item: String, detail: String, hint: String) -> void:
	_show_save_error_modal(title, "Save failed.", [{
		"cause":  cause,
		"item":   item,
		"detail": detail,
		"hint":   hint,
	}])


# Maps a _copy_file_chunked result dict to the right save-error modal call.
# `item` is the user-facing label (e.g. 'Round 4 "Boss Fight"' or
# 'Fork → Path A → Round 2 "Reward"'). Files the modal and is otherwise silent
# on success.
func _show_copy_failure_modal(copy_result: Dictionary, item: String) -> void:
	match copy_result.get("reason", ""):
		CAUSE_CANCELLED:
			_show_save_error_single(
				"SAVE CANCELLED",
				CAUSE_CANCELLED,
				item,
				"You cancelled the copy while %s was being processed." % item,
				"Press Save again to retry. Nothing on disk was changed.")
		CAUSE_SRC_UNREADABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_SRC_UNREADABLE,
				item,
				"Source file became unreadable: %s" % copy_result.get("detail", "?"),
				"The file may have been moved, deleted, or its drive disconnected since you opened the editor. Re-drag it into this round and try again.")
		CAUSE_DST_UNWRITABLE:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_DST_UNWRITABLE,
				item,
				"Could not create the destination file: %s" % copy_result.get("detail", "?"),
				"Check that the journeys folder drive isn't full or write-protected, and that no antivirus is blocking the editor. You can change the journeys folder in Options → Storage Location.")
		_:
			_show_save_error_single(
				"SAVE FAILED",
				CAUSE_UNKNOWN_COPY_ERROR,
				item,
				"An unexpected copy failure occurred while processing %s." % item,
				"Try saving again. If the problem persists, check the Godot debug output for details.")


# ---------------------------------------------------------------------------
# Stale staging folder recovery
# ---------------------------------------------------------------------------
#
# Save uses a `.~save_<journey_name>` sibling folder for staging (so a mid-save
# failure can be rolled back atomically — see `_on_save_pressed`). On a clean
# save the staging folder is renamed into place; on a clean cancel/failure it
# is deleted. But an unclean exit (app crash, power loss, force-kill) leaves
# the staging folder behind. The catalogue scanner hides it (dot prefix) so
# the user has no in-app way to discover or remove it.
#
# On builder startup we scan for these and offer to clean them up. We show
# the dialog only when there's something to act on — first-time users with
# no leftovers see nothing.

# Returns absolute paths to every `.~save_*` folder currently sitting in the
# journeys root. Empty if nothing to recover.
func _find_stale_staging_folders() -> Array:
	var result: Array = []
	var journeys_abs: String = ProjectSettings.globalize_path(SettingsService.get_journeys_dir())
	var dir: DirAccess = DirAccess.open(journeys_abs)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with(".~save_"):
			result.append(journeys_abs + "/" + entry)
		entry = dir.get_next()
	dir.list_dir_end()
	return result


# Called once per builder launch via call_deferred. Shows a non-blocking
# dialog when any staging folders are found, with options to delete them or
# leave them in place.
func _check_for_stale_staging_folders() -> void:
	var stale: Array = _find_stale_staging_folders()
	if stale.is_empty():
		return
	_show_stale_staging_dialog(stale)


# Built dynamically (rather than as a static .tscn) since this is a once-in-
# a-blue-moon flow and doesn't justify a scene file. Mirrors the SaveError
# modal style so it feels native.
func _show_stale_staging_dialog(stale: Array) -> void:
	var parts: Dictionary    = UITheme.build_centered_modal("UNFINISHED SAVES FOUND", UITheme.AMBER, Vector2i(680, 440))
	var modal: Control       = parts["modal"]
	var vbox:  VBoxContainer = parts["vbox"]

	var headline: Label = Label.new()
	headline.text = ("Found %d leftover save folder%s from a previous session that didn't finish (crash, power loss, or force-quit). They take disk space and are normally safe to delete." % [
		stale.size(), "s" if stale.size() != 1 else "",
	])
	headline.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.style_label(headline, UITheme.WHITE_SOFT, 13, false)
	vbox.add_child(headline)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list: VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	for path: String in stale:
		# Strip the .~save_ prefix to give the user the human-readable name
		# (it's the journey-folder name that would have resulted).
		var journey_name: String = (path.get_file() as String).substr(len(".~save_"))
		var row: Label = Label.new()
		row.text = "•  %s\n   %s" % [journey_name, path]
		row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		UITheme.style_label(row, UITheme.PURPLE_BRIGHT, 12, false)
		list.add_child(row)

	var recover_hint: Label = Label.new()
	recover_hint.text = "Advanced: to recover one manually, rename its folder to remove the `.~save_` prefix using your file manager. The journey will reappear in the catalogue. Most of the time, just deleting them is fine."
	recover_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UITheme.style_label(recover_hint, UITheme.SEPARATOR, 11, false)
	vbox.add_child(recover_hint)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)

	var keep_btn: Button = Button.new()
	keep_btn.text = "KEEP"
	keep_btn.custom_minimum_size = Vector2(140, 0)
	UITheme.style_button(keep_btn, UITheme.PURPLE_MID)
	keep_btn.pressed.connect(func() -> void: modal.queue_free())
	btn_row.add_child(keep_btn)

	var delete_btn: Button = Button.new()
	delete_btn.text = "✕  DELETE ALL"
	delete_btn.custom_minimum_size = Vector2(180, 0)
	UITheme.style_button(delete_btn, UITheme.MAGENTA)
	delete_btn.pressed.connect(func() -> void:
		for path: String in stale:
			JourneyData.delete_dir_recursive(path)
		modal.queue_free()
	)
	btn_row.add_child(delete_btn)

	add_child(modal)
