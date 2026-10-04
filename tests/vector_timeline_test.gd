# Vector 1A T-code encode + session timeline math (matches restim-vector-live/tests/test_timeline.py).
extends GdUnitTestSuite


func test_l0_four_digit_format() -> void:
	assert_str(VectorService.FormatTCode("L0", 0.5)).is_equal("L05000")
	assert_str(VectorService.FormatTCode("L0", 0.0)).is_equal("L00000")
	assert_str(VectorService.FormatTCode("L0", 1.0)).is_equal("L09999")


func test_timeline_axis_125_3_seconds() -> void:
	# 125.3 s at scale 10000 → encoded 0.01253 → 5-digit wire 01253
	assert_str(SessionTimeline.FormatTimelineAxis("T0", 125.3)).is_equal("T001253")


func test_timeline_round_trip_scale() -> void:
	assert_int(SessionTimeline.TimelineTcodeDigits).is_equal(5)
	var encoded: float = 125.3 / SessionTimeline.TimelineScaleSeconds
	var ticks: int = int(round(encoded * pow(10, SessionTimeline.TimelineTcodeDigits)))
	assert_int(ticks).is_equal(1253)


func test_session_timeline_resume_resets_elapsed() -> void:
	var timeline := SessionTimeline.new()
	timeline.SetRunning(true)
	timeline.Tick(120.0)
	timeline.ResetSitting()
	timeline.Tick(10.0)
	assert_float(timeline.GetPositionSeconds()).is_less(60.0)


func test_session_timeline_round_change_does_not_reset() -> void:
	var timeline := SessionTimeline.new()
	timeline.SetRunning(true)
	timeline.ConfigureRound(1, 10, 3600.0)
	timeline.Tick(300.0)
	var before: float = timeline.GetPositionSeconds()
	timeline.ConfigureRound(5, 10, 3600.0)
	assert_float(timeline.GetPositionSeconds()).is_equal_approx(before, 0.01)


func test_session_timeline_monotonic_progress() -> void:
	var timeline := SessionTimeline.new()
	timeline.SetRunning(true)
	timeline.ConfigureRound(1, 1, 3600.0, 600000.0)
	var prev: float = -1.0
	for step: int in range(1, 11):
		timeline.Tick(60.0)
		var progress: float = timeline.GetProgress()
		assert_float(progress).is_greater_equal(prev)
		prev = progress
