extends Control

signal closed

const PANEL_WIDTH: int = 300
const SLIDE_TIME: float = 0.18

@onready var _backdrop: ColorRect = $Backdrop
@onready var _panel: PanelContainer = $Panel
@onready var _vbox: VBoxContainer = $Panel/VBox
@onready var _header: HBoxContainer = $Panel/VBox/HeaderRow
@onready var _title: Label = $Panel/VBox/HeaderRow/Title
@onready var _close_btn: Button = $Panel/VBox/HeaderRow/CloseButton
@onready var _subtitle: Label = $Panel/VBox/Subtitle
@onready var _empty_lbl: Label = $Panel/VBox/EmptyLabel
@onready var _scroll: ScrollContainer = $Panel/VBox/Scroll
@onready var _item_list: VBoxContainer = $Panel/VBox/Scroll/ItemList

# True while an activation animation is playing — blocks further card clicks
# until the inventory list rebuilds (cleared in _refresh).
var _activating: bool = false


func _ready() -> void:
	# The backdrop and root cover the full viewport for slide animation only —
	# they must not block clicks to the game beneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.color = Color(0, 0, 0, 0)
	_apply_layout()
	_apply_theme()
	_close_btn.pressed.connect(close)
	InventoryService.InventoryChanged.connect(_refresh)
	InventoryService.UnlockedChanged.connect(_refresh)
	CoinService.BalanceChanged.connect(_on_balance_changed)
	_refresh()
	_slide_in()


func _on_balance_changed(_balance: int) -> void:
	_refresh()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


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


# --------------------------------------------------------------------------
# Item list
# --------------------------------------------------------------------------


func _refresh() -> void:
	_activating = false
	for child in _item_list.get_children():
		child.queue_free()

	var ppu: bool = InventoryService.UnlockPayPerUse
	var unlocked_ids: Array = InventoryService.GetUnlockedIds() if ppu else []
	var items: Array = InventoryService.GetItems()
	var has_any: bool = not unlocked_ids.is_empty() or not items.is_empty()
	_empty_lbl.visible = not has_any
	_scroll.visible = has_any

	# PPU: unlocked modifiers — pay price to activate (no inventory charge).
	if ppu:
		for id_v in unlocked_ids:
			var id: String = str(id_v)
			var data: Dictionary = InventoryService.GetItemData(id)
			if data.is_empty():
				continue
			_item_list.add_child(_make_unlocked_row(id, data))

	# Held charges — utilities always; modifiers too in classic mode.
	for i in items.size():
		var data: Dictionary = items[i]
		_item_list.add_child(_make_charge_row(i, data))


func _make_unlocked_row(id: String, data: Dictionary) -> Control:
	var cls: Dictionary = _class_info(data.get("kind", ""))
	var price: int = int(data.get("price", 0))
	var can_afford: bool = CoinService.CanAfford(price)

	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _row_stylebox(cls["color"]))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not can_afford:
		card.modulate = Color(1, 1, 1, 0.55)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(margin)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	col.add_child(top_row)

	var name_lbl: Label = Label.new()
	name_lbl.text = (data.get("name", "?") as String).to_upper()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 14)
	top_row.add_child(name_lbl)

	var class_lbl: Label = Label.new()
	class_lbl.text = "%s %s" % [cls["glyph"], cls["label"]]
	class_lbl.add_theme_color_override("font_color", cls["color"])
	class_lbl.add_theme_font_size_override("font_size", 10)
	top_row.add_child(class_lbl)

	var dur_lbl: Label = Label.new()
	var dur_ms: int = data.get("duration_ms", 0)
	if bool(data.get("round_scoped", false)):
		dur_lbl.text = "ROUND"
	else:
		dur_lbl.text = "%ds" % int(dur_ms / 1000.0)
	dur_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	dur_lbl.add_theme_font_size_override("font_size", 11)
	top_row.add_child(dur_lbl)

	var desc_lbl: Label = Label.new()
	desc_lbl.text = data.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	desc_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(desc_lbl)

	var use_lbl: Label = Label.new()
	if can_afford:
		use_lbl.text = "> CLICK TO ACTIVATE  ♦ %d" % price
		use_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	else:
		use_lbl.text = "✕ INSUFFICIENT  ♦ %d" % price
		use_lbl.add_theme_color_override("font_color", UITheme.DANGER)
	use_lbl.add_theme_font_size_override("font_size", 10)
	col.add_child(use_lbl)

	_set_mouse_filter_recursive(margin, Control.MOUSE_FILTER_IGNORE)
	if can_afford:
		card.gui_input.connect(_on_unlocked_card_input.bind(card, use_lbl, id))
	return card


func _make_charge_row(slot_idx: int, data: Dictionary) -> Control:
	var cls: Dictionary = _class_info(data.get("kind", ""))
	var kind: String = data.get("kind", "")
	var host: Node = _inventory_host()
	var gate: String = ""
	if host != null and host.has_method("inventory_activation_gate"):
		gate = host.inventory_activation_gate(data)
	var disabled: bool = gate == "disabled"

	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _row_stylebox(cls["color"]))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if disabled:
		card.modulate = Color(1, 1, 1, 0.4)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	card.add_child(margin)

	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	margin.add_child(col)

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	col.add_child(top_row)

	var name_lbl: Label = Label.new()
	name_lbl.text = (data.get("name", "?") as String).to_upper()
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_color_override("font_color", UITheme.WHITE_SOFT)
	name_lbl.add_theme_font_size_override("font_size", 14)
	top_row.add_child(name_lbl)

	var class_lbl: Label = Label.new()
	class_lbl.text = "%s %s" % [cls["glyph"], cls["label"]]
	class_lbl.add_theme_color_override("font_color", cls["color"])
	class_lbl.add_theme_font_size_override("font_size", 10)
	top_row.add_child(class_lbl)

	var dur_lbl: Label = Label.new()
	var dur_ms: int = data.get("duration_ms", 0)
	if bool(data.get("round_scoped", false)):
		dur_lbl.text = "ROUND"
	else:
		dur_lbl.text = "%ds" % int(dur_ms / 1000.0) if dur_ms > 0 else "HOLD"
	dur_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	dur_lbl.add_theme_font_size_override("font_size", 11)
	top_row.add_child(dur_lbl)

	var desc_lbl: Label = Label.new()
	desc_lbl.text = data.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	desc_lbl.add_theme_font_size_override("font_size", 11)
	col.add_child(desc_lbl)

	var use_lbl: Label = Label.new()
	if kind == "key" or kind == "cleanse":
		use_lbl.text = "> HELD (AUTO-USE)"
		use_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	elif disabled:
		use_lbl.text = "✕ UNAVAILABLE"
		use_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	else:
		use_lbl.text = "> CLICK TO ACTIVATE"
		use_lbl.add_theme_color_override("font_color", UITheme.AMBER)
	use_lbl.add_theme_font_size_override("font_size", 10)
	col.add_child(use_lbl)

	_set_mouse_filter_recursive(margin, Control.MOUSE_FILTER_IGNORE)
	if kind != "key" and kind != "cleanse" and not disabled:
		card.gui_input.connect(_on_charge_card_input.bind(card, use_lbl, slot_idx))
	return card


# Classifies an item by its effect `kind` into a player-facing category.
# buff = helps the player, debuff = hinders, modifier = neutral change.
func _class_info(kind: String) -> Dictionary:
	match kind:
		"score_multiplier", "coin_jackpot":
			return {"label": "BUFF", "color": UITheme.TOXIC_GREEN, "glyph": "▲"}
		"block", "blackout", "blackout_soft":
			return {"label": "DEBUFF", "color": UITheme.ERROR_SOFT, "glyph": "▼"}
		"key", "cleanse", "save_now", "shave_cooldown", "skip_round":
			return {"label": "UTILITY", "color": UITheme.PURPLE_BRIGHT, "glyph": "●"}
		_:
			return {"label": "MODIFIER", "color": UITheme.AMBER, "glyph": "◆"}


func _set_mouse_filter_recursive(node: Node, filter: int) -> void:
	if node is Control:
		(node as Control).mouse_filter = filter
	for child in node.get_children():
		_set_mouse_filter_recursive(child, filter)


func _on_unlocked_card_input(event: InputEvent, card: Control, use_lbl: Label, id: String) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_activate_unlocked_card(card, use_lbl, id)


func _on_charge_card_input(event: InputEvent, card: Control, use_lbl: Label, slot_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_activate_charge_card(card, use_lbl, slot_idx)


func _activate_unlocked_card(card: Control, use_lbl: Label, id: String) -> void:
	if _activating:
		return
	var data: Dictionary = InventoryService.GetItemData(id)
	var price: int = int(data.get("price", 0))
	if not CoinService.CanAfford(price):
		return
	var host: Node = _inventory_host()
	if host != null and host.has_method("inventory_activation_gate"):
		var gate: String = host.inventory_activation_gate(data)
		if gate == "disabled":
			return
		if gate != "":
			if host.has_method("_show_save_toast"):
				host._show_save_toast(gate)
			return
	_activating = true
	UISound.item_use()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	use_lbl.text = "✓ ACTIVATED"
	use_lbl.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)

	var tw: Tween = create_tween()
	tw.tween_property(card, "modulate", Color(1.8, 1.8, 1.8, 1.0), 0.09)
	tw.tween_property(card, "modulate:a", 0.0, 0.24).set_ease(Tween.EASE_IN)
	(
		tw
		. parallel()
		. tween_property(card, "position:x", card.position.x + 90.0, 0.24)
		. set_ease(Tween.EASE_IN)
		. set_trans(Tween.TRANS_CUBIC)
	)
	var dur_override: int = -1
	if host != null and host.has_method("inventory_duration_override_ms"):
		dur_override = int(host.inventory_duration_override_ms(data))
	tw.tween_callback(
		func() -> void: InventoryService.ActivateUnlocked(id, dur_override)
	)


func _activate_charge_card(card: Control, use_lbl: Label, slot_idx: int) -> void:
	if _activating:
		return
	var data: Dictionary = InventoryService.PeekItem(slot_idx)
	if data.is_empty():
		return
	var host: Node = _inventory_host()
	if host != null and host.has_method("inventory_activation_gate"):
		var gate: String = host.inventory_activation_gate(data)
		if gate == "disabled":
			return
		if gate != "":
			if host.has_method("_show_save_toast"):
				host._show_save_toast(gate)
			return
	_activating = true
	UISound.item_use()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	use_lbl.text = "✓ ACTIVATED"
	use_lbl.add_theme_color_override("font_color", UITheme.TOXIC_GREEN)

	var tw: Tween = create_tween()
	# Bright flash.
	tw.tween_property(card, "modulate", Color(1.8, 1.8, 1.8, 1.0), 0.09)
	# Slide right + fade out together.
	tw.tween_property(card, "modulate:a", 0.0, 0.24).set_ease(Tween.EASE_IN)
	(
		tw
		. parallel()
		. tween_property(card, "position:x", card.position.x + 90.0, 0.24)
		. set_ease(Tween.EASE_IN)
		. set_trans(Tween.TRANS_CUBIC)
	)
	var dur_override: int = -1
	if host != null and host.has_method("inventory_duration_override_ms"):
		dur_override = int(host.inventory_duration_override_ms(data))
	# Activate once the card has visually left — InventoryChanged → _refresh().
	tw.tween_callback(
		func() -> void: InventoryService.ActivateItem(slot_idx, dur_override)
	)


func _inventory_host() -> Node:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("inventory_activation_gate"):
			return n
		n = n.get_parent()
	return null


# --------------------------------------------------------------------------
# Layout / theme
# --------------------------------------------------------------------------


func _apply_layout() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0

	_backdrop.anchor_right = 1.0
	_backdrop.anchor_bottom = 1.0

	# Panel: anchored to the right edge, full height.
	_panel.anchor_left = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	_panel.offset_top = 0
	_panel.offset_bottom = 0
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)

	_vbox.add_theme_constant_override("separation", 12)
	_header.add_theme_constant_override("separation", 8)
	_item_list.add_theme_constant_override("separation", 10)


func _apply_theme() -> void:
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = UITheme.PANEL_BG_DEEP
	panel_style.border_color = UITheme.PURPLE_BRIGHT
	panel_style.border_width_left = 3
	panel_style.content_margin_left = 18
	panel_style.content_margin_right = 18
	panel_style.content_margin_top = 18
	panel_style.content_margin_bottom = 18
	_panel.add_theme_stylebox_override("panel", panel_style)

	_title.add_theme_color_override("font_color", UITheme.PURPLE_BRIGHT)
	_title.add_theme_font_size_override("font_size", 20)
	_title.uppercase = true

	_subtitle.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_subtitle.add_theme_font_size_override("font_size", 11)
	_subtitle.uppercase = true

	_empty_lbl.add_theme_color_override("font_color", UITheme.DARK_TEXT)
	_empty_lbl.add_theme_font_size_override("font_size", 13)
	_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_style_close_button(_close_btn)


# `accent` colours the card outline — a bold left stripe plus a thin border —
# so the item's effect class (buff / debuff / modifier) reads at a glance.
func _row_stylebox(accent: Color) -> StyleBoxFlat:
	var s: StyleBoxFlat = StyleBoxFlat.new()
	s.bg_color = UITheme.CARD_BG
	s.border_color = accent
	s.border_width_left = 4
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	return s


# Thin delegate to UITheme — the canonical styling lives there.
func _style_close_button(btn: Button) -> void:
	UITheme.style_close_button(btn)
