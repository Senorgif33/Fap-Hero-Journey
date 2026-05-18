extends Control

# ---------------------------------------------------------------------------
# Options.gd
# Purple matrix theme. Audio, display, and Intiface/Buttplug settings.
# Settings are persisted to user://settings.cfg via ConfigFile.
# ---------------------------------------------------------------------------

const COLOR_BG:            Color = Color(0.0,   0.0,   0.0,   1.0)
const COLOR_PANEL_BG:      Color = Color(0.055, 0.008, 0.086, 1.0)
const COLOR_PURPLE_DARK:   Color = Color(0.176, 0.024, 0.259, 1.0)
const COLOR_PURPLE_MID:    Color = Color(0.408, 0.063, 0.627, 1.0)
const COLOR_PURPLE_BRIGHT: Color = Color(0.698, 0.118, 1.0,   1.0)
const COLOR_MAGENTA:       Color = Color(0.878, 0.0,   0.878, 1.0)
const COLOR_WHITE_SOFT:    Color = Color(0.878, 0.780, 1.0,   1.0)
const COLOR_SEPARATOR:     Color = Color(0.698, 0.118, 1.0,   0.5)
const COLOR_OK:            Color = Color(0.35,  0.95,  0.35,  1.0)
const COLOR_ERROR:         Color = Color(1.0,   0.25,  0.05,  1.0)

const TOP_BAR_HEIGHT:  int = 64
const PANEL_HALF_W:    int = 480
const PANEL_PAD_V:     int = 24
const BORDER_WIDTH:    int = 3
const ROW_LABEL_W:     int = 260
const SLIDER_MIN_W:    int = 260
const VALUE_LABEL_W:   int = 64

const SETTINGS_PATH:       String = "user://settings.cfg"
const DEFAULT_BP_ADDRESS:  String = "ws://localhost:12345"

const RESOLUTIONS: Array = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]

@onready var _bg:              ColorRect     = $Background
@onready var _top_bar:         HBoxContainer = $TopBar
@onready var _back_btn:        Button        = $TopBar/BackButton
@onready var _title_lbl:       Label         = $TopBar/TitleLabel
@onready var _content_panel:   PanelContainer = $ContentPanel
@onready var _content_vbox:    VBoxContainer  = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox
@onready var _master_slider:   HSlider        = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterSlider
@onready var _master_value:    Label          = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterValue
@onready var _fs_toggle:       Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsToggle
@onready var _res_dropdown:    OptionButton   = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResDropdown
@onready var _address_input:   LineEdit       = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressInput
@onready var _auto_toggle:     Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow/AutoConnectToggle
@onready var _connect_btn:     Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ConnectBtn
@onready var _scan_btn:        Button         = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/ScanBtn
@onready var _status_lbl:      Label          = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow/StatusLabel
@onready var _device_dropdown: OptionButton   = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceDropdown

var _config: ConfigFile = ConfigFile.new()
var _is_connected: bool = false
var overlay_mode: bool = false


func _ready() -> void:
	_apply_layout()
	_apply_theme()
	_populate_resolution_dropdown()
	_load_settings()
	_connect_signals()
	_sync_buttplug_state()


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _apply_layout() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	_bg.anchor_right  = 1.0
	_bg.anchor_bottom = 1.0
	_bg.offset_left = 0
	_bg.offset_top = 0
	_bg.offset_right = 0
	_bg.offset_bottom = 0
	
	var animated_bg: Control = $AnimatedBackground
	animated_bg.anchor_right  = 1.0
	animated_bg.anchor_bottom = 1.0

	_top_bar.anchor_right  = 1.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_left   = 16
	_top_bar.offset_right  = -16
	_top_bar.offset_bottom = TOP_BAR_HEIGHT
	_top_bar.add_theme_constant_override("separation", 0)

	_content_panel.anchor_left   = 0.5
	_content_panel.anchor_right  = 0.5
	_content_panel.anchor_top    = 0.0
	_content_panel.anchor_bottom = 1.0
	_content_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_content_panel.offset_left   = -PANEL_HALF_W
	_content_panel.offset_right  =  PANEL_HALF_W
	_content_panel.offset_top    = TOP_BAR_HEIGHT + PANEL_PAD_V
	_content_panel.offset_bottom = -PANEL_PAD_V

	($ContentPanel/ContentScroll/MarginWrapper as MarginContainer).add_theme_constant_override("margin_right", 24)

	_content_vbox.add_theme_constant_override("separation", 10)

	for section_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection",
	]:
		var s: VBoxContainer = get_node(section_path)
		s.add_theme_constant_override("separation", 12)

	for row_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/ConnectionRow",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow",
	]:
		var r: HBoxContainer = get_node(row_path)
		r.add_theme_constant_override("separation", 16)

	var master_lbl: Label = $ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterLabel
	master_lbl.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	_master_slider.custom_minimum_size = Vector2(SLIDER_MIN_W, 0)
	_master_value.custom_minimum_size  = Vector2(VALUE_LABEL_W, 0)

	for label_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceLabel",
	]:
		(get_node(label_path) as Label).custom_minimum_size = Vector2(ROW_LABEL_W, 0)

	_res_dropdown.custom_minimum_size  = Vector2(220, 0)
	_device_dropdown.custom_minimum_size = Vector2(220, 0)


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

func _apply_theme() -> void:
	_bg.color = COLOR_BG

	_style_label(_title_lbl, COLOR_PURPLE_BRIGHT, 18, true)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER

	_style_button(_back_btn, COLOR_MAGENTA)
	_style_button(_connect_btn, COLOR_PURPLE_BRIGHT)
	_style_button(_scan_btn, COLOR_PURPLE_MID)

	_style_panel()

	for header_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/AudioHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/DisplayHeader",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/IntifaceHeader",
	]:
		_style_label(get_node(header_path), COLOR_PURPLE_BRIGHT, 13, true)

	var sep_style: StyleBoxFlat = _make_separator_style()
	for sep_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/AudioDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/DisplayDivider",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/IntifaceDivider",
	]:
		(get_node(sep_path) as HSeparator).add_theme_stylebox_override("separator", sep_style)

	for row_label_path in [
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/AudioSection/MasterRow/MasterLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/FullscreenRow/FsLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/DisplaySection/ResolutionRow/ResLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AddressRow/AddressLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/AutoConnectRow/AutoConnectLabel",
		"ContentPanel/ContentScroll/MarginWrapper/ContentVBox/IntifaceSection/DeviceRow/DeviceLabel",
	]:
		_style_label(get_node(row_label_path), COLOR_WHITE_SOFT, 14, false)

	_style_label(_master_value, COLOR_PURPLE_BRIGHT, 14, false)
	_style_label(_status_lbl,   COLOR_ERROR,         13, false)

	_style_slider(_master_slider)
	_style_option_button(_res_dropdown)
	_style_option_button(_device_dropdown)
	_style_line_edit(_address_input)
	_style_toggle(_fs_toggle,   false)
	_style_toggle(_auto_toggle, false)


func _style_panel() -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color            = COLOR_PANEL_BG
	s.border_color        = COLOR_PURPLE_BRIGHT
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	s.corner_radius_top_left     = 4
	s.corner_radius_top_right    = 4
	s.corner_radius_bottom_left  = 4
	s.corner_radius_bottom_right = 4
	s.shadow_color = Color(COLOR_MAGENTA.r, COLOR_MAGENTA.g, COLOR_MAGENTA.b, 0.5)
	s.shadow_size  = 12
	s.content_margin_left   = 32
	s.content_margin_right  = 32
	s.content_margin_top    = 28
	s.content_margin_bottom = 28
	_content_panel.add_theme_stylebox_override("panel", s)

func _make_separator_style() -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = COLOR_SEPARATOR
	return s


func _style_label(label: Label, color: Color, size: int, uppercase: bool = false) -> void:
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size)
	label.uppercase = uppercase


func _style_button(btn: Button, accent: Color) -> void:
	btn.add_theme_color_override("font_color",         accent)
	btn.add_theme_color_override("font_hover_color",   COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color", COLOR_BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	btn.add_theme_stylebox_override("normal",  _make_btn_style(accent, COLOR_PURPLE_DARK))
	btn.add_theme_stylebox_override("hover",   _make_btn_style(accent, COLOR_PURPLE_MID))
	btn.add_theme_stylebox_override("pressed", _make_btn_style(accent, accent))
	btn.add_theme_stylebox_override("focus",   StyleBoxEmpty.new())


func _make_btn_style(border: Color, fill: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat   = StyleBoxFlat.new()
	s.bg_color            = fill
	s.border_color        = border
	s.border_width_left   = 2
	s.border_width_right  = 2
	s.border_width_top    = 2
	s.border_width_bottom = 2
	s.content_margin_left   = 18
	s.content_margin_right  = 18
	s.content_margin_top    = 10
	s.content_margin_bottom = 10
	return s


func _style_toggle(btn: Button, pressed: bool) -> void:
	var active_color:   Color = COLOR_PURPLE_BRIGHT
	var inactive_color: Color = COLOR_PURPLE_MID
	var accent: Color = active_color if pressed else inactive_color
	btn.add_theme_color_override("font_color",          accent)
	btn.add_theme_color_override("font_hover_color",    COLOR_WHITE_SOFT)
	btn.add_theme_color_override("font_pressed_color",  COLOR_BG)
	btn.add_theme_font_size_override("font_size", 14)
	btn.text = btn.text.to_upper()
	var fill: Color = COLOR_PURPLE_MID if pressed else COLOR_PURPLE_DARK
	btn.add_theme_stylebox_override("normal",   _make_btn_style(accent, fill))
	btn.add_theme_stylebox_override("hover",    _make_btn_style(accent, COLOR_PURPLE_MID))
	btn.add_theme_stylebox_override("pressed",  _make_btn_style(active_color, active_color))
	btn.add_theme_stylebox_override("focus",    StyleBoxEmpty.new())
	btn.text = "ON" if pressed else "OFF"


func _style_slider(slider: HSlider) -> void:
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color          = COLOR_PURPLE_DARK
	track.border_color      = COLOR_PURPLE_MID
	track.border_width_left = 1
	track.border_width_right = 1 
	track.border_width_top = 1
	track.border_width_bottom = 1
	track.content_margin_top = 4
	track.content_margin_bottom = 4

	var fill: StyleBoxFlat = StyleBoxFlat.new()
	fill.bg_color = COLOR_PURPLE_BRIGHT
	fill.content_margin_top = 4
	fill.content_margin_bottom = 4

	slider.add_theme_stylebox_override("slider",       track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_color_override("grabber_color",   COLOR_MAGENTA)
	slider.custom_minimum_size.y = 24


func _style_option_button(opt: OptionButton) -> void:
	opt.add_theme_color_override("font_color",       COLOR_WHITE_SOFT)
	opt.add_theme_color_override("font_hover_color", COLOR_PURPLE_BRIGHT)
	opt.add_theme_font_size_override("font_size", 14)
	opt.add_theme_stylebox_override("normal", _make_btn_style(COLOR_PURPLE_MID,    COLOR_PURPLE_DARK))
	opt.add_theme_stylebox_override("hover",  _make_btn_style(COLOR_PURPLE_BRIGHT, COLOR_PURPLE_MID))
	opt.add_theme_stylebox_override("focus",  StyleBoxEmpty.new())


func _style_line_edit(edit: LineEdit) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color          = COLOR_PURPLE_DARK
	s.border_color      = COLOR_PURPLE_MID
	
	s.border_width_left = 2
	s.border_width_right = 2
	s.border_width_top = 2
	s.border_width_bottom = 2
	
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	
	edit.add_theme_stylebox_override("normal", s)
	edit.add_theme_color_override("font_color", COLOR_WHITE_SOFT)
	edit.add_theme_color_override("font_placeholder_color", COLOR_PURPLE_MID)
	edit.add_theme_color_override("caret_color", COLOR_PURPLE_BRIGHT)
	edit.add_theme_color_override("selection_color", Color(COLOR_PURPLE_BRIGHT.r, COLOR_PURPLE_BRIGHT.g, COLOR_PURPLE_BRIGHT.b, 0.4))
	edit.add_theme_font_size_override("font_size", 14)


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _populate_resolution_dropdown() -> void:
	_res_dropdown.clear()
	for res: Vector2i in RESOLUTIONS:
		_res_dropdown.add_item("%d × %d" % [res.x, res.y])


func _load_settings() -> void:
	if _config.load(SETTINGS_PATH) != OK:
		_apply_defaults()
		return

	var vol: float = _config.get_value("audio", "master_volume", 1.0)
	_master_slider.value = vol
	_update_volume_label(vol)
	AudioServer.set_bus_volume_db(0, linear_to_db(vol))

	var res_idx: int = _config.get_value("display", "resolution_index", 1)
	_res_dropdown.selected = clampi(res_idx, 0, RESOLUTIONS.size() - 1)

	var fullscreen: bool = _config.get_value("display", "fullscreen", false)
	_fs_toggle.button_pressed = fullscreen
	_style_toggle(_fs_toggle, fullscreen)
	_apply_fullscreen(fullscreen)

	var address: String = _config.get_value("intiface", "address", DEFAULT_BP_ADDRESS)
	_address_input.text = address

	var auto_connect: bool = _config.get_value("intiface", "auto_connect", true)
	_auto_toggle.button_pressed = auto_connect
	_style_toggle(_auto_toggle, auto_connect)


func _apply_defaults() -> void:
	_master_slider.value = 1.0
	_master_value.text   = "100%"
	_res_dropdown.selected = 1
	_address_input.text  = DEFAULT_BP_ADDRESS
	_style_toggle(_fs_toggle,   false)
	_style_toggle(_auto_toggle, true)
	_auto_toggle.button_pressed = true


func _save_settings() -> void:
	_config.set_value("audio",    "master_volume",    _master_slider.value)
	_config.set_value("display",  "fullscreen",       _fs_toggle.button_pressed)
	_config.set_value("display",  "resolution_index", _res_dropdown.selected)
	_config.set_value("intiface", "address",          _address_input.text)
	_config.set_value("intiface", "auto_connect",     _auto_toggle.button_pressed)
	_config.save(SETTINGS_PATH)


func _sync_buttplug_state() -> void:
	_is_connected = ButtplugService.BpConnected
	if _is_connected:
		_set_connected_ui(true)
		_device_dropdown.clear()
		for name: String in ButtplugService.GetDeviceNames():
			_device_dropdown.add_item(name)
		_device_dropdown.disabled = _device_dropdown.item_count == 0
	else:
		_set_connected_ui(false)


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

func _connect_signals() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_master_slider.value_changed.connect(_on_volume_changed)
	_fs_toggle.toggled.connect(_on_fullscreen_toggled)
	_res_dropdown.item_selected.connect(_on_resolution_selected)
	_auto_toggle.toggled.connect(_on_auto_connect_toggled)
	_connect_btn.pressed.connect(_on_connect_pressed)
	_scan_btn.pressed.connect(_on_scan_pressed)

	ButtplugService.connect("Connected",     _on_bp_connected)
	ButtplugService.connect("Disconnected",  _on_bp_disconnected)
	ButtplugService.connect("DeviceAdded",   _on_bp_device_added)
	ButtplugService.connect("DeviceRemoved", _on_bp_device_removed)
	ButtplugService.connect("ScanFinished",  _on_bp_scan_finished)
	ButtplugService.connect("ErrorOccurred", _on_bp_error)


func _on_back_pressed() -> void:
	_save_settings()
	if overlay_mode:
		queue_free()
	else:
		Transition.change_scene("res://scenes/main/Main.tscn")


func _on_volume_changed(value: float) -> void:
	_update_volume_label(value)
	AudioServer.set_bus_volume_db(0, linear_to_db(value))
	_save_settings()


func _on_fullscreen_toggled(pressed: bool) -> void:
	_style_toggle(_fs_toggle, pressed)
	_apply_fullscreen(pressed)
	_save_settings()


func _on_resolution_selected(index: int) -> void:
	if not _fs_toggle.button_pressed:
		var res: Vector2i = RESOLUTIONS[index]
		DisplayServer.window_set_size(res)
	_save_settings()


func _on_auto_connect_toggled(pressed: bool) -> void:
	_style_toggle(_auto_toggle, pressed)
	_save_settings()


func _on_connect_pressed() -> void:
	if _is_connected:
		ButtplugService.DisconnectFromIntiface()
	else:
		var address: String = _address_input.text.strip_edges()
		if address.is_empty():
			address = DEFAULT_BP_ADDRESS
		_set_status("● CONNECTING…", COLOR_PURPLE_MID)
		_connect_btn.disabled = true
		ButtplugService.ConnectToIntiface(address)


func _on_scan_pressed() -> void:
	_set_status("● SCANNING…", COLOR_PURPLE_MID)
	_scan_btn.disabled = true
	ButtplugService.StartScan()


func _on_bp_connected() -> void:
	_is_connected = true
	_set_connected_ui(true)


func _on_bp_disconnected() -> void:
	_is_connected = false
	_device_dropdown.clear()
	_device_dropdown.disabled = true
	_set_connected_ui(false)


func _on_bp_device_added(name: String, _index: int) -> void:
	_device_dropdown.add_item(name)
	_device_dropdown.disabled = false


func _on_bp_device_removed(index: int) -> void:
	for i: int in _device_dropdown.item_count:
		if _device_dropdown.get_item_id(i) == index:
			_device_dropdown.remove_item(i)
			break
	_device_dropdown.disabled = _device_dropdown.item_count == 0


func _on_bp_scan_finished() -> void:
	_scan_btn.disabled = false
	var count: int = _device_dropdown.item_count
	if count > 0:
		_set_status("● %d DEVICE%s FOUND" % [count, "S" if count > 1 else ""], COLOR_OK)
	else:
		_set_status("● NO DEVICES FOUND", COLOR_ERROR)


func _on_bp_error(message: String) -> void:
	_connect_btn.disabled = false
	_set_status("● ERROR: " + message.left(60).to_upper(), COLOR_ERROR)
	_is_connected = false
	_set_connected_ui(false)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_connected_ui(connected: bool) -> void:
	_connect_btn.disabled = false
	_scan_btn.disabled    = not connected
	if connected:
		_style_button(_connect_btn, COLOR_MAGENTA)
		_connect_btn.text = "> DISCONNECT"
		_set_status("● CONNECTED", COLOR_OK)
	else:
		_style_button(_connect_btn, COLOR_PURPLE_BRIGHT)
		_connect_btn.text = "> CONNECT"
		_set_status("● DISCONNECTED", COLOR_ERROR)


func _set_status(text: String, color: Color) -> void:
	_status_lbl.text = text
	_status_lbl.add_theme_color_override("font_color", color)


func _update_volume_label(value: float) -> void:
	_master_value.text = "%d%%" % roundi(value * 100.0)


func _apply_fullscreen(enabled: bool) -> void:
	var mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN if enabled \
		else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(mode)
