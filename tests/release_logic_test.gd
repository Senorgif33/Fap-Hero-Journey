extends GdUnitTestSuite

# Release / "I came" — schema coercion, mode matrix (ReleaseLogic), GameState
# JumpToNode flag preservation, and ScoreService.AddScore deltas.


func before_test() -> void:
	ScoreService.Reset()
	ScoreService.SetMultiplier(1.0)


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------


func test_normalize_release_defaults_disabled() -> void:
	var n: Dictionary = JourneyData.normalize_release_round({})
	assert_bool(bool(n["release_enabled"])).is_false()
	assert_str(str(n["release_mode"])).is_equal("stamp_flag")
	assert_str(str(n["release_flag"])).is_equal("")
	assert_str(str(n["release_jump_to"])).is_equal("")
	assert_int(int(n["release_deadline_ms"])).is_equal(0)
	assert_int(int(n["release_score_hit"])).is_equal(0)
	assert_int(int(n["release_score_miss"])).is_equal(0)
	assert_bool(bool(n["release_remove_on_press"])).is_true()
	assert_bool(bool(n["release_invert"])).is_false()
	assert_str(str(n["release_disabled_if_flag"])).is_equal("")
	assert_int(int(n["release_seek_to_ms"])).is_equal(-1)
	assert_array(n["release_windows"] as Array).is_empty()


func test_coerce_round_includes_release_fields() -> void:
	var out: Dictionary = JourneyData.coerce_node_save_data(
		"round",
		{
			"release_enabled": true,
			"release_mode": "fail_jump",
			"release_flag": "came",
			"release_jump_to": "n_epi",
			"release_deadline_ms": 12000.0,  # JSON float → int
			"release_score_hit": 50,
			"release_score_miss": -10,
			"release_remove_on_press": false,
			"release_invert": true,
			"release_disabled_if_flag": "early",
			"release_seek_to_ms": 90000.0,
			"release_windows":
			[
				{"until_ms": 331000.0, "score": 20, "expire_score": 0},
				{"until_ms": 0, "score": 50, "expire_score": 20},
			],
		}
	)
	assert_bool(bool(out["release_enabled"])).is_true()
	assert_str(str(out["release_mode"])).is_equal("fail_jump")
	assert_str(str(out["release_flag"])).is_equal("came")
	assert_str(str(out["release_jump_to"])).is_equal("n_epi")
	assert_int(int(out["release_deadline_ms"])).is_equal(12000)
	assert_int(int(out["release_score_hit"])).is_equal(50)
	assert_int(int(out["release_score_miss"])).is_equal(-10)
	assert_bool(bool(out["release_remove_on_press"])).is_false()
	assert_bool(bool(out["release_invert"])).is_true()
	assert_str(str(out["release_disabled_if_flag"])).is_equal("early")
	assert_int(int(out["release_seek_to_ms"])).is_equal(90000)
	var bands: Array = out["release_windows"] as Array
	assert_int(bands.size()).is_equal(2)
	assert_int(int((bands[0] as Dictionary)["until_ms"])).is_equal(331000)
	assert_int(int((bands[0] as Dictionary)["coins"])).is_equal(20)
	assert_int(int((bands[1] as Dictionary)["expire_coins"])).is_equal(20)
	assert_int(int((bands[0] as Dictionary)["seek_to_ms"])).is_equal(-1)


func test_normalize_release_unknown_mode_falls_back() -> void:
	var n: Dictionary = JourneyData.normalize_release_round({"release_mode": "nope"})
	assert_str(str(n["release_mode"])).is_equal("stamp_flag")


func test_normalize_windows_mode_and_sort() -> void:
	var n: Dictionary = JourneyData.normalize_release_round(
		{
			"release_mode": "windows",
			"release_windows":
			[
				{"until_ms": 0, "flag": "late", "coins": 50},
				{"until_ms": 1000, "flag": "early", "coins": 20, "seek_to_ms": 5000},
			],
		}
	)
	assert_str(str(n["release_mode"])).is_equal("windows")
	var bands: Array = n["release_windows"] as Array
	assert_int(bands.size()).is_equal(2)
	assert_int(int((bands[0] as Dictionary)["until_ms"])).is_equal(1000)
	assert_str(str((bands[0] as Dictionary)["flag"])).is_equal("early")
	assert_int(int((bands[0] as Dictionary)["coins"])).is_equal(20)
	assert_int(int((bands[0] as Dictionary)["seek_to_ms"])).is_equal(5000)
	assert_int(int((bands[1] as Dictionary)["until_ms"])).is_equal(0)
	assert_str(str((bands[1] as Dictionary)["flag"])).is_equal("late")
	assert_int(int((bands[1] as Dictionary)["coins"])).is_equal(50)


func test_normalize_legacy_score_keys_to_coins() -> void:
	var b: Dictionary = JourneyData.normalize_release_band(
		{"until_ms": 100, "score": 7, "expire_score": 3}
	)
	assert_int(int(b["coins"])).is_equal(7)
	assert_int(int(b["expire_coins"])).is_equal(3)
	assert_bool(b.has("score")).is_false()


# ---------------------------------------------------------------------------
# Mode matrix (ReleaseLogic)
# ---------------------------------------------------------------------------


func test_is_available_respects_enabled_and_gate_flag() -> void:
	var flags: Dictionary = {}
	var has: Callable = func(f: String) -> bool: return bool(flags.get(f, false))
	var off: Dictionary = ReleaseLogic.normalize({})
	assert_bool(ReleaseLogic.is_available(off, has)).is_false()

	var on: Dictionary = ReleaseLogic.normalize({"release_enabled": true})
	assert_bool(ReleaseLogic.is_available(on, has)).is_true()

	var gated: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_disabled_if_flag": "early"}
	)
	assert_bool(ReleaseLogic.is_available(gated, has)).is_true()
	flags["early"] = true
	assert_bool(ReleaseLogic.is_available(gated, has)).is_false()


func test_press_action_mode_matrix() -> void:
	assert_str(
		ReleaseLogic.press_action(ReleaseLogic.normalize({"release_enabled": true, "release_mode": "windows"}))
	).is_equal(ReleaseLogic.ACTION_WINDOWS)
	assert_str(
		ReleaseLogic.press_action(ReleaseLogic.normalize({"release_enabled": true, "release_mode": "stamp_flag"}))
	).is_equal(ReleaseLogic.ACTION_SET_FLAG)
	assert_str(
		ReleaseLogic.press_action(ReleaseLogic.normalize({"release_enabled": true, "release_mode": "fail_jump"}))
	).is_equal(ReleaseLogic.ACTION_FAIL_JUMP)
	assert_str(
		ReleaseLogic.press_action(ReleaseLogic.normalize({"release_enabled": true, "release_mode": "timed_window"}))
	).is_equal(ReleaseLogic.ACTION_STAMP)
	assert_str(
		ReleaseLogic.press_action(
			ReleaseLogic.normalize({"release_enabled": true, "release_mode": "loop_until_clean"})
		)
	).is_equal(ReleaseLogic.ACTION_RESTART)
	# punish default = fail on press
	assert_str(
		ReleaseLogic.press_action(
			ReleaseLogic.normalize({"release_enabled": true, "release_mode": "punish_polarity"})
		)
	).is_equal(ReleaseLogic.ACTION_FAIL_JUMP)
	# invert = must-release success on press
	assert_str(
		ReleaseLogic.press_action(
			ReleaseLogic.normalize(
				{"release_enabled": true, "release_mode": "punish_polarity", "release_invert": true}
			)
		)
	).is_equal(ReleaseLogic.ACTION_SUCCESS_STAMP)


func test_deadline_score_hit_and_miss() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{"release_score_hit": 40, "release_score_miss": -5}
	)
	assert_int(ReleaseLogic.deadline_score(cfg, true)).is_equal(40)
	assert_int(ReleaseLogic.deadline_score(cfg, false)).is_equal(-5)


func test_fail_on_clean_finish_must_release_only() -> void:
	var must: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "punish_polarity", "release_invert": true}
	)
	assert_bool(ReleaseLogic.fail_on_clean_finish(must, false)).is_true()
	assert_bool(ReleaseLogic.fail_on_clean_finish(must, true)).is_false()

	var punish: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "punish_polarity", "release_invert": false}
	)
	assert_bool(ReleaseLogic.fail_on_clean_finish(punish, false)).is_false()

	var stamp: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "stamp_flag"}
	)
	assert_bool(ReleaseLogic.fail_on_clean_finish(stamp, false)).is_false()


func test_resolve_window_before_on_after_boundary() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{
			"release_enabled": true,
			"release_mode": "windows",
			"release_windows":
			[
				{"until_ms": 331000, "coins": 20, "flag": "early"},
				{"until_ms": 0, "coins": 50, "flag": "late"},
			],
		}
	)
	var early: Dictionary = ReleaseLogic.resolve_window(cfg, 0)
	assert_str(str(early.get("flag", ""))).is_equal("early")
	assert_int(int(early.get("coins", 0))).is_equal(20)
	# Boundary is exclusive: t == until_ms → next band
	var on_boundary: Dictionary = ReleaseLogic.resolve_window(cfg, 331000)
	assert_str(str(on_boundary.get("flag", ""))).is_equal("late")
	var after: Dictionary = ReleaseLogic.resolve_window(cfg, 400000)
	assert_str(str(after.get("flag", ""))).is_equal("late")
	assert_int(int(after.get("coins", 0))).is_equal(50)


func test_resolve_window_empty_is_noop() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "windows", "release_windows": []}
	)
	assert_dict(ReleaseLogic.resolve_window(cfg, 1000)).is_empty()


func test_expire_coins_fires_once_at_boundary_if_no_release() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{
			"release_enabled": true,
			"release_mode": "windows",
			"release_windows":
			[
				{"until_ms": 131000, "coins": 50, "expire_coins": 20},
				{"until_ms": 0, "coins": 0, "expire_coins": 0},
			],
		}
	)
	var fired: Dictionary = {}
	assert_int(ReleaseLogic.expire_coins_due(cfg, 130999, false, fired)).is_equal(0)
	assert_int(ReleaseLogic.expire_coins_due(cfg, 131000, false, fired)).is_equal(20)
	# Second tick at/after boundary must not re-award
	assert_int(ReleaseLogic.expire_coins_due(cfg, 200000, false, fired)).is_equal(0)
	assert_bool(fired.has(0)).is_true()


func test_expire_coins_skipped_after_release() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{
			"release_enabled": true,
			"release_mode": "windows",
			"release_windows":
			[
				{"until_ms": 131000, "coins": 50, "expire_coins": 20},
				{"until_ms": 0, "coins": 0, "expire_coins": 0},
			],
		}
	)
	var fired: Dictionary = {}
	assert_int(ReleaseLogic.expire_coins_due(cfg, 200000, true, fired)).is_equal(0)
	assert_bool(fired.is_empty()).is_true()


func test_expire_coins_at_round_end_open_band() -> void:
	var cfg: Dictionary = ReleaseLogic.normalize(
		{
			"release_enabled": true,
			"release_mode": "windows",
			"release_windows":
			[
				{"until_ms": 331000, "coins": 20, "expire_coins": 0},
				{"until_ms": 0, "coins": 50, "expire_coins": 20},
			],
		}
	)
	var fired: Dictionary = {}
	# Crossing early boundary with expire_coins 0 awards nothing
	assert_int(ReleaseLogic.expire_coins_due(cfg, 331000, false, fired)).is_equal(0)
	assert_int(ReleaseLogic.expire_coins_at_round_end(cfg, false, fired)).is_equal(20)
	assert_int(ReleaseLogic.expire_coins_at_round_end(cfg, false, fired)).is_equal(0)
	# After release: no round-end award if no release
	var fired2: Dictionary = {}
	assert_int(ReleaseLogic.expire_coins_at_round_end(cfg, true, fired2)).is_equal(0)


func test_applies_round_seek_legacy_continuing_only() -> void:
	var stamp: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "stamp_flag", "release_seek_to_ms": 5000}
	)
	assert_bool(ReleaseLogic.applies_round_seek(stamp, ReleaseLogic.ACTION_SET_FLAG)).is_true()
	assert_bool(ReleaseLogic.applies_round_seek(stamp, ReleaseLogic.ACTION_FAIL_JUMP)).is_false()
	var windows: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "windows", "release_seek_to_ms": 5000}
	)
	# Band seek is separate — round-level seek helper stays off for windows press action
	assert_bool(ReleaseLogic.applies_round_seek(windows, ReleaseLogic.ACTION_WINDOWS)).is_false()
	var no_seek: Dictionary = ReleaseLogic.normalize(
		{"release_enabled": true, "release_mode": "stamp_flag", "release_seek_to_ms": -1}
	)
	assert_bool(ReleaseLogic.applies_round_seek(no_seek, ReleaseLogic.ACTION_SET_FLAG)).is_false()


func test_validate_release_windows() -> void:
	var ok: Array = JourneyData.validate_release_windows(
		[{"until_ms": 1000, "coins": 1}, {"until_ms": 0, "coins": 2}], 60000
	)
	assert_array(ok).is_empty()
	var bad: Array = JourneyData.validate_release_windows(
		[{"until_ms": 1000}, {"until_ms": 2000}], 60000
	)
	assert_bool(bad.size() > 0).is_true()


# ---------------------------------------------------------------------------
# GameState JumpToNode / SetFlag / RestartCurrentRound
# ---------------------------------------------------------------------------


func _linear_graph() -> Dictionary:
	# A → B → C  (Format-2 graph)
	return {
		"start": "a",
		"nodes":
		{
			"a":
			{
				"type": "round",
				"data": {"name": "A", "set_flags": ["from_a"]},
				"out": [{"to": "b"}],
			},
			"b":
			{
				"type": "round",
				"data": {"name": "B", "set_flags": ["from_b"]},
				"out": [{"to": "c"}],
			},
			"c": {"type": "round", "data": {"name": "C"}, "out": []},
		},
	}


func test_jump_to_node_preserves_flags() -> void:
	GameState.StartJourney(_linear_graph())
	assert_bool(GameState.HasFlag("from_a")).is_true()
	GameState.SetFlag("mid_release")
	assert_bool(GameState.HasFlag("mid_release")).is_true()
	assert_int(GameState.RoundNumber).is_equal(1)

	assert_bool(GameState.JumpToNode("c")).is_true()
	assert_str(GameState.CurrentRound()["name"]).is_equal("C")
	# Prior flags survive; landing on C does not clear them.
	assert_bool(GameState.HasFlag("from_a")).is_true()
	assert_bool(GameState.HasFlag("mid_release")).is_true()
	assert_int(GameState.RoundNumber).is_equal(2)  # counted C


func test_seek_to_node_clears_flags_unlike_jump() -> void:
	GameState.StartJourney(_linear_graph())
	GameState.SetFlag("mid_release")
	assert_bool(GameState.SeekToNode("c")).is_true()
	assert_bool(GameState.HasFlag("mid_release")).is_false()
	assert_bool(GameState.HasFlag("from_a")).is_false()


func test_jump_to_missing_node_is_noop() -> void:
	GameState.StartJourney(_linear_graph())
	assert_str(GameState.CurrentNodeId()).is_equal("a")
	assert_bool(GameState.JumpToNode("missing")).is_false()
	assert_str(GameState.CurrentNodeId()).is_equal("a")


func test_restart_current_round_stays_put() -> void:
	GameState.StartJourney(_linear_graph())
	GameState.Advance()  # → B
	assert_str(GameState.CurrentRound()["name"]).is_equal("B")
	var before: int = GameState.RoundNumber
	assert_bool(GameState.RestartCurrentRound()).is_true()
	assert_str(GameState.CurrentRound()["name"]).is_equal("B")
	assert_int(GameState.RoundNumber).is_equal(before)
	assert_bool(GameState.HasFlag("from_a")).is_true()
	assert_bool(GameState.HasFlag("from_b")).is_true()


# ---------------------------------------------------------------------------
# ScoreService.AddScore
# ---------------------------------------------------------------------------


func test_add_score_positive_and_negative_clamp() -> void:
	ScoreService.AddScore(10)
	assert_int(ScoreService.TotalScore).is_equal(10)
	ScoreService.AddScore(-3)
	assert_int(ScoreService.TotalScore).is_equal(7)
	ScoreService.AddScore(-100)
	assert_int(ScoreService.TotalScore).is_equal(0)
	ScoreService.EndRound()
	ScoreService.AddScore(5)
	ScoreService.AddScore(-100)
	assert_int(ScoreService.TotalScore).is_equal(0)  # current floored; bank was 0 from prev
	# Bank a round, then prove AddScore can't eat banked points:
	ScoreService.Reset()
	ScoreService.AddScore(8)
	ScoreService.EndRound()
	ScoreService.AddScore(4)
	ScoreService.AddScore(-100)
	assert_int(ScoreService.TotalScore).is_equal(8)  # bank 8 + current 0
