extends PanelContainer

signal selected

const CARD_MIN_WIDTH:  int = 280
const CARD_MIN_HEIGHT: int = 340
const BORDER_WIDTH:    int = 2

@onready var _cover: TextureRect = $VBox/CoverRect
@onready var _title: Label       = $VBox/TitleLabel


func _ready() -> void:
	custom_minimum_size = Vector2(CARD_MIN_WIDTH, CARD_MIN_HEIGHT)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter        = Control.MOUSE_FILTER_STOP

	_cover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cover.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_cover.custom_minimum_size   = Vector2.ZERO

	_title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	_title.add_theme_font_size_override("font_size", 13)
	_title.uppercase = true
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_constant_override("margin_top",    8)
	_title.add_theme_constant_override("margin_bottom", 10)

	mouse_entered.connect(_on_hover_enter)
	mouse_exited.connect(_on_hover_exit)
	_set_style(false)


func setup(journey: Dictionary) -> void:
	_title.text = journey.get("title", "Unknown")
	var cover_path: String = journey.get("cover_path", "")
	var img: Image = JourneyData.load_image_smart(cover_path)
	_cover.texture = ImageTexture.create_from_image(img) if img else null


func _set_style(hovered: bool) -> void:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color     = UITheme.PURPLE_DARK if hovered else UITheme.PANEL_BG
	s.border_color = UITheme.PURPLE_BRIGHT if hovered else UITheme.PURPLE_MID
	s.border_width_left   = BORDER_WIDTH
	s.border_width_right  = BORDER_WIDTH
	s.border_width_top    = BORDER_WIDTH
	s.border_width_bottom = BORDER_WIDTH
	if hovered:
		s.shadow_color = Color(UITheme.PURPLE_BRIGHT.r, UITheme.PURPLE_BRIGHT.g, UITheme.PURPLE_BRIGHT.b, 0.45)
		s.shadow_size  = 10
	s.content_margin_left   = 0
	s.content_margin_right  = 0
	s.content_margin_top    = 0
	s.content_margin_bottom = 12
	add_theme_stylebox_override("panel", s)


func _on_hover_enter() -> void:
	_set_style(true)
	_title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)


func _on_hover_exit() -> void:
	_set_style(false)
	_title.add_theme_color_override("font_color", UITheme.WHITE_SOFT)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			selected.emit()
