extends CanvasLayer

# ---------------------------------------------------------------------------
# Transition.gd  –  Global scene-change handler with fade + spinner.
# Register as autoload named "Transition" in Project Settings → Autoloads.
# Usage: Transition.change_scene("res://scenes/foo/Foo.tscn")
# ---------------------------------------------------------------------------

const COLOR_OVERLAY: Color = Color(0.0, 0.0, 0.0, 0.0)
const COLOR_BLACK: Color = Color(0.0, 0.0, 0.0, 1.0)
const COLOR_SPINNER: Color = Color(0.698, 0.118, 1.0, 1.0)
const COLOR_SPINNER2: Color = Color(0.408, 0.063, 0.627, 0.4)

const FADE_DURATION: float = 0.35
const SPINNER_R: float = 22.0
const SPINNER_W: float = 4.0

var _overlay: ColorRect
var _spinner: _SpinnerNode
var _busy: bool = false


class _SpinnerNode extends Control:
	var _angle: float = 0.0

	func _ready() -> void:
		var d: float = (SPINNER_R + SPINNER_W) * 2.0
		custom_minimum_size = Vector2(d, d)
		size = custom_minimum_size

	func _process(delta: float) -> void:
		_angle += delta * 2.8
		queue_redraw()

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		var r: float = SPINNER_R
		var w: float = SPINNER_W
		draw_arc(c, r, _angle, _angle + TAU * 0.72, 48, COLOR_SPINNER,  w, true)
		draw_arc(c, r, _angle + TAU * 0.72, _angle + TAU, 24, COLOR_SPINNER2, w, true)


func _ready() -> void:
	layer = 128

	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_overlay = ColorRect.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.color = COLOR_OVERLAY
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	root.add_child(_overlay)

	_spinner = _SpinnerNode.new()
	_spinner.anchor_left   = 0.5
	_spinner.anchor_right  = 0.5
	_spinner.anchor_top    = 0.5
	_spinner.anchor_bottom = 0.5
	_spinner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_spinner.grow_vertical   = Control.GROW_DIRECTION_BOTH
	var half: float = SPINNER_R + SPINNER_W
	_spinner.offset_left   = -half
	_spinner.offset_top    = -half
	_spinner.offset_right  =  half
	_spinner.offset_bottom =  half
	_spinner.visible = false
	root.add_child(_spinner)


func change_scene(path: String) -> void:
	if _busy:
		return
	_busy = true

	_overlay.color        = COLOR_OVERLAY
	_overlay.visible      = true
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var tw: Tween = create_tween()
	tw.tween_property(_overlay, "color", COLOR_BLACK, FADE_DURATION)
	await tw.finished

	_spinner.visible = true

	get_tree().change_scene_to_file(path)
	await get_tree().process_frame
	await get_tree().process_frame

	_spinner.visible = false

	tw = create_tween()
	tw.tween_property(_overlay, "color", COLOR_OVERLAY, FADE_DURATION)
	await tw.finished

	_overlay.visible      = false
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_busy = false
