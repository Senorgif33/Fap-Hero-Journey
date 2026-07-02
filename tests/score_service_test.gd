extends GdUnitTestSuite

# ScoreService (C#) — bucket scoring, multiplier rounding, pause penalty,
# round transitions, and the save round-trip. Driven through the ScoreService
# autoload (GDScript can call the C# API directly); each test starts from a
# clean slate via before_test → Reset, and GdUnit runs a suite sequentially, so
# the shared singleton is safe.
#
# Bucket reference (from ScoreService.cs): amplitude <= 20 → 1 pt (small),
# <= 70 → 3 pts (medium), else 5 pts (large).


func before_test() -> void:
	ScoreService.Reset()
	ScoreService.SetMultiplier(1.0)


# Amplitude maps to the right bucket at each threshold boundary.
func test_bucket_thresholds() -> void:
	ScoreService.AddStroke(20)  # small upper bound
	assert_int(ScoreService.TotalScore).is_equal(1)
	ScoreService.Reset()
	ScoreService.AddStroke(21)  # medium lower bound
	assert_int(ScoreService.TotalScore).is_equal(3)
	ScoreService.Reset()
	ScoreService.AddStroke(70)  # medium upper bound
	assert_int(ScoreService.TotalScore).is_equal(3)
	ScoreService.Reset()
	ScoreService.AddStroke(71)  # large
	assert_int(ScoreService.TotalScore).is_equal(5)


# TotalScore = banked rounds + the in-progress round.
func test_total_accumulates_across_rounds() -> void:
	ScoreService.AddStroke(10)  # +1
	ScoreService.AddStroke(90)  # +5  → current 6
	ScoreService.EndRound()  # bank 6
	ScoreService.AddStroke(50)  # +3  → current 3
	assert_int(ScoreService.TotalScore).is_equal(9)
	assert_int(ScoreService.LastRoundScore).is_equal(6)


# StartRound discards the in-progress round's score.
func test_start_round_resets_current() -> void:
	ScoreService.AddStroke(90)  # current 5
	ScoreService.StartRound()
	assert_int(ScoreService.TotalScore).is_equal(0)


# EndRound banks the current round and surfaces it via LastRoundScore.
func test_end_round_banks_and_last_round_score() -> void:
	assert_int(ScoreService.LastRoundScore).is_equal(0)  # none completed yet
	ScoreService.AddStroke(90)  # current 5
	ScoreService.EndRound()
	assert_int(ScoreService.LastRoundScore).is_equal(5)
	assert_int(ScoreService.TotalScore).is_equal(5)


# PenalizeScore docks the current round only, clamped at 0 — banked rounds survive.
func test_penalize_clamps_at_zero_current_only() -> void:
	ScoreService.AddStroke(90)  # current 5
	ScoreService.EndRound()  # bank 5
	ScoreService.AddStroke(90)  # current 5  → total 10
	ScoreService.PenalizeScore(3)
	assert_int(ScoreService.TotalScore).is_equal(7)  # current 5→2
	ScoreService.PenalizeScore(100)
	assert_int(ScoreService.TotalScore).is_equal(5)  # current floored at 0, bank intact


# A non-positive penalty is a no-op.
func test_penalize_ignores_nonpositive() -> void:
	ScoreService.AddStroke(90)  # current 5
	ScoreService.PenalizeScore(0)
	ScoreService.PenalizeScore(-3)
	assert_int(ScoreService.TotalScore).is_equal(5)


# PenalizeScore emits ScoreChanged with the new total (the HUD listens to this).
func test_penalize_emits_score_changed() -> void:
	ScoreService.AddStroke(90)  # current/total 5
	var captured := [-1]
	var cb := func(total: int) -> void: captured[0] = total
	ScoreService.ScoreChanged.connect(cb)
	ScoreService.PenalizeScore(2)
	ScoreService.ScoreChanged.disconnect(cb)
	assert_int(captured[0]).is_equal(3)


# Multiplier scales points and rounds, but a stroke is always worth at least 1.
func test_multiplier_rounding() -> void:
	ScoreService.SetMultiplier(2.0)
	ScoreService.AddStroke(10)  # small 1 × 2 = 2
	assert_int(ScoreService.TotalScore).is_equal(2)
	ScoreService.Reset()
	ScoreService.SetMultiplier(2.0)
	ScoreService.AddStroke(90)  # large 5 × 2 = 10
	assert_int(ScoreService.TotalScore).is_equal(10)
	ScoreService.Reset()
	ScoreService.SetMultiplier(0.0)
	ScoreService.AddStroke(10)  # 1 × 0 = 0 → floored to 1
	assert_int(ScoreService.TotalScore).is_equal(1)


# CaptureSaveData → LoadFromSave restores the cumulative totals, and play
# continues adding on top.
func test_save_roundtrip() -> void:
	ScoreService.AddStroke(90)  # +5
	ScoreService.AddStroke(10)  # +1  → current 6, two strokes
	ScoreService.EndRound()
	var snapshot: Dictionary = ScoreService.CaptureSaveData()
	assert_int(snapshot["score"]).is_equal(6)
	assert_int(snapshot["strokes"]).is_equal(2)

	ScoreService.Reset()
	ScoreService.LoadFromSave(snapshot)
	assert_int(ScoreService.TotalScore).is_equal(6)
	assert_int(ScoreService.TotalStrokes).is_equal(2)

	# Further play stacks on the restored totals.
	ScoreService.StartRound()
	ScoreService.AddStroke(90)  # +5
	ScoreService.EndRound()
	assert_int(ScoreService.TotalScore).is_equal(11)
