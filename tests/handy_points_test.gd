extends GdUnitTestSuite

# HandyService v3 HSP — the pure feeder math: funscript actions → HSP points,
# and the lookahead window batching that streams them into the device buffer.


func test_actions_to_points_shape() -> void:
	var actions := [Vector2(0, 0), Vector2(500, 100), Vector2(1000, 37.4)]
	var points: Array = HandyPoints.actions_to_points(actions)
	assert_int(points.size()).is_equal(3)
	assert_int(int((points[1] as Dictionary)["t"])).is_equal(500)
	assert_int(int((points[1] as Dictionary)["x"])).is_equal(100)
	# position is rounded + clamped to 0-100
	assert_int(int((points[2] as Dictionary)["x"])).is_equal(37)


func _points(times: Array) -> Array:
	var out: Array = []
	for t: int in times:
		out.append({"t": t, "x": 50})
	return out


# The window collects points up to until_t and reports the next cursor.
func test_window_collects_up_to_time() -> void:
	var pts := _points([0, 1000, 2000, 3000, 9000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 0, 2500)
	assert_int((w["batch"] as Array).size()).is_equal(3)  # 0, 1000, 2000
	assert_int(int(w["next_idx"])).is_equal(3)


# Resuming from a cursor only returns the remaining in-window points.
func test_window_resumes_from_cursor() -> void:
	var pts := _points([0, 1000, 2000, 3000, 9000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 3, 12000)
	assert_int((w["batch"] as Array).size()).is_equal(2)  # 3000, 9000
	assert_int(int(w["next_idx"])).is_equal(5)


# A batch never exceeds the HSP per-add cap.
func test_window_caps_at_max_points() -> void:
	var times: Array = []
	for i: int in 250:
		times.append(i * 10)
	var w: Dictionary = HandyPoints.points_in_window(_points(times), 0, 999999)
	assert_int((w["batch"] as Array).size()).is_equal(HandyPoints.MAX_POINTS_PER_ADD)
	assert_int(int(w["next_idx"])).is_equal(HandyPoints.MAX_POINTS_PER_ADD)


# Nothing in range → empty batch, cursor unmoved (feeder no-ops).
func test_window_empty_when_ahead() -> void:
	var pts := _points([5000, 6000])
	var w: Dictionary = HandyPoints.points_in_window(pts, 0, 1000)
	assert_int((w["batch"] as Array).size()).is_equal(0)
	assert_int(int(w["next_idx"])).is_equal(0)


# ── apply_effects (items / curses reach the Handy) ───────────────────────────

const PTS := [
	{"t": 0, "x": 0},
	{"t": 500, "x": 100},
	{"t": 1000, "x": 0},
]


func _xs(points: Array) -> Array:
	return points.map(func(p: Dictionary) -> int: return int(p["x"]))


# No stroke effects → positions unchanged, timestamps preserved.
func test_apply_effects_passthrough() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [])
	assert_array(_xs(out)).is_equal([0, 100, 0])
	assert_int(int((out[1] as Dictionary)["t"])).is_equal(500)


# Reverse mirrors around 100 (0↔100); an even count cancels.
func test_apply_effects_reverse() -> void:
	assert_array(_xs(HandyPoints.apply_effects(PTS, [{"kind": "reverse"}]))).is_equal([100, 0, 100])
	(
		assert_array(
			_xs(HandyPoints.apply_effects(PTS, [{"kind": "reverse"}, {"kind": "reverse"}]))
		)
		. is_equal([0, 100, 0])
	)


# Clamp rescales 0-100 into the sub-range.
func test_apply_effects_clamp() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "clamp", "min": 40, "max": 60}])
	assert_array(_xs(out)).is_equal([40, 60, 40])


# Scale shrinks each stroke around its local centre (midpoint of neighbours).
func test_apply_effects_scale_local_centre() -> void:
	# Middle point x=100, neighbours 0 and 0 → centre 0 → 0 + (100-0)*0.6 = 60.
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "scale", "factor": 0.6}])
	assert_int(int((out[1] as Dictionary)["x"])).is_equal(60)


# Block → flat hold line at hold_pos, timestamps intact.
func test_apply_effects_block_holds() -> void:
	var out: Array = HandyPoints.apply_effects(PTS, [{"kind": "block"}], 50)
	assert_array(_xs(out)).is_equal([50, 50, 50])
	assert_int(int((out[2] as Dictionary)["t"])).is_equal(1000)


# Non-stroke kinds (score/coin effects) are ignored.
func test_apply_effects_ignores_non_stroke() -> void:
	var out: Array = HandyPoints.apply_effects(
		PTS, [{"kind": "score_multiplier", "factor": 2.0}, {"kind": "coin_penalty", "factor": 0.5}]
	)
	assert_array(_xs(out)).is_equal([0, 100, 0])
