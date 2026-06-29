extends Control

# ---------------------------------------------------------------------------
# AnimatedBackground.gd
# Purple matrix theme. Orbs travel from screen edges to hit indicators and
# explode with a double-ring burst and particles.
# ---------------------------------------------------------------------------

const COLORS: Array[Color] = [
	Color(0.698, 0.118, 1.0, 1.0),  # bright violet  #b21eff
	Color(0.878, 0.0, 0.878, 1.0),  # magenta        #e000e0
	Color(0.408, 0.063, 0.627, 1.0),  # mid purple     #6810a0
	Color(0.800, 0.600, 1.0, 1.0),  # pale lavender  #cc99ff
]

const NUM_INDICATORS: int = 8
const CIRCLE_SPEED: float = 140.0
const SPAWN_MIN: float = 0.8
const SPAWN_MAX: float = 2.2
const LINE_ALPHA: float = 0.22
const CIRCLE_ALPHA: float = 0.90
const INDICATOR_ALPHA: float = 0.40
const EXPLODE_DURATION: float = 0.40
const PARTICLE_COUNT: int = 12
const DASH_LEN: float = 6.0
const GAP_LEN: float = 10.0
const INDICATOR_RADIUS: float = 18.0
const INNER_RADIUS: float = 5.0
const MARGIN: float = 60.0

var _screen_size: Vector2 = Vector2.ZERO
var _indicators: Array[Dictionary] = []


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen_size = get_viewport_rect().size
	get_viewport().size_changed.connect(_on_resize)
	_build_indicators()


func _on_resize() -> void:
	_screen_size = get_viewport_rect().size
	_indicators.clear()
	_build_indicators()


func _build_indicators() -> void:
	for i: int in NUM_INDICATORS:
		(
			_indicators
			. append(
				{
					"pos":
					Vector2(
						randf_range(MARGIN, _screen_size.x - MARGIN),
						randf_range(MARGIN, _screen_size.y - MARGIN)
					),
					"color": COLORS[i % COLORS.size()],
					"spawn_timer": randf_range(0.0, SPAWN_MAX),
					"spawn_interval": randf_range(SPAWN_MIN, SPAWN_MAX),
					"circles": [] as Array[Dictionary],
				}
			)
		)


func _process(delta: float) -> void:
	for ind: Dictionary in _indicators:
		ind["spawn_timer"] = (ind["spawn_timer"] as float) + delta
		if (ind["spawn_timer"] as float) >= (ind["spawn_interval"] as float):
			ind["spawn_timer"] = 0.0
			ind["spawn_interval"] = randf_range(SPAWN_MIN, SPAWN_MAX)
			_spawn_circle(ind)

		var circles: Array[Dictionary] = ind["circles"]
		for circle: Dictionary in circles:
			if circle["done"] as bool:
				continue
			if not (circle["exploding"] as bool):
				var dir: Vector2 = circle["direction"]
				circle["pos"] = (circle["pos"] as Vector2) + dir * CIRCLE_SPEED * delta
				var dist: float = (circle["pos"] as Vector2).distance_to(ind["pos"] as Vector2)
				if dist < CIRCLE_SPEED * delta * 1.5:
					_trigger_explode(circle, ind["pos"] as Vector2)
			else:
				circle["explode_timer"] = (circle["explode_timer"] as float) + delta
				var particles: Array[Dictionary] = circle["particles"]
				for p: Dictionary in particles:
					p["offset"] = (p["offset"] as Vector2) + (p["velocity"] as Vector2) * delta
				if (circle["explode_timer"] as float) >= EXPLODE_DURATION:
					circle["done"] = true

		ind["circles"] = circles.filter(func(c: Dictionary) -> bool: return not (c["done"] as bool))

	queue_redraw()


func _spawn_circle(ind: Dictionary) -> void:
	var target: Vector2 = ind["pos"] as Vector2
	var radius: float = randf_range(6.0, 11.0)
	var edge_pos: Vector2 = _random_edge_point()
	var dir: Vector2 = (target - edge_pos).normalized()

	(
		(ind["circles"] as Array[Dictionary])
		. append(
			{
				"pos": edge_pos,
				"direction": dir,
				"radius": radius,
				"color": ind["color"] as Color,
				"exploding": false,
				"explode_timer": 0.0,
				"particles": [] as Array[Dictionary],
				"done": false,
			}
		)
	)


func _random_edge_point() -> Vector2:
	match randi() % 4:
		0:
			return Vector2(randf_range(0.0, _screen_size.x), 0.0)
		1:
			return Vector2(randf_range(0.0, _screen_size.x), _screen_size.y)
		2:
			return Vector2(0.0, randf_range(0.0, _screen_size.y))
		_:
			return Vector2(_screen_size.x, randf_range(0.0, _screen_size.y))


func _trigger_explode(circle: Dictionary, target: Vector2) -> void:
	circle["pos"] = target
	circle["exploding"] = true
	circle["explode_timer"] = 0.0
	var particles: Array[Dictionary] = []
	for i: int in PARTICLE_COUNT:
		var angle: float = (TAU / float(PARTICLE_COUNT)) * float(i) + randf_range(-0.3, 0.3)
		var speed: float = randf_range(50.0, 160.0)
		(
			particles
			. append(
				{
					"offset": Vector2.ZERO,
					"velocity": Vector2(cos(angle), sin(angle)) * speed,
				}
			)
		)
	circle["particles"] = particles


func _draw() -> void:
	for ind: Dictionary in _indicators:
		var ind_pos: Vector2 = ind["pos"]
		var ind_col: Color = ind["color"]

		var ring_col: Color = ind_col
		ring_col.a = INDICATOR_ALPHA
		draw_arc(ind_pos, INDICATOR_RADIUS, 0.0, TAU, 48, ring_col, 1.5)

		var dot_col: Color = ind_col
		dot_col.a = INDICATOR_ALPHA * 1.5
		draw_circle(ind_pos, INNER_RADIUS, dot_col)

		var circles: Array[Dictionary] = ind["circles"]
		for circle: Dictionary in circles:
			if circle["done"] as bool:
				continue

			var cpos: Vector2 = circle["pos"]
			var col: Color = circle["color"]

			if not (circle["exploding"] as bool):
				var line_col: Color = col
				line_col.a = LINE_ALPHA
				_draw_dashed(cpos, ind_pos, line_col)

				col.a = CIRCLE_ALPHA
				draw_arc(cpos, circle["radius"] as float, 0.0, TAU, 24, col, 1.5)

				col.a = CIRCLE_ALPHA * 0.18
				draw_circle(cpos, (circle["radius"] as float) * 0.5, col)
			else:
				var t: float = (circle["explode_timer"] as float) / EXPLODE_DURATION
				var alpha: float = (1.0 - t) * CIRCLE_ALPHA

				col.a = alpha * 0.85
				draw_arc(
					ind_pos, (circle["radius"] as float) * (1.0 + t * 3.0), 0.0, TAU, 36, col, 2.0
				)

				col.a = alpha * 0.40
				draw_arc(
					ind_pos, (circle["radius"] as float) * (1.0 + t * 5.5), 0.0, TAU, 36, col, 1.0
				)

				col.a = alpha
				var particles: Array[Dictionary] = circle["particles"]
				for p: Dictionary in particles:
					draw_circle(ind_pos + (p["offset"] as Vector2), 2.0, col)


func _draw_dashed(from: Vector2, to: Vector2, color: Color) -> void:
	var total: float = from.distance_to(to)
	var dir: Vector2 = (to - from).normalized()
	var traveled: float = 0.0
	var drawing: bool = true
	while traveled < total:
		var seg_len: float = DASH_LEN if drawing else GAP_LEN
		var seg_end: float = minf(traveled + seg_len, total)
		if drawing:
			draw_line(from + dir * traveled, from + dir * seg_end, color, 1.0)
		traveled = seg_end
		drawing = not drawing
